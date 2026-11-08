import Foundation
import TaptionPlanEngine

struct RecordChartSlice: Identifiable, Equatable, Sendable {
    let id: String
    let categoryID: String
    let duration: TimeInterval
}

struct RecordChartBucket: Identifiable, Equatable, Sendable {
    let id: String
    let span: TimeSpan
    let slices: [RecordChartSlice]

    var total: TimeInterval {
        slices.reduce(0) { $0 + $1.duration }
    }
}

/// 기록 화면의 그림 데이터. 뷰 본문에서 계산하면 제스처마다 전체 기간을
/// 다시 훑게 되므로 순수 함수로 떼어 두고 데이터가 바뀔 때만 부른다.
enum RecordChartEngine {
    /// 하루 원형 시간표. 카테고리마다 하나의 고리를 만들어 겹친 기록이
    /// 서로를 가리지 않게 한다. 고리는 총 시간이 긴 쪽이 바깥이다.
    static func clockRings(
        actuals: [ActualRecord],
        in span: TimeSpan,
        asOf: Date = .now,
        scope: RecordAnalysisScope = .legacy
    ) -> [RecordClockRing] {
        let limit = min(asOf, span.end)
        let total = span.duration
        guard total > 0 else { return [] }

        var byCategory: [String: [TimeSpan]] = [:]
        var seen = Set<UUID>()
        for actual in actuals {
            guard seen.insert(actual.id).inserted else { continue }
            guard actual.startedAt < limit,
                  let visible = actual.span(asOf: limit)
                      .intersection(with: span),
                  visible.duration > 0 else {
                continue
            }
            let categoryID = scope.categoryID(for: actual)
            byCategory[categoryID, default: []].append(visible)
        }

        return byCategory
            .map { categoryID, spans in
                let merged = ActualIntervalMergeEngine.union(spans)
                return RecordClockRing(
                    id: categoryID,
                    categoryID: categoryID,
                    duration: merged.reduce(0) { $0 + $1.duration },
                    arcs: merged.enumerated().map { offset, value in
                        RecordClockArc(
                            id: "\(categoryID).\(offset)",
                            categoryID: categoryID,
                            startFraction: value.start
                                .timeIntervalSince(span.start) / total,
                            endFraction: value.end
                                .timeIntervalSince(span.start) / total
                        )
                    }
                )
            }
            .sorted {
                $0.duration == $1.duration
                    ? $0.categoryID < $1.categoryID
                    : $0.duration > $1.duration
            }
    }

    /// 주·월·년 막대. `unit`은 한 칸의 길이(주·월은 하루, 년은 한 달)다.
    /// `categoryIDs`가 비어 있지 않으면 고른 카테고리만 남긴다. 흐리게
    /// 덮는 대신 여기서 걸러야 세로 범위도 남은 자료에 맞출 수 있다.
    static func buckets(
        actuals: [ActualRecord],
        in span: TimeSpan,
        unit: Calendar.Component,
        calendar: Calendar,
        categoryIDs: Set<String> = [],
        asOf: Date = .now
    ) -> [RecordChartBucket] {
        let limit = min(asOf, span.end)
        let visible = uniqueVisible(
            actuals,
            in: span,
            asOf: limit,
            categoryIDs: categoryIDs
        )

        return buckets(
            values: visible,
            in: span,
            unit: unit,
            calendar: calendar
        )
    }

    /// 주·월·년은 세부 활동이 아니라 일별로 확정된 일과를 합산한다. 매일을
    /// 먼저 24시간 분류한 뒤에만 일·월 단위 막대로 묶어, 상위 기간에서
    /// 중복 활동 시간이 더해지지 않게 한다.
    static func phaseBuckets(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        in span: TimeSpan,
        unit: Calendar.Component,
        calendar: Calendar,
        asOf: Date = .now,
        scope: RecordAnalysisScope = .legacy
    ) -> [RecordChartBucket] {
        let end = min(span.end, asOf)
        guard end > span.start else { return [] }
        let values = DayPhaseEngine.completePhasesAcrossDays(
            actuals: actuals,
            travel: travel,
            stays: stays,
            placeKinds: placeKinds,
            in: span,
            calendar: calendar,
            asOf: asOf
        ).map { (scope.phase($0.phase).rawValue, $0.span) }
        return buckets(
            values: values,
            in: span,
            unit: unit,
            calendar: calendar
        )
    }

    static func categoryDurations(
        in buckets: [RecordChartBucket]
    ) -> [CategoryDuration] {
        var totals: [String: TimeInterval] = [:]
        for slice in buckets.flatMap(\.slices) {
            totals[slice.categoryID, default: 0] += slice.duration
        }
        return totals.map {
            CategoryDuration(categoryID: $0.key, planned: 0, actual: $0.value)
        }.sorted {
            $0.actual == $1.actual
                ? $0.categoryID < $1.categoryID
                : $0.actual > $1.actual
        }
    }

    private static func buckets(
        values: [(categoryID: String, span: TimeSpan)],
        in span: TimeSpan,
        unit: Calendar.Component,
        calendar: Calendar
    ) -> [RecordChartBucket] {
        var result: [RecordChartBucket] = []
        var cursor = calendar.dateInterval(of: unit, for: span.start)?.start
            ?? span.start
        while cursor < span.end {
            guard let next = calendar.date(
                byAdding: unit,
                value: 1,
                to: cursor
            ) else {
                break
            }
            let bucketSpan = TimeSpan(
                start: max(cursor, span.start),
                end: min(next, span.end)
            )
            result.append(
                RecordChartBucket(
                    id: ReviewSelectionEngine.identifier(
                        of: bucketSpan.start,
                        calendar: calendar
                    ),
                    span: bucketSpan,
                    slices: slices(of: values, in: bucketSpan)
                )
            )
            cursor = next
        }
        return result
    }

    /// 고른 카테고리만 남긴 막대에서 가장 높은 칸(시간). 세로 눈금 범위를
    /// 이 값으로 다시 잡아 막대가 높이를 다 쓰게 한다.
    static func maxTotalHours(_ buckets: [RecordChartBucket]) -> Double {
        let peak = (buckets.map(\.total).max() ?? 0) / 3_600
        return peak > 0 ? peak : 1
    }

    private static func uniqueVisible(
        _ actuals: [ActualRecord],
        in span: TimeSpan,
        asOf: Date,
        categoryIDs: Set<String>
    ) -> [(categoryID: String, span: TimeSpan)] {
        var seen = Set<UUID>()
        return actuals.compactMap { actual in
            guard seen.insert(actual.id).inserted else { return nil }
            let categoryID = ActualRecordCategoryResolver.categoryID(for: actual)
            guard categoryIDs.isEmpty || categoryIDs.contains(categoryID) else {
                return nil
            }
            guard actual.startedAt < asOf,
                  let visible = actual.span(asOf: asOf)
                      .intersection(with: span),
                  visible.duration > 0 else {
                return nil
            }
            return (categoryID, visible)
        }
    }

    private static func slices(
        of values: [(categoryID: String, span: TimeSpan)],
        in bucket: TimeSpan
    ) -> [RecordChartSlice] {
        var byCategory: [String: [TimeSpan]] = [:]
        for value in values {
            guard let clipped = value.span.intersection(with: bucket),
                  clipped.duration > 0 else {
                continue
            }
            byCategory[value.categoryID, default: []].append(clipped)
        }
        return byCategory
            .map { categoryID, spans in
                RecordChartSlice(
                    id: categoryID,
                    categoryID: categoryID,
                    duration: ActualIntervalMergeEngine.duration(of: spans)
                )
            }
            .sorted {
                $0.duration == $1.duration
                    ? $0.categoryID < $1.categoryID
                    : $0.duration > $1.duration
            }
    }
}
