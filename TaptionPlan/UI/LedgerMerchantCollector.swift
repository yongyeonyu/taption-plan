import Foundation

/// 아이콘을 정하지 못한 가맹점 이름 모으기(MER1121A01, 대표 지시 2026-11-21).
/// 가계부에서 종류를 알 수 없어 통화 기호로 보이는 가맹점 이름을 중계 서버(`POST /merchants/unknown`)로 보내, 요청이 많은 것을 골라 아이콘 규칙에 등록한다.
/// - 사용자가 「데이터 보호 › 가맹점 이름 보내기」를 켰을 때만 보낸다(기본 꺼짐).
/// - 보내는 것은 이름과 건수뿐이다. 금액·시각·분류·위치·계정은 없다. 결제 문자·영수증에서 들어온 지출만 보고, 직접 쓴 것·이체·취소·통행료는 보지 않는다.
/// - `*`·숫자 연속·@·주소 꼴이 든 이름(사람 이름·카드·전화·계정이 섞일 수 있는 것)은 기기에서 먼저 거른다. 서버도 같은 검사를 한다.
@MainActor
enum LedgerMerchantCollector {
    static let enabledKey = "ledgerMerchantShareEnabled"
    static let reportedKey = "ledgerMerchantReportedIDs"
    static let lastAttemptKey = "ledgerMerchantLastAttempt"
    /// 몇 시간에 한 번만 시도한다.
    static let minimumInterval: TimeInterval = 6 * 3_600
    /// 이 기간 안의 기록만 본다.
    static let windowDays = 60
    static let batchSize = 100
    static let reportedLimit = 3_000

    struct Item: Equatable {
        var name: String
        var count: Int
    }

    struct Pending: Equatable {
        var items: [Item]
        /// 이번에 보낼 기록 id(보낸 뒤 다시 세지 않게 적어 둔다).
        var entryIDs: [UUID]
    }

    enum Failure: Equatable {
        case disabled, locked, notReady, offline, dailyLimit, server(Int)
    }

    struct Result: Equatable {
        var accepted = 0
        var rejected = 0
        var failure: Failure?
        var skippedTooSoon = false
    }

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: enabledKey) }

    static func setEnabled(_ on: Bool, defaults: UserDefaults = .standard) { defaults.set(on, forKey: enabledKey) }

    // MARK: 이름 거르기

    /// 서버가 받는 이름이면 다듬은 이름, 아니면 nil(`server/trip-relay/src/merchants.js`의 `cleanName`과 같은 규칙).
    static func clean(_ raw: String) -> String? {
        let name = raw.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard (2...40).contains(name.count) else { return nil }
        let compact = name.filter { !" ,.-".contains($0) }
        var run = 0
        for character in compact {
            run = character.isASCII && character.isNumber ? run + 1 : 0
            if run >= 4 { return nil }
        }
        if name.contains(where: { "*@:/\\<>".contains($0) }) || name.localizedCaseInsensitiveContains("http") || name.localizedCaseInsensitiveContains("www.") { return nil }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return nil }
        return name
    }

    // MARK: 모을 것

    /// 아직 보고하지 않은, 종류를 알 수 없는 결제 문자·영수증 지출을 이름별로 센다.
    static func pending(entries: [LedgerEntry], reported: Set<UUID>, now: Date = .now) -> Pending {
        let since = now.addingTimeInterval(-Double(windowDays) * 86_400)
        var counts: [String: Int] = [:]
        var ids: [UUID] = []
        for entry in entries where isCandidate(entry, since: since) && !reported.contains(entry.id) {
            guard let name = clean(entry.title) else { continue }
            counts[name, default: 0] += 1
            ids.append(entry.id)
        }
        let items = counts.map { Item(name: $0.key, count: min(100, $0.value)) }.sorted { ($0.count, $1.name) > ($1.count, $0.name) }
        return Pending(items: items, entryIDs: ids)
    }

    static func isCandidate(_ entry: LedgerEntry, since: Date) -> Bool {
        entry.kind == .expense && (entry.source == .message || entry.source == .receipt) && entry.transfer == nil && entry.canceledAt == nil
            && entry.occurredAt >= since && LedgerToll.kind(for: entry) == nil && LedgerMerchantKind.classify(entry) == nil
    }

    static func reportedIDs(_ defaults: UserDefaults = .standard) -> Set<UUID> {
        Set((defaults.stringArray(forKey: reportedKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    private static func remember(_ ids: [UUID], defaults: UserDefaults) {
        var all = defaults.stringArray(forKey: reportedKey) ?? []
        all.append(contentsOf: ids.map(\.uuidString))
        if all.count > reportedLimit { all.removeFirst(all.count - reportedLimit) }
        defaults.set(all, forKey: reportedKey)
    }

    static func pendingCount(entries: [LedgerEntry] = LedgerBook.shared.entries, defaults: UserDefaults = .standard) -> Int {
        pending(entries: entries, reported: reportedIDs(defaults)).items.count
    }

    // MARK: 보내기

    static func body(_ items: [Item]) -> Data {
        let object: [String: Any] = ["format": "bokki-merchants", "version": 1, "items": items.map { ["name": $0.name, "count": $0.count] }]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// 켜져 있고 마지막 시도로부터 시간이 지났을 때만 보낸다. 가계부를 열 때 부른다.
    static func sendIfDue(
        env: AssistantRegistration.Environment = .live, defaults: UserDefaults = .standard, now: Date = .now,
        entries: [LedgerEntry] = LedgerBook.shared.entries
    ) async -> Result {
        guard isEnabled(defaults) else { return Result(failure: .disabled) }
        if let last = defaults.object(forKey: lastAttemptKey) as? Date, now.timeIntervalSince(last) < minimumInterval {
            return Result(skippedTooSoon: true)
        }
        return await send(env: env, defaults: defaults, now: now, entries: entries)
    }

    static func send(
        env: AssistantRegistration.Environment = .live, defaults: UserDefaults = .standard, now: Date = .now,
        entries: [LedgerEntry] = LedgerBook.shared.entries
    ) async -> Result {
        var result = Result()
        guard isEnabled(defaults) else { result.failure = .disabled; return result }
        guard !env.client().locked else { result.failure = .locked; return result }
        let work = pending(entries: entries, reported: reportedIDs(defaults), now: now)
        guard !work.items.isEmpty else { return result }
        defaults.set(now, forKey: lastAttemptKey)
        guard await AssistantRegistration.prepare(env), let master = env.secrets.read(.master) else { result.failure = .notReady; return result }
        for start in stride(from: 0, to: work.items.count, by: batchSize) {
            let batch = Array(work.items[start..<min(start + batchSize, work.items.count)])
            let request = TripRelay.relayRequest("/merchants/unknown", method: "POST", body: body(batch), token: master, host: env.host, client: env.client())
            guard let reply = await TripRelay.send(request, session: env.session) else { result.failure = .offline; return result }
            switch reply.status {
            case 201:
                let counts = (try? JSONSerialization.jsonObject(with: reply.data)) as? [String: Any]
                result.accepted += counts?["accepted"] as? Int ?? 0
                result.rejected += counts?["rejected"] as? Int ?? 0
            case 429:
                result.failure = .dailyLimit
                return result
            default:
                result.failure = .server(reply.status)
                return result
            }
        }
        remember(work.entryIDs, defaults: defaults)
        return result
    }

    /// 지금까지 보낸 이름을 서버에서 지운다.
    static func eraseSent(env: AssistantRegistration.Environment = .live, defaults: UserDefaults = .standard) async -> Bool {
        guard !env.client().locked, await AssistantRegistration.prepare(env), let master = env.secrets.read(.master) else { return false }
        let request = TripRelay.relayRequest("/merchants/unknown", method: "DELETE", body: nil, token: master, host: env.host, client: env.client())
        guard let reply = await TripRelay.send(request, session: env.session), reply.status == 200 else { return false }
        defaults.removeObject(forKey: reportedKey)
        return true
    }
}

import SwiftUI

/// 「데이터 보호 › 내 데이터」의 가맹점 이름 보내기 스위치(기본 꺼짐).
struct LedgerMerchantShareRow: View {
    let language: MapHomeLanguage
    @State private var isOn = LedgerMerchantCollector.isEnabled()
    @State private var pending = 0
    @State private var status: String?
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(language.text("가맹점 이름 보내기", "Share merchant names"), isOn: Binding(
                get: { isOn },
                set: { value in
                    isOn = value
                    LedgerMerchantCollector.setEnabled(value)
                    reload()
                    if value { Task { _ = await LedgerMerchantCollector.send(); reload() } }
                }
            ))
            .tint(Color.tpReferenceMint)
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
            .accessibilityIdentifier("merchantShareToggle")
            Text(language.text(
                "가계부에서 아이콘을 정하지 못한 가게 이름만 개발자에게 보내 아이콘을 늘리는 데 써요. 금액·시각·위치·계정은 보내지 않고, 끄면 보내지 않아요.",
                "Only the names of merchants whose icon couldn't be chosen are sent to the developer to add more icons. Amounts, times, locations and accounts are never sent, and nothing is sent when off."
            ))
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if isOn {
                Text(language.text("보낼 이름 \(pending)개", "\(pending) names to send"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            }
            Button(language.text("보낸 이름 지우기", "Delete sent names"), role: .destructive) {
                Task {
                    isBusy = true
                    let done = await LedgerMerchantCollector.eraseSent()
                    status = done ? language.text("서버에서 지웠어요", "Deleted from the server") : language.text("지우지 못했어요. 잠시 뒤 다시 해 주세요.", "Couldn't delete. Try again shortly.")
                    isBusy = false
                    reload()
                }
            }
            .buttonStyle(.bordered)
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
            .disabled(isBusy)
            if let status {
                Text(status)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                    .foregroundStyle(Color.tpReferenceBlue)
            }
        }
        .task { reload() }
    }

    private func reload() {
        isOn = LedgerMerchantCollector.isEnabled()
        pending = LedgerMerchantCollector.pendingCount()
    }
}
