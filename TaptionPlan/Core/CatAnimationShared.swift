import SwiftUI

/// One animation source for the iPhone preview, iPhone/Watch widgets, and the
/// Watch app.  The renderer is deliberately stateless: the caller supplies a
/// pose, so WidgetKit and WatchKit never mutate view state from a background
/// callback.
enum TaptionCatAnimationAction: String, CaseIterable, Sendable {
    case walking
    case running
    case sitting
    case sleeping
    case grooming
    case eating
    case startled
    case ballPlay
    case fishingPlay
    case stretching
    case kneading
    case yawning

    var movesAcrossTrack: Bool {
        self == .walking || self == .running
    }

    /// 앉은 자세를 공유하는 동작. 몸통 크기와 다리 길이를 함께 쓴다.
    var sitsUpright: Bool {
        switch self {
        case .sitting, .grooming, .kneading, .yawning: true
        default: false
        }
    }
}

/// 걸음 위상과 별개로 도는 미세 동작.  눈 깜빡임·귀 털기·꼬리 끝 흔들림은
/// 각자 다른 주기를 쓰므로, 위젯이 드문드문 그리는 프레임끼리도 표정이
/// 달라져 고양이가 얼어붙어 보이지 않는다.
struct TaptionCatIdleBeat: Equatable, Sendable {
    /// 1이면 눈을 완전히 뜬 상태, 0이면 감은 상태.
    var eyeOpenness: Double
    /// -1...1. 귀를 터는 순간에만 크게 움직인다.
    var earFlick: Double
    /// -1...1. 꼬리 끝만 살짝 젓는 양.
    var tailTip: Double

    /// 동작 줄이기에서 쓰는 완전 정지 값.
    static let still = TaptionCatIdleBeat(
        eyeOpenness: 1,
        earFlick: 0,
        tailTip: 0
    )

    static func beat(
        at date: Date,
        reducesMotion: Bool = false
    ) -> TaptionCatIdleBeat {
        guard !reducesMotion else { return .still }
        let seconds = date.timeIntervalSinceReferenceDate
        // 유효하지 않은 날짜에서 나머지 연산이 NaN이 되는 것을 막는다.
        guard seconds.isFinite, abs(seconds) < 9e15 else { return .still }
        return TaptionCatIdleBeat(
            eyeOpenness: eyeOpenness(at: seconds),
            earFlick: earFlick(at: seconds),
            tailTip: sin(2 * .pi * cyclePosition(seconds, period: 2.9))
        )
    }

    private static func eyeOpenness(at seconds: Double) -> Double {
        let t = cyclePosition(seconds, period: 3.6) * 3.6
        return switch t {
        case ..<0.08: 0.45
        case ..<0.20: 0
        case ..<0.30: 0.55
        default: 1
        }
    }

    private static func earFlick(at seconds: Double) -> Double {
        let t = cyclePosition(seconds, period: 5.2) * 5.2
        let flick = t < 0.32 ? sin(2 * .pi * t / 0.32) : 0
        let sway = 0.14 * sin(2 * .pi * cyclePosition(seconds, period: 4.4))
        return min(1, max(-1, flick + sway))
    }

    private static func cyclePosition(
        _ seconds: Double,
        period: Double
    ) -> Double {
        let value = seconds.truncatingRemainder(dividingBy: period) / period
        return value < 0 ? value + 1 : value
    }
}

struct TaptionCatMotionDetails: Equatable, Sendable {
    var tailSwing: Double
    var headTiltDegrees: Double
    /// -1...1. 다리·앞발·소품이 함께 쓰는 연속 값.
    var legSwing: Double
}

struct TaptionCatAnimationPose: Equatable, Sendable {
    var progress: Double
    var facesLeft: Bool
    var phase: Int
    var action: TaptionCatAnimationAction
    var tailSwing: Double
    var headTiltDegrees: Double
    var legSwing: Double = 0
    var idle: TaptionCatIdleBeat = .still

    /// 한 주기 동안 0에서 1까지 부드럽게 차올랐다 내려가는 값.
    var cycleEase: Double {
        let count = TaptionCatAnimationEngine.phaseCount
        let index = ((phase % count) + count) % count
        return (1 - cos(2 * .pi * Double(index) / Double(count))) / 2
    }
}

enum TaptionCatAnimationEngine {
    /// A small, deterministic frame clock keeps the same gait on iPhone,
    /// WidgetKit and watchOS.  TimelineView supplies the actual redraw date.
    static let stepDuration: TimeInterval = 0.12
    /// 모든 동작은 실제 자세가 다른 6장의 스프라이트로 한 주기를 돈다.
    static let phaseCount = 6
    private static let stepCount = 40

    static func pose(
        at date: Date,
        preferredAction: TaptionCatAnimationAction? = nil,
        reducesMotion: Bool = false
    ) -> TaptionCatAnimationPose {
        // 유효하지 않은 날짜가 들어오면 Int64 변환 자체가 런타임 트랩이다.
        let elapsed = date.timeIntervalSinceReferenceDate / stepDuration
        guard elapsed.isFinite,
              elapsed > -9e15,
              elapsed < 9e15 else {
            return TaptionCatAnimationPose(
                progress: 0.5,
                facesLeft: false,
                phase: 0,
                action: .sitting,
                tailSwing: 0,
                headTiltDegrees: 0,
                legSwing: 0,
                idle: .still
            )
        }
        let rawStep = Int64(floor(elapsed))
        let count = Int64(stepCount)
        let step = Int(((rawStep % count) + count) % count)
        let phase = reducesMotion ? 0 : step % phaseCount
        let action = preferredAction ?? .walking
        let moves = action.movesAcrossTrack && !reducesMotion
        let outward = step <= stepCount / 2
        let distance = outward
            ? Double(step) / Double(stepCount / 2)
            : Double(stepCount - step) / Double(stepCount / 2)
        let motion = motionDetails(for: action, phase: phase)
        return TaptionCatAnimationPose(
            progress: moves ? min(1, max(0, distance)) : 0.5,
            facesLeft: moves && !outward,
            phase: phase,
            action: reducesMotion ? .sitting : action,
            tailSwing: reducesMotion ? 0 : motion.tailSwing,
            headTiltDegrees: reducesMotion ? 0 : motion.headTiltDegrees,
            legSwing: reducesMotion ? 0 : motion.legSwing,
            idle: TaptionCatIdleBeat.beat(at: date, reducesMotion: reducesMotion)
        )
    }

    static func pose(
        from action: String,
        progress: Double,
        phase: Int,
        facesLeft: Bool,
        tailSwing: Double,
        headTiltDegrees: Double,
        legSwing: Double = 0,
        idle: TaptionCatIdleBeat = .still
    ) -> TaptionCatAnimationPose {
        TaptionCatAnimationPose(
            progress: min(1, max(0, progress)),
            facesLeft: facesLeft,
            phase: phase,
            action: TaptionCatAnimationAction(rawValue: action) ?? .walking,
            tailSwing: tailSwing,
            headTiltDegrees: headTiltDegrees,
            legSwing: legSwing,
            idle: idle
        )
    }

    static func motionDetails(
        for action: TaptionCatAnimationAction,
        phase: Int
    ) -> TaptionCatMotionDetails {
        let index = ((phase % phaseCount) + phaseCount) % phaseCount
        let angle = 2 * Double.pi * Double(index) / Double(phaseCount)
        let tail = sin(angle)
        let head = -4 * cos(angle)
        let step = sin(angle)
        let quickStep = sin(2 * angle)
        let ease = (1 - cos(angle)) / 2

        return switch action {
        case .walking:
            .init(tailSwing: tail, headTiltDegrees: head, legSwing: step)
        case .running:
            .init(
                tailSwing: -tail,
                headTiltDegrees: head * 1.45,
                legSwing: quickStep
            )
        case .sitting:
            .init(
                tailSwing: tail * 0.55,
                headTiltDegrees: head * 1.25,
                legSwing: step * 0.2
            )
        case .grooming:
            .init(
                tailSwing: tail * 0.38,
                headTiltDegrees: -2.5 - 8.5 * cos(angle),
                legSwing: step
            )
        case .startled:
            .init(tailSwing: 1, headTiltDegrees: -7, legSwing: 0)
        case .sleeping:
            .init(
                tailSwing: tail * 0.16,
                headTiltDegrees: 7,
                legSwing: step * 0.35
            )
        case .eating:
            .init(
                tailSwing: tail * 0.28,
                headTiltDegrees: 12,
                legSwing: quickStep * 0.7
            )
        case .ballPlay:
            .init(
                tailSwing: -tail * 0.85,
                headTiltDegrees: head * 1.6,
                legSwing: quickStep
            )
        case .fishingPlay:
            .init(
                tailSwing: tail * 0.72,
                headTiltDegrees: 4.5 * sin(angle) + 4.5 * sin(2 * angle),
                legSwing: step
            )
        case .stretching:
            .init(
                tailSwing: 0.4 + 0.4 * tail,
                headTiltDegrees: 3 + 4 * ease,
                legSwing: step * 0.4
            )
        case .kneading:
            .init(
                tailSwing: tail * 0.3,
                headTiltDegrees: 4 + 2 * cos(angle),
                legSwing: quickStep
            )
        case .yawning:
            .init(
                tailSwing: tail * 0.35,
                headTiltDegrees: -3 - 9 * ease,
                legSwing: step * 0.2
            )
        }
    }
}

struct TaptionCatAnimationView: View {
    let style: String
    let pose: TaptionCatAnimationPose
    let reducesMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            // 컴플리케이션 초기 레이아웃에서 크기가 0이나 NaN으로 들어올 수
            // 있다. 그대로 쓰면 프레임과 오프셋이 NaN이 된다.
            let width = proxy.size.width.isFinite
                ? max(0, proxy.size.width)
                : 52
            let catWidth = min(52, width)
            let available = max(0, width - catWidth)
            let progress = pose.progress.isFinite
                ? min(1, max(0, pose.progress))
                : 0.5
            let swing = pose.legSwing.isFinite
                ? min(1, max(-1, pose.legSwing))
                : 0
            let bounce: CGFloat = reducesMotion
                ? 0
                : (pose.action == .running
                    ? CGFloat(1 - 4 * abs(swing))
                    : pose.action.movesAcrossTrack
                        ? CGFloat(-1.5 * abs(swing))
                        : 0)
            TaptionCatFigure(
                style: style,
                pose: pose,
                reducesMotion: reducesMotion
            )
            .frame(width: catWidth, height: 32)
            .scaleEffect(x: pose.facesLeft ? -1 : 1, y: 1)
            .offset(x: available * progress, y: bounce)
        }
        .accessibilityLabel("고양이 애니메이션")
    }
}

private struct TaptionCatFigure: View {
    let style: String
    let pose: TaptionCatAnimationPose
    let reducesMotion: Bool

    var body: some View {
        TaptionCatAtlasIllustration(
            style: style,
            pose: pose,
            reducesMotion: reducesMotion
        )
    }
}

private struct TaptionCatAtlasIllustration: View {
    let style: String
    let pose: TaptionCatAnimationPose
    let reducesMotion: Bool

    private var action: TaptionCatAnimationAction { pose.action }

    var body: some View {
        TaptionCatAtlasSprite(
            style: style,
            action: action,
            frame: reducesMotion ? 0 : pose.phase
        )
            .frame(width: 52, height: 32)
    }
}

/// 지도 배지에서 프레임을 직접 골라 쓰기 위해 모듈 내부로 공개한다.
struct TaptionCatAtlasSprite: View {
    let style: String
    let action: TaptionCatAnimationAction
    let frame: Int

    private var actionIndex: Int {
        switch action {
        case .walking: 0
        case .running: 1
        case .sitting: 2
        case .sleeping: 3
        case .grooming: 4
        case .eating: 5
        case .startled: 6
        case .ballPlay: 7
        case .fishingPlay: 8
        case .stretching: 9
        case .kneading: 10
        case .yawning: 11
        }
    }

    private var assetName: String {
        switch style.lowercased() {
        case "white", "흰색 고양이": "TaptionCatAtlasWhite"
        case "mackerel", "고등어 고양이": "TaptionCatAtlasMackerel"
        case "black", "검정 고양이": "TaptionCatAtlasBlack"
        case "gray", "회색 고양이": "TaptionCatAtlasGray"
        case "cheese", "치즈 고양이": "TaptionCatAtlasCheese"
        case "cow", "젖소무늬 고양이": "TaptionCatAtlasCow"
        default: "TaptionCatAtlasCalico"
        }
    }

    var body: some View {
        let frameIndex = ((frame % 6) + 6) % 6
        Image(assetName)
            .resizable()
            .interpolation(.high)
            .frame(width: 312, height: 384)
            .offset(
                x: -CGFloat(frameIndex) * 52,
                y: -CGFloat(actionIndex) * 32
            )
            .frame(width: 52, height: 32, alignment: .topLeading)
            .clipped()
            .id("\(assetName)-\(actionIndex)-\(frameIndex)")
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}
