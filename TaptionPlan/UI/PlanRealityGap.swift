import Foundation
import TaptionPlanCore
import TaptionPlanStore

/// 계획과 실제의 차이(PVR1114A13). 화면·지도·AI 요약이 같은 값을 쓴다. 순수 계산만 둔다.
enum PlanRealityGap {
    /// 차이를 보이고 판정하는 기준.
    struct Thresholds: Equatable, Sendable {
        /// 시각·길이 차이가 이보다 작으면 뱃지를 달지 않는다.
        var timeBadge: TimeInterval = 5 * 60
        /// 지금 이만큼 밀렸으면 지연이다.
        var delay: TimeInterval = 15 * 60
        /// 비용 차이가 이보다 작으면 뱃지를 달지 않는다(원).
        var costBadgeKRW: Double = 1_000
        /// 예산 초과: 지금까지의 계획 지출보다 이 금액과 이 비율 가운데 큰 쪽 이상 더 썼을 때.
        var overBudgetKRW: Double = 5_000
        var overBudgetRatio = 0.1
        /// 여행 일정의 곳에서 이 거리 안에 머문 기록을 그 일정의 실제로 본다(m).
        var stopRadiusMeters = 200.0

        static let standard = Thresholds()
    }

    /// 실제를 어디서 찾았나: 일정에 이어진 기록, 그 곳에 머문 기록, 없음.
    enum Match: String, Sendable { case linked, place, none }

    struct Item: Identifiable, Equatable, Sendable {
        var id: String
        var title: String
        var plan: TimeSpan
        var actual: TimeSpan?
        var match: Match = .none
        /// 아직 끝나지 않은 기록. 끝 시각·길이 차이를 내지 않는다.
        var isOngoing = false
        var plannedKRW: Double?
        var spentKRW: Double?

        var startDelta: TimeInterval? { actual.map { $0.start.timeIntervalSince(plan.start) } }
        var endDelta: TimeInterval? { isOngoing ? nil : actual.map { $0.end.timeIntervalSince(plan.end) } }
        var durationDelta: TimeInterval? { isOngoing ? nil : actual.map { $0.duration - plan.duration } }
        /// 쓴 돈 − 계획 지출. 둘 다 있을 때만.
        var costDelta: Double? {
            guard let plannedKRW, let spentKRW else { return nil }
            return spentKRW - plannedKRW
        }

        /// 뱃지로 보일 시간 차이: 시작이 어긋났으면 시작, 아니면 길이.
        func timeBadge(_ thresholds: Thresholds = .standard) -> TimeInterval? {
            if let startDelta, abs(startDelta) >= thresholds.timeBadge { return startDelta }
            if let durationDelta, abs(durationDelta) >= thresholds.timeBadge { return durationDelta }
            return nil
        }

        func costBadge(_ thresholds: Thresholds = .standard) -> Double? {
            costDelta.flatMap { abs($0) >= thresholds.costBadgeKRW ? $0 : nil }
        }
    }

    struct Day: Equatable, Sendable {
        var items: [Item] = []
        /// 그날 일정들의 계획 지출 합과, 지금까지 시작한 일정만의 합.
        var plannedKRW = 0.0
        var plannedSoFarKRW = 0.0
        /// 그날 일정 시간 안에 쓴 돈.
        var spentKRW = 0.0
        /// 지금 밀린 시간. 근거(기록)가 있을 때만 0보다 크다.
        var delay: TimeInterval = 0
        var isDelayed = false
        var isOverBudget = false
        /// 아직 끝나지 않은 일정 수.
        var remaining = 0

        var overKRW: Double { spentKRW - plannedSoFarKRW }
        /// 남은 일정이 있고 밀렸거나 예산을 넘겼으면 다시 짤 만하다.
        var needsReplan: Bool { remaining > 0 && (isDelayed || isOverBudget) }

        /// 막대를 그릴 시간 범위(계획과 실제를 모두 덮는다).
        var range: TimeSpan? {
            let spans = items.flatMap { [$0.plan] + ($0.actual.map { [$0] } ?? []) }
            guard let start = spans.map(\.start).min(), let end = spans.map(\.end).max(), end > start else { return nil }
            return TimeSpan(start: start, end: end)
        }
    }

    struct Input {
        var plans: [PlanRecord] = []
        var actuals: [ActualRecord] = []
        var places: [PlaceStay] = []
        var stops: [TravelPlanStop] = []
        var tripItems: [TravelTripItem] = []
        var entries: [LedgerEntry] = []
        var day: TimeSpan
        var now: Date
    }

    static func day(_ input: Input, thresholds: Thresholds = .standard) -> Day {
        let rows = rows(input)
        guard !rows.isEmpty else { return Day() }
        let spent = spending(input)
        var day = Day()
        day.items = rows.map { row in
            var item = Item(id: row.id, title: row.title, plan: row.span)
            if let found = linked(row, input) ?? stayed(row, input, radius: thresholds.stopRadiusMeters) {
                item.actual = found.span
                item.match = found.match
                item.isOngoing = found.isOngoing
            }
            if let tripItem = row.item {
                let family = [tripItem] + TravelTripItem.details(of: tripItem.itemID, tripID: tripItem.tripID, in: input.tripItems)
                let planned = family.reduce(0) { $0 + ($1.plannedSpendKRW ?? 0) }
                let used = family.reduce(0) { $0 + (spent["\($1.tripID)/\($1.itemID)"] ?? 0) }
                item.plannedKRW = planned > 0 ? planned : nil
                // 아직 끝나지 않았고 쓴 돈도 없으면 차이를 내지 않는다.
                item.spentKRW = used > 0 || row.span.end <= input.now ? used : nil
            }
            return item
        }
        day.plannedKRW = day.items.reduce(0) { $0 + ($1.plannedKRW ?? 0) }
        day.plannedSoFarKRW = day.items.reduce(0) { $0 + ($1.plan.start <= input.now ? $1.plannedKRW ?? 0 : 0) }
        day.spentKRW = day.items.reduce(0) { $0 + ($1.spentKRW ?? 0) }
        day.isOverBudget = day.plannedKRW > 0
            && day.overKRW >= max(thresholds.overBudgetKRW, day.plannedSoFarKRW * thresholds.overBudgetRatio)
        let isToday = input.day.contains(input.now)
        day.remaining = isToday ? day.items.filter { $0.plan.end > input.now && ($0.actual == nil || $0.isOngoing) }.count : 0
        day.delay = isToday ? delay(day.items, now: input.now) : 0
        day.isDelayed = day.delay >= thresholds.delay
        return day
    }

    /// 지금 밀린 시간: 기록이 있는 일정 가운데 계획상 가장 늦은 것에서 읽는다.
    /// 진행 중이면 늦게 시작한 만큼(계획 끝을 넘겼으면 넘긴 만큼), 끝났으면 늦게 끝난 만큼이다.
    static func delay(_ items: [Item], now: Date) -> TimeInterval {
        guard let last = items.filter({ $0.actual != nil && $0.plan.start <= now }).max(by: { $0.plan.start < $1.plan.start }) else { return 0 }
        if last.isOngoing {
            return max(0, last.startDelta ?? 0, now.timeIntervalSince(last.plan.end))
        }
        return max(0, last.endDelta ?? 0)
    }

    // MARK: 일정 줄

    private struct Row {
        var id: String
        var title: String
        var span: TimeSpan
        var plan: PlanRecord?
        var item: TravelTripItem?
    }

    /// 그날의 일정 줄: 계획(루틴·건너뜀·하위 일정을 묶는 상위 계획 제외)과, 계획에 이어지지 않은 여행 일정(굵은 곳만).
    private static func rows(_ input: Input) -> [Row] {
        let dayPlans = input.plans.filter {
            $0.status != .skipped && $0.span.duration > 0 && $0.span.intersection(with: input.day) != nil && !GoalRecordPolicy.isGoal($0)
        }
        let parents = Set(dayPlans.compactMap(\.parentID))
        let itemByPlan = Dictionary(input.tripItems.compactMap { item in item.planID.map { ($0, item) } }, uniquingKeysWith: { first, _ in first })
        var rows = dayPlans.filter { !parents.contains($0.id) && itemByPlan[$0.id]?.parentItemID == nil }.map {
            Row(id: "plan:\($0.id.uuidString)", title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines), span: $0.span, plan: $0, item: itemByPlan[$0.id])
        }
        let planned = Set(dayPlans.map(\.id))
        rows += input.tripItems.filter { item in
            item.parentItemID == nil && item.end > item.start && !(item.planID.map(planned.contains) ?? false)
                && TimeSpan(start: item.start, end: item.end).intersection(with: input.day) != nil
        }.map { Row(id: "item:\($0.tripID)/\($0.itemID)", title: $0.title, span: TimeSpan(start: $0.start, end: $0.end), item: $0) }
        return rows.sorted { ($0.span.start, $0.id) < ($1.span.start, $1.id) }
    }

    // MARK: 실제 찾기

    private struct Found {
        var span: TimeSpan
        var match: Match
        var isOngoing: Bool
    }

    /// 그 일정에 이어진 기록들의 처음부터 끝까지.
    private static func linked(_ row: Row, _ input: Input) -> Found? {
        guard let id = row.plan?.id else { return nil }
        let mine = input.actuals.filter { ($0.planID == id || $0.routineID == id) && $0.startedAt < input.now }
        let spans = mine.map { $0.span(asOf: input.now) }.filter { $0.intersection(with: input.day) != nil || $0.duration == 0 && input.day.contains($0.start) }
        guard let start = spans.map(\.start).min(), let end = spans.map(\.end).max() else { return nil }
        return Found(span: TimeSpan(start: start, end: end), match: .linked, isOngoing: mine.contains { $0.endedAt == nil })
    }

    /// 여행 일정의 곳 가까이에 머문 기록 가운데 계획 시각에 가장 가까운 것.
    private static func stayed(_ row: Row, _ input: Input, radius: Double) -> Found? {
        let stop = input.stops.first { stop in
            (row.plan != nil && stop.planID == row.plan?.id)
                || (row.item != nil && stop.tripID == row.item?.tripID && stop.itemID == row.item?.itemID)
        }
        guard let stop else { return nil }
        let near = input.places.filter { stay in
            guard let point = stay.point, stay.span.start < input.now, stay.span.intersection(with: input.day) != nil else { return false }
            return meters(point.latitude, point.longitude, stop.latitude, stop.longitude) <= radius
        }
        guard let stay = near.min(by: { abs($0.span.start.timeIntervalSince(row.span.start)) < abs($1.span.start.timeIntervalSince(row.span.start)) }) else { return nil }
        let end = min(stay.span.end, input.now)
        // 머문 기록은 끝 시각이 늘 있다. 방금까지 이어졌으면 아직 머무는 중으로 본다.
        return Found(span: TimeSpan(start: stay.span.start, end: end), match: .place, isOngoing: input.now.timeIntervalSince(stay.span.end) < 5 * 60)
    }

    static func meters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radians = Double.pi / 180
        let dLat = (lat2 - lat1) * radians, dLon = (lon2 - lon1) * radians
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * radians) * cos(lat2 * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 6_371_000 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// 여행 일정별 쓴 돈(`여행 번호/일정 번호`). 나누는 규칙은 계획표와 같다(`TravelPlanSpend.byItem`).
    private static func spending(_ input: Input) -> [String: Double] {
        var result: [String: Double] = [:]
        for tripID in Set(input.tripItems.map(\.tripID)) {
            for (itemID, amount) in TravelPlanSpend.byItem(items: input.tripItems, tripID: tripID, entries: input.entries) {
                result["\(tripID)/\(itemID)"] = amount
            }
        }
        return result
    }
}

/// 차이를 글로: 뱃지와 AI에게 보낼 요약.
@MainActor
enum PlanRealityText {
    /// 「+25분」「-1시간 5분」.
    static func time(_ delta: TimeInterval, _ language: MapHomeLanguage) -> String {
        let minutes = Int((abs(delta) / 60).rounded())
        let hours = minutes / 60, rest = minutes % 60
        let amount = minutes < 60 ? language.text("\(minutes)분", "\(minutes) min") : language.text("\(hours)시간 \(rest)분", "\(hours) h \(rest) min")
        return (delta < 0 ? "-" : "+") + amount
    }

    /// 「+5,000원」「-5,000원」.
    static func money(_ delta: Double, _ language: MapHomeLanguage) -> String {
        (delta < 0 ? "-" : "+") + LedgerMoney.text(abs(delta), language: language)
    }

    static func clock(_ span: TimeSpan, calendar: Calendar = .autoupdatingCurrent) -> String {
        func text(_ date: Date) -> String {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
        return "\(text(span.start))–\(text(span.end))"
    }

    /// AI에게 보낼 차이 요약. 좌표·계좌·가게 이름은 싣지 않는다. 일정 제목은 공유 수준이 「머문 곳 이름과 시각」일 때만 싣는다.
    /// 공유를 껐으면 nil.
    static func summary(_ day: PlanRealityGap.Day, level: AssistantShareLevel, language: MapHomeLanguage, now: Date,
                        thresholds: PlanRealityGap.Thresholds = .standard, calendar: Calendar = .autoupdatingCurrent) -> String? {
        guard level != .off, day.needsReplan else { return nil }
        var head: [String] = []
        let late = time(day.delay, language), over = money(day.overKRW, language), remaining = day.remaining
        if day.isDelayed { head.append(language.text("지연 \(late)", "Late \(late)")) }
        if day.isOverBudget { head.append(language.text("예산 \(over)", "Budget \(over)")) }
        head.append(language.text("남은 일정 \(remaining)개", "\(remaining) left"))
        var lines = [head.joined(separator: " · ")]
        for (index, item) in day.items.enumerated() {
            let name = level == .visits ? item.title : "#\(index + 1)"
            var line = "\(clock(item.plan, calendar: calendar)) \(name)"
            if let actual = item.actual {
                var deltas = [item.timeBadge(thresholds).map { time($0, language) }, item.costBadge(thresholds).map { money($0, language) }].compactMap { $0 }
                if item.isOngoing { deltas.insert(language.text("진행 중", "ongoing"), at: 0) }
                line += " → \(clock(actual, calendar: calendar))" + (deltas.isEmpty ? "" : " (\(deltas.joined(separator: ", ")))")
            } else if item.plan.end > now {
                line += " · " + language.text("남음", "left")
            }
            lines.append(line)
        }
        return String(lines.joined(separator: "\n").prefix(1_900))
    }

    /// AI 일의 `context`: 숫자만 싣는다.
    static func context(_ day: PlanRealityGap.Day, level: AssistantShareLevel, now: Date, calendar: Calendar = .autoupdatingCurrent) -> [String: String] {
        var context = ["remaining": String(day.remaining), "from": String(clock(TimeSpan(start: now, end: now), calendar: calendar).prefix(5)), "level": level.rawValue]
        if day.isDelayed { context["delayMinutes"] = String(Int((day.delay / 60).rounded())) }
        if day.isOverBudget { context["overKRW"] = String(Int(day.overKRW.rounded())) }
        return context
    }

    /// 같은 차이를 두 번 보내지 않게 하는 표식: 날짜와, 15분·5,000원 단위로 뭉친 차이.
    static func signature(_ day: PlanRealityGap.Day, dayStart: Date) -> String {
        "\(Int(dayStart.timeIntervalSince1970))|\(Int(day.delay / 900))|\(Int(max(0, day.overKRW) / 5_000))|\(day.remaining)"
    }
}
