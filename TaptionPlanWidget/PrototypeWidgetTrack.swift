import ActivityKit
import AppIntents
import OSLog
import SwiftUI
import TaptionPlanCore
import WidgetKit

struct PrototypeWidgetTrack: View {
    let payload: TaptionWidgetPayload
    let date: Date
    let visibleRowLimit: Int
    let maxItemsPerLane: Int
    let windowDuration: TimeInterval
    let resolutionLabel: String?

    var body: some View {
        GeometryReader { proxy in
            let lanes = TaptionWidgetPlaybackEngine.lanes(
                for: payload.items,
                at: date,
                windowDuration: windowDuration
            )
            // Keep the table flush to the widget edge.  The old 62pt label
            // gutter plus outer widget padding hid the right side of the
            // six-hour grid on compact families.
            let labelWidth: CGFloat = 56
            let axisHeight: CGFloat = 15
            let trackWidth = max(1, proxy.size.width - labelWidth)
            let viewportHeight = max(1, proxy.size.height - axisHeight)
            let visibleRowCount = max(
                1,
                min(
                    visibleRowLimit,
                    lanes.count
                )
            )
            // Keep the lanes compact.  The previous implementation expanded
            // every row to fill the entire viewport, which made a few items
            // look vertically disconnected and pushed the chart away from
            // the header.  A capped row still scrolls when there are more
            // lanes than fit in the widget.
            let idealRowHeight = viewportHeight / CGFloat(visibleRowCount)
            let rowHeight = min(
                idealRowHeight,
                visibleRowLimit >= 6 ? 28 : 30
            )
            let contentHeight = rowHeight * CGFloat(lanes.count)
            let scrollProgress = TaptionWidgetAutoScrollEngine.progress(
                at: date,
                rowCount: lanes.count,
                visibleRows: visibleRowCount,
                reducesMotion: payload.reducesMotion ?? false
            )
            let scrollOffset = CGFloat(
                TaptionWidgetAutoScrollEngine.offset(
                    at: date,
                    contentHeight: Double(contentHeight),
                    viewportHeight: Double(viewportHeight),
                    rowCount: lanes.count,
                    visibleRows: visibleRowCount,
                    reducesMotion: payload.reducesMotion ?? false
                )
            )
            let nowX = labelWidth + trackWidth / 2

            ZStack(alignment: .topLeading) {
                axisLabels(
                    labelWidth: labelWidth,
                    trackWidth: trackWidth
                )

                ZStack(alignment: .topLeading) {
                    ForEach(Array(lanes.enumerated()), id: \.element) { index, lane in
                        let y = CGFloat(index) * rowHeight
                        laneBackground(
                            lane: lane,
                            width: proxy.size.width,
                            height: rowHeight
                        )
                        .offset(y: y)

                        laneLabel(lane)
                            .frame(width: labelWidth - 4, height: rowHeight)
                            .offset(x: 2, y: y)
                    }

                    ForEach(Array(lanes.enumerated()), id: \.element) { index, lane in
                        let y = CGFloat(index) * rowHeight
                        ForEach(trackItems(in: lane).prefix(maxItemsPerLane)) { item in
                            itemBar(
                                item,
                                lane: lane,
                                trackWidth: trackWidth,
                                rowHeight: rowHeight
                            )
                            .offset(
                                    x: labelWidth
                                    + trackWidth * fraction(item.startsAt),
                                    y: y
                                    + max(
                                        1,
                                        (rowHeight - barHeight(rowHeight)) / 2
                                    )
                            )
                        }
                    }
                }
                .frame(
                    width: proxy.size.width,
                    height: contentHeight,
                    alignment: .topLeading
                )
                .offset(y: -scrollOffset)
                .frame(
                    width: proxy.size.width,
                    height: viewportHeight,
                    alignment: .top
                )
                .clipped()
                .offset(y: axisHeight)

                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
                    Rectangle()
                        .fill(WidgetPalette.line.opacity(fraction == 0.5 ? 0.9 : 0.55))
                        .frame(width: 0.5, height: viewportHeight)
                        .offset(
                            x: labelWidth + trackWidth * fraction,
                            y: axisHeight
                        )
                }

                Rectangle()
                    .fill(WidgetPalette.now)
                    .frame(
                        width: 1.5,
                        height: viewportHeight
                    )
                    .offset(x: nowX - 0.75, y: axisHeight)

                Circle()
                    .fill(WidgetPalette.now)
                    .frame(width: 6, height: 6)
                    .offset(x: nowX - 3, y: axisHeight - 3)

                if contentHeight > viewportHeight {
                    Capsule()
                        .fill(WidgetPalette.line.opacity(0.65))
                        .frame(width: 2, height: 15)
                        .overlay(alignment: .top) {
                            Circle()
                                .fill(WidgetPalette.secondary.opacity(0.85))
                                .frame(width: 3.5, height: 3.5)
                                .offset(y: 11.5 * scrollProgress)
                        }
                        .offset(
                            x: proxy.size.width - 2.5,
                            y: axisHeight + 4
                        )
                }
            }
            .clipped()
        }
    }

    private var windowStart: Date {
        date.addingTimeInterval(-windowDuration / 2)
    }

    private var windowEnd: Date {
        date.addingTimeInterval(windowDuration / 2)
    }

    private func trackItems(
        in lane: TaptionWidgetLane
    ) -> [TaptionWidgetItem] {
        TaptionWidgetPlaybackEngine.visibleItems(
            in: lane,
            from: payload.items,
            at: date,
            windowDuration: windowDuration
        )
    }

    private func axisLabels(
        labelWidth: CGFloat,
        trackWidth: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Text(windowDurationLabel)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(WidgetPalette.secondary)
                .frame(width: labelWidth - 4, alignment: .leading)
                .offset(x: 2)
            Text(windowStart.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(WidgetPalette.secondary)
                .offset(x: labelWidth)
            Text(date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(WidgetPalette.now)
                .frame(width: 54)
                .offset(x: labelWidth + trackWidth / 2 - 27)
            Text(windowEnd.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(WidgetPalette.secondary)
                .frame(width: 45, alignment: .trailing)
                .offset(x: labelWidth + trackWidth - 45)
        }
    }

    private var windowDurationLabel: String {
        if let resolutionLabel {
            return resolutionLabel
        }
        let hours = Int(windowDuration / 3_600)
        let shown = min(24, max(1, hours))
        return AppLanguagePreference.text("\(shown)시간", "\(shown)h")
    }

    private func laneBackground(
        lane: TaptionWidgetLane,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        Rectangle()
            .fill(
                lane == .action
                    ? Color.white
                    : WidgetPalette.automaticFill
            )
            .frame(width: width, height: height)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(WidgetPalette.line)
                    .frame(height: 0.5)
            }
    }

    private func laneLabel(_ lane: TaptionWidgetLane) -> some View {
        Label(lane.localizedTitle, systemImage: lane.systemImage)
            .font(.system(size: 9.2, weight: .bold))
            .foregroundStyle(WidgetPalette.ink.opacity(0.9))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func itemBar(
        _ item: TaptionWidgetItem,
        lane: TaptionWidgetLane,
        trackWidth: CGFloat,
        rowHeight: CGFloat
    ) -> some View {
        let start = fraction(item.startsAt)
        let end = fraction(item.endsAt)
        let width = max(4, trackWidth * max(0.012, end - start))
        let active = item.startsAt <= date && date < item.endsAt
        return RoundedRectangle(cornerRadius: 5)
            .fill(categoryColor(item, lane: lane).opacity(active ? 1 : 0.86))
            .frame(width: width, height: barHeight(rowHeight))
            .overlay(alignment: .leading) {
                if width >= 34 {
                    Text(item.title)
                        .font(.system(size: 9, weight: active ? .bold : .semibold))
                        .foregroundStyle(WidgetPalette.ink.opacity(0.9))
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                }
            }
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(WidgetPalette.ink.opacity(0.28), lineWidth: 0.6)
                }
            }
    }

    private func barHeight(_ rowHeight: CGFloat) -> CGFloat {
        // Keep bars nearly flush inside each lane while retaining a 1–2pt
        // separator so adjacent segments remain visually distinct.
        min(22, max(14, rowHeight - 3))
    }

    private func fraction(_ value: Date) -> CGFloat {
        let duration = windowEnd.timeIntervalSince(windowStart)
        return CGFloat(
            min(
                1,
                max(
                    0,
                    value.timeIntervalSince(windowStart) / duration
                )
            )
        )
    }

    private func categoryColor(
        _ item: TaptionWidgetItem,
        lane: TaptionWidgetLane
    ) -> Color {
        if let hex = item.categoryHex {
            return Color(widgetHex: hex)
        }
        switch lane {
        case .schedule:
            return Color(red: 0.78, green: 0.80, blue: 0.83)
        case .location:
            return Color(red: 0.63, green: 0.83, blue: 0.92)
        case .movement:
            return Color(red: 0.82, green: 0.68, blue: 0.46)
        case .sleep:
            return Color(red: 0.79, green: 0.84, blue: 0.90)
        case .activity:
            return Color(red: 0.49, green: 0.68, blue: 0.51)
        case .appUsage:
            return Color(red: 0.55, green: 0.48, blue: 0.72)
        case .action:
            break
        }
        return switch item.categoryID {
        case "exercise": Color(red: 0.996, green: 0.835, blue: 0.812)
        case "activity": Color(red: 0.784, green: 0.875, blue: 0.765)
        case "study": Color(red: 0.827, green: 0.780, blue: 0.902)
        case "hobby": Color(red: 0.769, green: 0.914, blue: 0.855)
        case "sleep": Color(red: 0.851, green: 0.867, blue: 0.918)
        case "movement": Color(red: 0.910, green: 0.827, blue: 0.702)
        case "location": Color(red: 0.847, green: 0.910, blue: 0.949)
        case "travel": Color(red: 0.945, green: 0.710, blue: 0.596)
        case "health": Color(red: 0.784, green: 0.875, blue: 0.765)
        case "photo": Color(red: 0.906, green: 0.843, blue: 0.933)
        default: Color(red: 0.745, green: 0.855, blue: 0.890)
        }
    }
}

struct WidgetWalkingCat: View {
    let style: String
    let activity: TaptionWidgetItem?
    let reducesMotion: Bool
    let pose: TaptionWidgetCatWalkPose

    var body: some View {
        GeometryReader { proxy in
            let isAnimating = !reducesMotion
            let isMoving = isAnimating && pose.action.movesAcrossTrack
            let sharedPose = TaptionCatAnimationEngine.pose(
                from: (reducesMotion ? TaptionWidgetCatAction.sitting : pose.action).rawValue,
                progress: reducesMotion ? 0.5 : pose.progress,
                phase: isAnimating ? pose.legPhase : 0,
                facesLeft: pose.facesLeft && isAnimating,
                tailSwing: isAnimating ? pose.tailSwing : 0,
                headTiltDegrees: isAnimating ? pose.headTiltDegrees : 0,
                legSwing: isAnimating ? pose.legSwing : 0,
                idle: isAnimating ? pose.idle : .still
            )

            ZStack(alignment: .topLeading) {
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(
                                WidgetPalette.secondary.opacity(
                                    index % 2 == pose.legPhase % 2
                                        ? 0.20
                                        : 0.08
                                )
                            )
                            .frame(width: 2.2, height: 1.5)
                    }
                }
                .offset(x: 5, y: 19)
                .opacity(isMoving ? 1 : 0)

                TaptionCatAnimationView(
                    style: style,
                    pose: sharedPose,
                    reducesMotion: reducesMotion,
                    scene: scene
                )
            }
        }
        .accessibilityLabel(
            "\(catName) 고양이가 \(actionLabel)"
        )
    }

    private var scene: TaptionHwarangPose? {
        activity.flatMap {
            TaptionHwarangPose.widgetScene(
                style: style,
                categoryID: $0.categoryID,
                title: $0.title,
                action: pose.action,
                reducesMotion: reducesMotion
            )
        }
    }

    private var catName: String {
        switch style {
        case "white": "화랑이"
        case "mackerel": "윤복이"
        case "black": "검정"
        case "gray": "회색"
        case "cheese": "치즈"
        case "cow": "젖소무늬"
        default: "춘향이"
        }
    }

    private var actionLabel: String {
        if scene != nil, let activity { return "\(activity.title) 중" }
        return switch reducesMotion ? .sitting : pose.action {
        case .walking: "걷는 중"
        case .running: "달리는 중"
        case .sitting: "앉아 있는 중"
        case .sleeping: "자는 중"
        case .grooming: "그루밍하는 중"
        case .eating: "밥 먹는 중"
        case .startled: "놀란 상태"
        case .ballPlay: "공을 잡고 노는 중"
        case .fishingPlay: "낚싯대 장난감으로 노는 중"
        case .stretching: "기지개를 켜는 중"
        case .kneading: "꾹꾹이를 하는 중"
        case .yawning: "하품하는 중"
        }
    }
}

enum WidgetPalette {
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let secondary = Color(red: 0.43, green: 0.43, blue: 0.45)
    static let line = Color(red: 0.87, green: 0.87, blue: 0.89)
    static let automaticFill = Color(red: 0.935, green: 0.935, blue: 0.945)
    static let focusFill = Color(red: 1.00, green: 0.95, blue: 0.85)
    static let focusInk = Color(red: 0.57, green: 0.38, blue: 0.08)
    static let weather = Color(red: 0.31, green: 0.47, blue: 0.59)
    static let now = Color(red: 1.00, green: 0.23, blue: 0.19)
}
