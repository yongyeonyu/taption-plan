import Foundation

extension AssistantPINStore {
    /// 앱 비밀번호를 바꾸면 서버 PIN도 새 값으로 바꾼다(PIN1110A01). 서버에 PIN이 없으면 할 일이 없다.
    /// 실패하면 다음 승인 때 「예전 PIN」으로 옮기거나 초기화한다.
    @discardableResult
    static func follow(appPassword: String, previous: String, env: AssistantRegistration.Environment = .live) async -> Change? {
        guard isSet(env.defaults),
              let next = AssistantPINDerivation.pin(appPassword: appPassword),
              let old = AssistantPINDerivation.pin(appPassword: previous), next != old else { return nil }
        return await set(pin: next, current: old, env: env)
    }
}

extension AssistantServerRefusal {
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
        case .unauthorized:
            return language.text("이 기기의 AI 연결 준비가 풀렸어요. 「AI 연결」을 닫았다가 다시 열어 주세요.", "This device's AI link needs to be set up again. Close and reopen AI connections.")
        case .tooManyKeys:
            return language.text("연결은 20개까지예요. 안 쓰는 연결을 끊고 다시 해 주세요.", "Up to 20 connections. Cut one you don't use and try again.")
        case .conflict:
            return language.text("이 키는 쓸 수 없어요. 다시 만들어 주세요.", "This key can't be used. Make a new one.")
        case .invalid:
            return language.text("요청 형식이 맞지 않아요. 앱을 업데이트해 주세요.", "The request wasn't accepted. Please update the app.")
        case .rateLimited:
            let seconds = retryAfterSeconds.map { max(1, $0) }
            return seconds.map { language.text("요청이 많아요. \($0)초 뒤 다시 해 주세요.", "Too many requests. Try again in \($0) s.") }
                ?? language.text("요청이 많아요. 잠시 뒤 다시 해 주세요.", "Too many requests. Try again in a moment.")
        case .serverOutdated:
            return language.text("서버가 아직 이 기능을 모르고 있어요. 앱이나 서버 업데이트가 필요해요.", "The server doesn't support this yet. The app or server needs an update.")
        }
    }
}
