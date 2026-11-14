import Foundation
import TaptionPlanCore

/// 「AI가 한 일」에 적는 전·후 요약 글(ABA1114A15). 반영할 때 한 번 만들어 기록에 남긴다.
@MainActor
enum AssistantChangeSummary {
    /// 합치기 전: 「걷기 3건 (14:10–14:40)」. 이름이 여럿이면 앞의 둘만 적는다.
    static func merged(_ records: [ActualRecord], language: MapHomeLanguage) -> String {
        let sorted = records.sorted { $0.startedAt < $1.startedAt }
        guard let first = sorted.first else { return "" }
        var titles: [String] = []
        for record in sorted where !titles.contains(record.title) { titles.append(record.title) }
        let names = titles.prefix(2).joined(separator: "·") + (titles.count > 2 ? "…" : "")
        let count = sorted.count
        let end = sorted.compactMap(\.endedAt).max().map(AssistantEditText.clock) ?? "…"
        let range = "\(AssistantEditText.clock(first.startedAt))–\(end)"
        return language.text("\(names) \(count)건 (\(range))", "\(names) ×\(count) (\(range))")
    }

    /// 합친 뒤: 「1건으로 합침 · 14:10–14:40 걷기」.
    static func mergedInto(_ record: String, language: MapHomeLanguage) -> String {
        language.text("1건으로 합침 · \(record)", "Merged into one · \(record)")
    }

    /// 이동 한 구간: 「14:10–14:40 버스」.
    static func move(_ span: TimeSpan, mode: String) -> String {
        "\(AssistantEditText.clock(span.start))–\(AssistantEditText.clock(span.end)) \(mode)"
    }

    /// 새로 넣은 지출: 「통행료 900원 · 11/14 · 교통」.
    static func expense(_ entry: LedgerEntry, language: MapHomeLanguage) -> String {
        [amount(entry, language), AssistantDataText.day(entry.occurredAt), entry.category.title(language)].joined(separator: " · ")
    }

    /// 고친 지출: 이름·금액에 더해 바뀐 칸(날짜·분류·장소·여행)만 양쪽에 붙인다.
    static func expensePair(before: LedgerEntry, after: LedgerEntry, language: MapHomeLanguage) -> (before: String, after: String) {
        var old = [amount(before, language)], new = [amount(after, language)]
        func add(_ left: String, _ right: String) {
            guard left != right else { return }
            old.append(left)
            new.append(right)
        }
        add(AssistantDataText.day(before.occurredAt), AssistantDataText.day(after.occurredAt))
        add(before.category.title(language), after.category.title(language))
        add(before.place ?? "–", after.place ?? "–")
        if before.tripID != after.tripID { add(scope(before, language), scope(after, language)) }
        return (old.joined(separator: " · "), new.joined(separator: " · "))
    }

    /// 고친 메모. 앞 80자가 같아 차이가 안 보이면 달라지는 곳 둘레를 보인다.
    static func memoPair(_ before: String, _ after: String, limit: Int = 80) -> (before: String, after: String) {
        let old = Array(before), new = Array(after)
        let common = zip(old, new).prefix { $0 == $1 }.count
        guard before != after, common > limit - 20 else { return (String(old.prefix(limit)), String(new.prefix(limit))) }
        let start = common - 20
        func cut(_ text: [Character]) -> String { "…" + String(text[start...].prefix(limit)) }
        return (cut(old), cut(new))
    }

    private static func amount(_ entry: LedgerEntry, _ language: MapHomeLanguage) -> String {
        "\(entry.title) \(LedgerMoney.text(entry.amount, currency: entry.currency, language: language))"
    }

    private static func scope(_ entry: LedgerEntry, _ language: MapHomeLanguage) -> String {
        entry.tripID == nil ? language.text("일상 지출", "Everyday spending") : language.text("여행 지출", "Trip spending")
    }
}

/// 하루치 「AI가 정리한 것」(ABA1114A15). 「AI가 한 일」 기록에서 그날 것만 골라 종류와 되돌리기 상태로 나눈다.
/// 새 저장소는 없다. 기록에 든 전·후 값의 날짜로 묶고, 날짜가 없는 일(설정 등)은 반영한 날로 묶는다.
enum AssistantDigest {
    enum Group: Int, CaseIterable, Sendable {
        case records, memos, schedules, ledger, settings, bubbles

        func title(_ language: MapHomeLanguage) -> String {
            switch self {
            case .records: language.text("기록", "Records")
            case .memos: language.text("메모", "Memos")
            case .schedules: language.text("일정", "Schedule")
            case .ledger: language.text("가계부", "Ledger")
            case .settings: language.text("설정", "Settings")
            case .bubbles: language.text("말풍선", "Bubbles")
            }
        }

        var symbol: String {
            switch self {
            case .records: "figure.walk"
            case .memos: "note.text"
            case .schedules: "calendar"
            case .ledger: "wonsign.circle"
            case .settings: "gearshape"
            case .bubbles: "bubble.left"
            }
        }
    }

    enum State: Equatable, Sendable { case undoable, undone, irreversible }

    struct Item: Identifiable, Equatable, Sendable {
        var entry: AssistantLogEntry
        var group: Group
        var state: State
        var id: UUID { entry.id }
    }

    struct Day: Equatable, Sendable {
        var items: [Item] = []

        var count: Int { items.count }
        func count(_ state: State) -> Int { items.filter { $0.state == state }.count }
        /// 종류별 건수. 많은 것부터, 같으면 정해 둔 순서.
        var groups: [(group: Group, count: Int)] {
            Group.allCases.map { group in (group, items.filter { $0.group == group }.count) }
                .filter { $0.1 > 0 }
                .sorted { ($1.1, $0.0.rawValue) < ($0.1, $1.0.rawValue) }
        }
    }

    /// 명령 결과 알림과 같은 나눔을 쓴다. 질문·승인 요청은 바꾼 것이 없어 뺀다.
    static func group(_ kind: AssistantActionKind) -> Group? {
        var counter = AssistantCommandOutcome()
        counter.count(kind)
        if counter.edits > 0 { return .records }
        if counter.memos > 0 { return .memos }
        if counter.schedules > 0 { return .schedules }
        if counter.ledger > 0 { return .ledger }
        if counter.bubbles > 0 { return .bubbles }
        return counter.questions > 0 ? nil : .settings
    }

    static func state(_ entry: AssistantLogEntry) -> State {
        if entry.undoneAt != nil { return .undone }
        return entry.irreversible == true ? .irreversible : .undoable
    }

    /// 바뀐 기록·이동·메모·지출·일정의 날짜. 여러 날에 걸친 루틴·여행·설정은 날짜가 없어 반영한 때를 쓴다.
    static func recordDate(_ entry: AssistantLogEntry) -> Date {
        let delta = entry.delta
        let dates: [Date]
        switch group(entry.kind) {
        case .records:
            dates = delta.actuals.compactMap { ($0.before ?? $0.after)?.startedAt }
                + (delta.movement?.before.segments.map(\.span.start) ?? [])
                + (delta.addedSleepSpans + delta.removedSleepSpans).map(\.start)
        case .memos:
            dates = delta.memos.compactMap { ($0.after ?? $0.before)?.occurredAt }
        case .ledger:
            dates = [(delta.ledgerEntry ?? delta.ledgerBefore)?.occurredAt].compactMap { $0 }
        case .schedules where [.addSchedule, .updateSchedule, .deleteSchedule].contains(entry.kind):
            dates = delta.plans.compactMap { ($0.after ?? $0.before)?.span.start }
        default:
            dates = []
        }
        return dates.min() ?? entry.appliedAt
    }

    /// 그날 반영된 것. 거절된 명령은 뺀다. 기록 순서(최근 것부터)를 지킨다.
    static func day(_ log: [AssistantLogEntry], on day: Date, calendar: Calendar = .autoupdatingCurrent) -> Day {
        Day(items: log.compactMap { entry in
            guard !entry.isRejected, let group = group(entry.kind), calendar.isDate(recordDate(entry), inSameDayAs: day) else { return nil }
            return Item(entry: entry, group: group, state: state(entry))
        })
    }

    static func headline(_ count: Int, language: MapHomeLanguage) -> String {
        language.text("AI가 정리한 \(count)건", "\(count) tidied by AI")
    }

    /// 「기록 2 · 가계부 1」.
    static func breakdown(_ day: Day, language: MapHomeLanguage) -> String {
        day.groups.map { "\($0.group.title(language)) \($0.count)" }.joined(separator: " · ")
    }

    /// 되돌리기 상태 한 줄. 0건인 것은 적지 않는다.
    static func undoLine(_ day: Day, language: MapHomeLanguage) -> String {
        let open = day.count(.undoable), undone = day.count(.undone), fixed = day.count(.irreversible)
        var parts: [String] = []
        if open > 0 { parts.append(language.text("되돌릴 수 있는 것 \(open)건", "\(open) can be undone")) }
        if undone > 0 { parts.append(language.text("되돌린 것 \(undone)건", "\(undone) undone")) }
        if fixed > 0 { parts.append(language.text("되돌릴 수 없는 것 \(fixed)건", "\(fixed) can't be undone")) }
        return parts.joined(separator: " · ")
    }
}
