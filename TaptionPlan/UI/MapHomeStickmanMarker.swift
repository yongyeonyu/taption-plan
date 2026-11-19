import Foundation
import SeasonPackKit
import SwiftUI

enum MapHomeStickmanAnimationEngine {
    static let frameDuration = TaptionLiveActivityStickmanAnimation.frameDuration
    static let phaseCount = TaptionLiveActivityStickmanAnimation.frameCount

    static func phase(at date: Date, reducesMotion: Bool = false) -> Int {
        TaptionLiveActivityStickmanAnimation.frameIndex(
            at: date.timeIntervalSinceReferenceDate,
            isAnimating: !reducesMotion
        )
    }

    static func phase(for progress: Double) -> Int {
        guard progress.isFinite else { return 0 }
        let normalized = min(max(progress, 0), 1)
        return min(
            phaseCount - 1,
            Int((normalized * Double(phaseCount)).rounded(.down))
        )
    }

    static func oscillation(for phase: Int) -> Double {
        sin(2 * .pi * Double(phase) / Double(phaseCount))
    }

    static func secondaryOscillation(for phase: Int) -> Double {
        sin(4 * .pi * Double(phase) / Double(phaseCount))
    }

    static func pulse(for phase: Int) -> Double {
        (oscillation(for: phase) + 1) / 2
    }
}

enum MapHomeStickmanRoutePhase {
    case actual
    case forecast

    var color: Color {
        Color(
            hex: self == .actual
                ? MapHomeWBSTripStyle.actualRouteHex
                : MapHomeWBSTripStyle.forecastRouteHex
        )
    }
}

/// 이동 속도를 30km/h 구간으로 나눠 고양이 동작·표정·이펙트를 바꾼다.
/// 동작만 보고 속도를 가늠할 수 있게, 구간이 오를수록 걷기→뛰기→질주→
/// (피카츄처럼) 번개 질주로 변한다.
enum MapHomeSpeedTier: Int, CaseIterable, Sendable {
    case idle       // 정지/미세 이동
    case strolling  // 0-10km/h 우아하게 걷기
    case walking    // 10-30
    case jogging    // 30-60 걷기→뛰기 전환
    case running    // 60-90 매우 빠르게
    case flying     // 90-120 거의 날아가듯
    case pikachu    // 120+ 번개 질주

    static func tier(forMetersPerSecond mps: Double?) -> MapHomeSpeedTier {
        guard let mps, mps > 0 else { return .idle }
        let kmh = mps * 3.6
        switch kmh {
        case ..<0.8: return .idle
        case ..<10: return .strolling
        case ..<30: return .walking
        case ..<60: return .jogging
        case ..<90: return .running
        case ..<120: return .flying
        default: return .pikachu
        }
    }

    /// 이 구간에서 쓸 화랑이 장면. 지도에서 움직이는 동안은 멈추지 않는 걷기·달리기만 쓴다.
    var scene: HwarangScene {
        switch self {
        case .idle, .strolling, .walking: .walkLoop
        case .jogging, .running, .flying, .pikachu: .runLoop
        }
    }

    /// 동작 재생 배속. 빠를수록 다리가 더 빨리 움직인다.
    var frameRateMultiplier: Double {
        switch self {
        case .idle: return 1
        case .strolling: return 0.8
        case .walking: return 1.1
        case .jogging: return 1.6
        case .running: return 2.2
        case .flying: return 3.0
        case .pikachu: return 4.0
        }
    }

    /// 진행 방향으로 기울이는 각도(질주감).
    var leanDegrees: Double {
        switch self {
        case .idle, .strolling, .walking: return 0
        case .jogging: return 6
        case .running: return 12
        case .flying: return 20
        case .pikachu: return 26
        }
    }

    /// 뒤로 끌리는 스피드 라인 개수(0=없음).
    var speedLines: Int {
        switch self {
        case .idle, .strolling, .walking: return 0
        case .jogging: return 2
        case .running: return 3
        case .flying: return 4
        case .pikachu: return 5
        }
    }

    var isPikachu: Bool { self == .pikachu }
}

struct MapHomeStickmanMarker: View {
    static let size = CGSize(width: 36, height: 36)

    let action: MapHomeStickmanAction
    var animationPhase: Int? = nil
    var routePhase: MapHomeStickmanRoutePhase = .actual
    var speedMetersPerSecond: Double? = nil
    var equippedAccessoryID: String? = nil
    var facesLeft = false
    var rideLabel: String? = nil
    var rendersAsynchronously = false // 지도 위에서만 켠다(영상 렌더러는 끈 채로, PRF1116A01).
    @AppStorage(MapHomeStickmanAction.vehicleDisplayKey) private var showsVehicles = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let isStatic = reduceMotion || isLuminanceReduced || !action.animatesPresentation
        let scene = action.markerScene(speedMetersPerSecond: speedMetersPerSecond, showsVehicles: showsVehicles)
        let tier = action.isMoving && !scene.isVehicleScene
            ? MapHomeSpeedTier.tier(forMetersPerSecond: speedMetersPerSecond)
            : .idle
        let hat = MapHomeGrowthAccessoryCatalog.hatAssetName(for: equippedAccessoryID)
        let scarf = MapHomeGrowthAccessoryCatalog.scarfStyle(for: equippedAccessoryID)
        let ribbon = MapHomeGrowthAccessoryCatalog.ribbonStyle(for: equippedAccessoryID)
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30,
                paused: isStatic || animationPhase != nil || MapHomeLiveGate.shared.isCovered
            )
        ) { context in
            let clock = animationPhase.map { Double($0) * MapHomeStickmanAnimationEngine.frameDuration }
                ?? HwarangClock.seconds(at: context.date)
            let sec = isStatic ? 0 : clock * (action.isMoving ? tier.frameRateMultiplier : 1)
            ZStack {
                // 스피드 라인 — 빠를수록 뒤로 더 많이 끌린다.
                if tier.speedLines > 0 {
                    HStack(spacing: 1.5) {
                        ForEach(0..<tier.speedLines, id: \.self) { i in
                            Capsule()
                                .fill(
                                    (tier.isPikachu ? Color.yellow : Color.tpAccent)
                                        .opacity(0.55 - Double(i) * 0.08)
                                )
                                .frame(width: 6 + CGFloat(i) * 2, height: 1.6)
                        }
                    }
                    .offset(x: Self.size.width * (facesLeft ? 0.9 : -0.9))
                }
                HwarangSceneView(
                    scene: scene,
                    sec: sec,
                    width: Self.size.width * 1.6,
                    anchorHeight: Self.size.height,
                    facesLeft: facesLeft && action.isMoving,
                    hatAssetName: hat,
                    scarf: scarf,
                    ribbon: ribbon,
                    showsBackdrop: false, rendersAsynchronously: rendersAsynchronously
                )
                .rotationEffect(.degrees(facesLeft ? -tier.leanDegrees * 0.5 : tier.leanDegrees * 0.5))
                // 피카츄 구간 — 번개 스파크.
                if tier.isPikachu {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .black))
                        .foregroundStyle(.yellow)
                        .shadow(color: .orange.opacity(0.8), radius: 2)
                        .offset(x: Self.size.width * 0.28, y: -Self.size.height * 0.26)
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .overlay(alignment: .top) { if let rideLabel, scene.isVehicleScene { MapHomeRideLabelBadge(text: rideLabel) } }
        .taptionShadow(.floating)
        .accessibilityHidden(true)
    }
}

struct MapHomeStickmanGlyph: View {
    let action: MapHomeStickmanAction
    var size: CGFloat = 30
    var equippedAccessoryID: String? = nil
    var rendersAsynchronously = false
    /// 집에 있는 화랑이만 시즌 팩의 모자·의상을 입는다(SEA1119A01).
    var usesSeasonPack = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let isStatic = reduceMotion || isLuminanceReduced || !action.animatesPresentation
        let seasonHat = usesSeasonPack ? SeasonPackAdapter.hatImage() : nil
        let seasonLayers = usesSeasonPack ? SeasonPackAdapter.characterLayers() : []
        let hat = MapHomeGrowthAccessoryCatalog.hatAssetName(for: equippedAccessoryID)
        let seasonLook = usesSeasonPack ? SeasonPackAdapter.look() : nil
        let scarf = seasonLook?.scarf ?? MapHomeGrowthAccessoryCatalog.scarfStyle(for: equippedAccessoryID)
        let ribbon = seasonLook?.ribbon ?? MapHomeGrowthAccessoryCatalog.ribbonStyle(for: equippedAccessoryID)
        // 같은 화면의 화랑이들이 동시에 같은 자세로 겹치지 않게 분류별로 시작을 어긋낸다.
        let offset = Double(MapHomeStickmanAction.allCases.firstIndex(of: action) ?? 0) * 3.7
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: isStatic || MapHomeLiveGate.shared.isCovered)) { context in
            HwarangSceneView(
                scene: action.hwarangScene,
                sec: isStatic ? 0 : HwarangClock.seconds(at: context.date) + offset,
                width: size * 1.6,
                anchorHeight: size,
                hatAssetName: hat,
                hatImage: seasonHat,
                scarf: scarf,
                ribbon: ribbon,
                seasonLook: seasonLook,
                showsBackdrop: size >= 36,
                keepsBodySize: false, rendersAsynchronously: rendersAsynchronously
            )
        }
        .frame(width: size, height: size)
        .overlay { if !seasonLayers.isEmpty { SeasonPackCharacterLayersView(layers: seasonLayers).frame(width: size * 1.6, height: size * 1.6) } }
        .accessibilityHidden(true)
    }
}

enum HwarangClock {
    /// 소수 정밀도를 지키려고 큰 주기로 나머지를 쓴다.
    static func seconds(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 86_400)
    }
}
