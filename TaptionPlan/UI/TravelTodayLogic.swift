import Foundation
import TaptionPlanCore
import TaptionPlanStore

/// 지난 여행 일정의 확정(TVZ1116C01): 갔음·건너뜀. 일정 상태 칸(`TravelTripItem.status`)에 함께 적는다.
/// 예약·미정이던 일정은 `visited/booked`처럼 뒤에 지켜 두어 되돌리면 그대로 돌아온다. 예전 빌드는 모르는 값이라 계획으로 읽는다.
enum TravelVisitMark: String, CaseIterable, Sendable {
    case visited, skipped

    private static let bases: Set<String> = ["booked", "tentative"]

    init?(stored: String?) {
        guard let head = stored?.split(separator: "/").first, let mark = Self(rawValue: String(head)) else { return nil }
        self = mark
    }

    /// 확정을 뺀 원래 상태(예약·미정). 계획이면 nil.
    static func base(_ stored: String?) -> String? {
        guard let last = stored?.split(separator: "/").last.map(String.init) else { return nil }
        return bases.contains(last) ? last : nil
    }

    /// 저장할 값. `mark`가 nil이면 확정을 지우고 원래 상태만 남긴다.
    static func stored(_ mark: TravelVisitMark?, over current: String?) -> String? {
        let base = base(current)
        guard let mark else { return base }
        return base.map { "\(mark.rawValue)/\($0)" } ?? mark.rawValue
    }

    /// 상태 칸에 둘 수 있는 값인가(공유 방에서 받은 글을 거른다).
    static func isStorable(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1: return bases.contains(parts[0]) || Self(rawValue: parts[0]) != nil
        case 2: return Self(rawValue: parts[0]) != nil && bases.contains(parts[1])
        default: return false
        }
    }
}

/// 오늘 카드가 보이는 것(TVZ1116C01). 계획표의 그날 블록에서 고른다. 순수 계산만 둔다.
struct TravelTodayBoard: Equatable {
    struct Stop: Identifiable, Equatable {
        let id: String
        var title: String
        var startMinute: Int
        var endMinute: Int
    }

    /// 끝났는데 아직 확정하지 않은 일정.
    struct Review: Identifiable, Equatable {
        var stop: Stop
        /// 자동 기록이 그 곳·시간과 맞아 「갔음」을 미리 골라 둔다. 저장은 사용자가 누를 때만 한다.
        var suggestsVisited: Bool
        var id: String { stop.id }
    }

    struct Done: Identifiable, Equatable {
        var stop: Stop
        var mark: TravelVisitMark
        var id: String { stop.id }
    }

    /// 지금 하고 있는 일정과 남은 분.
    var current: Stop?
    var remainingMinutes = 0
    var next: Stop?
    /// 다음 곳까지 가는 분(길찾기로 받아 둔 것이 있을 때만).
    var travelMinutes: Int?
    var reviews: [Review] = []
    var done: [Done] = []
    /// 오늘 일정이 하나도 없다.
    var isEmpty = true

    /// - Parameters:
    ///   - marks: 일정 번호별 확정.
    ///   - suggested: 자동 기록이 맞은 일정 번호.
    ///   - travelMinutes: 구간(`TravelPlayhead.legKey`)별 이동 분.
    static func make(
        blocks: [TravelPlanTableModel.Block], nowMinute: Int, marks: [String: TravelVisitMark] = [:], suggested: Set<String> = [],
        travelMinutes: [String: Int] = [:]
    ) -> TravelTodayBoard {
        let stops = stops(blocks)
        var board = TravelTodayBoard()
        board.isEmpty = stops.isEmpty
        // 확정한 일정은 지금·다음에서 빠진다(일찍 끝냈거나 건너뛴 것).
        let open = stops.filter { marks[$0.id] == nil }
        if let current = open.last(where: { $0.startMinute <= nowMinute && nowMinute < $0.endMinute }) {
            board.current = current
            board.remainingMinutes = current.endMinute - nowMinute
        }
        if let next = open.first(where: { $0.startMinute > nowMinute }) {
            board.next = next
            board.travelMinutes = stops.prefix { $0.id != next.id }.reversed().lazy
                .compactMap { travelMinutes[TravelPlayhead.legKey($0.id, next.id)] }.first
        }
        board.reviews = open.filter { $0.endMinute <= nowMinute }.map { Review(stop: $0, suggestsVisited: suggested.contains($0.id)) }
        board.done = stops.compactMap { stop in marks[stop.id].map { Done(stop: stop, mark: $0) } }
        return board
    }

    /// 그날의 굵은 일정(시각 순). 같은 날에 코스 곳이 있는 세부 계획은 그 곳에 딸려 따로 묻지 않는다.
    static func stops(_ blocks: [TravelPlanTableModel.Block]) -> [Stop] {
        let ids = Set(blocks.map(\.id))
        return blocks.filter { block in block.endMinute > block.startMinute && !(block.parentID.map(ids.contains) ?? false) }
            .sorted { ($0.startMinute, $0.endMinute, $0.id) < ($1.startMinute, $1.endMinute, $1.id) }
            .map { Stop(id: $0.id, title: $0.title, startMinute: $0.startMinute, endMinute: $0.endMinute) }
    }

    /// 확정을 물을 수 있는 일정(끝났고 확정 안 된 것)의 번호. 자동 기록 맞춤은 이것만 본다.
    static func reviewIDs(blocks: [TravelPlanTableModel.Block], nowMinute: Int, marks: [String: TravelVisitMark]) -> Set<String> {
        Set(stops(blocks).filter { $0.endMinute <= nowMinute && marks[$0.id] == nil }.map(\.id))
    }

    static func marks(_ items: [TravelTripItem], tripID: String) -> [String: TravelVisitMark] {
        var marks: [String: TravelVisitMark] = [:]
        for item in items where item.tripID == tripID { marks[item.itemID] = TravelVisitMark(stored: item.status) }
        return marks
    }
}

/// 자동 기록이 그 일정을 다녀온 것으로 보이는가(TVZ1116C01). 기록은 읽기만 한다.
enum TravelVisitMatch {
    /// 핀에서 이 거리 안에 머문 기록(「계획과 실제」와 같은 값).
    static let radiusMeters = PlanRealityGap.Thresholds.standard.stopRadiusMeters
    /// 계획 시각의 앞뒤로 이만큼까지는 같은 일정으로 본다.
    static let slack: TimeInterval = 30 * 60

    /// 머문 기록이 핀 반경 안이고 계획 시간과 겹치거나, 그 일정에 이어진 기록이 이미 시작했으면 true.
    static func isVisited(
        item: TravelTripItem, stop: TravelPlanStop?, stays: [PlaceStay], actuals: [ActualRecord] = [], now: Date,
        radius: Double = radiusMeters, slack: TimeInterval = slack
    ) -> Bool {
        if let planID = item.planID, actuals.contains(where: { $0.planID == planID && $0.startedAt < now }) { return true }
        guard let stop else { return false }
        let from = item.start.addingTimeInterval(-slack), until = item.end.addingTimeInterval(slack)
        return stays.contains { stay in
            guard let point = stay.point, stay.span.start < now, stay.span.start < until, stay.span.end > from else { return false }
            return PlanRealityGap.meters(point.latitude, point.longitude, stop.latitude, stop.longitude) <= radius
        }
    }

    /// `ids` 가운데 자동 기록이 맞은 일정 번호.
    static func suggested(
        ids: Set<String>, items: [TravelTripItem], tripID: String, stops: [TravelPlanStop], stays: [PlaceStay], actuals: [ActualRecord], now: Date
    ) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let mine = items.filter { $0.tripID == tripID && ids.contains($0.itemID) }
        guard let first = mine.map(\.start).min(), let last = mine.map(\.end).max() else { return [] }
        let near = stays.filter { $0.span.start < last.addingTimeInterval(slack) && $0.span.end > first.addingTimeInterval(-slack) }
        return Set(mine.filter { item in
            isVisited(item: item, stop: stops.first { $0.tripID == tripID && $0.itemID == item.itemID }, stays: near, actuals: actuals, now: now)
        }.map(\.itemID))
    }
}

/// 여행 화면에서 「계획과 실제」를 열 날.
struct TravelTodayDay: Identifiable {
    let date: Date
    var id: Date { date }
}
