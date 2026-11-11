import Foundation
import TaptionPlanCore

/// 하루 기록에 더하는 루틴·여행·수면 칸(AIR1110A03). 공유 수준이 「보내지 않음」이면 하루 기록째 보내지 않는다.
/// 좌표·주소는 넣지 않는다.
extension AssistantActivityDay {
    /// 그날에 걸친 루틴. `id`로 `updateGoal`·`deleteGoal`을 고른다. 날짜는 끝 날짜를 포함한다.
    struct Goal: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var start: String
        var end: String
    }

    struct Trip: Codable, Equatable, Sendable {
        struct Item: Codable, Equatable, Sendable {
            var stopId: String?
            var itemId: String?
            var title: String
            var order: Int?
            var start: String?
            var end: String?
            var status: String
        }

        /// 직접 만든 여행 일정은 null.
        var tripId: String?
        var items: [Item]
    }

    /// 수면 기록. `recordId`로 `updateSleep`을 고른다.
    struct Sleep: Codable, Equatable, Sendable {
        var recordId: String
        var start: String
        var end: String
        var minutes: Int
        var source: String
    }

    /// 가계부 기록(LED1110A01). 금액과 통화, 원화 환산. 장소·낸 사람·메모는 보내지 않는다.
    struct Expense: Codable, Equatable, Sendable {
        var id: String
        var time: String
        var title: String
        var category: String
        var kind: String
        var amount: Double
        var currency: String
        var amountKRW: Double?
    }

    /// 이 달 예산과 지금까지 쓴 돈(PLN1111A01 제안 4, T0 읽기). 오늘 날짜에만 싣는다.
    struct Budget: Codable, Equatable, Sendable {
        var month: String
        var amountKRW: Double
        var spentKRW: Double
    }

    /// 앱이 분류하지 못한 시간(아무 기록도 덮지 않은 틈). `classifyUnconfirmed`가 그 시각으로 채운다. 10분 넘는 것만.
    struct Unconfirmed: Codable, Equatable, Sendable {
        var start: String
        var end: String
        var minutes: Int
    }
}

extension AssistantActivityBuilder {
    static let goalLimit = 50
    static let tripLimit = 100

    static func addExtras(to result: inout AssistantActivityDay, _ input: AssistantActivityInput, day: TimeSpan, stamp: Stamp) {
        let goals = input.goals
            .filter { GoalRecordPolicy.isGoal($0) && $0.span.end > day.start && $0.span.start < day.end }
            .sorted { $0.span.start < $1.span.start }
            .prefix(goalLimit)
            .map { plan in
                AssistantActivityDay.Goal(
                    id: plan.id.uuidString, title: String(plan.title.prefix(200)),
                    start: stamp.date(plan.span.start), end: stamp.date(plan.span.end.addingTimeInterval(-1))
                )
            }
        if !goals.isEmpty { result.goals = Array(goals) }
        let trips = tripGroups(input, day: day, stamp: stamp)
        if !trips.isEmpty { result.trips = trips }
        let sleep = input.actuals
            .filter { $0.categoryID == "sleep" && $0.endedAt != nil }
            .compactMap { actual -> AssistantActivityDay.Sleep? in
                guard let span = actual.span(asOf: input.now).intersection(with: day), span.duration >= 60 else { return nil }
                let whole = actual.span(asOf: input.now)
                return AssistantActivityDay.Sleep(
                    recordId: actual.id.uuidString, start: stamp.instant(whole.start), end: stamp.instant(whole.end),
                    minutes: Int((whole.duration / 60).rounded()), source: isUserRecord(actual) ? "user" : "auto"
                )
            }
            .sorted { $0.start < $1.start }
        if !sleep.isEmpty { result.sleep = sleep }
        let expenses = input.ledger
            .filter { $0.occurredAt >= day.start && $0.occurredAt < day.end }
            .sorted { $0.occurredAt < $1.occurredAt }
            .prefix(memoLimit)
            .map {
                AssistantActivityDay.Expense(
                    id: $0.id.uuidString, time: stamp.instant($0.occurredAt), title: String($0.title.prefix(60)), category: $0.category.rawValue,
                    kind: $0.kind.rawValue, amount: $0.amount, currency: $0.currency, amountKRW: $0.amountKRW
                )
            }
        if !expenses.isEmpty { result.expenses = Array(expenses) }
        if let budget = input.budget, input.calendar.isDate(input.day, inSameDayAs: input.now) { result.budget = budget }
        // 아무 기록도 덮지 않은 틈만(화면의 미확인과 같은 계산). 사용자가 가린 기록은 기록이 있는 시간이라 틈이 아니다.
        let until = min(day.end, input.now)
        if until > day.start {
            let unconfirmed = ReviewCoverageEngine.unconfirmedRecords(actuals: input.actuals, in: [TimeSpan(start: day.start, end: until)], asOf: input.now)
                .compactMap { gap -> AssistantActivityDay.Unconfirmed? in
                    let span = gap.span(asOf: input.now)
                    guard span.duration >= unconfirmedMinimum else { return nil }
                    return AssistantActivityDay.Unconfirmed(
                        start: stamp.instant(span.start), end: stamp.instant(span.end), minutes: Int((span.duration / 60).rounded())
                    )
                }
                .sorted { $0.start < $1.start }
                .prefix(goalLimit)
            if !unconfirmed.isEmpty { result.unconfirmed = Array(unconfirmed) }
        }
    }

    static let unconfirmedMinimum: TimeInterval = 10 * 60

    /// 그날의 여행 핀과, 핀 없이 시간만 있는 여행 일정을 여행 번호로 묶는다.
    private static func tripGroups(_ input: AssistantActivityInput, day: TimeSpan, stamp: Stamp) -> [AssistantActivityDay.Trip] {
        let stops = TravelPlanSchedule.stops(on: day.start, in: input.tripStops, calendar: input.calendar)
        var groups: [String?: [AssistantActivityDay.Trip.Item]] = [:]
        var order: [String?] = []
        func add(_ tripID: String?, _ item: AssistantActivityDay.Trip.Item) {
            if groups[tripID] == nil { order.append(tripID) }
            groups[tripID, default: []].append(item)
        }
        var covered = Set<String>()
        for stop in stops.prefix(tripLimit) {
            let linked = input.tripItems.first { $0.tripID == stop.tripID && $0.itemID == stop.itemID && stop.itemID != nil }
            if let itemID = stop.itemID, let tripID = stop.tripID { covered.insert("\(tripID)|\(itemID)") }
            add(stop.tripID, .init(
                stopId: stop.id.uuidString, itemId: stop.itemID, title: String(stop.title.prefix(200)), order: stop.order,
                start: linked.map { stamp.instant($0.start) }, end: linked.map { stamp.instant($0.end) },
                status: TripItemStatus(raw: stop.status).rawValue
            ))
        }
        for item in input.tripItems where item.end > day.start && item.start < day.end && !covered.contains("\(item.tripID)|\(item.itemID)") {
            add(item.tripID, .init(
                stopId: nil, itemId: item.itemID, title: String(item.title.prefix(200)), order: nil,
                start: stamp.instant(item.start), end: stamp.instant(item.end), status: TripItemStatus(raw: item.status).rawValue
            ))
        }
        return order.map { AssistantActivityDay.Trip(tripId: $0, items: Array((groups[$0] ?? []).prefix(tripLimit))) }
    }
}
