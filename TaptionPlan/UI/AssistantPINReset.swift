import LocalAuthentication
import SwiftUI

/// PIN이 서버에 있는지 묻기와 「PIN을 잊었어요」(REV1110A06, 대표 결정).
/// 기기 표시만 믿지 않고 `GET /pin`으로 맞추고, 잊었으면 `POST /pin/reset`으로 PIN과 모든 AI 연결을 지운다.
extension AssistantPINStore {
    struct Status: Equatable, Sendable {
        var isSet: Bool
        var isLocked = false
        var retryAfterSeconds: Int?
    }

    /// `{"set":bool,"locked":bool,"retryAfter"?:초}`. 예전 서버의 `lockedUntil`도 읽는다.
    static func parseStatus(_ data: Data, now: Date = .now) -> Status? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let isSet = object["set"] as? Bool else { return nil }
        var retry = object["retryAfter"] as? Int
        if retry == nil, let until = (object["lockedUntil"] as? String).flatMap(TripRelay.isoDate) {
            retry = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
        }
        let locked = (object["locked"] as? Bool) ?? ((retry ?? 0) > 0)
        return Status(isSet: isSet, isLocked: locked, retryAfterSeconds: locked ? retry : nil)
    }

    /// 서버가 아는 PIN 상태. 기기 표시가 다르면 맞춘다. 닿지 못하면 nil.
    static func status(env: AssistantRegistration.Environment = .live) async -> Status? {
        guard let master = env.secrets.read(.master) else { return nil }
        let reply = await TripRelay.send(TripRelay.relayRequest("/pin", method: "GET", token: master, host: env.host, client: env.client()), session: env.session)
        guard let reply, reply.status == 200, let status = parseStatus(reply.data) else { return nil }
        mark(isSet: status.isSet, defaults: env.defaults)
        return status
    }

    static func mark(isSet: Bool, defaults: UserDefaults = .standard) {
        if defaults.bool(forKey: setKey) != isSet { defaults.set(isSet, forKey: setKey) }
    }

    /// `POST /pin/reset`(주 키). 서버가 PIN과 모든 연결을 지우면 기기의 연결 키·이름도 지운다.
    /// 먼저 기기 주인인지 확인한다(Face ID·Touch ID, 안 되면 기기 암호). 실패·취소면 아무것도 하지 않고,
    /// 기기 암호가 아예 없을 때만 확인 창만으로 지운다(대표 결정, REV1110A06).
    static func reset(
        env: AssistantRegistration.Environment = .live, authenticator: AssistantOwnerAuthenticating = AssistantDeviceOwnerAuthenticator(),
        reason: String
    ) async -> Bool {
        guard await authenticator.authenticate(reason: reason) != .failed else { return false }
        guard let master = env.secrets.read(.master) else { return false }
        let reply = await TripRelay.send(
            TripRelay.relayRequest("/pin/reset", method: "POST", body: Data("{}".utf8), token: master, host: env.host, client: env.client()), session: env.session
        )
        guard let reply, (200..<300).contains(reply.status),
              ((try? JSONSerialization.jsonObject(with: reply.data)) as? [String: Any])?["reset"] as? Bool == true else { return false }
        mark(isSet: false, defaults: env.defaults)
        env.clearConnections()
        AssistantKeyLabels.removeAll(defaults: env.defaults)
        return true
    }
}

enum AssistantOwnerAuthResult: Equatable, Sendable {
    case passed
    /// 틀렸거나 취소했다.
    case failed
    /// 기기에 암호가 없어 확인할 방법이 없다.
    case noPasscode
}

/// 기기 주인 확인. 시험에서 바꿔 끼우려고 나눈다.
protocol AssistantOwnerAuthenticating: Sendable {
    func authenticate(reason: String) async -> AssistantOwnerAuthResult
}

struct AssistantDeviceOwnerAuthenticator: AssistantOwnerAuthenticating {
    func authenticate(reason: String) async -> AssistantOwnerAuthResult {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return error?.code == LAError.Code.passcodeNotSet.rawValue ? .noPasscode : .failed
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true ? .passed : .failed
    }
}

/// 「PIN을 잊었어요」 확인. 모든 AI 연결이 끊긴다고 알린 뒤 본인 확인을 거쳐 지운다.
private struct AssistantPINResetDialog: ViewModifier {
    @Binding var isPresented: Bool
    let language: MapHomeLanguage
    let onDone: @MainActor (Bool) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            language.text("PIN을 지울까요?", "Erase the PIN?"), isPresented: $isPresented, titleVisibility: .visible
        ) {
            Button(language.text("PIN 지우고 연결 모두 끊기", "Erase PIN and cut all connections"), role: .destructive) {
                let reason = language.text("AI 연결 PIN을 지우려면 본인 확인이 필요해요.", "Confirm it's you to erase the AI connection PIN.")
                Task { @MainActor in onDone(await AssistantPINStore.reset(reason: reason)) }
            }
            Button(language.text("취소", "Cancel"), role: .cancel) {}
        } message: {
            Text(language.text(
                "PIN을 지우면 모든 AI 연결이 끊겨요. 새 PIN을 정한 뒤 쓰던 AI를 다시 연결해 주세요.",
                "Erasing the PIN cuts every AI connection. Set a new PIN, then reconnect the AIs you use."
            ))
        }
    }
}

extension View {
    func assistantPINReset(isPresented: Binding<Bool>, language: MapHomeLanguage, onDone: @escaping @MainActor (Bool) -> Void) -> some View {
        modifier(AssistantPINResetDialog(isPresented: isPresented, language: language, onDone: onDone))
    }
}

enum AssistantPINText {
    static func resetDone(_ language: MapHomeLanguage) -> String {
        language.text("PIN을 지웠어요. 새 PIN을 정해 주세요.", "The PIN was erased. Set a new one.")
    }

    static func resetFailed(_ language: MapHomeLanguage) -> String {
        language.text("PIN을 지우지 못했어요. 잠시 뒤 다시 해 주세요.", "Couldn't erase the PIN. Try again in a moment.")
    }
}
