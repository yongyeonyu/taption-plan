import SwiftUI

/// 지도 위 이벤트 아이콘 레이어. 매니페스트의 `menuIcons[]`만 읽고, 구간 밖이면 뷰를 만들지 않는다.
/// 아이콘은 44pt 이상 히트 영역을 열고 누르면 그 팩이 정의한 메뉴 시트가 열린다.
public struct SeasonPackIconLayer: View {
    private let center: SeasonPackCenter
    private let origin: CGPoint?
    @State private var opened: SeasonPackPlacedIcon?

    /// `origin`은 집 아이콘의 화면 위치(없으면 화면 오른쪽 가운데쯤).
    public init(center: SeasonPackCenter = .shared, origin: CGPoint? = nil) { self.center = center; self.origin = origin }

    public var body: some View {
        GeometryReader { proxy in
            let base = origin ?? CGPoint(x: proxy.size.width - 52, y: proxy.size.height * 0.42)
            let icons = center.placedIcons(origin: base, bounds: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(icons) { placed in
                    if let pack = center.active, let image = SeasonPackImageCache.shared.image(pack: pack, asset: placed.icon.icon) {
                        Button { opened = placed } label: {
                            Image(decorative: image, scale: 3).resizable().scaledToFit().frame(width: 32, height: 32)
                                .frame(width: 44, height: 44)
                                .background(.regularMaterial, in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(placed.icon.label?.resolve(language: center.host?.languageCode ?? "en") ?? "")
                        .position(x: base.x + placed.offset.x, y: base.y + placed.offset.y)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .sheet(item: $opened) { placed in
            SeasonPackMenuView(center: center, packID: placed.packID, menu: placed.icon.menu, language: center.host?.languageCode ?? "en")
        }
    }
}
