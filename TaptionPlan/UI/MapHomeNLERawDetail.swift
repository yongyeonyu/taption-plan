import SwiftUI

/// 세 줄의 너비. 대분류가 가장 넓고, 센서 원본과 상세활동이 오른쪽에 나란히 선다.
/// 상세활동 구간에 겹친 센서 근거 한 줄(NLE1103A01).
enum NLESensorEvidenceText {
    static func summary(_ segments: [MapHomeNLESensorSegment], start: Int, end: Int, categoryID: String) -> (text: String, differs: Bool) {
        let inside = segments.filter { $0.startMinute < end && $0.endMinute > start }
        var titles: [String] = []
        for segment in inside.sorted(by: { $0.channel.rawValue < $1.channel.rawValue }) where !titles.contains(segment.title) {
            titles.append(segment.title)
        }
        // 정지는 어느 분류와도 어긋나지 않는다. 회의·휴식은 앉아서 한다(NLE1103A02).
        let differs = inside.contains {
            $0.channel == .motion && $0.categoryID != categoryID && $0.categoryID != "unconfirmed"
                && $0.behavior != MotionKind.stationary.rawValue
        }
        return (titles.prefix(6).joined(separator: " · "), differs)
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
        .overlay(Capsule().stroke(Color.tpBorder, lineWidth: TaptionBorder.width))
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
