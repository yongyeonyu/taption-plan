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

/// 막대 그림의 세로 눈금. 눈금 자리가 좁아 한 시간이 넘으면 시간만 적고,
/// 그 아래는 분으로 적는다.
enum DurationAxisText {
    static func korean(hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        if minutes == 0 { return "0" }
        if minutes < 60 { return "\(minutes)분" }
        if minutes % 60 == 0 { return "\(minutes / 60)시간" }
        return DurationText.korean(Double(minutes) * 60)
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

// MARK: - 하루 원형 시간표의 재생·고르기

/// 원형 시간표는 재생 중 매 프레임 다시 그린다. 그때마다 하루를 다시 집계하면
/// 예산을 넘기므로, 이미 만들어 둔 고리를 자르고 고르는 일만 여기서 한다.
enum RecordClockEngine {
    /// 재생이 00시에서 24시까지 한 바퀴 도는 데 걸리는 시간.
    static let sweepDuration: TimeInterval = 24

    /// 재생 중 화면 갱신 예산. 한 시간당 1초라 60Hz면 충분히 매끄럽다.
    static let frameInterval: TimeInterval = 1.0 / 60.0

    /// 가로로 이만큼 끌어야 날짜가 넘어간다.
    static let swipeThreshold: Double = 44

    /// 보고 있는 하루가 지금을 품을 때만 현재 시각 위치(0…1)를 준다.
    /// 오늘이 아니면 바늘을 그리지 않는다.
    static func nowFraction(in span: TimeSpan, asOf: Date = .now) -> Double? {
        let total = span.duration
        guard total > 0, span.start <= asOf, asOf < span.end else { return nil }
        return asOf.timeIntervalSince(span.start) / total
    }

    /// 재생 진행률(0…1). 재생 중이 아니면 nil이고, 그때는 정적인 화면이다.
    static func progress(start: Date?, now: Date) -> Double? {
        guard let start else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 0 else { return 0 }
        return min(1, elapsed / sweepDuration)
    }

    /// 범례에서 고른 카테고리만 남긴다. 고르지 않았으면 그대로 둔다.
    static func rings(
        _ rings: [RecordClockRing],
        isolating categoryID: String?
    ) -> [RecordClockRing] {
        guard let categoryID else { return rings }
        return rings.filter { $0.categoryID == categoryID }
    }

    /// 재생머리가 지난 만큼만 남긴다. 진행률이 nil이면 자르지 않는다.
    static func rings(
        _ rings: [RecordClockRing],
        revealedThrough progress: Double?
    ) -> [RecordClockRing] {
        guard let progress else { return rings }
        return rings.compactMap { ring in
            let arcs = ring.arcs.compactMap { arc -> RecordClockArc? in
                guard arc.startFraction < progress else { return nil }
                guard arc.endFraction > progress else { return arc }
                return RecordClockArc(
                    id: arc.id,
                    categoryID: arc.categoryID,
                    startFraction: arc.startFraction,
                    endFraction: progress
                )
            }
            guard !arcs.isEmpty else { return nil }
            return RecordClockRing(
                id: ring.id,
                categoryID: ring.categoryID,
                duration: ring.duration,
                arcs: arcs
            )
        }
    }

    /// 재생머리가 지금 지나고 있는 카테고리. 이 기록만 굵게 그린다.
    static func categoryIDs(
        in rings: [RecordClockRing],
        at fraction: Double
    ) -> Set<String> {
        var result: Set<String> = []
        for ring in rings where ring.arcs.contains(
            where: { $0.startFraction <= fraction && fraction < $0.endFraction }
        ) {
            result.insert(ring.categoryID)
        }
        return result
    }

    /// 가로로 충분히 끌었을 때만 날짜를 옮긴다. 왼쪽으로 끌면 다음 날이다.
    /// 세로가 더 길면 목록 스크롤이므로 날짜를 건드리지 않는다.
    static func swipeStep(
        width: Double,
        height: Double,
        threshold: Double = swipeThreshold
    ) -> Int? {
        guard abs(width) >= threshold, abs(width) > abs(height) else {
            return nil
        }
        return width < 0 ? 1 : -1
    }
}
