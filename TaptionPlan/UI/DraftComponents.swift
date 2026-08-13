import SwiftUI

struct DraftTopBar: View {
    let title: String
    let trailing: String
    var trailingColor: Color = .tpSecondary
    var selectedScale: TimeScale?
    var scaleOptions: [TimeScale] = TimeScale.allCases
    var onScaleChange: ((TimeScale) -> Void)?
    var dayZoom: TimelineZoomPreset?
    var onDayZoomChange: ((TimelineZoomPreset) -> Void)?
    var onBack: (() -> Void)?
    var onTitleTap: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var trailingSystemImage: String?
    var onTrailingTap: (() -> Void)?
    var trailingAccessibilityLabel = ""
    var isPreviousEnabled = true
    var isNextEnabled = true
    var textSizeAdjustment: CGFloat = 0

    var body: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let onBack {
                    Button(action: onBack) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.taption(size: 12, weight: .bold))
                            Text(title)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(
                        .taption(
                            size: 17 + textSizeAdjustment,
                            weight: .bold
                        )
                    )
                    .foregroundStyle(Color.tpInk)
                } else if onPrevious != nil || onNext != nil {
                    HStack(spacing: 3) {
                        periodNavigationButton(
                            systemName: "chevron.left",
                            action: onPrevious,
                            isEnabled: isPreviousEnabled,
                            accessibilityLabel: "이전 \(selectedScale?.rawValue ?? "기간")"
                        )

                        titleButton

                        periodNavigationButton(
                            systemName: "chevron.right",
                            action: onNext,
                            isEnabled: isNextEnabled,
                            accessibilityLabel: "다음 \(selectedScale?.rawValue ?? "기간")"
                        )
                    }
                    .layoutPriority(1)
                } else {
                    titleText
                }

                Spacer(minLength: 4)

                if let trailingSystemImage,
                   let onTrailingTap {
                    Button(action: onTrailingTap) {
                        Image(systemName: trailingSystemImage)
                            .font(
                                .taption(
                                    size: 16 + textSizeAdjustment,
                                    weight: .bold
                                )
                            )
                            .foregroundStyle(Color.tpInk)
                            .frame(width: 34, height: 34)
                            .background(
                                Color.tpSky.opacity(0.22),
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        trailingAccessibilityLabel.isEmpty
                            ? trailingSystemImage
                            : trailingAccessibilityLabel
                    )
                } else if !trailing.isEmpty {
                    if let onTrailingTap {
                        Button(action: onTrailingTap) {
                            Text(trailing)
                                .font(
                                    .taption(
                                        size: 12 + textSizeAdjustment,
                                        weight: .semibold
                                    )
                                )
                                .foregroundStyle(trailingColor)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            trailingAccessibilityLabel.isEmpty
                                ? trailing
                                : trailingAccessibilityLabel
                        )
                    } else {
                        Text(trailing)
                            .font(
                                .taption(
                                    size: 12 + textSizeAdjustment,
                                    weight: .regular
                                )
                            )
                            .foregroundStyle(trailingColor)
                            .lineLimit(1)
                    }
                }
            }

            if let selectedScale {
                DraftScalePicker(
                    selected: selectedScale,
                    options: scaleOptions,
                    dayZoom: dayZoom,
                    onSelect: { scale in onScaleChange?(scale) },
                    onDayZoomChange: { zoom in onDayZoomChange?(zoom) }
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 5)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                colors: [Color.tpSurface, Color.tpSurfaceBlue.opacity(0.52)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.tpLine)
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var titleButton: some View {
        if let onTitleTap {
            Button(action: onTitleTap) {
                titleText
            }
            .buttonStyle(.plain)
            .accessibilityLabel("현재 날짜와 시간으로 이동")
            .accessibilityIdentifier("schedule.jump-to-now")
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(title)
            .font(
                .taption(
                    size: 19 + textSizeAdjustment,
                    weight: .bold
                )
            )
            .foregroundStyle(Color.tpInk)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func periodNavigationButton(
        systemName: String,
        action: (() -> Void)?,
        isEnabled: Bool,
        accessibilityLabel: String
    ) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: systemName)
                .font(.taption(size: 12.5, weight: .bold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            isEnabled ? Color.tpInk : Color.tpSecondary.opacity(0.28)
        )
        .disabled(!isEnabled || action == nil)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(
            systemName == "chevron.left"
                ? "schedule.period.previous"
                : "schedule.period.next"
        )
    }
}

struct DraftScalePicker: View {
    let selected: TimeScale
    let options: [TimeScale]
    let dayZoom: TimelineZoomPreset?
    let onSelect: (TimeScale) -> Void
    let onDayZoomChange: (TimelineZoomPreset) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { scale in
                Button {
                    onSelect(scale)
                } label: {
                    Text(scale.rawValue)
                        .font(.taption(size: 12.5, weight: selected == scale ? .semibold : .regular))
                        .foregroundStyle(selected == scale ? Color.tpInk : Color.tpSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if selected == scale {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.tpSurface)
                                    .shadow(color: Color.tpSky.opacity(0.24), radius: 1.5, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(scale.rawValue) 보기")
                .accessibilityIdentifier("schedule.scale.\(scale.rawValue)")
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.tpSky.opacity(0.18))
        )
    }
}

enum DraftBottomBarMetrics {
    /// 하단 탭 막대는 `safeAreaInset`으로 화면 위에 떠 있고, 그 인셋은
    /// `NavigationStack` 안쪽 화면의 안전 영역까지 내려오지 않는다. 스크롤
    /// 화면은 마지막 줄이 막대 뒤로 숨지 않도록 이만큼을 직접 비워 둔다.
    static let contentInset: CGFloat = 104
}

struct DraftBottomNavigationBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            tabButton(.schedule)
            if !TaptionProductScope.automaticLoggingOnly {
                tabButton(.goals)
                mainAddButton
            }
            tabButton(.review)
            memoAddButton
            tabButton(.settings)
        }
        .padding(.horizontal, 6)
        .padding(.top, 16)
        .padding(.bottom, 0)
        .background(
            LinearGradient(
                colors: [Color.tpSurface.opacity(0.98), Color.tpSurfacePink.opacity(0.88)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.tpLine)
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var mainAddButton: some View {
        Button {
            if model.selectedTab == .goals {
                model.addPlanContext = .goal
            } else if model.detail == .group,
                      let parentID = model.selectedGroupPlanID {
                model.addPlanContext = .child(parentID)
            } else {
                model.addPlanContext = .quick
            }
            model.isAddPlanPresented = true
        } label: {
            Image(systemName: "plus")
                .font(.taption(size: 23, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.tpProjectDark, in: Circle())
                .shadow(color: Color.tpSky.opacity(0.36), radius: 7, y: 4)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(mainAddButtonAccessibilityLabel)
    }

    private var mainAddButtonAccessibilityLabel: String {
        if model.selectedTab == .goals { return "루틴 추가" }
        return model.detail == .group ? "하위 계획 추가" : "계획 추가"
    }

    private var memoAddButton: some View {
        Button {
            model.openMemoEntry(at: .now)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "plus")
                    .font(.taption(size: 19, weight: .bold))
                    .frame(height: 20)
                Text("메모")
                    .font(.taption(size: 9.5, weight: .regular))
            }
            .foregroundStyle(Color.tpSecondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("메모 추가")
    }

    private func tabButton(_ tab: RootTab) -> some View {
        Button {
            model.selectTab(tab)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.taption(size: 19, weight: model.selectedTab == tab ? .bold : .regular))
                    .frame(height: 20)
                Text(tab.rawValue)
                    .font(.taption(size: 9.5, weight: model.selectedTab == tab ? .bold : .regular))
            }
            .foregroundStyle(model.selectedTab == tab ? Color.tpInk : Color.tpSecondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.selectedTab == tab ? .isSelected : [])
    }
}

struct DraftChip: View {
    let title: String
    var selected = false
    var tint: Color = .tpInk
    var fontSize: CGFloat = 9.5

    var body: some View {
        Text(title)
            .font(.taption(size: fontSize, weight: .bold))
            .foregroundStyle(selected ? Color.white : Color.tpSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(selected ? tint : Color.tpSky.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct FixedStripeBackground: View {
    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(red: 0.95, green: 0.95, blue: 0.96))
            )
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 12
            }
            context.stroke(
                path,
                with: .color(Color(red: 0.87, green: 0.87, blue: 0.89)),
                lineWidth: 6
            )
        }
    }
}

struct CatFaceView: View {
    let coat: CatCoat

    var body: some View {
        TaptionCatAnimationView(
            style: coat.rawValue,
            pose: TaptionCatAnimationEngine.pose(
                at: Date(timeIntervalSinceReferenceDate: 0),
                preferredAction: .sitting,
                reducesMotion: true
            ),
            reducesMotion: true
        )
        .frame(width: 52, height: 34)
        .accessibilityHidden(true)
    }
}

struct RunningCatView: View {
    let coat: CatCoat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hopping = false

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: TaptionCatAnimationEngine.stepDuration,
                paused: reduceMotion
            )
        ) { context in
            TaptionCatAnimationView(
                style: coat.rawValue,
                pose: TaptionCatAnimationEngine.pose(
                    at: context.date,
                    preferredAction: .running,
                    reducesMotion: reduceMotion
                ),
                reducesMotion: reduceMotion
            )
        }
        .frame(width: 56, height: 36)
    }

    private var outline: Color {
        coat == .black ? .black : Color(red: 0.27, green: 0.28, blue: 0.30)
    }

    private var eye: Color {
        coat == .black ? Color(red: 0.96, green: 0.83, blue: 0.37) : .tpInk
    }
}

struct CatActionPreviewStage: View {
    let coat: CatCoat
    let action: TaptionWidgetCatAction
    let reducesMotion: Bool

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: TaptionWidgetCatPreviewEngine.stepDuration,
                paused: reducesMotion
            )
        ) { context in
            let pose = TaptionWidgetCatPreviewEngine.pose(
                at: context.date,
                action: action,
                reducesMotion: reducesMotion
            )
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(.black.opacity(0.08))
                        .frame(height: 1)
                        .offset(y: proxy.size.height - 7)

                    TaptionCatAnimationView(
                        style: coat.rawValue,
                        pose: TaptionCatAnimationEngine.pose(
                            from: pose.action.rawValue,
                            progress: pose.progress,
                            phase: pose.legPhase,
                            facesLeft: pose.facesLeft,
                            tailSwing: pose.tailSwing,
                            headTiltDegrees: pose.headTiltDegrees,
                            legSwing: pose.legSwing,
                            idle: pose.idle
                        ),
                        reducesMotion: reducesMotion
                    )
                    .frame(width: proxy.size.width, height: 48)
                    .offset(y: max(0, (proxy.size.height - 48) / 2))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(coat.rawValue), \(action.previewTitle) 미리보기"
        )
    }
}

private struct PreviewActionCat: View {
    let coat: CatCoat
    let pose: TaptionWidgetCatWalkPose
    let reducesMotion: Bool

    var body: some View {
        let action = pose.action
        let phase = pose.legPhase

        ZStack {
            accessory(action, phase: phase)

            HStack(spacing: -5) {
                tail(action)

                Ellipse()
                    .fill(coat.baseColor)
                    .frame(
                        width: bodySize(action).width,
                        height: bodySize(action).height
                    )
                    .overlay {
                        Ellipse().stroke(outline.opacity(0.9), lineWidth: 1.2)
                    }
                    .overlay(alignment: .bottom) {
                        legs(action, phase: phase)
                    }
                    .overlay(alignment: .trailing) {
                        head(action, phase: phase)
                            .rotationEffect(
                                .degrees(
                                    reducesMotion
                                        ? 0
                                        : pose.headTiltDegrees
                                )
                            )
                            .offset(
                                x: action == .sleeping ? 1 : 7,
                                y: headOffset(action, phase: phase)
                            )
                    }
            }
            .rotationEffect(.degrees(action == .sleeping ? 4 : 0))
            .offset(y: bounce(action, phase: phase))
        }
    }

    private var outline: Color {
        coat == .black
            ? .black
            : Color(red: 0.27, green: 0.28, blue: 0.30)
    }

    private var eye: Color {
        coat == .black
            ? Color(red: 0.96, green: 0.83, blue: 0.37)
            : .tpInk
    }

    private func bodySize(_ action: TaptionWidgetCatAction) -> CGSize {
        switch action {
        case .sitting, .grooming:
            CGSize(width: 25, height: 24)
        case .sleeping:
            CGSize(width: 34, height: 14)
        case .startled:
            CGSize(width: 26, height: 20)
        default:
            CGSize(width: 31, height: 17)
        }
    }

    private func bounce(
        _ action: TaptionWidgetCatAction,
        phase: Int
    ) -> CGFloat {
        guard !reducesMotion else { return 0 }
        return switch action {
        case .running:
            phase.isMultiple(of: 2) ? 1 : -3
        case .walking, .ballPlay, .fishingPlay:
            phase.isMultiple(of: 2) ? 0 : -1.5
        case .startled:
            -3
        default:
            0
        }
    }

    private func headOffset(
        _ action: TaptionWidgetCatAction,
        phase: Int
    ) -> CGFloat {
        switch action {
        case .eating:
            phase.isMultiple(of: 2) ? 5 : 8
        case .sleeping:
            4
        case .grooming:
            phase.isMultiple(of: 2) ? -7 : -3
        case .sitting:
            -8
        case .startled:
            -5
        default:
            -4
        }
    }

    private func tail(_ action: TaptionWidgetCatAction) -> some View {
        Capsule()
            .fill(action == .startled ? coat.baseColor : outline)
            .overlay {
                if action == .startled {
                    Capsule().stroke(outline, lineWidth: 1.2)
                }
            }
            .frame(
                width: action == .startled ? 9 : 3,
                height: action == .startled ? 30 : 22
            )
            .rotationEffect(
                .degrees(
                    action == .startled
                        ? -18
                        : -54 + (pose.tailSwing * 12)
                )
            )
            .offset(
                x: action == .startled ? 1 : 4,
                y: action == .sleeping ? 4 : -2
            )
    }

    private func head(
        _ action: TaptionWidgetCatAction,
        phase: Int
    ) -> some View {
        ZStack {
            HStack(spacing: 7) {
                Triangle().fill(coat.baseColor)
                Triangle().fill(coat.baseColor)
            }
            .frame(width: 18, height: 9)
            .offset(y: -7)

            Circle()
                .fill(coat.baseColor)
                .overlay { Circle().stroke(outline.opacity(0.9), lineWidth: 1) }

            HStack(spacing: 5) {
                eyeShape(action)
                eyeShape(action)
            }
            .offset(y: -1)

            Circle()
                .fill(Color(red: 1, green: 0.58, blue: 0.65))
                .frame(width: 2.5, height: 2)
                .offset(y: 3)

            if action == .grooming {
                Capsule()
                    .fill(coat.baseColor)
                    .overlay { Capsule().stroke(outline, lineWidth: 0.8) }
                    .frame(width: 5, height: 13)
                    .rotationEffect(
                        .degrees(phase.isMultiple(of: 2) ? -28 : 8)
                    )
                    .offset(x: -7, y: 6)
            }
        }
        .frame(width: 18, height: 18)
    }

    private func eyeShape(_ action: TaptionWidgetCatAction) -> some View {
        Capsule()
            .fill(eye)
            .frame(
                width: action == .sleeping ? 4 : 2,
                height: action == .sleeping ? 1 : 2.5
            )
    }

    @ViewBuilder
    private func legs(
        _ action: TaptionWidgetCatAction,
        phase: Int
    ) -> some View {
        if action != .sleeping {
            let spread = phase.isMultiple(of: 2) ? 22.0 : -22.0
            HStack(spacing: action == .sitting ? 8 : 11) {
                Capsule()
                    .fill(outline)
                    .frame(
                        width: 2.5,
                        height: action == .sitting ? 13 : 11
                    )
                    .rotationEffect(
                        .degrees(action.movesAcrossTrack ? spread : 4)
                    )
                Capsule()
                    .fill(outline)
                    .frame(
                        width: 2.5,
                        height: action == .sitting ? 13 : 11
                    )
                    .rotationEffect(
                        .degrees(action.movesAcrossTrack ? -spread : -4)
                    )
            }
            .offset(y: action == .sitting ? 8 : 6)
        }
    }

    @ViewBuilder
    private func accessory(
        _ action: TaptionWidgetCatAction,
        phase: Int
    ) -> some View {
        switch action {
        case .sleeping:
            Text(phase.isMultiple(of: 2) ? "z" : "zZ")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
                .offset(x: 22, y: -15)
        case .eating:
            ZStack {
                Capsule()
                    .fill(Color(red: 0.89, green: 0.46, blue: 0.36))
                    .frame(width: 20, height: 7)
                HStack(spacing: 1) {
                    Circle().fill(.brown).frame(width: 3, height: 3)
                    Circle().fill(.brown).frame(width: 3, height: 3)
                }
                .offset(y: -3)
            }
            .offset(x: 21, y: 16)
        case .startled:
            Image(systemName: "exclamationmark")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Color.tpNow)
                .offset(x: 21, y: -17)
        case .ballPlay:
            Circle()
                .fill(Color(red: 0.38, green: 0.61, blue: 0.88))
                .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 1) }
                .frame(width: 11, height: 11)
                .offset(
                    x: phase.isMultiple(of: 2) ? 23 : 16,
                    y: phase.isMultiple(of: 2) ? 15 : 8
                )
        case .fishingPlay:
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 16, y: 4))
                    path.addLine(to: CGPoint(x: 45, y: 29))
                }
                .stroke(
                    Color.tpSecondary,
                    style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                )
                Image(systemName: "fish.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.tpPlaceDark)
                    .offset(
                        x: 21,
                        y: 12 + CGFloat(phase % 2) * 3
                    )
            }
            .frame(width: 64, height: 48)
        case .grooming:
            Image(systemName: "sparkles")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.tpWeatherDark)
                .offset(x: 20, y: -14)
        default:
            EmptyView()
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
