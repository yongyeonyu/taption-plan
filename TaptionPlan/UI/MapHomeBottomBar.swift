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
    /// 하단 메뉴 알약. 지도가 비치지 않게 불투명하게 칠한다(대표 요청).
    func mapHomeBottomBarPill() -> some View {
        frame(height: MapHomeBottomBarMetrics.pillHeight)
            .background {
                Capsule()
                    .fill(Color.tpSurface)
                    .overlay(Capsule().stroke(Color.tpLine.opacity(0.8), lineWidth: 0.6))
                    .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
            }
    }
}
