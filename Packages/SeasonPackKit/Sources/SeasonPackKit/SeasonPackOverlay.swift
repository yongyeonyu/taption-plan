import SwiftUI

/// 앱이 지도 위에 한 번 얹는 최상위 뷰. 기본은 터치를 통과시키고(`allowsHitTesting` false), 아이콘·산타·선물만 히트를 연다.
/// 이벤트가 없으면 아무것도 그리지 않는다.
public struct SeasonPackOverlay: View {
    private let center: SeasonPackCenter
    private let homeOrigin: CGPoint?
    @Environment(\.scenePhase) private var scenePhase

    public init(center: SeasonPackCenter = .shared, homeOrigin: CGPoint? = nil) { self.center = center; self.homeOrigin = homeOrigin }

    public var body: some View {
        ZStack {
            if center.active != nil {
                if let snow = center.activeSnow { SeasonPackSnowLayer(config: snow, motion: center.motion) }
                SeasonPackActorLayer(center: center)
                SeasonPackIconLayer(center: center, origin: homeOrigin)
                if let cue = center.stage.lyricText {
                    GeometryReader { proxy in
                        SeasonPackKaraokeBubble(text: cue)
                            .position(x: homeOrigin?.x ?? proxy.size.width * 0.5, y: (homeOrigin?.y ?? proxy.size.height * 0.42) - 96)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: center.stage.lyricText)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                center.stage.resume()
                center.recompute()
            } else {
                center.stage.pause()
            }
        }
        .onDisappear { center.stage.pause() }
    }
}
