import Foundation

/// 기록 화면이 쓰는 "N시간 N분" 표기. 화면마다 같은 계산을 다시 쓰지 않도록
/// 한 곳에 둔다.
enum DurationText {
    static func korean(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int(interval / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)분" }
        if minutes == 0 { return "\(hours)시간" }
        return "\(hours)시간 \(minutes)분"
    }

    static func signedKorean(_ interval: TimeInterval) -> String {
        (interval > 0 ? "＋" : "－") + korean(abs(interval))
    }
}

/// 자동 기록은 `activity` 하나에 걸음·수면·이동이 섞여 들어온다. 어느 줄에
/// 묶을지 판단하는 규칙을 화면마다 따로 두면 시간표와 기록이 어긋나므로
/// 한 곳에서만 정한다.
enum ActualRecordCategoryResolver {
    private static let movementWords = [
        "걷", "달리", "러닝", "자전거", "사이클", "계단", "차량", "자동차",
        "버스", "지하철", "택시", "기차", "비행기", "배", "이동", "walking",
        "running", "cycling", "automotive", "subway", "transit",
    ]

    static func categoryID(for actual: ActualRecord) -> String {
        guard actual.categoryID == "activity" else { return actual.categoryID }
        let value = "\(actual.title) \(actual.behavior ?? "")".lowercased()
        if value.contains("수면") || value.contains("sleep") { return "sleep" }
        return movementWords.contains(where: value.contains)
            ? "movement"
            : "activity"
    }
}

// MARK: - 계층형 기록 목록

struct RecordGroupChild: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let duration: TimeInterval
    let start: Date
    let recordID: UUID
    let occurrenceCount: Int
}

struct RecordCategoryGroup: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let colorHex: String?
    let icon: CategoryIcon?
    let duration: TimeInterval
    let dominantChildTitle: String?
    let children: [RecordGroupChild]
}

/// 기간 안의 자동·수동 기록을 카테고리 → 항목의 두 단계로 접는다.
/// 화면은 이 결과만 그리고, 제스처 중에는 다시 계산하지 않는다.
enum ActualRecordGroupingEngine {
    static func groups(
        actuals: [ActualRecord],
        in span: TimeSpan,
        categories: [CategoryDefinition],
        asOf: Date = .now
    ) -> [RecordCategoryGroup] {
        let limit = min(asOf, span.end)
        var seen = Set<UUID>()
        var byCategory: [String: [(record: ActualRecord, span: TimeSpan)]] = [:]

        for actual in actuals {
            guard seen.insert(actual.id).inserted else { continue }
            guard actual.startedAt < limit,
                  let visible = actual.span(asOf: limit)
                      .intersection(with: span),
                  visible.duration > 0 else {
                continue
            }
            let id = ActualRecordCategoryResolver.categoryID(for: actual)
            byCategory[id, default: []].append((actual, visible))
        }

        let definitions = Dictionary(
            categories.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return byCategory
            .map { categoryID, values in
                let children = mergedChildren(values)
                let definition = definitions[categoryID]
                return RecordCategoryGroup(
                    id: categoryID,
                    name: displayName(
                        categoryID: categoryID,
                        definition: definition
                    ),
                    colorHex: definition?.darkHex,
                    icon: definition?.icon,
                    duration: children.reduce(0) { $0 + $1.duration },
                    dominantChildTitle: children
                        .max { $0.duration < $1.duration }?
                        .title,
                    children: children
                )
            }
            .sorted {
                $0.duration == $1.duration
                    ? $0.id < $1.id
                    : $0.duration > $1.duration
            }
    }

    /// 자동 기록은 같은 제목이 하루에 여러 번 끊겨 들어온다. 제목이 같으면
    /// 한 줄로 합치고 겹치는 구간은 한 번만 센다.
    private static func mergedChildren(
        _ values: [(record: ActualRecord, span: TimeSpan)]
    ) -> [RecordGroupChild] {
        Dictionary(grouping: values) { childTitle($0.record).lowercased() }
            .values
            .compactMap { entries -> RecordGroupChild? in
                let ordered = entries.sorted { $0.span.start < $1.span.start }
                guard let first = ordered.first else { return nil }
                return RecordGroupChild(
                    id: first.record.id.uuidString,
                    title: childTitle(first.record),
                    duration: ActualIntervalMergeEngine.duration(
                        of: ordered.map(\.span)
                    ),
                    start: first.span.start,
                    recordID: first.record.id,
                    occurrenceCount: ordered.count
                )
            }
            .sorted {
                $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start
            }
    }

    private static func childTitle(_ actual: ActualRecord) -> String {
        if ActualRecordCategoryResolver.categoryID(for: actual) == "movement" {
            return MovementPresentation.title(for: actual)
        }
        let trimmed = actual.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !trimmed.isEmpty { return trimmed }
        return TimelineRowKind.title(forCategoryID: actual.categoryID)
            ?? actual.categoryID
    }

    private static func displayName(
        categoryID: String,
        definition: CategoryDefinition?
    ) -> String {
        // 어플·날씨처럼 사용자 카테고리에 없는 자동 줄도 한글 이름을 갖는다.
        if let name = definition?.name { return name }
        return TimelineRowKind.title(forCategoryID: categoryID) ?? categoryID
    }
}

// MARK: - 기록 차트

struct RecordClockArc: Identifiable, Equatable, Sendable {
    let id: String
    let categoryID: String
    /// 하루를 0…1로 본 시작·끝 위치. 자정이 0이다.
    let startFraction: Double
    let endFraction: Double
}

struct RecordClockRing: Identifiable, Equatable, Sendable {
    let id: String
    let categoryID: String
    let duration: TimeInterval
    let arcs: [RecordClockArc]
}

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
        asOf: Date = .now
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
            byCategory[
                ActualRecordCategoryResolver.categoryID(for: actual),
                default: []
            ].append(visible)
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
    static func buckets(
        actuals: [ActualRecord],
        in span: TimeSpan,
        unit: Calendar.Component,
        calendar: Calendar,
        asOf: Date = .now
    ) -> [RecordChartBucket] {
        let limit = min(asOf, span.end)
        let visible = uniqueVisible(actuals, in: span, asOf: limit)

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
                    id: ISO8601DateFormatter.string(
                        from: bucketSpan.start,
                        timeZone: calendar.timeZone,
                        formatOptions: [.withInternetDateTime]
                    ),
                    span: bucketSpan,
                    slices: slices(of: visible, in: bucketSpan)
                )
            )
            cursor = next
        }
        return result
    }

    private static func uniqueVisible(
        _ actuals: [ActualRecord],
        in span: TimeSpan,
        asOf: Date
    ) -> [(categoryID: String, span: TimeSpan)] {
        var seen = Set<UUID>()
        return actuals.compactMap { actual in
            guard seen.insert(actual.id).inserted else { return nil }
            guard actual.startedAt < asOf,
                  let visible = actual.span(asOf: asOf)
                      .intersection(with: span),
                  visible.duration > 0 else {
                return nil
            }
            return (
                ActualRecordCategoryResolver.categoryID(for: actual),
                visible
            )
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
