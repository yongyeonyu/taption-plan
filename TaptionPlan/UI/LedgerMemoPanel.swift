import Observation
import SwiftUI

/// 할 일 목록 패널의 거르기(LED1111A03, TDP1113A01): 전체 · 확인 · 일정 · 메모 · 지출 · AI.
enum LedgerMemoFilter: String, CaseIterable, Identifiable {
    /// 맨 앞 「지출」: 지출 합계 한 줄만 보이는 접힌 모양(TDW1114A01). 예전 「전체」·「지출」 탭은 없앴다.
    case today, check, schedule, memos, inbox, ai
    var id: String { rawValue }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .today: language.text("지출", "Spending")
        case .check: language.text("확인", "Check")
        case .schedule: language.text("일정", "Events")
        case .memos: language.text("메모", "Memos")
        // 받은 결제 문자·알림(INB1114A01).
        case .inbox: language.text("내역", "Inbox")
        // AI에게 맡긴 일(AIQ1111A01).
        case .ai: "AI"
        }
    }
}

/// 가계부 화면을 어디서든 연다(메모 목록 머리, 「+ 메모」 길게 누르기). 화면은 지도 왼쪽 위 단추 뒤에 붙은 호스트가 띄운다.
@MainActor
@Observable
final class LedgerPresenter {
    static let shared = LedgerPresenter()
    var isPresented = false
}

struct LedgerSheetHost: View {
    let language: MapHomeLanguage
    var tripID: String?
    /// 앱 여행 계획에서 가져온 여행. 창을 열 때만 계산한다.
    var plannedTrips: () -> [LedgerTrip] = { [] }
    @Bindable private var presenter = LedgerPresenter.shared
    /// 열 때 한 번만 만든다. 지도 화면이 다시 그려질 때마다 만들어 넘기면 가계부도 매번 다시 그려졌다(LGP1113A01).
    @State private var trips: [LedgerTrip] = []

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: presenter.isPresented) { _, open in if open { trips = plannedTrips() } }
            .sheet(isPresented: $presenter.isPresented) { LedgerSheet(language: language, tripID: tripID, plannedTrips: trips) }
    }
}

/// 메모 목록 맨 위: 거르기와 이 달 지출·오늘 지출, 가계부 열기.
struct LedgerMemoHeader: View {
    @Binding var filter: LedgerMemoFilter
    /// 가계부에 이어진 메모 id. 값이 실제로 바뀔 때만 써서 지도 화면을 다시 그리게 한다.
    @Binding var linkedMemoIDs: Set<UUID>
    let language: MapHomeLanguage
    let day: Date
    private var book: LedgerBook { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $filter) {
                ForEach(LedgerMemoFilter.allCases) { Text($0.title(language)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Button { LedgerPresenter.shared.isPresented = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wonsign.circle.fill").foregroundStyle(Color.tpAccent)
                    Text(summary).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(Color.tpSecondary)
                }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                .foregroundStyle(Color.tpInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .mapHomeGlass(in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("memo-ledger-open")
            // 조용히 넣지 않은 결제는 「확인」 위에 띠로 모아 보인다(LRV1111A01, TDW1114A01).
            if filter == .check { LedgerReviewBand(language: language) }
        }
        .task {
            await book.load()
            publishLinkedIDs()
        }
        .onChange(of: book.entries) { _, _ in publishLinkedIDs() }
    }

    private func publishLinkedIDs() {
        let ids = Set(book.entries.compactMap(\.memoID))
        if ids != linkedMemoIDs { linkedMemoIDs = ids }
    }

    private var summary: String {
        let today = LedgerBook.total(book.entries(on: day), .expense)
        let month = LedgerBook.total(book.entries(inMonth: LedgerBook.monthKey(day)), .expense)
        let dayLabel = Self.periodLabels(day: day, now: .now, language: language)
        return "\(dayLabel.day) \(LedgerMoney.text(today, language: language)) · \(dayLabel.month) \(LedgerMoney.text(month, language: language))"
    }

    /// 오늘이면 「오늘 · 이번 달」, 다른 날이면 그 날짜와 그 달(대표 지시 2026-11-11, LDT1111A01).
    static func periodLabels(day: Date, now: Date, language: MapHomeLanguage, calendar: Calendar = .autoupdatingCurrent) -> (day: String, month: String) {
        let sameMonth = calendar.isDate(day, equalTo: now, toGranularity: .month)
        let dayText = calendar.isDate(day, inSameDayAs: now)
            ? language.text("오늘", "Today")
            : day.formatted(.dateTime.month(.abbreviated).day().locale(language.locale))
        let monthText = sameMonth
            ? language.text("이번 달", "This month")
            : day.formatted(.dateTime.month(.wide).locale(language.locale))
        return (dayText, monthText)
    }
}

/// 「지출」로 거르면 그날 가계부 기록을 메모 카드처럼 보인다. 누르면 가계부가 열린다.
/// 「전체」에서는 메모로 넣지 않은 지출(직접·AI·결제 문자·영수증)만 메모 아래에 붙인다(LDT1111A01).
struct LedgerDayCards: View {
    let language: MapHomeLanguage
    let day: Date
    var onlyUnlinked = false
    private var book: LedgerBook { .shared }

    var body: some View {
        let entries = book.entries(on: day)
            .filter { !onlyUnlinked || $0.memoID == nil }
            .sorted { $0.occurredAt < $1.occurredAt }
        if entries.isEmpty, !onlyUnlinked {
            Text(language.text("그날 지출이 없어요. 메모에 「커피 4500」처럼 쓰면 들어가요.", "No spending that day. Write a memo like \"Coffee 4500\" to add one."))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .regular))
                .foregroundStyle(Color.tpSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .mapHomeGlass(in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
        }
        ForEach(entries) { entry in
            Button { LedgerPresenter.shared.isPresented = true } label: { LedgerMemoCard(entry: entry, language: language) }
                .buttonStyle(.plain)
        }
    }
}

/// 메모 카드와 같은 모양의 가계부 기록 한 줄: 동그란 아이콘, 13pt 제목, 11pt 금액·시각.
struct LedgerMemoCard: View {
    let entry: LedgerEntry
    let language: MapHomeLanguage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let toll = LedgerToll.kind(for: entry) {
                LedgerTollIcon(toll: toll, size: 24).frame(width: 26, height: 26)
            } else {
                Image(systemName: entry.category.symbol)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    .foregroundStyle(Color.tpAccent)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.9), in: Circle())
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(2)
                // 취소된 결제는 줄을 긋고 합계에서 뺀다(LCN1111A01).
                Text((entry.kind == .expense ? "−" : "+") + LedgerMoney.text(entry.amount, currency: entry.currency, language: language)
                     + (entry.canceledAt == nil ? "" : " · " + language.text("취소됨", "Canceled")))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                    .strikethrough(entry.canceledAt != nil)
                    .foregroundStyle(entry.canceledAt != nil ? Color.tpSecondary : entry.kind == .expense ? Color.tpAccent : Color.green)
                Text("\(entry.occurredAt.formatted(date: .omitted, time: .shortened)) · \(entry.category.title(language))")
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .regular))
                    .foregroundStyle(Color.tpSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .mapHomeGlass(in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
        .contentShape(Rectangle())
    }
}

extension MapHomeView {
    /// 「메모」로 거르면 가계부에 이어진 메모는 뺀다. 이어진 메모 id는 머리 줄이 바뀔 때만 넘겨 준다
    /// (지도 화면이 장부를 직접 지켜보면 장부가 바뀔 때마다 지도 전체가 다시 그려진다, 리뷰).
    var panelMemos: [ActionMemo] {
        memoLedgerFilter == .memos ? queuedMemos.filter { !memoLedgerLinkedIDs.contains($0.id) } : queuedMemos
    }
}

/// 가계부에 이어진 메모 카드의 금액. 장부를 이 작은 뷰만 지켜본다.
struct LedgerMemoBadge: View {
    let memoID: UUID
    let language: MapHomeLanguage

    var body: some View {
        if let entry = LedgerBook.shared.entry(forMemo: memoID) {
            Text((entry.kind == .expense ? "−" : "+") + LedgerMoney.text(entry.amount, currency: entry.currency, language: language))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                .foregroundStyle(Color.tpAccent)
        }
    }
}

/// 하루 지출 카운터(SPD1111A01, 대표 지시 2026-11-11). 그날 가계부 지출을 재생·핸들 시각까지 더한다.
@MainActor
enum LedgerDaySpending {
    static func entries(day: Date, cutoff: Date, calendar: Calendar = MapHomeGrowthPolicy.localCalendar, book: LedgerBook = .shared) -> [LedgerEntry] {
        if !book.isLoaded { Task { await book.load() } }
        // 실제로 쓴 돈만: 일상↔여행 짝 기록(예산 이체·정산)은 뺀다(LED1111A05).
        return book.entries(on: day, calendar: calendar).filter { $0.kind == .expense && $0.transfer == nil && $0.occurredAt <= cutoff }
    }

    /// 그날 수입: 일상 수입만(여행 이체·친구에게 받은 여행 경비는 뺀다).
    static func income(day: Date, calendar: Calendar = MapHomeGrowthPolicy.localCalendar, book: LedgerBook = .shared) -> Double {
        LedgerBook.total(book.entries(on: day, calendar: calendar).filter { $0.kind == .income && $0.transfer == nil && book.isDaily($0) }, .income)
    }

    /// 달력용 한 달 날짜별 수입·지출(원). 지출은 실제로 쓴 돈(이체 제외, 여행 중 지출 포함).
    static func monthTotals(month: Date, calendar: Calendar = MapHomeGrowthPolicy.localCalendar, book: LedgerBook = .shared) -> [Date: (income: Double, expense: Double)] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [:] }
        var result: [Date: (income: Double, expense: Double)] = [:]
        for entry in book.entries where entry.transfer == nil && entry.occurredAt >= interval.start && entry.occurredAt < interval.end {
            let day = calendar.startOfDay(for: entry.occurredAt)
            var value = result[day] ?? (0, 0)
            if entry.kind == .expense { value.expense += entry.countedKRW } else if book.isDaily(entry) { value.income += entry.countedKRW }
            result[day] = value
        }
        return result
    }

    static func total(day: Date, cutoff: Date, calendar: Calendar = MapHomeGrowthPolicy.localCalendar, book: LedgerBook = .shared) -> Double {
        LedgerBook.total(entries(day: day, cutoff: cutoff, calendar: calendar, book: book), .expense)
    }

    /// 카운터를 누르면 뜨는 상세: 그날 지출을 시각순으로, 분류별 합계와 함께.
    static func detail(day: Date, cutoff: Date, total: String, language: MapHomeLanguage) -> MapHomeCounterDetailContent {
        let list = entries(day: day, cutoff: cutoff).sorted { $0.occurredAt < $1.occurredAt }
        let sum = max(1, LedgerBook.total(list, .expense))
        let rows = list.enumerated().map { index, entry in
            MapHomeCounterDetailContent.Row(
                id: index, title: entry.title,
                subtitle: "\(MapHomeCounterDetailBuilder.timeText(entry.occurredAt)) · \(entry.category.title(language))",
                value: LedgerMoney.text(entry.amount, currency: entry.currency, language: language)
            )
        }
        let byCategory = Dictionary(grouping: list, by: \.category).map { ($0.key, LedgerBook.total($0.value, .expense)) }.sorted { $0.1 > $1.1 }
        let categoryRows = byCategory.enumerated().map { index, item in
            MapHomeCounterDetailContent.Row(
                id: index, title: item.0.title(language), subtitle: nil,
                value: LedgerMoney.text(item.1, language: language), share: item.1 / sum
            )
        }
        var hourly = Array(repeating: 0.0, count: 24)
        for entry in list { hourly[min(23, max(0, MapHomeGrowthPolicy.localCalendar.component(.hour, from: entry.occurredAt)))] += entry.countedKRW }
        return MapHomeCounterDetailContent(
            systemImage: MapHomeCounterKind.spending.systemImage,
            title: language.text("하루 지출", "Daily spending"),
            value: total,
            sections: list.isEmpty ? [] : [
                .init(id: 0, title: language.text("분류별", "By category"), rows: categoryRows),
                .init(id: 1, title: language.text("시간순", "By time"), rows: rows),
            ],
            note: list.isEmpty ? language.text("그날 지출이 없어요. 메모에 「커피 4500」처럼 쓰면 들어가요.", "No spending that day. Write a memo like \"Coffee 4500\" to add one.") : nil,
            caption: language.text("\(list.count)건", "\(list.count) entries"),
            hourly: list.isEmpty ? [] : hourly
        )
    }
}

/// 할 일 목록 패널의 한 줄(TDP1113A01). 「전체」는 메모·일정·앱 계획·지출을 한 줄로 섞는다.
enum MapHomeTodoPanelRow: Identifiable, Equatable {
    case memo(ActionMemo)
    case event(CalendarRecord)
    case plan(PlanRecord)
    case expense(LedgerEntry)

    var id: String {
        switch self {
        case .memo(let memo): "memo-\(memo.id.uuidString)"
        case .event(let event): "event-\(event.id)"
        case .plan(let plan): "plan-\(plan.id.uuidString)"
        case .expense(let entry): "expense-\(entry.id.uuidString)"
        }
    }

    /// 시각이 없는 것(시각 없는 메모·종일 일정)은 맨 위에 둔다.
    var isUntimed: Bool {
        switch self {
        case .memo(let memo): memo.isTimeless == true
        case .event(let event): event.isAllDay
        case .plan, .expense: false
        }
    }

    var date: Date {
        switch self {
        case .memo(let memo): memo.isTimeless == true ? memo.createdAt : memo.occurredAt
        case .event(let event): event.span.start
        case .plan(let plan): plan.span.start
        case .expense(let entry): entry.occurredAt
        }
    }

    /// 시각 없는 것이 위, 그다음 시각 순. 같은 시각은 들어온 순서를 지킨다.
    static func ordered(_ rows: [MapHomeTodoPanelRow]) -> [MapHomeTodoPanelRow] {
        rows.enumerated().sorted { lhs, rhs in
            if lhs.element.isUntimed != rhs.element.isUntimed { return lhs.element.isUntimed }
            if lhs.element.date != rhs.element.date { return lhs.element.date < rhs.element.date }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// 「일정」에 보일 앱 계획. 달력에서 가져온 계획은 달력 일정과 겹치므로 뺀다.
    static func plans(_ plans: [PlanRecord], on day: Date, calendar: Calendar = .autoupdatingCurrent) -> [PlanRecord] {
        plans
            .filter { $0.externalEventID == nil && calendar.isDate($0.span.start, inSameDayAs: day) }
            .sorted { $0.span.start < $1.span.start }
    }
}

/// 앱 계획·달력 일정 한 줄. 메모 카드와 같은 모양이다.
struct MapHomeTodoScheduleCard: View {
    let systemImage: String
    let title: String
    let time: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                .foregroundStyle(Color.tpReferenceBlue)
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.9), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(2)
                Text(time)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .regular))
                    .foregroundStyle(Color.tpSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .mapHomeGlass(in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    static func time(_ span: TimeSpan, allDay: Bool, language: MapHomeLanguage) -> String {
        if allDay { return language.text("종일", "All day") }
        return "\(span.start.formatted(date: .omitted, time: .shortened)) – \(span.end.formatted(date: .omitted, time: .shortened))"
    }
}
