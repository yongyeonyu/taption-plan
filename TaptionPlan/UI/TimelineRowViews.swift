import SwiftUI
import UIKit
import MapKit

struct TimelineBlockSlice {
    let centerX: CGFloat
    let width: CGFloat
    /// 실제 시간 길이가 최소 너비보다 짧아 억지로 넓혀 그린 막대.  이런
    /// 막대는 안쪽에 아무 글자도 담을 수 없다.
    let isStub: Bool

    var minX: CGFloat { centerX - width / 2 }
    var maxX: CGFloat { centerX + width / 2 }
}

/// 한 줄에서 실제로 그려질 막대. 년·월처럼 기록이 촘촘한 배율에서는 수천
/// 개의 막대가 같은 픽셀에 겹쳐 쌓이므로, 앞선 막대가 이미 덮은 자리를
/// 반 포인트도 넓히지 못하는 막대는 뷰로 만들지 않는다.
struct TimelineRowBar: Identifiable {
    let id: UUID
    let block: TimelineBlock
    let slice: TimelineBlockSlice
    /// 합치기 전 본래 너비.  글자·아이콘을 그릴지 판단할 때는 합쳐진
    /// 너비가 아니라 이 값을 본다.
    let contentWidth: CGFloat
}

enum TimelineRowBarMerging {
    static let isEnabled = true
}

/// 같은 칸에서 이어 붙는 중인 자투리 막대 묶음.
struct TimelineBarRun {
    let lane: TimelineBarLane
    let barIndex: Int
    let minX: CGFloat
    var maxX: CGFloat
    let isStub: Bool
}

/// 겹침 판정을 같은 줄·같은 모양끼리만 하기 위한 열쇠.
struct TimelineBarLane: Equatable {
    let top: CGFloat
    let height: CGFloat
    let isGoal: Bool
    let isFixed: Bool
    let isActual: Bool
    let styleKey: String

    init(_ block: TimelineBlock) {
        top = block.top
        height = block.height
        isGoal = block.isGoal
        isFixed = block.isFixed
        isActual = block.isActual
        styleKey = block.styleKey
    }
}

struct TimelineRow: View {
    let row: TimelineRowModel
    let isSelected: Bool
    let editingPlanID: UUID?
    let visibleDuration: TimeInterval
    let viewport: GanttViewport
    let displaySpan: TimeSpan
    let scale: TimeScale
    let useCachedBlockFractions: Bool
    let onBlockTap: (TimelineBlock) -> Void
    let onBlockDoubleTap: (TimelineBlock) -> Void
    let onEdit: (UUID?) -> Void
    let onMove: (TimelineBlock, TimeInterval) -> Void
    let onResizeStart: (TimelineBlock, TimeInterval) -> Void
    let onResizeEnd: (TimelineBlock, TimeInterval) -> Void
    let onRowTap: () -> Void
    let onDrop: (String) -> Bool

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onRowTap) {
                HStack(spacing: TaptionSpacing.tight) {
                    if let iconName = row.iconName {
                        Image(systemName: iconName)
                            .font(.taption(size: 8.5, weight: .bold))
                            .foregroundStyle(row.dotColor)
                            .frame(width: 11, height: 11)
                    } else if row.dotColor != .clear {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(row.dotColor)
                            .frame(width: 8, height: 8)
                    }
                    Text(row.title)
                        .lineLimit(row.title.contains("\n") ? 3 : 1)
                        .minimumScaleFactor(0.78)
                        .lineSpacing(1)
                }
                .font(
                    .taption(
                        size: row.title.contains("\n")
                            ? 8.4
                            : (row.title.count > 4 ? 9 : 10.5),
                        weight: .semibold
                    )
                )
                .foregroundStyle(isSelected ? Color.tpInk : Color.tpInk)
                .padding(.leading, row.title.count > 4 ? 4 : 8)
                .padding(.trailing, 2)
                .frame(
                    width: scheduleLabelColumnWidth,
                    height: row.height,
                    alignment: .leading
                )
                .background(
                    isSelected
                        ? Color.tpInk.opacity(0.06)
                        : Color.clear
                )
                .overlay(alignment: .leading) {
                    if isSelected {
                        Rectangle()
                            .fill(Color.tpInk)
                            .frame(width: 3)
                    }
                }
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture().onEnded {
                    onEdit(nil)
                }
            )
            .draggable(row.id)
            .dropDestination(for: String.self) { sourceIDs, _ in
                guard let sourceID = sourceIDs.first else { return false }
                return onDrop(sourceID)
            }

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onEdit(nil)
                        }

                    if row.isSystemAutomatic {
                        Rectangle()
                            .fill(Color.tpInk.opacity(0.026))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    ForEach(visibleBars(width: proxy.size.width)) { bar in
                        let block = bar.block
                        TimelineBar(
                                block: block,
                                color: block.fillColor ?? row.fillColor,
                                actualColor:
                                    block.actualColor ?? row.actualColor,
                                width: bar.slice.width,
                                contentWidth: bar.contentWidth,
                                isEditing: editingPlanID == block.planID,
                                visibleDuration: visibleDuration,
                                secondsPerPoint:
                                    visibleDuration
                                    / max(1, proxy.size.width),
                                onTap: {
                                    if block.planID == nil {
                                        onEdit(nil)
                                    }
                                    onBlockTap(block)
                                },
                                onDoubleTap: {
                                    onBlockDoubleTap(block)
                                },
                                onEdit: { onEdit(block.planID) },
                                onMove: { onMove(block, $0) },
                                onResizeStart: {
                                    onResizeStart(block, $0)
                                },
                                onResizeEnd: {
                                    onResizeEnd(block, $0)
                                }
                            )
                            .position(
                                x: bar.slice.centerX,
                                y: block.top + block.height / 2
                            )
                    }
                }
            }
            .clipped()
        }
        .background(
            row.isSystemAutomatic
                ? Color.tpInk.opacity(0.018)
                : Color.clear
        )
        .frame(height: row.height)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ganttTableLineColor)
                .frame(height: 0.5)
        }
    }

    /// 눈에 보이는 막대만 남긴다.  앞선 막대가 덮은 구간을 반 포인트도
    /// 넓히지 못하는 막대는 같은 색·같은 칸에 그대로 묻히므로 건너뛴다.
    /// 하루처럼 막대가 넓은 배율에서는 어떤 막대도 걸러지지 않는다.
    private func visibleBars(width: CGFloat) -> [TimelineRowBar] {
        var bars: [TimelineRowBar] = []
        var runs: [TimelineBarRun] = []
        let displayStart = displaySpan.start
        let displayEnd = displaySpan.end
        let displayDuration = max(1, displaySpan.duration)
        let candidateBlocks: ArraySlice<TimelineBlock>
        if useCachedBlockFractions {
            let range = TimelineVisibleIntervalIndex.candidateRange(
                starts: row.blockStarts,
                prefixMaximumEnds: row.prefixMaximumBlockEnds,
                visibleStart: viewport.start,
                visibleEnd: viewport.end
            )
            candidateBlocks = row.blocks[range]
        } else {
            candidateBlocks = row.blocks[...]
        }
        for block in candidateBlocks {
            // Drag snapshots intentionally cover a wider window than the
            // current viewport. Reject blocks outside that viewport before
            // doing date-to-fraction projection; on dense automatic rows this
            // removes most of the per-frame work during a scrub.
            if !useCachedBlockFractions {
                if let endsAt = block.endsAt, endsAt <= displayStart {
                    continue
                }
                if let startsAt = block.startsAt, startsAt >= displayEnd {
                    continue
                }
            }
            guard let slice = visibleSlice(
                for: block,
                width: width,
                displayDuration: displayDuration
            ) else {
                continue
            }
            let lane = TimelineBarLane(block)
            let runIndex = runs.firstIndex { $0.lane == lane }
            if TimelineRowBarMerging.isEnabled,
               slice.isStub,
               let runIndex,
               runs[runIndex].isStub,
               slice.minX <= runs[runIndex].maxX {
                // 이미 그려진 막대와 맞닿은 자투리 막대는 같은 자리를 다시
                // 칠할 뿐이므로 앞 막대를 늘려 한 개로 합친다. 칠해지는
                // 범위는 그대로다.
                runs[runIndex].maxX = max(runs[runIndex].maxX, slice.maxX)
                let run = runs[runIndex]
                bars[run.barIndex] = TimelineRowBar(
                    id: bars[run.barIndex].id,
                    block: bars[run.barIndex].block,
                    slice: TimelineBlockSlice(
                        centerX: (run.minX + run.maxX) / 2,
                        width: run.maxX - run.minX,
                        isStub: true
                    ),
                    contentWidth: bars[run.barIndex].contentWidth
                )
                continue
            }
            let run = TimelineBarRun(
                lane: lane,
                barIndex: bars.count,
                minX: slice.minX,
                maxX: slice.maxX,
                isStub: slice.isStub
            )
            if let runIndex {
                runs[runIndex] = run
            } else {
                runs.append(run)
            }
            bars.append(
                TimelineRowBar(
                    id: block.id,
                    block: block,
                    slice: slice,
                    contentWidth: slice.width
                )
            )
        }
        return bars
    }

    private func visibleSlice(
        for block: TimelineBlock,
        width: CGFloat,
        displayDuration: TimeInterval
    ) -> TimelineBlockSlice? {
        let blockStart: Double
        let blockEnd: Double
        if useCachedBlockFractions {
            blockStart = Double(block.start)
            blockEnd = blockStart + Double(block.length)
        } else if let startsAt = block.startsAt,
           let endsAt = block.endsAt {
            // All four resolutions use a continuous time coordinate while
            // dragging. This keeps a block moving at a constant speed across
            // week/month/year boundaries instead of snapping to calendar
            // bucket edges.
            let duration = displayDuration
            blockStart = startsAt.timeIntervalSince(displaySpan.start)
                / duration
            blockEnd = endsAt.timeIntervalSince(displaySpan.start)
                / duration
        } else {
            blockStart = Double(block.start)
            blockEnd = blockStart + Double(block.length)
        }
        let overlapStart = max(blockStart, viewport.start)
        let overlapEnd = min(blockEnd, viewport.end)
        guard overlapStart < overlapEnd else { return nil }

        let startFraction =
            (overlapStart - viewport.start) / viewport.length
        let endFraction =
            (overlapEnd - viewport.start) / viewport.length
        let naturalWidth =
            width * CGFloat(endFraction - startFraction)
        return TimelineBlockSlice(
            centerX:
                width * CGFloat((startFraction + endFraction) / 2),
            width: max(block.minimumWidth, naturalWidth),
            isStub: naturalWidth < block.minimumWidth
        )
    }
}

struct TimelineBar: View {
    let block: TimelineBlock
    let color: Color
    let actualColor: Color
    let width: CGFloat
    /// 합치기 전 본래 너비.  글자와 앱 이름은 이 너비를 기준으로 그린다.
    let contentWidth: CGFloat
    let isEditing: Bool
    let visibleDuration: TimeInterval
    let secondsPerPoint: TimeInterval
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onEdit: () -> Void
    let onMove: (TimeInterval) -> Void
    let onResizeStart: (TimeInterval) -> Void
    let onResizeEnd: (TimeInterval) -> Void

    var body: some View {
        HStack(spacing: 3) {
            if !showsContent {
                EmptyView()
            } else if showsApplicationName {
                // 번들 ID가 아닌 실제 앱 이름·아이콘. 시스템만 그릴 수 있어서
                // 문자열 제목 대신 토큰 라벨을 쓴다.
                AppUsageNameLabel(
                    tokenData: block.appUsageTokenData,
                    size: textSize,
                    tint: textColor
                )
                if showsMinuteDetails {
                    Text(primaryText)
                        .font(.taption(size: textSize, weight: .semibold))
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            } else {
                Text(primaryText)
                    .font(.taption(size: textSize, weight: .semibold))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            if showsContent, !showsMinuteDetails, let count = block.groupCount {
                Spacer(minLength: 1)
                Text("▸ \(count)")
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpInk.opacity(0.62))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.tpSurface.opacity(0.70), in: Capsule())
            }
            if showsContent, !showsMinuteDetails, block.status == .completed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(actualColor)
            }
        }
        .padding(.horizontal, 6)
        .frame(
            width: width,
            height: block.height,
            alignment: .leading
        )
        .background {
            if block.isGoal {
                GoalStripeBackground(
                    tint: color.opacity(0.76)
                )
            } else if block.isFixed {
                if block.isActual {
                    actualColor.opacity(0.82)
                } else {
                    FixedStripeBackground()
                }
            } else {
                color
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: blockCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            if block.isFixed {
                RoundedRectangle(
                    cornerRadius: blockCornerRadius,
                    style: .continuous
                )
                    .stroke(
                        block.isActual
                            ? actualColor
                            : Color(
                                red: 0.78,
                                green: 0.78,
                                blue: 0.80
                            ),
                        lineWidth: 1
                    )
            } else if block.isGoal {
                RoundedRectangle(
                    cornerRadius: blockCornerRadius,
                    style: .continuous
                )
                    .stroke(
                        color,
                        lineWidth: 1.1
                    )
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let fraction = block.actualFraction, fraction > 0 {
                Capsule()
                    .fill(actualColor)
                    .frame(
                        width: max(4, width * CGFloat(fraction)),
                        height: 3
                    )
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)
            }
        }
        .overlay {
            if isEditing, block.planID != nil, !block.isFixed {
                HStack {
                    resizeHandle
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onEnded {
                                    onResizeStart(
                                        $0.translation.width * secondsPerPoint
                                    )
                                }
                        )
                    Spacer()
                    resizeHandle
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onEnded {
                                    onResizeEnd(
                                        $0.translation.width * secondsPerPoint
                                    )
                                }
                        )
                }
                .padding(.horizontal, -5)
            }
        }
        .highPriorityGesture(
            TapGesture(count: 2)
                .exclusively(before: TapGesture(count: 1))
                .onEnded { value in
                    switch value {
                    case .first:
                        onDoubleTap()
                    case .second:
                        onTap()
                    }
                }
        )
        // 자동 기록은 옮기거나 길이를 바꿀 수 없다.  두 제스처 모두 안에서
        // 곧바로 빠져나가므로 아예 붙이지 않는다.  촘촘한 배율에서는 한
        // 프레임에 수백 개의 인식기를 만들던 자리다.
        .modifier(
            TimelineBarEditGestures(
                isEnabled: !block.isFixed,
                onEdit: onEdit,
                onMove: { onMove($0 * secondsPerPoint) },
                canMove: isEditing && block.planID != nil
            )
        )
        .accessibilityHint(
            block.isFixed
                ? "자동 기록은 수정할 수 없습니다. 두 번 탭하면 해당 시간으로 확대합니다"
                : "두 번 탭하면 확대하고, 길게 누른 뒤 드래그하면 이동하며 양 끝점을 끌면 길이를 조절합니다"
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            onTap()
        }
    }

    private var showsMinuteDetails: Bool {
        visibleDuration
            <= GanttZoomStage.oneMinute.duration * 1.15
    }

    /// 아이콘과 이름이 잘리지 않고 들어갈 만큼 막대가 넓을 때만 토큰을 그린다.
    /// 좁으면 최선의 추정 이름이 담긴 제목 문자열을 그대로 쓴다.
    private var showsApplicationName: Bool {
        contentWidth >= 58
            && AppUsageNameLabel.canRender(block.appUsageTokenData)
    }

    /// 억지로 넓힌 자투리 막대에는 글자가 한 자도 들어가지 않는다.  글자와
    /// 배지를 만들지 않으면 년·월처럼 막대가 촘촘한 배율에서 프레임마다
    /// 수백 개의 글자 배치를 건너뛴다.
    private var showsContent: Bool {
        contentWidth >= 18
    }

    private var textSize: CGFloat {
        block.height <= 20 ? 9.5 : 10.5
    }

    private var textColor: Color {
        block.isActual ? Color.white : Color.tpInk.opacity(0.64)
    }

    private var blockCornerRadius: CGFloat {
        block.isGoal ? 0 : (block.height <= 20 ? 10 : 7)
    }

    private var primaryText: String {
        GanttPrecisionPresentation.label(
            title: block.title,
            startsAt: block.startsAt,
            endsAt: block.endsAt,
            detailText: block.detailText,
            visibleDuration: visibleDuration
        )
    }

    private var resizeHandle: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .overlay {
                Circle().stroke(Color.tpInk.opacity(0.65), lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.16), radius: 2)
    }
}

struct TimelineBarEditGestures: ViewModifier {
    let isEnabled: Bool
    let onEdit: () -> Void
    let onMove: (CGFloat) -> Void
    let canMove: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onLongPressGesture(
                    minimumDuration: 0.18,
                    maximumDistance: 12,
                    perform: onEdit
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onEnded {
                            guard canMove else { return }
                            onMove($0.translation.width)
                        }
                )
        } else {
            content
        }
    }
}

struct TimelinePhaseActivity: Identifiable {
    let id: UUID
    let phase: DayPhase
    let title: String
    let span: TimeSpan
    let categoryID: String
    let categoryName: String
    let detailText: String
    let color: Color
    let isMeasured: Bool
    let actualID: UUID?
    let travelID: UUID?
    let recordNodeID: String?
    let isRoute: Bool
    let appUsageTokenData: Data?
    let styleKey: String
}
