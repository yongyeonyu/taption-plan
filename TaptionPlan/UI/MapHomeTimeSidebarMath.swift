import SwiftUI

// 사이드바 눈금·확대·드래그 계산. 화면(View)과 분리해 테스트로 고정한다(PRF1101A01).

enum MapHomeTimeSidebarMath {
    static let fullDayMinutes = 1_440
    static let zoomDurations = [1_440, 720, 360, 180, 60]
    /// 트랙 위·아래 여백. 아래 여백 안에 원형 연필 단추가 들어가, 안쪽 내용(눈금·트랙)을 28에서 40으로 줄였다(ARC1030A05).
    static let verticalInset: CGFloat = 40
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
    /// 4pt 움직여야 손잡이 드래그가 시작된다. 그 아래는 탭(한 번 알림·두 번 편집)으로 처리한다(PRF1101A01).
    static let handleDragMinimumDistance: CGFloat = 4
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

    static func startMinuteRevealingSelection(
        selectedMinute: Int,
        visibleStartMinute: Int,
        durationMinutes: Int
    ) -> Int {
        let duration = min(max(durationMinutes, 60), fullDayMinutes)
        let start = min(max(visibleStartMinute, 0), fullDayMinutes - duration)
        if (start...(start + duration)).contains(selectedMinute) { return start }
        return startMinute(centerMinute: selectedMinute, durationMinutes: duration)
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

    static func segmentCenterPosition(
        start: Int,
        end: Int,
        window: ClosedRange<Int>
    ) -> CGFloat {
        (position(minute: start, window: window)
            + position(minute: end, window: window)) / 2
    }

    static func unconfirmedReviewMarkerCenters(
        segments: [MapHomeTimeRailSegment],
        window: ClosedRange<Int>,
        trackHeight: CGFloat,
        verticalInset: CGFloat = MapHomeTimeSidebarMath.verticalInset
    ) -> [String: CGFloat] {
        let height = max(0, trackHeight)
        let centers = segments.compactMap { segment -> (String, CGFloat)? in
            let start = max(segment.startMinute, window.lowerBound)
            let end = min(segment.endMinute, window.upperBound)
            guard start < end else { return nil }
            return (
                segment.id,
                verticalInset + height * segmentCenterPosition(
                    start: start,
                    end: end,
                    window: window
                )
            )
        }
        return Dictionary(uniqueKeysWithValues: centers)
    }

    /// 미확인 아이콘끼리 아이콘 크기(26pt)보다 가까우면 한 묶음으로 본다. 위에서 아래 순서로 묶는다.
    static func reviewMarkerGroups(
        segments: [MapHomeTimeRailSegment],
        centers: [String: CGFloat],
        iconSize: CGFloat = 26
    ) -> [[MapHomeTimeRailSegment]] {
        let sorted = segments.sorted { (centers[$0.id] ?? 0) < (centers[$1.id] ?? 0) }
        var groups: [[MapHomeTimeRailSegment]] = []
        var lastY: CGFloat?
        for segment in sorted {
            let y = centers[segment.id] ?? 0
            if let lastY, y - lastY < iconSize, !groups.isEmpty {
                groups[groups.count - 1].append(segment)
            } else {
                groups.append([segment])
            }
            lastY = y
        }
        return groups
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
        trackHeight: CGFloat,
        minimumStep: Int = 0
    ) -> MapHomeTimeRulerLabels {
        let hours = visibleHourLabels(
            window: window,
            durationMinutes: durationMinutes,
            trackHeight: trackHeight
        )

        let minuteStep = minuteRulerStep(
            durationMinutes: durationMinutes,
            trackHeight: trackHeight,
            minimumStep: minimumStep
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

    /// 분 글자 간격. 화면 높이로 정한 간격과 사용자가 고른 최소 간격(`minimumStep`) 중 넓은 쪽을 쓴다.
    static func minuteRulerStep(
        durationMinutes: Int,
        trackHeight: CGFloat,
        minimumStep: Int = 0
    ) -> Int {
        let duration = CGFloat(min(max(durationMinutes, 1), fullDayMinutes))
        let pointsPerMinute = max(trackHeight, 1) / duration
        let spacing = minimumRulerLabelSpacing(durationMinutes: durationMinutes)
        let fitted = [1, 5, 10, 15, 20, 30, 60, 120].first {
            pointsPerMinute * CGFloat($0) >= spacing
        } ?? 30
        return max(fitted, minimumStep)
    }

    static func visibleRulerRows(
        window: ClosedRange<Int>,
        durationMinutes: Int,
        trackHeight: CGFloat,
        minimumStep: Int = 0
    ) -> [MapHomeTimeRulerRow] {
        let labels = visibleRulerLabels(
            window: window,
            durationMinutes: durationMinutes,
            trackHeight: trackHeight,
            minimumStep: minimumStep
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

/// 오늘 날씨 칩이 지금을 가로지르면 지난 부분과 남은 부분으로 나눈다.
/// 같은 날씨가 길게 이어져 한 칩이 지난 시간까지 덮으면 끝 시각이 미래라 지난 칸 비활성이 사라졌다(WTH1101A01).
enum MapHomeWeatherPastSplit {
    static func ranges(start: Int, end: Int, currentMinute: Int?) -> [Range<Int>] {
        guard let now = currentMinute, start < now, now < end else { return [start..<end] }
        return [start..<now, now..<end]
    }
}

private extension Array where Element == Int {
    func closestIndex(to value: Int) -> Int {
        enumerated().min(by: { abs($0.element - value) < abs($1.element - value) })?.offset ?? 0
    }
}
