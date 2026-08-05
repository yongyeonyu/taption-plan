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

    /// 1분이 되지 않는 사용도 실제로 있었던 사용이다. "0분"이라고 적으면
    /// 없던 일처럼 읽히므로, 시간표 상세와 기록 목록이 같은 문구를 쓴다.
    static func koreanAtLeastAMinute(_ interval: TimeInterval) -> String {
        interval > 0 && interval < 60 ? "1분 미만" : korean(interval)
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
        groups(
            actuals: actuals,
            in: [span],
            categories: categories,
            asOf: asOf
        )
    }

    /// 고른 칸이 여럿일 때도 목록은 하나다. 기록을 칸마다 잘라 담고 같은
    /// 항목의 조각을 합쳐, 떨어진 칸을 골라도 합계가 겹쳐 세어지지 않는다.
    static func groups(
        actuals: [ActualRecord],
        in spans: [TimeSpan],
        categories: [CategoryDefinition],
        asOf: Date = .now
    ) -> [RecordCategoryGroup] {
        var seen = Set<UUID>()
        var byCategory: [String: [(record: ActualRecord, span: TimeSpan)]] = [:]

        for actual in actuals {
            guard seen.insert(actual.id).inserted else { continue }
            let id = ActualRecordCategoryResolver.categoryID(for: actual)
            for span in spans {
                let limit = min(asOf, span.end)
                guard actual.startedAt < limit,
                      let visible = actual.span(asOf: limit)
                          .intersection(with: span),
                      visible.duration > 0 else {
                    continue
                }
                byCategory[id, default: []].append((actual, visible))
            }
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
    /// 한 줄로 합치고 겹치는 구간은 한 번만 센다. 한 기록이 고른 칸 여럿에
    /// 걸쳐 잘렸을 때는 조각이 아니라 기록을 센다.
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
                    occurrenceCount: Set(ordered.map(\.record.id)).count
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

// MARK: - 기간 고르기

/// 기록 화면에서 손가락으로 켜고 끄는 한 칸.
struct ReviewPeriodBucket: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let span: TimeSpan
}

/// 기록 화면이 읽을 구간을 정한다. 고른 칸이 없으면 기간 전체 하나이고,
/// 고른 칸이 있으면 그 칸들의 합집합이다. 합계·눈금판·목록이 모두 이 한
/// 값을 읽어야 서로 다른 숫자를 말하지 않는다.
enum ReviewSelectionEngine {
    /// 배율마다 고를 수 있는 칸의 크기. 하루는 나누지 않는다 — 하루는 늘
    /// 통째로 본다.
    static func bucketLevel(for level: TimelineLevel) -> TimelineLevel? {
        switch level {
        case .day: nil
        case .week: .day
        case .month: .week
        case .year: .month
        }
    }

    static func buckets(
        for level: TimelineLevel,
        in period: TimeSpan,
        calendar: Calendar
    ) -> [ReviewPeriodBucket] {
        guard let bucketLevel = bucketLevel(for: level) else { return [] }
        let component = component(for: bucketLevel)
        var result: [ReviewPeriodBucket] = []
        var cursor = period.start

        while cursor < period.end {
            guard let interval = calendar.dateInterval(
                of: component,
                for: cursor
            ) else {
                break
            }
            let span = TimeSpan(
                start: max(interval.start, period.start),
                end: min(interval.end, period.end)
            )
            if span.duration > 0 {
                result.append(
                    ReviewPeriodBucket(
                        id: identifier(of: span.start, calendar: calendar),
                        label: label(
                            of: span,
                            level: bucketLevel,
                            index: result.count,
                            calendar: calendar
                        ),
                        span: span
                    )
                )
            }
            guard interval.end > cursor else { break }
            cursor = interval.end.addingTimeInterval(0.001)
        }
        return result
    }

    /// 고른 칸이 없거나 지금 기간에 없는 칸만 남았으면 기간 전체로 돌아간다.
    /// 화면이 아무것도 가리키지 않는 상태에 빠지지 않게 하는 마지막 방어다.
    static func spans(
        period: TimeSpan,
        buckets: [ReviewPeriodBucket],
        selectedIDs: Set<String>
    ) -> [TimeSpan] {
        let chosen = buckets
            .filter { selectedIDs.contains($0.id) }
            .map(\.span)
        guard !chosen.isEmpty else { return [period] }
        return ActualIntervalMergeEngine.union(chosen, mergeGap: 0)
    }

    private static func component(
        for level: TimelineLevel
    ) -> Calendar.Component {
        switch level {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    private static func identifier(
        of start: Date,
        calendar: Calendar
    ) -> String {
        ISO8601DateFormatter.string(
            from: start,
            timeZone: calendar.timeZone,
            formatOptions: [.withInternetDateTime]
        )
    }

    private static let weekdayNames = ["일", "월", "화", "수", "목", "금", "토"]

    private static func label(
        of span: TimeSpan,
        level: TimelineLevel,
        index: Int,
        calendar: Calendar
    ) -> String {
        switch level {
        case .day:
            let weekday = calendar.component(.weekday, from: span.start)
            return weekdayNames[max(1, min(7, weekday)) - 1]
        case .week:
            return "\(index + 1)주"
        case .month:
            return "\(calendar.component(.month, from: span.start))월"
        case .year:
            return "\(calendar.component(.year, from: span.start))년"
        }
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

/// 하루 눈금판 안쪽에 덧대는 띠. 바깥 고리가 "무엇을 했는가"라면 이 띠는
/// 그 안의 결을 보여 준다. 한 띠에는 종류가 다른 조각이 이어 붙는다.
enum RecordClockDetailKind: String, Equatable, Sendable {
    case sleepStage
    case travel
}

struct RecordClockDetailArc: Identifiable, Equatable, Sendable {
    let id: String
    /// 색과 이름을 고르는 열쇠. 수면은 `SleepStage`, 이동은 `TravelMode`의
    /// 원시값이다.
    let token: String
    let startFraction: Double
    let endFraction: Double
}

struct RecordClockDetailRing: Identifiable, Equatable, Sendable {
    let id: String
    let kind: RecordClockDetailKind
    let arcs: [RecordClockDetailArc]
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

/// 메모는 구간이 아니라 순간이다. 시간표는 구간만 그릴 수 있으므로 순간을
/// 표식으로 바꾸고, 한 화면에서 서로 구분되지 않을 만큼 붙은 표식은 하나로
/// 합친다. 화소보다 얇은 조각을 수백 개 그리면 화면이 멈춘다는 사실은 눈금판
/// 띠에서 이미 배웠으므로 기준값도 그 띠와 같은 것
/// (`RecordClockDetailEngine.minimumArcFraction`)을 쓴다.
enum MemoTimelineEngine {
    /// 항목에 딸리지 않은 메모가 갖는 분류. 곧 시간표 메모 줄의 id 다.
    static let categoryID = TimelineRowKind.memo.rawValue

    /// 표식 하나의 기본 길이. 하루의 0.4%는 약 6분이다.
    static let markerDuration: TimeInterval =
        86_400 * RecordClockDetailEngine.minimumArcFraction

    /// 보이는 기간이 넓을수록 더 많이 합친다. 주는 약 40분, 월은 약 3시간,
    /// 년은 약 하루 반 안에 있는 메모가 표식 하나로 모인다.
    static func clusterInterval(
        visibleDuration: TimeInterval
    ) -> TimeInterval {
        max(
            markerDuration,
            visibleDuration * RecordClockDetailEngine.minimumArcFraction
        )
    }

    /// 시간표 메모 줄에 그려질 표식. 여러 메모가 모였으면 `memoIDs` 가 그
    /// 전부를 들고 있어 탭 한 번으로 묶음을 열 수 있다.
    struct Marker: Identifiable, Equatable, Sendable {
        let id: UUID
        let span: TimeSpan
        let memoIDs: [UUID]
        let title: String

        var count: Int { memoIDs.count }
    }

    static func markers(
        from memos: [ActionMemo],
        in span: TimeSpan,
        visibleDuration: TimeInterval
    ) -> [Marker] {
        let interval = clusterInterval(visibleDuration: visibleDuration)
        let sorted = memos
            .filter { $0.occurredAt >= span.start && $0.occurredAt < span.end }
            .sorted {
                $0.occurredAt == $1.occurredAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.occurredAt < $1.occurredAt
            }
        var result: [Marker] = []
        var grouped: [ActionMemo] = []
        for memo in sorted {
            // 앞 메모와의 간격이 표식 하나 길이보다 좁으면 같은 자리를 다시
            // 칠할 뿐이므로 이어 붙인다. 눈금판 띠의 합치기 규칙과 같다.
            if let previous = grouped.last,
               memo.occurredAt.timeIntervalSince(previous.occurredAt)
                   < interval {
                grouped.append(memo)
                continue
            }
            if let marker = marker(grouped, interval: interval) {
                result.append(marker)
            }
            grouped = [memo]
        }
        if let marker = marker(grouped, interval: interval) {
            result.append(marker)
        }
        return result
    }

    /// 표식을 탭했을 때 열 메모. 표식이 덮은 구간은 반열림이라 이웃 표식의
    /// 메모를 끌어오지 않는다.
    static func memoIDs(
        in span: TimeSpan,
        from memos: [ActionMemo]
    ) -> [UUID] {
        memos
            .filter { $0.occurredAt >= span.start && $0.occurredAt < span.end }
            .sorted { $0.occurredAt < $1.occurredAt }
            .map(\.id)
    }

    /// 메모를 남길 순간. 시간표가 지금을 비추고 있으면 지금이고, 지난 기간을
    /// 펼쳐 둔 상태라면 화면 한가운데다. 어제에 남긴 메모는 어제에 남는다.
    static func entryDate(now: Date, visibleSpan: TimeSpan) -> Date {
        guard now >= visibleSpan.start, now < visibleSpan.end else {
            return visibleSpan.start
                .addingTimeInterval(visibleSpan.duration / 2)
        }
        return now
    }

    static func title(count: Int, firstText: String) -> String {
        count <= 1
            ? firstText.trimmingCharacters(in: .whitespacesAndNewlines)
            : "메모 \(count)개"
    }

    private static func marker(
        _ memos: [ActionMemo],
        interval: TimeInterval
    ) -> Marker? {
        guard let first = memos.first, let last = memos.last else {
            return nil
        }
        return Marker(
            id: first.id,
            span: TimeSpan(
                start: first.occurredAt,
                end: last.occurredAt.addingTimeInterval(interval)
            ),
            memoIDs: memos.map(\.id),
            title: title(count: memos.count, firstText: first.text)
        )
    }
}

/// 눈금판 안쪽 띠의 조각을 만든다. 이미 받아 둔 수면 단계와 이동 구간만
/// 읽고, 건강 데이터를 새로 묻지 않는다.
enum RecordClockDetailEngine {
    /// 이보다 짧은 조각은 띠 굵기보다 얇게 그려져 보이지도 않으면서 그리는
    /// 값만 늘린다. 하루의 0.4%는 약 6분이다.
    static let minimumArcFraction: Double = 0.004

    /// 한 띠가 가질 수 있는 조각 수의 상한. 넘으면 기준을 넓혀 더 합친다.
    /// 재생 중에는 이 띠를 프레임마다 다시 그리므로 상한이 곧 예산이다.
    static let maximumArcCount = 32

    /// 수면 단계 띠. HealthKit은 같은 시각에 여러 단계를 겹쳐 보내므로
    /// 경계마다 한 단계를 골라 한 줄로 편다.
    static func sleepRing(
        sessions: [SleepSession],
        in span: TimeSpan
    ) -> RecordClockDetailRing? {
        var seen = Set<UUID>()
        var clipped: [(stage: SleepStage, span: TimeSpan)] = []
        for session in sessions {
            for segment in session.segments {
                guard seen.insert(segment.id).inserted else { continue }
                guard let visible = segment.span.intersection(with: span),
                      visible.duration > 0 else {
                    continue
                }
                clipped.append((segment.stage, visible))
            }
        }
        return ring(
            kind: .sleepStage,
            pieces: resolvedStages(clipped),
            in: span
        )
    }

    /// 이동 구간 띠. 같은 이동 수단이 이어지면 한 조각으로 붙인다.
    static func travelRing(
        segments: [TravelSegment],
        in span: TimeSpan
    ) -> RecordClockDetailRing? {
        var seen = Set<UUID>()
        var pieces: [(token: String, span: TimeSpan)] = []
        for segment in segments.sorted(by: { $0.span.start < $1.span.start }) {
            guard seen.insert(segment.id).inserted else { continue }
            guard let visible = segment.span.intersection(with: span),
                  visible.duration > 0 else {
                continue
            }
            // 겹쳐 들어온 구간도 한 줄에 그려야 하므로 앞 조각 뒤로 민다.
            let start = max(visible.start, pieces.last?.span.end ?? visible.start)
            guard start < visible.end else { continue }
            pieces.append(
                (
                    segment.mode.rawValue,
                    TimeSpan(start: start, end: visible.end)
                )
            )
        }
        return ring(kind: .travel, pieces: pieces, in: span)
    }

    /// 겹친 단계 가운데 구체적인 관측이 이긴다. 경계마다 한 단계만 남겨
    /// 띠가 서로를 가리지 않게 한다.
    private static func resolvedStages(
        _ segments: [(stage: SleepStage, span: TimeSpan)]
    ) -> [(token: String, span: TimeSpan)] {
        let boundaries = Array(
            Set(segments.flatMap { [$0.span.start, $0.span.end] })
        ).sorted()
        guard boundaries.count >= 2 else { return [] }

        var result: [(token: String, span: TimeSpan)] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            guard start < end else { continue }
            let winner = segments
                .filter { $0.span.start < end && start < $0.span.end }
                .max { $0.stage.overlapPriority < $1.stage.overlapPriority }
            guard let winner else { continue }
            result.append(
                (winner.stage.rawValue, TimeSpan(start: start, end: end))
            )
        }
        return result
    }

    private static func ring(
        kind: RecordClockDetailKind,
        pieces: [(token: String, span: TimeSpan)],
        in span: TimeSpan
    ) -> RecordClockDetailRing? {
        let total = span.duration
        guard total > 0, !pieces.isEmpty else { return nil }

        var minimum = minimumArcFraction
        var condensed = condensed(pieces, minimumDuration: minimum * total)
        while condensed.count > maximumArcCount, minimum < 0.05 {
            minimum *= 2
            condensed = self.condensed(
                pieces,
                minimumDuration: minimum * total
            )
        }
        guard !condensed.isEmpty else { return nil }

        return RecordClockDetailRing(
            id: kind.rawValue,
            kind: kind,
            arcs: condensed.enumerated().map { offset, piece in
                RecordClockDetailArc(
                    id: "\(kind.rawValue).\(offset)",
                    token: piece.token,
                    startFraction: min(
                        1,
                        piece.span.start.timeIntervalSince(span.start) / total
                    ),
                    endFraction: min(
                        1,
                        piece.span.end.timeIntervalSince(span.start) / total
                    )
                )
            }
        )
    }

    /// 눈에 띄지 않을 만큼 짧은 조각은 그리지 않고 이웃에 합친다. 화소보다
    /// 얇은 조각을 수백 개 그리면 화면이 멈춘다. 붙어 있는 이웃이 없으면
    /// 최소 길이까지만 늘려 하나로 남긴다.
    private static func condensed(
        _ pieces: [(token: String, span: TimeSpan)],
        minimumDuration: TimeInterval
    ) -> [(token: String, span: TimeSpan)] {
        var merged: [(token: String, span: TimeSpan)] = []
        for piece in pieces.sorted(by: { $0.span.start < $1.span.start }) {
            guard let last = merged.last else {
                merged.append(piece)
                continue
            }
            let gap = piece.span.start.timeIntervalSince(last.span.end)
            guard gap < minimumDuration else {
                merged.append(piece)
                continue
            }
            if last.token == piece.token
                || piece.span.duration < minimumDuration {
                merged[merged.count - 1] = (
                    last.token,
                    TimeSpan(
                        start: last.span.start,
                        end: max(last.span.end, piece.span.end)
                    )
                )
            } else if last.span.duration < minimumDuration {
                // 앞 조각이 너무 짧으면 뒤 조각이 그 자리를 이어받는다.
                merged[merged.count - 1] = (
                    piece.token,
                    TimeSpan(start: last.span.start, end: piece.span.end)
                )
            } else {
                merged.append(piece)
            }
        }

        return merged.map { piece in
            guard piece.span.duration < minimumDuration else { return piece }
            return (
                piece.token,
                TimeSpan(
                    start: piece.span.start,
                    end: piece.span.start.addingTimeInterval(minimumDuration)
                )
            )
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

    /// 안쪽 띠도 재생머리를 따라 드러난다. 아직 아무것도 지나지 않았어도
    /// 띠 자체는 남겨야 눈금판에서 줄이 사라졌다 나타나지 않는다.
    static func detailRings(
        _ rings: [RecordClockDetailRing],
        revealedThrough progress: Double?
    ) -> [RecordClockDetailRing] {
        guard let progress else { return rings }
        return rings.map { ring in
            RecordClockDetailRing(
                id: ring.id,
                kind: ring.kind,
                arcs: ring.arcs.compactMap { arc in
                    guard arc.startFraction < progress else { return nil }
                    guard arc.endFraction > progress else { return arc }
                    return RecordClockDetailArc(
                        id: arc.id,
                        token: arc.token,
                        startFraction: arc.startFraction,
                        endFraction: progress
                    )
                }
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
