import SwiftUI
import UIKit
import MapKit

extension TimelineBoard {
    func cachedLayoutSnapshot(
        in span: TimeSpan
    ) -> NLETimelineRenderSnapshot {
        let key = NLETimelineRenderKey(
            documentRevision: model.timelineRevision,
            scale: scale,
            isGroup: isGroup,
            selectedGroupPlanID: model.selectedGroupPlanID,
            spanStart: span.start.timeIntervalSinceReferenceDate,
            spanEnd: span.end.timeIntervalSinceReferenceDate
        )
        return layoutCache.value(for: key) {
            makeLayoutSnapshot(in: span)
        }
    }

    func makeLayoutSnapshot(
        in span: TimeSpan
    ) -> NLETimelineRenderSnapshot {
        let index = dataIndexCache.value(for: model.timelineRevision) {
            TimelineBoardDataIndex(
                plans: storedPlans,
                categories: model.snapshot.categories
            )
        }
        var rowModels = rows(in: span, index: index)
        let clusters: [PhotoCluster] = []
        rowModels = TimelineRowOrder.ordered(
            rowModels,
            id: \.id,
            savedIDs: model.snapshot.settings.timelineRowOrder
        )
        let buckets = summaryBuckets(in: span)
        let colors = summaryColors(for: buckets)
        // 넓은 배율의 요약 막대만 하단 여백을 쓴다.
        let footerHeight: CGFloat = scale == .day ? 0 : 46
        return NLETimelineRenderSnapshot(
            documentRevision: model.timelineRevision,
            rows: rowModels,
            axisMarkers: axisMarkers(in: span),
            photoClusters: clusters,
            summaryBuckets: buckets,
            summaryColors: colors,
            contentHeight: rowModels.reduce(0) { $0 + $1.height }
                + footerHeight
        )
    }

    var rulerMinorDivisionCount: Int {
        if isContinuousTimeline {
            return activeContinuousDuration <= 60 * 60 ? 5 : 4
        }
        return 2
    }

    func compactAutomaticHeight(_ laneCount: Int) -> CGFloat {
        10 + CGFloat(max(1, laneCount)) * 18
    }

    func laneAllocation<Item: Identifiable>(
        _ items: [Item],
        span: (Item) -> TimeSpan
    ) -> (lanes: [Item.ID: Int], count: Int)
    where Item.ID: Hashable {
        let allocation = TimelineLaneAllocator.allocate(items, span: span)
        return (allocation.lanes, allocation.count)
    }

    var layoutDataSpan: TimeSpan {
        dragLayoutSpan ?? visibleSpan
    }

    /// 확대·축소는 보이는 구간의 길이 자체가 바뀌므로 드래그처럼 창을 한 번만
    /// 잡아 둘 수 없다.  여유 폭을 두고, 실제로 모자랄 때만 다시 잡는다.
    func ensureMagnifyLayoutWindow(around center: Date) {
        guard isContinuousTimeline else { return }

        let minimumWindowDuration = max(60, activeContinuousDuration * 3)
        if let current = dragLayoutSpan,
           current.duration >= minimumWindowDuration {
            let margin = current.duration * 0.25
            let safeStart = current.start.addingTimeInterval(margin)
            let safeEnd = current.end.addingTimeInterval(-margin)
            if safeStart <= center, center <= safeEnd {
                return
            }
        }

        let windowDuration = max(
            minimumWindowDuration,
            dragLayoutSpan?.duration ?? 0
        )
        let halfDuration = windowDuration / 2
        let nextWindow = TimeSpan(
            start: center.addingTimeInterval(-halfDuration),
            end: center.addingTimeInterval(halfDuration)
        )
        guard dragLayoutSpan != nextWindow else { return }
        // Keep the data window and its derived rows as one cache entry. If the
        // window advances during a pinch, leaving the snapshot nil makes the
        // next SwiftUI pass rebuild every row on the hot path.
        dragLayoutSnapshot = cachedLayoutSnapshot(in: nextWindow)
        dragLayoutSpan = nextWindow
    }

    @ViewBuilder
    func gridLines(markers: [TimelineAxisMarker]) -> some View {
        HStack(spacing: 0) {
            if !usesFullWidthRuler {
                Color.clear.frame(width: scheduleLabelColumnWidth)
            }
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(markers) { marker in
                        Rectangle()
                            .fill(ganttTableLineColor)
                            .frame(width: 0.5)
                            .position(
                                x: proxy.size.width
                                    * CGFloat(marker.fraction),
                                y: proxy.size.height / 2
                            )
                    }
                }
            }
            .clipped()
        }
    }
}
