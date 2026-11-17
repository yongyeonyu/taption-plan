import CoreLocation
import MapKit
import SwiftUI
import TaptionPlanCore

/// 일정에 붙이는 선택 칸(PLB1114A18): 장소와 예상 지출. 저장할 수 있는 값만 남긴다.
struct PlanSpot: Equatable {
    private(set) var place: PlanPlace?
    private(set) var plannedSpendKRW: Double?

    init(place: PlanPlace?, plannedSpendKRW: Double?) {
        self.place = place.flatMap { place in
            let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, place.latitude.isFinite, place.longitude.isFinite,
                  CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)) else { return nil }
            return PlanPlace(name: name, latitude: place.latitude, longitude: place.longitude)
        }
        self.plannedSpendKRW = plannedSpendKRW.flatMap { $0.isFinite && $0 >= 1 ? $0.rounded() : nil }
    }

    /// 입력 칸의 글(숫자만 읽는다)로 만든다.
    init(place: PlanPlace?, spendText: String) {
        self.init(place: place, plannedSpendKRW: Double(TravelQuickEntrySheet.spendDigits(spendText)))
    }

    /// 「계획과 실제」 지도에 그릴 그날 일반 일정의 장소. 이미 여행 핀이 이어진 일정·루틴·건너뛴 일정은 뺀다. 저장하지 않는 값이다.
    static func mapStops(plans: [PlanRecord], day: TimeSpan, pinned: Set<UUID>, after order: Int) -> [TravelPlanStop] {
        plans.filter { $0.place != nil && $0.status != .skipped && !pinned.contains($0.id) && !GoalRecordPolicy.isGoal($0) && $0.span.intersection(with: day) != nil }
            .sorted { ($0.span.start, $0.id.uuidString) < ($1.span.start, $1.id.uuidString) }
            .enumerated().compactMap { index, plan in
                plan.place.map {
                    TravelPlanStop(id: plan.id, title: $0.name, latitude: $0.latitude, longitude: $0.longitude, day: day.start, order: order + index, planID: plan.id)
                }
            }
    }
}

