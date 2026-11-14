import CryptoKit
import Foundation
import Security

/// AI 연결 하나의 권한(SEC1110A01). 「기록 수정 허용」을 끄면 read, 켜면 write.
enum AssistantKeyScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case read
    case write

    var id: String { rawValue }
}

extension AssistantKeyScope {
    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .read: language.text("읽기만", "Read only")
        case .write: language.text("수정 가능", "Can edit")
        }
    }
}

/// AI 연결 키의 사용 기간. 서버는 두 권한 모두 365일까지 받고, 만료 없음은 null로 보낸다.
enum AssistantKeyPeriod: Int, CaseIterable, Identifiable, Codable, Sendable {
    case month = 30
    case quarter = 90
    case year = 365
    case never = 0

    var id: Int { rawValue }
    var days: Int? { self == .never ? nil : rawValue }
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

struct AssistantScopedKey: Identifiable, Equatable, Sendable {
    var id: String
    var scope: AssistantKeyScope
    /// nil이면 만료 없음.
    var expiresAt: Date?
    /// "rest"·"oauth" 등 서버가 알려 준 연결 방식과 OAuth 앱 이름(AIR1110A03). 없을 수 있다.
    var source: String? = nil
    var client: String? = nil
    /// OAuth 연결이 돌아가는 주소의 호스트. `client`는 상대가 적어 낸 이름이라 이것을 함께 보인다(REV1110A06).
    var host: String? = nil

    func isActive(now: Date = .now) -> Bool { expiresAt.map { $0 > now } ?? true }

    func expiresSoon(now: Date = .now) -> Bool {
        expiresAt.map { $0.timeIntervalSince(now) <= 7 * 86_400 } ?? false
    }
}

/// 연결 이름(피클·ChatGPT 등)과 기간은 기기에만 둔다. 서버에는 보내지 않는다(SEC1110A01).
enum AssistantKeyLabels {
    static let labelsKey = "assistantKeyLabels"
    static let periodsKey = "assistantKeyPeriods"
    /// 마지막으로 서버에서 읽은 연결 수(OAuth 포함). 이름표가 없는 연결도 「연결됨」으로 본다.
    static let serverCountKey = "assistantServerKeyCount"

    /// 연결된 AI 수: 기기의 이름표와 서버가 알려 준 수 가운데 큰 쪽.
    static func connectionCount(_ defaults: UserDefaults = .standard) -> Int {
        max((defaults.dictionary(forKey: labelsKey) ?? [:]).count, defaults.integer(forKey: serverCountKey))
    }
    /// OAuth로 붙은 AI가 적어 낸 앱 이름(연결 id → 이름). 「AI가 한 일」에 어느 AI인지 보이는 데 쓴다(AIN1114A01).
    static let clientsKey = "assistantKeyClients"

    static func saveClients(_ keys: [AssistantScopedKey], defaults: UserDefaults = .standard) {
        var values = defaults.dictionary(forKey: clientsKey) as? [String: String] ?? [:]
        let before = values
        for key in keys { if let client = key.client.flatMap({ clean(String($0.prefix(maxLength))) }) { values[key.id] = client } }
        if values != before { defaults.set(values, forKey: clientsKey) }
    }

    static func client(_ id: String, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: clientsKey) as? [String: String])?[id]
    }

    static let maxLength = 20

    static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.count > maxLength ? nil : trimmed
    }

    static func label(_ id: String, defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: labelsKey) as? [String: String])?[id]
    }

    static func period(_ id: String, defaults: UserDefaults = .standard) -> AssistantKeyPeriod {
        ((defaults.dictionary(forKey: periodsKey) as? [String: Int])?[id]).flatMap(AssistantKeyPeriod.init(rawValue:)) ?? .quarter
    }

    static func save(_ id: String, label: String, period: AssistantKeyPeriod, defaults: UserDefaults = .standard) {
        var labels = defaults.dictionary(forKey: labelsKey) as? [String: String] ?? [:]
        var periods = defaults.dictionary(forKey: periodsKey) as? [String: Int] ?? [:]
        labels[id] = label
        periods[id] = period.rawValue
        defaults.set(labels, forKey: labelsKey)
        defaults.set(periods, forKey: periodsKey)
    }

    static func remove(_ id: String, defaults: UserDefaults = .standard) {
        var labels = defaults.dictionary(forKey: labelsKey) as? [String: String] ?? [:]
        var periods = defaults.dictionary(forKey: periodsKey) as? [String: Int] ?? [:]
        labels[id] = nil
        periods[id] = nil
        defaults.set(labels, forKey: labelsKey)
        defaults.set(periods, forKey: periodsKey)
        AssistantKeyProviders.remove(id, defaults: defaults)
    }

    static func removeAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: labelsKey)
        defaults.removeObject(forKey: periodsKey)
        defaults.removeObject(forKey: AssistantKeyProviders.defaultsKey)
        defaults.removeObject(forKey: serverCountKey)
    }
}

/// AI용 키 글자를 키체인에 둔다. 나중에 연결 안내를 다시 복사할 수 있게 한다.
enum AssistantKeyStore {
    private static let service = "com.taption.plan.triprelay.scoped"

    /// 서버가 쓰는 id: SHA-256 16진 글자의 앞 8글자.
    static func keyID(_ token: String) -> String {
        String(SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    private static func query(_ id: String? = nil) -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let id { value[kSecAttrAccount as String] = id }
        return value
    }

    static func token(for id: String) -> String? {
        var item: CFTypeRef?
        var request = query(id)
        request[kSecReturnData as String] = true
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8), TripRelay.isValidKey(value) else { return nil }
        return value
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        let id = keyID(token)
        SecItemDelete(query(id) as CFDictionary)
        var item = query(id)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ id: String) { SecItemDelete(query(id) as CFDictionary) }

    static func removeAll() { SecItemDelete(query() as CFDictionary) }
}

/// `POST /keys`·`GET /keys`·`DELETE /keys`(SEC1110A01). 모두 주 키로 부른다.
extension TripRelay {
    static func isoText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func expiry(for period: AssistantKeyPeriod, from now: Date = .now) -> Date? {
        period.days.map { now.addingTimeInterval(TimeInterval($0) * 86_400) }
    }

    /// 만료 없음은 `"expiresAt": null`로 보낸다. 연결 이름은 넣지 않는다.
    /// PIN은 몸통에만 싣고 기기에는 남기지 않는다(SEC1110A02).
    static func keysBody(token: String, scope: AssistantKeyScope, expiresAt: Date?, pin: String? = nil) -> Data? {
        var body: [String: Any] = [
            "keys": [["token": token, "scope": scope.rawValue, "expiresAt": expiresAt.map(isoText) ?? NSNull()] as [String: Any]],
        ]
        if let pin { body["pin"] = pin }
        return try? JSONSerialization.data(withJSONObject: body)
    }

    static func parseKeys(_ data: Data) -> [AssistantScopedKey]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keys = object["keys"] as? [[String: Any]] else { return nil }
        return keys.compactMap { value in
            guard let id = value["id"] as? String, let scope = (value["scope"] as? String).flatMap(AssistantKeyScope.init(rawValue:))
            else { return nil }
            // 없거나 null이면 만료 없음, 글자인데 읽지 못하면 뺀다.
            var expiresAt: Date?
            if let text = value["expiresAt"] as? String {
                guard let date = isoDate(text) else { return nil }
                expiresAt = date
            }
            return AssistantScopedKey(
                id: id, scope: scope, expiresAt: expiresAt,
                source: value["source"] as? String, client: (value["client"] as? String) ?? (value["clientName"] as? String),
                host: (value["host"] as? String).map { String($0.prefix(253)) }
            )
        }
        .sorted { ($0.expiresAt ?? .distantFuture) > ($1.expiresAt ?? .distantFuture) }
    }

    /// 주 키 바꾸기에서 예전 키로 지울 경로. 순서는 규격대로.
    static let rotationDeletionPaths = ["/keys", "/activity", "/command", "/plan"]
}

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
