import SwiftUI
import UIKit
import MapKit

struct TimelineBoard: View {
    @Bindable var model: AppModel

    let scale: TimeScale

    let storedPlans: [PlanRecord]

    var isGroup = false

    var usesFullWidthRuler = false

    @Binding var dayZoom: TimelineZoomPreset

    @Binding var editingPlanID: UUID?

    var onPlayheadMove: ((Date) -> Void)?

    var onSelection: ((TimelineSelection) -> Void)?

    var onFocus: ((TimelineSelection) -> Void)?

    var onPhotoSelection: ((PhotoCluster) -> Void)?

    @State var viewport = GanttViewport.full

    @State var dragOrigin: GanttViewport?

    @State var magnifyOrigin: GanttViewport?

    @State var continuousCenterDate: Date = .now

    @State var continuousDragOrigin: Date?

    @State var continuousTimelineDuration: TimeInterval = 86_400

    @State var preserveViewportAfterContinuousDrag = false

    // During a continuous-day drag, keep a slightly wider data window alive
    // so the rows are not rebuilt on every 240 Hz touch sample.  Blocks carry
    // their source dates and are reprojected against the moving display span
    // at render time; the wider window is rebuilt only when a drag starts or
    // ends.
    @State var dragLayoutSpan: TimeSpan?

    /// Keep row geometry stable while the timeline is being dragged.
    @State var dragLayoutSnapshot: NLETimelineRenderSnapshot?

    @State var zoomFeedbackSequence = 0

    @State var continuousMagnifyOrigin: ContinuousMagnifyOrigin?

    @State var selectedRowID: String?

    @State var layoutCache = NLETimelineRenderCache()

    @State var dataIndexCache = TimelineBoardDataIndexCache()

    @State var summaryCache = TimelineSummaryCache()

    @State var lastContinuousRenderUptime: TimeInterval = 0

    // Touch hardware can deliver 120/240 samples per second, while the
    // timeline only needs to invalidate at the display cadence.  Keeping a
    // separate gate for viewport gestures prevents day, week, and month
    // pans/pinches from rebuilding every row for every sample.
    @State var lastViewportRenderUptime: TimeInterval = 0

    // This reference is intentionally mutated without publishing SwiftUI
    // state. It aggregates 120/240 Hz input and emits one support event at
    // gesture end, keeping the render path free of per-sample diagnostics.
    @State var gestureMetrics = TimelineGestureMetrics()

    // Keep the ruler compact so the timeline retains the larger share of the
    // screen while still leaving room for labels and holiday names.
    let axisHeight: CGFloat = 34

    var body: some View {
        // Resolve the moving span once per render pass.  Before this local
        // snapshot was introduced, every row and every gesture overlay asked
        // for `visibleSpan` independently, rebuilding Calendar intervals
        // several dozen times while a 240 Hz touch stream was being reduced
        // to the 60 Hz display budget.
        let displaySpan = visibleSpan
        let layoutSpan = dragLayoutSpan ?? displaySpan
        let layout = dragLayoutSnapshot ?? cachedLayoutSnapshot(in: layoutSpan)
        // Axis labels are cheap to derive and must follow the moving
        // playhead even while the wider drag window keeps row geometry
        // cached.
        let displayAxisMarkers = dragLayoutSpan == nil
            ? layout.axisMarkers
            : axisMarkers(in: displaySpan)
        let visibleDuration = displaySpan.duration * viewport.length
        let cachedDragViewport = dragLayoutSpan.flatMap {
            TimelineCachedViewportProjection.viewport(
                displaySpan: displaySpan,
                dataSpan: $0,
                viewport: viewport
            )
        }
        let rowViewport = cachedDragViewport ?? viewport
        let usesCachedBlockFractions = dragLayoutSpan == nil
            || cachedDragViewport != nil
        GeometryReader { boardProxy in
            let contentTimelineWidth = max(
                1,
                boardProxy.size.width - scheduleLabelColumnWidth
            )
            let rulerTimelineWidth = max(
                1,
                boardProxy.size.width
                    - (usesFullWidthRuler ? 0 : scheduleLabelColumnWidth)
            )
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    GeometryReader { _ in
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    editingPlanID = nil
                                }

                            // Rows can grow substantially once automatic
                            // location/activity history is populated. Lazy
                            // creation keeps off-screen rows out of the 240 Hz
                            // interaction path while fixed row heights still
                            // preserve the scrollable content size.
                            LazyVStack(spacing: 0) {
                                ForEach(layout.rows) { row in
                                    if row.id == "photo" {
                                        photoRow(layout.photoClusters)
                                            .draggable(row.id)
                                            .dropDestination(for: String.self) {
                                                sourceIDs, _ in
                                                guard let sourceID = sourceIDs.first
                                                else { return false }
                                                return finishRowDrop(
                                                    sourceID: sourceID,
                                                    targetID: row.id,
                                                    rows: layout.rows
                                                )
                                            }
                                    } else {
                                        TimelineRow(
                                            row: row,
                                            isSelected: selectedRowID == row.id,
                                            editingPlanID: editingPlanID,
                                            visibleDuration: visibleDuration,
                                            viewport: rowViewport,
                                            displaySpan: displaySpan,
                                            scale: scale,
                                            useCachedBlockFractions:
                                                usesCachedBlockFractions,
                                            onBlockTap: handleTap,
                                            onBlockDoubleTap: focusOnBlock,
                                            onEdit: { editingPlanID = $0 },
                                            onMove: { block, delta in
                                                guard let planID = block.planID else {
                                                    return
                                                }
                                                model.movePlan(planID, by: delta)
                                            },
                                            onResizeStart: { block, delta in
                                                guard let planID = block.planID else {
                                                    return
                                                }
                                                model.resizePlan(
                                                    planID,
                                                    startDelta: delta
                                                )
                                            },
                                            onResizeEnd: { block, delta in
                                                guard let planID = block.planID else {
                                                    return
                                                }
                                                model.resizePlan(
                                                    planID,
                                                    endDelta: delta
                                                )
                                            },
                                            onRowTap: { handleRowTap(row) },
                                            onDrop: { sourceID in
                                                finishRowDrop(
                                                    sourceID: sourceID,
                                                    targetID: row.id,
                                                    rows: layout.rows
                                                )
                                            }
                                        )
                                    }
                                }

                                if scale != .day {
                                    summaryStrip(
                                        buckets: layout.summaryBuckets,
                                        colors: layout.summaryColors
                                    )
                                }
                            }

                            gridLines(markers: displayAxisMarkers)
                                .allowsHitTesting(false)

                            // The playhead is driven by `continuousCenterDate`
                            // during a drag and is always centered for the
                            // other resolutions. A minute-based TimelineView
                            // here only rebuilt this whole overlay for a date
                            // that was never read, so keep the line static
                            // until an actual playhead change arrives.
                            currentLine()
                                .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(height: layout.contentHeight)
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .top
                )
                .scrollBounceBehavior(.basedOnSize)
                .simultaneousGesture(
                    viewportDragGesture(width: contentTimelineWidth)
                )
                // 시간표 핀치는 UIKit 인식기 한 경로로만 받는다. SwiftUI `MagnifyGesture`도 함께 걸려
                // 한 손짓이 두 번 반영됐다(PRF1101A01). 아래 눈금자는 이 인식기 밖이라 SwiftUI 핀치를 쓴다.
                .background {
                    TwoFingerPinchAttachment(
                        onChanged: { scale, anchor in
                            viewportMagnifyChanged(
                                factor: Double(scale),
                                anchor: Double(anchor)
                            )
                        },
                        onEnded: { scale, anchor in
                            viewportMagnifyEnded(
                                factor: Double(scale),
                                anchor: Double(anchor)
                            )
                        }
                    )
                }

                // Keep the time ruler below the timeline. It remains visible
                // while rows scroll, like a measuring scale in an editor.
                axis(markers: displayAxisMarkers)
                    .layoutPriority(1)
                    .simultaneousGesture(
                        viewportDragGesture(width: rulerTimelineWidth)
                    )
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            editingPlanID = nil
                        }
                    )
                    .highPriorityGesture(
                        viewportMagnifyGesture,
                        including: .subviews
                    )
            }
            .contentShape(Rectangle())
            .background {
                TwoFingerDoubleTapAttachment {
                    resetViewport(withFeedback: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
#if DEBUG
        .background(TimelineFrameBudgetProbeView())
#endif
        .background(Color.tpSurface)
        .onAppear {
            continuousCenterDate = model.selectedDate
            continuousTimelineDuration = continuousDuration(
                around: model.selectedDate
            )
            onPlayheadMove?(continuousCenterDate)
        }
        .onChange(of: scale) { _, _ in
            preserveViewportAfterContinuousDrag = false
            continuousCenterDate = model.selectedDate
            continuousTimelineDuration = continuousDuration(
                around: model.selectedDate
            )
            dragLayoutSpan = nil
            dragLayoutSnapshot = nil
            onPlayheadMove?(continuousCenterDate)
            resetViewport()
        }
        .onChange(of: model.selectedDate) { _, newDate in
            if continuousCenterDate != newDate {
                continuousCenterDate = newDate
                onPlayheadMove?(newDate)
            }
            let preserveViewport = preserveViewportAfterContinuousDrag
            preserveViewportAfterContinuousDrag = false
            // A continuous drag changes the selected date, but it must not
            // change the viewport that a preceding pinch established. Keep
            // the current length as a fallback as well, because SwiftUI can
            // deliver this callback after the gesture-end transaction.
            let keepZoom = preserveViewport
                || !viewport.isFull
                || hasCustomContinuousDuration
            if continuousDragOrigin == nil {
                dragLayoutSpan = nil
                dragLayoutSnapshot = nil
                if !keepZoom {
                    continuousTimelineDuration = continuousDuration(around: newDate)
                    resetViewport()
                }
            }
        }
        .accessibilityHint(
            "간트 본문을 드래그해 이동하고 두 손가락으로 최대 1분 단위까지 확대합니다"
        )
        .accessibilityIdentifier("schedule.timeline.board")
        .accessibilityValue(currentResolutionLabel)
        .sensoryFeedback(
            .impact(weight: .light),
            trigger: zoomFeedbackSequence
        )
    }

    /// 순간을 그린 표식이 손가락보다 좁아지지 않게 하는 하한.
    var memoMarkerMinimumWidth: CGFloat { 22 }
}
