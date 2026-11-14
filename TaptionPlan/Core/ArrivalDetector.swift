import CoreLocation
import Foundation
import TaptionPlanCore

/// 도착을 볼 일정 장소 하나(ARC1114A14). 좌표는 여행 일정 핀이나 일반 일정의 장소(PLB1114A18)에서 온다.
struct ArrivalCandidate: Equatable, Sendable {
    var stopID: UUID
    var title: String
    var latitude: Double
    var longitude: Double
    /// 이때부터 도착으로 본다(시각이 있는 일정은 시작 2시간 전, 날짜만 있으면 그날 0시).
    var opensAt: Date
    /// 일정이 끝나는 때. 지나면 도착으로 보지 않는다.
    var closesAt: Date
    var tripID: String?
    var itemID: String?
    /// 일반 일정의 장소에서 만든 후보만 채운다: 일정 시간·메모·예상 지출. 이때 `stopID`는 일정 번호다.
    var planSpan: TimeSpan?
    var note: String?
    var plannedSpendKRW: Double?
}

/// 앱이 실제로 받은 위치 하나.
struct ArrivalFix: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var timestamp: Date
}

/// 받은 위치가 일정 장소 반경 안인지 가리는 순수 판정. 받지 못한 위치로는 추정하지 않는다.
enum ArrivalDetector {
    static let radius: CLLocationDistance = 180
    static let leadTime: TimeInterval = 2 * 60 * 60
    /// 이보다 오래된 위치는 지금 있는 곳이 아닐 수 있어 쓰지 않는다.
    static let maximumFixAge: TimeInterval = 120
    static let shownRetention: TimeInterval = 30 * 24 * 60 * 60

    /// 일정 시각은 이어진 여행 일정 → 이어진 계획 → 핀의 날짜 순으로 찾는다.
    static func candidates(
        stops: [TravelPlanStop],
        items: [TravelTripItem],
        plans: [PlanRecord],
        memos: [ActionMemo] = [],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ArrivalCandidate] {
        planCandidates(plans: plans, memos: memos, pinned: Set(stops.compactMap(\.planID))) + stops.compactMap { stop in
            guard CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)) else { return nil }
            let item = stop.tripID.flatMap { trip in items.first { $0.tripID == trip && $0.itemID == stop.itemID } }
            let plan = stop.planID.flatMap { id in plans.first { $0.id == id } }
            let opensAt: Date
            let closesAt: Date
            if let item {
                opensAt = item.start.addingTimeInterval(-leadTime)
                closesAt = max(item.end, item.start)
            } else if let plan {
                opensAt = plan.span.start.addingTimeInterval(-leadTime)
                closesAt = max(plan.span.end, plan.span.start)
            } else {
                opensAt = calendar.startOfDay(for: stop.day)
                closesAt = calendar.date(byAdding: .day, value: 1, to: opensAt) ?? opensAt.addingTimeInterval(86_400)
            }
            return ArrivalCandidate(
                stopID: stop.id, title: item?.title ?? stop.title, latitude: stop.latitude, longitude: stop.longitude,
                opensAt: opensAt, closesAt: closesAt, tripID: stop.tripID, itemID: stop.itemID
            )
        }
    }

    /// 장소를 넣은 일반 일정(PLB1114A18). 루틴·건너뛴 일정과, 이미 여행 핀이 이어진 일정은 뺀다. 시각 창은 그 일정의 시간이다.
    static func planCandidates(plans: [PlanRecord], memos: [ActionMemo], pinned: Set<UUID>) -> [ArrivalCandidate] {
        plans.compactMap { plan in
            guard let place = plan.place, plan.status != .skipped, !pinned.contains(plan.id), !GoalRecordPolicy.isGoal(plan),
                  CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)) else { return nil }
            let notes = memos.filter { $0.planID == plan.id }.sorted { $0.createdAt < $1.createdAt }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return ArrivalCandidate(
                stopID: plan.id, title: place.name, latitude: place.latitude, longitude: place.longitude,
                opensAt: plan.span.start.addingTimeInterval(-leadTime), closesAt: max(plan.span.end, plan.span.start),
                planSpan: plan.span, note: notes.isEmpty ? nil : notes.joined(separator: "\n"),
                plannedSpendKRW: plan.plannedSpendKRW
            )
        }
    }

    /// 반경 안이고 시각 창 안이며 아직 보이지 않은 일정 중 가장 가까운 곳. 정확도가 반경보다 나쁘거나 위치가 오래됐으면 nil.
    static func arrival(
        fix: ArrivalFix,
        now: Date,
        candidates: [ArrivalCandidate],
        shown: Set<UUID>
    ) -> ArrivalCandidate? {
        let age = now.timeIntervalSince(fix.timestamp)
        guard fix.horizontalAccuracy.isFinite, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= radius,
              age >= -5, age <= maximumFixAge,
              CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)) else { return nil }
        let here = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        return candidates
            .filter { !shown.contains($0.stopID) && now >= $0.opensAt && now <= $0.closesAt }
            .map { ($0, here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))) }
            .filter { $0.1 <= radius }
            .min { ($0.1, $0.0.opensAt) < ($1.1, $1.0.opensAt) }?
            .0
    }

    /// 보인 기록에서 오래된 것을 지운다.
    static func pruned(_ shown: [String: Date], now: Date) -> [String: Date] {
        shown.filter { now.timeIntervalSince($0.value) < shownRetention }
    }
}

/// 도착 카드에 보일 내용. 모델에 있는 것만 담는다(결제 수단은 모델에 없어 줄이 없다).
struct ArrivalCard: Equatable, Identifiable {
    struct CheckItem: Equatable, Identifiable {
        /// `여행 번호|일정 번호`. 완료 표시를 기기에 둘 때의 키.
        var id: String
        var title: String
        var note: String?
    }

    var id: UUID
    var title: String
    var start: Date?
    var end: Date?
    var offsetSeconds: Int?
    var note: String?
    var checklist: [CheckItem]
    /// 이곳과 세부 계획의 예상 지출 합(원).
    var plannedSpendKRW: Double?
    var tripBudgetKRW: Double?

    static func make(candidate: ArrivalCandidate, items: [TravelTripItem], tripBudgetKRW: Double?) -> ArrivalCard {
        let item = candidate.tripID.flatMap { trip in items.first { $0.tripID == trip && $0.itemID == candidate.itemID } }
        let details = item.map { TravelTripItem.details(of: $0.itemID, tripID: $0.tripID, in: items).sorted { $0.start < $1.start } } ?? []
        let spend = ([item].compactMap { $0 } + details).compactMap(\.plannedSpendKRW).reduce(0, +) + (item == nil ? candidate.plannedSpendKRW ?? 0 : 0)
        return ArrivalCard(
            id: candidate.stopID,
            title: candidate.title,
            start: item?.start ?? candidate.planSpan?.start,
            end: item?.end ?? candidate.planSpan?.end,
            offsetSeconds: item?.startOffsetSeconds,
            note: clean(item?.note ?? candidate.note),
            checklist: details.map { CheckItem(id: "\($0.tripID)|\($0.itemID)", title: $0.title, note: clean($0.note)) },
            plannedSpendKRW: spend > 0 ? spend : nil,
            tripBudgetKRW: tripBudgetKRW.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
