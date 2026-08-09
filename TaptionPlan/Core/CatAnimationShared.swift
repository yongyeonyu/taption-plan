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

private struct TaptionCatAtlasSprite: View {
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

private struct ReferenceCatIllustration: View {
    let palette: TaptionCatPalette
    let pose: TaptionCatAnimationPose
    let reducesMotion: Bool
    let legSwing: Double

    private var action: TaptionCatAnimationAction { pose.action }

    var body: some View {
        ZStack {
            Image("TaptionReferenceCat")
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 32)
                .clipped()
                .offset(actionOffset)
                .scaleEffect(x: actionScaleX, y: actionScaleY, anchor: .bottom)
                .rotationEffect(actionTilt, anchor: .bottom)
                .opacity(0.99)
            postureOverlay
            overlay
        }
        .frame(width: 52, height: 32)
    }

    private var actionOffset: CGSize {
        guard !reducesMotion else { return .zero }
        let swing = CGFloat(legSwing)
        switch action {
        case .walking: return CGSize(width: swing * 1.2, height: -abs(swing) * 0.8)
        case .running: return CGSize(width: swing * 1.8, height: -abs(swing) * 2.0)
        case .sitting: return CGSize(width: 1, height: 2)
        case .sleeping: return CGSize(width: 0, height: 2)
        case .grooming: return CGSize(width: swing * 1.0, height: abs(swing) * 0.8)
        case .eating: return CGSize(width: -3, height: 4 + swing * 1.2)
        case .ballPlay, .fishingPlay: return CGSize(width: swing * 1.1, height: 2 - abs(swing) * 1.1)
        case .stretching: return CGSize(width: swing * 0.5, height: 1)
        case .kneading: return CGSize(width: 0, height: 2)
        case .startled: return CGSize(width: swing * 0.8, height: -1)
        default: return .zero
        }
    }

    private var actionScaleX: CGFloat {
        guard !reducesMotion else { return 1 }
        switch action {
        case .sitting: return 0.80
        case .sleeping: return 1.12
        case .grooming: return 0.88
        case .eating: return 0.88
        case .ballPlay, .fishingPlay: return 0.86
        case .stretching: return 1.24
        case .kneading: return 0.90
        case .yawning: return 0.90
        case .startled: return 1.10
        case .running: return 1 + abs(CGFloat(legSwing)) * 0.06
        default: return 1
        }
    }

    private var actionScaleY: CGFloat {
        guard !reducesMotion else { return action == .sleeping ? 0.95 : 1 }
        switch action {
        case .sitting: return 0.78
        case .sleeping: return 0.62 + CGFloat(pose.cycleEase) * 0.08
        case .grooming: return 0.94
        case .eating: return 0.76
        case .ballPlay, .fishingPlay: return 0.80
        case .stretching: return 0.68
        case .kneading: return 0.64
        case .yawning: return 0.88
        case .running: return 0.90 + abs(CGFloat(legSwing)) * 0.10
        case .startled: return 1.10
        default: return 1
        }
    }

    private var actionTilt: Angle {
        guard !reducesMotion else { return .zero }
        let swing = legSwing
        switch action {
        case .walking: return .degrees(swing * 5)
        case .running: return .degrees(swing * 10)
        case .grooming: return .degrees(-10 + swing * 5)
        case .eating: return .degrees(-17 + swing * 3)
        case .stretching: return .degrees(18 + pose.cycleEase * 10)
        case .sleeping: return .degrees(8)
        case .yawning: return .degrees(-10 - pose.cycleEase * 5)
        case .sitting: return .degrees(0)
        case .startled: return .degrees(swing * 3)
        default: return .zero
        }
    }

    @ViewBuilder
    private var postureOverlay: some View {
        switch action {
        case .walking, .running:
            movingPaws
        case .sitting:
            sittingHindquarter
        case .eating:
            loweredHead
        case .ballPlay, .fishingPlay:
            raisedPlayPaw
        case .stretching:
            stretchPaws
        case .kneading:
            kneadingCushion
        default:
            EmptyView()
        }
    }

    private var movingPaws: some View {
        HStack(spacing: action == .running ? 5 : 7) {
            Capsule()
                .fill(.white)
                .overlay { Capsule().stroke(palette.outline, lineWidth: 0.8) }
                .frame(width: 2.8, height: action == .running ? 6 : 5.5)
                .rotationEffect(.degrees(-18 * legSwing), anchor: .top)
            Capsule()
                .fill(.white)
                .overlay { Capsule().stroke(palette.outline, lineWidth: 0.8) }
                .frame(width: 2.8, height: action == .running ? 6 : 5.5)
                .rotationEffect(.degrees(18 * legSwing), anchor: .top)
        }
        .offset(x: -1, y: 10)
        .opacity(0.92)
    }

    private var sittingHindquarter: some View {
        ZStack {
            Ellipse()
                .fill(.white)
                .overlay { Ellipse().stroke(palette.outline, lineWidth: 0.8) }
                .frame(width: 16, height: 9)
            Ellipse()
                .fill(palette.patch)
                .frame(width: 8, height: 6)
                .offset(x: 3, y: -1)
            Capsule()
                .fill(.white)
                .overlay { Capsule().stroke(palette.outline, lineWidth: 0.8) }
                .frame(width: 3.5, height: 6)
                .offset(x: -6, y: 5)
        }
        .offset(x: 11, y: 8)
    }

    private var loweredHead: some View {
        ZStack {
            Capsule()
                .fill(.white)
                .overlay { Capsule().stroke(palette.outline, lineWidth: 0.75) }
                .frame(width: 12, height: 4)
            Circle()
                .fill(Color(red: 0.98, green: 0.43, blue: 0.52))
                .frame(width: 1.7, height: 1.7)
                .offset(x: 5, y: 1)
        }
        .rotationEffect(.degrees(-10))
        .offset(x: -16, y: 8)
    }

    private var raisedPlayPaw: some View {
        Capsule()
            .fill(.white)
            .overlay { Capsule().stroke(palette.outline, lineWidth: 0.8) }
            .frame(width: 3.5, height: 8)
            .rotationEffect(.degrees(-35 + legSwing * 20), anchor: .bottom)
            .offset(x: -7, y: 5)
    }

    private var stretchPaws: some View {
        HStack(spacing: 3) {
            Capsule().fill(.white).overlay { Capsule().stroke(palette.outline, lineWidth: 0.8) }
                .frame(width: 4, height: 9)
            Capsule().fill(.white).overlay { Capsule().stroke(palette.outline, lineWidth: 0.8) }
                .frame(width: 4, height: 9)
        }
        .rotationEffect(.degrees(42))
        .offset(x: -13, y: 8)
    }

    private var kneadingCushion: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color(red: 0.72, green: 0.55, blue: 0.38).opacity(0.85))
            .frame(width: 18, height: 4)
            .offset(x: -3, y: 12)
    }

    @ViewBuilder
    private var overlay: some View {
        switch action {
        case .startled:
            puffedTail
            Text("!")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(.red)
                .offset(x: 20, y: -14)
        case .eating:
            bowl
        case .grooming:
            groomingPaw
        case .sleeping:
            Text(pose.phase < TaptionCatAnimationEngine.phaseCount / 2 ? "z" : "zZ")
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 0.37, green: 0.40, blue: 0.48))
                .offset(x: 21, y: -14)
        case .yawning:
            yawnMouth
        case .kneading:
            kneadingPaws
        case .ballPlay:
            Circle()
                .fill(Color(red: 0.38, green: 0.61, blue: 0.88))
                .frame(width: 8, height: 8)
                .offset(x: 21 + CGFloat(legSwing) * 3, y: 10)
        case .fishingPlay:
            fishingLine
        default:
            EmptyView()
        }
    }

    private var bowl: some View {
        ZStack {
            Ellipse()
                .fill(Color(red: 0.93, green: 0.46, blue: 0.32))
                .frame(width: 11, height: 5)
                .overlay { Ellipse().stroke(Color(red: 0.52, green: 0.20, blue: 0.15), lineWidth: 0.7) }
            Ellipse()
                .fill(Color(red: 0.63, green: 0.26, blue: 0.16))
                .frame(width: 8, height: 2.2)
            HStack(spacing: 1) {
                Circle().fill(Color(red: 0.36, green: 0.20, blue: 0.10)).frame(width: 1.7)
                Circle().fill(Color(red: 0.36, green: 0.20, blue: 0.10)).frame(width: 1.7)
                Circle().fill(Color(red: 0.36, green: 0.20, blue: 0.10)).frame(width: 1.7)
            }
            .offset(y: -1)
        }
        .offset(x: -18, y: 11)
    }

    private var groomingPaw: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(.white)
            .overlay { RoundedRectangle(cornerRadius: 2).stroke(palette.outline, lineWidth: 0.8) }
            .frame(width: 4.5, height: 11)
            .rotationEffect(.degrees(-24 + legSwing * 10), anchor: .bottom)
            .offset(x: -11, y: 2)
    }

    private var yawnMouth: some View {
        ZStack {
            Ellipse()
                .fill(palette.outline)
                .frame(width: 5.5, height: 4.8 + CGFloat(pose.cycleEase) * 2)
            Capsule()
                .fill(Color(red: 0.98, green: 0.43, blue: 0.52))
                .frame(width: 3.1, height: 1.8)
                .offset(y: 1.1)
        }
        .offset(x: -12, y: 4)
    }

    private var kneadingPaws: some View {
        HStack(spacing: 2) {
            Capsule().fill(palette.shadow).frame(width: 5.5, height: 2.4)
            Capsule().fill(palette.shadow).frame(width: 5.5, height: 2.4)
        }
        .rotationEffect(.degrees(legSwing * 5))
        .offset(x: -4, y: 12)
    }

    private var puffedTail: some View {
        ZStack {
            RaccoonTailShape()
                .fill(.white)
                .overlay { RaccoonTailShape().stroke(palette.outline, lineWidth: 1.3) }
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(palette.patch)
                    .frame(width: 7, height: 2.1)
                    .rotationEffect(.degrees(-18 + Double(index) * 18))
                    .offset(x: 4, y: CGFloat(index - 1) * 5)
            }
        }
        .frame(width: 19, height: 25)
        .scaleEffect(1.05)
        .rotationEffect(.degrees(legSwing * 5), anchor: .bottom)
        .offset(x: 17, y: 0)
    }

    private var fishingLine: some View {
        Path { path in
            path.move(to: CGPoint(x: 16, y: 1))
            path.addLine(to: CGPoint(x: 43, y: 25))
        }
        .stroke(.gray, style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "fish.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.blue)
        }
    }
}

private struct RaccoonTailShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.12, y: rect.height * 0.82))
        path.addCurve(
            to: CGPoint(x: rect.width * 0.62, y: rect.height * 0.63),
            control1: CGPoint(x: rect.width * 0.18, y: rect.height * 0.65),
            control2: CGPoint(x: rect.width * 0.42, y: rect.height * 0.92)
        )
        path.addCurve(
            to: CGPoint(x: rect.width * 0.63, y: rect.height * 0.20),
            control1: CGPoint(x: rect.width * 0.88, y: rect.height * 0.48),
            control2: CGPoint(x: rect.width * 0.91, y: rect.height * 0.06)
        )
        path.addCurve(
            to: CGPoint(x: rect.width * 0.35, y: rect.height * 0.20),
            control1: CGPoint(x: rect.width * 0.55, y: rect.height * 0.04),
            control2: CGPoint(x: rect.width * 0.42, y: rect.height * 0.07)
        )
        path.addCurve(
            to: CGPoint(x: rect.width * 0.12, y: rect.height * 0.82),
            control1: CGPoint(x: rect.width * 0.24, y: rect.height * 0.38),
            control2: CGPoint(x: rect.width * 0.02, y: rect.height * 0.58)
        )
        path.closeSubpath()
        return path
    }
}

private struct TaptionCatPalette {
    enum Coat {
        case white, calico, tabby, black, gray, cheese, cow
    }

    let coat: Coat
    let base: Color
    let highlight: Color
    let shadow: Color
    let patch: Color
    let secondPatch: Color
    let outline: Color
    let eye: Color
    let innerEar: Color
    let nose: Color

    var fur: LinearGradient {
        LinearGradient(
            colors: [highlight, base],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    init(style: String) {
        let value = style.lowercased()
        switch value {
        case "white", "흰색 고양이":
            coat = .white
            base = Color(white: 0.97); highlight = .white
            shadow = Color(white: 0.82); patch = Color(white: 0.88)
            secondPatch = Color(white: 0.75)
            outline = Color(white: 0.48); eye = Color(red: 0.28, green: 0.66, blue: 0.92)
        case "calico", "삼색 고양이":
            coat = .calico
            base = Color(red: 0.97, green: 0.95, blue: 0.91)
            highlight = .white; shadow = Color(red: 0.82, green: 0.78, blue: 0.71)
            patch = Color(red: 0.96, green: 0.49, blue: 0.13)
            secondPatch = Color(red: 0.20, green: 0.15, blue: 0.12)
            outline = Color(red: 0.31, green: 0.22, blue: 0.16); eye = .green
        case "mackerel", "고등어 고양이":
            coat = .tabby
            base = Color(red: 0.58, green: 0.60, blue: 0.62)
            highlight = Color(red: 0.74, green: 0.75, blue: 0.76)
            shadow = Color(red: 0.40, green: 0.42, blue: 0.44)
            patch = Color(red: 0.27, green: 0.29, blue: 0.31)
            secondPatch = Color(red: 0.77, green: 0.73, blue: 0.66)
            outline = Color(red: 0.18, green: 0.19, blue: 0.20); eye = .yellow
        case "black", "검정 고양이":
            coat = .black
            base = Color(white: 0.10); highlight = Color(white: 0.26)
            shadow = Color(white: 0.035); patch = Color(white: 0.30)
            secondPatch = Color(white: 0.42)
            outline = Color(white: 0.06); eye = Color(red: 0.95, green: 0.78, blue: 0.22)
        case "gray", "회색 고양이":
            coat = .gray
            base = Color(white: 0.58); highlight = Color(white: 0.74)
            shadow = Color(white: 0.40); patch = Color(white: 0.39)
            secondPatch = Color(white: 0.82)
            outline = Color(white: 0.28); eye = .green
        case "cheese", "치즈 고양이":
            coat = .cheese
            base = Color(red: 0.92, green: 0.63, blue: 0.28)
            highlight = Color(red: 1.00, green: 0.78, blue: 0.43)
            shadow = Color(red: 0.71, green: 0.39, blue: 0.12)
            patch = Color(red: 0.72, green: 0.39, blue: 0.12)
            secondPatch = Color(red: 1.00, green: 0.88, blue: 0.67)
            outline = Color(red: 0.48, green: 0.28, blue: 0.12); eye = .green
        case "cow", "젖소무늬 고양이":
            coat = .cow
            base = Color(white: 0.98); highlight = .white
            shadow = Color(white: 0.82); patch = Color(white: 0.08)
            secondPatch = Color(white: 0.22)
            outline = Color(white: 0.36); eye = Color(red: 0.92, green: 0.73, blue: 0.20)
        default:
            coat = .calico
            base = Color(red: 0.96, green: 0.93, blue: 0.86)
            highlight = .white; shadow = Color(red: 0.82, green: 0.77, blue: 0.68)
            patch = Color(red: 0.96, green: 0.49, blue: 0.13)
            secondPatch = Color(red: 0.20, green: 0.15, blue: 0.12)
            outline = Color(red: 0.31, green: 0.22, blue: 0.16); eye = .green
        }
        innerEar = Color(red: 0.92, green: 0.57, blue: 0.60)
        nose = Color(red: 0.62, green: 0.31, blue: 0.34)
    }
}
