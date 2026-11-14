import Foundation
import TaptionAssistantProtocol

/// PIN은 서버가 비밀 값(pepper)을 섞은 HMAC으로만 확인한다(SEC1110A03). 기기에는 PIN도 검증값도 두지 않고,
/// 「PIN을 정했다」는 표시만 남긴다. PIN 글자는 시트 상태에만 있다가 TLS로 보낸다.
@MainActor
public enum AssistantPINStore {
    public static let setKey = "assistantPINSet"

    public enum Change: Equatable, Sendable {
        case saved
        case refused(AssistantServerRefusal)
        case invalid
        case failed
    }

    public static func isSet(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: setKey) }

    /// `POST /pin` `{"pin"}`, 바꿀 때는 `{"pin","currentPin"}`(주 키).
    public static func set(pin: String, current: String?, env: AssistantRegistration.Environment) async -> Change {
        guard AssistantPIN.isValid(pin), current.map(AssistantPIN.isValid) ?? true else { return .invalid }
        var body = ["pin": pin]
        if let current { body["currentPin"] = current }
        guard let master = env.secrets.read(.master), let data = try? JSONSerialization.data(withJSONObject: body) else { return .failed }
        let reply = await TripRelay.send(TripRelay.relayRequest("/pin", method: "POST", body: data, token: master, host: env.host, client: env.client()), session: env.session)
        guard let reply else { return .failed }
        guard (200..<300).contains(reply.status) else {
            return AssistantServerRefusal.parse(status: reply.status, data: reply.data).map(Change.refused) ?? .failed
        }
        env.defaults.set(true, forKey: setKey)
        return .saved
    }
}

/// `POST /keys`·OAuth 승인 거절(SEC1110A02). 잠금 문구는 서버가 준 것을 먼저 보인다.
public struct AssistantServerRefusal: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case wrongPIN
        case locked
        case pinNotSet
        /// 503 `pin_check_unavailable`.
        case unavailable
        /// 422 `current_pin_required`: PIN을 바꿀 때 지금 PIN이 빠졌다.
        case currentPINRequired
        /// 404 `not_found`: 서버가 이 주소를 모른다(앱보다 옛 서버).
        case serverOutdated
        /// 401: 이 기기의 주 키가 서버에 없다(CUE1110A01).
        case unauthorized
        /// 422 `too_many_keys`: 연결이 20개다.
        case tooManyKeys
        /// 409 `key_conflict`·`revoked_key`: 쓸 수 없는 키다.
        case conflict
        /// 그 밖의 422: 형식이 맞지 않는다.
        case invalid
        /// PIN이 아닌 429: 요청이 많다.
        case rateLimited
    }

    public var kind: Kind
    public var message: String?
    public var retryAfterSeconds: Int?
    public var remaining: Int?

    public init(kind: Kind, message: String? = nil, retryAfterSeconds: Int? = nil, remaining: Int? = nil) {
        self.kind = kind
        self.message = message
        self.retryAfterSeconds = retryAfterSeconds
        self.remaining = remaining
    }

    public static func parse(status: Int, data: Data, retryAfterHeader: String? = nil, now: Date = .now) -> Self? {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let error = ((object["error"] as? String) ?? "").lowercased()
        let message = (object["message"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        var retry = (object["retryAfter"] as? Int) ?? retryAfterHeader.flatMap { Int($0) }
        if retry == nil, let until = (object["lockedUntil"] as? String).flatMap(TripRelay.isoDate) {
            retry = max(0, Int(until.timeIntervalSince(now)))
        }
        let remaining = (object["remaining"] as? Int) ?? (object["attemptsLeft"] as? Int)
        if status == 404, error == "not_found" { return Self(kind: .serverOutdated, message: nil) }
        if status == 503 || error == "pin_check_unavailable" { return Self(kind: .unavailable, message: nil) }
        if error == "current_pin_required" { return Self(kind: .currentPINRequired, message: message) }
        if status == 423 || error.contains("lock") || (status == 429 && error.contains("pin")) {
            return Self(kind: .locked, message: message, retryAfterSeconds: retry, remaining: nil)
        }
        if error.contains("pin_not_set") || error.contains("no_pin") || error.contains("pin_required") {
            return Self(kind: .pinNotSet, message: message)
        }
        if error.contains("pin") || status == 403 {
            return Self(kind: .wrongPIN, message: message, remaining: remaining)
        }
        if status == 401 { return Self(kind: .unauthorized, message: nil) }
        if error == "too_many_keys" { return Self(kind: .tooManyKeys, message: nil) }
        if status == 409 { return Self(kind: .conflict, message: nil) }
        if status == 422 { return Self(kind: .invalid, message: nil) }
        if status == 429 { return Self(kind: .rateLimited, message: nil, retryAfterSeconds: retry) }
        return nil
    }
}
