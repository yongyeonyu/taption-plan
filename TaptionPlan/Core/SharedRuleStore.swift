import CryptoKit
import Foundation

/// 공통 규칙(SRL1116A01): 운영자가 검토해 서명한 규칙 묶음을 서버에서 받아 쓰고, 동의한 사용자의 AI 규칙을 후보로 올린다.
/// 설계는 `docs/SHARED_RULES_PLAN.md`. 우선순위는 내가 정한 규칙 → 내 AI가 만든 규칙 → 공통 규칙 → 코드의 표다.
@MainActor
enum SharedRuleStore {
    struct SignedBundle: Codable, Equatable {
        var version: Int
        var payload: String
        var signature: String
    }

    private struct Payload: Decodable {
        let format: String
        let version: Int
        let engine: Int
        let rules: [Rule]
    }

    static let bundleKey = "sharedRulesBundle"
    static let receiveKey = "sharedRulesReceive"
    static let offKey = "sharedRulesOff"
    static let checkedKey = "sharedRulesCheckedAt"
    static let contributeKey = "sharedRulesContribute"
    static let sentKey = "sharedRulesSent"
    /// 하루에 한 번만 확인한다. 화면을 열 때는 바로.
    static let checkInterval: TimeInterval = 86_400
    static let sentLimit = 500

    /// 서명 확인용 공개 키(Info.plist `SHARED_RULES_PUBLIC_KEY`, base64). 비어 있으면 공통 규칙을 쓰지 않는다.
    nonisolated static var publicKey: String? {
        (Bundle.main.object(forInfoDictionaryKey: "SHARED_RULES_PUBLIC_KEY") as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
    }

    // MARK: 스위치

    /// 받기는 기본 켜짐(대표 결정 2026-11-16). 켜져 있어도 서버에서 받은 것을 기기에서 쓰는 것이지 기기 정보를 보내지는 않는다.
    static func isReceiving(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: receiveKey) as? Bool ?? true }
    static func setReceiving(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: receiveKey)
        AssistantRuleStore.refreshSnapshot(defaults)
    }

    /// 후보 올리기는 기본 꺼짐. AI 연결 화면에서 사용자가 켠다.
    static func isContributing(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: contributeKey) }
    static func setContributing(_ on: Bool, defaults: UserDefaults = .standard) { defaults.set(on, forKey: contributeKey) }

    static func disabledIDs(_ defaults: UserDefaults = .standard) -> Set<String> { Set(defaults.stringArray(forKey: offKey) ?? []) }
    static func setEnabled(_ id: String, _ on: Bool, defaults: UserDefaults = .standard) {
        var off = disabledIDs(defaults)
        if on { off.remove(id) } else { off.insert(id) }
        defaults.set(Array(off).sorted(), forKey: offKey)
        AssistantRuleStore.refreshSnapshot(defaults)
    }

    // MARK: 받은 묶음

    static func stored(_ defaults: UserDefaults = .standard) -> SignedBundle? {
        defaults.data(forKey: bundleKey).flatMap { try? JSONDecoder().decode(SignedBundle.self, from: $0) }
    }

    static var version: Int { stored()?.version ?? 0 }

    /// 서명이 맞는 묶음 안에서 이 앱이 읽을 수 있고 공통으로 허용된 종류의 규칙. 서명이 틀리면 빈 목록.
    nonisolated static func rules(in bundle: SignedBundle, publicKey: String?) -> [Rule] {
        guard let publicKey, verified(bundle, publicKey: publicKey),
              let data = bundle.payload.data(using: .utf8), let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.format == "bokki-shared-rules", payload.engine <= RuleEngine.version, payload.version == bundle.version else { return [] }
        return payload.rules.compactMap { rule in
            guard let type = RuleType(rawValue: rule.type), SharedRuleFilter.sharedTypes.contains(type), rule.appliesTo <= RuleEngine.version, RuleShape.isValid(rule) else { return nil }
            var made = rule
            made.enabled = true
            made.source = .init(by: "shared")
            return made
        }
    }

    nonisolated static func verified(_ bundle: SignedBundle, publicKey: String) -> Bool {
        guard let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              let signature = Data(base64Encoded: bundle.signature), let message = bundle.payload.data(using: .utf8) else { return false }
        return key.isValidSignature(signature, for: message)
    }

    /// 받은 공통 규칙 전체(끈 것 포함). 화면용.
    static func all(_ defaults: UserDefaults = .standard, publicKey: String? = SharedRuleStore.publicKey) -> [Rule] {
        stored(defaults).map { rules(in: $0, publicKey: publicKey) } ?? []
    }

    /// 판단에 쓸 규칙. 받기가 꺼져 있거나 규칙을 꺼 둔 것은 뺀다.
    static func active(_ defaults: UserDefaults = .standard, publicKey: String? = SharedRuleStore.publicKey) -> [Rule] {
        guard isReceiving(defaults) else { return [] }
        let off = disabledIDs(defaults)
        return all(defaults, publicKey: publicKey).filter { !off.contains($0.id) }
    }

    /// 결제 문자 읽기 규칙(정규식)을 기존 읽기가 쓰는 꼴로. 내 규칙·내 AI 규칙을 다 본 다음에 쓴다.
    static func paymentRules(_ defaults: UserDefaults = .standard, publicKey: String? = SharedRuleStore.publicKey) -> [LedgerMessageRules.Rule] {
        RuleEngine.paymentTextRules(rules: active(defaults, publicKey: publicKey)).compactMap { item in
            guard let kind = LedgerMessageRules.Kind(rawValue: item.kind),
                  case let .success(rule) = LedgerMessageRules.validated(name: item.name ?? "", pattern: item.pattern, sample: item.sample, kind: kind) else { return nil }
            return rule
        }
    }

    // MARK: 받아 오기

    /// 서버에서 새 묶음이 있으면 받는다. 마지막 확인 뒤 하루가 안 지났으면(`force`가 아니면) 하지 않는다. 기기 정보를 보내지 않는 내려받기다.
    @discardableResult
    static func sync(force: Bool = false, now: Date = .now, env: AssistantRegistration.Environment = .live) async -> Bool {
        let defaults = env.defaults
        guard isReceiving(defaults), publicKey != nil else { return false }
        if !force, let last = defaults.object(forKey: checkedKey) as? Date, abs(now.timeIntervalSince(last)) < checkInterval { return false }
        guard let token = await AssistantRegistration.searchToken(env) else { return false }
        let since = stored(defaults).map { [URLQueryItem(name: "since", value: String($0.version))] } ?? []
        guard let reply = await TripRelay.send(TripRelay.relayRequest("/shared/rules", method: "GET", query: since, token: token, host: env.host, client: env.client()), session: env.session) else { return false }
        if reply.status == 401 { AssistantRegistration.searchTokenRejected(defaults: defaults) }
        guard reply.status == 200 || reply.status == 304 else { return false }
        defaults.set(now, forKey: checkedKey)
        // 서명이 맞고 지난번보다 새 묶음만 저장한다. 맞지 않으면 버리고 지난번 것을 그대로 쓴다.
        // 판 번호는 서명 안(payload)의 것과 같아야 한다. 겉의 번호만 큰 예전 묶음이 새 판을 막지 못하게 한다(REV1117A02).
        if reply.status == 200, let bundle = decode(reply.data), bundle.version > (stored(defaults)?.version ?? 0), let publicKey,
           verified(bundle, publicKey: publicKey), signedVersion(bundle) == bundle.version,
           let data = try? JSONEncoder().encode(bundle) { defaults.set(data, forKey: bundleKey) }
        AssistantRuleStore.refreshSnapshot(defaults)
        return true
    }

    private struct Reply: Decodable { let version: Int; let payload: String?; let signature: String? }
    private struct SignedVersion: Decodable { let version: Int }

    /// 서명한 글 안의 판 번호.
    nonisolated static func signedVersion(_ bundle: SignedBundle) -> Int? {
        bundle.payload.data(using: .utf8).flatMap { try? JSONDecoder().decode(SignedVersion.self, from: $0) }?.version
    }

    nonisolated static func decode(_ data: Data) -> SignedBundle? {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), let payload = reply.payload, let signature = reply.signature else { return nil }
        return SignedBundle(version: reply.version, payload: payload, signature: signature)
    }

    // MARK: 올리기 (사용자가 동의한 때만)

    /// 올릴 후보와 그 표시. 내 AI가 만든 켜진 규칙 가운데 개인 정보 거르기를 통과한 것 중 아직 안 올린 것.
    nonisolated static func pending(rules: [Rule], sent: Set<String>) -> [(mark: String, upload: SharedRuleFilter.Upload)] {
        var seen = Set<String>(), out: [(String, SharedRuleFilter.Upload)] = []
        for rule in rules where rule.source?.by == "ai" && rule.enabled {
            guard let candidate = SharedRuleFilter.candidate(from: rule) else { continue }
            let upload = SharedRuleFilter.upload(candidate)
            guard let data = try? JSONEncoder.sorted.encode(upload) else { continue }
            let mark = AssistantRuleStore.stableID(String(decoding: data, as: UTF8.self))
            if !sent.contains(mark), seen.insert(mark).inserted { out.append((mark, upload)) }
        }
        return out
    }

    private struct UploadBody: Encodable { let rules: [SharedRuleFilter.Upload] }

    /// 동의가 켜져 있고 AI 연결이 있을 때, 새 후보를 20개씩 올린다. 성공한 것만 「올림」으로 적는다.
    @discardableResult
    static func uploadCandidates(env: AssistantRegistration.Environment = .live) async -> Int {
        let defaults = env.defaults
        guard isContributing(defaults), MemoPolishQueue.hasConnection(defaults), let master = env.secrets.read(.master) else { return 0 }
        let sent = Set(defaults.stringArray(forKey: sentKey) ?? [])
        let batch = Array(pending(rules: AssistantRuleStore.effective(defaults).rules, sent: sent).prefix(20))
        guard !batch.isEmpty, let body = try? JSONEncoder().encode(UploadBody(rules: batch.map(\.upload))),
              let reply = await TripRelay.send(TripRelay.relayRequest("/shared/candidates", method: "POST", body: body, token: master, host: env.host, client: env.client()), session: env.session),
              (200..<300).contains(reply.status) else { return 0 }
        defaults.set(Array(((defaults.stringArray(forKey: sentKey) ?? []) + batch.map(\.mark)).suffix(sentLimit)), forKey: sentKey)
        return batch.count
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
}
