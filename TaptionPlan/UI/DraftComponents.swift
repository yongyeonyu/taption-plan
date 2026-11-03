import SwiftUI

/// Apple 날씨 출처 표기(결합 마크와 법적 고지 링크). 상세·설정 화면에서만 쓴다.
struct WeatherAttributionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var attribution = WeatherAttributionInfo.fallback

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let url = attribution.markURL(isDark: colorScheme == .dark) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Text(attribution.serviceName)
                }
                .frame(height: 14)
            } else {
                Text(attribution.serviceName)
                    .font(.taption(size: 9, weight: .semibold))
            }
            Link(
                "날씨 데이터 출처 및 법적 고지",
                destination: attribution.legalPageURL
            )
            .font(.taption(size: 8))
        }
        .foregroundStyle(Color.tpSecondary)
        .task { attribution = await WeatherAttributionStore.shared.current() }
    }
}

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
        VStack(spacing: TaptionMenuMetrics.sectionSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: TaptionMenuMetrics.sectionSpacing) {
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
                            .frame(
                                width: TaptionMenuMetrics.topBarIconSize,
                                height: TaptionMenuMetrics.topBarIconSize
                            )
                            .background(
                                Color.tpSky.opacity(0.22),
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                    .frame(
                        width: TaptionMenuMetrics.topBarIconHitSize,
                        height: TaptionMenuMetrics.topBarIconHitSize
                    )
                    .contentShape(Rectangle())
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
                        .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
                        .contentShape(Rectangle())
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
        .padding(.horizontal, TaptionMenuMetrics.contentInset)
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
                .frame(
                    width: TaptionMenuMetrics.topBarNavigationButtonSize,
                    height: TaptionMenuMetrics.topBarNavigationButtonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(
            width: TaptionMenuMetrics.topBarNavigationHitSize,
            height: TaptionMenuMetrics.topBarNavigationHitSize
        )
        .contentShape(Rectangle())
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
                        .padding(.vertical, TaptionMenuMetrics.scaleControlVerticalPadding)
                        .background {
                            if selected == scale {
                                RoundedRectangle(cornerRadius: TaptionRadius.tight, style: .continuous)
                                    .fill(Color.tpSurface)
                                    .shadow(color: Color.tpSky.opacity(0.24), radius: 1.5, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
                .contentShape(Rectangle())
                .accessibilityLabel("\(scale.rawValue) 보기")
                .accessibilityIdentifier("schedule.scale.\(scale.rawValue)")
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: TaptionRadius.control, style: .continuous)
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

struct DraftChip: View {
    let title: String
    var selected = false
    var tint: Color = .tpInk
    var fontSize: CGFloat = 9.5

    var body: some View {
        Text(title)
            .font(.taption(size: fontSize, weight: .bold))
            .foregroundStyle(selected ? Color.white : Color.tpSecondary)
            .padding(.horizontal, TaptionMenuMetrics.chipHorizontalPadding)
            .padding(.vertical, TaptionMenuMetrics.chipVerticalPadding)
            .background(selected ? tint : Color.tpSky.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: TaptionRadius.control, style: .continuous))
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
                with: .color(Color.tpControlFillSoft)
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
