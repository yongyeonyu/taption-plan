import SwiftUI
import UIKit

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
        return Self(
            systemImage: category.systemImage,
            tint: category.tint,
            accessibilityLabel: accessibilityLabel ?? category.title
        )
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

    static var all: [Self] {
        all(categoryColors: [:])
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
    let sourceID: UUID?

    init(
        startMinute: Int,
        endMinute: Int,
        categoryID: String,
        title: String,
        sourceID: UUID? = nil
    ) {
        self.startMinute = min(max(startMinute, 0), 1_440)
        self.endMinute = min(max(endMinute, 0), 1_440)
        self.categoryID = CanonicalCategoryPalette.orderedIDs.contains(categoryID)
            ? categoryID
            : "activity"
        self.title = title
        self.sourceID = sourceID
        id = [
            String(self.startMinute),
            String(self.endMinute),
            self.categoryID,
            sourceID?.uuidString ?? "gap",
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
        let actual: ActualRecord
        let startMinute: Int
        let endMinute: Int
        let categoryID: String
    }

    static func segments(
        from actuals: [ActualRecord],
        on date: Date,
        asOf: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MapHomeTimeRailSegment] {
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
        else { return [.wholeDayUnconfirmed] }
        let day = TimeSpan(start: dayStart, end: dayEnd)
        let candidates = AutomaticRecordTimelineEngine.activities(
            from: actuals,
            inside: day,
            asOf: asOf
        ).compactMap { actual -> Candidate? in
            let span = actual.span(asOf: asOf)
            let start = max(span.start, dayStart)
            let end = min(span.end, dayEnd)
            guard start < end else { return nil }
            let startMinute = minute(
                for: start,
                relativeTo: dayStart,
                rounding: .down
            )
            let endMinute = minute(
                for: end,
                relativeTo: dayStart,
                rounding: .up
            )
            guard startMinute < endMinute else { return nil }
            return Candidate(
                actual: actual,
                startMinute: startMinute,
                endMinute: endMinute,
                categoryID: RecordAnalysisCategoryPolicy.categoryID(for: actual)
            )
        }

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
                title: winner?.actual.title ?? "미확인",
                sourceID: winner?.actual.id
            )
            append(next, to: &result)
        }
        return result.isEmpty ? [.wholeDayUnconfirmed] : result
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
              previous.categoryID == segment.categoryID,
              previous.title == segment.title,
              previous.sourceID == segment.sourceID
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
                sourceID: previous.sourceID
            )
        )
    }

    private static func isHigherPriority(
        _ lhs: Candidate,
        than rhs: Candidate
    ) -> Bool {
        let lhsPhase = RecordAnalysisCategoryPolicy.phase(for: lhs.categoryID)
        let rhsPhase = RecordAnalysisCategoryPolicy.phase(for: rhs.categoryID)
        if lhsPhase.precedence != rhsPhase.precedence {
            return lhsPhase.precedence > rhsPhase.precedence
        }
        if lhs.actual.manuallyCorrected != rhs.actual.manuallyCorrected {
            return lhs.actual.manuallyCorrected
        }
        let lhsConfidence = confidenceRank(lhs.actual.confidence)
        let rhsConfidence = confidenceRank(rhs.actual.confidence)
        if lhsConfidence != rhsConfidence { return lhsConfidence > rhsConfidence }
        let lhsSource = sourceRank(lhs.actual.source)
        let rhsSource = sourceRank(rhs.actual.source)
        if lhsSource != rhsSource { return lhsSource > rhsSource }
        if lhs.actual.startedAt != rhs.actual.startedAt {
            return lhs.actual.startedAt > rhs.actual.startedAt
        }
        if lhs.actual.createdAt != rhs.actual.createdAt {
            return lhs.actual.createdAt > rhs.actual.createdAt
        }
        return lhs.actual.id.uuidString > rhs.actual.id.uuidString
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

/// A narrow, non-resizing time rail for the map home screen.
/// The handle changes the selected minute only; it never changes panel size.
struct MapHomeTimeSidebar: View {
    let date: Date
    @Binding var selectedMinute: Int
    let activity: MapHomeTimeSidebarActivity?
    let segments: [MapHomeTimeRailSegment]
    let categoryColors: [String: String]
    let zoomResetToken: Int
    var zoomLevel: CGFloat = 0
    var onSelectionChanged: ((Int) -> Void)?
    var onSectionEdit: (() -> Void)?
    var onZoomChanged: ((CGFloat) -> Void)?

    @State private var dragStartMinute: Int?
    @State private var lastRenderUptime: TimeInterval = 0
    @State private var isPrecisionMode = false
    @State private var visibleDurationMinutes = MapHomeTimeSidebarMath.fullDayMinutes
    @State private var magnificationStartDuration = MapHomeTimeSidebarMath.fullDayMinutes
    @State private var visibleStartMinute = 0
    @State private var viewportDragStartMinute: Int?
    @State private var isHandleDragging = false

    private let railWidth: CGFloat
    // Keep the numeric rail visibly separated from both the map header and
    // the bottom ad boundary while preserving the same minute-to-pixel scale.
    private let verticalInset: CGFloat = 14
    private let activeRailWidth: CGFloat = 12
    private let numericColumnWidth: CGFloat = 27

    init(
        date: Date,
        selectedMinute: Binding<Int>,
        activity: MapHomeTimeSidebarActivity? = nil,
        segments: [MapHomeTimeRailSegment] = [],
        categoryColors: [String: String] = [:],
        zoomResetToken: Int = 0,
        zoomLevel: CGFloat = 0,
        railWidth: CGFloat = 58,
        onSelectionChanged: ((Int) -> Void)? = nil,
        onSectionEdit: (() -> Void)? = nil,
        onZoomChanged: ((CGFloat) -> Void)? = nil
    ) {
        self.date = date
        self._selectedMinute = selectedMinute
        self.activity = activity
        self.segments = segments
        self.categoryColors = categoryColors
        self.zoomResetToken = zoomResetToken
        self.zoomLevel = min(max(zoomLevel, 0), 1)
        self.railWidth = max(58, railWidth)
        self.onSelectionChanged = onSelectionChanged
        self.onSectionEdit = onSectionEdit
        self.onZoomChanged = onZoomChanged
    }

    var body: some View {
        GeometryReader { proxy in
            let railHeight = max(220, proxy.size.height)
            let trackHeight = max(1, railHeight - verticalInset * 2)
            let maxMinute = MapHomeTimeSidebarMath.maximumSelectableMinute(
                for: date,
                now: Date()
            )
            let minute = min(max(selectedMinute, 0), maxMinute)
            let visibleWindow = MapHomeTimeSidebarMath.visibleWindow(
                startMinute: visibleStartMinute,
                durationMinutes: visibleDurationMinutes,
                centerMinute: minute
            )
            let selectedY = isViewportInteraction
                ? verticalInset + trackHeight / 2
                : verticalInset + trackHeight * MapHomeTimeSidebarMath.position(
                    minute: minute,
                    window: visibleWindow
                )
            let trackX = railWidth - numericColumnWidth - activeRailWidth / 2 - 1

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        timeTapGesture(
                            trackHeight: trackHeight,
                            maxMinute: maxMinute,
                            visibleWindow: visibleWindow
                        )
                    )
                    .simultaneousGesture(viewportDragGesture(trackHeight: trackHeight))

                Rectangle()
                    .fill(Color.white.opacity(0.68))
                    // Keep the existing white numeric gutter continuous past
                    // both ends of the coloured rail.
                    .frame(width: numericColumnWidth + 3, height: railHeight)
                    .position(
                        x: railWidth - (numericColumnWidth + 3) / 2,
                        y: railHeight / 2
                    )
                    .allowsHitTesting(false)

                ZStack {
                    Rectangle()
                        .fill(Color.tpInk.opacity(0.72))

                    ForEach(displaySegments) { segment in
                        let start = max(min(segment.startMinute, visibleWindow.upperBound), visibleWindow.lowerBound)
                        let end = min(max(segment.endMinute, visibleWindow.lowerBound), visibleWindow.upperBound)
                        if start < end {
                            Rectangle()
                                .fill(
                                    Color(hex: categoryColorHex(
                                        segment.categoryID
                                    )).opacity(
                                        segment.categoryID == "unconfirmed"
                                            ? 0.82
                                            : 0.94
                                    )
                                )
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

                ForEach(MapHomeTimeSidebarMath.visibleHours(window: visibleWindow), id: \.self) { hour in
                    let y = verticalInset + trackHeight * MapHomeTimeSidebarMath.position(
                        minute: hour * 60,
                        window: visibleWindow
                    )
                    HStack(spacing: 3) {
                        Capsule()
                            .fill(Color.tpInk.opacity(hour.isMultiple(of: 6) ? 0.38 : 0.18))
                            .frame(width: hour.isMultiple(of: 6) ? 8 : 5, height: 1.5)
                        Text(String(format: "%02d", hour))
                            .font(.system(size: 8, weight: hour.isMultiple(of: 6) ? .bold : .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.tpInk.opacity(hour.isMultiple(of: 6) ? 0.82 : 0.52))
                            .frame(width: 16, alignment: .leading)
                    }
                    .frame(width: numericColumnWidth, alignment: .leading)
                    .position(
                        x: railWidth - numericColumnWidth / 2,
                        y: y
                    )
                    .allowsHitTesting(false)
                }

                selectionHandle(
                    minute: minute,
                    y: selectedY,
                    trackX: trackX,
                    trackHeight: trackHeight,
                    maxMinute: maxMinute,
                    visibleWindow: visibleWindow
                )
            }
            .frame(width: railWidth, height: railHeight)
            .contentShape(Rectangle())
            .simultaneousGesture(magnificationGesture())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("시간 선택")
            .accessibilityValue(timeLabel(for: minute))
        }
        .frame(width: railWidth)
        .onDisappear {
            dragStartMinute = nil
            isPrecisionMode = false
            isHandleDragging = false
        }
        .onChange(of: zoomResetToken) { _, _ in
            visibleDurationMinutes = MapHomeTimeSidebarMath.fullDayMinutes
            magnificationStartDuration = MapHomeTimeSidebarMath.fullDayMinutes
            visibleStartMinute = 0
        }
        .onChange(of: zoomLevel) { _, level in
            let duration = MapHomeTimeSidebarMath.duration(for: level)
            if duration != visibleDurationMinutes {
                visibleDurationMinutes = duration
                visibleStartMinute = MapHomeTimeSidebarMath.startMinute(
                    centerMinute: selectedMinute,
                    durationMinutes: duration
                )
                magnificationStartDuration = duration
            }
        }
    }

    private func selectionHandle(
        minute: Int,
        y: CGFloat,
        trackX: CGFloat,
        trackHeight: CGFloat,
        maxMinute: Int,
        visibleWindow: ClosedRange<Int>
    ) -> some View {
        let handleHeight: CGFloat = 40
        let fallbackActivity = MapHomeTimeSidebarActivity.majorCategory(
            "unconfirmed",
            categoryColors: categoryColors
        )
        return ZStack {
            Button {
                onSectionEdit?()
            } label: {
                Image(systemName: activity?.systemImage ?? fallbackActivity.systemImage)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(activity?.tint ?? fallbackActivity.tint)
                    .frame(width: 32, height: handleHeight)
                    .background(
                        Color.tpInk.opacity(0.90),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(
                                (activity?.tint ?? fallbackActivity.tint)
                                    .opacity(0.45),
                                lineWidth: 1
                            )
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(activity?.accessibilityLabel ?? fallbackActivity.accessibilityLabel)
            .accessibilityHint("탭하면 섹션 편집을 엽니다")
            .position(x: trackX - 23, y: handleHeight / 2)

            VStack(spacing: -1) {
                Text(String(format: "%02d", minute / 60))
                Text(String(format: "%02d", minute % 60))
            }
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.white)
            .frame(width: 32, height: 40)
            .background(
                isPrecisionMode
                    ? Color.green.opacity(0.90)
                    : Color.tpInk.opacity(0.90),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .simultaneousGesture(precisionLongPressGesture())
            .simultaneousGesture(precisionReleaseGesture())
            .accessibilityHidden(true)
            .position(x: trackX + activeRailWidth / 2 + 17, y: handleHeight / 2)
        }
        .frame(width: railWidth, height: handleHeight)
        .position(x: railWidth / 2, y: y)
        .simultaneousGesture(dragGesture(
            trackHeight: trackHeight,
            maxMinute: maxMinute,
            visibleWindow: visibleWindow
        ))
    }

    private func precisionLongPressGesture() -> some Gesture {
        LongPressGesture(minimumDuration: 1.0, maximumDistance: 24)
            .onChanged { isPressing in
                guard isPressing, !isPrecisionMode else { return }
                isPrecisionMode = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
    }

    private func precisionReleaseGesture() -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onEnded { _ in
                // Defer the reset until the parent drag publishes its final
                // sample, so the release sample still uses quarter speed.
                DispatchQueue.main.async {
                    isPrecisionMode = false
                }
            }
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
                publish(minute, force: true)
            }
    }

    private func dragGesture(
        trackHeight: CGFloat,
        maxMinute: Int,
        visibleWindow: ClosedRange<Int>
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                isHandleDragging = true
                if dragStartMinute == nil {
                    dragStartMinute = min(max(selectedMinute, 0), maxMinute)
                    lastRenderUptime = 0
                }
                let base = dragStartMinute ?? selectedMinute
                let minute = MapHomeTimeSidebarMath.minuteByDragging(
                    baseMinute: base,
                    translation: value.translation.height,
                    trackHeight: trackHeight,
                    maxMinute: maxMinute,
                    visibleStartMinute: visibleWindow.lowerBound,
                    visibleDurationMinutes: visibleWindow.upperBound - visibleWindow.lowerBound,
                    sensitivity: isPrecisionMode ? 0.25 : 1
                )
                publish(minute, force: false)
            }
            .onEnded { value in
                let base = dragStartMinute ?? selectedMinute
                let minute = MapHomeTimeSidebarMath.minuteByDragging(
                    baseMinute: base,
                    translation: value.translation.height,
                    trackHeight: trackHeight,
                    maxMinute: maxMinute,
                    visibleStartMinute: visibleWindow.lowerBound,
                    visibleDurationMinutes: visibleWindow.upperBound - visibleWindow.lowerBound,
                    sensitivity: isPrecisionMode ? 0.25 : 1
                )
                publish(minute, force: true)
                dragStartMinute = nil
                isPrecisionMode = false
                isHandleDragging = false
            }
    }

    private func viewportDragGesture(trackHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard visibleDurationMinutes < MapHomeTimeSidebarMath.fullDayMinutes,
                      !isHandleDragging
                else { return }
                if viewportDragStartMinute == nil { viewportDragStartMinute = visibleStartMinute }
                let base = viewportDragStartMinute ?? visibleStartMinute
                let delta = Int((value.translation.height / max(trackHeight, 1) * CGFloat(visibleDurationMinutes)).rounded())
                visibleStartMinute = min(max(base + delta, 0), MapHomeTimeSidebarMath.fullDayMinutes - visibleDurationMinutes)
                let fixedMinute = MapHomeTimeSidebarMath.minuteByFixedPlayhead(
                    trackHeight: trackHeight,
                    verticalInset: verticalInset,
                    maxMinute: MapHomeTimeSidebarMath.maximumSelectableMinute(for: date, now: Date()),
                    visibleStartMinute: visibleStartMinute,
                    visibleDurationMinutes: visibleDurationMinutes
                )
                publish(fixedMinute, force: false)
            }
            .onEnded { _ in viewportDragStartMinute = nil }
    }

    private func magnificationGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if magnificationStartDuration == MapHomeTimeSidebarMath.fullDayMinutes {
                    magnificationStartDuration = visibleDurationMinutes
                }
                let next = MapHomeTimeSidebarMath.durationByMagnification(
                    startDurationMinutes: magnificationStartDuration,
                    magnification: value
                )
                if next != visibleDurationMinutes {
                    visibleDurationMinutes = next
                    visibleStartMinute = MapHomeTimeSidebarMath.startMinute(
                        centerMinute: selectedMinute,
                        durationMinutes: next
                    )
                    onZoomChanged?(MapHomeTimeSidebarMath.zoomLevel(for: next))
                }
            }
            .onEnded { _ in
                magnificationStartDuration = visibleDurationMinutes
            }
    }

    private func publish(_ minute: Int, force: Bool) {
        let resolved = min(max(minute, 0), MapHomeTimeSidebarMath.maximumSelectableMinute(for: date, now: Date()))
        let uptime = ProcessInfo.processInfo.systemUptime
        guard TimelineInteractionFrameGate.shouldRender(
            lastUptime: &lastRenderUptime,
            nowUptime: uptime,
            force: force
        ) else { return }
        guard selectedMinute != resolved else { return }
        selectedMinute = resolved
        onSelectionChanged?(resolved)
    }

    private func timeLabel(for minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private var displaySegments: [MapHomeTimeRailSegment] {
        segments.isEmpty ? [.wholeDayUnconfirmed] : segments
    }

    private var isViewportInteraction: Bool {
        visibleDurationMinutes < MapHomeTimeSidebarMath.fullDayMinutes && !isHandleDragging
    }
}

enum MapHomeTimeSidebarMath {
    static let fullDayMinutes = 1_440
    static let zoomDurations = [1_440, 720, 360, 180, 60]

    static func zoomLevel(for durationMinutes: Int) -> CGFloat {
        let index = zoomDurations.closestIndex(to: durationMinutes)
        return 1 - CGFloat(index) / CGFloat(zoomDurations.count - 1)
    }

    static func durationByMagnification(
        startDurationMinutes: Int,
        magnification: CGFloat
    ) -> Int {
        let startIndex = zoomDurations.firstIndex(of: startDurationMinutes)
            ?? zoomDurations.closestIndex(to: startDurationMinutes)
        let steps = Int((log(max(Double(magnification), 0.01)) / log(2)).rounded())
        return zoomDurations[min(max(startIndex + steps, 0), zoomDurations.count - 1)]
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

    static func duration(for level: CGFloat) -> Int {
        let index = Int(((1 - min(max(level, 0), 1)) * CGFloat(zoomDurations.count - 1)).rounded())
        return zoomDurations[min(max(index, 0), zoomDurations.count - 1)]
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

    static func minuteByDragging(
        baseMinute: Int,
        translation: CGFloat,
        trackHeight: CGFloat,
        maxMinute: Int,
        visibleStartMinute: Int = 0,
        visibleDurationMinutes: Int = fullDayMinutes,
        sensitivity: CGFloat = 1
    ) -> Int {
        guard trackHeight > 0 else { return min(max(baseMinute, 0), maxMinute) }
        let duration = min(max(visibleDurationMinutes, 1), fullDayMinutes)
        let delta = Int((translation / trackHeight * CGFloat(duration) * max(sensitivity, 0)).rounded())
        let lower = min(max(visibleStartMinute, 0), fullDayMinutes - duration)
        let upper = min(max(lower + duration, 0), maxMinute)
        return min(max(baseMinute + delta, lower), upper)
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
