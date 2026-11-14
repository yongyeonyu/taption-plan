import CryptoKit
import Foundation
import Security

/// 여행 계획 중계(TRP1110A04). AI 비서가 server/trip-relay로 보낸 계획을 앱을 열 때 가져온다.
/// 연동 키는 기기 키체인에만 두고, 서버는 키의 해시만 안다. 서버 주소가 없으면 기능을 숨긴다.
public enum TripRelay {
    private static let service = "com.taption.plan.triprelay"
    private static let account = "relay-key"

    public static var host: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "TRIP_RELAY_HOST") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty || value.contains("$(") ? nil : value
    }

    public static var isAvailable: Bool { host != nil }

    public static var endpoint: URL? { host.flatMap { URL(string: "https://\($0)/plan") } }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public static var key: String? {
        var item: CFTypeRef?
        var request = query
        request[kSecReturnData as String] = true
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8), isValidKey(value) else { return nil }
        return value
    }

    /// 무작위 32바이트를 base64url 43자로(AI용 키도 같은 모양, SEC1110A01).
    public static func randomToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return base64URL(Data(bytes))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func isValidKey(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil
    }

    /// 프롬프트 끝에 붙이는 전달 안내. 도구 호출이 되는 AI는 JSON을 서버로 바로 보낸다.
    /// `key`에는 그 AI의 연결 키만 넣는다. 주 키는 넣지 않는다(SEC1110A02).
    public static func deliveryInstruction(endpoint: URL, key: String) -> String {
        """

        Delivery to the app
        - After I confirm and you have output the JSON, if you can make HTTP requests, also send it:
          POST \(endpoint.absoluteString)
          Headers: \(headerLines(key: key))
          Body: exactly the same JSON.
        - Then tell me whether it was sent (201 means delivered). If you cannot make HTTP requests, just show the JSON.
        """
    }

    private static let lastReceivedKey = "tripRelayLastReceivedHash"

    /// 도착한 계획을 받는다. 없으면 nil. 반영하기 전에는 서버에서 지우지 않는다.
    public static func fetch(session: URLSession = .shared) async -> String? {
        guard let reply = await send(request(method: "GET"), session: session), reply.status == 200 else { return nil }
        return String(data: reply.data, encoding: .utf8)
    }

    /// 반영을 마친 뒤 서버에서 지운다.
    public static func clear(session: URLSession = .shared) async {
        _ = await send(request(method: "DELETE"), session: session)
    }

    /// 자동으로 띄울 새 계획인가. 지운 뒤에도 서버 캐시가 잠깐 예전 값을 돌려주므로 같은 내용은 한 번만 띄운다.
    public static func isNew(_ text: String, defaults: UserDefaults = .standard) -> Bool {
        guard !isLastReceived(text, defaults: defaults) else { return false }
        defaults.set(hash(text), forKey: lastReceivedKey)
        return true
    }

    /// 중계에서 마지막으로 받은 계획과 같은 글인가. 붙여 넣은 다른 계획을 반영할 때 서버의 새 계획을 지우지 않게 한다.
    public static func isLastReceived(_ text: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: lastReceivedKey) == hash(text)
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func request(method: String) -> URLRequest? {
        guard let endpoint, let key else { return nil }
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }
}

/// 중계 서버의 다른 경로를 부르는 주소와 보내기(429 다시 보내기 포함). 요청 만들기(`relayRequest`)는 `AssistantSharing.swift`에 있다.
extension TripRelay {
    public static func url(_ path: String, query: [URLQueryItem] = [], host: String? = TripRelay.host) -> URL? {
        guard let host else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = path
        parts.queryItems = query.isEmpty ? nil : query
        return parts.url
    }

    /// 상태 코드만 돌려준다. 실패하면 nil.
    public static func send(_ request: URLRequest?, session: URLSession = .shared) async -> (status: Int, data: Data)? {
        await sendResponse(request, session: session).map { ($0.response.statusCode, $0.data) }
    }

    /// 백그라운드 새로 고침처럼 시간이 없을 때는 429를 기다리지 않는다.
    @TaskLocal public static var singleAttempt = false
    /// 이보다 오래 기다리라는 429(하루 한도 등)는 다시 보내지 않고 그대로 돌려준다.
    public static let maximumRetryWait: Double = 5
    public static let retryLimit = 2

    /// 429면 `Retry-After`(없으면 몸통 `retryAfter`)만큼 기다려 두 번까지 다시 보낸다(SEC1110A03).
    /// 기다림이 길거나 하루 한도이거나 작업이 취소되면 받은 429를 그대로 돌려준다(REV1110A06).
    public static func sendResponse(_ request: URLRequest?, session: URLSession = .shared) async -> (response: HTTPURLResponse, data: Data)? {
        guard let request else { return nil }
        for attempt in 0...retryLimit {
            guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 429, attempt < retryLimit, !singleAttempt,
                  let wait = retryWait(header: http.value(forHTTPHeaderField: "Retry-After"), body: data) else { return (http, data) }
            do { try await Task.sleep(for: .seconds(wait)) } catch { return (http, data) }
        }
        return nil
    }

    /// 다시 보낼 만하면 기다릴 초, 아니면 nil.
    public static func retryWait(header: String?, body: Data) -> Double? {
        let error = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? String ?? ""
        let delay = retryDelay(header: header, body: body)
        return error.hasPrefix("daily_") || error == "write_budget_exhausted" || delay > maximumRetryWait ? nil : delay
    }

    public static func retryDelay(header: String?, body: Data) -> Double {
        let fromBody = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["retryAfter"] as? Double
        return min(60, max(0, header.flatMap(Double.init) ?? fromBody ?? 15))
    }

    public static func headerLines(key: String) -> String {
        "Authorization: Bearer \(key) and Content-Type: application/json"
    }
}
