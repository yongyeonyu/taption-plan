import SwiftUI

/// 앱이 지도 위에 한 번 얹는 최상위 뷰. 기본은 터치를 통과시키고(`allowsHitTesting` false), 아이콘·산타·선물만 히트를 연다.
/// 이벤트가 없으면 아무것도 그리지 않는다.
public struct SeasonPackOverlay: View {
    private let center: SeasonPackCenter
    private let homeOrigin: CGPoint?
    @Environment(\.scenePhase) private var scenePhase

    public init(center: SeasonPackCenter = .shared, homeOrigin: CGPoint? = nil) { self.center = center; self.homeOrigin = homeOrigin }

    /// 측정 전용(LAG1120A01): `-seasonHide snow,actors,icons`로 조각을 빼고 대기 CPU를 비교한다. BENCH·DEBUG 판에만 있다.
    private static func hides(_ part: String) -> Bool {
#if DEBUG || BENCH
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-seasonHide"), arguments.indices.contains(index + 1) else { return false }
        return arguments[index + 1].split(separator: ",").contains { $0 == part }
#else
        return false
#endif
    }

    public var body: some View {
        ZStack {
            if center.active != nil {
                if let snow = center.activeSnow, !Self.hides("snow") { SeasonPackSnowLayer(config: snow, motion: center.motion) }
                if !Self.hides("actors") { SeasonPackActorLayer(center: center) }
                if !Self.hides("icons") { SeasonPackIconLayer(center: center, origin: homeOrigin) }
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
            // 앱이 열려 있는 동안은 타이머가 돈다. 알림·제어 센터처럼 잠깐 비활성이 되는 것은 멈추지 않고, 백그라운드에서만 멈춘다.
            switch phase {
            case .active:
                center.stage.resume()
                center.recompute()
            case .background:
                center.stage.pause()
            default:
                break
            }
        }
        .onDisappear { center.stage.pause() }
    }
}
