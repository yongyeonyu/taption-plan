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
            Ellipse()
                .fill(.black.opacity(0.11))
                .frame(width: bodyWidth + 16, height: 4.8)
                .blur(radius: 0.55)
                .offset(x: 5, y: 14)
            accessory
            HStack(spacing: -6) {
                tail
                bodyShape
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

    private var bodyShape: some View {
        Ellipse()
            .fill(palette.fur)
            .frame(width: bodyWidth, height: bodyHeight)
            .overlay { bodyMarkings }
            .overlay {
                Ellipse()
                    .stroke(palette.outline.opacity(0.94), lineWidth: 1.45)
            }
            .overlay(alignment: .topLeading) {
                Capsule()
                    .fill(.white.opacity(palette.coat == .black ? 0.14 : 0.42))
                    .frame(width: bodyWidth * 0.44, height: 2)
                    .offset(x: bodyWidth * 0.18, y: bodyHeight * 0.14)
            }
            .overlay(alignment: .bottom) { legs }
            .overlay(alignment: .trailing) { head }
    }

    @ViewBuilder
    private var bodyMarkings: some View {
        ZStack {
            switch palette.coat {
            case .white:
                Ellipse()
                    .fill(palette.patch.opacity(0.45))
                    .frame(width: bodyWidth * 0.42, height: bodyHeight * 0.52)
                    .offset(x: -bodyWidth * 0.20, y: bodyHeight * 0.20)
            case .calico:
                Ellipse()
                    .fill(palette.patch)
                    .frame(width: bodyWidth * 0.42, height: bodyHeight * 0.72)
                    .rotationEffect(.degrees(-16))
                    .offset(x: -bodyWidth * 0.18, y: -1)
                Ellipse()
                    .fill(palette.secondPatch)
                    .frame(width: bodyWidth * 0.29, height: bodyHeight * 0.56)
                    .rotationEffect(.degrees(22))
                    .offset(x: bodyWidth * 0.27, y: 2)
            case .tabby, .gray, .cheese:
                HStack(spacing: 2.7) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule()
                            .fill(palette.patch.opacity(0.88 - Double(index) * 0.08))
                            .frame(width: 2.2, height: bodyHeight * 0.62)
                            .rotationEffect(.degrees(index.isMultiple(of: 2) ? -15 : 13))
                    }
                }
                .offset(y: -bodyHeight * 0.17)
                Ellipse()
                    .fill(palette.secondPatch.opacity(0.75))
                    .frame(width: bodyWidth * 0.36, height: bodyHeight * 0.31)
                    .offset(x: bodyWidth * 0.20, y: bodyHeight * 0.30)
            case .black:
                Ellipse()
                    .fill(palette.patch.opacity(0.40))
                    .frame(width: bodyWidth * 0.68, height: bodyHeight * 0.38)
                    .offset(x: -1, y: -bodyHeight * 0.21)
            case .cow:
                Ellipse()
                    .fill(palette.patch)
                    .frame(width: bodyWidth * 0.38, height: bodyHeight * 0.66)
                    .rotationEffect(.degrees(18))
                    .offset(x: -bodyWidth * 0.22, y: 1)
                Circle()
                    .fill(palette.patch)
                    .frame(width: bodyHeight * 0.48)
                    .offset(x: bodyWidth * 0.29, y: -bodyHeight * 0.18)
            }
        }
        .frame(width: bodyWidth, height: bodyHeight)
        .clipShape(Ellipse())
    }

    private var bodyWidth: CGFloat {
        switch action {
        case _ where action.sitsUpright: 28
        case .sleeping: 37
        case .stretching: 40
        case .startled: 29
        default: 35
        }
    }

    private var bodyHeight: CGFloat {
        switch action {
        case _ where action.sitsUpright: 25
        case .sleeping: 15
        case .stretching: 14
        case .startled: 22
        default: 19
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
            ZStack {
                FluffyTailShape()
                    .fill(palette.fur)
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule()
                            .fill(palette.patch.opacity(0.78))
                            .frame(width: 7, height: 2)
                    }
                }
                .opacity(usesTailBands ? 1 : 0)
                FluffyTailShape()
                    .stroke(palette.outline.opacity(0.85), lineWidth: 0.8)
            }
                .frame(width: 13, height: 31)
                .rotationEffect(.degrees(-18))
                .offset(x: 1, y: -2)
        } else {
            ZStack {
                CatTailCurve()
                    .stroke(
                        palette.outline.opacity(0.92),
                        style: StrokeStyle(lineWidth: 7.2, lineCap: .round)
                    )
                CatTailCurve()
                    .stroke(
                        palette.fur,
                        style: StrokeStyle(lineWidth: 4.9, lineCap: .round)
                    )
                if usesTailBands {
                    CatTailCurve()
                        .trim(from: 0.05, to: 0.26)
                        .stroke(
                            palette.patch,
                            style: StrokeStyle(lineWidth: 4.5, lineCap: .butt)
                        )
                    CatTailCurve()
                        .trim(from: 0.42, to: 0.56)
                        .stroke(
                            palette.patch.opacity(0.9),
                            style: StrokeStyle(lineWidth: 4.5, lineCap: .butt)
                        )
                } else if palette.coat == .calico || palette.coat == .cow {
                    CatTailCurve()
                        .trim(from: 0, to: 0.34)
                        .stroke(
                            palette.secondPatch,
                            style: StrokeStyle(lineWidth: 4.5, lineCap: .round)
                        )
                }
            }
            .frame(width: 16, height: 28)
            .rotationEffect(
                .degrees(idle.tailTip * 7),
                anchor: .top
            )
            .rotationEffect(.degrees(tailBaseDegrees))
            .offset(x: 5, y: action == .sleeping ? 4 : -2)
        }
    }

    private var usesTailBands: Bool {
        switch palette.coat {
        case .tabby, .gray, .cheese: true
        default: false
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
                .fill(palette.fur)
                .overlay { headMarkings }
                .overlay {
                    Circle()
                        .stroke(palette.outline.opacity(0.95), lineWidth: 1.45)
                }
            HStack(spacing: 6.2) {
                eye
                eye
            }
            .offset(y: -2.2)
            HStack(spacing: 8) {
                Circle().fill(palette.innerEar.opacity(0.42))
                Circle().fill(palette.innerEar.opacity(0.42))
            }
            .frame(width: 14, height: 2.5)
            .offset(y: 2.4)
            HStack(spacing: 9.5) {
                Circle()
                    .fill(Color(red: 1, green: 0.45, blue: 0.49).opacity(0.17))
                Circle()
                    .fill(Color(red: 1, green: 0.45, blue: 0.49).opacity(0.17))
            }
            .frame(width: 18, height: 5)
            .offset(y: 4.5)
            HStack(spacing: -0.7) {
                Circle().fill(.white.opacity(0.86))
                Circle().fill(.white.opacity(0.86))
            }
            .frame(width: 9.5, height: 5.2)
            .offset(y: 3.2)
            whiskers
            Triangle()
                .fill(palette.nose)
                .frame(width: 4.2, height: 3)
                .rotationEffect(.degrees(180))
                .offset(y: 2.9)
            CatMouthShape()
                .stroke(palette.outline.opacity(0.86), lineWidth: 0.85)
                .frame(width: 7.5, height: 4.2)
                .offset(y: 5)
            if action == .yawning {
                Ellipse()
                    .fill(palette.outline)
                    .frame(
                        width: 4 + 3 * yawn,
                        height: 0.8 + 5.4 * yawn
                    )
                    .offset(y: 5 + 1.6 * yawn)
            }
            if action == .grooming {
                CatLegShape()
                    .fill(palette.fur)
                    .overlay { CatLegShape().stroke(palette.outline, lineWidth: 0.6) }
                    .frame(width: 6, height: 13)
                    .rotationEffect(.degrees(-10 + legSwing * 18))
                    .offset(x: -7, y: 6)
            }
        }
        .frame(width: 23, height: 23)
        .rotationEffect(
            .degrees(reducesMotion ? 0 : pose.headTiltDegrees),
            anchor: .bottom
        )
        .offset(x: headOffset.x, y: headOffset.y)
    }

    @ViewBuilder
    private var headMarkings: some View {
        ZStack {
            switch palette.coat {
            case .white:
                Ellipse()
                    .fill(palette.patch.opacity(0.4))
                    .frame(width: 7, height: 12)
                    .offset(x: -6, y: -1)
            case .calico:
                Circle()
                    .fill(palette.patch)
                    .frame(width: 12)
                    .offset(x: 4.5, y: -5.5)
                Ellipse()
                    .fill(palette.secondPatch)
                    .frame(width: 7, height: 10)
                    .rotationEffect(.degrees(-18))
                    .offset(x: -6, y: 2)
            case .tabby, .gray, .cheese:
                VStack(spacing: 1) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill(palette.patch)
                            .frame(width: 1.5, height: 5.3 - CGFloat(index) * 0.5)
                            .rotationEffect(.degrees(Double(index - 1) * 12))
                    }
                }
                .rotationEffect(.degrees(90))
                .offset(y: -5)
            case .black:
                Ellipse()
                    .fill(palette.patch.opacity(0.45))
                    .frame(width: 10, height: 4)
                    .offset(x: -1, y: -5)
            case .cow:
                Ellipse()
                    .fill(palette.patch)
                    .frame(width: 10, height: 13)
                    .rotationEffect(.degrees(18))
                    .offset(x: -5, y: -2)
            }
        }
        .frame(width: 23, height: 23)
        .clipShape(Circle())
    }

    private var headOffset: (x: CGFloat, y: CGFloat) {
        switch action {
        case .sleeping: (0, 5.5)
        // 귀가 몸통에 묻히지 않도록 머리를 조금 띄운다.
        case .stretching: (5, -2)
        // 밥그릇 쪽으로 고개를 내렸다 올린다.
        case .eating: (3, -2 + CGFloat(legSwing) * 1.5)
        default: (2, -3.5)
        }
    }

    /// 0...1. 하품이 가장 크게 벌어진 순간이 1이다.
    private var yawn: CGFloat {
        guard action == .yawning, !reducesMotion else { return 0 }
        return CGFloat(pose.cycleEase)
    }

    private var ears: some View {
        HStack(spacing: 8.2) {
            ear
                .rotationEffect(
                    .degrees(idle.earFlick * -4 - Double(yawn) * 7),
                    anchor: .bottom
                )
            ear
                .rotationEffect(
                    .degrees(idle.earFlick * 13 + Double(yawn) * 7),
                    anchor: .bottom
                )
        }
        .frame(width: 23, height: 11)
        .offset(y: -8.5)
    }

    private var ear: some View {
        Triangle()
            .fill(palette.fur)
            .overlay {
                Triangle()
                    .fill(palette.innerEar.opacity(0.72))
                    .scaleEffect(0.54, anchor: .bottom)
                    .offset(y: 1.5)
            }
            .overlay { Triangle().stroke(palette.outline, lineWidth: 1) }
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
        ZStack {
            Capsule()
                .fill(palette.outline)
            if eyeOpenness >= 0.15 {
                Circle()
                    .fill(palette.eye.opacity(0.96))
                    .frame(width: 2.3)
                    .offset(x: 0.7, y: 0.8)
                Circle()
                    .fill(palette.outline)
                    .frame(width: 1.1)
                    .offset(x: 0.8, y: 1)
                Circle()
                    .fill(.white)
                    .frame(width: 1.55)
                    .offset(x: -0.95, y: -1.05)
                Circle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 0.65)
                    .offset(x: 1.1, y: -0.25)
            }
        }
            .frame(
                width: 4.4 + (1 - eyeOpenness) * 1.2,
                height: 1 + eyeOpenness * 4.1
            )
    }

    private var whiskers: some View {
        HStack(spacing: 5) {
            whiskerSet.scaleEffect(x: -1, y: 1)
            whiskerSet
        }
        .offset(y: 3)
        .opacity(action == .sleeping ? 0.35 : 0.9)
    }

    private var whiskerSet: some View {
        VStack(spacing: 1.4) {
            ForEach([-9.0, 0, 9], id: \.self) { angle in
                Capsule()
                    .fill(palette.outline.opacity(0.67))
                    .frame(width: 7.5, height: 0.8)
                    .rotationEffect(.degrees(angle))
            }
        }
    }

    @ViewBuilder
    private var legs: some View {
        if action != .sleeping {
            HStack(spacing: action.sitsUpright ? 5 : 4.3) {
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
        case .kneading: 1
        case .stretching: 3
        case _ where action.sitsUpright: 7
        default: 5
        }
    }

    private func leg(index: Int) -> some View {
        VStack(spacing: -1) {
            CatLegShape()
                .fill(palette.fur)
                .overlay {
                    CatLegShape()
                        .stroke(palette.outline.opacity(0.90), lineWidth: 0.8)
                }
                .frame(width: 4.8, height: legHeight(index: index))
            ZStack {
                Capsule()
                    .fill(palette.shadow)
                HStack(spacing: 0.7) {
                    Capsule().fill(palette.outline.opacity(0.55))
                    Capsule().fill(palette.outline.opacity(0.55))
                }
                .frame(width: 2.4, height: 0.55)
                .offset(y: 0.4)
            }
                .frame(
                    width: action == .kneading && index >= 2 ? 7 : 6.3,
                    height: 3.1
                )
        }
        .opacity(index.isMultiple(of: 2) ? 0.9 : 1)
        .rotationEffect(.degrees(legRotation(index: index)))
        .offset(y: legOffsetY(index: index))
    }

    private func legHeight(index: Int) -> CGFloat {
        switch action {
        case .stretching: index >= 2 ? 7.5 : 10
        // 식빵 자세라 발이 짧게 접혀 있다.
        case .kneading: 6
        case _ where action.sitsUpright: 12
        default: 9.5
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

private struct CatTailCurve: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX * 0.78, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.maxX * 0.36, y: rect.minY + rect.height * 0.08),
            control1: CGPoint(x: rect.maxX * 0.22, y: rect.maxY * 0.76),
            control2: CGPoint(x: rect.minX, y: rect.maxY * 0.28)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX * 0.77, y: rect.minY + rect.height * 0.18),
            control1: CGPoint(x: rect.maxX * 0.48, y: rect.minY),
            control2: CGPoint(x: rect.maxX * 0.68, y: rect.minY)
        )
        return path
    }
}

private struct FluffyTailShape: Shape {
    func path(in rect: CGRect) -> Path {
        let points = [
            CGPoint(x: 0.50, y: 0.00), CGPoint(x: 0.78, y: 0.06),
            CGPoint(x: 0.72, y: 0.14), CGPoint(x: 0.91, y: 0.22),
            CGPoint(x: 0.78, y: 0.31), CGPoint(x: 0.93, y: 0.43),
            CGPoint(x: 0.79, y: 0.52), CGPoint(x: 0.89, y: 0.66),
            CGPoint(x: 0.72, y: 0.73), CGPoint(x: 0.78, y: 0.89),
            CGPoint(x: 0.57, y: 1.00), CGPoint(x: 0.35, y: 0.91),
            CGPoint(x: 0.39, y: 0.76), CGPoint(x: 0.19, y: 0.68),
            CGPoint(x: 0.31, y: 0.54), CGPoint(x: 0.12, y: 0.43),
            CGPoint(x: 0.29, y: 0.32), CGPoint(x: 0.14, y: 0.20),
            CGPoint(x: 0.34, y: 0.13), CGPoint(x: 0.27, y: 0.05)
        ]
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: rect.minX + first.x * rect.width, y: rect.minY + first.y * rect.height))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height))
        }
        path.closeSubpath()
        return path
    }
}

private struct CatLegShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.20, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY),
            control: CGPoint(x: rect.minX + rect.width * 0.05, y: rect.midY)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.80, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.midY)
        )
        path.closeSubpath()
        return path
    }
}

private struct CatMouthShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY * 0.68),
            control: CGPoint(x: rect.width * 0.34, y: rect.maxY)
        )
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY * 0.68),
            control: CGPoint(x: rect.width * 0.66, y: rect.maxY)
        )
        return path
    }
}
