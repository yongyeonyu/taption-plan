import Foundation

/// 서버로 가는 요청 하나. 비밀(토큰·증명·주인 열쇠)은 헤더와 본문에만 싣고 `path`·`query`에는 넣지 않는다.
public struct ShareHTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var query: [URLQueryItem]
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, path: String, query: [URLQueryItem] = [], headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public struct ShareHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// 소켓이 닫혔을 때 `receive()`가 던지는 값.
public struct ShareSocketClosed: Error, Sendable, Equatable {
    public var code: Int

    public init(code: Int) { self.code = code }
}

/// 열린 소켓 하나. 글자 메시지만 다룬다.
public protocol ShareSocket: Sendable {
    func send(_ text: String) async throws
    /// 다음 글자 메시지. 닫히면 `ShareSocketClosed`를 던진다.
    func receive() async throws -> String
    func close(code: Int) async
}

/// 전송 추상화. 기준 주소는 구현이 들고 있다(패키지는 서버 주소를 모른다).
/// 전송 실패는 `ShareError.offline`(인터넷 없음) 또는 `ShareError.transport`로 던진다. 4xx·5xx는 응답으로 돌려준다.
public protocol ShareTransport: Sendable {
    func send(_ request: ShareHTTPRequest) async throws -> ShareHTTPResponse
    func openSocket(path: String, headers: [String: String]) async throws -> any ShareSocket
}

/// `URLSession` 구현. 앱이 기준 주소(중계 서버)를 넣어 만든다.
public struct URLSessionShareTransport: ShareTransport {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func send(_ request: ShareHTTPRequest) async throws -> ShareHTTPResponse {
        guard let url = Self.url(base: baseURL, path: request.path, query: request.query) else { throw ShareError.transport }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        if request.body != nil { urlRequest.setValue("application/json", forHTTPHeaderField: "content-type") }
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw ShareError.transport }
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
            }
            return ShareHTTPResponse(status: http.statusCode, headers: headers, body: data)
        } catch {
            throw Self.shareError(error)
        }
    }

    public func openSocket(path: String, headers: [String: String]) async throws -> any ShareSocket {
        guard let url = Self.url(base: baseURL, path: path, query: [], socket: true) else { throw ShareError.transport }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1024 * 1024 // 서버가 주는 `changes` 응답이 기본 한도보다 클 수 있다.
        task.resume()
        return URLSessionShareSocket(task: task)
    }

    /// 기준 주소 + 경로. 소켓이면 http → ws, https → wss.
    static func url(base: URL, path: String, query: [URLQueryItem], socket: Bool = false) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let prefix = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        parts.path = prefix + path
        parts.queryItems = query.isEmpty ? nil : query
        parts.fragment = nil
        if socket { parts.scheme = parts.scheme == "http" ? "ws" : "wss" }
        return parts.url
    }

    static func shareError(_ error: any Error) -> ShareError {
        if let error = error as? ShareError { return error }
        guard let code = (error as? URLError)?.code else { return .transport }
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        default:
            return .transport
        }
    }
}

/// `URLSessionWebSocketTask`를 감싼 소켓.
final class URLSessionShareSocket: ShareSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) { self.task = task }

    func send(_ text: String) async throws {
        do { try await task.send(.string(text)) } catch { throw ShareError.transport }
    }

    func receive() async throws -> String {
        while true {
            let message: URLSessionWebSocketTask.Message
            do { message = try await task.receive() } catch {
                // 서버가 닫았으면 닫힘 코드가 있고, 신호가 끊겼으면 없다(-1 → 1006으로 본다).
                let code = task.closeCode.rawValue
                throw ShareSocketClosed(code: code > 0 ? code : 1006)
            }
            if case .string(let text) = message { return text }
        }
    }

    func close(code: Int) async {
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
    }
}
