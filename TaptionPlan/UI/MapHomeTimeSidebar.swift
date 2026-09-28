import SwiftUI
import UIKit

private func mapHomeWeatherSymbolColor(
    _ weather: WeatherContext,
    component: WeatherSymbolPaletteComponent
) -> Color {
    let palette = WeatherSymbolKind(symbolName: weather.symbolName).palette
    let color = component == .primary ? palette.primary : palette.secondary
    return Color(red: color.red, green: color.green, blue: color.blue)
}

enum MapHomeWeatherDisplayPolicy {
    static let forecastOpacity = 0.58
    static let pillBackgroundOpacity = 1.0

    enum PillBackgroundStyle: Equatable {
        case currentWhite
        case forecastOpaque

        var color: Color {
            switch self {
            case .currentWhite: .white
            case .forecastOpaque: .tpSurface
            }
        }
    }

    static func pillBackgroundStyle(for context: WeatherContext) -> PillBackgroundStyle {
        context.isForecast == true ? .forecastOpaque : .currentWhite
    }

    static func opacity(for context: WeatherContext) -> Double {
        context.isForecast == true ? forecastOpacity : 1
    }

    static func isComplete(_ context: WeatherContext) -> Bool {
        guard context.fetchedAt != nil,
              context.isStale != true,
              !context.condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !context.symbolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              context.temperatureCelsius.isFinite else {
            return false
        }

        if let airQuality = context.airQuality {
            guard airQuality.pm10MicrogramsPerCubicMeter.isFinite,
                  airQuality.pm25MicrogramsPerCubicMeter.isFinite,
                  !airQuality.providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
        }
        return true
    }
}

enum MapHomeTimeSidebarDragProjection {
    static func state(
        from base: MapHomeTimeSidebarNLEState,
        translation: CGFloat,
        trackHeight: CGFloat,
        maxMinute: Int,
        sensitivity: CGFloat
    ) -> MapHomeTimeSidebarNLEState {
        MapHomeTimeSidebarNLEState(
            selectedMinute: MapHomeTimeSidebarMath.minuteByDragging(
                baseMinute: base.selectedMinute,
                translation: translation,
                trackHeight: trackHeight,
                maxMinute: maxMinute,
                visibleStartMinute: base.visibleStartMinute,
                visibleDurationMinutes: base.visibleDurationMinutes,
                sensitivity: sensitivity
            ),
            visibleStartMinute: base.visibleStartMinute,
            visibleDurationMinutes: base.visibleDurationMinutes
        )
    }
}

enum MapHomeTimeSidebarViewportProjection {
    static func state(
        from base: MapHomeTimeSidebarNLEState,
        translation: CGFloat,
        trackHeight: CGFloat,
        verticalInset: CGFloat,
        maxMinute: Int,
        sensitivity: CGFloat
    ) -> MapHomeTimeSidebarNLEState {
        let delta = Int(
            (translation / max(trackHeight, 1)
                * CGFloat(base.visibleDurationMinutes)
                * max(sensitivity, 0)).rounded()
        )
        let start = min(
            max(base.visibleStartMinute + delta, 0),
            MapHomeTimeSidebarMath.fullDayMinutes - base.visibleDurationMinutes
        )
        let fixedMinute = MapHomeTimeSidebarMath.minuteByFixedPlayhead(
            trackHeight: trackHeight,
            verticalInset: verticalInset,
            maxMinute: maxMinute,
            visibleStartMinute: start,
            visibleDurationMinutes: base.visibleDurationMinutes
        )
        return MapHomeTimeSidebarNLEState(
            selectedMinute: fixedMinute,
            visibleStartMinute: start,
            visibleDurationMinutes: base.visibleDurationMinutes
        )
    }
}

enum MapHomeTimeSidebarStyle {
    static let panelBackground = Color.tpSurface.opacity(0.88)
    static let panelBorder = Color.tpLine.opacity(0.64)
    static let numericColumnBackground = Color.tpSurface.opacity(0.92)
    static let trackBackground = Color.tpBackground.opacity(0.62)
    static let handleBackground = Color.tpSurfaceCream
    static let deepPinkHex = "#D94772"
    static let handleForeground = Color(hex: deepPinkHex)
    static let handleBorder = Color(hex: deepPinkHex)
    static let handleFontSize: CGFloat = 12
    static let handleFontWeight: Font.Weight = .semibold
    static let handleFontDesign: Font.Design = .rounded
    static let handleCornerRadius: CGFloat = 18
}

enum MapHomeWeatherRailLayout {
    static let minimumItemSpacing: CGFloat = 32
    static let widgetScale: CGFloat = 0.8
    static let itemHeight: CGFloat = 28 * widgetScale

    static func scaled(_ value: CGFloat) -> CGFloat {
        value * widgetScale
    }

    static func itemWidth(railWidth: CGFloat) -> CGFloat {
        max(0, railWidth - 2) * widgetScale
    }

    static func itemCenterX(railWidth: CGFloat, itemWidth: CGFloat) -> CGFloat {
        railWidth - MapHomeWeatherRailAlignmentMath.itemTrailingInset - itemWidth / 2
    }

    static func visibleIndices(
        yPositions: [CGFloat],
        candidateIndices: [Int],
        priorityIndices: [Int],
        minimumSpacing: CGFloat = minimumItemSpacing
    ) -> Set<Int> {
        var kept: [Int] = []
        var visited = Set<Int>()
        let candidates = Set(candidateIndices)
        for index in priorityIndices + candidateIndices where
            candidates.contains(index)
                && yPositions.indices.contains(index)
                && visited.insert(index).inserted
        {
            if kept.allSatisfy({ abs(yPositions[$0] - yPositions[index]) >= minimumSpacing }) {
                kept.append(index)
            }
        }
        return Set(kept)
    }
}

enum MapHomeWeatherRailAlignmentMath {
    static let itemTrailingInset: CGFloat = 1

    static func weatherOriginX(
        weatherRailWidth: CGFloat,
        timeRailWidth _: CGFloat
    ) -> CGFloat {
        return MapHomeTimeSidebarMath.handleLaneWidth
            - weatherRailWidth
            + itemTrailingInset
            - MapHomeTimeSidebarMath.weatherDockGap
    }

}

enum MapHomeTimeSidebarHandleSide {
    case leading
    case trailing

    var allowsDrag: Bool {
        true
    }
}

struct MapHomeTimeSidebarActivity {
    let systemImage: String
    let tint: Color
    let accessibilityLabel: String
    let stickmanAction: MapHomeStickmanAction

    static func majorCategory(
        _ categoryID: String,
        accessibilityLabel: String? = nil,
        categoryColors: [String: String] = [:]
    ) -> Self {
        let category = MapHomeSidebarMajorCategory.presentation(
            for: categoryID,
            categoryColors: categoryColors
        )
        let icon = categoryID == "movement"
            ? MapHomeMovementIcon.systemImage(for: accessibilityLabel ?? category.title)
            : category.systemImage
        let title = accessibilityLabel ?? category.title
        return Self(
            systemImage: icon,
            tint: category.tint,
            accessibilityLabel: title,
            stickmanAction: MapHomeStickmanActionResolver.action(
                for: categoryID,
                label: title
            )
        )
    }
}

enum MapHomeMovementIcon {
    static func systemImage(for label: String) -> String {
        let value = label.lowercased()
        if value.contains("지하철") || value.contains("subway") || value.contains("metro") {
            return "tram.fill"
        }
        if value.contains("버스") || value.contains("bus") || value.contains("transit") {
            return "bus.fill"
        }
        if value.contains("택시") || value.contains("taxi") {
            return "car.side.fill"
        }
        if value.contains("기차") || value.contains("열차") || value.contains("train") {
            return "train.side.front.car"
        }
        if value.contains("비행기") || value.contains("항공") || value.contains("airplane") {
            return "airplane"
        }
        if value.contains("배") || value.contains("선박") || value.contains("ship") {
            return "ferry.fill"
        }
        if value.contains("자전거") || value.contains("cycling") || value.contains("bike") {
            return "bicycle"
        }
        if value.contains("자동차") || value.contains("자가용") || value.contains("차량")
            || value.contains("car") || value.contains("driving") {
            return "car.fill"
        }
        return "figure.walk.motion"
    }
}

private struct MapHomeUnconfirmedChecker: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 6
            let columns = Int(ceil(size.width / cell))
            let rows = Int(ceil(size.height / cell))
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    context.fill(
                        Path(
                            CGRect(
                                x: CGFloat(column) * cell,
                                y: CGFloat(row) * cell,
                                width: cell,
                                height: cell
                            )
                        ),
                        with: .color(.white.opacity(0.20))
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 오른쪽 시간 레일에서 공통으로 보이는 대분류 모형이다. 제목과 아이콘은
/// 단일 JSON 분류표에서, 색상은 앱 공통 팔레트에서 읽는다.
struct MapHomeSidebarMajorCategory: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let hex: String

    var tint: Color {
        Color(hex: hex)
    }

    var stickmanAction: MapHomeStickmanAction {
        MapHomeStickmanActionResolver.action(for: id, label: title)
    }

    func localizedTitle(_ language: MapHomeLanguage) -> String {
        guard language == .english else { return title }
        switch id {
        case "activity": return "Activity"
        case "work": return "Work"
        case "study": return "Study"
        case "hobby": return "Hobby"
        case "sleep": return "Sleep"
        case "movement": return "Movement"
        case "eating": return "Eating"
        case "exercise": return "Exercise"
        case "health": return "Health"
        case "unconfirmed": return "Unconfirmed"
        default: return title
        }
    }

    static var all: [Self] {
        all(categoryColors: [:])
    }

    static func custom(_ category: MapUserActivityCategory) -> Self {
        Self(
            id: "custom:\(category.id.uuidString)",
            title: category.title,
            systemImage: category.systemImage,
            hex: category.hex
        )
    }

    static func all(categoryColors: [String: String] = [:]) -> [Self] {
        let catalog = Dictionary(
            uniqueKeysWithValues: RecordClassificationCatalog.categories.map {
                ($0.id, $0)
            }
        )
        return CanonicalCategoryPalette.orderedIDs.compactMap { id in
            guard let category = catalog[id] else { return nil }
            return Self(
                id: category.id,
                title: category.title,
                systemImage: category.systemImage,
                hex: categoryColors[category.id]
                    ?? MapHomePastelPalette.hex(category.id)
            )
        }
    }

    static func presentation(
        for categoryID: String,
        categoryColors: [String: String] = [:]
    ) -> Self {
        let values = all(categoryColors: categoryColors)
        return values.first { $0.id == categoryID }
            ?? values.first { $0.id == "activity" }
            ?? Self(
                id: "activity",
                title: "활동",
                systemImage: "sparkles",
                hex: categoryColors["activity"]
                    ?? MapHomePastelPalette.hex("activity")
            )
    }
}

/// A single, clipped automatic-record interval on the right-hand time rail.
/// Intervals use a half-open minute range so adjacent records never overlap.
struct MapHomeTimeRailSegment: Identifiable, Hashable {
    let id: String
    let startMinute: Int
    let endMinute: Int
    let categoryID: String
    let title: String
    let behavior: String?
    let sourceIDs: [UUID]

    var sourceID: UUID? { sourceIDs.first }

    init(
        startMinute: Int,
        endMinute: Int,
        categoryID: String,
        title: String,
        behavior: String? = nil,
        sourceID: UUID? = nil,
        sourceIDs: [UUID] = []
    ) {
        self.startMinute = min(max(startMinute, 0), 1_440)
        self.endMinute = min(max(endMinute, 0), 1_440)
        self.categoryID = CanonicalCategoryPalette.orderedIDs.contains(categoryID)
            ? categoryID
            : "activity"
        self.title = title
        self.behavior = behavior
        self.sourceIDs = Array(
            Set(sourceIDs + (sourceID.map { [$0] } ?? []))
        ).sorted { $0.uuidString < $1.uuidString }
        id = [
            String(self.startMinute),
            String(self.endMinute),
            self.categoryID,
            self.behavior ?? "none",
            self.sourceIDs.map(\.uuidString).joined(separator: ","),
        ].joined(separator: "-")
    }

    static let wholeDayUnconfirmed = MapHomeTimeRailSegment(
        startMinute: 0,
        endMinute: 1_440,
        categoryID: "unconfirmed",
        title: "미확인"
    )
}

enum MapHomeUnconfirmedReviewPolicy {
    static func recentDates(asOf now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0...7).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
    }

    static func segments(
        from segments: [MapHomeTimeRailSegment],
        for date: Date,
        asOf now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MapHomeTimeRailSegment] {
        let dayStart = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        guard dayStart <= today else { return [] }
        let latestMinute = dayStart == today
            ? min(1_440, max(0, Int(now.timeIntervalSince(dayStart) / 60)))
            : 1_440
        return segments
            .filter { $0.categoryID == "unconfirmed" && $0.startMinute < latestMinute }
            .map {
                MapHomeTimeRailSegment(
                    startMinute: $0.startMinute,
                    endMinute: min($0.endMinute, latestMinute),
                    categoryID: $0.categoryID,
                    title: $0.title,
                    behavior: $0.behavior,
                    sourceIDs: $0.sourceIDs
                )
            }
            .filter { $0.startMinute < $0.endMinute }
            .sorted {
                $0.startMinute == $1.startMinute
                    ? $0.endMinute < $1.endMinute
                    : $0.startMinute < $1.startMinute
            }
    }

    static func reviewTargets(
        from segments: [MapHomeTimeRailSegment],
        focusingOn focusedSegment: MapHomeTimeRailSegment?,
        for date: Date,
        asOf now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MapHomeTimeRailSegment] {
        let candidates = focusedSegment.map { [$0] } ?? segments
        return Self.segments(
            from: candidates,
            for: date,
            asOf: now,
            calendar: calendar
        )
    }

    static func visibleReviewTargets(
        from segments: [MapHomeTimeRailSegment],
        in window: ClosedRange<Int>,
        for date: Date,
        asOf now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MapHomeTimeRailSegment] {
        reviewTargets(
            from: segments,
            focusingOn: nil,
            for: date,
            asOf: now,
            calendar: calendar
        ).filter {
            max($0.startMinute, window.lowerBound)
                < min($0.endMinute, window.upperBound)
        }
    }

    static func hasSegments(
        from segments: [MapHomeTimeRailSegment],
        for date: Date,
        asOf now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        let dayStart = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        guard dayStart <= today else { return false }
        let latestMinute = dayStart == today
            ? min(1_440, max(0, Int(now.timeIntervalSince(dayStart) / 60)))
            : 1_440
        return segments.contains {
            $0.categoryID == "unconfirmed"
                && $0.startMinute < min($0.endMinute, latestMinute)
        }
    }

    static func midpointMinute(for segment: MapHomeTimeRailSegment) -> Int {
        (segment.startMinute + segment.endMinute) / 2
    }
}

/// Keeps the rail input immutable while a gesture is rendering. A prefix
/// maximum-end index avoids scanning off-screen records for every frame while
/// retaining long intervals that overlap the visible window.
struct MapHomeTimeSidebarRailSnapshot: Equatable, Sendable {
    private let segments: [MapHomeTimeRailSegment]
    private let maximumEnds: [Int]

    init(_ segments: [MapHomeTimeRailSegment]) {
        let normalized = segments.sorted {
            if $0.startMinute != $1.startMinute {
                return $0.startMinute < $1.startMinute
            }
            if $0.endMinute != $1.endMinute {
                return $0.endMinute < $1.endMinute
            }
            return $0.id < $1.id
        }
        self.segments = normalized
        var maximumEnd = 0
        self.maximumEnds = normalized.map {
            maximumEnd = max(maximumEnd, $0.endMinute)
            return maximumEnd
        }
    }

    func visibleSegments(in window: ClosedRange<Int>) -> [MapHomeTimeRailSegment] {
        guard !segments.isEmpty else { return [] }
        var index = firstPotentialIndex(after: window.lowerBound)

        var visible: [MapHomeTimeRailSegment] = []
        while index < segments.count {
            let segment = segments[index]
            guard segment.startMinute < window.upperBound else { break }
            if segment.endMinute > window.lowerBound {
                visible.append(segment)
            }
            index += 1
        }
        return visible
    }

    private func firstPotentialIndex(after minute: Int) -> Int {
        var lower = 0
        var upper = maximumEnds.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if maximumEnds[middle] > minute {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }
}

/// Produces one winning automatic category for every minute in a day.  It
/// derives a presentation copy only; source records remain untouched.
enum MapHomeTimeRailSegmentEngine {
    private struct SegmentAccumulator {
        let startMinute: Int
        var endMinute: Int
        let categoryID: String
        let title: String
        let behavior: String?
        let mergeKey: String
        var sourceIDs: Set<UUID>

        init(_ segment: MapHomeTimeRailSegment) {
            startMinute = segment.startMinute
            endMinute = segment.endMinute
            categoryID = segment.categoryID
            title = segment.title
            behavior = segment.behavior
            mergeKey = MapHomeTimeRailSegmentEngine.mergeKey(for: segment)
            sourceIDs = Set(segment.sourceIDs)
        }

        mutating func append(_ segment: MapHomeTimeRailSegment) {
            endMinute = segment.endMinute
            sourceIDs.formUnion(segment.sourceIDs)
        }

        func segment() -> MapHomeTimeRailSegment {
            MapHomeTimeRailSegment(
                startMinute: startMinute,
                endMinute: endMinute,
                categoryID: categoryID,
                title: title,
                behavior: behavior,
                sourceIDs: Array(sourceIDs)
            )
        }
    }

    private struct Candidate {
        let startMinute: Int
        let endMinute: Int
        let categoryID: String
        let title: String
        let sourceID: UUID?
        let behavior: String?
        let phasePrecedence: Int
        let isUserOverride: Bool
        let isConfirmed: Bool
        let confidence: ConfidenceLevel
        let sourceRank: Int
        let startedAt: Date
        let createdAt: Date
        let tieBreaker: String
    }

    static func segments(
        from actuals: [ActualRecord],
        on date: Date,
        asOf: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MapHomeTimeRailSegment] {
        makeSegments(
            actuals: actuals,
            travel: [],
            on: date,
            asOf: asOf,
            calendar: calendar
        )
    }

    /// Builds the same rail from automatic records plus inferred travel. The
    /// overload keeps existing callers source-compatible while letting the
    /// map show persisted subway/bus segments that have no ActualRecord.
    static func segments(
        from actuals: [ActualRecord],
        travel: [TravelSegment],
        on date: Date,
        asOf: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MapHomeTimeRailSegment] {
        makeSegments(
            actuals: actuals,
            travel: travel,
            on: date,
            asOf: asOf,
            calendar: calendar
        )
    }

    private static func makeSegments(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        on date: Date,
        asOf: Date,
        calendar: Calendar
    ) -> [MapHomeTimeRailSegment] {
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
        else { return [.wholeDayUnconfirmed] }
        let day = TimeSpan(start: dayStart, end: dayEnd)
        let automaticActuals = AutomaticRecordTimelineEngine.activities(
            from: actuals,
            inside: day,
            asOf: asOf
        )
        let displayOverrides = actuals.filter {
            $0.source == .manual
                && $0.manuallyCorrected
                && $0.span(asOf: asOf).intersection(with: day) != nil
        }
        let actualCandidates = (automaticActuals + displayOverrides).compactMap { actual -> Candidate? in
            candidate(
                start: actual.span(asOf: asOf).start,
                end: actual.span(asOf: asOf).end,
                dayStart: dayStart,
                dayEnd: dayEnd,
                categoryID: RecordAnalysisCategoryPolicy.categoryID(for: actual),
                title: title(for: actual),
                sourceID: actual.id,
                behavior: movementBehavior(for: actual),
                phasePrecedence: RecordAnalysisCategoryPolicy.phase(
                    for: RecordAnalysisCategoryPolicy.categoryID(for: actual)
                ).precedence,
                isUserOverride: actual.source == .manual
                    && actual.manuallyCorrected,
                isConfirmed: actual.manuallyCorrected,
                confidence: actual.confidence,
                sourceRank: sourceRank(actual.source),
                startedAt: actual.startedAt,
                createdAt: actual.createdAt,
                tieBreaker: actual.id.uuidString
            )
        }
        let travelCandidates = travel.compactMap { segment -> Candidate? in
            candidate(
                start: segment.span.start,
                end: segment.span.end,
                dayStart: dayStart,
                dayEnd: dayEnd,
                categoryID: "movement",
                title: title(for: segment),
                sourceID: segment.id,
                behavior: segment.mode.rawValue,
                phasePrecedence: RecordAnalysisCategoryPolicy.phase(
                    for: "movement"
                ).precedence,
                isUserOverride: false,
                isConfirmed: segment.isConfirmed,
                confidence: segment.confidence,
                sourceRank: 8,
                startedAt: segment.span.start,
                createdAt: segment.span.start,
                tieBreaker: segment.id.uuidString
            )
        }
        let candidates = actualCandidates + travelCandidates

        let boundaries = Set(
            candidates.flatMap { [$0.startMinute, $0.endMinute] } + [0, 1_440]
        ).sorted()
        var startsByMinute = Array(repeating: [Int](), count: 1_441)
        for (index, candidate) in candidates.enumerated() {
            startsByMinute[candidate.startMinute].append(index)
        }
        var active: [Int] = []
        var result: [SegmentAccumulator] = []

        for (start, end) in zip(boundaries, boundaries.dropFirst()) where start < end {
            for candidateIndex in startsByMinute[start] {
                push(candidateIndex, into: &active, candidates: candidates)
            }
            while let candidateIndex = active.first,
                  candidates[candidateIndex].endMinute <= start {
                popHighest(from: &active, candidates: candidates)
            }
            let winner = active.first.map { candidates[$0] }
            let next = MapHomeTimeRailSegment(
                startMinute: start,
                endMinute: end,
                categoryID: winner?.categoryID ?? "unconfirmed",
                title: winner?.title ?? "미확인",
                behavior: winner?.behavior,
                sourceID: winner?.sourceID
            )
            append(next, to: &result)
        }
        let segments = result.map { $0.segment() }
        return segments.isEmpty ? [.wholeDayUnconfirmed] : segments
    }

    private static func candidate(
        start: Date,
        end: Date,
        dayStart: Date,
        dayEnd: Date,
        categoryID: String,
        title: String,
        sourceID: UUID,
        behavior: String?,
        phasePrecedence: Int,
        isUserOverride: Bool,
        isConfirmed: Bool,
        confidence: ConfidenceLevel,
        sourceRank: Int,
        startedAt: Date,
        createdAt: Date,
        tieBreaker: String
    ) -> Candidate? {
        let clippedStart = max(start, dayStart)
        let clippedEnd = min(end, dayEnd)
        guard clippedStart < clippedEnd else { return nil }
        let startMinute = minute(
            for: clippedStart,
            relativeTo: dayStart,
            rounding: .down
        )
        let endMinute = minute(
            for: clippedEnd,
            relativeTo: dayStart,
            rounding: .up
        )
        guard startMinute < endMinute else { return nil }
        return Candidate(
            startMinute: startMinute,
            endMinute: endMinute,
            categoryID: categoryID,
            title: title,
            sourceID: sourceID,
            behavior: behavior,
            phasePrecedence: phasePrecedence,
            isUserOverride: isUserOverride,
            isConfirmed: isConfirmed,
            confidence: confidence,
            sourceRank: sourceRank,
            startedAt: startedAt,
            createdAt: createdAt,
            tieBreaker: tieBreaker
        )
    }

    private static func title(for actual: ActualRecord) -> String {
        let categoryID = RecordAnalysisCategoryPolicy.categoryID(for: actual)
        return categoryID == "movement"
            ? MovementPresentation.title(for: actual)
            : actual.title
    }

    private static func title(for segment: TravelSegment) -> String {
        "\(MovementPresentation.title(for: segment.mode)) 탑승"
    }

    private static func movementBehavior(for actual: ActualRecord) -> String? {
        guard RecordAnalysisCategoryPolicy.categoryID(for: actual) == "movement"
        else { return actual.behavior }
        return MovementPresentation.mode(for: actual)?.rawValue
            ?? actual.behavior
            ?? actual.title
    }

    static func segment(
        at minute: Int,
        in segments: [MapHomeTimeRailSegment]
    ) -> MapHomeTimeRailSegment? {
        let resolved = min(max(minute, 0), 1_439)
        return segments.first {
            $0.startMinute <= resolved && resolved < $0.endMinute
        }
    }

    private static func minute(
        for date: Date,
        relativeTo dayStart: Date,
        rounding: FloatingPointRoundingRule
    ) -> Int {
        let raw = date.timeIntervalSince(dayStart) / 60
        return min(1_440, max(0, Int(raw.rounded(rounding))))
    }

    private static func append(
        _ segment: MapHomeTimeRailSegment,
        to result: inout [SegmentAccumulator]
    ) {
        if let previous = result.last,
           previous.endMinute == segment.startMinute,
           previous.mergeKey == mergeKey(for: segment) {
            result[result.count - 1].append(segment)
        } else {
            result.append(SegmentAccumulator(segment))
        }
    }

    private static func mergeKey(
        for segment: MapHomeTimeRailSegment
    ) -> String {
        switch segment.categoryID {
        case "movement":
            return "movement:\(segment.behavior ?? segment.title)"
        case "activity" where segment.behavior == nil:
            return "activity:\(segment.title.lowercased())"
        default:
            return segment.categoryID
        }
    }

    private static func isHigherPriority(
        _ lhs: Candidate,
        than rhs: Candidate
    ) -> Bool {
        if lhs.isUserOverride != rhs.isUserOverride {
            return lhs.isUserOverride
        }
        if lhs.isConfirmed != rhs.isConfirmed {
            return lhs.isConfirmed
        }
        if lhs.phasePrecedence != rhs.phasePrecedence {
            return lhs.phasePrecedence > rhs.phasePrecedence
        }
        let lhsConfidence = confidenceRank(lhs.confidence)
        let rhsConfidence = confidenceRank(rhs.confidence)
        if lhsConfidence != rhsConfidence { return lhsConfidence > rhsConfidence }
        if lhs.sourceRank != rhs.sourceRank {
            return lhs.sourceRank > rhs.sourceRank
        }
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt > rhs.startedAt
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.tieBreaker > rhs.tieBreaker
    }

    private static func isHigherPriority(
        _ lhs: Int,
        than rhs: Int,
        candidates: [Candidate]
    ) -> Bool {
        let left = candidates[lhs]
        let right = candidates[rhs]
        if isHigherPriority(left, than: right) { return true }
        if isHigherPriority(right, than: left) { return false }
        return lhs < rhs
    }

    private static func push(
        _ candidateIndex: Int,
        into heap: inout [Int],
        candidates: [Candidate]
    ) {
        heap.append(candidateIndex)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard isHigherPriority(
                heap[child],
                than: heap[parent],
                candidates: candidates
            ) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private static func popHighest(
        from heap: inout [Int],
        candidates: [Candidate]
    ) {
        guard !heap.isEmpty else { return }
        guard heap.count > 1 else {
            heap.removeLast()
            return
        }
        heap[0] = heap.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else { return }
            let right = left + 1
            let child = right < heap.count
                && isHigherPriority(
                    heap[right],
                    than: heap[left],
                    candidates: candidates
                )
                ? right
                : left
            guard isHigherPriority(
                heap[child],
                than: heap[parent],
                candidates: candidates
            ) else { return }
            heap.swapAt(parent, child)
            parent = child
        }
    }

    private static func confidenceRank(_ confidence: ConfidenceLevel) -> Int {
        switch confidence {
        case .high: 3
        case .medium: 2
        case .low: 1
        }
    }

    private static func sourceRank(_ source: ActualSource) -> Int {
        switch source {
        case .healthKit: 7
        case .appleWatch: 6
        case .location: 5
        case .motion: 4
        case .appUsage: 3
        case .media, .call: 2
        case .manual, .timer, .calendar, .photo: 0
        }
    }
}

/// Keeps high-frequency handle input independent from the rendered sidebar
/// state. The edge offset is calculated from elapsed time, not touch-event
/// count, so a 240 Hz stream cannot speed up automatic scrolling.
final class MapHomeTimeSidebarHandleDrag {
    private var baseState: MapHomeTimeSidebarNLEState?
    private var accumulatedEdgePoints: CGFloat = 0
    private var lastUptime: TimeInterval = 0

    func begin(
        with state: MapHomeTimeSidebarNLEState,
        nowUptime: TimeInterval
    ) {
        baseState = state
        accumulatedEdgePoints = 0
        lastUptime = nowUptime
    }

    func projectedState(
        locationY: CGFloat,
        trackHeight: CGFloat,
        verticalInset: CGFloat,
        maxMinute: Int,
        interactionMaxMinute: Int = MapHomeTimeSidebarMath.fullDayMinutes,
        nowUptime: TimeInterval
    ) -> MapHomeTimeSidebarNLEState? {
        guard let baseState, trackHeight > 0 else { return nil }

        let selectionMaxMinute = min(
            max(maxMinute, 0),
            MapHomeTimeSidebarMath.fullDayMinutes
        )
        let inputMaxMinute = min(
            max(interactionMaxMinute, selectionMaxMinute),
            MapHomeTimeSidebarMath.fullDayMinutes
        )

        let duration = min(
            max(baseState.visibleDurationMinutes, 60),
            MapHomeTimeSidebarMath.fullDayMinutes
        )
        let rawHandleY = locationY - verticalInset
        let edgeDirection: CGFloat
        if rawHandleY <= 0 {
            edgeDirection = -1
        } else if rawHandleY >= trackHeight {
            edgeDirection = 1
        } else {
            edgeDirection = 0
        }

        let elapsed = min(max(nowUptime - lastUptime, 0), 1.0 / 30.0)
        lastUptime = nowUptime
        accumulatedEdgePoints += edgeDirection
            * MapHomeTimeSidebarMath.edgeScrollPointsPerSecond
            * elapsed

        // Do not let a same-day rail auto-scroll past the selectable now
        // boundary. Without this clamp, dragging at the lower edge could
        // keep advancing through future blank minutes and look like an
        // accelerated sidebar scroll.
        let maximumStart = min(
            MapHomeTimeSidebarMath.maximumVisibleStart(
                durationMinutes: duration
            ),
            max(0, maxMinute - duration)
        )
        let pointsPerMinute = trackHeight / CGFloat(duration)
        let minimumOffset = CGFloat(-baseState.visibleStartMinute) * pointsPerMinute
        let maximumOffset = CGFloat(maximumStart - baseState.visibleStartMinute)
            * pointsPerMinute
        accumulatedEdgePoints = min(
            max(accumulatedEdgePoints, minimumOffset),
            maximumOffset
        )
        let edgeMinutes = Int(
            (accumulatedEdgePoints / trackHeight * CGFloat(duration)).rounded()
        )
        let localY = min(max(rawHandleY, 0), trackHeight)
        let localMinute = min(
            inputMaxMinute,
            baseState.visibleStartMinute + Int(
                (localY / trackHeight * CGFloat(duration)).rounded()
            )
        )

        return MapHomeTimeSidebarNLEState(
            selectedMinute: min(
                max(localMinute + edgeMinutes, 0),
                selectionMaxMinute
            ),
            visibleStartMinute: min(
                max(baseState.visibleStartMinute + edgeMinutes, 0),
                maximumStart
            ),
            visibleDurationMinutes: duration
        )
    }

    func reset() {
        baseState = nil
        accumulatedEdgePoints = 0
        lastUptime = 0
    }
}

/// A narrow, playhead-centered time rail for the map home screen.
struct MapHomeTimeSidebar: View {
    let date: Date
    @Binding var selectedMinute: Int
    let activity: MapHomeTimeSidebarActivity?
    let segments: [MapHomeTimeRailSegment]
    let categoryColors: [String: String]
    let zoomResetToken: Int
    let zoomStepToken: Int
    let maximumSelectableMinute: Int?
    var onViewportChanged: ((Int, Int) -> Void)?
    var onInteractionChanged: ((Bool) -> Void)?
    var onSectionEdit: ((Int) -> Void)?
    var onUnconfirmedReview: ((MapHomeTimeRailSegment) -> Void)?

    @State private var visibleDurationMinutes = MapHomeTimeSidebarMath.fullDayMinutes
    @State private var visibleStartMinute = 0
    @State private var dragStartMinute: Int?
    @State private var viewportDragStartMinute: Int?
    @State private var gestureBaseState: MapHomeTimeSidebarNLEState?
    @State private var isHandleDragging = false
    @State private var nleProjection = TimelineNLEProjection<MapHomeTimeSidebarNLEState>()
    @State private var handleDrag = MapHomeTimeSidebarHandleDrag()
    @State private var railSnapshot: MapHomeTimeSidebarRailSnapshot
    @State private var pendingRailSegments: [MapHomeTimeRailSegment]?
    @State private var pinchStepOffset = 0
    @State private var lastPinchRenderUptime: TimeInterval = 0

    private let railWidth: CGFloat
    private let trailingInteractionWidth: CGFloat
    // Keep the numeric rail visibly separated from both the map header and
    // the bottom ad boundary while preserving the same minute-to-pixel scale.
    private let verticalInset = MapHomeTimeSidebarMath.verticalInset
    private let activeRailWidth = MapHomeTimeSidebarMath.activeRailWidth
    // Reserve the leading tick length inside the numeric gutter so labels do
    // not sit on top of ruler marks at the tighter zoom steps.
    private let numericColumnWidth = MapHomeTimeSidebarMath.rulerNumericColumnWidth
    private let rulerTickWidth = MapHomeTimeSidebarMath.rulerTickWidth

    private var totalWidth: CGFloat {
        MapHomeTimeSidebarMath.totalWidth(railWidth: railWidth)
    }

    private var interactionWidth: CGFloat {
        MapHomeTimeSidebarMath.interactionWidth(
            railWidth: railWidth,
            trailingInteractionWidth: trailingInteractionWidth
        )
    }

    init(
        date: Date,
        selectedMinute: Binding<Int>,
        activity: MapHomeTimeSidebarActivity? = nil,
        segments: [MapHomeTimeRailSegment] = [],
        categoryColors: [String: String] = [:],
        zoomResetToken: Int = 0,
        zoomStepToken: Int = 0,
        railWidth: CGFloat = 44,
        maximumSelectableMinute: Int? = nil,
        trailingInteractionWidth: CGFloat = 0,
        onViewportChanged: ((Int, Int) -> Void)? = nil,
        onInteractionChanged: ((Bool) -> Void)? = nil,
        onSectionEdit: ((Int) -> Void)? = nil,
        onUnconfirmedReview: ((MapHomeTimeRailSegment) -> Void)? = nil
    ) {
        self.date = date
        self._selectedMinute = selectedMinute
        self.activity = activity
        self.segments = segments
        self.categoryColors = categoryColors
        self.zoomResetToken = zoomResetToken
        self.zoomStepToken = zoomStepToken
        self.railWidth = max(44, railWidth)
        self.maximumSelectableMinute = maximumSelectableMinute
        self.trailingInteractionWidth = max(0, trailingInteractionWidth)
        self.onViewportChanged = onViewportChanged
        self.onInteractionChanged = onInteractionChanged
        self.onSectionEdit = onSectionEdit
        self.onUnconfirmedReview = onUnconfirmedReview
        self._railSnapshot = State(
            initialValue: MapHomeTimeSidebarRailSnapshot(segments)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let railHeight = max(220, proxy.size.height)
            let trackHeight = max(1, railHeight - verticalInset * 2)
            let maxMinute = maximumSelectableMinute
                ?? MapHomeTimeSidebarMath.maximumSelectableMinute(
                    for: date,
                    now: Date()
                )
            let minute = min(max(selectedMinute, 0), maxMinute)
            let visibleWindow = MapHomeTimeSidebarMath.visibleWindow(
                startMinute: visibleStartMinute,
                durationMinutes: visibleDurationMinutes,
                centerMinute: minute
            )
            let visibleSegments = railSnapshot.visibleSegments(in: visibleWindow)
            let reviewableVisibleSegments =
                MapHomeUnconfirmedReviewPolicy.visibleReviewTargets(
                    from: segments,
                    in: visibleWindow,
                    for: date
                )
            let reviewMarkerCenters =
                MapHomeTimeSidebarMath.unconfirmedReviewMarkerCenters(
                    segments: reviewableVisibleSegments,
                    window: visibleWindow,
                    trackHeight: trackHeight,
                    verticalInset: verticalInset
                )
            let selectedY = isViewportInteraction
                ? verticalInset + trackHeight / 2
                : verticalInset + trackHeight * MapHomeTimeSidebarMath.position(
                    minute: minute,
                    window: visibleWindow
                )
            let railOriginX = MapHomeTimeSidebarMath.handleLaneWidth
            let trackX = MapHomeTimeSidebarMath.trackCenterX(
                railOriginX: railOriginX,
                railWidth: railWidth,
                numericColumnWidth: numericColumnWidth,
                activeRailWidth: activeRailWidth
            )

            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(MapHomeTimeSidebarStyle.panelBackground)
                        .frame(width: railWidth, height: railHeight)
                        .position(
                            x: railOriginX + railWidth / 2,
                            y: railHeight / 2
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(MapHomeTimeSidebarStyle.panelBorder, lineWidth: 1)
                                .frame(width: railWidth, height: railHeight)
                                .position(
                                    x: railOriginX + railWidth / 2,
                                    y: railHeight / 2
                                )
                        }
                        .shadow(color: .black.opacity(0.05), radius: 7, y: 2)
                        .allowsHitTesting(false)

                    Rectangle()
                        .fill(.clear)
                        .frame(width: railWidth, height: railHeight)
                        .contentShape(Rectangle())
                        .position(
                            x: railOriginX + railWidth / 2,
                            y: railHeight / 2
                        )
                        .gesture(
                            timeTapGesture(
                                trackHeight: trackHeight,
                                maxMinute: maxMinute,
                                visibleWindow: visibleWindow
                            )
                        )
                        .simultaneousGesture(viewportDragGesture(trackHeight: trackHeight))
                        .simultaneousGesture(timelineMagnificationGesture)

                    Rectangle()
                    .fill(MapHomeTimeSidebarStyle.numericColumnBackground)
                    // Keep the existing white numeric gutter continuous past
                    // both ends of the coloured rail.
                    .frame(width: numericColumnWidth + 3, height: railHeight)
                    .position(
                        x: railOriginX
                            + railWidth
                            - (numericColumnWidth + 3) / 2,
                        y: railHeight / 2
                    )
                    .allowsHitTesting(false)

                    ZStack {
                    Rectangle()
                        .fill(MapHomeTimeSidebarStyle.trackBackground)

                    ForEach(visibleSegments) { segment in
                        let start = max(min(segment.startMinute, visibleWindow.upperBound), visibleWindow.lowerBound)
                        let end = min(max(segment.endMinute, visibleWindow.lowerBound), visibleWindow.upperBound)
                        if start < end {
                            Rectangle()
                                .fill(
                                    Color(hex: categoryColorHex(
                                        segment.categoryID
                                    )).opacity(
                                        segment.categoryID == "unconfirmed"
                                            ? 0.50
                                            : 0.94
                                    )
                                )
                                .overlay {
                                    if segment.categoryID == "unconfirmed" {
                                        MapHomeUnconfirmedChecker()
                                    }
                                }
                                .frame(
                                    width: activeRailWidth,
                                    height: max(
                                        1,
                                        trackHeight * MapHomeTimeSidebarMath.spanFraction(
                                            start: start,
                                            end: end,
                                            window: visibleWindow
                                        )
                                    )
                                )
                                .position(
                                    x: activeRailWidth / 2,
                                        y: trackHeight * MapHomeTimeSidebarMath.position(
                                            minute: (start + end) / 2,
                                            window: visibleWindow
                                        )
                                )
                        }
                    }
                }
                .frame(width: activeRailWidth, height: trackHeight)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .position(
                    x: trackX,
                    y: verticalInset + trackHeight / 2
                )
                .allowsHitTesting(false)

                    if MapHomeTimeSidebarMath.showsTenMinuteRuler(
                    durationMinutes: visibleDurationMinutes
                ) {
                    let showsMinuteTicks = MapHomeTimeSidebarMath.showsMinuteTicks(
                        durationMinutes: visibleDurationMinutes
                    )
                    let minuteMarks = MapHomeTimeSidebarMath.visibleMinuteMarks(window: visibleWindow)
                    let rulerRows = MapHomeTimeSidebarMath.visibleRulerRows(
                        window: visibleWindow,
                        durationMinutes: visibleDurationMinutes,
                        trackHeight: trackHeight
                    )
                    let rulerFontSize = MapHomeTimeSidebarMath.rulerFontSize(
                        durationMinutes: visibleDurationMinutes
                    )
                    Canvas { context, size in
                        for minuteMark in minuteMarks {
                            guard showsMinuteTicks || minuteMark.isMultiple(of: 10) else {
                                continue
                            }
                            let isTenMinute = minuteMark.isMultiple(of: 10)
                            let y = verticalInset + trackHeight * MapHomeTimeSidebarMath.position(
                                minute: minuteMark,
                                window: visibleWindow
                            )
                            var path = Path()
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(
                                x: isTenMinute ? rulerTickWidth : rulerTickWidth / 2,
                                y: y
                            ))
                            context.stroke(
                                path,
                                with: .color(Color.tpSecondary.opacity(isTenMinute ? 0.54 : 0.22)),
                                lineWidth: 1
                            )
                        }
                    }
                    .frame(width: numericColumnWidth, height: railHeight)
                    .position(
                        x: railOriginX + railWidth - numericColumnWidth / 2,
                        y: railHeight / 2
                    )
                    .allowsHitTesting(false)

                    ForEach(rulerRows) { row in
                        let minuteMark = row.minute
                        let y = verticalInset + trackHeight * MapHomeTimeSidebarMath.position(
                            minute: minuteMark,
                            window: visibleWindow
                        )
                        Text(String(format: "%02d:%02d", minuteMark / 60, minuteMark % 60))
                        .font(.system(size: rulerFontSize, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.55)
                        .allowsTightening(true)
                        .foregroundStyle(Color.tpInk.opacity(0.78))
                        .lineLimit(1)
                        .frame(width: numericColumnWidth, alignment: .trailing)
                        .position(
                            x: MapHomeTimeSidebarMath.rulerLabelCenterX(
                                railOriginX: railOriginX,
                                railWidth: railWidth,
                                numericColumnWidth: numericColumnWidth
                            ),
                            y: y
                        )
                        .allowsHitTesting(false)
                    }
                } else {
                    let rulerFontSize = MapHomeTimeSidebarMath.rulerFontSize(
                        durationMinutes: visibleDurationMinutes
                    )
                    ForEach(
                        MapHomeTimeSidebarMath.visibleHourLabels(
                            window: visibleWindow,
                            durationMinutes: visibleDurationMinutes,
                            trackHeight: trackHeight
                        ),
                        id: \.self
                    ) { hour in
                        let y = verticalInset + trackHeight * MapHomeTimeSidebarMath.position(
                            minute: hour * 60,
                            window: visibleWindow
                        )
                        HStack(spacing: 3) {
                            Capsule()
                                .fill(Color.tpSecondary.opacity(hour.isMultiple(of: 6) ? 0.38 : 0.18))
                                .frame(width: hour.isMultiple(of: 6) ? 8 : 5, height: 1.5)
                            Text(String(format: "%02d", hour))
                                .font(.system(size: rulerFontSize, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Color.tpInk.opacity(hour.isMultiple(of: 6) ? 0.82 : 0.52))
                                .frame(width: 20, alignment: .trailing)
                                .offset(x: -MapHomeTimeSidebarMath.rulerLabelTrailingInset)
                        }
                        .frame(width: numericColumnWidth, alignment: .leading)
                        .position(
                            x: railOriginX + railWidth - numericColumnWidth / 2,
                            y: y
                        )
                        .allowsHitTesting(false)
                    }
                }

                    selectionHandle(
                        minute: minute,
                        y: selectedY,
                        trackX: trackX,
                        trackHeight: trackHeight,
                        railHeight: railHeight,
                        maxMinute: maxMinute,
                        visibleWindow: visibleWindow
                    )
                }
                .frame(
                    width: totalWidth,
                    height: railHeight,
                    alignment: .topLeading
                )
                .mask(alignment: .leading) {
                    HStack(spacing: 0) {
                        Rectangle().frame(width: railOriginX)
                        RoundedRectangle(
                            cornerRadius: 22,
                            style: .continuous
                        )
                        .frame(width: railWidth)
                        Rectangle().frame(width: trailingInteractionWidth)
                    }
                    .frame(height: railHeight)
                }

                if trailingInteractionWidth > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(
                            width: trailingInteractionWidth,
                            height: railHeight
                        )
                        .contentShape(Rectangle())
                        .position(
                            x: totalWidth + trailingInteractionWidth / 2,
                            y: railHeight / 2
                        )
                        .highPriorityGesture(
                            dragGesture(
                                trackHeight: trackHeight,
                                maxMinute: maxMinute,
                                visibleWindow: visibleWindow
                            )
                        )
                        .zIndex(3)
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                onSectionEdit?(minute)
                            }
                        )
                        .accessibilityLabel("시간 선택")
                        .accessibilityHint("화면 오른쪽 끝까지 끌어 시간을 선택합니다")
                }

                ForEach(reviewableVisibleSegments) { segment in
                    let start = max(
                        segment.startMinute,
                        visibleWindow.lowerBound
                    )
                    let end = min(segment.endMinute, visibleWindow.upperBound)
                    if start < end {
                        Button {
                            onUnconfirmedReview?(segment)
                        } label: {
                            Image(systemName: "questionmark")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.tpInk)
                                .frame(width: 26, height: 26)
                                .background(MapHomeTimeSidebarStyle.panelBackground, in: Circle())
                                .overlay(Circle().stroke(MapHomeTimeSidebarStyle.panelBorder, lineWidth: 1))
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                .frame(
                                    width: MapHomeTimeSidebarMath.reviewMarkerHitHeight,
                                    height: MapHomeTimeSidebarMath.reviewMarkerHitHeight
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "미확인 구간 \(timeLabel(for: start))–\(timeLabel(for: end)) 입력"
                        )
                        .position(
                            x: railOriginX - 16,
                            y: reviewMarkerCenters[segment.id]
                                ?? verticalInset + trackHeight
                                    * MapHomeTimeSidebarMath.position(
                                        minute: (start + end) / 2,
                                        window: visibleWindow
                                    )
                        )
                        .zIndex(4)
                    }
                }

            }
            .frame(
                width: interactionWidth,
                height: railHeight,
                alignment: .topLeading
            )
            .coordinateSpace(name: "mapHomeTimeSidebarRail")
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("시간 선택")
            .accessibilityValue(timeLabel(for: minute))
        }
        .frame(width: interactionWidth)
        .onDisappear {
            if isHandleDragging || viewportDragStartMinute != nil {
                onInteractionChanged?(false)
            }
            dragStartMinute = nil
            viewportDragStartMinute = nil
            gestureBaseState = nil
            isHandleDragging = false
            nleProjection.reset()
            handleDrag.reset()
            pendingRailSegments = nil
            pinchStepOffset = 0
            lastPinchRenderUptime = 0
        }
        .onChange(of: segments) { _, newSegments in
            if isTimelineInteractionActive {
                pendingRailSegments = newSegments
            } else {
                let snapshot = MapHomeTimeSidebarRailSnapshot(newSegments)
                guard railSnapshot != snapshot else { return }
                railSnapshot = snapshot
            }
        }
        .onChange(of: zoomResetToken) { _, _ in
            let reset = MapHomeTimeSidebarMath.resetState(
                selectedMinute: selectedMinute
            )
            if visibleDurationMinutes != reset.visibleDurationMinutes {
                visibleDurationMinutes = reset.visibleDurationMinutes
            }
            if visibleStartMinute != reset.visibleStartMinute {
                visibleStartMinute = reset.visibleStartMinute
            }
            onViewportChanged?(
                visibleStartMinute,
                visibleDurationMinutes
            )
            nleProjection.synchronize(with: nleState)
        }
        .onChange(of: zoomStepToken) { oldValue, newValue in
            let delta = newValue - oldValue
            guard delta != 0 else { return }
            let direction = delta > 0 ? 1 : -1
            for _ in 0..<abs(delta) {
                zoomTimeline(direction: direction)
            }
        }
        .onChange(of: selectedMinute) { _, _ in
            guard !isHandleDragging, viewportDragStartMinute == nil else { return }
            nleProjection.synchronize(with: nleState)
        }
    }

    private func selectionHandle(
        minute: Int,
        y: CGFloat,
        trackX: CGFloat,
        trackHeight: CGFloat,
        railHeight: CGFloat,
        maxMinute: Int,
        visibleWindow: ClosedRange<Int>
    ) -> some View {
        let handleSize = MapHomeTimeSidebarMath.handleVisualSize
        let doubleTapHitSize = MapHomeTimeSidebarMath.handleDoubleTapHitSize(
            railWidth: railWidth,
            handleHeight: handleSize.height
        )
        let handleCenterX = MapHomeTimeSidebarMath.handleCenterX(
            trackX: trackX,
            activeRailWidth: activeRailWidth
        )
        let timeBlockCenterX = MapHomeTimeSidebarMath.selectionTimeBlockCenterX(
            railWidth: railWidth,
            railOriginX: MapHomeTimeSidebarMath.handleLaneWidth,
            trackX: trackX,
            activeRailWidth: activeRailWidth
        )
        let leadingInteractionFrame = MapHomeTimeSidebarMath.selectionHandleTouchFrame(
            side: .leading,
            leadingCenterX: handleCenterX,
            trailingCenterX: timeBlockCenterX,
            leadingHitWidth: doubleTapHitSize.width,
            trailingHitWidth: MapHomeTimeSidebarMath.selectionTimeBlockHitWidth,
            totalWidth: totalWidth
        )
        let trailingInteractionFrame = MapHomeTimeSidebarMath.selectionHandleTouchFrame(
            side: .trailing,
            leadingCenterX: handleCenterX,
            trailingCenterX: timeBlockCenterX,
            leadingHitWidth: doubleTapHitSize.width,
            trailingHitWidth: MapHomeTimeSidebarMath.selectionTimeBlockHitWidth,
            totalWidth: totalWidth
        )
        let leadingHitCenterY = MapHomeTimeSidebarMath.handleHitCenterY(
            handleCenterY: y,
            railHeight: railHeight,
            hitHeight: MapHomeTimeSidebarMath.handleDragHitHeight
        )
        let trailingHitCenterY = MapHomeTimeSidebarMath.handleHitCenterY(
            handleCenterY: y,
            railHeight: railHeight,
            hitHeight: MapHomeTimeSidebarMath.trailingHandleDragHitHeight
        )
        let fallbackActivity = MapHomeTimeSidebarActivity.majorCategory(
            "unconfirmed",
            categoryColors: categoryColors
        )
        return ZStack(alignment: .topLeading) {
            Text(timeLabel(for: minute))
            .font(.system(
                size: MapHomeTimeSidebarStyle.handleFontSize,
                weight: MapHomeTimeSidebarStyle.handleFontWeight,
                design: MapHomeTimeSidebarStyle.handleFontDesign
            ))
            .monospacedDigit()
            .foregroundStyle(MapHomeTimeSidebarStyle.handleForeground)
            .frame(
                width: MapHomeTimeSidebarMath.selectionTimeBlockWidth,
                height: 36
            )
            .background(
                MapHomeTimeSidebarStyle.handleBackground,
                in: RoundedRectangle(
                    cornerRadius: MapHomeTimeSidebarStyle.handleCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: MapHomeTimeSidebarStyle.handleCornerRadius,
                    style: .continuous
                )
                .stroke(MapHomeTimeSidebarStyle.handleBorder, lineWidth: 1)
            }
            .accessibilityHidden(true)
            .zIndex(2)
            .position(
                x: timeBlockCenterX,
                y: y
            )

            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(
                    width: leadingInteractionFrame.width,
                    height: MapHomeTimeSidebarMath.handleDragHitHeight
                )
                .contentShape(Rectangle())
                .position(x: leadingInteractionFrame.midX, y: leadingHitCenterY)
                .highPriorityGesture(
                    dragGesture(
                        trackHeight: trackHeight,
                        maxMinute: maxMinute,
                        visibleWindow: visibleWindow
                    )
                )
                .zIndex(3)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        publish(minute)
                    }
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        onSectionEdit?(minute)
                    }
                )
                .accessibilityLabel(
                    activity?.accessibilityLabel ?? fallbackActivity.accessibilityLabel
                )
                .accessibilityHint("드래그하면 시간을 이동하고 두 번 탭하면 섹션 편집을 엽니다")

            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(
                    width: trailingInteractionFrame.width,
                    height: MapHomeTimeSidebarMath.trailingHandleDragHitHeight
                )
                .contentShape(Rectangle())
                .position(x: trailingInteractionFrame.midX, y: trailingHitCenterY)
                .highPriorityGesture(
                    dragGesture(
                        trackHeight: trackHeight,
                        maxMinute: maxMinute,
                        visibleWindow: visibleWindow
                    )
                )
                .zIndex(3)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        publish(minute)
                    }
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        onSectionEdit?(minute)
                    }
                )
                .accessibilityLabel(
                    activity?.accessibilityLabel ?? fallbackActivity.accessibilityLabel
                )
                .accessibilityHint("드래그하면 시간을 이동하고 두 번 탭하면 섹션 편집을 엽니다")
        }
        .frame(width: totalWidth, height: railHeight)
        .zIndex(3)
    }

    private func categoryColorHex(_ id: String) -> String {
        categoryColors[id] ?? MapHomePastelPalette.hex(id)
    }

    private func timeTapGesture(
        trackHeight: CGFloat,
        maxMinute: Int,
        visibleWindow: ClosedRange<Int>
    ) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let minute = MapHomeTimeSidebarMath.minuteByLocation(
                    y: value.location.y,
                    trackHeight: trackHeight,
                    verticalInset: verticalInset,
                    maxMinute: maxMinute,
                    visibleStartMinute: visibleWindow.lowerBound,
                    visibleDurationMinutes: visibleWindow.upperBound - visibleWindow.lowerBound
                )
                publish(minute)
            }
    }

    private func dragGesture(
        trackHeight: CGFloat,
        maxMinute: Int,
        visibleWindow: ClosedRange<Int>
    ) -> some Gesture {
        DragGesture(
            minimumDistance: MapHomeTimeSidebarMath.handleDragMinimumDistance,
            coordinateSpace: .named("mapHomeTimeSidebarRail")
        )
            .onChanged { value in
                if !isHandleDragging {
                    isHandleDragging = true
                    onInteractionChanged?(true)
                }
                if dragStartMinute == nil {
                    dragStartMinute = min(max(selectedMinute, 0), maxMinute)
                    let base = nleState
                    gestureBaseState = base
                    nleProjection.begin(with: base)
                    handleDrag.begin(
                        with: base,
                        nowUptime: ProcessInfo.processInfo.systemUptime
                    )
                }
                let nowUptime = ProcessInfo.processInfo.systemUptime
                guard let projected = handleDrag.projectedState(
                    locationY: value.location.y,
                    trackHeight: trackHeight,
                    verticalInset: verticalInset,
                    maxMinute: maxMinute,
                    nowUptime: nowUptime
                ) else { return }
                render(projected, nowUptime: nowUptime)
            }
            .onEnded { value in
                let nowUptime = ProcessInfo.processInfo.systemUptime
                if let handleProjected = handleDrag.projectedState(
                    locationY: value.location.y,
                    trackHeight: trackHeight,
                    verticalInset: verticalInset,
                    maxMinute: maxMinute,
                    nowUptime: nowUptime
                ) {
                    let projected: MapHomeTimeSidebarNLEState
                    if visibleDurationMinutes < MapHomeTimeSidebarMath.fullDayMinutes {
                        projected = MapHomeTimeSidebarNLEState(
                            selectedMinute: handleProjected.selectedMinute,
                            visibleStartMinute: MapHomeTimeSidebarMath.startMinute(
                                centerMinute: handleProjected.selectedMinute,
                                durationMinutes: handleProjected.visibleDurationMinutes
                            ),
                            visibleDurationMinutes: handleProjected.visibleDurationMinutes
                        )
                    } else {
                        projected = handleProjected
                    }
                    render(projected, nowUptime: nowUptime, force: true)
                }
                dragStartMinute = nil
                isHandleDragging = false
                gestureBaseState = nil
                handleDrag.reset()
                commitPendingRailSnapshot()
                onInteractionChanged?(false)
            }
    }

    private var isViewportInteraction: Bool {
        visibleDurationMinutes < MapHomeTimeSidebarMath.fullDayMinutes && !isHandleDragging
    }

    private func viewportDragGesture(trackHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard visibleDurationMinutes < MapHomeTimeSidebarMath.fullDayMinutes,
                      !isHandleDragging else { return }
                if viewportDragStartMinute == nil {
                    viewportDragStartMinute = visibleStartMinute
                    onInteractionChanged?(true)
                    let base = nleState
                    gestureBaseState = base
                    nleProjection.begin(with: base)
                }
                let nowUptime = ProcessInfo.processInfo.systemUptime
                let base = gestureBaseState ?? nleState
                render(
                    MapHomeTimeSidebarViewportProjection.state(
                        from: base,
                        translation: value.translation.height,
                        trackHeight: trackHeight,
                        verticalInset: verticalInset,
                        maxMinute: MapHomeTimeSidebarMath.maximumSelectableMinute(for: date, now: Date()),
                        sensitivity: MapHomeTimeSidebarMath.standardDragSensitivity
                    ),
                    nowUptime: nowUptime
                )
            }
            .onEnded { value in
                let base = gestureBaseState ?? nleState
                render(
                    MapHomeTimeSidebarViewportProjection.state(
                        from: base,
                        translation: value.translation.height,
                        trackHeight: trackHeight,
                        verticalInset: verticalInset,
                        maxMinute: MapHomeTimeSidebarMath.maximumSelectableMinute(for: date, now: Date()),
                        sensitivity: MapHomeTimeSidebarMath.standardDragSensitivity
                    ),
                    nowUptime: ProcessInfo.processInfo.systemUptime,
                    force: true
                )
                viewportDragStartMinute = nil
                gestureBaseState = nil
                commitPendingRailSnapshot()
                onInteractionChanged?(false)
            }
    }

    private func zoomTimeline(direction: Int) {
        let duration = MapHomeTimeSidebarMath.duration(
            afterZoomStep: direction,
            from: visibleDurationMinutes
        )
        guard duration != visibleDurationMinutes else { return }
        let maxMinute = MapHomeTimeSidebarMath.maximumSelectableMinute(for: date, now: Date())
        let selected = min(max(selectedMinute, 0), maxMinute)
        visibleDurationMinutes = duration
        visibleStartMinute = MapHomeTimeSidebarMath.startMinute(
            centerMinute: selected,
            durationMinutes: duration
        )
        onViewportChanged?(visibleStartMinute, visibleDurationMinutes)
        viewportDragStartMinute = nil
        nleProjection.synchronize(with: nleState)
    }

    private var timelineMagnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let offset = MapHomeTimeSidebarPinchMath.stepOffset(
                    magnification: scale
                )
                guard offset != pinchStepOffset else { return }
                guard TimelineInteractionFrameGate.shouldRender(
                    lastUptime: &lastPinchRenderUptime,
                    nowUptime: ProcessInfo.processInfo.systemUptime
                ) else { return }
                let delta = offset - pinchStepOffset
                for _ in 0..<abs(delta) {
                    zoomTimeline(direction: delta > 0 ? 1 : -1)
                }
                pinchStepOffset = offset
            }
            .onEnded { scale in
                let offset = MapHomeTimeSidebarPinchMath.stepOffset(
                    magnification: scale
                )
                let delta = offset - pinchStepOffset
                for _ in 0..<abs(delta) {
                    zoomTimeline(direction: delta > 0 ? 1 : -1)
                }
                pinchStepOffset = 0
                lastPinchRenderUptime = 0
            }
    }

    private func publish(_ minute: Int) {
        let state = MapHomeTimeSidebarNLEState(
            selectedMinute: min(
                max(minute, 0),
                MapHomeTimeSidebarMath.maximumSelectableMinute(for: date, now: Date())
            ),
            visibleStartMinute: visibleStartMinute,
            visibleDurationMinutes: visibleDurationMinutes
        )
        apply(state)
    }

    private func render(
        _ state: MapHomeTimeSidebarNLEState,
        nowUptime: TimeInterval,
        force: Bool = false
    ) {
        let rendered = force
            ? nleProjection.finish(with: state, nowUptime: nowUptime)
            : nleProjection.submit(state, nowUptime: nowUptime)
        guard let rendered else { return }
        apply(rendered)
    }

    private func apply(_ state: MapHomeTimeSidebarNLEState) {
        let viewportChanged = visibleStartMinute != state.visibleStartMinute
            || visibleDurationMinutes != state.visibleDurationMinutes
        let selectionChanged = selectedMinute != state.selectedMinute
        if viewportChanged {
            if visibleStartMinute != state.visibleStartMinute {
                visibleStartMinute = state.visibleStartMinute
            }
            if visibleDurationMinutes != state.visibleDurationMinutes {
                visibleDurationMinutes = state.visibleDurationMinutes
            }
            onViewportChanged?(state.visibleStartMinute, state.visibleDurationMinutes)
        }
        if selectionChanged {
            selectedMinute = state.selectedMinute
        }
    }

    private var isTimelineInteractionActive: Bool {
        isHandleDragging || viewportDragStartMinute != nil
    }

    private func commitPendingRailSnapshot() {
        guard !isTimelineInteractionActive,
              let pendingRailSegments else { return }
        railSnapshot = MapHomeTimeSidebarRailSnapshot(pendingRailSegments)
        self.pendingRailSegments = nil
    }

    private func draggedState(
        base: MapHomeTimeSidebarNLEState,
        translation: CGFloat,
        trackHeight: CGFloat,
        maxMinute: Int,
        sensitivity: CGFloat
    ) -> MapHomeTimeSidebarNLEState {
        MapHomeTimeSidebarDragProjection.state(
            from: base,
            translation: translation,
            trackHeight: trackHeight,
            maxMinute: maxMinute,
            sensitivity: sensitivity
        )
    }

    private var nleState: MapHomeTimeSidebarNLEState {
        MapHomeTimeSidebarNLEState(
            selectedMinute: selectedMinute,
            visibleStartMinute: visibleStartMinute,
            visibleDurationMinutes: visibleDurationMinutes
        )
    }

    private func timeLabel(for minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

}

struct MapHomeTimeRulerLabels: Equatable, Sendable {
    let hours: [Int]
    let minutes: [Int]
}

struct MapHomeTimeRulerRow: Identifiable, Equatable, Sendable {
    let minute: Int
    let hour: Int?
    let minuteComponent: Int?

    var id: Int { minute }
}

enum MapHomeUnconfirmedQuickCategoryLayout {
    static let columnCount = 4

    static func rows(
        from categories: [MapHomeSidebarMajorCategory]
    ) -> [[MapHomeSidebarMajorCategory]] {
        stride(from: 0, to: categories.count, by: columnCount).map { start in
            Array(categories[start..<min(start + columnCount, categories.count)])
        }
    }
}

struct MapHomeUnconfirmedReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let date: Date
    let segments: [MapHomeTimeRailSegment]
    let focusedSegment: MapHomeTimeRailSegment?
    let recentDates: [Date]
    let language: MapHomeLanguage
    let onDateSelect: (Date) -> Void
    let onSelect: (MapHomeTimeRailSegment) -> Void
    let onQuickConfirm: (MapHomeTimeRailSegment, MapHomeSidebarMajorCategory) async -> Bool
    @State private var savingSegmentID: String?
    @State private var saveFailedSegmentID: String?

    private var quickCategories: [MapHomeSidebarMajorCategory] {
        let ids = ["work", "study", "sleep", "eating", "movement", "exercise", "hobby", "activity"]
        let byID = Dictionary(uniqueKeysWithValues: MapHomeSidebarMajorCategory.all.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    private var quickCategoryRows: [[MapHomeSidebarMajorCategory]] {
        MapHomeUnconfirmedQuickCategoryLayout.rows(from: quickCategories)
    }

    private var unconfirmedSegments: [MapHomeTimeRailSegment] {
        MapHomeUnconfirmedReviewPolicy.reviewTargets(
            from: segments,
            focusingOn: focusedSegment,
            for: date
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !recentDates.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(recentDates, id: \.self) { day in
                                let selected = Calendar.autoupdatingCurrent.isDate(day, inSameDayAs: date)
                                Button {
                                    onDateSelect(day)
                                } label: {
                                    Text(day.formatted(.dateTime.month().day()))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(selected ? Color.white : Color.tpInk)
                                        .padding(.horizontal, 12)
                                        .frame(minHeight: 34)
                                        .background(
                                            selected ? Color.tpAccent : Color.tpSurface,
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                                .disabled(savingSegmentID != nil)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
                if !unconfirmedSegments.isEmpty {
                    Text(language.text(
                        "활동을 누르면 바로 저장됩니다. 시간을 누르면 자세히 편집할 수 있습니다.",
                        "Tap an activity to save it, or tap the time to edit details."
                    ))
                    .font(.caption)
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                }
                Group {
                    if unconfirmedSegments.isEmpty {
                        ContentUnavailableView(
                            language.text("미확인 구간이 없습니다", "No unconfirmed intervals"),
                            systemImage: "checkmark.circle",
                            description: Text(language.text(
                                "이날의 활동이 모두 확인되었습니다.",
                                "All activity for this day is confirmed."
                            ))
                        )
                    } else {
                        List(unconfirmedSegments) { segment in
                            VStack(alignment: .leading, spacing: 10) {
                                Button {
                                    onSelect(segment)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "questionmark.circle.fill")
                                            .foregroundStyle(Color.tpSecondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("\(time(segment.startMinute))–\(time(segment.endMinute))")
                                                .font(.headline.monospacedDigit())
                                                .foregroundStyle(Color.tpInk)
                                            Text(language.text(
                                                "\(duration(segment.endMinute - segment.startMinute)) 미확인",
                                                "\(duration(segment.endMinute - segment.startMinute)) unconfirmed"
                                            ))
                                            .font(.subheadline)
                                            .foregroundStyle(Color.tpSecondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Color.tpSecondary.opacity(0.7))
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint(language.text("시간을 자세히 편집합니다", "Edit this time interval"))
                                VStack(spacing: 6) {
                                    ForEach(Array(quickCategoryRows.enumerated()), id: \.offset) { _, row in
                                        HStack(spacing: 6) {
                                            ForEach(row) { category in
                                                Button {
                                                    guard savingSegmentID == nil else { return }
                                                    savingSegmentID = segment.id
                                                    saveFailedSegmentID = nil
                                                    Task { @MainActor in
                                                        let saved = await onQuickConfirm(segment, category)
                                                        if !saved {
                                                            saveFailedSegmentID = segment.id
                                                        } else if focusedSegment != nil {
                                                            dismiss()
                                                        }
                                                        savingSegmentID = nil
                                                    }
                                                } label: {
                                                    Label(category.localizedTitle(language), systemImage: category.systemImage)
                                                        .font(.system(size: 11, weight: .semibold))
                                                        .lineLimit(1)
                                                        .minimumScaleFactor(0.72)
                                                        .frame(maxWidth: .infinity, minHeight: 36)
                                                        .background(category.tint.opacity(0.18), in: Capsule())
                                                }
                                                .buttonStyle(.plain)
                                                .disabled(savingSegmentID != nil)
                                            }
                                        }
                                    }
                                }
                                if saveFailedSegmentID == segment.id {
                                    Text(language.text(
                                        "저장하지 못했습니다. 다시 시도해 주세요.",
                                        "Could not save. Please try again."
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle(language.text("미확인 활동", "Unconfirmed activity"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(language.text("닫기", "Close")) { dismiss() }
                }
            }
        }
    }

    private func time(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if language == .english {
            if hours == 0 { return "\(remainder)m" }
            return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }
        if hours == 0 { return "\(remainder)분" }
        return remainder == 0 ? "\(hours)시간" : "\(hours)시간 \(remainder)분"
    }
}

struct MapHomeWeatherSidebar: View {
    let date: Date
    let contexts: [WeatherContext]
    let selectedMinute: Int
    let language: MapHomeLanguage
    let visibleStartMinute: Int
    let visibleDurationMinutes: Int

    private let railWidth: CGFloat = 62
    private let verticalInset = MapHomeTimeSidebarMath.verticalInset

    private struct Entry: Identifiable {
        let context: WeatherContext
        let startMinute: Int
        let endMinute: Int

        var id: UUID { context.id }
    }

    var body: some View {
        GeometryReader { proxy in
            let railHeight = max(220, proxy.size.height)
            let trackHeight = max(1, railHeight - verticalInset * 2)
            let entries = weatherEntries
            let window = MapHomeTimeSidebarMath.visibleWindow(
                startMinute: visibleStartMinute,
                durationMinutes: visibleDurationMinutes,
                centerMinute: selectedMinute
            )
            let clampedSelectedMinute = min(max(selectedMinute, 0), 1_439)
            let nowComponents = Calendar.autoupdatingCurrent.dateComponents(
                [.hour, .minute],
                from: Date.now
            )
            let currentMinute = (nowComponents.hour ?? 0) * 60 + (nowComponents.minute ?? 0)
            let isToday = Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: Date.now)
            let selectedIndex = entries.firstIndex {
                clampedSelectedMinute >= $0.startMinute
                    && clampedSelectedMinute < $0.endMinute
            }
            let currentIndex = isToday ? entries.firstIndex {
                currentMinute >= $0.startMinute && currentMinute < $0.endMinute
            } : nil
            let yPositions = entries.map { entry in
                let startMinute = max(entry.startMinute, window.lowerBound)
                let endMinute = min(entry.endMinute, window.upperBound)
                let start = MapHomeTimeSidebarMath.position(minute: startMinute, window: window)
                let end = MapHomeTimeSidebarMath.position(minute: endMinute, window: window)
                return verticalInset + trackHeight * (start + end) / 2
            }
            let candidateIndices = entries.indices.filter { index in
                max(entries[index].startMinute, window.lowerBound)
                    < min(entries[index].endMinute, window.upperBound)
            }
            let visibleIndices = MapHomeWeatherRailLayout.visibleIndices(
                yPositions: yPositions,
                candidateIndices: candidateIndices,
                priorityIndices: [selectedIndex, currentIndex].compactMap { $0 }
            )
            ZStack(alignment: .topLeading) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    let startMinute = max(entry.startMinute, window.lowerBound)
                    let endMinute = min(entry.endMinute, window.upperBound)
                    let y = yPositions[index]
                    if startMinute < endMinute, visibleIndices.contains(index) {
                        let itemWidth = MapHomeWeatherRailLayout.itemWidth(
                            railWidth: railWidth
                        )
                        let isSelected = index == selectedIndex
                        let isCurrent = index == currentIndex
                        let entryMinute = min(
                            max((entry.startMinute + entry.endMinute) / 2, 0),
                            MapHomeTimeSidebarMath.fullDayMinutes
                        )

                        HStack(spacing: MapHomeWeatherRailLayout.scaled(4)) {
                            Image(systemName: entry.context.symbolName)
                                .font(.system(
                                    size: MapHomeWeatherRailLayout.scaled(13),
                                    weight: .semibold
                                ))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(
                                    mapHomeWeatherSymbolColor(entry.context, component: .primary),
                                    mapHomeWeatherSymbolColor(entry.context, component: .secondary)
                                )
                            Text("\(Int(entry.context.temperatureCelsius.rounded()))°")
                                .font(.system(
                                    size: MapHomeWeatherRailLayout.scaled(10),
                                    weight: isSelected ? .bold : .semibold,
                                    design: .rounded
                                ))
                                .monospacedDigit()
                                .foregroundStyle(isSelected || isCurrent ? Color.tpAccent : Color.tpInk)
                        }
                        .opacity(MapHomeWeatherDisplayPolicy.opacity(for: entry.context))
                        .padding(.horizontal, MapHomeWeatherRailLayout.scaled(8))
                        .frame(
                            width: itemWidth,
                            height: MapHomeWeatherRailLayout.itemHeight
                        )
                        .background(
                            MapHomeWeatherDisplayPolicy
                                .pillBackgroundStyle(for: entry.context).color
                                .opacity(MapHomeWeatherDisplayPolicy.pillBackgroundOpacity),
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .stroke(
                                    isSelected ? Color.tpPastelRose : Color.tpLine.opacity(0.8),
                                    lineWidth: MapHomeWeatherRailLayout.scaled(
                                        isSelected ? 1.2 : 0.8
                                    )
                                )
                        }
                        .shadow(
                            color: .black.opacity(0.10),
                            radius: MapHomeWeatherRailLayout.scaled(3),
                            y: MapHomeWeatherRailLayout.scaled(1)
                        )
                        .position(
                            x: MapHomeWeatherRailLayout.itemCenterX(
                                railWidth: railWidth,
                                itemWidth: itemWidth
                            ),
                            y: y
                        )
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            language.text(
                                "\(entryMinute / 60)시 날씨 \(entry.context.condition), \(Int(entry.context.temperatureCelsius.rounded()))도"
                                    + (entry.context.airQuality.map { ", 미세먼지 \($0.overallGrade.displayName)" } ?? ""),
                                "\(entryMinute / 60):00 weather: \(entry.context.condition), \(Int(entry.context.temperatureCelsius.rounded())) degrees Celsius"
                                    + (entry.context.airQuality.map { ", air quality \($0.overallGrade.displayName)" } ?? "")
                            )
                        )
                        .accessibilityValue(
                            isSelected
                                ? language.text("선택된 시간", "Selected time")
                                : entry.context.isForecast == true
                                    ? language.text(
                                        "미래 예보 · 비활성",
                                        "Future forecast · inactive"
                                    )
                                    : language.text(
                                        "관측된 날씨 · 활성",
                                        "Observed weather · active"
                                    )
                        )
                    }
                }
            }
            .frame(width: railWidth, height: railHeight)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(language.text("시간축 날씨", "Weather timeline"))
        }
        .frame(width: railWidth)
    }

    private var weatherEntries: [Entry] {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: date)
        return MapHomeWeatherTimelineMath.persistentSpans(
            for: date,
            contexts: contexts.filter(MapHomeWeatherDisplayPolicy.isComplete),
            calendar: calendar,
            minimumTemperatureChangeCelsius:
                MapHomeWeatherTimelineMath.fullDayTemperatureChangeCelsius
        ).compactMap { entry in
            let start = entry.span.start
            let end = entry.span.end
            let startMinute = min(
                max(Int(start.timeIntervalSince(dayStart) / 60), 0),
                1_439
            )
            let endMinute = min(
                max(Int(ceil(end.timeIntervalSince(dayStart) / 60)), startMinute + 1),
                1_440
            )
            return Entry(
                context: entry.context,
                startMinute: startMinute,
                endMinute: endMinute
            )
        }
    }
}

enum MapHomeTimeSidebarMath {
    static let fullDayMinutes = 1_440
    static let zoomDurations = [1_440, 720, 360, 180, 60]
    static let verticalInset: CGFloat = 20
    static let reviewMarkerHitHeight: CGFloat = 44
    static let standardDragSensitivity: CGFloat = 1.6
    static let precisionDragSensitivity: CGFloat = 0.25
    static let edgeScrollPointsPerSecond: CGFloat = 192
    static let rulerNumericColumnWidth: CGFloat = 32
    static let rulerLabelTrailingInset: CGFloat = 6
    static let rulerTickWidth: CGFloat = 6
    static let rulerHourColumnWidth: CGFloat = 12
    static let rulerMinuteColumnWidth: CGFloat = 12
    static let rulerColumnSpacing: CGFloat = 2
    static let minimumRulerLabelSpacing: CGFloat = 24
    static let selectionTimeBlockWidth: CGFloat = 44
    static let handleDoubleTapHitScale: CGFloat = 1.5
    static let selectionTimeBlockHitWidth: CGFloat =
        selectionTimeBlockWidth * handleDoubleTapHitScale
    static let handleDragMinimumDistance: CGFloat = 0
    static let handleDragHitHeight: CGFloat = 88
    static let trailingHandleDragHitHeight: CGFloat = handleDragHitHeight * 1.5
    static let handleLaneWidth: CGFloat = 69
    static let activeRailWidth: CGFloat = 7
    static let handleVisualSize = CGSize(width: 44, height: 44)
    static let handleRailGap: CGFloat = 4
    static let weatherDockGap: CGFloat = 4

    static func selectedTimeCardFrame(
        availableHeight: CGFloat,
        selectedMinute: Int,
        visibleStartMinute: Int,
        visibleDurationMinutes: Int,
        verticalInset: CGFloat = MapHomeTimeSidebarMath.verticalInset
    ) -> CGRect {
        let height = max(0, availableHeight)
        let inset = min(max(0, verticalInset), height / 2)
        let trackHeight = max(1, height - inset * 2)
        let window = visibleWindow(
            startMinute: visibleStartMinute,
            durationMinutes: visibleDurationMinutes,
            centerMinute: selectedMinute
        )
        let center = min(max(selectedMinute, 0), fullDayMinutes - 1)
        let start = max(window.lowerBound, center - 60)
        let end = min(window.upperBound, center + 60)
        let top = inset + trackHeight * position(minute: start, window: window)
        let bottom = inset + trackHeight * position(minute: end, window: window)
        return CGRect(x: 0, y: top, width: 0, height: max(1, bottom - top))
    }

    static func totalWidth(railWidth: CGFloat) -> CGFloat {
        handleLaneWidth + railWidth
    }

    static func rulerLabelCenterX(
        railOriginX: CGFloat,
        railWidth: CGFloat,
        numericColumnWidth: CGFloat,
        trailingInset: CGFloat = rulerLabelTrailingInset
    ) -> CGFloat {
        railOriginX + railWidth - numericColumnWidth / 2 - max(0, trailingInset)
    }

    static func interactionWidth(
        railWidth: CGFloat,
        trailingInteractionWidth: CGFloat = 0
    ) -> CGFloat {
        totalWidth(railWidth: railWidth) + max(0, trailingInteractionWidth)
    }

    static func trackCenterX(
        railOriginX: CGFloat,
        railWidth: CGFloat,
        numericColumnWidth: CGFloat,
        activeRailWidth: CGFloat
    ) -> CGFloat {
        railOriginX + railWidth - numericColumnWidth - activeRailWidth / 2 - 1
    }

    static func handleCenterX(
        trackX: CGFloat,
        activeRailWidth: CGFloat
    ) -> CGFloat {
        trackX - activeRailWidth / 2 - handleRailGap - handleVisualSize.width / 2
    }

    static func handleHitCenterY(
        handleCenterY: CGFloat,
        railHeight: CGFloat,
        hitHeight: CGFloat
    ) -> CGFloat {
        min(max(handleCenterY, hitHeight / 2), railHeight - hitHeight / 2)
    }

    static func handleDoubleTapHitSize(
        railWidth: CGFloat,
        handleHeight: CGFloat
    ) -> CGSize {
        CGSize(
            width: railWidth * handleDoubleTapHitScale,
            height: handleHeight * handleDoubleTapHitScale
        )
    }

    static func selectionHandleTouchFrame(
        side: MapHomeTimeSidebarHandleSide,
        leadingCenterX: CGFloat,
        trailingCenterX: CGFloat,
        leadingHitWidth: CGFloat,
        trailingHitWidth: CGFloat,
        totalWidth: CGFloat
    ) -> CGRect {
        let splitX = (leadingCenterX + trailingCenterX) / 2
        let minimumX: CGFloat
        let maximumX: CGFloat
        switch side {
        case .leading:
            minimumX = leadingCenterX - leadingHitWidth / 2
            maximumX = min(splitX, leadingCenterX + leadingHitWidth / 2)
        case .trailing:
            minimumX = max(splitX, trailingCenterX - trailingHitWidth / 2)
            maximumX = trailingCenterX + trailingHitWidth / 2
        }
        let clampedMinimumX = min(max(minimumX, 0), max(totalWidth, 1))
        let clampedMaximumX = min(max(maximumX, clampedMinimumX), max(totalWidth, 1))
        return CGRect(
            x: clampedMinimumX,
            y: 0,
            width: max(clampedMaximumX - clampedMinimumX, 1),
            height: 1
        )
    }

    static func rulerFontSize(durationMinutes: Int) -> CGFloat {
        10
    }

    static func rulerColumnWidth(durationMinutes: Int) -> CGFloat {
        min(12, max(10, ceil(rulerFontSize(durationMinutes: durationMinutes) * 1.2)))
    }

    static func minimumRulerLabelSpacing(durationMinutes: Int) -> CGFloat {
        max(
            minimumRulerLabelSpacing,
            ceil(rulerFontSize(durationMinutes: durationMinutes) + 2)
        )
    }

    static func rulerLabelsStartX(railWidth: CGFloat) -> CGFloat {
        railWidth - rulerNumericColumnWidth + rulerTickWidth
    }

    static func selectionTimeBlockCenterX(
        railWidth: CGFloat,
        railOriginX: CGFloat = 0,
        trackX: CGFloat,
        activeRailWidth: CGFloat
    ) -> CGFloat {
        let ideal = trackX + activeRailWidth / 2 + 17
        let halfWidth = selectionTimeBlockWidth / 2
        return min(
            max(ideal, railOriginX + halfWidth),
            railOriginX + railWidth - halfWidth
        )
    }

    static func duration(afterZoomStep step: Int, from durationMinutes: Int) -> Int {
        let index = zoomDurations.firstIndex(of: durationMinutes)
            ?? zoomDurations.closestIndex(to: durationMinutes)
        return zoomDurations[min(max(index + step, 0), zoomDurations.count - 1)]
    }

    static func visibleWindow(
        startMinute: Int,
        durationMinutes: Int,
        centerMinute: Int
    ) -> ClosedRange<Int> {
        let duration = min(max(durationMinutes, 60), fullDayMinutes)
        let start = min(max(startMinute, 0), fullDayMinutes - duration)
        return start...(start + duration)
    }

    static func visibleWindow(
        centerMinute: Int,
        durationMinutes: Int
    ) -> ClosedRange<Int> {
        visibleWindow(
            startMinute: startMinute(centerMinute: centerMinute, durationMinutes: durationMinutes),
            durationMinutes: durationMinutes,
            centerMinute: centerMinute
        )
    }

    static func startMinute(centerMinute: Int, durationMinutes: Int) -> Int {
        let duration = min(max(durationMinutes, 60), fullDayMinutes)
        let half = duration / 2
        let center = min(max(centerMinute, 0), fullDayMinutes)
        return min(max(center - half, 0), fullDayMinutes - duration)
    }

    static func maximumVisibleStart(durationMinutes: Int) -> Int {
        fullDayMinutes - min(max(durationMinutes, 60), fullDayMinutes)
    }

    static func resetState(selectedMinute: Int) -> MapHomeTimeSidebarNLEState {
        MapHomeTimeSidebarNLEState(
            selectedMinute: min(max(selectedMinute, 0), fullDayMinutes - 1),
            visibleStartMinute: 0,
            visibleDurationMinutes: fullDayMinutes
        )
    }

    static func position(minute: Int, window: ClosedRange<Int>) -> CGFloat {
        let span = max(window.upperBound - window.lowerBound, 1)
        return min(max(CGFloat(minute - window.lowerBound) / CGFloat(span), 0), 1)
    }

    static func unconfirmedReviewMarkerCenters(
        segments: [MapHomeTimeRailSegment],
        window: ClosedRange<Int>,
        trackHeight: CGFloat,
        verticalInset: CGFloat = MapHomeTimeSidebarMath.verticalInset,
        markerHeight: CGFloat = MapHomeTimeSidebarMath.reviewMarkerHitHeight
    ) -> [String: CGFloat] {
        let visible = segments.compactMap { segment -> (id: String, minute: Int)? in
            let start = max(segment.startMinute, window.lowerBound)
            let end = min(segment.endMinute, window.upperBound)
            guard start < end else { return nil }
            return (segment.id, (start + end) / 2)
        }
        guard !visible.isEmpty else { return [:] }

        let height = max(0, trackHeight)
        let halfMarker = min(max(0, markerHeight), height) / 2
        let lowerCenter = verticalInset + halfMarker
        let upperCenter = verticalInset + height - halfMarker
        let spacing = visible.count > 1
            ? min(max(0, markerHeight), (upperCenter - lowerCenter) / CGFloat(visible.count - 1))
            : 0
        var centers = visible.map { item in
            min(
                max(
                    verticalInset + height * position(minute: item.minute, window: window),
                    lowerCenter
                ),
                upperCenter
            )
        }

        if centers.count > 1 {
            for index in 1..<centers.count {
                centers[index] = max(centers[index], centers[index - 1] + spacing)
            }
            for index in stride(from: centers.count - 2, through: 0, by: -1) {
                centers[index] = min(centers[index], centers[index + 1] - spacing)
            }
        }

        return Dictionary(uniqueKeysWithValues: zip(visible.map(\.id), centers))
    }

    static func spanFraction(start: Int, end: Int, window: ClosedRange<Int>) -> CGFloat {
        position(minute: end, window: window) - position(minute: start, window: window)
    }

    static func visibleHours(window: ClosedRange<Int>) -> [Int] {
        let first = max(0, Int(ceil(Double(window.lowerBound) / 60)))
        let last = min(24, Int(floor(Double(window.upperBound) / 60)))
        return Array(first...max(first, last))
    }

    static func visibleHourLabels(
        window: ClosedRange<Int>,
        durationMinutes: Int,
        trackHeight: CGFloat
    ) -> [Int] {
        let hours = visibleHours(window: window)
        guard hours.count > 1 else { return hours }
        let duration = CGFloat(min(max(durationMinutes, 60), fullDayMinutes))
        let pointsPerHour = max(trackHeight, 1) * 60 / duration
        let step = max(
            1,
            Int(ceil(
                minimumRulerLabelSpacing(durationMinutes: durationMinutes)
                    / max(pointsPerHour, 1)
            ))
        )
        return hours.enumerated().compactMap { index, hour in
            index.isMultiple(of: step) || index == hours.count - 1
                ? hour
                : nil
        }
    }

    static func visibleMinuteMarks(window: ClosedRange<Int>) -> [Int] {
        let first = min(max(window.lowerBound, 0), fullDayMinutes)
        let last = min(max(window.upperBound, first), fullDayMinutes)
        return Array(first...last)
    }

    static func visibleRulerLabels(window: ClosedRange<Int>) -> MapHomeTimeRulerLabels {
        visibleRulerLabels(
            window: window,
            durationMinutes: fullDayMinutes,
            trackHeight: 1_000_000
        )
    }

    static func visibleRulerLabels(
        window: ClosedRange<Int>,
        durationMinutes: Int,
        trackHeight: CGFloat
    ) -> MapHomeTimeRulerLabels {
        let hours = visibleHourLabels(
            window: window,
            durationMinutes: durationMinutes,
            trackHeight: trackHeight
        )

        let minuteStep = minuteRulerStep(
            durationMinutes: durationMinutes,
            trackHeight: trackHeight
        )
        let firstMinute = max(
            0,
            ((window.lowerBound + minuteStep - 1) / minuteStep) * minuteStep
        )
        let lastMinute = min(
            fullDayMinutes,
            (window.upperBound / minuteStep) * minuteStep
        )
        let minutes: [Int]
        if firstMinute <= lastMinute {
            minutes = stride(from: firstMinute, through: lastMinute, by: minuteStep)
                .filter { !$0.isMultiple(of: 60) }
        } else {
            minutes = []
        }
        return MapHomeTimeRulerLabels(hours: hours, minutes: minutes)
    }

    static func minuteRulerStep(
        durationMinutes: Int,
        trackHeight: CGFloat
    ) -> Int {
        let duration = CGFloat(min(max(durationMinutes, 1), fullDayMinutes))
        let pointsPerMinute = max(trackHeight, 1) / duration
        let spacing = minimumRulerLabelSpacing(durationMinutes: durationMinutes)
        return [1, 5, 10, 15, 20, 30, 60, 120].first {
            pointsPerMinute * CGFloat($0) >= spacing
        } ?? 30
    }

    static func visibleRulerRows(
        window: ClosedRange<Int>,
        durationMinutes: Int,
        trackHeight: CGFloat
    ) -> [MapHomeTimeRulerRow] {
        let labels = visibleRulerLabels(
            window: window,
            durationMinutes: durationMinutes,
            trackHeight: trackHeight
        )
        let hourMinutes = labels.hours.map { $0 * 60 }
        let marks = Set(hourMinutes + labels.minutes).sorted()
        return marks.map { minute in
            let isHour = hourMinutes.contains(minute)
            return MapHomeTimeRulerRow(
                minute: minute,
                hour: isHour ? minute / 60 : nil,
                minuteComponent: isHour ? nil : minute % 60
            )
        }
    }

    static func showsTenMinuteRuler(durationMinutes: Int) -> Bool {
        durationMinutes < fullDayMinutes
    }

    static func showsMinuteTicks(durationMinutes: Int) -> Bool {
        durationMinutes <= 60
    }

    static func maximumSelectableMinute(for date: Date, now: Date, calendar: Calendar = .current) -> Int {
        guard calendar.isDate(date, inSameDayAs: now) else { return 1439 }
        let components = calendar.dateComponents([.hour, .minute], from: now)
        return min(1439, max(0, (components.hour ?? 0) * 60 + (components.minute ?? 0)))
    }

    /// A past day has no moving "now" cutoff: render its complete archived
    /// route until the user chooses a time on the rail.
    static func defaultTimelineMinute(
        for date: Date,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Int {
        guard calendar.isDate(date, inSameDayAs: now) else {
            return fullDayMinutes
        }
        let components = calendar.dateComponents([.hour, .minute], from: now)
        return min(
            fullDayMinutes - 1,
            max(0, (components.hour ?? 0) * 60 + (components.minute ?? 0))
        )
    }

    static func minuteByLocation(
        y: CGFloat,
        trackHeight: CGFloat,
        verticalInset: CGFloat,
        maxMinute: Int,
        visibleStartMinute: Int = 0,
        visibleDurationMinutes: Int = fullDayMinutes
    ) -> Int {
        guard trackHeight > 0 else { return 0 }
        let position = min(max(y - verticalInset, 0), trackHeight)
        let duration = min(max(visibleDurationMinutes, 1), fullDayMinutes)
        let minute = visibleStartMinute + Int((position / trackHeight * CGFloat(duration)).rounded())
        return min(max(minute, 0), maxMinute)
    }

    static func minuteByDragging(
        baseMinute: Int,
        translation: CGFloat,
        trackHeight: CGFloat,
        maxMinute: Int,
        visibleStartMinute: Int,
        visibleDurationMinutes: Int,
        sensitivity: CGFloat = 1
    ) -> Int {
        guard trackHeight > 0 else { return min(max(baseMinute, 0), maxMinute) }
        let duration = min(max(visibleDurationMinutes, 1), fullDayMinutes)
        let delta = Int(
            (translation / trackHeight * CGFloat(duration) * max(sensitivity, 0)).rounded()
        )
        let lower = min(max(visibleStartMinute, 0), fullDayMinutes - duration)
        let upper = min(max(lower + duration, 0), maxMinute)
        return min(max(baseMinute + delta, lower), upper)
    }

    static func minuteByFixedPlayhead(
        trackHeight: CGFloat,
        verticalInset: CGFloat,
        maxMinute: Int,
        visibleStartMinute: Int,
        visibleDurationMinutes: Int
    ) -> Int {
        minuteByLocation(
            y: verticalInset + trackHeight / 2,
            trackHeight: trackHeight,
            verticalInset: verticalInset,
            maxMinute: maxMinute,
            visibleStartMinute: visibleStartMinute,
            visibleDurationMinutes: visibleDurationMinutes
        )
    }

}

private extension Array where Element == Int {
    func closestIndex(to value: Int) -> Int {
        enumerated().min(by: { abs($0.element - value) < abs($1.element - value) })?.offset ?? 0
    }
}
