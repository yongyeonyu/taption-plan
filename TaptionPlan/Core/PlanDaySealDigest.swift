import Foundation
import TaptionPlanCore

/// 확정 요약을 만들 때 쓰는 하루 집계. 위젯 확장에는 필요 없어 앱 타깃에만 넣는다
/// (`DayPhaseEngine`·`RecordAnalysisCategoryPolicy`에 기댄다).
extension TaptionSealedDayBuilder {
    /// 하루를 대분류별 초로 묶는다. 하루 요약 화면과 확정 요약이 같은 값을 쓰도록 계산을 한 곳에 둔다.
    ///
    /// 식사는 대분류 phase에 없어 '활동'에 흡수되므로, 활동과 겹치는 식사 기록만큼을 활동에서 떼어
    /// '식사'로 옮긴다. 총합·이동·수면 집계는 그대로 두고 세부 원본도 건드리지 않는다.
    static func categoryDurations(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        day: TimeSpan,
        asOf now: Date
    ) -> [String: TimeInterval] {
        let phases = DayPhaseEngine.completePhases(
            actuals: actuals,
            travel: travel,
            stays: stays,
            placeKinds: placeKinds,
            in: day,
            asOf: now
        )
        var totalsByID: [String: TimeInterval] = [:]
        for entry in DayPhaseEngine.categoryDurations(phases, scope: .canonical) where entry.actual > 0 {
            totalsByID[entry.categoryID, default: 0] += entry.actual
        }
        let eatingSpans = actuals
            .filter { RecordAnalysisCategoryPolicy.categoryID(for: $0) == "eating" }
            .map { $0.span(asOf: now) }
            .compactMap { $0.intersection(with: day) }
        guard !eatingSpans.isEmpty else { return totalsByID }
        let eatingTotal = unionDuration(eatingSpans)
        let activityPhaseSpans = phases
            .filter { RecordAnalysisCategoryPolicy.canonicalPhase($0.phase).rawValue == "activity" }
            .map(\.span)
        var overlaps: [TimeSpan] = []
        for phaseSpan in activityPhaseSpans {
            for eating in eatingSpans {
                if let overlap = phaseSpan.intersection(with: eating) { overlaps.append(overlap) }
            }
        }
        let movedSeconds = min(unionDuration(overlaps), totalsByID["activity"] ?? 0)
        if movedSeconds > 0 {
            totalsByID["activity", default: 0] -= movedSeconds
            if (totalsByID["activity"] ?? 0) <= 0 { totalsByID["activity"] = nil }
        }
        var remaining = max(0, eatingTotal - movedSeconds)
        while remaining > 0,
              let donor = totalsByID.filter({ $0.key != "eating" }).max(by: { $0.value < $1.value }),
              donor.value > 0 {
            let taken = min(remaining, donor.value)
            totalsByID[donor.key] = donor.value - taken
            remaining -= taken
            if (totalsByID[donor.key] ?? 0) <= 0 { totalsByID[donor.key] = nil }
        }
        totalsByID["eating", default: 0] += eatingTotal - remaining
        return totalsByID
    }

    /// 겹치는 구간을 병합한 총 시간(같은 초를 두 번 세지 않는다).
    static func unionDuration(_ spans: [TimeSpan]) -> TimeInterval {
        let ordered = spans.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        guard var current = ordered.first else { return 0 }
        var total: TimeInterval = 0
        for span in ordered.dropFirst() {
            if span.start <= current.end {
                current.end = max(current.end, span.end)
            } else {
                total += current.duration
                current = span
            }
        }
        return total + current.duration
    }
}
