import SwiftUI

/// 세 줄의 너비. 대분류가 가장 넓고, 센서 원본과 상세활동이 오른쪽에 나란히 선다.
struct NLELaneWidths {
    let main: CGFloat
    let sensor: CGFloat
    let detail: CGFloat

    init(total: CGFloat, gutter: CGFloat, gap: CGFloat, sensorExpanded: Bool) {
        let usable = max(90, total - gutter - gap * 2)
        let main = max(40, (usable * (sensorExpanded ? 0.36 : 0.56)).rounded())
        let sensor = sensorExpanded ? max(26, (usable * 0.34).rounded()) : 26
        self.main = main
        self.sensor = sensor
        self.detail = max(26, usable - main - sensor)
    }
}

struct NLERawDetail: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let lines: [String]
}

/// 고른 시각에 가장 가까운 측정값 하나의 모든 값을 줄 단위로 보여 준다.
struct NLERawDetailSheet: View {
    let detail: NLERawDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(detail.title)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(18)), weight: .bold))
                .foregroundStyle(Color.tpInk)
                .padding(.horizontal, 20)
                .padding(.top, 26)
                .padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(detail.lines.enumerated()), id: \.offset) { index, line in
                        if index > 0 { Divider().padding(.leading, 16) }
                        Text(line)
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .medium))
                            .foregroundStyle(Color.tpInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                }
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(Color.tpBackground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("mapHomeNLERawDetailSheet")
    }
}

/// 겹치지 않게 칩을 고른다. 표시 간격이 좁아지면 먼저 온 구간을 남긴다.
enum NLESuggestionLayout {
    static let chipSpacing: CGFloat = 28

    static func placed(_ items: [(segment: MapHomeNLESensorSegment, y: CGFloat)]) -> [(segment: MapHomeNLESensorSegment, y: CGFloat)] {
        var result: [(segment: MapHomeNLESensorSegment, y: CGFloat)] = []
        for item in items.sorted(by: { $0.y < $1.y }) where item.y >= 0 {
            if let last = result.last, item.y - last.y < chipSpacing { continue }
            result.append(item)
        }
        return result
    }
}

/// 센서 근거로 고칠 수 있는 구간 칩.
struct NLESuggestionChip: View {
    let title: String
    let language: MapHomeLanguage
    let action: () -> Void

    private var shortTitle: String {
        title.components(separatedBy: " · ").first ?? title
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                TaptionCuteIcon("sparkles", size: 12)
                Text(language.text("\(shortTitle)(으)로 바꾸기", "Change to \(shortTitle)"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Color.tpAccent)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.tpSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.tpAccent.opacity(0.5), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }
}

enum NLEQuickMenuMetrics {
    static let height: CGFloat = 44
    static let width: CGFloat = 138
}

/// 누른 클립 옆의 알약. 아래 도구 막대까지 손을 옮기지 않아도 자주 쓰는 세 가지를 고른다.
struct NLEQuickMenuPill<MenuItems: View>: View {
    let language: MapHomeLanguage
    @ViewBuilder let menuItems: MenuItems
    let onSplit: () -> Void
    let onDelete: () -> Void

    init(
        language: MapHomeLanguage,
        @ViewBuilder menuItems: () -> MenuItems,
        onSplit: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.language = language
        self.menuItems = menuItems()
        self.onSplit = onSplit
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                menuItems
            } label: {
                icon("square.grid.2x2", language.text("분류", "Category"))
            }
            Button(action: onSplit) { icon("scissors", language.text("가르기", "Split")) }
                .buttonStyle(.plain)
            Button(action: onDelete) { icon("trash", language.text("지우기", "Clear")) }
                .buttonStyle(.plain)
        }
        .frame(height: NLEQuickMenuMetrics.height)
        .background(Color.tpSurface, in: Capsule())
        .overlay(Capsule().stroke(Color.tpLine, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    private func icon(_ systemImage: String, _ label: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
            .foregroundStyle(Color.tpInk)
            .frame(maxWidth: .infinity, minHeight: NLEQuickMenuMetrics.height)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }
}
