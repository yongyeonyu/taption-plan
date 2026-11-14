import CryptoKit
import Foundation
import Security

extension AssistantKeyScope {
    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .read: language.text("읽기만", "Read only")
        case .write: language.text("수정 가능", "Can edit")
        }
    }
}

extension AssistantKeyPeriod {
    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .month: language.text("30일", "30 days")
        case .quarter: language.text("90일", "90 days")
        case .year: language.text("1년", "1 year")
        case .never: language.text("만료 없음", "No expiry")
        }
    }
}

/// `POST /keys`·`GET /keys`·`DELETE /keys`(SEC1110A01). 모두 주 키로 부른다.
extension TripRelay {
    enum KeyCreation: Equatable {
        case created(AssistantScopedKey, token: String)
        case refused(AssistantServerRefusal)
        case failed
    }

    /// 새 연결 키를 만들어 PIN과 함께 서버에 올리고, 키는 키체인·이름·기간·AI는 기기 설정에 둔다(SEC1110A02).
    /// `existing`을 주면 그 키를 그대로 다시 올려 권한·기간만 바꾼다. 예전 권한의 키가 따로 남지 않는다(REV1110A06).
    @MainActor
    static func registerScopedKey(
        label: String, scope: AssistantKeyScope, period: AssistantKeyPeriod, pin: String, provider: AssistantAIProvider? = nil,
        existing: String? = nil, now: Date = .now, env: AssistantRegistration.Environment = .live
    ) async -> KeyCreation {
        guard let token = existing ?? randomToken(), let master = env.secrets.read(.master) else { return .failed }
        let expiresAt = expiry(for: period, from: now)
        let body = keysBody(token: token, scope: scope, expiresAt: expiresAt, pin: pin)
        let request = relayRequest("/keys", method: "POST", body: body, token: master, host: env.host, client: env.client())
        guard let (http, data) = await sendResponse(request, session: env.session) else { return .failed }
        guard (200..<300).contains(http.statusCode) else {
            let refusal = AssistantServerRefusal.parse(status: http.statusCode, data: data, retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"))
            return refusal.map(KeyCreation.refused) ?? .failed
        }
        guard existing != nil || env.saveConnection(token) else { return .failed }
        let key = AssistantScopedKey(id: AssistantKeyStore.keyID(token), scope: scope, expiresAt: expiresAt, source: "rest")
        AssistantKeyLabels.save(key.id, label: label, period: period, defaults: env.defaults)
        if let provider { AssistantKeyProviders.save(key.id, provider: provider, defaults: env.defaults) }
        return .created(key, token: token)
    }

    @MainActor
    static func scopedKeys(env: AssistantRegistration.Environment = .live) async -> [AssistantScopedKey]? {
        guard let master = env.secrets.read(.master),
              let reply = await send(relayRequest("/keys", method: "GET", token: master, host: env.host, client: env.client()), session: env.session) else { return nil }
        let keys: [AssistantScopedKey]? = reply.status == 204 ? [] : (reply.status == 200 ? parseKeys(reply.data) : nil)
        // 서버가 아는 연결 수를 적어 둔다. Claude처럼 OAuth로 붙은 연결은 기기에 이름표가 없다(OAC1113A01).
        if let keys {
            env.defaults.set(keys.count, forKey: AssistantKeyLabels.serverCountKey)
            AssistantKeyLabels.saveClients(keys, defaults: env.defaults)
        }
        return keys
    }

    static func revokeScopedKey(_ id: String, session: URLSession = .shared) async -> Bool {
        let reply = await send(relayRequest("/keys", method: "DELETE", query: [URLQueryItem(name: "id", value: id)], client: .live), session: session)
        guard let reply, (200..<300).contains(reply.status) else { return false }
        AssistantKeyStore.remove(id)
        AssistantKeyLabels.remove(id)
        AssistantKeyProviders.remove(id)
        return true
    }

    /// 「새 키로 바꾸기」. 새 주 키를 먼저 등록하고 예전 키로 서버 자료를 지운 뒤 바꾼다(SEC1110A02).
    /// 하나라도 서버에 닿지 못하면 바꾸지 않는다. 실패하면 nil.
    @MainActor
    static func rotateMasterKey() async -> String? {
        await AssistantRegistration.rotate(.live) ? key : nil
    }
}
