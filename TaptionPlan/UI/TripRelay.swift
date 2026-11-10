import CryptoKit
import Foundation
import Security

/// 여행 계획 중계(TRP1110A04). AI 비서가 server/trip-relay로 보낸 계획을 앱을 열 때 가져온다.
/// 연동 키는 기기 키체인에만 두고, 서버는 키의 해시만 안다. 서버 주소가 없으면 기능을 숨긴다.
enum TripRelay {
    private static let service = "com.taption.plan.triprelay"
    private static let account = "relay-key"

    static var host: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "TRIP_RELAY_HOST") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty || value.contains("$(") ? nil : value
    }

    static var isAvailable: Bool { host != nil }

    static var endpoint: URL? { host.flatMap { URL(string: "https://\($0)/plan") } }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static var key: String? {
        var item: CFTypeRef?
        var request = query
        request[kSecReturnData as String] = true
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8), isValidKey(value) else { return nil }
        return value
    }

    /// 무작위 32바이트를 base64url 43자로. 이전 키는 바로 쓸 수 없게 된다.
    @discardableResult
    static func issueKey() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let value = base64URL(Data(bytes))
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess ? value : nil
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func isValidKey(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil
    }

    /// 프롬프트 끝에 붙이는 전달 안내. 도구 호출이 되는 AI는 JSON을 서버로 바로 보낸다.
    static func deliveryInstruction(endpoint: URL, key: String) -> String {
        """

        Delivery to the app
        - After I confirm and you have output the JSON, if you can make HTTP requests, also send it:
          POST \(endpoint.absoluteString)
          Headers: Authorization: Bearer \(key) and Content-Type: application/json
          Body: exactly the same JSON.
        - Then tell me whether it was sent (201 means delivered). If you cannot make HTTP requests, just show the JSON.
        """
    }

    private static let lastReceivedKey = "tripRelayLastReceivedHash"

    /// 도착한 계획을 받는다. 없으면 nil. 반영하기 전에는 서버에서 지우지 않는다.
    static func fetch(session: URLSession = .shared) async -> String? {
        guard let request = request(method: "GET") else { return nil }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 반영을 마친 뒤 서버에서 지운다.
    static func clear(session: URLSession = .shared) async {
        guard let request = request(method: "DELETE") else { return }
        _ = try? await session.data(for: request)
    }

    /// 자동으로 띄울 새 계획인가. 지운 뒤에도 서버 캐시가 잠깐 예전 값을 돌려주므로 같은 내용은 한 번만 띄운다.
    static func isNew(_ text: String, defaults: UserDefaults = .standard) -> Bool {
        guard !isLastReceived(text, defaults: defaults) else { return false }
        defaults.set(hash(text), forKey: lastReceivedKey)
        return true
    }

    /// 중계에서 마지막으로 받은 계획과 같은 글인가. 붙여 넣은 다른 계획을 반영할 때 서버의 새 계획을 지우지 않게 한다.
    static func isLastReceived(_ text: String, defaults: UserDefaults = .standard) -> Bool {
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

extension MapHomeView {
    /// 앱을 열 때 확인한다. 처음 보는 계획이 있으면 여행 모드로 바꿔 미리보기를 띄운다.
    func checkTripRelay() async {
        guard TripRelay.isAvailable, TripRelay.key != nil, !isTripImportPresented,
              let text = await TripRelay.fetch(), !isTripImportPresented, TripRelay.isNew(text) else { return }
        pastedTripText = text
        if isTripClipboardOfferVisible { isTripClipboardOfferVisible = false }
        isTravelMode = true
        isTripImportPresented = true
    }
}
