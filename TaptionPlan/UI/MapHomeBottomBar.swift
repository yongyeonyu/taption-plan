import SwiftUI

/// 지도 홈 하단 메뉴. 화면 모서리 곡률을 따라 떠 있는 알약이다(NAV1102A01, 대표).
enum MapHomeBottomBarMetrics {
    static let pillHeight: CGFloat = 56
    /// 좌우·아래 여백을 같게 해 알약 끝이 화면 모서리와 나란해 보이게 한다.
    static let edgeMargin: CGFloat = 14
    /// 지도·사이드바가 비워 두는 높이(`MapHomeLayoutStyle.bottomReservedHeight`)와 같아야 한다.
    static var reservedHeight: CGFloat { pillHeight + edgeMargin }
}

/// 아이콘과 이름이 위아래로 놓인 하단 메뉴 단추. 이름 줄이 나란하도록 아이콘 자리는 26pt로 같다.
struct MapHomeBottomBarButton<Icon: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder let icon: Icon

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                icon
                    .frame(width: 26, height: 26)
                Text(title)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(height: 12)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

extension View {
    /// 하단 메뉴 알약. 위쪽 둥근 단추(`TaptionStickerDisc`)와 같은 입체 바탕이다(BAR1108A01).
    /// 사진링이 접혀 있으면 가운데 위에 반달이 붙고, 테두리는 반달까지 한 덩어리로 두른다.
    func mapHomeBottomBarPill(showsTab: Bool = false) -> some View {
        frame(height: MapHomeBottomBarMetrics.pillHeight)
            .background { MapHomeBottomBarBackground(showsTab: showsTab) }
    }
}

/// 알약과(있으면) 위쪽 가운데 반달을 합친 모양. 반달은 알약 위 끝에서 위로 솟는다.
struct MapHomeBottomBarShape: Shape {
    var showsTab: Bool

    func path(in rect: CGRect) -> Path {
        let pill = Path(roundedRect: rect, cornerRadius: rect.height / 2, style: .continuous)
        guard showsTab else { return pill }
        let w = MapHomePhotoRingTab.width, h = MapHomePhotoRingTab.height
        // 알약 위 끝과 조금 겹쳐야 합친 모양에 틈이 생기지 않는다.
        let tab = Path(roundedRect: CGRect(x: rect.midX - w / 2, y: rect.minY - h, width: w, height: h + 2),
                       cornerRadii: RectangleCornerRadii(topLeading: h, topTrailing: h))
        return pill.union(tab)
    }
}

struct MapHomeBottomBarBackground: View {
    var showsTab: Bool

    var body: some View {
        let palette = TaptionBarPalette.current
        let shape = MapHomeBottomBarShape(showsTab: showsTab)
        ZStack {
            shape.fill(LinearGradient(
                colors: [palette.cream, palette.cream.mix(with: .black, by: 0.08)],
                startPoint: .top, endPoint: .bottom
            ))
            // 위쪽 빛 반사. 단추의 흰 타원과 같은 역할을 넓은 알약에 맞게 띠로 둔다.
            shape.fill(LinearGradient(
                stops: [.init(color: .white.opacity(0.55), location: 0), .init(color: .white.opacity(0), location: 0.45)],
                startPoint: .top, endPoint: .bottom
            ))
            .padding(3)
            // 테두리는 사이드바와 같은 회색 한 줄(BAR1111A01, 대표 지시).
            shape.stroke(Color.tpBorder, lineWidth: TaptionBorder.width)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.22), radius: 2.5, y: 2)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .accessibilityHidden(true)
    }
}
