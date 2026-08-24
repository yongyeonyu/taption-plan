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
    static let numericColumnBackground = Color.white.opacity(0.68)
}

enum MapHomeWeatherBackgroundKind: Equatable {
    case selected
    case current
    case normal

    static func resolve(isSelected: Bool, isCurrent: Bool) -> Self {
        if isSelected { return .selected }
        if isCurrent { return .current }
        return .normal
    }

    var color: Color {
        switch self {
        case .selected:
            MapHomeTimeSidebarStyle.numericColumnBackground
        case .current:
            Color.tpWeather.opacity(0.28)
        case .normal:
            .clear
        }
    }
}

enum MapHomeWeatherCollisionMath {
    static let clearance: CGFloat = 4

    static func alignedWeatherFrame(
        centerX: CGFloat,
        playheadFrame: CGRect
    ) -> CGRect {
        let size = CGSize(width: 32, height: 22)
        return CGRect(
            x: centerX - size.width / 2,
            y: playheadFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func horizontalOffset(
        weatherFrame: CGRect,
        playheadFrame: CGRect
    ) -> CGFloat {
        let intersection = weatherFrame.intersection(playheadFrame)
        guard !intersection.isNull,
              intersection.width > 0,
              intersection.height > 0 else { return 0 }
        return min(
            0,
            playheadFrame.minX - clearance - weatherFrame.maxX
        )
    }
}

struct MapHomeTimeSidebarActivity {
    let systemImage: String
    let tint: Color
    let accessibilityLabel: String

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
        return Self(
            systemImage: icon,
            tint: category.tint,
            accessibilityLabel: accessibilityLabel ?? category.title
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
                    ?? CanonicalCategoryPalette.hex(category.id)
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
                    ?? CanonicalCategoryPalette.hex("activity")
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

/// Produces one winning automatic category for every minute in a day.  It
/// derives a presentation copy only; source records remain untouched.
enum MapHomeTimeRailSegmentEngine {
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
        var result: [MapHomeTimeRailSegment] = []

        for (start, end) in zip(boundaries, boundaries.dropFirst()) where start < end {
            let winner = candidates
                .filter { $0.startMinute <= start && $0.endMinute >= end }
                .max(by: { isHigherPriority($1, than: $0) })
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
        return result.isEmpty ? [.wholeDayUnconfirmed] : result
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
        to result: inout [MapHomeTimeRailSegment]
    ) {
        guard let previous = result.last,
              previous.endMinute == segment.startMinute,
              mergeKey(for: previous) == mergeKey(for: segment)
        else {
            result.append(segment)
            return
        }
        result.removeLast()
        result.append(
            MapHomeTimeRailSegment(
                startMinute: previous.startMinute,
                endMinute: segment.endMinute,
                categoryID: previous.categoryID,
                title: previous.title,
                behavior: previous.behavior,
                sourceIDs: previous.sourceIDs + segment.sourceIDs
            )
        )
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
        nowUptime: TimeInterval
    ) -> MapHomeTimeSidebarNLEState? {
        guard let baseState, trackHeight > 0 else { return nil }

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
        let localMinute = baseState.visibleStartMinute + Int(
            (localY / trackHeight * CGFloat(duration)).rounded()
        )

        return MapHomeTimeSidebarNLEState(
            selectedMinute: min(max(localMinute + edgeMinutes, 0), maxMinute),
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
    let currentWeather: WeatherContext?
    let zoomResetToken: Int
    let zoomStepToken: Int
    let maximumSelectableMinute: Int?
    var onSelectionChanged: ((Int) -> Void)?
    var onViewportChanged: ((Int, Int) -> Void)?
    var onSectionEdit: (() -> Void)?

    @State private var visibleDurationMinutes = MapHomeTimeSidebarMath.fullDayMinutes
    @State private var visibleStartMinute = 0
    @State private var dragStartMinute: Int?
    @State private var viewportDragStartMinute: Int?
    @State private var gestureBaseState: MapHomeTimeSidebarNLEState?
    @State private var isHandleDragging = false
    @State private var nleProjection = TimelineNLEProjection<MapHomeTimeSidebarNLEState>()
    @State private var handleDrag = MapHomeTimeSidebarHandleDrag()

    private let railWidth: CGFloat
    // Keep the numeric rail visibly separated from both the map header and
    // the bottom ad boundary while preserving the same minute-to-pixel scale.
    private let verticalInset: CGFloat = 14
    private let activeRailWidth: CGFloat = 12
    // Reserve the leading tick length inside the numeric gutter so labels do
    // not sit on top of ruler marks at the tighter zoom steps.
    private let numericColumnWidth = MapHomeTimeSidebarMath.rulerNumericColumnWidth
    private let rulerTickWidth = MapHomeTimeSidebarMath.rulerTickWidth

    private var totalWidth: CGFloat {
        MapHomeTimeSidebarMath.totalWidth(railWidth: railWidth)
    }

    init(
        date: Date,
        selectedMinute: Binding<Int>,
        activity: MapHomeTimeSidebarActivity? = nil,
        segments: [MapHomeTimeRailSegment] = [],
        categoryColors: [String: String] = [:],
        currentWeather: WeatherContext? = nil,
        zoomResetToken: Int = 0,
        zoomStepToken: Int = 0,
        railWidth: CGFloat = 58,
        maximumSelectableMinute: Int? = nil,
        onSelectionChanged: ((Int) -> Void)? = nil,
        onViewportChanged: ((Int, Int) -> Void)? = nil,
        onSectionEdit: (() -> Void)? = nil
    ) {
        self.date = date
        self._selectedMinute = selectedMinute
        self.activity = activity
        self.segments = segments
        self.categoryColors = categoryColors
        self.currentWeather = currentWeather
        self.zoomResetToken = zoomResetToken
        self.zoomStepToken = zoomStepToken
        self.railWidth = max(58, railWidth)
        self.maximumSelectableMinute = maximumSelectableMinute
        self.onSelectionChanged = onSelectionChanged
        self.onViewportChanged = onViewportChanged
        self.onSectionEdit = onSectionEdit
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
            let visibleSegments = displaySegments.filter {
                $0.endMinute > visibleWindow.lowerBound
                    && $0.startMinute < visibleWindow.upperBound
            }
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
                        .fill(Color.tpInk.opacity(0.72))

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
                    let rulerLabels = MapHomeTimeSidebarMath.visibleRulerLabels(
                        window: visibleWindow,
                        durationMinutes: visibleDurationMinutes,
                        trackHeight: trackHeight
                    )
                    let rulerFontSize = MapHomeTimeSidebarMath.rulerFontSize(
                        durationMinutes: visibleDurationMinutes
                    )
                    let hourColumnWidth = MapHomeTimeSidebarMath.rulerColumnWidth(
                        durationMinutes: visibleDurationMinutes
                    )
                    let minuteColumnWidth = hourColumnWidth
                    let columnSpacing = MapHomeTimeSidebarMath.rulerColumnSpacing
                    let labelsStartX = MapHomeTimeSidebarMath.rulerLabelsStartX(
                        railWidth: railWidth
                    ) + railOriginX
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
                                with: .color(Color.tpInk.opacity(isTenMinute ? 0.54 : 0.22)),
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

                    ForEach(rulerLabels.hours, id: \.self) { hour in
                        let minuteMark = hour * 60
                        let y = verticalInset + trackHeight * MapHomeTimeSidebarMath.position(
                            minute: minuteMark,
                            window: visibleWindow
                        )
                        Text(String(format: "%02d", hour))
                            .font(.system(size: rulerFontSize, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.tpInk.opacity(0.78))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: hourColumnWidth, alignment: .trailing)
                            .position(
                                x: labelsStartX + hourColumnWidth / 2,
                                y: y
                            )
                            .allowsHitTesting(false)
                    }

                    ForEach(rulerLabels.minutes, id: \.self) { minuteMark in
                        let y = verticalInset + trackHeight * MapHomeTimeSidebarMath.position(
                            minute: minuteMark,
                            window: visibleWindow
                        )
                        Text(String(format: "%02d", minuteMark % 60))
                            .font(.system(size: rulerFontSize, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.tpInk.opacity(0.78))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: minuteColumnWidth, alignment: .trailing)
                            .position(
                                x: labelsStartX
                                    + hourColumnWidth
                                    + columnSpacing
                                    + minuteColumnWidth / 2,
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
                                .fill(Color.tpInk.opacity(hour.isMultiple(of: 6) ? 0.38 : 0.18))
                                .frame(width: hour.isMultiple(of: 6) ? 8 : 5, height: 1.5)
                            Text(String(format: "%02d", hour))
                                .font(.system(size: rulerFontSize, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Color.tpInk.opacity(hour.isMultiple(of: 6) ? 0.82 : 0.52))
                                .frame(width: 20, alignment: .trailing)
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

                if let currentWeather {
                    compactWeather(
                        currentWeather,
                        handleCenterX: MapHomeTimeSidebarMath.handleCenterX(
                            trackX: trackX,
                            activeRailWidth: activeRailWidth
                        ),
                        handleCenterY: selectedY,
                        railHeight: railHeight
                    )
                }

            }
            .frame(width: totalWidth, height: railHeight)
            .coordinateSpace(name: "mapHomeTimeSidebarRail")
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("시간 선택")
            .accessibilityValue(timeLabel(for: minute))
        }
        .frame(width: totalWidth)
        .onDisappear {
            dragStartMinute = nil
            viewportDragStartMinute = nil
            gestureBaseState = nil
            isHandleDragging = false
            nleProjection.reset()
            handleDrag.reset()
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
        let hitCenterY = MapHomeTimeSidebarMath.handleHitCenterY(
            handleCenterY: y,
            railHeight: railHeight,
            hitHeight: doubleTapHitSize.height
        )
        let fallbackActivity = MapHomeTimeSidebarActivity.majorCategory(
            "unconfirmed",
            categoryColors: categoryColors
        )
        return ZStack(alignment: .topLeading) {
            Image(systemName: activity?.systemImage ?? fallbackActivity.systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(activity?.tint ?? fallbackActivity.tint)
                .frame(width: handleSize.width, height: handleSize.height)
                .background(
                    Color.tpInk.opacity(0.90),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(
                            (activity?.tint ?? fallbackActivity.tint)
                                .opacity(0.45),
                            lineWidth: 1
                        )
                }
                .position(x: handleCenterX, y: y)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(spacing: -1) {
                Text(String(format: "%02d", minute / 60))
                Text(String(format: "%02d", minute % 60))
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.white)
            .frame(width: 32, height: 40)
            .background(
                Color.tpInk.opacity(0.90),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)
            .zIndex(2)
            .position(
                x: MapHomeTimeSidebarMath.selectionTimeBlockCenterX(
                    railWidth: railWidth,
                    railOriginX: MapHomeTimeSidebarMath.handleLaneWidth,
                    trackX: trackX,
                    activeRailWidth: activeRailWidth
                ),
                y: y
            )

            Color.clear
                .frame(width: doubleTapHitSize.width, height: doubleTapHitSize.height)
                .contentShape(Rectangle())
                .position(x: handleCenterX, y: hitCenterY)
                .highPriorityGesture(
                    TapGesture(count: 2).onEnded {
                        onSectionEdit?()
                    }
                )
                .simultaneousGesture(dragGesture(
                    trackHeight: trackHeight,
                    maxMinute: maxMinute,
                    visibleWindow: visibleWindow
                ))
                .accessibilityLabel(
                    activity?.accessibilityLabel ?? fallbackActivity.accessibilityLabel
                )
                .accessibilityHint("두 번 탭하면 섹션 편집을 엽니다")
        }
        .frame(width: totalWidth, height: railHeight)
    }

    private func compactWeather(
        _ weather: WeatherContext,
        handleCenterX: CGFloat,
        handleCenterY: CGFloat,
        railHeight: CGFloat
    ) -> some View {
        let frame = MapHomeTimeSidebarMath.compactWeatherFrame(
            handleCenterX: handleCenterX,
            handleCenterY: handleCenterY,
            railHeight: railHeight
        )
        return HStack(spacing: 2) {
            Image(systemName: weather.symbolName)
                .font(.system(size: 9, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    mapHomeWeatherSymbolColor(weather, component: .primary),
                    mapHomeWeatherSymbolColor(weather, component: .secondary)
                )
            Text("\(Int(weather.temperatureCelsius.rounded()))°")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(Color.tpWeatherDark)
        .frame(width: frame.width, height: frame.height)
        .background(Color.tpWeather.opacity(0.24), in: Capsule())
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(false)
        .accessibilityLabel(
            "현재 날씨 \(weather.condition), \(Int(weather.temperatureCelsius.rounded()))도"
        )
    }

    private func categoryColorHex(_ id: String) -> String {
        categoryColors[id] ?? CanonicalCategoryPalette.hex(id)
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
            minimumDistance: 8,
            coordinateSpace: .named("mapHomeTimeSidebarRail")
        )
            .onChanged { value in
                if !isHandleDragging { isHandleDragging = true }
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
        visibleStartMinute = state.visibleStartMinute
        visibleDurationMinutes = state.visibleDurationMinutes
        selectedMinute = state.selectedMinute
        if viewportChanged {
            onViewportChanged?(state.visibleStartMinute, state.visibleDurationMinutes)
        }
        if selectionChanged {
            onSelectionChanged?(state.selectedMinute)
        }
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

    private var displaySegments: [MapHomeTimeRailSegment] {
        segments.isEmpty ? [.wholeDayUnconfirmed] : segments
    }

}

struct MapHomeTimeRulerLabels: Equatable, Sendable {
    let hours: [Int]
    let minutes: [Int]
}

struct MapHomeWeatherSidebar: View {
    let date: Date
    let contexts: [WeatherContext]
    let selectedMinute: Int
    let language: MapHomeLanguage
    let visibleStartMinute: Int
    let visibleDurationMinutes: Int

    private let railWidth: CGFloat = 58
    private let verticalInset: CGFloat = 14
    private let activeRailWidth: CGFloat = 12

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
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.tpWeather.opacity(0.30))
                    .frame(width: activeRailWidth, height: trackHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .position(
                        x: railWidth / 2,
                        y: verticalInset + trackHeight / 2
                    )

                ForEach(entries) { entry in
                    let startMinute = max(entry.startMinute, window.lowerBound)
                    let endMinute = min(entry.endMinute, window.upperBound)
                    let start = MapHomeTimeSidebarMath.position(
                        minute: startMinute,
                        window: window
                    )
                    let end = MapHomeTimeSidebarMath.position(
                        minute: endMinute,
                        window: window
                    )
                    let y = verticalInset + trackHeight * (start + end) / 2
                    let height = max(2, trackHeight * (end - start))
                    if startMinute < endMinute {
                        let itemWidth = railWidth - 2
                        let itemHeight = max(22, min(30, height + 8))
                        let playheadY = verticalInset + trackHeight
                            * MapHomeTimeSidebarMath.position(
                                minute: selectedMinute,
                                window: window
                            )
                        let timeTrackX = MapHomeTimeSidebarMath.trackCenterX(
                            railOriginX: MapHomeTimeSidebarMath.handleLaneWidth,
                            railWidth: railWidth,
                            numericColumnWidth: MapHomeTimeSidebarMath.rulerNumericColumnWidth,
                            activeRailWidth: activeRailWidth
                        )
                        let timeHandleCenterX = MapHomeTimeSidebarMath.handleCenterX(
                            trackX: timeTrackX,
                            activeRailWidth: activeRailWidth
                        )
                        let playheadFrame = CGRect(
                            x: railWidth + 4 + timeHandleCenterX
                                - MapHomeTimeSidebarMath.handleVisualSize.width / 2,
                            y: playheadY - 22,
                            width: MapHomeTimeSidebarMath.handleVisualSize.width,
                            height: MapHomeTimeSidebarMath.handleVisualSize.height
                        )
                        let weatherFrame = CGRect(
                            x: railWidth / 2 - itemWidth / 2,
                            y: y - itemHeight / 2,
                            width: itemWidth,
                            height: itemHeight
                        )
                        let collisionOffset = MapHomeWeatherCollisionMath.horizontalOffset(
                            weatherFrame: weatherFrame,
                            playheadFrame: playheadFrame
                        )
                        let clampedSelectedMinute = min(max(selectedMinute, 0), 1_439)
                        let isSelected = clampedSelectedMinute >= entry.startMinute
                            && clampedSelectedMinute < entry.endMinute
                        let nowMinute = Calendar.autoupdatingCurrent.dateComponents(
                            [.hour, .minute],
                            from: Date.now
                        )
                        let currentMinute = (nowMinute.hour ?? 0) * 60 + (nowMinute.minute ?? 0)
                        let isCurrent = Calendar.autoupdatingCurrent.isDate(
                            date,
                            inSameDayAs: Date.now
                        ) && currentMinute >= entry.startMinute
                            && currentMinute < entry.endMinute

                        HStack(spacing: 2) {
                            Image(systemName: entry.context.symbolName)
                                .font(.system(size: 12, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(
                                    mapHomeWeatherSymbolColor(entry.context, component: .primary),
                                    mapHomeWeatherSymbolColor(entry.context, component: .secondary)
                                )
                                .frame(width: 20)
                            Text("\(Int(entry.context.temperatureCelsius.rounded()))°C")
                                .font(.system(size: 9, weight: isSelected ? .bold : .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(isSelected ? Color.tpReferenceRose : Color.tpWeatherDark)
                        }
                        .padding(.horizontal, 3)
                        .frame(width: itemWidth, height: itemHeight)
                        .background(
                            MapHomeWeatherBackgroundKind.resolve(
                                isSelected: isSelected,
                                isCurrent: isCurrent
                            ).color,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.tpReferenceRose, lineWidth: 1.5)
                            }
                        }
                        .position(x: railWidth / 2 + collisionOffset, y: y)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            language.text(
                                "날씨 \(entry.context.condition), \(Int(entry.context.temperatureCelsius.rounded()))도",
                                "Weather \(entry.context.condition), \(Int(entry.context.temperatureCelsius.rounded())) degrees Celsius"
                            )
                        )
                        .accessibilityValue(
                            isSelected
                                ? language.text("선택된 시간", "Selected time")
                                : language.text("시간 구간", "Time interval")
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
            contexts: contexts,
            calendar: calendar
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
    static let standardDragSensitivity: CGFloat = 1.6
    static let precisionDragSensitivity: CGFloat = 0.25
    static let edgeScrollPointsPerSecond: CGFloat = 192
    static let rulerNumericColumnWidth: CGFloat = 44
    static let rulerTickWidth: CGFloat = 8
    static let rulerHourColumnWidth: CGFloat = 16
    static let rulerMinuteColumnWidth: CGFloat = 16
    static let rulerColumnSpacing: CGFloat = 2
    static let minimumRulerLabelSpacing: CGFloat = 12
    static let selectionTimeBlockWidth: CGFloat = 32
    static let handleDoubleTapHitScale: CGFloat = 1.5
    static let handleLaneWidth: CGFloat = 69
    static let handleVisualSize = CGSize(width: 44, height: 44)
    static let handleRailGap: CGFloat = 4
    static let compactWeatherSize = CGSize(width: 32, height: 22)
    static let compactWeatherGap: CGFloat = 4

    static func totalWidth(railWidth: CGFloat) -> CGFloat {
        handleLaneWidth + railWidth
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

    static func compactWeatherFrame(
        handleCenterX: CGFloat,
        handleCenterY: CGFloat,
        railHeight: CGFloat
    ) -> CGRect {
        let offset = handleVisualSize.height / 2
            + compactWeatherGap
            + compactWeatherSize.height / 2
        let preferredCenterY = handleCenterY - offset
        let centerY = preferredCenterY - compactWeatherSize.height / 2 >= 0
            ? preferredCenterY
            : min(railHeight - compactWeatherSize.height / 2, handleCenterY + offset)
        return CGRect(
            x: handleCenterX - compactWeatherSize.width / 2,
            y: centerY - compactWeatherSize.height / 2,
            width: compactWeatherSize.width,
            height: compactWeatherSize.height
        )
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

    static func rulerFontSize(durationMinutes: Int) -> CGFloat {
        switch durationMinutes {
        case ...60: 14
        case ...180: 13
        case ...360: 12
        case ...720: 11
        default: 10
        }
    }

    static func rulerColumnWidth(durationMinutes: Int) -> CGFloat {
        min(17, max(16, ceil(rulerFontSize(durationMinutes: durationMinutes) * 1.2)))
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
        let firstHour = max(0, Int(ceil(Double(window.lowerBound) / 60)))
        let lastHour = min(24, Int(floor(Double(window.upperBound) / 60)))
        let hours = firstHour <= lastHour
            ? Array(firstHour...lastHour)
            : []

        let duration = CGFloat(min(max(durationMinutes, 60), fullDayMinutes))
        let pointsPerTenMinutes = max(trackHeight, 1) * 10 / duration
        let minuteStep = pointsPerTenMinutes
            >= minimumRulerLabelSpacing(durationMinutes: durationMinutes)
            ? 10
            : 20
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

    static func showsTenMinuteRuler(durationMinutes: Int) -> Bool {
        durationMinutes <= 180
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
