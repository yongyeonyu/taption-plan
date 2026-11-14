import Foundation
import Security

/// 주 키 등록과 한 번 바꾸기, 지도 검색용 키(SEC1110A02).
/// 서버는 등록한 키만 받는다. 주 키는 앱이 만들고 사용자가 고르지 않는다.
@MainActor
public enum AssistantRegistration {
    public static let registeredKey = "assistantRegisteredMasterID"
    public static let searchRegisteredKey = "assistantRegisteredSearchID"
    public static let rotationKey = "assistantMasterRotation"
    /// 이 값이 있으면 이번 배포의 주 키 바꾸기를 마쳤다.
    public static let rotationTag = "SEC1110A02"
    /// 바꾸기 전에 AI 연결이 있었으면 다시 만들어 달라고 알린다.
    public static let reconnectKey = "assistantNeedsReconnect"

    public typealias Environment = AssistantEnvironment

    public enum Reply: Equatable, Sendable {
        case registered
        /// 409: 다른 목적(검색·연결 키)으로 쓰인 키라 주 키가 될 수 없다.
        case conflict
        case lowEntropy
        case failed(Int?)

        public var ok: Bool { self == .registered || self == .conflict }
    }

    public static func isReady(_ env: Environment) -> Bool {
        guard let master = env.secrets.read(.master), TripRelay.isValidKey(master) else { return false }
        return env.defaults.string(forKey: rotationKey) == rotationTag
            && env.defaults.string(forKey: registeredKey) == AssistantKeyStore.keyID(master)
    }

    /// 새 설치는 주 키를 만들어 등록하고, 예전 설치(빌드 305 이하)는 한 번 바꾼다.
    public static func prepare(_ env: Environment) async -> Bool {
        guard env.host != nil else { return false }
        if isReady(env) { return true }
        let master = env.secrets.read(.master).flatMap { TripRelay.isValidKey($0) ? $0 : nil }
        if let master, env.defaults.string(forKey: rotationKey) == rotationTag {
            // 바꾸기는 마쳤는데 등록 표시만 없다(예: 설정 초기화).
            guard await register(master, env: env).ok else { return false }
            env.defaults.set(AssistantKeyStore.keyID(master), forKey: registeredKey)
            return true
        }
        return await rotate(env)
    }

    /// 새 주 키를 등록하고, 예전 키로 서버의 키·기록·명령·계획을 지운 뒤 바꾼다.
    /// 중간에 끊기면 만들어 둔 새 키로 다음에 이어 간다. 「새 키로 바꾸기」도 이 길을 쓴다.
    /// 바꾸는 동안 올리기·명령 받기는 쉬게 하고, 하던 것이 끝나기를 기다린다(REV1110A06).
    public static func rotate(_ env: Environment) async -> Bool {
        guard AssistantRelayGate.beginRotation() else { return false }
        defer { AssistantRelayGate.endRotation() }
        guard await AssistantRelayGate.waitUntilIdle() else { return false }
        return await rotateExclusively(env)
    }

    private static func rotateExclusively(_ env: Environment) async -> Bool {
        let old = env.secrets.read(.master).flatMap { TripRelay.isValidKey($0) ? $0 : nil }
        guard let fresh = env.secrets.read(.pendingMaster).flatMap({ TripRelay.isValidKey($0) ? $0 : nil }) ?? TripRelay.randomToken(),
              env.secrets.write(fresh, to: .pendingMaster) else { return false }
        switch await register(fresh, env: env) {
        case .registered: break
        case .lowEntropy, .conflict:
            env.secrets.write(nil, to: .pendingMaster)
            return false
        case .failed: return false
        }
        if let old, old != fresh, await !deleteServerData(of: old, env: env) { return false }
        let hadConnections = !((env.defaults.dictionary(forKey: AssistantKeyLabels.labelsKey) ?? [:]).isEmpty)
        guard env.secrets.write(fresh, to: .master) else { return false }
        env.secrets.write(nil, to: .pendingMaster)
        env.defaults.set(AssistantKeyStore.keyID(fresh), forKey: registeredKey)
        env.defaults.set(rotationTag, forKey: rotationKey)
        // 새 주 키에는 PIN이 없으니 다시 정한다(SEC1110A03).
        env.defaults.set(false, forKey: AssistantPINStore.setKey)
        env.clearConnections()
        AssistantKeyLabels.removeAll(defaults: env.defaults)
        // 새 키에는 서버 기록이 없으니 처음부터 다시 올린다.
        AssistantActivityUploadGate.reset(defaults: env.defaults)
        env.defaults.set(false, forKey: AssistantActivityFlags.sharedKey)
        env.defaults.set(false, forKey: AssistantActivityFlags.pendingClearKey)
        if hadConnections { env.defaults.set(true, forKey: reconnectKey) }
        return true
    }

    /// 예전 주 키의 서버 자료를 지운다. 등록을 확인한 뒤 지우고, 지우기는 2xx만 성공으로 본다(REV1110A06).
    /// 등록할 수 없는 키(422·409)는 주 키로 쓰인 적도 쓰일 수도 없어 지울 것이 없다.
    private static func deleteServerData(of old: String, env: Environment) async -> Bool {
        switch await register(old, env: env) {
        case .registered: break
        case .lowEntropy, .conflict: return true
        case .failed: return false
        }
        for path in TripRelay.rotationDeletionPaths {
            let reply = await TripRelay.send(TripRelay.relayRequest(path, method: "DELETE", token: old, host: env.host, client: env.client()), session: env.session)
            guard let reply, (200..<300).contains(reply.status) else { return false }
        }
        return true
    }

    /// `POST /register`. 2xx는 등록, 409는 다른 목적으로 이미 쓰인 키.
    public static func register(_ token: String, env: Environment, purpose: String? = nil) async -> Reply {
        var body: [String: Any] = [:]
        if let purpose { body["purpose"] = purpose }
        let data = try? JSONSerialization.data(withJSONObject: body)
        let reply = await TripRelay.send(
            TripRelay.relayRequest("/register", method: "POST", body: data, token: token, host: env.host, client: env.client()), session: env.session
        )
        guard let reply else { return .failed(nil) }
        if (200..<300).contains(reply.status) { return .registered }
        if reply.status == 409 { return .conflict }
        return reply.status == 422 ? .lowEntropy : .failed(reply.status)
    }

    // MARK: 지도 검색용 키

    /// 카카오 검색에 붙이는 설치마다의 검색 전용 키(PIN 없음). 등록하지 못하면 nil.
    public static func searchToken(_ env: Environment) async -> String? {
        guard env.host != nil else { return nil }
        let stored = env.secrets.read(.search).flatMap { TripRelay.isValidKey($0) ? $0 : nil }
        guard let token = stored ?? TripRelay.randomToken() else { return nil }
        if stored == nil { env.secrets.write(token, to: .search) }
        if env.defaults.string(forKey: searchRegisteredKey) == AssistantKeyStore.keyID(token) { return token }
        switch await register(token, env: env, purpose: "search") {
        case .registered, .conflict:
            env.defaults.set(AssistantKeyStore.keyID(token), forKey: searchRegisteredKey)
            return token
        case .lowEntropy:
            env.secrets.write(nil, to: .search)
            return nil
        case .failed:
            return nil
        }
    }

    /// 서버가 검색 키를 모른다고 하면(401) 다음 검색 때 다시 등록한다.
    public static func searchTokenRejected(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: searchRegisteredKey)
    }
}

/// 날마다 마지막으로 올린 내용의 해시(TRP1110A07). 바뀐 날만 다시 올린다.
public enum AssistantActivityUploadGate {
    public static let defaultsKey = "assistantActivityHashes"

    public static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// 하루 기록 올리기가 기기 설정에 남기는 표시의 키. 주 키를 바꿀 때도 지운다.
public enum AssistantActivityFlags {
    public static let sharedKey = "assistantActivityShared"
    /// 공유 수준을 낮추거나 보관 기간을 줄여 서버 기록을 지워야 한다는 표시. 지울 때까지 올리지 않는다(REV1110A06).
    public static let pendingClearKey = "assistantActivityPendingClear"
}
