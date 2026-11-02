import SwiftUI
import UIKit

/// 넓은 화면(아이패드, 펼친 듀오)의 지도 홈 배치. 기기 이름이 아니라 실제 폭으로 가른다.
enum MapHomeWideLayoutPolicy {
    /// 이 폭부터 넓은 배치를 쓴다. 듀오 바깥 화면(466pt)·아이패드 좁은 분할은 아이폰 배치 그대로다.
    static let minimumWidth: CGFloat = 600
    /// 하단 메뉴 폭. 일곱 단추가 아이폰(402pt)과 같은 간격으로 놓인다.
    static let actionBarWidth: CGFloat = 402
    /// 날짜 줄 폭. 아이폰 402pt 화면에서 펼쳤을 때와 같다.
    static let dateStripWidth: CGFloat = 332
    /// 메뉴 패널 최대 높이. 왼쪽 아래에서 올라오며 화면 끝까지 늘어나지 않는다.
    static let menuMaximumHeight: CGFloat = 640
    /// 재생 진행 바·검색창 최대 폭.
    static let topOverlayMaximumWidth: CGFloat = 402

    static func isWide(viewportWidth: CGFloat) -> Bool {
        viewportWidth >= minimumWidth
    }

    /// 하단 메뉴 폭. 넓은 화면이 아니면 nil(가로 전체).
    static func actionBarWidth(viewportWidth: CGFloat) -> CGFloat? {
        isWide(viewportWidth: viewportWidth) ? actionBarWidth : nil
    }

    /// 사이드바가 아래쪽에서 비워 둘 높이. 넓은 화면은 하단 메뉴가 왼쪽에 있어 비울 것이 없다.
    static func sidebarBottomReserve(viewportWidth: CGFloat, actionBarHeight: CGFloat) -> CGFloat {
        isWide(viewportWidth: viewportWidth) ? 0 : actionBarHeight
    }

    /// 메뉴 패널 위쪽 좌표. 넓은 화면에서는 높이를 제한해 아래에 붙인다.
    static func menuTop(viewportWidth: CGFloat, viewportHeight: CGFloat, minimumTop: CGFloat) -> CGFloat {
        guard isWide(viewportWidth: viewportWidth) else { return minimumTop }
        return max(minimumTop, viewportHeight - menuMaximumHeight)
    }

    /// 날짜 줄 최대 폭. 넓은 화면이 아니면 nil(남은 폭 전부).
    static func dateStripMaximumWidth(viewportWidth: CGFloat) -> CGFloat? {
        isWide(viewportWidth: viewportWidth) ? dateStripWidth : nil
    }

    /// 상단 오버레이(재생 바·검색창) 최대 폭. 넓은 화면이 아니면 nil(제한 없음).
    static func topOverlayMaximumWidth(viewportWidth: CGFloat) -> CGFloat? {
        isWide(viewportWidth: viewportWidth) ? topOverlayMaximumWidth : nil
    }

    /// 검색창 폭 계산에 넘길 화면 폭.
    static func searchViewportWidth(_ viewportWidth: CGFloat) -> CGFloat {
        topOverlayMaximumWidth(viewportWidth: viewportWidth) ?? viewportWidth
    }
}

/// 화면 방향 규칙. 화면 짧은 변이 넓으면(아이패드, 듀오 안쪽) 가로·세로, 아니면(일반 아이폰, 듀오 바깥) 세로만.
enum AppOrientationPolicy {
    static let rotatableShortSide: CGFloat = 600

    /// Info.plist 값과 교집합이 적용되므로 폰에서 `.all`이어도 거꾸로 세운 세로는 나오지 않는다.
    static func mask(screenSize: CGSize) -> UIInterfaceOrientationMask {
        min(screenSize.width, screenSize.height) >= rotatableShortSide ? .all : .portrait
    }
}

extension View {
    /// 하단 메뉴 알약 자리. 넓은 화면은 왼쪽 아래에 폭을 정해 두고, 좁은 폭은 좌우 여백까지 채운다.
    func mapHomeWideActionBar(viewportWidth: CGFloat) -> some View {
        frame(width: MapHomeWideLayoutPolicy.actionBarWidth(viewportWidth: viewportWidth))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MapHomeBottomBarMetrics.edgeMargin)
            .padding(.bottom, MapHomeBottomBarMetrics.edgeMargin)
    }

    /// 넓은 화면에서 검색창 줄을 아이폰 폭으로 왼쪽에 둔다.
    func mapHomeWideTopOverlay(viewportWidth: CGFloat) -> some View {
        frame(maxWidth: MapHomeWideLayoutPolicy.topOverlayMaximumWidth(viewportWidth: viewportWidth))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 화면(접힘·펼침)이 바뀌면 허용 방향을 다시 묻게 한다.
    func refreshesSupportedOrientations() -> some View {
        onGeometryChange(for: CGSize.self, of: { $0.size }) { _ in
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}
