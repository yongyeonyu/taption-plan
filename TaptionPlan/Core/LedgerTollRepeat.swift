import Foundation
import SwiftUI

/// 같은 길 통행료 자동 넣기(TOL1111A01, 대표 지시 「돌아온 고속도로 톨비 자동 추가」).
/// 앱은 어느 요금소를 지났는지 모른다. 그래서 통행료 지출이 붙은 자동차 이동(출발→도착)을 배워 두고,
/// 같은 길이나 되돌아오는 길을 차로 다시 가면 같은 통행료를 넣는다. 한 이동에는 한 번만 넣고,
/// 사용자가 지워도 다시 넣지 않는다. 이미 그 무렵 통행료가 있으면 넣지 않는다.
enum LedgerTollRepeat {
    struct Drive: Equatable {
        var from: String
        var to: String
        var start: Date
        var end: Date

        var key: String { "\(from)|\(to)|\(Int(start.timeIntervalSince1970 / 60))" }
    }

    struct Rule: Codable, Equatable {
        var amount: Double
        var currency: String
        var title: String
        var learnedAt: Date
    }

    /// 통행료가 이 이동 무렵(출발 30분 전 ~ 도착 60분 뒤)에 있으면 그 이동의 통행료로 본다.
    static let before: TimeInterval = 30 * 60
    static let after: TimeInterval = 60 * 60
    /// 도착하고 이만큼 지나야 넣는다(같은 이동이 아직 이어질 수 있다).
    static let settle: TimeInterval = 10 * 60

    static func isToll(_ entry: LedgerEntry) -> Bool {
        guard entry.kind == .expense, entry.transfer == nil, entry.category == .transport else { return false }
        let title = entry.title.lowercased()
        return title.contains("통행료") || title.contains("톨비") || title.contains("toll")
    }

    static func pair(_ from: String, _ to: String) -> String { "\(from)→\(to)" }

    /// 그 무렵 통행료가 있는 이동에서 길별 통행료를 배운다. 늦게 본 것이 이긴다.
    static func learn(drives: [Drive], entries: [LedgerEntry], into rules: [String: Rule]) -> [String: Rule] {
        var result = rules
        // 앱이 자동으로 넣은 것(할인이 이미 든 금액)에서는 배우지 않는다.
        let own = { (entry: LedgerEntry) in autoNotes.contains { (entry.note ?? "").hasPrefix($0) } }
        for entry in entries.filter({ isToll($0) && !own($0) }).sorted(by: { $0.occurredAt < $1.occurredAt }) {
            guard let drive = drives.first(where: { covers($0, entry.occurredAt) }) else { continue }
            let key = pair(drive.from, drive.to)
            if let known = result[key], known.learnedAt > entry.occurredAt { continue }
            result[key] = Rule(amount: entry.amount, currency: entry.currency, title: entry.title, learnedAt: entry.occurredAt)
        }
        return result
    }

    /// 넣을 통행료. 같은 길이면 그대로, 되돌아오는 길이면 제목의 출근·퇴근을 바꾼다.
    static func entries(
        drives: [Drive], existing: [LedgerEntry], rules: [String: Rule], handled: Set<String>, now: Date,
        vehicle: LedgerTollDiscount.Vehicle = .standard, isOffDay: (Date) -> Bool = { _ in false },
        calendar: Calendar = .autoupdatingCurrent
    ) -> [(drive: Drive, entry: LedgerEntry, applied: LedgerTollDiscount.Applied, suspicious: Bool)] {
        var tolls = existing.filter(isToll).map(\.occurredAt)
        var result: [(drive: Drive, entry: LedgerEntry, applied: LedgerTollDiscount.Applied, suspicious: Bool)] = []
        func rate(_ date: Date) -> LedgerTollDiscount.Applied {
            LedgerTollDiscount.applied(at: date, vehicle: vehicle, isOffDay: isOffDay(date), calendar: calendar)
        }
        for drive in merged(drives) where !handled.contains(drive.key) && drive.end <= now.addingTimeInterval(-settle) {
            guard !tolls.contains(where: { covers(drive, $0) }) else { continue }
            let title: String
            let rule: Rule
            if let same = rules[pair(drive.from, drive.to)] {
                rule = same
                title = same.title
            } else if let back = rules[pair(drive.to, drive.from)] {
                rule = back
                title = reversed(back.title)
            } else { continue }
            // 배운 금액에서 정가를 되찾아, 이 이동 시각의 할인으로 다시 계산한다(TOL1112B01).
            let base = LedgerTollDiscount.base(from: rule.amount, rate: LedgerTollDiscount.applied(
                at: rule.learnedAt, vehicle: .standard, isOffDay: isOffDay(rule.learnedAt), calendar: calendar).rate)
            let middle = drive.start.addingTimeInterval(drive.end.timeIntervalSince(drive.start) / 2)
            let applied = rule.currency == "KRW" ? rate(middle) : LedgerTollDiscount.Applied(rate: 0, reason: .none)
            // 출발과 도착의 할인이 다르면 요금소를 언제 지났는지 몰라 확인을 받는다.
            let suspicious = rule.currency == "KRW" && rate(drive.start).rate != rate(drive.end).rate
            var entry = LedgerEntry(occurredAt: drive.end, amount: rule.currency == "KRW" ? LedgerTollDiscount.amount(base: base, rate: applied.rate) : rule.amount, title: title)
            entry.currency = rule.currency
            entry.category = .transport
            result.append((drive, entry, applied, suspicious))
            // 같은 길이 여러 조각으로 잡혀도 한 번만 넣는다(TOL1112A01).
            tolls.append(entry.occurredAt)
        }
        return result
    }

    /// 한 번의 이동이 여러 조각으로 잡히면 하나로 본다: 같은 출발·도착이고 겹치거나 30분 안에 이어지는 것.
    static func merged(_ drives: [Drive]) -> [Drive] {
        var result: [Drive] = []
        for drive in drives.sorted(by: { $0.start < $1.start }) {
            if let index = result.lastIndex(where: { $0.from == drive.from && $0.to == drive.to }),
               drive.start <= result[index].end.addingTimeInterval(before) {
                result[index].end = max(result[index].end, drive.end)
            } else {
                result.append(drive)
            }
        }
        return result
    }

    /// 자동으로 넣은 통행료를 그 시각의 할인으로 다시 계산한 것. 바꿀 것이 없거나 손으로 고친 금액이면 nil.
    /// 메모는 「자동 추가 · 출발 → 도착 · 할인」 꼴이고, 정가는 그 길(또는 반대 길)의 규칙에서 `base`로 구한다.
    static func adjusted(
        _ entry: LedgerEntry, rules: [String: Rule], base: (Rule) -> Double, applied: LedgerTollDiscount.Applied, label: String?
    ) -> LedgerEntry? {
        guard isToll(entry), entry.currency == "KRW", let note = entry.note, autoNotes.contains(where: { note.hasPrefix($0) }) else { return nil }
        let parts = note.components(separatedBy: " · ")
        guard parts.count >= 2 else { return nil }
        let ends = parts[1].components(separatedBy: " → ")
        guard ends.count == 2, let rule = rules[pair(ends[0], ends[1])] ?? rules[pair(ends[1], ends[0])], rule.currency == "KRW" else { return nil }
        let full = base(rule)
        // 앱이 넣을 수 있는 금액(배운 금액 그대로, 또는 정가에 할인·할증을 적용한 것)일 때만 고친다.
        let own = [rule.amount] + [0, 0.2, 0.3, 0.4, 0.5, -0.05].map { LedgerTollDiscount.amount(base: full, rate: $0) }
        guard own.contains(entry.amount) else { return nil }
        var fixed = entry
        fixed.amount = LedgerTollDiscount.amount(base: full, rate: applied.rate)
        fixed.note = (Array(parts.prefix(2)) + [label].compactMap { $0 }).joined(separator: " · ")
        guard fixed.amount != entry.amount || fixed.note != entry.note else { return nil }
        if fixed.amount != entry.amount { fixed.amountKRW = nil }
        return fixed
    }

    static let autoNotes = ["같은 길 통행료 자동 추가", "Same-route toll, added automatically"]

    /// 자동으로 넣은 통행료가 같은 이동에 여러 번 들어간 것(TOL1112A01 전의 버그). 가장 이른 하나만 남기고 지울 id.
    static func duplicates(in entries: [LedgerEntry]) -> [UUID] {
        let auto = entries.filter { entry in isToll(entry) && autoNotes.contains { (entry.note ?? "").hasPrefix($0) } }
            .sorted { $0.occurredAt < $1.occurredAt }
        var kept: [LedgerEntry] = []
        var extra: [UUID] = []
        for entry in auto {
            let same = kept.contains {
                $0.title == entry.title && $0.amount == entry.amount && $0.currency == entry.currency && $0.note == entry.note
                    && entry.occurredAt.timeIntervalSince($0.occurredAt) <= before + after
            }
            if same { extra.append(entry.id) } else { kept.append(entry) }
        }
        return extra
    }

    static func reversed(_ title: String) -> String {
        let marker = "\u{0}"
        return title
            .replacingOccurrences(of: "출근", with: marker)
            .replacingOccurrences(of: "퇴근", with: "출근")
            .replacingOccurrences(of: marker, with: "퇴근")
    }

    private static func covers(_ drive: Drive, _ date: Date) -> Bool {
        date >= drive.start.addingTimeInterval(-before) && date <= drive.end.addingTimeInterval(after)
    }
}

/// 손으로(또는 AI가) 넣은 통행료는 차종 할인 전 금액으로 보고, 그 시각의 출퇴근 할인만 든 것으로 본다. 차종을 고르면 거기에 맞춰 줄인다.
/// 고속도로 통행료 할인(TOL1112B01, 대표 지시 2026-11-12). 한국도로공사 구간·1종·하이패스 기준이고, 한 번에 가장 큰 할인 하나만 적용한다.
/// - 평일(공휴일 제외) 05~07시·20~22시 50%, 07~09시·18~20시 20%. 원래는 요금소 사이 20km 미만에만 주지만 앱은 그 거리를 몰라 시각만 본다.
/// - 경차 50%. 전기·수소차 2025년 40%, 2026년 30%, 2027년 20%, 그 뒤 없음(국토교통부 2024-11-15 발표).
/// - 주말·공휴일 07~21시 5% 할증(할인받는 차는 빼고).
enum LedgerTollDiscount {
    enum Vehicle: String, CaseIterable, Sendable { case standard, compact, electric }
    enum Reason: String, Equatable, Sendable { case none, commuteHalf, commuteFifth, compact, electric, weekend }
    struct Applied: Equatable, Sendable {
        /// 0.5는 50% 할인, -0.05는 5% 할증.
        var rate: Double
        var reason: Reason
    }

    static let vehicleKey = "ledgerTollVehicle"

    static func vehicle(_ defaults: UserDefaults = .standard) -> Vehicle {
        defaults.string(forKey: vehicleKey).flatMap(Vehicle.init) ?? .standard
    }

    static func vehicleRate(_ vehicle: Vehicle, year: Int) -> Double {
        switch vehicle {
        case .standard: 0
        case .compact: 0.5
        case .electric: year <= 2024 ? 0.5 : year == 2025 ? 0.4 : year == 2026 ? 0.3 : year == 2027 ? 0.2 : 0
        }
    }

    static func applied(at date: Date, vehicle: Vehicle, isOffDay: Bool, calendar: Calendar = .autoupdatingCurrent) -> Applied {
        let parts = calendar.dateComponents([.year, .hour], from: date)
        let hour = parts.hour ?? 12
        let own = vehicleRate(vehicle, year: parts.year ?? 2026)
        var best = own > 0 ? Applied(rate: own, reason: vehicle == .compact ? .compact : .electric) : Applied(rate: 0, reason: .none)
        if !isOffDay {
            let commute: Applied? = switch hour {
            case 5, 6, 20, 21: Applied(rate: 0.5, reason: .commuteHalf)
            case 7, 8, 18, 19: Applied(rate: 0.2, reason: .commuteFifth)
            default: nil
            }
            if let commute, commute.rate > best.rate { best = commute }
        } else if best.rate == 0, (7..<21).contains(hour) {
            best = Applied(rate: -0.05, reason: .weekend)
        }
        return best
    }

    /// 10원 단위로 맞춘다.
    static func amount(base: Double, rate: Double) -> Double { (base * (1 - rate) / 10).rounded() * 10 }
    static func base(from amount: Double, rate: Double) -> Double { rate >= 1 ? amount : (amount / (1 - rate) / 10).rounded() * 10 }

    static func label(_ applied: Applied, language: MapHomeLanguage) -> String? {
        switch applied.reason {
        case .none: nil
        case .commuteHalf: language.text("출퇴근 할인 50%", "Commute discount 50%")
        case .commuteFifth: language.text("출퇴근 할인 20%", "Commute discount 20%")
        case .compact: language.text("경차 할인 50%", "Compact car discount 50%")
        case .electric: language.text("전기·수소차 할인", "EV discount") + " \(Int((applied.rate * 100).rounded()))%"
        case .weekend: language.text("주말 할증 5%", "Weekend surcharge 5%")
        }
    }

    static func name(_ vehicle: Vehicle, language: MapHomeLanguage) -> String {
        switch vehicle {
        case .standard: language.text("일반", "Standard")
        case .compact: language.text("경차", "Compact")
        case .electric: language.text("전기·수소차", "EV · hydrogen")
        }
    }
}

/// 앱을 열 때·기록이 바뀐 뒤(5분에 한 번) 오늘과 어제의 자동차 이동을 본다.
@MainActor
enum LedgerTollRepeatRunner {
    static let rulesKey = "ledgerTollRules"
    static let handledKey = "ledgerTollHandledDrives"
    private static var lastRunAt = Date.distantPast
    private static var isRunning = false

    static func run(model: AppModel, defaults: UserDefaults = .standard, now: Date = .now, force: Bool = false) async {
        guard !isRunning, force || now.timeIntervalSince(lastRunAt) >= 5 * 60 else { return }
        isRunning = true
        lastRunAt = now
        defer { isRunning = false }
        let calendar = Calendar.autoupdatingCurrent
        var drives: [LedgerTollRepeat.Drive] = []
        for offset in 0..<2 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)),
                  let input = await model.assistantActivityInput(for: day, now: now, calendar: calendar),
                  let built = AssistantActivityBuilder.make(input, level: .visits) else { continue }
            drives += carDrives(built, language: input.language)
        }
        await LedgerBook.shared.load()
        // 가계부를 못 읽었으면 이미 있는 통행료를 알 수 없으니 넣지 않는다.
        guard LedgerBook.shared.isLoaded else { return }
        for id in LedgerTollRepeat.duplicates(in: LedgerBook.shared.entries) {
            await LedgerBook.shared.delete(id)
            TaptionPlanDiagnosticsLogger.shared.record("ledger_toll_repeat_duplicate_removed", fields: [:])
        }
        let entries = LedgerBook.shared.entries
        let stored = defaults.data(forKey: rulesKey).flatMap { try? JSONDecoder().decode([String: LedgerTollRepeat.Rule].self, from: $0) } ?? [:]
        let rules = LedgerTollRepeat.learn(drives: drives, entries: entries, into: stored)
        if rules != stored, let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: rulesKey) }
        let isOffDay = { (date: Date) in MapHomeCalendarDayStyle(date: date, calendar: calendar) != .weekday }
        var handled = defaults.stringArray(forKey: handledKey) ?? []
        let vehicle = LedgerTollDiscount.vehicle(defaults)
        let language = MapHomeLanguage.current
        // 이미 자동으로 넣은 통행료를 지금 차종·그 시각의 할인으로 맞춘다(최근 14일, 손으로 고친 금액은 두기).
        for entry in entries where now.timeIntervalSince(entry.occurredAt) <= 14 * 86_400 {
            let applied = LedgerTollDiscount.applied(at: entry.occurredAt, vehicle: vehicle, isOffDay: isOffDay(entry.occurredAt), calendar: calendar)
            let base = { (rule: LedgerTollRepeat.Rule) in
                LedgerTollDiscount.base(from: rule.amount, rate: LedgerTollDiscount.applied(
                    at: rule.learnedAt, vehicle: .standard, isOffDay: isOffDay(rule.learnedAt), calendar: calendar).rate)
            }
            guard let fixed = LedgerTollRepeat.adjusted(entry, rules: rules, base: base, applied: applied, label: LedgerTollDiscount.label(applied, language: language)) else { continue }
            await LedgerBook.shared.save(fixed)
        }
        guard !drives.isEmpty else { return }
        let additions = LedgerTollRepeat.entries(
            drives: drives, existing: entries, rules: rules, handled: Set(handled), now: now,
            vehicle: vehicle, isOffDay: isOffDay, calendar: calendar
        )
        for addition in additions {
            var entry = addition.entry
            entry.note = ([language.text("같은 길 통행료 자동 추가", "Same-route toll, added automatically"),
                           "\(addition.drive.from) → \(addition.drive.to)"]
                + [LedgerTollDiscount.label(addition.applied, language: language)].compactMap { $0 }).joined(separator: " · ")
            // 의심스러우면 넣지 않고 「확인 필요」에 올린다(대표 지시: 앱이 먼저 넣고, 의심스러우면 확인 요청).
            if addition.suspicious { LedgerReviewStore.shared.add(entry, reason: .toll, now: now) } else { await LedgerBook.shared.save(entry) }
            handled.append(addition.drive.key)
            TaptionPlanDiagnosticsLogger.shared.record("ledger_toll_repeat_added", fields: ["amount": String(Int(addition.entry.amount))])
        }
        if !additions.isEmpty { defaults.set(Array(handled.suffix(200)), forKey: handledKey) }
    }

    /// 출발·도착 이름을 아는 자동차 이동만. 이름 모르는 「머문 곳」은 길로 보지 않는다.
    static func carDrives(_ day: AssistantActivityDay, language: MapHomeLanguage) -> [LedgerTollRepeat.Drive] {
        let unnamed: Set<String> = [language.text("머문 곳", "Place"), "머문 곳", "Place"]
        return (day.moves ?? []).compactMap { move in
            guard move.mode == "car", let from = move.from, let to = move.to, from != to,
                  !unnamed.contains(from), !unnamed.contains(to),
                  let start = parser.date(from: move.start), let end = parser.date(from: move.end) else { return nil }
            return LedgerTollRepeat.Drive(from: from, to: to, start: start, end: end)
        }
    }

    private static var parser: DateFormatter { AssistantActivityBuilder.Stamp.instantParser }
}

/// 지도 화면에 붙는 보이지 않는 관찰자. 앱을 열 때·앞으로 올 때·기록이 바뀔 때 통행료를 본다.
struct LedgerTollRepeatObserver: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task { await runAll() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await runAll() } }
            }
            .onChange(of: model.rawDayRevisionSignal) { _, _ in Task { await runAll() } }
    }

    /// 통행료와 버스·지하철 요금(TRF1113A01)을 차례로 본다.
    private func runAll() async {
        await LedgerTollRepeatRunner.run(model: model)
        // 승하차 지점이 정류장인지 먼저 물어 두면 다음 분류 갱신에서 버스로 바뀌고, 그 뒤 요금이 들어간다(BST1113A01).
        await BusStopLookupRunner.run(model: model)
        RideLineTasks.enqueue(model.snapshot.travel)
        await LedgerTransitFareRunner.run(model: model)
    }
}
