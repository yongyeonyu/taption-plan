import Foundation

enum AssistantPIN {
    static func isValid(_ pin: String) -> Bool {
        pin.count == 6 && pin.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }
}

/// PIN은 서버가 비밀 값(pepper)을 섞은 HMAC으로만 확인한다(SEC1110A03). 기기에는 PIN도 검증값도 두지 않고,
/// 「PIN을 정했다」는 표시만 남긴다. PIN 글자는 시트 상태에만 있다가 TLS로 보낸다.
@MainActor
enum AssistantPINStore {
    static let setKey = "assistantPINSet"

    enum Change: Equatable {
        case saved
        case refused(AssistantServerRefusal)
        case invalid
        case failed
    }

    static func isSet(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: setKey) }

    /// `POST /pin` `{"pin"}`, 바꿀 때는 `{"pin","currentPin"}`(주 키).
    static func set(pin: String, current: String?, env: AssistantRegistration.Environment = .live) async -> Change {
        guard AssistantPIN.isValid(pin), current.map(AssistantPIN.isValid) ?? true else { return .invalid }
        var body = ["pin": pin]
        if let current { body["currentPin"] = current }
        guard let master = env.secrets.read(.master), let data = try? JSONSerialization.data(withJSONObject: body) else { return .failed }
        let reply = await TripRelay.send(TripRelay.relayRequest("/pin", method: "POST", body: data, token: master, host: env.host), session: env.session)
        guard let reply else { return .failed }
        guard (200..<300).contains(reply.status) else {
            return AssistantServerRefusal.parse(status: reply.status, data: reply.data).map(Change.refused) ?? .failed
        }
        env.defaults.set(true, forKey: setKey)
        return .saved
    }
}

/// `POST /keys`·OAuth 승인 거절(SEC1110A02). 잠금 문구는 서버가 준 것을 먼저 보인다.
struct AssistantServerRefusal: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case wrongPIN
        case locked
        case pinNotSet
        /// 503 `pin_check_unavailable`.
        case unavailable
        /// 422 `current_pin_required`: PIN을 바꿀 때 지금 PIN이 빠졌다.
        case currentPINRequired
    }

    var kind: Kind
    var message: String?
    var retryAfterSeconds: Int?
    var remaining: Int?

    static func parse(status: Int, data: Data, retryAfterHeader: String? = nil, now: Date = .now) -> Self? {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let error = ((object["error"] as? String) ?? "").lowercased()
        let message = (object["message"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        var retry = (object["retryAfter"] as? Int) ?? retryAfterHeader.flatMap { Int($0) }
        if retry == nil, let until = (object["lockedUntil"] as? String).flatMap(TripRelay.isoDate) {
            retry = max(0, Int(until.timeIntervalSince(now)))
        }
        let remaining = (object["remaining"] as? Int) ?? (object["attemptsLeft"] as? Int)
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
        return nil
    }

    func text(_ language: MapHomeLanguage) -> String {
        switch kind {
        case .locked:
            let minutes = retryAfterSeconds.map { max(1, Int((Double($0) / 60).rounded(.up))) }
            let fallback = minutes.map {
                language.text("PIN을 여러 번 틀려 잠겼어요. \($0)분 뒤 다시 해 주세요.", "Too many wrong PINs. Try again in \($0) min.")
            } ?? language.text("PIN을 여러 번 틀려 15분 동안 잠겼어요.", "Too many wrong PINs. Locked for 15 minutes.")
            return message.map { "\(fallback) (\($0))" } ?? fallback
        case .wrongPIN:
            if let remaining {
                return language.text("PIN이 맞지 않아요. \(remaining)번 더 틀리면 잠겨요.", "Wrong PIN. \(remaining) more tries before it locks.")
            }
            return language.text("PIN이 맞지 않아요.", "Wrong PIN.")
        case .pinNotSet:
            return language.text("먼저 「AI 연결」에서 PIN을 만들어 주세요.", "Set a PIN in AI connections first.")
        case .currentPINRequired:
            return language.text("지금 PIN을 함께 넣어 주세요.", "Enter your current PIN too.")
        case .unavailable:
            return language.text("잠시 뒤 다시 해 주세요.", "Please try again in a moment.")
        }
    }
}
