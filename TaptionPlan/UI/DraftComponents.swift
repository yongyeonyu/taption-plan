import SwiftUI

struct DraftTopBar: View {
    let title: String
    let trailing: String
    var trailingColor: Color = .tpSecondary
    var selectedScale: TimeScale?
    var onScaleChange: ((TimeScale) -> Void)?
    var onBack: (() -> Void)?

    var body: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let onBack {
                    Button(action: onBack) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .bold))
                            Text(title)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                } else {
                    Text(title)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                }

                Spacer(minLength: 4)

                Text(trailing)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(trailingColor)
                    .lineLimit(1)
            }

            if let selectedScale {
                DraftScalePicker(selected: selectedScale) { scale in
                    onScaleChange?(scale)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 5)
        .padding(.bottom, 8)
        .background(Color.white)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.tpLine)
                .frame(height: 0.5)
        }
    }
}

struct DraftScalePicker: View {
    let selected: TimeScale
    let onSelect: (TimeScale) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TimeScale.allCases) { scale in
                Button {
                    onSelect(scale)
                } label: {
                    Text(scale.rawValue)
                        .font(.system(size: 12.5, weight: selected == scale ? .semibold : .regular))
                        .foregroundStyle(selected == scale ? Color.tpInk : Color.tpSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if selected == scale {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(red: 0.93, green: 0.93, blue: 0.94))
        )
    }
}

struct DraftBottomNavigationBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            tabButton(.schedule)
            tabButton(.goals)

            Button {
                if model.detail == .group,
                   let parentID = model.selectedGroupPlanID {
                    model.addPlanContext = .child(parentID)
                } else {
                    model.addPlanContext = .quick
                }
                model.isAddPlanPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.tpInk, in: Circle())
                    .shadow(color: .black.opacity(0.28), radius: 7, y: 4)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(
                model.detail == .group ? "하위 계획 추가" : "계획 추가"
            )

            tabButton(.review)
            tabButton(.settings)
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.white.opacity(0.97))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.tpLine)
                .frame(height: 0.5)
        }
    }

    private func tabButton(_ tab: RootTab) -> some View {
        Button {
            model.selectTab(tab)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 19, weight: model.selectedTab == tab ? .bold : .regular))
                    .frame(height: 20)
                Text(tab.rawValue)
                    .font(.system(size: 9.5, weight: model.selectedTab == tab ? .bold : .regular))
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
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(selected ? Color.white : Color.tpSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(selected ? tint : Color(red: 0.94, green: 0.94, blue: 0.95))
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
        ZStack {
            Triangle()
                .fill(coat.baseColor)
                .frame(width: 15, height: 14)
                .rotationEffect(.degrees(-7))
                .offset(x: -13, y: -13)
            Triangle()
                .fill(earColor)
                .frame(width: 15, height: 14)
                .rotationEffect(.degrees(7))
                .offset(x: 13, y: -13)

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(coat.baseColor)
                .overlay {
                    coatPattern
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(outlineColor, lineWidth: 1.5)
                }

            HStack(spacing: 10) {
                Circle().fill(eyeColor).frame(width: 3.5, height: 3.5)
                Circle().fill(eyeColor).frame(width: 3.5, height: 3.5)
            }
            .offset(y: -1)
        }
        .frame(width: 42, height: 31)
    }

    @ViewBuilder
    private var coatPattern: some View {
        switch coat {
        case .calico:
            ZStack {
                Circle().fill(Color(red: 0.22, green: 0.21, blue: 0.23))
                    .frame(width: 17, height: 17).offset(x: -12, y: -8)
                Circle().fill(Color(red: 0.86, green: 0.53, blue: 0.23))
                    .frame(width: 19, height: 19).offset(x: 13, y: 8)
            }
        case .mackerel:
            stripePattern(color: Color(red: 0.30, green: 0.31, blue: 0.32))
        case .cheese:
            stripePattern(color: Color(red: 0.66, green: 0.42, blue: 0.16))
        case .cow:
            ZStack {
                Circle().fill(Color.tpInk).frame(width: 18, height: 18).offset(x: -13, y: -7)
                Circle().fill(Color.tpInk).frame(width: 20, height: 20).offset(x: 14, y: 9)
            }
        default:
            EmptyView()
        }
    }

    private func stripePattern(color: Color) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<5, id: \.self) { _ in
                Rectangle()
                    .fill(color)
                    .frame(width: 3)
                    .rotationEffect(.degrees(18))
            }
        }
    }

    private var earColor: Color {
        coat == .calico ? Color(red: 0.86, green: 0.53, blue: 0.23) : coat.baseColor
    }

    private var outlineColor: Color {
        coat == .black ? .black : Color(red: 0.35, green: 0.35, blue: 0.38)
    }

    private var eyeColor: Color {
        coat == .black ? Color(red: 0.96, green: 0.83, blue: 0.37) : .tpInk
    }
}

struct RunningCatView: View {
    let coat: CatCoat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hopping = false

    var body: some View {
        HStack(spacing: -4) {
            Capsule()
                .stroke(outline, lineWidth: 2)
                .frame(width: 14, height: 7)
                .rotationEffect(.degrees(-28))
            Ellipse()
                .fill(coat.baseColor)
                .frame(width: 25, height: 14)
                .overlay(alignment: .trailing) {
                    Circle()
                        .fill(coat.baseColor)
                        .frame(width: 13, height: 13)
                        .overlay {
                            Circle().fill(eye).frame(width: 2, height: 2).offset(x: 3, y: -1)
                        }
                        .offset(x: 5, y: -3)
                }
                .overlay(alignment: .bottom) {
                    HStack(spacing: 7) {
                        Capsule().fill(outline).frame(width: 2, height: 9).rotationEffect(.degrees(25))
                        Capsule().fill(outline).frame(width: 2, height: 9).rotationEffect(.degrees(-25))
                    }
                    .offset(y: 6)
                }
        }
        .frame(width: 40, height: 27)
        .offset(y: hopping ? -2 : 0)
        .animation(
            reduceMotion ? nil : .linear(duration: 0.21).repeatForever(autoreverses: true),
            value: hopping
        )
        .onAppear {
            if !reduceMotion {
                hopping = true
            }
        }
    }

    private var outline: Color {
        coat == .black ? .black : Color(red: 0.27, green: 0.28, blue: 0.30)
    }

    private var eye: Color {
        coat == .black ? Color(red: 0.96, green: 0.83, blue: 0.37) : .tpInk
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
