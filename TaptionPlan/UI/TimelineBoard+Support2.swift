import SwiftUI
import UIKit
import MapKit

extension TimelineBoard {
    func continuousAxisMarkers(
        in span: TimeSpan
    ) -> [TimelineAxisMarker] {
        let calendar = TimelineAxisGrid.normalizedCalendar()
        let zoomDuration = span.duration
        let component: Calendar.Component
        let componentValue: Int
        let step: TimeInterval
        switch scale {
        case .day:
            component = .minute
            switch zoomDuration {
            case ...Double(5 * 60): componentValue = 1
            case ...Double(15 * 60): componentValue = 5
            case ...Double(60 * 60): componentValue = 10
            case ...Double(6 * 60 * 60): componentValue = 30
            case ...Double(12 * 60 * 60): componentValue = 60
            case ...Double(24 * 60 * 60): componentValue = 120
            case ...Double(3 * 24 * 60 * 60): componentValue = 360
            default: componentValue = 1_440
            }
            step = Double(componentValue * 60)
        case .week:
            component = .day
            componentValue = 1
            step = 86_400
        case .month:
            component = .day
            componentValue = span.duration <= 14 * 86_400 ? 1 : 2
            step = Double(componentValue) * 86_400
        case .year:
            component = .month
            componentValue = 1
            step = 31 * 86_400
        }
        let start = span.start.timeIntervalSinceReferenceDate
        let end = span.end.timeIntervalSinceReferenceDate
        var nextDate: Date
        if scale == .year {
            nextDate = calendar.dateInterval(of: .month, for: span.start)?.start
                ?? span.start
        } else if scale == .day {
            nextDate = calendar.startOfDay(for: span.start)
        } else {
            nextDate = calendar.startOfDay(for: span.start)
        }
        while nextDate < span.start {
            nextDate = calendar.date(
                byAdding: component,
                value: componentValue,
                to: nextDate
            ) ?? nextDate.addingTimeInterval(step)
        }
        var next = nextDate.timeIntervalSinceReferenceDate
        var markers: [TimelineAxisMarker] = []
        while next <= end, markers.count < 64 {
            let date = Date(timeIntervalSinceReferenceDate: next)
            let label: String
            if scale == .day && zoomDuration <= 6 * 60 * 60 {
                label = axisHourMinuteLabel(date, calendar: calendar)
            } else if scale == .day && zoomDuration <= 24 * 60 * 60 {
                let hour = calendar.component(.hour, from: date)
                label = String(format: "%02d", hour)
            } else if scale == .year {
                label = "\(calendar.component(.month, from: date))월"
            } else if scale == .week {
                label = "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date))"
            } else {
                label = "\(calendar.component(.day, from: date))"
            }
            markers.append(
                TimelineAxisMarker(
                    id: "continuous-\(next)",
                    date: date,
                    fraction: (next - start) / max(1, end - start),
                    label: label,
                    isCurrent: abs(date.timeIntervalSince(continuousCenterDate))
                        < step / 2
                )
            )
            nextDate = calendar.date(
                byAdding: component,
                value: componentValue,
                to: nextDate
            ) ?? nextDate.addingTimeInterval(step)
            next = nextDate.timeIntervalSinceReferenceDate
        }
        return markers
    }

    func isCurrentBucket(_ bucket: TimelineAxisBucket) -> Bool {
        switch scale {
        case .week:
            return TimelineAxisGrid.normalizedCalendar().isDate(
                bucket.date,
                inSameDayAs: model.selectedDate
            )
        case .month:
            return TimelineAxisGrid.normalizedCalendar().isDate(
                bucket.date,
                equalTo: model.selectedDate,
                toGranularity: .day
            )
        case .year:
            return TimelineAxisGrid.normalizedCalendar().isDate(
                bucket.date,
                equalTo: model.selectedDate,
                toGranularity: .month
            )
        case .day:
            return false
        }
    }

    var axisTickInterval: TimeInterval {
        let target = viewportVisibleSpan.duration / 6
        let supportedSteps: [TimeInterval] = [
            60,
            5 * 60,
            15 * 60,
            30 * 60,
            60 * 60,
            3 * 60 * 60,
            6 * 60 * 60,
            12 * 60 * 60,
            24 * 60 * 60,
            2 * 24 * 60 * 60,
            5 * 24 * 60 * 60,
            7 * 24 * 60 * 60,
            14 * 24 * 60 * 60,
            30 * 24 * 60 * 60,
            90 * 24 * 60 * 60,
        ]
        return supportedSteps.first { $0 >= target }
            ?? supportedSteps.last
            ?? 60
    }

    func axisTickLabel(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if viewportVisibleSpan.duration <= 60 * 60 {
            return axisHourMinuteLabel(date, calendar: calendar)
        }
        if viewportVisibleSpan.duration <= 2 * 24 * 60 * 60 {
            return String(format: "%02d", calendar.component(.hour, from: date))
        }
        if viewportVisibleSpan.duration <= 90 * 24 * 60 * 60 {
            return "\(calendar.component(.month, from: date)).\(calendar.component(.day, from: date))"
        }
        return "\(calendar.component(.month, from: date))월"
    }

    func axisHourMinuteLabel(
        _ date: Date,
        calendar: Calendar
    ) -> String {
        String(
            format: "%02d:%02d",
            calendar.component(.hour, from: date),
            calendar.component(.minute, from: date)
        )
    }

    func markerX(
        _ marker: TimelineAxisMarker,
        width: CGFloat
    ) -> CGFloat {
        min(
            max(18, width - 18),
            max(18, width * CGFloat(marker.fraction))
        )
    }

    func playheadAxisLabel(_ date: Date) -> String {
        let calendar = TimelineAxisGrid.normalizedCalendar()
        switch scale {
        case .day:
            return date.formatted(date: .omitted, time: .shortened)
        case .week:
            let weekday = date.formatted(
                Date.FormatStyle()
                    .weekday(.short)
                    .locale(Locale(identifier: "ko_KR"))
            )
            return "\(calendar.component(.month, from: date))월 \(calendar.component(.day, from: date))일 \(weekday)"
        case .month:
            return "\(calendar.component(.month, from: date))월 \(calendar.component(.day, from: date))일"
        case .year:
            return "\(calendar.component(.year, from: date))년 \(calendar.component(.month, from: date))월"
        }
    }

    func photoClusters(in visibleSpan: TimeSpan) -> [PhotoCluster] {
        PhotoClusterer.cluster(
            model.snapshot.photos.filter {
                visibleSpan.contains($0.capturedAt)
            }
        )
    }

    /// 요약 띠는 선택한 날짜의 달력 구간만 본다.  드래그는 재생 머리만
    /// 움직이므로 띠 내용은 그대로다.  움직이는 데이터 창에 딸려 다시
    /// 계산되지 않도록 따로 캐시한다.
    func summaryBuckets(in visibleSpan: TimeSpan) -> [SummaryBucket] {
        let childLevel: TimelineLevel
        switch scale {
        case .day:
            return []
        case .week:
            childLevel = .day
        case .month:
            childLevel = .week
        case .year:
            childLevel = .month
        }
        let engine = TimelineAggregationEngine()
        let outerSpan = engine.interval(
            for: scale.timelineLevel,
            containing: model.selectedDate
        )
        let key = TimelineSummaryKey(
            timelineRevision: model.timelineRevision,
            childLevel: childLevel,
            spanStart: outerSpan.start.timeIntervalSinceReferenceDate,
            spanEnd: outerSpan.end.timeIntervalSinceReferenceDate
        )
        return summaryCache.value(for: key) {
            engine.buckets(
                of: childLevel,
                inside: outerSpan,
                plans: model.snapshot.plans,
                actuals: model.snapshot.actuals,
                photos: model.snapshot.photos
            )
        }
    }

    func summaryAccessibilityLabel(
        _ bucket: SummaryBucket
    ) -> String {
        let range =
            bucket.span.start.formatted(.dateTime.month().day())
            + "부터 "
            + bucket.span.end.addingTimeInterval(-1)
                .formatted(.dateTime.month().day())
        let photoText = bucket.photoCount > 0
            ? ", 사진 \(bucket.photoCount)장"
            : ""
        return "\(range) 요약\(photoText), 탭하여 확대"
    }

    func viewportMagnifyChanged(
        factor: Double,
        anchor: Double
    ) {
        gestureMetrics.begin("zoom")
        gestureMetrics.inputSample()
        if magnifyOrigin == nil {
            magnifyOrigin = viewport
            editingPlanID = nil
            TaptionPlanDiagnosticsLogger.shared.record(
                "timeline_zoom_began",
                fields: [
                    "scale": String(format: "%.3f", factor),
                    "anchor": String(format: "%.3f", anchor),
                    "resolution": scale.rawValue,
                ]
            )
            if isContinuousTimeline {
                let originSpan = visibleSpan
                let clampedAnchor = min(1, max(0, anchor))
                let anchorFraction = viewport.start
                    + viewport.length * clampedAnchor
                continuousMagnifyOrigin = ContinuousMagnifyOrigin(
                    duration: max(
                        60,
                        originSpan.duration * viewport.length
                    ),
                    anchorDate: timelineDate(
                        at: anchorFraction,
                        in: originSpan
                    ),
                    anchor: clampedAnchor
                )
                // The live duration becomes the source of truth.  Do not
                // leave a second viewport multiplier behind to quantize it.
                viewport = .full
                dragLayoutSpan = nil
                dragLayoutSnapshot = nil
            }
        }
        guard let magnifyOrigin else { return }
        if continuousMagnifyOrigin != nil {
            let lastRender = lastViewportRenderUptime
            applyContinuousMagnification(
                factor: factor,
                force: false
            )
            if lastViewportRenderUptime != lastRender {
                gestureMetrics.renderedSample()
            }
            return
        }
        let candidate = magnifyOrigin.magnifying(
            by: factor,
            anchor: anchor,
            minimumLength: viewportMinimumLength
        )
        let uptime = ProcessInfo.processInfo.systemUptime
        guard TimelineInteractionFrameGate.shouldRender(
            lastUptime: &lastViewportRenderUptime,
            nowUptime: uptime
        ) else {
            return
        }
        gestureMetrics.renderedSample()
        viewport = candidate
    }

    func viewportMagnifyEnded(
        factor: Double,
        anchor: Double
    ) {
        guard magnifyOrigin != nil else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "timeline_zoom_ended_without_begin",
                fields: [
                    "scale": String(format: "%.3f", factor),
                    "anchor": String(format: "%.3f", anchor),
                    "resolution": scale.rawValue,
                ]
            )
            return
        }
        finishSemanticMagnification(
            factor: factor,
            anchor: anchor
        )
        magnifyOrigin = nil
        lastViewportRenderUptime = 0
        recordGestureMetrics()
        TaptionPlanDiagnosticsLogger.shared.record(
            "timeline_zoom_ended",
            fields: [
                "scale": String(format: "%.3f", factor),
                "anchor": String(format: "%.3f", anchor),
                "resolution": scale.rawValue,
            ]
        )
    }

    func finishSemanticMagnification(
        factor: Double,
        anchor: Double
    ) {
        if continuousMagnifyOrigin != nil {
            applyContinuousMagnification(factor: factor, force: true)
            let finalCenter = continuousCenterDate
            continuousMagnifyOrigin = nil
            viewport = .full
            preserveViewportAfterContinuousDrag = true
            model.selectedDate = finalCenter
            onPlayheadMove?(finalCenter)
            zoomFeedbackSequence += 1
            return
        }

        let origin = magnifyOrigin ?? viewport
        let zoomsIn = factor >= 1.15
        let zoomsOut = factor <= 0.85
        guard zoomsIn || zoomsOut else {
            // The live viewport already follows the fingers. Do not snap a
            // small but intentional pinch back to the pre-gesture range.
            return
        }

        if scale != .day {
            let targetScale = zoomsIn
                ? scale.scheduleNarrower
                : scale.scheduleBroader
            guard let targetScale else {
                viewport = origin
                return
            }
            transitionScale(
                to: targetScale,
                origin: origin,
                anchor: anchor
            )
            return
        }

        let originStage = GanttZoomStage.nearest(
            to: visibleSpan.duration * origin.length
        )
        if zoomsOut, originStage == .day {
            guard let broader = scale.scheduleBroader else {
                viewport = origin
                return
            }
            transitionScale(
                to: broader,
                origin: origin,
                anchor: anchor
            )
            return
        }

        let targetStage = zoomsIn
            ? originStage.narrower
            : originStage.broader
        guard let targetStage, targetStage >= .day else {
            viewport = origin
            return
        }
        viewport = origin.fitting(
            visibleDuration: targetStage.duration,
            within: visibleSpan.duration,
            anchor: anchor
        )
        zoomFeedbackSequence += 1
    }

    func transitionScale(
        to targetScale: TimeScale,
        origin: GanttViewport,
        anchor: Double
    ) {
        let clampedAnchor = min(1, max(0, anchor))
        let anchorFraction =
            origin.start + origin.length * clampedAnchor
        model.selectedDate = timelineDate(
            at: anchorFraction,
            in: visibleSpan
        )
        viewport = .full
        selectScaleForResolution(targetScale)
        zoomFeedbackSequence += 1
    }

    func applyContinuousMagnification(
        factor: Double,
        force: Bool
    ) {
        guard let origin = continuousMagnifyOrigin else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard TimelineInteractionFrameGate.shouldRender(
            lastUptime: &lastViewportRenderUptime,
            nowUptime: uptime,
            force: force
        ) else {
            return
        }

        let safeFactor = max(0.01, factor)
        let nleViewport = NLETimelineViewport(
            centerDate: origin.anchorDate,
            visibleDuration: origin.duration
        )
        let magnified = nleViewport.magnified(
            by: safeFactor,
            anchor: origin.anchor,
            maximumDuration: NLETimelineViewport.maximumScheduleDuration
        )
        let duration = magnified.visibleDuration
        let center = magnified.centerDate
        if continuousTimelineDuration != duration {
            continuousTimelineDuration = duration
        }
        if continuousCenterDate != center {
            continuousCenterDate = center
        }
        viewport = .full
        ensureMagnifyLayoutWindow(around: center)
    }

    func resetViewport(withFeedback: Bool = false) {
        let changed = !viewport.isFull || hasCustomContinuousDuration
        if isContinuousTimeline {
            continuousTimelineDuration = continuousDuration(
                around: model.selectedDate
            )
            if isContinuousDay {
                dayZoom = .oneHour
            }
            continuousDragOrigin = nil
        }
        viewport = .full
        dragOrigin = nil
        magnifyOrigin = nil
        continuousMagnifyOrigin = nil
        dragLayoutSpan = nil
        dragLayoutSnapshot = nil
        editingPlanID = nil
        if withFeedback, changed {
            zoomFeedbackSequence += 1
        }
    }
}
