import SwiftUI
import UIKit

extension View {
    /// 반투명 면 + 테마 선 색 얇은 테두리. 리퀴드 글래스는 가장자리 굴절 띠가 두꺼워 보여 쓰지 않는다(UIX1101B01, 대표).
    func mapHomeGlass<S: Shape>(in shape: S) -> some View {
        background(Color.tpGlassTint, in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.stroke(Color.tpLine.opacity(0.8), lineWidth: 0.6))
    }
}

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
    static let pillBackgroundOpacity = 0.10

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

    /// 현재 -1시간보다 앞서 끝난 날씨(지나간 시간대)는 살짝 흐리게 보인다.
    /// 지나간 칩은 배경까지 함께 흐려서 미래 칩(불투명 배경, 흐린 글자)과 확실히 구분한다.
    static let fixedPastPillOpacity = 0.05
    static let fixedPastAge: TimeInterval = 60 * 60

    static func isFixedPast(_ context: WeatherContext, now: Date) -> Bool {
        context.isForecast != true
            && (context.validUntil ?? context.observedAt) <= now.addingTimeInterval(-fixedPastAge)
    }

    static func opacity(for context: WeatherContext) -> Double {
        context.isForecast == true ? forecastOpacity : 1
    }

    static func pillOpacity(for context: WeatherContext, now: Date = .now) -> Double {
        isFixedPast(context, now: now) ? fixedPastPillOpacity : 1
    }

    /// 지난 날씨는 배경만 흐리고 글자·아이콘은 그대로 둔다.
    /// 이미 끝난 시간대(`isPastSpan`)이거나 관측이 오래됐으면 지난 날씨로 보고 배경을 더 흐리게 한다.
    static func backgroundOpacity(for context: WeatherContext, isPastSpan: Bool = false, now: Date = .now) -> Double {
        isPastSpan || isFixedPast(context, now: now) ? fixedPastPillOpacity : pillBackgroundOpacity
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
    static var panelBackground: Color { Color.tpSurface.opacity(0.10) }
    static var panelBorder: Color { Color.tpLine.opacity(0.64) }
    static var numericColumnBackground: Color { Color.tpSurface.opacity(0.10) }
    static var trackBackground: Color { Color.tpBackground.opacity(0.62) }
    static var handleBackground: Color { Color.tpSurface }
    static let deepPinkHex = "#D94772"
    /// 기본 테마는 분홍 손잡이, 어두운 테마는 면 위에서 읽히도록 글자 색과 같은 밝은 계열을 쓴다.
    static var handleForeground: Color {
        TaptionUITheme.current.palette == nil ? Color(hex: deepPinkHex) : .tpInk
    }
    static var handleBorder: Color {
        TaptionUITheme.current.palette == nil ? Color(hex: deepPinkHex) : .tpLine
    }
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

/// 대분류 색은 그대로 두고 상세 활동을 표시하는 빗금 무늬.
private struct MapHomeDetailStripes: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let spacing: CGFloat = 7
            var offset = -size.width
            while offset < size.height {
                path.move(to: CGPoint(x: 0, y: offset + size.width))
                path.addLine(to: CGPoint(x: size.width, y: offset))
                offset += spacing
            }
            context.stroke(path, with: .color(.white.opacity(0.45)), lineWidth: 1.5)
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
        case "activity": return UITextPack.translate(english: "Activity")
        case "work": return UITextPack.translate(english: "Work")
        case "study": return UITextPack.translate(english: "Study")
        case "hobby": return UITextPack.translate(english: "Hobby")
        case "sleep": return UITextPack.translate(english: "Sleep")
        case "movement": return UITextPack.translate(english: "Movement")
        case "eating": return UITextPack.translate(english: "Eating")
        case "exercise": return UITextPack.translate(english: "Exercise")
        case "health": return UITextPack.translate(english: "Health")
        case "shower": return UITextPack.translate(english: "Shower")
        case "housework": return UITextPack.translate(english: "Housework")
        case "unconfirmed": return UITextPack.translate(english: "Unconfirmed")
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
    /// 등록 지점 안에서 걸은 분. 대분류는 그 곳의 것이고 상세 활동과 애니메이션만 걷기다.
    var walkSpans: [Range<Int>] = []

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

    static func nextSegment(
        after confirmed: MapHomeTimeRailSegment,
        in candidates: [MapHomeTimeRailSegment]
    ) -> MapHomeTimeRailSegment? {
        let remaining = candidates.filter {
            $0.categoryID == "unconfirmed"
                && !($0.startMinute == confirmed.startMinute
                    && $0.endMinute == confirmed.endMinute)
        }.sorted { $0.startMinute < $1.startMinute }
        return remaining.first { $0.startMinute >= confirmed.endMinute }
            ?? remaining.first
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
        AppLanguagePreference.text(korean: "\(MovementPresentation.title(for: segment.mode)) 탑승", english: "\(MovementPresentation.englishTitle(for: segment.mode)) ride")
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
        case "work" where segment.behavior == StationaryContextKind.meeting.rawValue:
            // 회의가 앞뒤 업무에 합쳐지면 업무 제목만 남아 보이지 않는다.
            return "work:meeting"
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
    /// 업무 구간 위에 무늬로 표시할 상세 활동(회의) 구간.
    let detailSpans: [Range<Int>]
    let categoryColors: [String: String]
    let zoomResetToken: Int
    let zoomStepToken: Int
    let maximumSelectableMinute: Int?
    var onInteractionChanged: ((Bool) -> Void)?
    var onSectionEdit: ((Int) -> Void)?
    /// 있으면 알약 맨 위 여백에 사이드바 접기 원형 버튼을 둔다(연필과 같은 모양).
    var onCollapse: (() -> Void)?
    var onUnconfirmedReview: ((MapHomeTimeRailSegment) -> Void)?
    /// 미확인 구간에 앞뒤 근거로 추정한 수단 아이콘을 얹는다(PLB1103A01).
    var unconfirmedMode: ((MapHomeTimeRailSegment) -> TravelMode?)?
    /// 묶인 미확인 아이콘을 누르면 여기 담긴 구간들을 작은 메뉴로 고른다.
    @State private var reviewChoices: [MapHomeTimeRailSegment]?

    /// 보이는 시간 창. 지도 홈이 들고 있는 값 하나를 시간 레일·날씨 띠·선택 캡슐이
    /// 함께 쓴다. 예전에는 이 화면이 `@State`로 따로 들고 `onViewportChanged`로
    /// 알렸는데, 메뉴를 열어 이 화면이 사라졌다 돌아오면 레일만 하루 전체로 돌아가고
    /// 부모가 든 창은 확대 상태로 남아 캡슐·날씨 띠가 다른 창을 썼다(2026-10-27).
    @Binding var visibleStartMinute: Int
    @Binding var visibleDurationMinutes: Int
    @State private var dragStartMinute: Int?
    @State private var viewportDragStartMinute: Int?
    @State private var gestureBaseState: MapHomeTimeSidebarNLEState?
    @State private var isHandleDragging = false
    @State private var handleDoubleTapDetector = MapHomeSidebarDoubleTapDetector()
    @State private var nleProjection = TimelineNLEProjection<MapHomeTimeSidebarNLEState>()
    @State private var handleDrag = MapHomeTimeSidebarHandleDrag()
    @State private var railSnapshot: MapHomeTimeSidebarRailSnapshot
    @State private var pendingRailSegments: [MapHomeTimeRailSegment]?
    @State private var pinchStepOffset = 0
    @AppStorage(MapHomeSidebarTimeFormat.storageKey) private var timeFormatRaw = MapHomeSidebarTimeFormat.twentyFourHour.rawValue
    @AppStorage(MapHomeSidebarRulerInterval.storageKey) private var rulerIntervalRaw = MapHomeSidebarRulerInterval.automatic.rawValue
    @State private var pinchGate = TimelineTrailingInputGate<Int>()

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

    /// 구동기 재생 중이면 4Hz로 오는 분 변화를 선형 애니메이션으로 이어, 손잡이·눈금이 끊기지 않고 내려간다(ARC1030A02).
    private let smoothsPlayback: Bool

    init(
        smoothsPlayback: Bool = false,
        date: Date,
        selectedMinute: Binding<Int>,
        visibleStartMinute: Binding<Int>,
        visibleDurationMinutes: Binding<Int>,
        activity: MapHomeTimeSidebarActivity? = nil,
        segments: [MapHomeTimeRailSegment] = [],
        detailSpans: [Range<Int>] = [],
        categoryColors: [String: String] = [:],
        zoomResetToken: Int = 0,
        zoomStepToken: Int = 0,
        railWidth: CGFloat = 44,
        maximumSelectableMinute: Int? = nil,
        trailingInteractionWidth: CGFloat = 0,
        onInteractionChanged: ((Bool) -> Void)? = nil,
        onSectionEdit: ((Int) -> Void)? = nil,
        onCollapse: (() -> Void)? = nil,
        onUnconfirmedReview: ((MapHomeTimeRailSegment) -> Void)? = nil,
        unconfirmedMode: ((MapHomeTimeRailSegment) -> TravelMode?)? = nil
    ) {
        self.smoothsPlayback = smoothsPlayback
        self.date = date
        self._selectedMinute = selectedMinute
        self._visibleStartMinute = visibleStartMinute
        self._visibleDurationMinutes = visibleDurationMinutes
        self.activity = activity
        self.segments = segments
        self.detailSpans = detailSpans
        self.categoryColors = categoryColors
        self.zoomResetToken = zoomResetToken
        self.zoomStepToken = zoomStepToken
        self.railWidth = max(44, railWidth)
        self.maximumSelectableMinute = maximumSelectableMinute
        self.trailingInteractionWidth = max(0, trailingInteractionWidth)
        self.onInteractionChanged = onInteractionChanged
        self.onSectionEdit = onSectionEdit
        self.onCollapse = onCollapse
        self.onUnconfirmedReview = onUnconfirmedReview
        self.unconfirmedMode = unconfirmedMode
        self._railSnapshot = State(
            initialValue: MapHomeTimeSidebarRailSnapshot(segments)
        )
    }

    /// 미확인 아이콘 묶음 층. 본문 식이 길어 따로 뺐다.
    @ViewBuilder
    private func reviewMarkerLayer(
        railOriginX: CGFloat,
        verticalInset: CGFloat,
        centers: [String: CGFloat],
        segments: [MapHomeTimeRailSegment]
    ) -> some View {
                // 아이콘 크기(26pt)만큼 가까운 미확인 구간은 아이콘 하나로 묶는다.
                ForEach(MapHomeTimeSidebarMath.reviewMarkerGroups(segments: segments, centers: centers), id: \.first?.id) { group in
                    let y = centers[group.first?.id ?? ""] ?? verticalInset
                    Button {
                        if group.count == 1, let only = group.first {
                            onUnconfirmedReview?(only)
                        } else {
                            reviewChoices = group
                        }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: group.count == 1 ? group.first.flatMap { unconfirmedMode?($0)?.outlineSymbolName } ?? "questionmark" : "questionmark")
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
                                .foregroundStyle(Color.tpInk)
                                .frame(width: 26, height: 26)
                                .taptionRaised(.circle, fill: .tpSurface)
                            if group.count > 1 {
                                Text("\(group.count)")
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .background(Color.tpReferenceBlue, in: Capsule())
                                    .offset(x: 4, y: -4)
                            }
                        }
                        .frame(
                            width: MapHomeTimeSidebarMath.reviewMarkerHitHeight,
                            height: MapHomeTimeSidebarMath.reviewMarkerHitHeight
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        unconfirmedGroupLabel(start: timeLabel(for: group[0].startMinute), end: timeLabel(for: group[0].endMinute), count: group.count)
                    )
                    .position(x: railOriginX - 16, y: y)
                    .zIndex(4)
                }
    }

    /// 측정용: `-benchHide=glass,segments,labels`(ARC1030A01).
    static func benchHidden(_ name: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-benchHide=") && $0.contains(name) }
    }

    /// 사이드바 패널 모양.
    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    var body: some View {
        sidebarBody
    }

    private var sidebarBody: some View {
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
            let selectedY = MapHomeTimeSidebarHandleMath.y(
                minute: minute,
                window: visibleWindow,
                trackHeight: trackHeight,
                verticalInset: verticalInset,
                isViewportDragging: viewportDragStartMinute != nil
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
                    if !Self.benchHidden("glass") {
                    TaptionRaisedFace(shape: .rounded(22), gloss: false)
                        .frame(width: railWidth, height: railHeight)
                        .position(
                            x: railOriginX + railWidth / 2,
                            y: railHeight / 2
                        )
                        .allowsHitTesting(false)
                    }

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
                        // 손잡이뿐 아니라 줄 어디를 두 번 눌러도 그 시각의 클립 편집으로 들어간다(대표 지시, NLE1029A01).
                        .simultaneousGesture(
                            SpatialTapGesture(count: 2).onEnded { value in
                                let minute = MapHomeTimeSidebarMath.minuteByLocation(
                                    y: value.location.y, trackHeight: trackHeight, verticalInset: verticalInset,
                                    maxMinute: maxMinute, visibleStartMinute: visibleWindow.lowerBound,
                                    visibleDurationMinutes: visibleWindow.upperBound - visibleWindow.lowerBound
                                )
                                TaptionPlanDiagnosticsLogger.shared.record(
                                    "sidebar_double_tap", fields: ["where": "rail"], metrics: ["minute": Double(minute)]
                                )
                                onSectionEdit?(minute)
                            }
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

                    ForEach(Self.benchHidden("segments") ? [] : visibleSegments) { segment in
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
                                        if trackHeight * MapHomeTimeSidebarMath.spanFraction(start: start, end: end, window: visibleWindow) >= 12,
                                           let mode = unconfirmedMode?(segment) {
                                            Image(systemName: mode.outlineSymbolName)
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(Color.tpInk)
                                        }
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
                                    y: trackHeight * MapHomeTimeSidebarMath.segmentCenterPosition(
                                        start: start,
                                        end: end,
                                        window: visibleWindow
                                    )
                                )
                        }
                    }

                    ForEach(MapHomeTimeSidebarMath.detailPatternSpans(detailSpans, segments: visibleSegments, window: visibleWindow), id: \.lowerBound) { span in
                        MapHomeDetailStripes()
                            .frame(
                                width: activeRailWidth,
                                height: max(1, trackHeight * MapHomeTimeSidebarMath.spanFraction(start: span.lowerBound, end: span.upperBound, window: visibleWindow))
                            )
                            .clipped()
                            .position(
                                x: activeRailWidth / 2,
                                y: trackHeight * MapHomeTimeSidebarMath.segmentCenterPosition(start: span.lowerBound, end: span.upperBound, window: visibleWindow)
                            )
                    }
                }
                .frame(width: activeRailWidth, height: trackHeight)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                // 왼쪽 위에서 빛을 받는 둥근 막대처럼 보이게 한 겹만 덧칠한다.
                .overlay {
                    LinearGradient(
                        colors: [.white.opacity(0.32), .clear, .black.opacity(0.16)],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    .allowsHitTesting(false)
                }
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
                        trackHeight: trackHeight,
                        minimumStep: rulerIntervalRaw
                    )
                    let rulerFontSize = MapHomeTimeSidebarMath.rulerFontSize(
                        durationMinutes: visibleDurationMinutes
                    )
                    if smoothsPlayback {
                        ForEach(minuteMarks.filter { showsMinuteTicks || $0.isMultiple(of: 10) }, id: \.self) { mark in
                            let isTenMinute = mark.isMultiple(of: 10)
                            let width = isTenMinute ? rulerTickWidth : rulerTickWidth / 2
                            Rectangle()
                                .fill(Color.tpSecondary.opacity(isTenMinute ? 0.54 : 0.22))
                                .frame(width: width, height: 1)
                                .position(
                                    x: railOriginX + railWidth - numericColumnWidth + width / 2,
                                    y: verticalInset + trackHeight * MapHomeTimeSidebarMath.position(minute: mark, window: visibleWindow)
                                )
                                .allowsHitTesting(false)
                        }
                    } else {
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
                    }

                    ForEach(Self.benchHidden("labels") ? [] : rulerRows) { row in
                        let minuteMark = row.minute
                        let y = verticalInset + trackHeight * MapHomeTimeSidebarMath.position(
                            minute: minuteMark,
                            window: visibleWindow
                        )
                        Text(rulerLabel(minuteMark))
                        .font(.taptionFixed(size: rulerFontSize, weight: .semibold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.55)
                        .allowsTightening(true)
                        .foregroundStyle(Color.tpSidebarTime(0.78))
                        .taptionTextOutline()
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
                                .frame(width: hour.isMultiple(of: 6) ? 8 : 5, height: 1.5).frame(width: 8, alignment: .leading)
                            Text(timeFormat.hourLabel(hour))
                                .minimumScaleFactor(0.6)
                                .font(.taptionFixed(size: rulerFontSize, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Color.tpSidebarTime(hour.isMultiple(of: 6) ? 0.82 : 0.52))
                                .taptionTextOutline()
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
                        panelShape
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
                        .accessibilityLabel("시간 선택")
                        .accessibilityHint("화면 오른쪽 끝까지 끌어 시간을 선택합니다")
                }

                reviewMarkerLayer(
                    railOriginX: railOriginX,
                    verticalInset: verticalInset,
                    centers: reviewMarkerCenters,
                    segments: reviewableVisibleSegments
                )

                // 알약 맨 아래 여백 안의 연필: 누르면 지금 시각의 클립 편집을 연다(대표 지시, ARC1030A05).
                if onSectionEdit != nil {
                    Button {
                        onSectionEdit?(minute)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
                            .foregroundStyle(Color.tpInk.opacity(0.85))
                            .frame(width: 26, height: 26)
                            .taptionRaised(.circle, fill: .tpSurface)
                            .frame(width: railWidth, height: verticalInset)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppLanguagePreference.text("클립 편집", "Clip editor"))
                    .accessibilityIdentifier("mapHomeTimelineEditButton")
                    .position(x: railOriginX + railWidth / 2, y: railHeight - verticalInset / 2)
                    .zIndex(5)
                }

                // 알약 맨 위 여백 안의 접기 버튼: 사이드바 전체를 닫는다(대표 지시).
                if let onCollapse {
                    Button(action: onCollapse) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
                            .foregroundStyle(Color.tpInk.opacity(0.85))
                            .frame(width: 26, height: 26)
                            .taptionRaised(.circle, fill: .tpSurface)
                            .frame(width: railWidth, height: verticalInset)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppLanguagePreference.text("사이드바 닫기", "Close sidebar"))
                    .accessibilityIdentifier("mapHomeSidebarCollapseButton")
                    .position(x: railOriginX + railWidth / 2, y: verticalInset / 2)
                    .zIndex(5)
                }

            }
            .frame(
                width: interactionWidth,
                height: railHeight,
                alignment: .topLeading
            )
            .animation(smoothsPlayback ? .linear(duration: 0.26) : nil, value: minute)
            .coordinateSpace(name: "mapHomeTimeSidebarRail")
            // 바깥 틀에 contentShape를 주면 레일 왼쪽 빈 띠에 닿은 손가락이 지도 핀치에서 빠진다(PNC1105A02). 손잡이·레일이 각자 터치를 받는다.
            .confirmationDialog(
                AppLanguagePreference.text("미확인 구간 고르기", "Choose an unconfirmed interval"),
                isPresented: Binding(
                    get: { reviewChoices != nil },
                    set: { if !$0 { reviewChoices = nil } }
                ),
                titleVisibility: .visible
            ) {
                ForEach(reviewChoices ?? [], id: \.id) { segment in
                    Button("\(timeLabel(for: segment.startMinute))–\(timeLabel(for: segment.endMinute))") {
                        onUnconfirmedReview?(segment)
                    }
                }
                Button("취소", role: .cancel) {}
            }
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
            pinchGate.reset()
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
            let start = MapHomeTimeSidebarMath.startMinuteRevealingSelection(
                selectedMinute: selectedMinute,
                visibleStartMinute: visibleStartMinute,
                durationMinutes: visibleDurationMinutes
            )
            if start != visibleStartMinute {
                visibleStartMinute = start
            }
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
            handleTimeText(minute)
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
            .taptionRaised(
                .rounded(MapHomeTimeSidebarStyle.handleCornerRadius),
                fill: MapHomeTimeSidebarStyle.handleBackground,
                line: MapHomeTimeSidebarStyle.handleBorder
            )
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
                .simultaneousGesture(handleTapGesture(minute: minute, maxMinute: maxMinute))
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
                .simultaneousGesture(handleTapGesture(minute: minute, maxMinute: maxMinute))
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

    /// 손잡이 탭 한 경로: 한 번이면 그 시각을 한 번만 알리고, 가까이 연달아 두 번이면 섹션 편집을 연다.
    /// 드래그는 4pt 움직여야 시작하므로 탭이 드래그 종료로 한 번 더 알려지지 않는다(PRF1101A01).
    private func handleTapGesture(minute: Int, maxMinute: Int) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            let now = ProcessInfo.processInfo.systemUptime
            let tappedMinute = min(max(minute, 0), maxMinute)
            guard handleDoubleTapDetector.registerEnd(
                startUptime: now, endUptime: now, translation: .zero, location: value.location
            ) else { return publish(tappedMinute) }
            TaptionPlanDiagnosticsLogger.shared.record("sidebar_double_tap", metrics: ["minute": Double(tappedMinute)])
            onSectionEdit?(tappedMinute)
        }
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
                // 걸러진 마지막 단계는 창 끝에 한 번 반영한다(손가락이 멈춰도 다음 입력을 기다리지 않음, PRF1101A01).
                pinchGate.deliver = { applyPinchStepOffset($0) }
                pinchGate.submit(offset)
            }
            .onEnded { scale in
                pinchGate.reset()
                applyPinchStepOffset(MapHomeTimeSidebarPinchMath.stepOffset(magnification: scale))
                pinchStepOffset = 0
            }
    }

    private func applyPinchStepOffset(_ offset: Int) {
        let delta = offset - pinchStepOffset
        for _ in 0..<abs(delta) {
            zoomTimeline(direction: delta > 0 ? 1 : -1)
        }
        pinchStepOffset = offset
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

    private var timeFormat: MapHomeSidebarTimeFormat {
        MapHomeSidebarTimeFormat(rawValue: timeFormatRaw) ?? .twentyFourHour
    }

    private func timeLabel(for minute: Int) -> String {
        timeFormat.timeLabel(minute)
    }

    /// 손잡이 시각. 12시간이면 칸(44pt)이 좁아 오전·오후를 위에 작게 적는다.
    @ViewBuilder
    private func handleTimeText(_ minute: Int) -> some View {
        if timeFormat == .twelveHour {
            VStack(spacing: -1) {
                Text(minute / 60 % 24 < 12 ? MapHomeLanguage.current.text("오전", "AM") : MapHomeLanguage.current.text("오후", "PM"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(8)), weight: .bold))
                Text(timeFormat.timeLabel(minute, includesPeriod: false))
            }
        } else {
            Text(timeLabel(for: minute))
        }
    }

    /// 눈금 글자. 정시는 시 글자, 그 사이는 시:분. 12시간이면 칸이 좁아 오전·오후는 정시 글자에만 적는다.
    private func rulerLabel(_ minute: Int) -> String {
        minute.isMultiple(of: 60) && timeFormat == .twelveHour
            ? timeFormat.hourLabel(minute / 60)
            : timeFormat.timeLabel(minute, includesPeriod: false)
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
    @State private var hasAdvanced = false
    @State private var nextFocusedSegment: MapHomeTimeRailSegment?
    @State private var confirmedSegmentIDs: Set<String> = []

    private var quickCategories: [MapHomeSidebarMajorCategory] {
        let ids = ["work", "study", "sleep", "eating", "movement", "exercise", "hobby", "activity"]
        let byID = Dictionary(uniqueKeysWithValues: MapHomeSidebarMajorCategory.all.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    private var quickCategoryRows: [[MapHomeSidebarMajorCategory]] {
        MapHomeUnconfirmedQuickCategoryLayout.rows(from: quickCategories)
    }

    private var unconfirmedSegments: [MapHomeTimeRailSegment] {
        if hasAdvanced, nextFocusedSegment == nil { return [] }
        return MapHomeUnconfirmedReviewPolicy.reviewTargets(
            from: segments.filter { !confirmedSegmentIDs.contains($0.id) },
            focusingOn: hasAdvanced ? nextFocusedSegment : focusedSegment,
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
                                    hasAdvanced = false
                                    nextFocusedSegment = nil
                                    confirmedSegmentIDs.removeAll()
                                    saveFailedSegmentID = nil
                                    onDateSelect(day)
                                } label: {
                                    Text(day.formatted(Date.FormatStyle().month().day().locale(language.locale)))
                                        .font(.taptionFixed(size: 12, weight: .semibold))
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
                    .font(.taptionFixed(size: 12))
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
Group {
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
                                            .font(.taptionFixed(size: 15))
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
                                                    let candidates = MapHomeUnconfirmedReviewPolicy.segments(
                                                        from: segments,
                                                        for: date
                                                    ).filter { !confirmedSegmentIDs.contains($0.id) }
                                                    Task { @MainActor in
                                                        let saved = await onQuickConfirm(segment, category)
                                                        if !saved {
                                                            saveFailedSegmentID = segment.id
                                                        } else {
                                                            confirmedSegmentIDs.insert(segment.id)
                                                            nextFocusedSegment = MapHomeUnconfirmedReviewPolicy.nextSegment(
                                                                after: segment,
                                                                in: candidates
                                                            )
                                                            hasAdvanced = true
                                                        }
                                                        savingSegmentID = nil
                                                    }
                                                } label: {
                                                    Label(category.localizedTitle(language), systemImage: category.systemImage)
                                                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                                                        .lineLimit(1)
                                                        .minimumScaleFactor(0.72)
                                                        .frame(maxWidth: .infinity, minHeight: 44)
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
                                    .font(.taptionFixed(size: 12))
                                    .foregroundStyle(.red)
                                }
                            }
                            .padding(.vertical, 6)
                        
}
.listRowBackground(Color.tpSurface)
}
.tpListStyle()
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle(language.text("미확인 활동", "Unconfirmed activity"))
            .navigationBarTitleDisplayMode(.inline)
        }
        // 아래로 내리는 핸들 제스처로 닫는다. 저장 중에만 막는다.
        .interactiveDismissDisabled(savingSegmentID != nil)
    }

    private func time(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return language.text("\(remainder)분", "\(remainder)m") }
        return remainder == 0
            ? language.text("\(hours)시간", "\(hours)h")
            : language.text("\(hours)시간 \(remainder)분", "\(hours)h \(remainder)m")
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

        var id: String { "\(context.id)-\(startMinute)" }
    }

    var body: some View {
        GeometryReader { proxy in
            let railHeight = max(220, proxy.size.height)
            let trackHeight = max(1, railHeight - verticalInset * 2)
            let window = MapHomeTimeSidebarMath.visibleWindow(
                startMinute: visibleStartMinute,
                durationMinutes: visibleDurationMinutes,
                centerMinute: selectedMinute
            )
            let clampedSelectedMinute = min(max(selectedMinute, 0), 1_439)
            let nowComponents = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: Date.now)
            let currentMinute = (nowComponents.hour ?? 0) * 60 + (nowComponents.minute ?? 0)
            let isToday = Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: Date.now)
            let isPastDay = Calendar.autoupdatingCurrent.startOfDay(for: date)
                < Calendar.autoupdatingCurrent.startOfDay(for: Date.now)
            let entries = weatherEntries(splittingAt: isToday ? currentMinute : nil)
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
                // 방금 지난 칩도 앞세운다. 지금 칸과 가까워 간격 규칙에 밀리면 지난 칸 비활성이 보이지 않았다(WTH1101A02).
                priorityIndices: [selectedIndex, currentIndex, isToday ? entries.lastIndex { $0.endMinute <= currentMinute } : nil].compactMap { $0 }
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
                        let isPastSpan = isPastDay || (isToday && entry.endMinute <= currentMinute)
                        let entryMinute = min(
                            max((entry.startMinute + entry.endMinute) / 2, 0),
                            MapHomeTimeSidebarMath.fullDayMinutes
                        )

                        HStack(spacing: MapHomeWeatherRailLayout.scaled(4)) {
                            Image(systemName: MapHomeHomeWeatherKind(symbolName: entry.context.symbolName).sidebarSymbol)
                                .font(.system(
                                    size: MapHomeWeatherRailLayout.scaled(13),
                                    weight: .semibold
                                ))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(
                                    !isPastSpan ? Color.white : mapHomeWeatherSymbolColor(entry.context, component: .primary),
                                    !isPastSpan ? Color.white : mapHomeWeatherSymbolColor(entry.context, component: .secondary)
                                )
                            Text("\(AppRegion.current.temperature(celsius: entry.context.temperatureCelsius))°")
                                .font(.system(
                                    size: MapHomeWeatherRailLayout.scaled(10),
                                    weight: isSelected ? .bold : .semibold,
                                    design: .rounded
                                ))
                                .monospacedDigit()
                                .foregroundStyle(!isPastSpan ? Color.white : (isSelected || isCurrent ? Color.tpAccent : Color.tpInk))
                        }
                        // 지난 시간대는 유리 칸을 흐리게, 남은 시간대는 채운 칸에 흰 글자로 또렷하게 둔다(대표 지시로 반전).
                        .opacity(isPastSpan ? MapHomeWeatherDisplayPolicy.forecastOpacity : 1)
                        .padding(.horizontal, MapHomeWeatherRailLayout.scaled(8))
                        .frame(
                            width: itemWidth,
                            height: MapHomeWeatherRailLayout.itemHeight
                        )
                        // 활성(남은) 칸은 테마 색으로 채우고, 글자·아이콘은 흰색.
                        .taptionRaised(
                            .capsule,
                            fill: isPastSpan ? nil : Color(hex: MapHomeHomeWeatherKind(symbolName: entry.context.symbolName).sidebarFillHex),
                            line: isSelected ? .tpPastelRose : nil,
                            lineWidth: isSelected ? 1.4 : 1
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
                                "\(entryMinute / 60)시 날씨 \(entry.context.condition), \(AppRegion.current.temperature(celsius: entry.context.temperatureCelsius))도",
                                "\(entryMinute / 60):00 weather: \(entry.context.condition), \(AppRegion.current.temperature(celsius: entry.context.temperatureCelsius)) degrees"
                            ) + (entry.context.airQuality.map {
                                let grade = $0.overallGrade.displayName
                                return language.text(", 미세먼지 \(grade)", ", air quality \(grade)")
                            } ?? "")
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

    private func weatherEntries(splittingAt currentMinute: Int?) -> [Entry] {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: date)
        return MapHomeWeatherTimelineMath.persistentSpans(
            for: date,
            contexts: contexts.filter(MapHomeWeatherDisplayPolicy.isComplete),
            calendar: calendar,
            minimumTemperatureChangeCelsius:
                MapHomeWeatherTimelineMath.fullDayTemperatureChangeCelsius
        ).flatMap { entry in
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
            return MapHomeWeatherPastSplit.ranges(start: startMinute, end: endMinute, currentMinute: currentMinute).map {
                Entry(context: entry.context, startMinute: $0.lowerBound, endMinute: $0.upperBound)
            }
        }
    }
}

/// 드래그 제스처가 터치를 먼저 가져가므로 탭 두 번은 드래그 종료에서 직접 판정한다.
/// 움직임이 거의 없고 짧은 터치가 가까운 위치에서 연달아 두 번 오면 더블탭이다.
struct MapHomeSidebarDoubleTapDetector: Equatable {
    static let maximumMovement: CGFloat = 10
    static let maximumTapDuration: TimeInterval = 0.35
    static let maximumInterval: TimeInterval = 0.45
    static let maximumSeparation: CGFloat = 40

    private var lastTapUptime: TimeInterval?
    private var lastTapLocation: CGPoint?

    /// 터치 하나가 끝날 때 부르고, 더블탭이면 true를 돌려준다.
    mutating func registerEnd(
        startUptime: TimeInterval,
        endUptime: TimeInterval,
        translation: CGSize,
        location: CGPoint
    ) -> Bool {
        let movement = hypot(translation.width, translation.height)
        guard movement <= Self.maximumMovement,
              endUptime - startUptime <= Self.maximumTapDuration else {
            reset()
            return false
        }
        if let lastTapUptime, let lastTapLocation,
           endUptime - lastTapUptime <= Self.maximumInterval,
           hypot(location.x - lastTapLocation.x, location.y - lastTapLocation.y)
               <= Self.maximumSeparation {
            reset()
            return true
        }
        lastTapUptime = endUptime
        lastTapLocation = location
        return false
    }

    mutating func reset() {
        lastTapUptime = nil
        lastTapLocation = nil
    }
}

/// 사이드바 시각 표시 방식(표시 > 사이드바). 기본은 24시간.
enum MapHomeSidebarTimeFormat: String, CaseIterable, Identifiable {
    case twentyFourHour
    case twelveHour

    static let storageKey = "mapHomeSidebarTimeFormat"
    static var current: MapHomeSidebarTimeFormat {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .twentyFourHour
    }

    var id: String { rawValue }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .twentyFourHour: language.text("24시간", "24-hour")
        case .twelveHour: language.text("12시간", "12-hour")
        }
    }

    /// 눈금의 정시 글자. 12시간이면 0시·12시에 오전·오후를 적고 나머지는 1~11로 적는다.
    func hourLabel(_ hour: Int, language: MapHomeLanguage = .current) -> String {
        let hour = ((hour % 24) + 24) % 24
        switch self {
        case .twentyFourHour:
            return String(format: "%02d", hour)
        case .twelveHour:
            if hour == 0 { return language.text("오전", "AM") }
            if hour == 12 { return language.text("오후", "PM") }
            return String(hour % 12)
        }
    }

    /// 시각 글자. 12시간이면 "오후 3:05"처럼 적는다(24:00은 자정).
    func timeLabel(_ minute: Int, includesPeriod: Bool = true, language: MapHomeLanguage = .current) -> String {
        let hour = (minute / 60) % 24
        let minutePart = minute % 60
        switch self {
        case .twentyFourHour:
            return String(format: "%02d:%02d", minute / 60, minutePart)
        case .twelveHour:
            let clock = String(format: "%d:%02d", hour % 12 == 0 ? 12 : hour % 12, minutePart)
            guard includesPeriod else { return clock }
            return (hour < 12 ? language.text("오전 ", "AM ") : language.text("오후 ", "PM ")) + clock
        }
    }
}

/// 사이드바 눈금에 시각 글자를 적는 최소 간격(표시 > 사이드바). 자동이면 화면 높이에 맞춘다.
enum MapHomeSidebarRulerInterval: Int, CaseIterable, Identifiable {
    case automatic = 0
    case five = 5
    case ten = 10
    case fifteen = 15
    case thirty = 30
    case hour = 60

    static let storageKey = "mapHomeSidebarRulerInterval"

    var id: Int { rawValue }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .automatic: language.text("자동", "Auto")
        case .hour: language.text("1시간", "1 hour")
        default: language.text("\(rawValue)분", "\(rawValue) min")
        }
    }
}

/// 저장된 한국어 활동 이름(정지·휴식, 걷기, 지하철 탑승 …)을 영어 설정에서 영어로 보여 준다.
/// 저장된 기록 글자는 그대로 두고 화면에 그릴 때만 바꾼다. 모르는 이름은 그대로 돌려준다.
enum KnownActivityTitleLocalizer {
    private static let english: [String: String] = [
        "정지·휴식": "Stationary", "정지": "Stopped", "휴식": "Rest", "집에서 휴식": "Resting at home", "집에서휴식": "Resting at home",
        "걷기": "Walking", "달리기": "Running", "뛰기": "Running", "자전거": "Cycling", "버스": "Bus", "지하철": "Subway",
        "택시": "Taxi", "자동차": "Car", "자가용": "Private car", "기차": "Train", "비행기": "Airplane", "배": "Ship",
        "이동": "Movement", "수면": "Sleep", "업무": "Work", "회사 업무": "Office work", "학교 학습": "School", "수업": "Class",
        "식사": "Meal", "운동": "Exercise", "취미": "Hobby", "활동": "Activity", "미확인": "Unconfirmed", "외출": "Out",
    ]

    static func localized(_ title: String, language: MapHomeLanguage) -> String {
        guard language == .english else { return title }
        if let value = english[title] { return UITextPack.translate(english: value) }
        if title.hasSuffix(" 탑승") {
            let base = String(title.dropLast(3))
            let name = english[base].map { UITextPack.translate(english: $0) } ?? base
            return language.text("\(name) 탑승", "\(name) ride")
        }
        return title
    }
}

/// 사이드바 세로 펼침·접힘: 위쪽 기준으로 높이만 늘고 줄며 투명도가 함께 바뀐다.
private struct SidebarVerticalStretch: ViewModifier {
    let amount: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: max(amount, 0.001), anchor: .top)
            .opacity(Double(min(max(amount, 0), 1)))
    }
}

extension AnyTransition {
    /// 사이드바가 날짜 배지 아래에서 쫙 펼쳐지고, 접힐 때는 아래부터 배지 쪽으로 줄어든다.
    static var sidebarDrop: AnyTransition {
        .modifier(
            active: SidebarVerticalStretch(amount: 0),
            identity: SidebarVerticalStretch(amount: 1)
        )
    }
}

private func unconfirmedGroupLabel(start: String, end: String, count: Int) -> String {
    count == 1
        ? AppLanguagePreference.text("미확인 구간 \(start)–\(end) 입력", "Enter unconfirmed interval \(start)–\(end)")
        : AppLanguagePreference.text("미확인 구간 \(count)개 선택", "Choose from \(count) unconfirmed intervals")
}
