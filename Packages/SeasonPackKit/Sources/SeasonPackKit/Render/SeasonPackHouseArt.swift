import SwiftUI

/// 집 아이콘 자리에 들어가는 팩 그림. `base`(낮)와 `lit`(점등)를 겹쳐 두고 크로스페이드하며, `glow`(별·반짝임)는 점등 중에 고정으로 얹는다.
/// 점멸은 `lit` 층의 밝기만 오르내린다. 동작 줄이기·저전력에서는 점멸 없이 정지한 `lit` 그림이다. 이벤트가 없으면 아무것도 그리지 않는다.
public struct SeasonPackHouseView: View {
    private let center: SeasonPackCenter
    private let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(center: SeasonPackCenter = .shared, size: CGFloat) {
        self.center = center; self.size = size
    }

    /// 이 팩이 집 그림을 바꾸는가(앱이 기존 그림을 가릴지 정할 때 쓴다).
    public static func replacesHouse(center: SeasonPackCenter = .shared) -> Bool { center.houseState() != nil }

    public var body: some View {
        if let pack = center.active, let state = center.houseState() {
            let _ = center.motion
            ZStack {
                layer(pack, state.baseAsset)
                if state.litAsset != nil {
                    let bulbs = pack.manifest.slots?.house?.bulbs
                    TimelineView(.animation(minimumInterval: 1.0 / 20, paused: state.blink == .none || bulbs != nil)) { context in
                        ZStack {
                            // 전구 시퀀스가 있으면 그림은 고정이고 불빛만 차례로 깜빡인다.
                            layer(pack, state.litAsset)
                                .opacity(state.isLit ? (bulbs != nil ? 1 : SeasonPackRenderer.blinkLevel(state.blink, at: context.date)) : 0)
                            layer(pack, state.glowAsset).opacity(state.isLit ? 1 : 0)
                        }
                    }
                    .animation(.easeInOut(duration: 1.5), value: state.isLit)
                    if let bulbs, state.isLit {
                        SeasonPackBulbsView(bulbs: bulbs, animated: !center.motion.isReduced)
                            .transition(.opacity)
                    }
                }
            }
            .frame(width: size, height: size)
            .overlay { textSlots(pack) }
            .overlay { treeHit(state.isLit) }
            .accessibilityHidden(true)
            .onAppear { center.motion = SeasonPackMotionPolicy(reduceMotion: reduceMotion, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled) }
            .onChange(of: reduceMotion) { _, value in
                center.motion = SeasonPackMotionPolicy(reduceMotion: value, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
            }
        }
    }

    /// 연도·메모 글자 칸: 그림에 굽지 않고 그 해 숫자를 런타임에 그린다.
    @ViewBuilder
    private func textSlots(_ pack: SeasonPack) -> some View {
        if let year = center.activeYear {
            let line = pack.manifest.slots?.bubbles?.memoItem.flatMap { center.memoStore?.firstLine(packID: pack.id, itemID: $0) }
            ForEach(pack.manifest.textSlots ?? [], id: \.id) { slot in
                SeasonPackTextSlotView(slot: slot, packID: pack.id, year: year, memoLine: line, defaults: center.defaults)
            }
        }
    }

    @ViewBuilder
    private func layer(_ pack: SeasonPack, _ asset: String?) -> some View {
        if let asset, let image = SeasonPackImageCache.shared.image(pack: pack, asset: asset) {
            Image(decorative: image, scale: 1).resizable().scaledToFit()
        }
    }

    /// 트리 터치는 점등 중 그림 위쪽 가운데 영역에서만 받는다. 그 밖은 기존 탭(하루 요약)이 그대로 받는다.
    @ViewBuilder
    private func treeHit(_ isLit: Bool) -> some View {
        if isLit {
            Color.clear
                .frame(width: size * 0.5, height: size * 0.62)
                .contentShape(Rectangle())
                .offset(y: -size * 0.04)
                .onTapGesture { center.stage.houseTapped() }
        }
    }
}

/// 캐릭터 위에 얹는 팩 레이어(의상·악세사리). 앵커·크기·오프셋은 매니페스트가 정한다.
public struct SeasonPackCharacterLayersView: View {
    private let layers: [(image: CGImage, layer: SeasonPackManifest.Layer)]

    public init(layers: [(image: CGImage, layer: SeasonPackManifest.Layer)]) { self.layers = layers }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(Array(layers.enumerated()), id: \.offset) { _, entry in
                    let frame = SeasonPackLayerPlacement.frame(for: entry.layer, imageSize: CGSize(width: entry.image.width, height: entry.image.height), in: proxy.size)
                    Image(decorative: entry.image, scale: 1)
                        .resizable().scaledToFit()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
