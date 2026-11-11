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
        for entry in entries.filter(isToll).sorted(by: { $0.occurredAt < $1.occurredAt }) {
            guard let drive = drives.first(where: { covers($0, entry.occurredAt) }) else { continue }
            let key = pair(drive.from, drive.to)
            if let known = result[key], known.learnedAt > entry.occurredAt { continue }
            result[key] = Rule(amount: entry.amount, currency: entry.currency, title: entry.title, learnedAt: entry.occurredAt)
        }
        return result
    }

    /// 넣을 통행료. 같은 길이면 그대로, 되돌아오는 길이면 제목의 출근·퇴근을 바꾼다.
    static func entries(drives: [Drive], existing: [LedgerEntry], rules: [String: Rule], handled: Set<String>, now: Date)
        -> [(drive: Drive, entry: LedgerEntry)] {
        let tolls = existing.filter(isToll).map(\.occurredAt)
        var result: [(drive: Drive, entry: LedgerEntry)] = []
        for drive in drives where !handled.contains(drive.key) && drive.end <= now.addingTimeInterval(-settle) {
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
            var entry = LedgerEntry(occurredAt: drive.end, amount: rule.amount, title: title)
            entry.currency = rule.currency
            entry.category = .transport
            result.append((drive, entry))
        }
        return result
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

/// 앱을 열 때·기록이 바뀐 뒤(5분에 한 번) 오늘과 어제의 자동차 이동을 본다.
@MainActor
enum LedgerTollRepeatRunner {
    static let rulesKey = "ledgerTollRules"
    static let handledKey = "ledgerTollHandledDrives"
    private static var lastRunAt = Date.distantPast
    private static var isRunning = false

    static func run(model: AppModel, defaults: UserDefaults = .standard, now: Date = .now) async {
        guard !isRunning, now.timeIntervalSince(lastRunAt) >= 5 * 60 else { return }
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
        guard !drives.isEmpty else { return }
        await LedgerBook.shared.load()
        let entries = LedgerBook.shared.entries
        let stored = defaults.data(forKey: rulesKey).flatMap { try? JSONDecoder().decode([String: LedgerTollRepeat.Rule].self, from: $0) } ?? [:]
        let rules = LedgerTollRepeat.learn(drives: drives, entries: entries, into: stored)
        if rules != stored, let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: rulesKey) }
        var handled = defaults.stringArray(forKey: handledKey) ?? []
        let additions = LedgerTollRepeat.entries(drives: drives, existing: entries, rules: rules, handled: Set(handled), now: now)
        let language = MapHomeLanguage.current
        for addition in additions {
            var entry = addition.entry
            entry.note = language.text("같은 길 통행료 자동 추가", "Same-route toll, added automatically")
                + " · \(addition.drive.from) → \(addition.drive.to)"
            await LedgerBook.shared.save(entry)
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

    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mmxxx"
        return formatter
    }()
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
            .task { await LedgerTollRepeatRunner.run(model: model) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await LedgerTollRepeatRunner.run(model: model) } }
            }
            .onChange(of: model.rawDayRevisionSignal) { _, _ in Task { await LedgerTollRepeatRunner.run(model: model) } }
    }
}
