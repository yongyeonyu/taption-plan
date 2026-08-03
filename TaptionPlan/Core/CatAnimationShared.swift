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

    var movesAcrossTrack: Bool {
        self == .walking || self == .running
    }
}

struct TaptionCatAnimationPose: Equatable, Sendable {
    var progress: Double
    var facesLeft: Bool
    var phase: Int
    var action: TaptionCatAnimationAction
    var tailSwing: Double
    var headTiltDegrees: Double
}

enum TaptionCatAnimationEngine {
    /// A small, deterministic frame clock keeps the same gait on iPhone,
    /// WidgetKit and watchOS.  TimelineView supplies the actual redraw date.
    static let stepDuration: TimeInterval = 0.16
    private static let stepCount = 20

    static func pose(
        at date: Date,
        preferredAction: TaptionCatAnimationAction? = nil,
        reducesMotion: Bool = false
    ) -> TaptionCatAnimationPose {
        let rawStep = Int(
            floor(date.timeIntervalSinceReferenceDate / stepDuration)
        )
        let step = ((rawStep % stepCount) + stepCount) % stepCount
        let phase = reducesMotion ? 0 : step % 4
        let action = preferredAction ?? .walking
        let moves = action.movesAcrossTrack && !reducesMotion
        let outward = step <= stepCount / 2
        let distance = outward
            ? Double(step) / Double(stepCount / 2)
            : Double(stepCount - step) / Double(stepCount / 2)
        let motion = motion(for: action, phase: phase)
        return TaptionCatAnimationPose(
            progress: moves ? min(1, max(0, distance)) : 0.5,
            facesLeft: moves && !outward,
            phase: phase,
            action: reducesMotion ? .sitting : action,
            tailSwing: reducesMotion ? 0 : motion.tail,
            headTiltDegrees: reducesMotion ? 0 : motion.head
        )
    }

    static func pose(
        from action: String,
        progress: Double,
        phase: Int,
        facesLeft: Bool,
        tailSwing: Double,
        headTiltDegrees: Double
    ) -> TaptionCatAnimationPose {
        TaptionCatAnimationPose(
            progress: min(1, max(0, progress)),
            facesLeft: facesLeft,
            phase: phase,
            action: TaptionCatAnimationAction(rawValue: action) ?? .walking,
            tailSwing: tailSwing,
            headTiltDegrees: headTiltDegrees
        )
    }

    private static func motion(
        for action: TaptionCatAnimationAction,
        phase: Int
    ) -> (tail: Double, head: Double) {
        let tails = [-1.0, -0.35, 0.45, 1.0]
        let heads = [-4.0, 1.5, 4.0, -1.5]
        let tail = tails[phase % tails.count]
        let head = heads[phase % heads.count]
        switch action {
        case .walking: return (tail, head)
        case .running: return (-tail, head * 1.45)
        case .grooming: return (tail * 0.38, [-11, -5, 6, -4][phase % 4])
        case .startled: return (1, -7)
        case .sleeping: return (tail * 0.16, 7)
        case .eating: return (tail * 0.28, 12)
        case .ballPlay: return (-tail * 0.85, head * 1.6)
        case .fishingPlay: return (tail * 0.72, [-8, 7, -4, 9][phase % 4])
        case .sitting: return (tail * 0.55, head * 1.25)
        }
    }
}

struct TaptionCatAnimationView: View {
    let style: String
    let pose: TaptionCatAnimationPose
    let reducesMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            let catWidth = min(52, proxy.size.width)
            let available = max(0, proxy.size.width - catWidth)
            let bounce: CGFloat = reducesMotion
                ? 0
                : (pose.action == .running
                    ? (pose.phase.isMultiple(of: 2) ? 1 : -3)
                    : pose.action.movesAcrossTrack
                        ? (pose.phase.isMultiple(of: 2) ? 0 : -1.5)
                        : 0)
            TaptionCatFigure(
                style: style,
                pose: pose,
                reducesMotion: reducesMotion
            )
            .frame(width: catWidth, height: 32)
            .scaleEffect(x: pose.facesLeft ? -1 : 1, y: 1)
            .offset(x: available * pose.progress, y: bounce)
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
            .rotationEffect(.degrees(action == .sleeping ? 4 : 0))
        }
        .frame(width: 52, height: 32)
    }

    private var bodyWidth: CGFloat {
        switch action {
        case .sitting, .grooming: 25
        case .sleeping: 34
        case .startled: 26
        default: 31
        }
    }

    private var bodyHeight: CGFloat {
        switch action {
        case .sitting, .grooming: 24
        case .sleeping: 14
        case .startled: 20
        default: 17
        }
    }

    private var bodyScaleY: CGFloat {
        guard action.movesAcrossTrack else { return 1 }
        return pose.phase.isMultiple(of: 2) ? 0.94 : 1.04
    }

    private var tail: some View {
        Capsule()
            .fill(action == .startled ? palette.base : palette.outline)
            .overlay {
                if action == .startled {
                    Capsule().stroke(palette.outline, lineWidth: 1)
                }
            }
            .frame(width: action == .startled ? 9 : 3,
                   height: action == .startled ? 30 : 22)
            .rotationEffect(
                .degrees(action == .startled ? -18 : -54 + pose.tailSwing * 12)
            )
            .offset(x: action == .startled ? 1 : 4,
                    y: action == .sleeping ? 4 : -2)
    }

    private var head: some View {
        ZStack {
            HStack(spacing: 7) {
                Triangle().fill(palette.base)
                Triangle().fill(palette.base)
            }
            .frame(width: 18, height: 9)
            .offset(y: -7)

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
            if action == .grooming {
                Capsule()
                    .fill(palette.base)
                    .overlay { Capsule().stroke(palette.outline, lineWidth: 0.8) }
                    .frame(width: 5, height: 13)
                    .rotationEffect(
                        .degrees(pose.phase.isMultiple(of: 2) ? -28 : 8)
                    )
                    .offset(x: -7, y: 6)
            }
        }
        .frame(width: 18, height: 18)
        .rotationEffect(
            .degrees(reducesMotion ? 0 : pose.headTiltDegrees),
            anchor: .center
        )
        .offset(x: action == .sleeping ? 1 : 7,
                y: action == .sleeping ? 4 : -4)
    }

    private var eye: some View {
        Capsule()
            .fill(palette.eye)
            .frame(width: action == .sleeping ? 4 : 2,
                   height: action == .sleeping ? 1 : 2.5)
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
            let stride = pose.phase.isMultiple(of: 2) ? 18.0 : -18.0
            HStack(spacing: action == .sitting ? 5 : 4) {
                leg(
                    index: 0,
                    rotation: action.movesAcrossTrack ? stride : 4
                )
                leg(
                    index: 1,
                    rotation: action.movesAcrossTrack ? -stride : -4
                )
                leg(
                    index: 2,
                    rotation: action.movesAcrossTrack ? -stride : 4
                )
                leg(
                    index: 3,
                    rotation: action.movesAcrossTrack ? stride : -4
                )
            }
            .offset(y: action == .sitting ? 8 : 6)
        }
    }

    private func leg(index: Int, rotation: Double) -> some View {
        VStack(spacing: -1) {
            Capsule()
                .fill(palette.outline.opacity(index.isMultiple(of: 2) ? 0.72 : 1))
                .frame(width: 2.5, height: action == .sitting ? 13 : 10)
            Capsule()
                .fill(palette.outline)
                .frame(width: 4.5, height: 2)
        }
        .rotationEffect(.degrees(rotation))
        .offset(
            y: action.movesAcrossTrack
                ? (pose.phase + index).isMultiple(of: 2) ? -1 : 2
                : 0
        )
    }

    @ViewBuilder
    private var accessory: some View {
        switch action {
        case .sleeping:
            Text(pose.phase.isMultiple(of: 2) ? "z" : "zZ")
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
                .offset(x: pose.phase.isMultiple(of: 2) ? 23 : 16,
                        y: pose.phase.isMultiple(of: 2) ? 15 : 8)
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
