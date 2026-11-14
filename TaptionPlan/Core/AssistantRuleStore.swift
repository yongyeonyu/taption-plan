import Foundation
import os
@_exported import TaptionRules

/// 지금 쓸 수 있는 규칙의 사본(AIX1114A01 P3). 가계부 분류·영수증 판정처럼 메인 액터 밖에서도 읽으므로 잠금으로 지킨다.
enum AssistantRuleSnapshot {
    private static let box = OSAllocatedUnfairLock<[Rule]>(initialState: [])

    static var rules: [Rule] { box.withLock { $0 } }
    static func set(_ rules: [Rule]) { box.withLock { $0 = rules } }
}

/// 서버 규칙 묶음의 기기 사본과 동기화. 서버가 정본이고, 앱은 같은 버전을 받아 1차 판단에 쓴다.
/// 사용자가 앱에서 끄거나 지운 것은 보낼 것(outbox)에 두었다가 서버에 올린다.
@MainActor
enum AssistantRuleStore {
    struct Op: Codable, Equatable {
        /// enable, disable, delete, put
        var op: String
        var id: String
        var rule: Rule?
    }

    static let setKey = "assistantRuleSet"
    static let outboxKey = "assistantRuleOutbox"
    static let ackedKey = "assistantRuleAcked"
    static let migratedKey = "assistantRulesMigrated"
    static let mirroredKey = "assistantRuleMirroredPaymentRules"
    /// 이 빌드가 실제로 판단에 쓰는 종류. 나머지는 읽을 수는 있어도 쓰지 않으므로 서버에 「건너뜀」으로 알린다.
    nonisolated static let appliedTypes: Set<RuleType> = [.paymentText, .skipWord, .textIgnore, .internalTransfer, .ownAccount, .sourceSwitch,
                                              .merchantCategory, .receiptHint, .calendarTitle, .rideLine]

    static func stored(_ defaults: UserDefaults = .standard) -> RuleSet {
        defaults.data(forKey: setKey).flatMap { try? JSONDecoder().decode(RuleSet.self, from: $0) } ?? RuleSet()
    }

    static func outbox(_ defaults: UserDefaults = .standard) -> [Op] {
        defaults.data(forKey: outboxKey).flatMap { try? JSONDecoder().decode([Op].self, from: $0) } ?? []
    }

    /// 서버 사본에 아직 못 올린 사용자 편집을 얹은 것. 화면과 판단은 이것을 쓴다.
    nonisolated static func applying(_ ops: [Op], to set: RuleSet) -> RuleSet {
        var rules = set.rules
        for op in ops {
            switch op.op {
            case "delete": rules.removeAll { $0.id == op.id }
            case "enable", "disable":
                if let index = rules.firstIndex(where: { $0.id == op.id }) { rules[index].enabled = op.op == "enable" }
            case "put":
                guard let rule = op.rule else { continue }
                if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule } else { rules.append(rule) }
            default: continue
            }
        }
        return RuleSet(version: set.version, rules: rules)
    }

    static func effective(_ defaults: UserDefaults = .standard) -> RuleSet { applying(outbox(defaults), to: stored(defaults)) }

    /// 쓸 규칙과 못 쓰는 규칙. 못 쓰는 것: 이 앱이 못 읽는 것 + 읽지만 아직 판단에 쓰지 않는 종류.
    nonisolated static func split(_ set: RuleSet) -> (rules: [Rule], skipped: [String]) {
        let (usable, unreadable) = RuleEngine.usable(set)
        let applied = usable.filter { RuleType(rawValue: $0.type).map(appliedTypes.contains) ?? false }
        let unused = usable.filter { !(RuleType(rawValue: $0.type).map(appliedTypes.contains) ?? false) }.map(\.id)
        return (applied, unreadable + unused)
    }

    /// 사본이 바뀌면 판단에 쓰는 사본과, 결제 문자 읽기 규칙(정규식)을 맞춘다.
    static func refreshSnapshot(_ defaults: UserDefaults = .standard) {
        let rules = split(effective(defaults)).rules
        AssistantRuleSnapshot.set(rules)
        mirrorPaymentRules(rules, defaults: defaults)
    }

    /// 서버의 결제 문자 규칙을 기존 정규식 읽기(`LedgerMessageRules`)에 맞춘다: 새로 온 것은 넣고, 꺼지거나 지워진 것은 뺀다.
    private static func mirrorPaymentRules(_ rules: [Rule], defaults: UserDefaults) {
        var mirrored = (defaults.dictionary(forKey: mirroredKey) as? [String: String]) ?? [:]
        var wanted: [String: UUID] = [:]
        for item in RuleEngine.paymentTextRules(rules: rules) {
            guard let kind = LedgerMessageRules.Kind(rawValue: item.kind) else { continue }
            let localID = UUID(uuidString: item.rule.id) ?? mirrored[item.rule.id].flatMap(UUID.init(uuidString:)) ?? UUID()
            wanted[item.rule.id] = localID
            guard !LedgerMessageRules.rules(defaults).contains(where: { $0.id == localID }),
                  case let .success(rule) = LedgerMessageRules.validated(name: item.name ?? "", pattern: item.pattern, sample: item.sample, kind: kind) else { continue }
            var copy = rule
            copy.id = localID
            LedgerMessageRules.add(copy, defaults: defaults)
        }
        for (serverID, localID) in mirrored where wanted[serverID] == nil {
            if let id = UUID(uuidString: localID) { LedgerMessageRules.remove(id, defaults: defaults) }
        }
        mirrored = wanted.mapValues(\.uuidString)
        defaults.set(mirrored, forKey: mirroredKey)
    }

    // MARK: 사용자가 고침

    private static func push(_ op: Op, defaults: UserDefaults) {
        var list = outbox(defaults).filter { !($0.id == op.id && $0.op != "put" && op.op != "put") }
        list.append(op)
        if let data = try? JSONEncoder().encode(Array(list.suffix(100))) { defaults.set(data, forKey: outboxKey) }
        refreshSnapshot(defaults)
    }

    static func setEnabled(_ id: String, _ on: Bool, defaults: UserDefaults = .standard) { push(Op(op: on ? "enable" : "disable", id: id), defaults: defaults) }
    static func delete(_ id: String, defaults: UserDefaults = .standard) { push(Op(op: "delete", id: id), defaults: defaults) }
    static func put(_ rule: Rule, defaults: UserDefaults = .standard) { push(Op(op: "put", id: rule.id, rule: rule), defaults: defaults) }

    // MARK: 동기화

    private struct OpsBody: Encodable { let baseVersion: Int; let ops: [Op] }
    private struct AckBody: Encodable { let version: Int; let engine: Int; let skipped: [String] }

    /// 보낼 것을 올리고, 서버 버전이 다르면 받아 오고, 받은 버전을 서버에 알린다. 연결된 AI가 없으면 하지 않는다.
    @discardableResult
    static func sync(env: AssistantRegistration.Environment = .live) async -> Bool {
        let defaults = env.defaults
        guard MemoPolishQueue.hasConnection(defaults), let master = env.secrets.read(.master) else { return false }
        migrateIfNeeded(defaults)
        let pending = outbox(defaults)
        if !pending.isEmpty {
            let body = try? JSONEncoder().encode(OpsBody(baseVersion: stored(defaults).version, ops: pending))
            let request = body.flatMap { TripRelay.relayRequest("/rules/ops", method: "POST", body: $0, token: master, host: env.host) }
            guard let reply = await TripRelay.send(request, session: env.session), (200..<300).contains(reply.status) else { return false }
            // 올리는 사이에 더해진 것은 남긴다.
            let rest = outbox(defaults).filter { !pending.contains($0) }
            if let data = try? JSONEncoder().encode(rest) { defaults.set(data, forKey: outboxKey) }
            defaults.set(true, forKey: migratedKey)
            // 올린 뒤에는 서버 것을 다시 받는다(버전이 올랐다).
            defaults.set(-1, forKey: ackedKey)
        }
        let version = stored(defaults).version
        let since = defaults.data(forKey: setKey) == nil || defaults.integer(forKey: ackedKey) < 0 ? nil : String(version)
        let query = since.map { [URLQueryItem(name: "since", value: $0)] } ?? []
        guard let reply = await TripRelay.send(TripRelay.relayRequest("/rules", method: "GET", query: query, token: master, host: env.host), session: env.session) else { return false }
        if reply.status == 200, let set = try? JSONDecoder().decode(RuleSet.self, from: reply.data), let data = try? JSONEncoder().encode(set) {
            defaults.set(data, forKey: setKey)
        } else if reply.status != 304 {
            return false
        }
        refreshSnapshot(defaults)
        let current = stored(defaults)
        let skipped = split(effective(defaults)).skipped
        let signature = current.version * 1_000 + skipped.count
        guard defaults.integer(forKey: ackedKey) != signature else { return true }
        let ack = try? JSONEncoder().encode(AckBody(version: current.version, engine: RuleEngine.version, skipped: skipped))
        if let reply = await TripRelay.send(ack.flatMap { TripRelay.relayRequest("/rules/ack", method: "POST", body: $0, token: master, host: env.host) }, session: env.session),
           (200..<300).contains(reply.status) {
            defaults.set(signature, forKey: ackedKey)
        }
        return true
    }

    /// 처음 한 번: 기기에만 있던 결제 문자 규칙·넣지 않을 낱말·내 계좌 이름을 서버에 올릴 것으로 둔다.
    /// 올리기가 성공한 뒤에야 끝난 것으로 적는다(`sync`).
    static func migrateIfNeeded(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migratedKey), outbox(defaults).isEmpty else { return }
        var ops: [Op] = []
        for rule in LedgerMessageRules.rules(defaults) {
            var result: [String: RuleValue] = ["kind": .text(rule.kind.rawValue)]
            if !rule.name.isEmpty { result["name"] = .text(rule.name) }
            let made = Rule(id: rule.id.uuidString, type: RuleType.paymentText.rawValue, match: ["pattern": .text(rule.pattern), "sample": .text(rule.sample)],
                            result: result, source: .init(by: "ai"))
            if RuleShape.isValid(made) { ops.append(Op(op: "put", id: made.id, rule: made)) }
        }
        for word in PaymentAlertSources.skipWords(defaults) {
            let made = Rule(id: "skip-" + stableID(word), type: RuleType.skipWord.rawValue, match: ["word": .text(word)], source: .init(by: "user"))
            if RuleShape.isValid(made) { ops.append(Op(op: "put", id: made.id, rule: made)) }
        }
        for name in LedgerOwnAccounts.names(defaults) {
            let made = Rule(id: "own-" + stableID(name), type: RuleType.ownAccount.rawValue, match: ["name": .text(name)], source: .init(by: "user"))
            if RuleShape.isValid(made) { ops.append(Op(op: "put", id: made.id, rule: made)) }
        }
        guard !ops.isEmpty else { return defaults.set(true, forKey: migratedKey) }
        if let data = try? JSONEncoder().encode(Array(ops.prefix(50))) { defaults.set(data, forKey: outboxKey) }
    }

    /// 같은 글이면 같은 id가 되게 한다(다시 올려도 겹치지 않는다).
    nonisolated static func stableID(_ text: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 36)
    }
}
