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
    static let stepDuration: TimeInterval = 0.08
    /// 꼬리·머리·다리를 한 주기에 8번 표본화한다. 4번이던 시절보다
    /// 중간값이 두 배로 늘어 움직임이 덜 끊긴다.
    static let phaseCount = 8
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

    private var palette: TaptionCatPalette { TaptionCatPalette(style: style) }
    private var action: TaptionCatAnimationAction { pose.action }
    private var idle: TaptionCatIdleBeat {
        reducesMotion ? .still : pose.idle
    }
    private var legSwing: Double {
        guard !reducesMotion, pose.legSwing.isFinite else { return 0 }
        return min(1, max(-1, pose.legSwing))
    }

    var body: some View {
        ZStack {
            accessory
            HStack(spacing: -5) {
                tail
                Ellipse()
                    .fill(palette.base)
                    .frame(width: bodyWidth, height: bodyHeight)
                    .overlay { Ellipse().stroke(palette.outline, lineWidth: 1) }
                    .overlay(alignment: .bottom) { legs }
                    .overlay(alignment: .trailing) { head }
            }
            .scaleEffect(
                x: 1,
                y: reducesMotion ? 1 : bodyScaleY,
                anchor: .bottom
            )
            .rotationEffect(.degrees(bodyTiltDegrees))
        }
        .frame(width: 52, height: 32)
    }

    private var bodyWidth: CGFloat {
        switch action {
        case _ where action.sitsUpright: 25
        case .sleeping: 34
        case .stretching: 37
        case .startled: 26
        default: 31
        }
    }

    private var bodyHeight: CGFloat {
        switch action {
        case _ where action.sitsUpright: 24
        case .sleeping: 14
        case .stretching: 13
        case .startled: 20
        default: 17
        }
    }

    private var bodyTiltDegrees: Double {
        switch action {
        case .sleeping: 4
        // 기지개는 앞을 낮추고 엉덩이를 든다.
        case .stretching: 16 + 6 * pose.cycleEase
        default: 0
        }
    }

    private var bodyScaleY: CGFloat {
        switch action {
        // 자는 동안에도 숨은 쉰다.
        case .sleeping: 1 + CGFloat(legSwing) * 0.03
        case _ where action.movesAcrossTrack:
            1.04 - 0.10 * CGFloat(abs(legSwing))
        default: 1
        }
    }

    @ViewBuilder
    private var tail: some View {
        if action == .startled {
            Capsule()
                .fill(palette.base)
                .overlay { Capsule().stroke(palette.outline, lineWidth: 1) }
                .frame(width: 9, height: 30)
                .rotationEffect(.degrees(-18))
                .offset(x: 1, y: -2)
        } else {
            VStack(spacing: -1) {
                Capsule()
                    .fill(palette.outline)
                    .frame(width: 3, height: 7)
                    .rotationEffect(
                        .degrees(idle.tailTip * 16),
                        anchor: .bottom
                    )
                Capsule()
                    .fill(palette.outline)
                    .frame(width: 3, height: 16)
            }
            .rotationEffect(.degrees(tailBaseDegrees))
            .offset(x: 4, y: action == .sleeping ? 4 : -2)
        }
    }

    private var tailBaseDegrees: Double {
        // 기지개에서는 꼬리가 위로 곧게 선다. 몸통 기울기만큼 되돌린다.
        action == .stretching
            ? -14 - bodyTiltDegrees + pose.tailSwing * 8
            : -54 + pose.tailSwing * 12
    }

    private var head: some View {
        ZStack {
            ears
            Circle()
                .fill(palette.base)
                .overlay { Circle().stroke(palette.outline, lineWidth: 1) }
            HStack(spacing: 5) {
                eye
                eye
            }
            .offset(y: -1)
            whiskers
            Circle()
                .fill(Color(red: 1, green: 0.58, blue: 0.65))
                .frame(width: 2.5, height: 2)
                .offset(y: 3)
            if action == .yawning {
                // 이 크기에서 가장 크게 읽히는 부위가 머리다. 입을 벌린다.
                Ellipse()
                    .fill(palette.outline)
                    .frame(
                        width: 4 + 3 * yawn,
                        height: 0.8 + 5.4 * yawn
                    )
                    .offset(y: 5 + 1.6 * yawn)
            }
            if action == .grooming {
                Capsule()
                    .fill(palette.base)
                    .overlay { Capsule().stroke(palette.outline, lineWidth: 0.8) }
                    .frame(width: 5, height: 13)
                    .rotationEffect(.degrees(-10 + legSwing * 18))
                    .offset(x: -7, y: 6)
            }
        }
        .frame(width: 18, height: 18)
        .rotationEffect(
            .degrees(reducesMotion ? 0 : pose.headTiltDegrees),
            anchor: .bottom
        )
        .offset(x: headOffset.x, y: headOffset.y)
    }

    private var headOffset: (x: CGFloat, y: CGFloat) {
        switch action {
        case .sleeping: (1, 4)
        // 귀가 몸통에 묻히지 않도록 머리를 조금 띄운다.
        case .stretching: (9, -3)
        // 밥그릇 쪽으로 고개를 내렸다 올린다.
        case .eating: (7, -3 + CGFloat(legSwing) * 1.5)
        default: (7, -4)
        }
    }

    /// 0...1. 하품이 가장 크게 벌어진 순간이 1이다.
    private var yawn: CGFloat {
        guard action == .yawning, !reducesMotion else { return 0 }
        return CGFloat(pose.cycleEase)
    }

    private var ears: some View {
        HStack(spacing: 7) {
            Triangle()
                .fill(palette.base)
                .rotationEffect(
                    .degrees(idle.earFlick * -4 - Double(yawn) * 7),
                    anchor: .bottom
                )
            Triangle()
                .fill(palette.base)
                .rotationEffect(
                    .degrees(idle.earFlick * 13 + Double(yawn) * 7),
                    anchor: .bottom
                )
        }
        .frame(width: 18, height: 9)
        .offset(y: -7)
    }

    /// 0이면 감은 눈, 1이면 뜬 눈.
    private var eyeOpenness: Double {
        guard action != .sleeping else { return 0 }
        return switch action {
        // 꾹꾹이는 만족스러워서 실눈을 뜬다.
        case .kneading: min(0.4, idle.eyeOpenness)
        // 하품이 깊어질수록 눈이 감긴다.
        case .yawning: min(1 - Double(yawn), idle.eyeOpenness)
        default: idle.eyeOpenness
        }
    }

    private var eye: some View {
        Capsule()
            .fill(palette.eye)
            .frame(
                width: 2 + (1 - eyeOpenness) * 2,
                height: 1 + eyeOpenness * 1.5
            )
    }

    private var whiskers: some View {
        VStack(spacing: 2) {
            Capsule()
                .fill(palette.outline.opacity(0.65))
                .frame(width: 9, height: 0.7)
                .rotationEffect(.degrees(-8))
            Capsule()
                .fill(palette.outline.opacity(0.65))
                .frame(width: 9, height: 0.7)
                .rotationEffect(.degrees(8))
        }
        .offset(x: 7, y: 3)
        .opacity(action == .sleeping ? 0.35 : 0.9)
    }

    @ViewBuilder
    private var legs: some View {
        if action != .sleeping {
            HStack(spacing: action.sitsUpright ? 5 : 4) {
                ForEach(0..<4, id: \.self) { index in
                    leg(index: index)
                }
            }
            .offset(y: legGroupOffsetY)
        }
    }

    /// 52×32 프레임을 벗어나면 발이 잘려 동작이 읽히지 않는다.
    private var legGroupOffsetY: CGFloat {
        switch action {
        case .kneading: 2
        case .stretching: 4
        case _ where action.sitsUpright: 8
        default: 6
        }
    }

    private func leg(index: Int) -> some View {
        VStack(spacing: -1) {
            Capsule()
                .fill(palette.outline.opacity(index.isMultiple(of: 2) ? 0.72 : 1))
                .frame(width: 2.5, height: legHeight(index: index))
            Capsule()
                .fill(palette.outline)
                .frame(
                    width: action == .kneading && index >= 2 ? 5.5 : 4.5,
                    height: 2
                )
        }
        .rotationEffect(.degrees(legRotation(index: index)))
        .offset(y: legOffsetY(index: index))
    }

    private func legHeight(index: Int) -> CGFloat {
        switch action {
        case .stretching: index >= 2 ? 8 : 10
        // 식빵 자세라 발이 짧게 접혀 있다.
        case .kneading: 6
        case _ where action.sitsUpright: 13
        default: 10
        }
    }

    private func legRotation(index: Int) -> Double {
        let swing = legSwing * 18
        switch action {
        case .walking, .running:
            return index == 0 || index == 3 ? swing : -swing
        // 앞다리를 앞으로 뻗고 뒷다리로 버틴다.
        case .stretching:
            return index >= 2 ? -26 - 10 * pose.cycleEase : 8
        case .kneading:
            return index >= 2 ? -4 : 4
        default:
            return index.isMultiple(of: 2) ? 4 : -4
        }
    }

    private func legOffsetY(index: Int) -> CGFloat {
        switch action {
        case .walking, .running:
            return index.isMultiple(of: 2)
                ? CGFloat(-legSwing * 1.5)
                : CGFloat(legSwing * 1.5)
        // 앞발 두 개가 번갈아 눌린다.
        case .kneading:
            guard index >= 2 else { return 0 }
            return index == 2
                ? CGFloat(-2.8 * legSwing)
                : CGFloat(2.8 * legSwing)
        default:
            return 0
        }
    }

    @ViewBuilder
    private var accessory: some View {
        switch action {
        case .sleeping:
            Text(pose.phase < TaptionCatAnimationEngine.phaseCount / 2 ? "z" : "zZ")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 0.37, green: 0.40, blue: 0.48))
                .offset(x: 22, y: -15)
        case .eating:
            Capsule()
                .fill(Color(red: 0.89, green: 0.46, blue: 0.36))
                .frame(width: 20, height: 7)
                .overlay {
                    HStack(spacing: 1) {
                        Circle().fill(.brown).frame(width: 3, height: 3)
                        Circle().fill(.brown).frame(width: 3, height: 3)
                    }
                    .offset(y: -3)
                }
                .offset(x: 21, y: 16)
        case .startled:
            Image(systemName: "exclamationmark")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(.red)
                .offset(x: 21, y: -17)
        case .ballPlay:
            Circle()
                .fill(Color(red: 0.38, green: 0.61, blue: 0.88))
                .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 1) }
                .frame(width: 11, height: 11)
                .offset(x: 19.5 + CGFloat(legSwing) * 3.5,
                        y: 11.5 + CGFloat(legSwing) * 3.5)
        case .fishingPlay:
            Path { path in
                path.move(to: CGPoint(x: 16, y: 4))
                path.addLine(to: CGPoint(x: 45, y: 29))
            }
            .stroke(.gray, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "fish.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.blue)
                    .offset(x: 2, y: 3)
            }
        case .kneading:
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(palette.outline.opacity(0.24))
                .frame(width: 27, height: 5)
                .offset(x: 5, y: 12)
        default:
            EmptyView()
        }
    }
}

private struct TaptionCatPalette {
    let base: Color
    let patch: Color
    let outline: Color
    let eye: Color

    init(style: String) {
        let value = style.lowercased()
        switch value {
        case "white", "흰색 고양이":
            base = Color(white: 0.98); patch = Color(white: 0.86)
            outline = Color(white: 0.62); eye = .blue
        case "calico", "삼색 고양이":
            base = Color(red: 0.97, green: 0.95, blue: 0.91)
            patch = Color(red: 0.86, green: 0.47, blue: 0.20)
            outline = Color(red: 0.35, green: 0.28, blue: 0.22); eye = .green
        case "mackerel", "고등어 고양이":
            base = Color(red: 0.58, green: 0.60, blue: 0.62)
            patch = Color(red: 0.27, green: 0.29, blue: 0.31)
            outline = Color(red: 0.18, green: 0.19, blue: 0.20); eye = .yellow
        case "black", "검정 고양이":
            base = Color(white: 0.12); patch = Color(white: 0.28)
            outline = Color(white: 0.50); eye = .yellow
        case "gray", "회색 고양이":
            base = Color(white: 0.58); patch = Color(white: 0.43)
            outline = Color(white: 0.28); eye = .green
        case "cheese", "치즈 고양이":
            base = Color(red: 0.92, green: 0.63, blue: 0.28)
            patch = Color(red: 0.72, green: 0.39, blue: 0.12)
            outline = Color(red: 0.48, green: 0.28, blue: 0.12); eye = .green
        case "cow", "젖소무늬 고양이":
            base = Color(white: 0.98); patch = Color(white: 0.10)
            outline = Color(white: 0.48); eye = .yellow
        default:
            base = Color(red: 0.96, green: 0.93, blue: 0.86)
            patch = Color(red: 0.86, green: 0.47, blue: 0.20)
            outline = Color(red: 0.35, green: 0.28, blue: 0.22); eye = .green
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
