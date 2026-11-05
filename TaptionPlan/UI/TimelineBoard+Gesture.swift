import SwiftUI
import UIKit
import MapKit

extension TimelineBoard {
    /// 드래그하는 동안 쓰는 데이터 창.  손가락이 움직이는 도중에는 이 창을
    /// 다시 만들지 않는다.  전체 기록을 한 번 더 계산하는 순간 그 프레임이
    /// 통째로 사라지기 때문이다.  대신 보이는 구간의 다섯 배를 미리 담고,
    /// 최종 위치는 제스처가 끝날 때 정확한 구간으로 다시 그린다.
    ///
    /// 창의 중심은 보이는 구간 길이의 격자에 맞춰 둔다.  손을 뗀 자리마다
    /// 경계가 조금씩 달라지면 같은 곳을 다시 훑어도 캐시가 매번 빗나간다.
    var dragLayoutWindow: TimeSpan {
        let currentSpan = visibleSpan
        let unit = max(60, currentSpan.duration)
        let center = currentSpan.start.timeIntervalSinceReferenceDate
            + currentSpan.duration / 2
        let snappedCenter = (center / unit).rounded() * unit
        let half = unit * 2.5
        return TimeSpan(
            start: Date(
                timeIntervalSinceReferenceDate: snappedCenter - half
            ),
            end: Date(timeIntervalSinceReferenceDate: snappedCenter + half)
        )
    }

    func zoomIntoSummary(_ bucket: SummaryBucket) {
        model.selectedDate = bucket.span.start
        switch scale {
        case .week:
            selectScaleForResolution(.day)
        case .month:
            selectScaleForResolution(.week)
        case .year:
            selectScaleForResolution(.month)
        case .day:
            break
        }
    }

    func viewportDragGesture(
        width: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard abs(value.translation.width)
                        > abs(value.translation.height) else {
                    return
                }
                viewportDragChanged(
                    translationWidth: value.translation.width,
                    width: width
                )
            }
            .onEnded { value in
                viewportDragEnded(
                    translationWidth: value.translation.width,
                    width: width
                )
            }
    }

    func viewportDragChanged(
        translationWidth: CGFloat,
        width: CGFloat
    ) {
        guard editingPlanID == nil else { return }
        gestureMetrics.begin("pan")
        gestureMetrics.inputSample()
        do {
                if isContinuousTimeline {
                    if continuousDragOrigin == nil {
                        continuousDragOrigin = continuousCenterDate
                        continuousTimelineDuration = visibleSpan.duration
                        editingPlanID = nil
                        lastContinuousRenderUptime = 0
                    }
                    if dragLayoutSpan == nil {
                        let window = dragLayoutWindow
                        dragLayoutSpan = window
                        dragLayoutSnapshot = cachedLayoutSnapshot(in: window)
                    }
                    guard let continuousDragOrigin else { return }
                    let candidate = NLETimelineViewport(
                        centerDate: continuousDragOrigin,
                        visibleDuration: activeContinuousDuration
                    )
                    .panned(
                        by: Double(translationWidth),
                        viewportWidth: Double(max(1, width))
                    )
                    .centerDate
                    let uptime = ProcessInfo.processInfo.systemUptime
                    guard TimelineInteractionFrameGate.shouldRender(
                        lastUptime: &lastContinuousRenderUptime,
                        nowUptime: uptime
                    ) else {
                        return
                    }
                    gestureMetrics.renderedSample()
                    guard continuousCenterDate != candidate else { return }
                    continuousCenterDate = candidate
                } else {
                    if dragOrigin == nil {
                        dragOrigin = viewport
                    }
                    guard let dragOrigin else { return }
                    let candidate = dragOrigin.panning(
                        translation: Double(translationWidth),
                        viewportWidth: Double(width)
                    )
                    let uptime = ProcessInfo.processInfo.systemUptime
                    guard TimelineInteractionFrameGate.shouldRender(
                        lastUptime: &lastViewportRenderUptime,
                        nowUptime: uptime
                    ) else {
                        return
                    }
                    gestureMetrics.renderedSample()
                    guard viewport != candidate else { return }
                    viewport = candidate
                }
        }
    }

    func viewportDragEnded(
        translationWidth: CGFloat,
        width: CGFloat
    ) {
        do {
                if isContinuousTimeline {
                    var finalDate = continuousCenterDate
                    if let continuousDragOrigin {
                        finalDate = NLETimelineViewport(
                            centerDate: continuousDragOrigin,
                            visibleDuration: activeContinuousDuration
                        )
                        .panned(
                            by: Double(translationWidth),
                            viewportWidth: Double(max(1, width))
                        )
                        .centerDate
                    }
                    // 손을 뗀 자리가 곧 최종 자리다. 기록이 없는 구간에
                    // 멈추면 그 빈 구간을 보여 준다. 예전에는 가장 가까운
                    // 기록으로 끌어당겼는데, 아직 아무것도 없는 앞날을 펼쳐
                    // 계획을 세우려 할 때마다 화면이 되돌아왔다.
                    continuousCenterDate = finalDate
                    // Changing the selected date normally resets the
                    // viewport. A continuous drag is different: it pans the
                    // already zoomed range, so keep that zoom after commit.
                    preserveViewportAfterContinuousDrag = true
                    let preservedViewport = viewport
                    model.selectedDate = finalDate
                    onPlayheadMove?(finalDate)
                    // Restore synchronously as well as in the selected-date
                    // observer. This covers the case where the parent view
                    // re-renders before that observer is delivered.
                    viewport = preservedViewport
                    lastContinuousRenderUptime = 0
                    dragLayoutSpan = nil
                    dragLayoutSnapshot = nil
                } else if let dragOrigin {
                    // Commit the final sample even when the last 240 Hz
                    // callback arrived inside the 60 Hz presentation gate.
                    viewport = dragOrigin.panning(
                        translation: Double(translationWidth),
                        viewportWidth: Double(width)
                    )
                    if dragOrigin.isFull,
                       abs(translationWidth) > width * 0.18 {
                        // At the default full-period view, a horizontal swipe
                        // crosses the period boundary instead of stopping at
                        // the edge. Zoomed views retain the existing free pan.
                        model.shiftSelectedDate(
                            by: translationWidth < 0 ? 1 : -1
                        )
                    }
                }
                dragOrigin = nil
                continuousDragOrigin = nil
                lastViewportRenderUptime = 0
        }
        recordGestureMetrics()
    }

    var viewportMagnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.001)
            .onChanged { value in
                viewportMagnifyChanged(
                    factor: Double(value.magnification),
                    anchor: Double(value.startAnchor.x)
                )
            }
            .onEnded { value in
                viewportMagnifyEnded(
                    factor: Double(value.magnification),
                    anchor: Double(value.startAnchor.x)
                )
            }
    }

    func recordGestureMetrics() {
        guard let fields = gestureMetrics.finish() else { return }
        TaptionPlanDiagnosticsLogger.shared.record(
            "timeline_gesture_metrics",
            fields: fields
        )
    }

    func handleRowTap(_ row: TimelineRowModel) {
        selectedRowID = row.id
        if row.id.hasPrefix("dayPhase."),
           let block = nearestBlock(
               in: row.blocks,
               to: continuousCenterDate
           ) {
            onSelection?(selectionFromBlock(block))
            return
        }
        let selectableBlocks = row.blocks
            .filter { !$0.isActual && $0.planID != nil }
            .sorted {
                ($0.startsAt ?? .distantPast) < ($1.startsAt ?? .distantPast)
            }
        if let block = selectableBlocks.first {
            onSelection?(selectionFromBlock(block))
            return
        }

        guard let categoryID = row.categoryID else { return }
        if categoryID == "calendar" {
            onSelection?(
                TimelineSelection(
                    title: "일정",
                    span: visibleSpan,
                    planID: nil,
                    isRoute: false,
                    categoryID: "calendar",
                    categoryName: "일정"
                )
            )
            return
        }
        onSelection?(
            TimelineSelection(
                title: row.title,
                span: visibleSpan,
                planID: nil,
                isRoute: categoryID == "movement" || categoryID == "location",
                categoryID: categoryID,
                categoryName: row.title
            )
        )
    }

    func handleTap(_ block: TimelineBlock) {
        let selection = selectionFromBlock(block)
        onSelection?(selection)

        if selection.categoryID == ReviewCoverageEngine.unconfirmedCategoryID {
            model.detail = .unconfirmedEditor(selection.span)
            return
        }

        // A stored actual record is the editable source for the selected
        // timeline block.  Open its detail editor directly so a tap on the
        // timetable is enough to correct the displayed activity and time.
        // The editor persists a correction while keeping automatic sensor /
        // HealthKit source values unchanged.
        if let actualID = selection.actualID,
           model.snapshot.actuals.contains(where: { $0.id == actualID }) {
            model.detail = .actualEditor(actualID)
            return
        }

        if block.opensLocationTimeline {
            return
        }

        if block.groupCount != nil {
            if let planID = block.planID {
                model.openGroup(planID)
            }
            return
        }

    }
}
