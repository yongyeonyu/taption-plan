import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
import UIKit

/// 구글 OAuth 설정. 클라이언트 ID는 공개 값이라 앱에 둔다. 리디렉트는 iOS 클라이언트 규칙(반전된 ID 스킴)을 따른다.
enum GoogleCalendarConfig {
    static let clientID = "12503110622-e4agan8gbaggkbopfv79jg2i96bt2p23.apps.googleusercontent.com"
    static let redirectScheme = "com.googleusercontent.apps.12503110622-e4agan8gbaggkbopfv79jg2i96bt2p23"
    static let redirectURI = redirectScheme + ":/oauth2redirect"
    static let scope = "https://www.googleapis.com/auth/calendar.readonly"
}

enum GoogleCalendarError: LocalizedError {
    case cancelled
    case notConnected
    case requestFailed
    /// 리프레시 토큰이 거부됐거나 앱 권한이 취소됐다. 다시 연결해야 한다.
    case authExpired

    var errorDescription: String? {
        switch self {
        case .cancelled: "구글 로그인이 취소됐어요."
        case .notConnected: "구글 계정이 연결되어 있지 않아요."
        case .requestFailed: "구글 캘린더를 불러오지 못했어요. 네트워크를 확인한 뒤 다시 시도해 주세요."
        case .authExpired: "구글 연결이 만료됐어요. 설정에서 다시 연결해 주세요."
        }
    }
}

/// 구글 계정 직접 연동. 로그인 → 리프레시 토큰을 키체인에 보관 → 오늘 일정을 읽는다.
@MainActor
@Observable
final class GoogleCalendarAccount: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleCalendarAccount()

    private static let keychainService = "com.taption.plan.googleCalendar"
    private static let keychainAccount = "refreshToken"

    private(set) var isConnected: Bool
    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var isConnecting = false

    override init() {
        isConnected = Self.loadRefreshToken() != nil
        super.init()
    }

    // MARK: 연결·해제

    func connect() async throws {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        let verifier = Self.randomURLSafe(byteCount: 48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: GoogleCalendarConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: GoogleCalendarConfig.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleCalendarConfig.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        let callback = try await authenticate(url: components.url!)
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw GoogleCalendarError.cancelled
        }
        let token = try await postToken([
            "client_id": GoogleCalendarConfig.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": GoogleCalendarConfig.redirectURI,
        ], isRefresh: false)
        guard let refresh = token.refreshToken else { throw GoogleCalendarError.requestFailed }
        guard Self.saveRefreshToken(refresh) else { throw GoogleCalendarError.requestFailed }
        accessToken = token.accessToken
        accessTokenExpiry = Self.expiry(afterSeconds: token.expiresIn)
        isConnected = true
    }

    func disconnect() {
        if let refresh = Self.loadRefreshToken() {
            Task { await Self.revoke(refresh) }
        }
        Self.deleteRefreshToken()
        accessToken = nil
        isConnected = false
    }

    // MARK: 일정

    /// 오늘(시작 자정 ~ 다음 날 자정) 기본 캘린더의 일정을 시작 시각순으로 돌려준다.
    func todayEvents(calendar: Calendar = .current, now: Date = .now) async throws -> [CalendarRecord] {
        let token = try await validAccessToken()
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: Self.rfc3339.string(from: start)),
            URLQueryItem(name: "timeMax", value: Self.rfc3339.string(from: end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "100"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            // 사용자가 구글에서 앱 권한을 취소했다.
            forgetConnection()
            throw GoogleCalendarError.authExpired
        }
        guard status == 200, let list = try? JSONDecoder().decode(EventList.self, from: data) else {
            throw GoogleCalendarError.requestFailed
        }
        let parser = Event.Parser(calendar: calendar)
        return list.items
            .filter { $0.status != "cancelled" }
            .compactMap { $0.record(parser: parser) }
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.span.start < rhs.span.start
            }
    }

    // MARK: 토큰

    private func validAccessToken() async throws -> String {
        if let accessToken, accessTokenExpiry > .now { return accessToken }
        guard let refresh = Self.loadRefreshToken() else {
            forgetConnection()
            throw GoogleCalendarError.notConnected
        }
        do {
            let token = try await postToken([
                "client_id": GoogleCalendarConfig.clientID,
                "refresh_token": refresh,
                "grant_type": "refresh_token",
            ], isRefresh: true)
            accessToken = token.accessToken
            accessTokenExpiry = Self.expiry(afterSeconds: token.expiresIn)
            return token.accessToken
        } catch GoogleCalendarError.authExpired {
            forgetConnection()
            throw GoogleCalendarError.authExpired
        }
    }

    /// 앱이 들고 있는 연결 정보를 지운다(구글 쪽 권한 취소는 하지 않는다: 이미 거부된 상태).
    private func forgetConnection() {
        Self.deleteRefreshToken()
        accessToken = nil
        accessTokenExpiry = .distantPast
        isConnected = false
    }

    /// 만료 60초 전에 갱신한다. 아주 짧은 수명(120초 이하)은 절반이 지나면 갱신해 매번 갱신하지 않게 한다.
    private static func expiry(afterSeconds seconds: Int) -> Date {
        let margin = seconds > 120 ? 60 : seconds / 2
        return Date.now.addingTimeInterval(TimeInterval(seconds - margin))
    }

    /// 네트워크 연결 실패를 requestFailed로 통일한다.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw GoogleCalendarError.requestFailed
        }
    }

    private struct TokenResponse: Decodable {
        var accessToken: String
        var expiresIn: Int
        var refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    private func postToken(_ fields: [String: String], isRefresh: Bool) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if isRefresh, status == 400 || status == 401 {
            throw GoogleCalendarError.authExpired
        }
        guard status == 200, let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw GoogleCalendarError.requestFailed
        }
        return token
    }

    // MARK: 로그인 창

    private func authenticate(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: GoogleCalendarConfig.redirectScheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: GoogleCalendarError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? GoogleCalendarError.cancelled)
                }
            }
            session.presentationContextProvider = self
            session.start()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }

    // MARK: 일정 응답

    fileprivate struct EventList: Decodable {
        var items: [Event]
    }

    fileprivate struct Event: Decodable {
        var id: String
        var summary: String?
        var status: String?
        var start: When?
        var end: When?

        struct When: Decodable {
            var dateTime: String?
            var date: String?
        }

        func record(parser: Parser) -> CalendarRecord? {
            guard let start, let startDate = parser.instant(start) else { return nil }
            let endDate = end.flatMap { parser.instant($0) } ?? startDate.addingTimeInterval(3_600)
            let isAllDay = start.dateTime == nil
            return CalendarRecord(
                id: "google-\(id)",
                calendarID: "google-primary",
                title: summary ?? "(제목 없음)",
                span: TimeSpan(start: startDate, end: max(endDate, startDate)),
                isAllDay: isAllDay,
                calendarTitle: "구글 캘린더",
                calendarColorHex: nil,
                sourceTitle: "Google"
            )
        }

        /// 한 번 만든 포매터를 여러 일정에 재사용한다. 종일 일정은 "yyyy-MM-dd", 시간 일정은 RFC 3339다.
        struct Parser {
            private let plain = ISO8601DateFormatter()
            private let fractional: ISO8601DateFormatter = {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter
            }()
            private let day: DateFormatter

            init(calendar: Calendar) {
                day = DateFormatter()
                day.calendar = calendar
                day.timeZone = calendar.timeZone
                day.dateFormat = "yyyy-MM-dd"
            }

            func instant(_ when: When) -> Date? {
                if let dateTime = when.dateTime {
                    return plain.date(from: dateTime) ?? fractional.date(from: dateTime)
                }
                return when.date.flatMap { day.date(from: $0) }
            }
        }
    }

    // MARK: 키체인

    private static func loadRefreshToken() -> String? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func saveRefreshToken(_ token: String) -> Bool {
        deleteRefreshToken()
        var query = keychainQuery()
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// 해제할 때 구글 쪽 권한도 취소한다. 실패해도 로컬 토큰은 지운다.
    private static func revoke(_ token: String) async {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "token=\(formEncode(token))".data(using: .utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func deleteRefreshToken() {
        SecItemDelete(keychainQuery() as CFDictionary)
    }

    private static func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    // MARK: 유틸

    private static let rfc3339: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? value
    }
}
