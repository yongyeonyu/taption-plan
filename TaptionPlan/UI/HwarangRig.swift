import SwiftUI
import UIKit

/// 코드로 그리는 화랑이(RIG1101A01). 부품과 관절을 CoreGraphics로 그리고 장면마다 여러 동작을 이어 재생한다.
/// 위젯·워치는 기존 그림(`TaptionCatAtlasSprite`)을 그대로 쓴다.
enum HwarangScene: CaseIterable, Hashable, Sendable {
    case walkLoop, runLoop
    case stroll, groom, work, study, yarn, sleep, eat, wheel, stretch, confused
    case shower, robotVacuum, carFront, subway, train, bus, bicycle, airplane, boat, atlas

    /// 장면의 동작별 길이(초)와 배경 이동 속도.
    fileprivate var beats: [(duration: CGFloat, speed: CGFloat)] {
        switch self {
        case .walkLoop, .runLoop: [(4, 0)]
        case .stroll: [(4.5, 18), (2, 0), (2, 0), (3.5, 18), (2, 30)]
        case .groom: [(1.5, 0), (1.5, 0), (3, 0), (3.2, 0), (2, 0), (1, 0), (2.4, 0), (1, 0), (2.2, 0), (2.4, 0), (1.4, 0)]
        case .work: [(3.6, 0), (2.2, 0), (2.2, 0), (2.2, 0), (2.8, 0), (2.2, 0)]
        case .study: [(4.8, 0), (1.8, 0), (4.8, 0), (2.6, 0)]
        case .yarn: [(2.4, 0), (1, 0), (2.6, 0), (1.6, 0), (3.2, 0), (1.8, 0)]
        case .sleep: [(5, 0), (1.2, 0), (1.6, 0), (3, 0), (3.4, 0)]
        case .eat: [(3.4, 0), (2, 0), (1.8, 0), (2.6, 0), (2.2, 0)]
        case .wheel: [(2.6, 1.1), (3.4, 2.6), (2.6, 4.4), (1.8, 2), (2, 0.2)]
        case .stretch: [(3.4, 0), (2.6, 0), (2.6, 0), (2.4, 0), (3.2, 0)]
        case .confused: [(2.2, 0), (2.2, 0), (2, 0), (2.4, 0), (2, 0)]
        case .shower: [(3.6, 0), (1.4, 0), (3, 0), (1.6, 0)]
        case .robotVacuum: [(7, 0)]
        case .carFront: [(4, 60), (2.4, 60), (3, 60)]
        case .subway, .train: [(4, 90), (3, 90)]
        case .bicycle: [(5, 46)]
        case .bus: [(4, 55), (3, 55)]
        case .airplane: [(5, 26)]
        case .boat: [(5, 22)]
        case .atlas: [(6, 0)]
        }
    }

    var totalDuration: CGFloat { beats.reduce(0) { $0 + $1.duration } }
    var beatCount: Int { beats.count }

    /// 화랑이가 탈것 안에 있는 장면. 속도와 상관없이 같은 장면을 보여 준다.
    var isVehicleScene: Bool {
        switch self {
        case .carFront, .subway, .train, .bus, .bicycle, .airplane, .boat: true
        default: false
        }
    }
}

enum Eye { case open, half, closed, happy }

struct HeadPose {
    var tilt: CGFloat = 0
    var ear: CGFloat = 0
    var look: CGFloat = 0
    var mouthOpen: CGFloat = 0
    var tongue: CGFloat = 0
    var turn: CGFloat = 0
    var eye: Eye = .open
    var blink = false
    var wet = false
}

private enum PoseProp {
    case none
    case book(flip: CGFloat)
    case map
}

private struct Pose {
    var hip = CGPoint.zero, mid = CGPoint.zero, sh = CGPoint.zero, head = CGPoint.zero
    var bn = CGPoint.zero, bf = CGPoint.zero, fn = CGPoint.zero, ff = CGPoint.zero
    var headX: CGFloat = 8, headY: CGFloat = 9
    var rh: CGFloat = 11.6, rs: CGFloat = 9.8, rm: CGFloat = 1.6
    var hindBend: CGFloat = 1, farHindBend: CGFloat? = nil, foreBend: CGFloat = -1
    var ta: CGFloat = 0, tc: CGFloat = 0, tw: CGFloat = 0, tp: CGFloat = 0
    var h = HeadPose()
    var flat: CGFloat = 0, legUp: CGFloat = 0, spread: CGFloat = 0
    var foreOver = false
    var prop = PoseProp.none
    var desk = false
    var fnAbs = CGPoint.zero, ffAbs = CGPoint.zero
    var squash: CGFloat = 1
    // 식빵
    var breath: CGFloat = 0, drop: CGFloat = 0
}

let groundY: CGFloat = 104
let tau = CGFloat.pi * 2
private let wheelCenter = CGPoint(x: 58, y: 62)
private let wheelRadius: CGFloat = 48
private let wheelGround: CGFloat = 106
private let wheelScale: CGFloat = 0.76
private let bookCenter: CGFloat = 66, bookY: CGFloat = groundY + 8, bookWidth: CGFloat = 34

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t)) }
private func ease(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }
func clamp(_ v: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat { max(a, min(b, v)) }
func wrap(_ v: CGFloat, _ m: CGFloat) -> CGFloat { let r = v.truncatingRemainder(dividingBy: m); return r < 0 ? r + m : r }
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
private func blink(_ s: CGFloat, _ every: CGFloat = 3.1) -> Eye { wrap(s, every) < 0.14 ? .closed : .open }

private func blend(_ a: HeadPose, _ b: HeadPose, _ u: CGFloat) -> HeadPose {
    var o = u < 0.5 ? a : b
    o.tilt = lerp(a.tilt, b.tilt, u); o.ear = lerp(a.ear, b.ear, u); o.look = lerp(a.look, b.look, u)
    o.mouthOpen = lerp(a.mouthOpen, b.mouthOpen, u); o.tongue = lerp(a.tongue, b.tongue, u); o.turn = lerp(a.turn, b.turn, u)
    return o
}

private func blend(_ a: Pose, _ b: Pose, _ u: CGFloat) -> Pose {
    var o = u < 0.5 ? a : b
    o.hip = lerp(a.hip, b.hip, u); o.mid = lerp(a.mid, b.mid, u); o.sh = lerp(a.sh, b.sh, u); o.head = lerp(a.head, b.head, u)
    o.bn = lerp(a.bn, b.bn, u); o.bf = lerp(a.bf, b.bf, u); o.fn = lerp(a.fn, b.fn, u); o.ff = lerp(a.ff, b.ff, u)
    o.headX = lerp(a.headX, b.headX, u); o.headY = lerp(a.headY, b.headY, u)
    o.rh = lerp(a.rh, b.rh, u); o.rs = lerp(a.rs, b.rs, u); o.rm = lerp(a.rm, b.rm, u)
    o.ta = lerp(a.ta, b.ta, u); o.tc = lerp(a.tc, b.tc, u); o.tw = lerp(a.tw, b.tw, u); o.tp = lerp(a.tp, b.tp, u)
    o.h = blend(a.h, b.h, u)
    o.flat = lerp(a.flat, b.flat, u); o.legUp = lerp(a.legUp, b.legUp, u); o.spread = lerp(a.spread, b.spread, u)
    o.fnAbs = lerp(a.fnAbs, b.fnAbs, u); o.ffAbs = lerp(a.ffAbs, b.ffAbs, u)
    o.breath = lerp(a.breath, b.breath, u); o.drop = lerp(a.drop, b.drop, u)
    return o
}

// MARK: - 자세

private func foot(_ phase: CGFloat, _ x: CGFloat, _ stride: CGFloat, _ lift: CGFloat, duty: CGFloat = 0.6) -> CGPoint {
    let ph = wrap(phase, 1)
    if ph < duty { return P(x + stride * (0.5 - ph / duty), groundY) }
    let u = (ph - duty) / (1 - duty)
    return P(x + stride * (ease(u) - 0.5), groundY - lift * sin(u * .pi))
}

private func walk(_ s: CGFloat, period: CGFloat = 1.15, stride: CGFloat = 20) -> Pose {
    let t = s / period, b = sin(t * tau * 2), y = -b * 0.9
    var p = Pose()
    p.headX = 3
    p.hip = P(40, 76 + y + sin(t * tau) * 0.5); p.mid = P(54, 73.5 + y * 0.4); p.sh = P(68, 75 - y * 0.6); p.head = P(76, 56 - b * 0.8)
    p.bn = foot(t, 30, stride, 8); p.bf = foot(t + 0.5, 46, stride, 8); p.fn = foot(t + 0.25, 68, stride, 9); p.ff = foot(t + 0.75, 84, stride, 9)
    p.ta = -2.25; p.tc = 0.9; p.tw = 0.42; p.tp = t * tau * 2
    p.h = HeadPose(tilt: sin(t * tau) * 0.03, look: 1.6)
    return p
}

private func gallop(_ s: CGFloat, period: CGFloat = 0.56, mouth: CGFloat = 0.4) -> Pose {
    let t = s / period, w = t * tau, f = sin(w), g = cos(w), y = -abs(sin(w)) * 6
    func reach(_ ph: CGFloat, _ x: CGFloat) -> CGPoint {
        let a = ph * tau
        return P(x + cos(a) * 16, min(groundY, groundY - 5 + sin(a) * 9 + y * 0.3))
    }
    var p = Pose()
    p.hip = P(38 - f * 3, 78 + y + g * 2.5); p.mid = P(55, 73 + y - f * 2.8); p.sh = P(72 + f * 3, 76 + y - g * 2.5); p.head = P(87, 57 + y - g * 1.8)
    p.bn = reach(t, 28); p.bf = reach(t + 0.16, 46); p.fn = reach(t + 0.5, 70); p.ff = reach(t + 0.66, 90)
    p.ta = -2.7 + f * 0.35; p.tc = 0.45; p.tw = 0.5; p.tp = w * 1.4
    p.h = HeadPose(tilt: 0.05 + g * 0.05, look: 2, mouthOpen: mouth)
    return p
}

private func stand(_ s: CGFloat, _ h: HeadPose = HeadPose(look: 1.6)) -> Pose {
    let br = sin(s * tau / 2.4) * 0.5
    var p = Pose()
    p.headX = 3
    p.hip = P(40, 76); p.mid = P(54, 74 + br * 0.4); p.sh = P(68, 75 - br * 0.4); p.head = P(76, 56 - br * 0.5)
    p.bn = P(30, groundY); p.bf = P(46, groundY); p.fn = P(68, groundY); p.ff = P(84, groundY)
    p.ta = -2.2; p.tc = 0.9; p.tw = 0.3; p.tp = s * 2.2
    p.h = h
    return p
}

private func sit(_ s: CGFloat, _ h: HeadPose = HeadPose(look: 1.4)) -> Pose {
    let br = sin(s * tau / 2.8) * 0.5
    var p = Pose()
    p.headX = 2; p.headY = 6
    p.hip = P(50, 88); p.mid = P(56, 76 + br * 0.3); p.sh = P(62, 67 - br); p.rh = 12.5; p.rs = 9; p.rm = 1
    p.head = P(66, 48 - br * 1.2)
    p.bf = P(62, groundY); p.bn = P(56, groundY); p.ff = P(76, groundY); p.fn = P(69, groundY)
    p.hindBend = -1; p.ta = 3.25; p.tc = -0.95; p.tw = 0.28; p.tp = s * 2.2
    p.h = h
    return p
}

/// 앉아서 뒷다리를 들고 몸을 말아 엉덩이를 핥는 자세. k: 다리 올림, d: 머리 숙임.
private func lick(_ s: CGFloat, k: CGFloat, d: CGFloat, _ h: HeadPose, spread: CGFloat = 0, shake: CGFloat = 0, along: CGFloat = 0, tw: CGFloat = 0.25) -> Pose {
    let up = ease(clamp(k * 1.6, 0, 1)), jitter = shake * sin(s * 30)
    var p = sit(s)
    p.flat = k; p.legUp = k; p.spread = spread
    p.hip = P(lerp(50, 46, k), lerp(88, 84, k)); p.mid = P(lerp(56, 58, k), lerp(76, 78, k)); p.sh = P(lerp(62, 70, k), lerp(67, 80, k))
    p.rh = lerp(13, 11, k); p.rs = 9.5
    p.bn = P(lerp(56, 28, up) + jitter, lerp(groundY, 30 + sin(s * 3) * 1.2, up))
    p.bf = P(lerp(62, 94, k), groundY); p.farHindBend = 1
    p.fn = P(lerp(69, 80, k), groundY); p.ff = P(lerp(76, 88, k), groundY)
    p.head = P(lerp(66, lerp(70, lerp(62, 54, along), d), k), lerp(48, lerp(58, lerp(74, 64, along), d), k))
    p.headX = lerp(2, 0, k); p.headY = lerp(6, 0, k)
    p.ta = lerp(3.25, 3.0, k); p.tc = lerp(-0.95, 0.3, k); p.tw = tw; p.tp = s * 2.2
    p.h = h
    p.h.tilt = h.tilt != 0 ? h.tilt : k * d * lerp(0.72, 0.45, along)
    return p
}

/// 쪼그려 앉아 앞발은 책 뒤로 숨기고 머리만 좌우로 돌려 읽는다. 책장은 혼자 넘어간다.
private func study(_ s: CGFloat, turn: CGFloat, flip: CGFloat, eye: Eye? = nil) -> Pose {
    let br = sin(s * tau / 2.8) * 0.5
    var p = Pose()
    p.hip = P(46, 90); p.mid = P(54, 84 - br * 0.4); p.sh = P(62, 84 - br * 0.6); p.rh = 14; p.rs = 11
    p.head = P(62 + turn * 3, 64 - br * 0.6); p.headX = 0; p.headY = 12
    p.bn = P(50, groundY); p.bf = P(58, groundY); p.fn = P(62, groundY); p.ff = P(72, groundY)
    p.ta = 3.3; p.tc = -0.9; p.tw = 0.55; p.tp = s * 1.5
    p.prop = .book(flip: flip)
    p.h = HeadPose(tilt: turn * 0.09, look: turn * 4, eye: eye ?? blink(s, 2.9))
    return p
}

private func desk(_ s: CGFloat, _ a: CGFloat, _ b: CGFloat, _ h: HeadPose) -> Pose {
    var p = Pose()
    p.desk = true
    p.hip = P(26, 87); p.mid = P(44, 77); p.sh = P(62, 84)
    p.head = P(58, 58 + sin(s * 2) * 0.8)
    p.fnAbs = P(82, 97 + a * 0.9); p.ffAbs = P(96, 95 + b * 0.9)
    p.tp = s * 2
    p.h = h
    return p
}

private func eating(_ s: CGFloat, dip: CGFloat, _ h: HeadPose) -> Pose {
    var p = Pose()
    p.headX = 5; p.headY = 6 - dip * 5
    p.hip = P(38, 76); p.mid = P(53, 76); p.sh = P(68, 80 + dip * 3); p.head = P(80, 62 + dip * 18)
    p.bn = P(30, groundY); p.bf = P(44, groundY); p.fn = P(62, groundY); p.ff = P(76, groundY)
    p.ta = -2.1; p.tc = 0.9; p.tw = 0.3; p.tp = s * 2
    p.h = h
    return p
}

/// 자전거 안장에 앉아 페달을 밟는다. 뒷발은 크랭크를 따라 돈다.
private func riding(_ s: CGFloat) -> Pose {
    let a = s * 6, sway = sin(a) * 0.8
    var p = Pose()
    p.hip = P(38, 70 + sway * 0.4); p.mid = P(50, 67); p.sh = P(64, 70); p.rh = 10; p.rs = 9
    p.head = P(68, 46 - sway * 0.5); p.headX = 0; p.headY = 3
    p.bn = P(58 + cos(a) * 9, 96 + sin(a) * 9); p.bf = P(52 + cos(a + .pi) * 9, 96 + sin(a + .pi) * 9)
    p.fn = P(100, 62); p.ff = P(96, 62)
    p.ta = 3.0; p.tc = -0.4; p.tw = 0.3; p.tp = s * 3
    p.h = HeadPose(tilt: sway * 0.03, look: 1.8, mouthOpen: 0.2, eye: wrap(s, 4) < 3 ? blink(s) : .happy)
    return p
}

private func bow(_ s: CGFloat, _ k: CGFloat) -> Pose {
    var p = Pose()
    p.hip = P(lerp(42, 38, k), lerp(76, 64, k)); p.mid = P(lerp(56, 54, k), lerp(74, 76, k)); p.sh = P(70, lerp(76, 90, k)); p.head = P(84, lerp(57, 80, k))
    p.rh = 11; p.rs = 9.5
    p.bn = P(34, groundY); p.bf = P(46, groundY); p.fn = P(lerp(68, 92, k), groundY); p.ff = P(lerp(78, 102, k), groundY)
    p.ta = lerp(-2.2, -1.3, k); p.tc = 0.5; p.tw = 0.3; p.tp = s * 2
    p.h = HeadPose(tilt: lerp(0, -0.14, k), look: 1.6, mouthOpen: k > 0.75 ? 0.45 : 0, eye: k > 0.5 ? .closed : .open)
    return p
}

private func pose(_ scene: HwarangScene, beat i: Int, s: CGFloat, u: CGFloat) -> Pose {
    switch scene {
    case .walkLoop: return walk(s)
    case .runLoop: return gallop(s)
    case .stroll:
        switch i {
        case 0, 3: return walk(s)
        case 1:
            let swing = sin(s * 2.5)
            return stand(s, HeadPose(tilt: swing * 0.12, look: lerp(-3, 3, (swing + 1) / 2)))
        case 2:
            var p = eating(s, dip: 0.9, HeadPose(tilt: 0.29, look: 1.6, eye: .happy))
            p.head = P(82, 78 + sin(s * 9) * 0.8)
            return p
        default: return walk(s, period: 0.72, stride: 22)
        }
    case .groom:
        let l = (sin(s * 12) + 1) / 2
        switch i {
        case 0: return sit(s, HeadPose())
        case 1: return lick(s, k: ease(clamp(u * 1.5, 0, 1)), d: 0, HeadPose(look: -1), spread: u)
        case 2:
            let v = (sin(s * 3.2) + 1) / 2, m = (sin(s * 11) + 1) / 2
            return lick(s, k: 1, d: 1 - m * 0.1, HeadPose(ear: sin(s * 2) * 0.08, look: 1, mouthOpen: 0.3, tongue: 0.5 + m * 0.5, eye: .closed), along: v, tw: 0.3)
        case 3: return lick(s, k: 1, d: 1 - l * 0.12, HeadPose(look: 1, mouthOpen: 0.3, tongue: 0.45 + l * 0.55, eye: .closed), tw: 0.35)
        case 4: return lick(s, k: 1, d: 0.05, HeadPose(ear: sin(s * 6) * 0.15, look: 1, mouthOpen: 0.15, tongue: 0.8, eye: wrap(s, 1.2) < 0.12 ? .closed : .open), tw: 0.15)
        case 5: return lick(s, k: 1, d: 0.2, HeadPose(look: 1, tongue: 0.3, eye: .closed), spread: 1, shake: 2.6)
        case 6: return lick(s, k: 1, d: 1 - l * 0.12, HeadPose(look: 1, mouthOpen: 0.3, tongue: 0.45 + l * 0.55, eye: .closed))
        case 7: return lick(s, k: 1 - ease(u), d: 0, HeadPose(look: 1, tongue: 0.4, eye: .happy))
        case 8:
            let m = (sin(s * 11) + 1) / 2
            var p = sit(s, HeadPose(tilt: 0.2, look: 1.4, mouthOpen: 0.35, tongue: 0.35 + m * 0.65, eye: .closed))
            p.head = P(66, 51); p.fn = P(71, 69 + m * 1.5); p.foreOver = true
            return p
        case 9:
            let w = (sin(s * 5) + 1) / 2
            var p = sit(s, HeadPose(tilt: 0.12 - w * 0.12, look: 1.4, eye: .closed))
            p.head = P(66, 49); p.fn = P(lerp(70, 76, w), lerp(62, 44, w)); p.foreOver = true
            return p
        default: return sit(s, HeadPose(look: 1.4, tongue: (sin(s * 7) + 1) * 0.3, eye: .happy))
        }
    case .work:
        switch i {
        case 0: return desk(s, min(0, sin(s * 12)) * 3.5, min(0, -sin(s * 12)) * 3.5, HeadPose(tilt: 0.05, turn: 1, eye: blink(s)))
        case 1: return desk(s, 0, 0, HeadPose(tilt: 0.05, turn: 1 - pow(sin(u * .pi), 0.7)))
        case 2: return desk(s, 0, 0, HeadPose(tilt: 0.04 + sin(s * 7) * 0.05, turn: 1, eye: blink(s)))
        case 3: return desk(s, 0, 0, HeadPose(tilt: -0.16 + sin(s * 2) * 0.05, turn: 0.55, eye: blink(s)))
        case 4: return desk(s, min(0, sin(s * 22)) * 4.5, min(0, -sin(s * 22)) * 4.5, HeadPose(tilt: 0.05, mouthOpen: 0.2, turn: 1, eye: .happy))
        default:
            let k = sin(u * .pi)
            var p = desk(s, 0, 0, HeadPose(tilt: 0.05, mouthOpen: k * 0.8, turn: lerp(1, 0.25, k), eye: .closed))
            p.sh = P(62, 84 - k * 6); p.head = P(58, 58 - k * 10)
            p.fnAbs = P(82 + k * 4, 97 - k * 14); p.ffAbs = P(96 + k * 2, 95 - k * 14)
            return p
        }
    case .study:
        switch i {
        case 0, 2: return study(s, turn: sin(u * tau * 2), flip: 0)
        case 1: return study(s, turn: cos(ease(u) * .pi), flip: u, eye: .open)
        default:
            let f = wrap(u * 2, 1)
            return study(s, turn: cos(ease(f) * .pi), flip: f, eye: .open)
        }
    case .yarn:
        var p = Pose()
        switch i {
        case 0:
            let w = sin(s * 14) * 2
            p.hip = P(40 + w * 0.5, 68); p.mid = P(56, 76); p.sh = P(72, 88); p.rh = 11; p.rs = 9.6; p.head = P(81, 73)
            p.bn = P(34, groundY); p.bf = P(46, groundY); p.fn = P(72, groundY); p.ff = P(84, groundY)
            p.ta = -1.6 + w * 0.06; p.tc = -0.8; p.tw = 0.75; p.tp = s * 14
            p.h = HeadPose(look: 2.6)
        case 1:
            let j = sin(u * .pi) * 22
            p.hip = P(lerp(40, 58, u), 76 - j); p.mid = P(lerp(56, 72, u), 72 - j); p.sh = P(lerp(72, 86, u), 74 - j); p.head = P(lerp(84, 98, u), 58 - j)
            p.bn = P(lerp(34, 50, u), groundY - j * 0.7); p.bf = P(lerp(46, 60, u), groundY - j * 0.7); p.fn = P(lerp(76, 96, u), groundY - j * 0.6); p.ff = P(lerp(84, 104, u), groundY - j * 0.6)
            p.ta = -2.6; p.tc = 0.4; p.tw = 0.2; p.tp = s * 6
            p.h = HeadPose(look: 2.5, mouthOpen: 0.4)
        case 2:
            let k = (sin(s * 5) + 1) / 2
            p.hip = P(38, 80); p.mid = P(53, 80); p.sh = P(68, 84); p.head = P(80, 66)
            p.bn = P(34, groundY); p.bf = P(46, groundY); p.ff = P(76, groundY); p.fn = P(lerp(78, 98, k), groundY - k * 10)
            p.ta = -1.9; p.tc = 0.7; p.tw = 0.5; p.tp = s * 5
            p.h = HeadPose(look: 2.6, eye: k > 0.6 ? .happy : .open)
        case 3: return gallop(s, period: 0.48)
        case 4:
            let k = sin(s * 11)
            p.hip = P(42, 92); p.mid = P(56, 95); p.sh = P(72, 92); p.rh = 12; p.rs = 10; p.head = P(90, 86)
            p.hindBend = -1; p.foreBend = 1
            p.bn = P(48 + k * 3, 70 - k * 4); p.bf = P(58 - k * 3, 68 + k * 4); p.fn = P(66, 66); p.ff = P(60, 62)
            p.ta = 3; p.tc = -0.5; p.tw = 0.5; p.tp = s * 5
            p.h = HeadPose(tilt: 1.3, mouthOpen: 0.3, eye: .happy)
        default: return sit(s, HeadPose(tilt: sin(s * 3) * 0.06, look: 1.4, eye: .happy))
        }
        return p
    case .sleep:
        var p = Pose()
        p.breath = sin(s * tau / 3) * 0.9; p.tp = s
        p.h.eye = .closed
        switch i {
        case 1: p.h.ear = sin(u * .pi * 4) * 0.3
        case 2: p.h.eye = sin(u * .pi) > 0.4 ? .half : .closed
        case 3:
            p.drop = (1 - cos(u * tau * 2)) * 3
            p.h.tilt = (1 - cos(u * tau * 2)) * 0.05
        case 4: p.drop = 6; p.h.tilt = 0.1
        default: break
        }
        return p
    case .eat:
        switch i {
        case 0, 3: return eating(s, dip: 1, HeadPose(tilt: 0.32, look: 1.6, mouthOpen: (sin(s * 16) + 1) * 0.25, eye: .happy))
        case 1: return eating(s, dip: 0, HeadPose(look: 1.6, mouthOpen: (sin(s * 11) + 1) * 0.2, eye: .happy))
        case 2: return eating(s, dip: 0, HeadPose(tilt: 0.06, look: 1.6, tongue: (sin(s * 8) + 1) * 0.45, eye: .happy))
        default: return sit(s, HeadPose(look: 1.4, tongue: 0.2, eye: .happy))
        }
    case .wheel:
        switch i {
        case 0:
            var p = walk(s, period: 0.95, stride: 18)
            p.h.look = 2
            return p
        case 1: return gallop(s, period: 0.56)
        case 2: return gallop(s, period: 0.38, mouth: 0.7)
        case 3: return sit(s, HeadPose(look: 1.4, mouthOpen: 0.3, eye: .happy))
        default: return stand(s, HeadPose(look: 1.6, mouthOpen: 0.5 + sin(s * 14) * 0.3, tongue: 0.5, eye: .happy))
        }
    case .stretch:
        let k = sin(u * .pi)
        switch i {
        case 0: return bow(s, pow(k, 0.6))
        case 1:
            var p = stand(s, HeadPose(tilt: 0.1 * k, look: 1.6, eye: .closed))
            p.mid = P(54, 74 - k * 12); p.hip = P(42, 76 + k * 2); p.sh = P(66, 76 + k * 2); p.head = P(82, 58 + k * 8); p.rm = 1.6 + k
            return p
        case 2:
            var p = stand(s, HeadPose(tilt: -k * 0.08, look: 1.6, eye: .happy))
            p.bn = P(lerp(36, 10, k), lerp(groundY, groundY - 10, k)); p.ta = -2.2 + k * 0.5
            return p
        case 3:
            var p = bow(s, k * 0.6)
            p.fn = P(lerp(68, 104, k), groundY)
            return p
        default:
            let br = sin(u * tau)
            var p = sit(s, HeadPose(look: 1.4, eye: .closed))
            p.mid = P(56, 76 - br * 0.8); p.sh = P(62, 67 - br * 1.6); p.rm = 1 + br * 0.9; p.head = P(66, 48 - br * 2); p.tc = -1.3; p.tw = 0.08
            return p
        }
    case .confused:
        switch i {
        case 0, 1, 2:
            let h = [HeadPose(tilt: 0.28, look: 2, eye: blink(s, 1.7)), HeadPose(tilt: -0.26, look: -1.2, eye: blink(s, 1.9)), HeadPose(tilt: 0.12, look: 2.4)][i]
            var p = sit(s, h)
            p.tw = 0.6; p.tp = s * 4
            if i == 2 { p.fn = P(77, groundY - 10) }
            return p
        case 3:
            var p = eating(s, dip: 0.5, HeadPose(tilt: 0.16, look: 2.4))
            p.head = P(84, 70 + sin(s * 10) * 1.2)
            return p
        default: return sit(s, HeadPose(tilt: 0.1, look: 1.4, mouthOpen: 0.2, eye: .closed))
        }
    case .shower:
        var h: HeadPose
        switch i {
        case 0: h = HeadPose(tilt: sin(s * 1.3) * 0.05, look: 0.6, mouthOpen: 0.15, eye: .closed)
        case 1: h = HeadPose(tilt: sin(s * 26) * 0.24, eye: .happy)
        case 2: h = HeadPose(tilt: -0.08, look: 1, mouthOpen: 0.35, eye: .half)
        default: h = HeadPose(tilt: sin(s * 2) * 0.06, look: -1, tongue: 0.4, eye: blink(s, 1.3))
        }
        h.wet = true
        var p = sit(s, h)
        p.head = P(66, 56); p.ta = 3.3; p.tc = -0.2; p.tw = 0.06
        return p
    case .robotVacuum:
        return sit(s, HeadPose(tilt: sin(s * 1.7) * 0.1, look: 1.4, mouthOpen: 0.2, eye: wrap(s, 5) < 2.5 ? .open : .happy))
    case .carFront:
        var p = Pose()
        p.h = HeadPose(tilt: sin(s * 0.9) * 0.08, look: sin(s * 0.7) * 2, mouthOpen: i == 1 ? 0.35 : 0, eye: i == 1 ? .happy : blink(s))
        return p
    case .bicycle:
        return riding(s)
    case .subway, .train, .bus:
        var p = Pose()
        p.h = HeadPose(tilt: sin(s * 0.8) * 0.1, look: i == 0 ? 2.4 : sin(s * 1.2) * 3, eye: blink(s, 2.6))
        return p
    case .airplane, .boat:
        var p = Pose()
        let cock = sin(s * 1.6)
        p.h = HeadPose(tilt: cock * 0.3, ear: cock * 0.12, look: cock * 2.4, mouthOpen: 0.15, eye: blink(s, 2.2))
        return p
    case .atlas:
        var p = study(s, turn: sin(s * 0.7) * 0.5, flip: 0, eye: blink(s, 2.9))
        p.prop = .map
        return p
    }
}

private struct SceneState {
    var pose: Pose
    var beat: Int
    var u: CGFloat
    var progress: CGFloat
}

private func sceneState(_ scene: HwarangScene, _ sec: CGFloat) -> SceneState {
    let beats = scene.beats
    let total = scene.totalDuration
    let full = beats.reduce(CGFloat(0)) { $0 + $1.duration * $1.speed }
    var t = wrap(sec, total), i = 0
    var progress = (sec / total).rounded(.down) * full
    while t >= beats[i].duration, i < beats.count - 1 {
        t -= beats[i].duration
        progress += beats[i].duration * beats[i].speed
        i += 1
    }
    progress += t * beats[i].speed
    let u = clamp(t / beats[i].duration, 0, 1)
    var p = pose(scene, beat: i, s: sec, u: u)
    let fade: CGFloat = 0.45
    if t < fade, beats.count > 1 {
        let previous = pose(scene, beat: (i - 1 + beats.count) % beats.count, s: sec, u: 1)
        p = blend(previous, p, ease(t / fade))
    }
    return SceneState(pose: p, beat: i, u: u, progress: progress)
}

// MARK: - 그리기

private struct Blob { var x: CGFloat, y: CGFloat, r: CGFloat }

struct HwarangPainter {
    let c: CGContext
    let small: Bool
    var hatImage: UIImage?
    var lineScale: CGFloat = 1
    var toes: [CGPoint] = []

    func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        (CGFloat(hex >> 16 & 0xFF) / 255, CGFloat(hex >> 8 & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha)
    }
    func fill(_ hex: UInt32, _ alpha: CGFloat = 1) { let v = rgb(hex, alpha); c.setFillColor(red: v.0, green: v.1, blue: v.2, alpha: v.3) }
    func stroke(_ hex: UInt32, _ width: CGFloat, _ alpha: CGFloat = 1) { let v = rgb(hex, alpha); c.setStrokeColor(red: v.0, green: v.1, blue: v.2, alpha: v.3); c.setLineWidth(width) }
    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) { c.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)) }
    func oval(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) { c.addEllipse(in: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2)) }
    func quad(_ cx: CGFloat, _ cy: CGFloat, _ x: CGFloat, _ y: CGFloat) { c.addQuadCurve(to: P(x, y), control: P(cx, cy)) }
    func cubic(_ a: CGFloat, _ b: CGFloat, _ d: CGFloat, _ e: CGFloat, _ x: CGFloat, _ y: CGFloat) { c.addCurve(to: P(x, y), control1: P(a, b), control2: P(d, e)) }
    func poly(_ points: [CGPoint]) { c.beginPath(); c.addLines(between: points); c.closePath() }
    let outline: UInt32 = 0x5A4033
    let white: UInt32 = 0xFFFFFF
    private let farLimb: UInt32 = 0xEFE9E0

    private var outlineWidth: CGFloat { (small ? 3.3 : 2.2) * lineScale }

    private func addBlobs(_ list: [Blob], grow: CGFloat = 0) {
        for b in list { circle(b.x, b.y, b.r + grow) }
    }

    private func paint(_ list: [Blob], fillColor: UInt32) {
        fill(outline); c.beginPath(); addBlobs(list, grow: outlineWidth); c.fillPath()
        fill(fillColor); c.beginPath(); addBlobs(list); c.fillPath()
    }

    private mutating func drawToes() {
        stroke(outline, 1.1); c.setLineCap(.round); c.beginPath()
        for t in toes { for d: CGFloat in [-2.2, 1.2] { c.move(to: P(t.x + d + 1, t.y + 2)); c.addLine(to: P(t.x + d + 1, t.y - 1.4)) } }
        c.strokePath()
        toes = []
    }

    func ik(_ a: CGPoint, _ b: CGPoint, _ l1: CGFloat, _ l2: CGFloat, _ bend: CGFloat) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let raw = hypot(dx, dy), len = raw == 0 ? 1 : raw
        let d = clamp(len, 0.01, l1 + l2 - 0.01)
        let k = (l1 * l1 - l2 * l2 + d * d) / (2 * d)
        let h = sqrt(max(0, l1 * l1 - k * k))
        let ux = dx / len, uy = dy / len
        return P(a.x + ux * k - uy * h * bend, a.y + uy * k + ux * h * bend)
    }

    private func chain(_ list: inout [Blob], _ points: [CGPoint], _ radii: [CGFloat]) {
        let step: CGFloat = small ? 2.2 : 1.1
        for i in 0..<(points.count - 1) {
            let n = Int((hypot(points[i + 1].x - points[i].x, points[i + 1].y - points[i].y) / step).rounded(.up)) + 1
            for j in 0...n {
                let t = CGFloat(j) / CGFloat(n), q = lerp(points[i], points[i + 1], t)
                list.append(Blob(x: q.x, y: q.y, r: lerp(radii[i], radii[i + 1], t)))
            }
        }
    }

    func catmull(_ p: [CGPoint], seg: Int = 6) -> [CGPoint] {
        var o: [CGPoint] = []
        for i in 0..<(p.count - 1) {
            let a = p[max(i - 1, 0)], b = p[i], d = p[i + 1], e = p[min(i + 2, p.count - 1)]
            for j in 0..<seg {
                let t = CGFloat(j) / CGFloat(seg), t2 = t * t, t3 = t2 * t
                func f(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (3 * b - a - 3 * c + d) * t3)
                }
                o.append(P(f(a.x, b.x, d.x, e.x), f(a.y, b.y, d.y, e.y)))
            }
        }
        o.append(p[p.count - 1])
        return o
    }

    private mutating func hind(_ list: inout [Blob], _ hip: CGPoint, _ paw: CGPoint, _ bend: CGFloat) {
        let hock = P(paw.x - 3, paw.y - 5), knee = ik(hip, hock, 8, 6.5, bend)
        chain(&list, [hip, knee, hock, P(paw.x, paw.y - 3)], [11.5, 8.6, 6.4, 6])
        list.append(Blob(x: paw.x + 1.6, y: paw.y - 4, r: 6.4))
        toes.append(P(paw.x + 1.6, paw.y))
    }

    private mutating func fore(_ list: inout [Blob], _ sh: CGPoint, _ paw: CGPoint, _ bend: CGFloat) {
        let wrist = P(paw.x - 0.6, paw.y - 3.5), elbow = ik(sh, wrist, 6.5, 6.5, bend)
        chain(&list, [sh, elbow, wrist, P(paw.x, paw.y - 3)], [9, 7.6, 6.2, 6])
        list.append(Blob(x: paw.x + 1.6, y: paw.y - 4, r: 6.3))
        toes.append(P(paw.x + 1.6, paw.y))
    }

    private func tail(_ list: inout [Blob], _ base: CGPoint, _ angle: CGFloat, _ curl: CGFloat, _ amp: CGFloat, _ phase: CGFloat) {
        var x = base.x, y = base.y
        var points = [base], radii: [CGFloat] = [7.4]
        for i in 1...10 {
            let u = CGFloat(i) / 10, a = angle + curl * u + amp * u * sin(phase - CGFloat(i) * 0.55)
            x += cos(a) * 2.9; y += sin(a) * 2.9
            points.append(P(x, y)); radii.append(lerp(7.4, 6.2, u) + sin(u * .pi) * 0.8)
        }
        chain(&list, points, radii)
    }

    private func headPath() {
        c.beginPath(); c.move(to: P(-20, 3))
        cubic(-20, -11, -10, -15, 0, -15); cubic(10, -15, 20, -11, 20, 3)
        quad(22.5, 6, 20.2, 8); quad(21, 10.5, 18, 10.4)
        cubic(13, 14.5, 6, 15, 0, 15); cubic(-6, 15, -13, 14.5, -18, 10.4)
        quad(-21, 10.5, -20.2, 8); quad(-22.5, 6, -20, 3); c.closePath()
    }

    private func ear(_ side: CGFloat, _ t: CGFloat, _ twitch: CGFloat, _ lineWidth: CGFloat) {
        let ex = side < 0 ? lerp(-13, -11.5, t) : lerp(13, 14, t), sx = side < 0 ? 1 : lerp(1, 0.9, t)
        c.saveGState(); c.translateBy(x: ex, y: -10)
        c.rotate(by: lerp(side * 0.34, side < 0 ? -0.2 : 0.38, t) + (side > 0 ? twitch : 0))
        c.scaleBy(x: sx, y: 1)
        fill(white); stroke(outline, lineWidth)
        c.beginPath(); c.move(to: P(-6.5, 4)); quad(-4.5, -8, 0, -8.6); quad(4.5, -8, 6.5, 4); c.closePath(); c.drawPath(using: .fillStroke)
        fill(0xFFC9D4); c.beginPath(); c.move(to: P(-3.4, 2.6)); quad(-2.4, -4.8, 0, -5.2); quad(2.4, -4.8, 3.4, 2.6); c.closePath(); c.fillPath()
        c.restoreGState()
    }

    private func openEye(_ ex: CGFloat, _ ey: CGFloat, look: CGFloat, t: CGFloat) {
        fill(0x2474D6); stroke(outline, 1.2); c.beginPath(); oval(ex, ey, 5.9, 6.5); c.drawPath(using: .fillStroke)
        fill(0x74C6FF); c.beginPath(); oval(ex, ey + 3, 4.7, 3.1); c.fillPath()
        fill(0x10203A); c.beginPath(); oval(ex + look * 0.2 + t * 1.4, ey - 0.2, 3.7, 4.5); c.fillPath()
        fill(white); c.beginPath(); circle(ex - 1.8 + t, ey - 2.5, 2); circle(ex + 2 + t, ey + 1.8, 1); circle(ex + 1.9 + t, ey - 3, 0.6); c.fillPath()
    }

    func head(_ x: CGFloat, _ y: CGFloat, _ o: HeadPose) {
        let eye: Eye = o.eye == .open && o.blink ? .closed : o.eye
        let hs: CGFloat = small ? 1.72 : 1.5, t = clamp(o.turn, 0, 1), look = o.look
        c.saveGState(); c.translateBy(x: x, y: y); c.rotate(by: o.tilt); c.scaleBy(x: hs, y: hs)
        c.setLineJoin(.round); c.setLineCap(.round)
        let lineWidth = (small ? 3.3 : 2.2) / hs * lineScale
        ear(1, t, o.ear, lineWidth); ear(-1, t, o.ear, lineWidth)
        fill(white); stroke(outline, lineWidth); headPath(); c.drawPath(using: .fillStroke)
        if !small {
            stroke(outline, 1, 0.28); c.beginPath()
            let fx = lerp(0, 4, t)
            for dx: CGFloat in [-1.8, 1.8] { c.move(to: P(fx + dx, -14)); c.addLine(to: P(fx + dx, -10.5)) }
            c.strokePath()
        }
        fill(0xFF96AF, 0.5); c.beginPath(); oval(lerp(-14.6, -6.5, t) + look * 0.4, 8.6, 3.9, 2.4); oval(lerp(14.6, 17, t) + look * 0.4, 8.6, lerp(3.9, 2.6, t), 2.4); c.fillPath()
        for side: CGFloat in [-1, 1] {
            let ex = (side < 0 ? lerp(-10.2, -0.6, t) : lerp(10.2, 14.4, t)) + look, ey: CGFloat = 3, sx = side < 0 ? 1 : lerp(1, 0.8, t)
            c.saveGState(); c.translateBy(x: ex, y: ey); c.scaleBy(x: sx, y: 1); c.translateBy(x: -ex, y: -ey)
            switch eye {
            case .open: openEye(ex, ey, look: look, t: t)
            case .half:
                c.saveGState(); c.clip(to: CGRect(x: ex - 8, y: ey - 0.2, width: 16, height: 10)); openEye(ex, ey, look: look, t: t); c.restoreGState()
                stroke(outline, 1.7); c.beginPath(); c.move(to: P(ex - 6.2, ey - 0.2)); quad(ex, ey - 1.2, ex + 6.2, ey - 0.2); c.strokePath()
            case .happy:
                stroke(outline, 1.8); c.beginPath(); c.move(to: P(ex - 4.6, ey + 1.6)); quad(ex, ey - 4.2, ex + 4.6, ey + 1.6); c.strokePath()
            case .closed:
                stroke(outline, 1.8); c.beginPath(); c.move(to: P(ex - 4.6, ey)); quad(ex, ey + 4, ex + 4.6, ey); c.strokePath()
            }
            c.restoreGState()
        }
        let mx = lerp(look * 0.7, 7.4, t), my: CGFloat = 6.2
        fill(0xF2758F); c.beginPath(); c.move(to: P(mx - 1.3, my)); quad(mx, my - 0.5, mx + 1.3, my); quad(mx + 0.6, my + 1.5, mx, my + 1.5); quad(mx - 0.6, my + 1.5, mx - 1.3, my); c.fillPath()
        stroke(outline, 1.05)
        if o.mouthOpen > 0.05 {
            fill(0xE0637C); c.beginPath(); oval(mx, my + 3.3, 2.1, 0.8 + o.mouthOpen * 2); c.drawPath(using: .fillStroke)
        } else {
            c.beginPath(); c.move(to: P(mx - 2.4, my + 2)); quad(mx - 1.2, my + 3.6, mx, my + 2); quad(mx + 1.2, my + 3.6, mx + 2.4, my + 2); c.strokePath()
        }
        if o.tongue > 0.05 {
            // 작은 크기에서도 보이도록 입 너비보다 넓고 길게, 진한 분홍으로 내민다.
            let halfWidth: CGFloat = small ? 2.9 : 2.5, top = my + 2.6, length = 1.6 + o.tongue * 3.6
            let bottom = top + length
            func tongueEdge() {
                c.beginPath(); c.move(to: P(mx - halfWidth, top)); c.addLine(to: P(mx - halfWidth, bottom))
                cubic(mx - halfWidth, bottom + 3, mx + halfWidth, bottom + 3, mx + halfWidth, bottom); c.addLine(to: P(mx + halfWidth, top))
            }
            // 입에서 나오는 쪽은 선을 긋지 않아 뿌리가 입 안으로 이어져 보인다.
            fill(0xFF6E94); tongueEdge(); c.closePath(); c.fillPath()
            stroke(outline, 0.9); tongueEdge(); c.strokePath()
            stroke(0xE04E78, 0.6); c.beginPath(); c.move(to: P(mx, top + 0.8)); c.addLine(to: P(mx, bottom)); c.strokePath()
        }
        if !small {
            stroke(outline, 0.75); c.beginPath()
            for side: CGFloat in [-1, 1] {
                let a = side < 0 ? lerp(-19, -14, t) : lerp(19, 20, t), b = side < 0 ? lerp(-24, -20, t) : lerp(24, 26, t)
                c.move(to: P(a, 5.4)); c.addLine(to: P(b, 4.6)); c.move(to: P(a, 7.6)); c.addLine(to: P(b, 8.2))
            }
            c.strokePath()
        }
        if o.wet {
            // 물에 젖어 이마와 볼 털이 뾰족하게 뭉친다.
            fill(white); c.beginPath(); c.move(to: P(-10, -13)); c.addLine(to: P(-7, -19.5)); c.addLine(to: P(-3.6, -14)); c.addLine(to: P(0, -21)); c.addLine(to: P(3.6, -14)); c.addLine(to: P(7, -19.5)); c.addLine(to: P(10, -13)); c.closePath(); c.fillPath()
            stroke(outline, lineWidth); c.beginPath(); c.move(to: P(-10, -14)); c.addLine(to: P(-7, -19.5)); c.addLine(to: P(-3.6, -14)); c.addLine(to: P(0, -21)); c.addLine(to: P(3.6, -14)); c.addLine(to: P(7, -19.5)); c.addLine(to: P(10, -14))
            for side: CGFloat in [-1, 1] { c.move(to: P(side * 19, 1)); c.addLine(to: P(side * 25, 5)); c.addLine(to: P(side * 19.5, 6)); c.addLine(to: P(side * 24, 11)); c.addLine(to: P(side * 17, 11)) }
            c.strokePath()
        }
        if let hatImage {
            // 모자를 귀 사이 머리 위에 씌운다. 머리와 함께 기울고 돈다.
            let w: CGFloat = 32, h = w * 60 / 68
            UIGraphicsPushContext(c)
            hatImage.draw(in: CGRect(x: lerp(0, 3, t) - w / 2, y: -10.5 - h, width: w, height: h))
            UIGraphicsPopContext()
        }
        c.restoreGState()
    }

    private func mapBody(_ q: CGPoint) -> CGPoint { P(58 + (q.x - 58) * 0.88, groundY - (groundY - q.y) * 0.86) }
    private func mapPaw(_ q: CGPoint) -> CGPoint { P(58 + (q.x - 58) * 1.04, groundY - (groundY - q.y) * 0.86) }

    /// 몸·꼬리·앞다리를 한 윤곽으로 그린다. 윤곽을 먼저 그린 뒤 면을 덮어 안쪽 선을 없앤다.
    private func unionBody(_ body: () -> Void, parts: [Blob]) {
        let w = outlineWidth
        c.setLineJoin(.round); c.setLineCap(.round)
        stroke(outline, w * 2); body(); c.strokePath()
        fill(outline); c.beginPath(); addBlobs(parts, grow: w); c.fillPath()
        fill(white); body(); c.fillPath()
        c.beginPath(); addBlobs(parts); c.fillPath()
    }

    private mutating func deskCat(_ p: Pose) {
        let br = sin(p.tp * 0.9) * 0.7, top = 59 - br, tw = sin(p.tp * 0.8) * 2
        var parts: [Blob] = []
        let tailPoints = catmull([P(24, groundY - 5), P(10, groundY - 4), P(0, groundY - 5), P(-5, groundY - 12), P(-3, groundY - 20 + tw)])
        for (i, q) in tailPoints.enumerated() { parts.append(Blob(x: q.x, y: q.y, r: lerp(7, 6, CGFloat(i) / CGFloat(tailPoints.count - 1)))) }
        let sh = P(66, p.sh.y + 2)
        toes = []
        fore(&parts, P(sh.x + 4, sh.y), p.ffAbs, -1)
        fore(&parts, sh, p.fnAbs, -1)
        unionBody({
            c.beginPath(); c.move(to: P(20, groundY + 1))
            cubic(6, groundY + 1, 4, 86, 14, 75); cubic(22, top + 4, 38, top, 52, top)
            cubic(66, top, 78, 70, 78, 84); cubic(79, 94, 76, groundY + 1, 70, groundY + 1); c.closePath()
        }, parts: parts)
        drawToes()
        head(p.head.x + 1, groundY - (groundY - p.head.y) * 0.86 - 7, p.h)
    }

    private mutating func cat(_ raw: Pose) {
        if raw.desk { deskCat(raw); return }
        let hip = mapBody(raw.hip), mid = mapBody(raw.mid), sh = mapBody(raw.sh)
        let bn = mapPaw(raw.bn), bf = mapPaw(raw.bf), fn = mapPaw(raw.fn), ff = mapPaw(raw.ff)
        var headPoint = mapBody(raw.head)
        headPoint.x += raw.headX; headPoint.y -= raw.headY
        toes = []
        var far: [Blob] = []
        hind(&far, P(hip.x + 6, hip.y + 1), bf, raw.farHindBend ?? raw.hindBend)
        fore(&far, P(sh.x + 6, sh.y + 2), ff, raw.foreBend)
        paint(far, fillColor: farLimb)
        toes = []
        var near: [Blob] = []
        if raw.legUp >= 0.5 {
            // 뒷다리를 든 자세: 꼬리를 먼저 따로 그려 다리 윤곽이 꼬리 위로 살아나게 한다.
            var behind: [Blob] = []
            tail(&behind, P(hip.x - 7, hip.y - 3), raw.ta, raw.tc, raw.tw, raw.tp)
            paint(behind, fillColor: white)
        } else {
            tail(&near, P(hip.x - 7, hip.y - 3), raw.ta, raw.tc, raw.tw, raw.tp)
        }
        let spine = catmull([hip, mid, sh])
        for (i, q) in spine.enumerated() {
            let u = CGFloat(i) / CGFloat(spine.count - 1)
            near.append(Blob(x: q.x, y: q.y, r: lerp(raw.rh + 5, raw.rs + 4.4, u) + sin(u * .pi) * raw.rm))
        }
        if raw.flat > 0.5 {
            var x = hip.x - 8
            while x <= sh.x + 6 { near.append(Blob(x: x, y: groundY - 7, r: 7)); x += 2 }
        }
        if raw.legUp < 0.5 {
            hind(&near, hip, bn, raw.hindBend)
        } else {
            let root = P(hip.x - 2, hip.y - 2), knee = P(lerp(root.x, bn.x, 0.5) - 3, lerp(root.y, bn.y, 0.5))
            chain(&near, [root, knee, bn], [11.5, 8.4, 6.6])
            near.append(Blob(x: bn.x, y: bn.y - 1, r: 7.4))
        }
        if !raw.foreOver { fore(&near, sh, fn, raw.foreBend) }
        paint(near, fillColor: white)
        drawToes()
        // 가슴 털
        fill(0xFFF4E4); c.beginPath(); c.move(to: P(sh.x - 6, sh.y - 2)); quad(sh.x + 2, sh.y - 6, sh.x + 10, sh.y - 2)
        for q in [P(7, 6), P(4, 3), P(2, 9), P(-1, 3), P(-4, 6)] { c.addLine(to: P(sh.x + q.x, sh.y + q.y)) }
        c.closePath(); c.fillPath()
        if raw.legUp >= 0.5 {
            // 다리를 든 그루밍 자세에서 보이는 엉덩이 표시. 작은 X로 귀엽게 그린다.
            let mark = P(hip.x - 11, hip.y + 7)
            stroke(0xC9607E, 1.3); c.setLineCap(.round); c.beginPath()
            c.move(to: P(mark.x - 1.6, mark.y - 1.6)); c.addLine(to: P(mark.x + 1.6, mark.y + 1.6))
            c.move(to: P(mark.x + 1.6, mark.y - 1.6)); c.addLine(to: P(mark.x - 1.6, mark.y + 1.6)); c.strokePath()
            fill(0xFFB5C4); c.beginPath(); oval(bn.x + 0.6, bn.y + 0.6, 3.4, 2.8)
            let sp = 1 + raw.spread * 0.28
            for d in [P(-3.8, -2.8), P(-0.2, -4.4), P(3.6, -2.6)] { circle(bn.x + 0.6 + d.x * sp, bn.y + d.y * sp, 1.35 + raw.spread * 0.2) }
            c.fillPath()
        }
        head(headPoint.x, headPoint.y, raw.h)
        switch raw.prop {
        case .none: break
        case let .book(flip): book(flip)
        case .map: foldedMap()
        }
        if raw.foreOver {
            var top: [Blob] = []
            toes = []
            fore(&top, sh, fn, raw.foreBend)
            paint(top, fillColor: white)
            // 몸 위에 겹친 앞다리 윤곽을 지운다.
            c.saveGState(); c.beginPath(); addBlobs(near); c.clip()
            fill(white); c.beginPath(); addBlobs(top, grow: outlineWidth + 0.3); c.fillPath()
            c.restoreGState()
            drawToes()
        }
    }

    private mutating func loaf(_ p: Pose) {
        let br = p.breath, top = 62 - br * 1.2, tw = sin(p.tp * 1.1) * 2.4
        var parts: [Blob] = []
        let tailPoints = catmull([P(30, groundY - 5), P(14, groundY - 4), P(1, groundY - 5), P(-6, groundY - 13 + tw * 0.4), P(-3, groundY - 21 + tw)])
        for (i, q) in tailPoints.enumerated() { parts.append(Blob(x: q.x, y: q.y, r: lerp(7, 6, CGFloat(i) / CGFloat(tailPoints.count - 1)))) }
        let pawA = P(86, groundY - 2.5), pawB = P(97, groundY - 2.5)
        parts += [Blob(x: pawA.x, y: pawA.y, r: 5.8), Blob(x: pawA.x - 3, y: pawA.y - 1, r: 5.8), Blob(x: pawB.x, y: pawB.y, r: 5.6), Blob(x: pawB.x - 3, y: pawB.y - 1, r: 5.6)]
        unionBody({
            c.beginPath(); c.move(to: P(30, groundY + 1))
            cubic(16, groundY + 1, 14, 84, 24, 74); cubic(32, top + 2, 48, top, 62, top)
            cubic(80, top, 96, 70, 97, 86); cubic(98, 96, 96, groundY + 1, 88, groundY + 1); c.closePath()
        }, parts: parts)
        if !small {
            stroke(outline, 1.1); c.beginPath()
            for q in [pawA, pawB] { for d: CGFloat in [-1.4, 1.8] { c.move(to: P(q.x + d, q.y + 4)); c.addLine(to: P(q.x + d, q.y + 0.6)) } }
            c.strokePath()
        }
        var h = p.h
        if h.tilt == 0 { h.tilt = 0.03 }
        head(82, 68 + br * 0.6 + p.drop, h)
    }

    private func letterZ(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat, alpha: CGFloat) {
        stroke(0x5E78C4, max(1.4, size * 0.2), alpha); c.setLineJoin(.round); c.beginPath()
        c.addLines(between: [P(x, y - size), P(x + size * 0.7, y - size), P(x, y), P(x + size * 0.7, y)]); c.strokePath()
    }

    private func sleepLetters(_ sec: CGFloat) {
        let z = wrap(sec * 0.5, 1)
        letterZ(98 + z * 10, 48 - z * 16, 7 + z * 4, alpha: 1 - z)
        letterZ(110 + z * 8, 34 - z * 8, 8 + z * 4, alpha: max(0, 1 - abs(z - 0.5) * 2))
    }

    private func questionMark(_ sec: CGFloat) {
        let y = 16 + sin(sec * 2.2) * 3
        stroke(0x7A5FC6, 3.6); c.setLineCap(.round); c.beginPath()
        c.addArc(center: P(106, y), radius: 5.4, startAngle: .pi, endAngle: .pi * 0.4 + tau, clockwise: false)
        c.addLine(to: P(106, y + 11)); c.strokePath()
        fill(0x7A5FC6); c.beginPath(); circle(106, y + 16.5, 2.2); c.fillPath()
    }

    private func book(_ flip: CGFloat) {
        let cx = bookCenter, y0 = bookY, w = bookWidth
        c.setLineJoin(.round); c.setLineCap(.round)
        fill(0xC8473A); stroke(outline, 2.2); c.beginPath(); c.move(to: P(cx - w - 2, y0)); quad(cx, y0 + 4, cx + w + 2, y0); c.addLine(to: P(cx + w + 1, y0 - 4)); c.addLine(to: P(cx - w - 1, y0 - 4)); c.closePath(); c.drawPath(using: .fillStroke)
        for sign: CGFloat in [-1, 1] {
            fill(0xFFFDF4); stroke(outline, 2.2); c.beginPath(); c.move(to: P(cx, y0 - 2)); quad(cx + sign * w * 0.5, y0 - 20, cx + sign * w, y0 - 16); c.addLine(to: P(cx + sign * w, y0 - 3)); quad(cx + sign * w * 0.5, y0 - 6, cx, y0 - 2); c.closePath(); c.drawPath(using: .fillStroke)
        }
        stroke(0xBDB199, 1); c.beginPath()
        for (x0, x1) in [(cx - w + 3, cx - 3), (cx + 3, cx + w - 3)] {
            for i in 0..<4 { let yy = y0 - 1 - 3 - CGFloat(i) * 3.3; c.move(to: P(x0, yy)); c.addLine(to: P(lerp(x0, x1, i == 3 ? 0.6 : 1), yy)) }
        }
        c.strokePath()
        stroke(outline, 1.2, 0.35); c.beginPath(); c.move(to: P(cx, y0 - 2)); c.addLine(to: P(cx, y0 - 14)); c.strokePath()
        if flip > 0, flip < 1 {
            let a = flip * .pi, ex = cx + cos(a) * w, ey = y0 - 16 - sin(a) * 22, mx = cx + cos(a) * w * 0.55, my = y0 - 14 - sin(a) * 18 - abs(cos(a)) * 5
            fill(cos(a) > 0 ? 0xFFF3D6 : 0xFFFDF4); stroke(outline, 2.2); c.beginPath(); c.move(to: P(cx, y0 - 14)); quad(mx, my, ex, ey); c.addLine(to: P(ex, ey + 12)); quad(mx, my + 11, cx, y0 - 2); c.closePath(); c.drawPath(using: .fillStroke)
            stroke(0xBDB199, 0.9); c.beginPath()
            for t: CGFloat in [3, 6, 9] { c.move(to: P(lerp(cx, ex, 0.25), lerp(y0 - 14, ey, 0.3) + t)); c.addLine(to: P(lerp(cx, ex, 0.85), lerp(y0 - 14, ey, 0.85) + t)) }
            c.strokePath()
        }
    }

    private func yarn(_ x: CGFloat, _ y: CGFloat, _ rot: CGFloat) {
        fill(0xE96A8A); stroke(outline, 2.2); c.beginPath(); circle(x, y, 8); c.drawPath(using: .fillStroke)
        stroke(0xA83E5C, 1.1); c.beginPath(); c.addArc(center: P(x - 1, y), radius: 5, startAngle: 0.5 + rot, endAngle: 3 + rot, clockwise: false); c.strokePath()
        c.beginPath(); c.addArc(center: P(x + 1, y), radius: 5, startAngle: -1 + rot, endAngle: 1.5 + rot, clockwise: false); c.strokePath()
    }

    private func bowl() {
        fill(0xE46F7E); stroke(outline, 2.2); c.setLineJoin(.round); poly([P(82, 92), P(114, 92), P(109, groundY), P(87, groundY)]); c.drawPath(using: .fillStroke)
        fill(0x8B5A2B); c.beginPath(); oval(98, 91, 14, 3); c.drawPath(using: .fillStroke)
    }

    private func trees(_ offset: CGFloat) {
        fill(0xE9DFB9); c.fill(CGRect(x: -14, y: groundY - 2, width: 160, height: 26))
        stroke(0xB99B66, 2.2); c.setLineDash(phase: wrap(offset, 17), lengths: [9, 8]); c.beginPath(); c.move(to: P(-14, groundY + 6)); c.addLine(to: P(146, groundY + 6)); c.strokePath(); c.setLineDash(phase: 0, lengths: [])
        for i in 0..<5 {
            let x = wrap(CGFloat(i) * 62 - offset * 0.55, 310) - 40
            fill(0x8B5A2B); stroke(outline, 2.2); let trunk = CGRect(x: x - 2.5, y: 72, width: 5, height: 30); c.fill(trunk); c.stroke(trunk)
            fill(i % 2 == 1 ? 0x7FB069 : 0x5F9E4F); c.beginPath(); circle(x, 62, 14); circle(x - 9, 70, 9); circle(x + 9, 70, 9); c.drawPath(using: .fillStroke)
        }
        fill(0xA6C97F); c.beginPath()
        for i in 0..<7 { oval(wrap(CGFloat(i) * 44 - offset, 308) - 14, groundY + 1, 5, 2.2) }
        c.fillPath()
    }

    private func wheel(_ rotation: CGFloat) {
        let x = wheelCenter.x, y = wheelCenter.y, r = wheelRadius
        stroke(outline, 3); c.setLineCap(.round); c.beginPath(); c.addLines(between: [P(x - 20, y + r + 9), P(x, y), P(x + 20, y + r + 9)]); c.strokePath()
        c.saveGState(); c.translateBy(x: x, y: y); c.rotate(by: rotation)
        func ring(_ radius: CGFloat) { c.beginPath(); circle(0, 0, radius); c.strokePath() }
        stroke(0xC78A5B, 7); ring(r)
        stroke(outline, 1.5); ring(r + 3.5); ring(r - 3.5)
        stroke(0xD6AE85, 1.8); c.beginPath()
        for i in 0..<10 { let a = CGFloat(i) / 10 * tau; c.move(to: .zero); c.addLine(to: P(cos(a) * (r - 3.5), sin(a) * (r - 3.5))) }
        c.strokePath()
        stroke(0xA67449, 2); c.beginPath()
        for i in 0..<20 { let a = CGFloat(i) / 20 * tau; c.move(to: P(cos(a) * (r - 3), sin(a) * (r - 3))); c.addLine(to: P(cos(a) * (r + 3), sin(a) * (r + 3))) }
        c.strokePath()
        c.restoreGState()
        fill(0x8B5A2B); c.beginPath(); circle(x, y, 4); c.fillPath()
    }

    /// 화면이 보는 사람 쪽으로 비스듬히 돌아간 노트북. 힌지는 D-C, 키보드 면은 A-B-C-D.
    private func laptop(_ sec: CGFloat) {
        let a = P(66, groundY + 1), b = P(106, groundY + 4), cc = P(124, 94), d = P(88, 91), e = P(94, 58), f = P(130, 60)
        func q(_ u: CGFloat, _ v: CGFloat, _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGPoint { lerp(lerp(p0, p1, u), lerp(p3, p2, u), v) }
        func sc(_ u: CGFloat, _ v: CGFloat) -> CGPoint { q(0.05 + u * 0.9, 0.07 + v * 0.86, d, cc, f, e) }
        func deck(_ u: CGFloat, _ v: CGFloat) -> CGPoint { q(u, v, a, b, cc, d) }
        c.setLineJoin(.round); c.setLineCap(.round)
        fill(0x46525F); stroke(outline, 2.2); poly([d, cc, f, e]); c.drawPath(using: .fillStroke)
        fill(0x17243A); poly([sc(0, 0), sc(1, 0), sc(1, 1), sc(0, 1)]); c.fillPath()
        fill(0x2C3D59); poly([sc(0, 1), sc(1, 1), sc(1, 0.86), sc(0, 0.86)]); c.fillPath()
        for (i, color) in [UInt32(0xFF6F61), 0xF7C948, 0x5FD38D].enumerated() {
            let p = sc(0.06 + CGFloat(i) * 0.07, 0.93)
            fill(color); c.beginPath(); circle(p.x, p.y, 1.1); c.fillPath()
        }
        // 타자에 따라 늘어나는 코드 줄
        let colors: [UInt32] = [0x7CC4FF, 0xF2A7C3, 0xA6E3A1, 0xF7C948, 0xC2B4E9], widths: [CGFloat] = [0.62, 0.8, 0.44, 0.7, 0.54]
        let typing = wrap(sec * 0.22, 1)
        var caret: CGPoint?
        for i in 0..<5 {
            let v = 0.74 - CGFloat(i) * 0.145, progress = clamp((typing - CGFloat(i) / 5) * 5, 0, 1) * widths[i]
            if progress <= 0 { continue }
            let inset = 0.08 + CGFloat(i % 2) * 0.06, p0 = sc(inset, v), p1 = sc(inset + progress, v)
            stroke(colors[i], 1.5); c.beginPath(); c.move(to: p0); c.addLine(to: p1); c.strokePath()
            caret = p1
        }
        if let caret, wrap(sec * 2.4, 1) < 0.6 {
            stroke(white, 1.3); c.beginPath(); c.move(to: P(caret.x + 1.2, caret.y - 1.6)); c.addLine(to: P(caret.x + 1.2, caret.y + 1.6)); c.strokePath()
        }
        fill(0xD7DEE6); stroke(outline, 2.2); poly([a, b, cc, d]); c.drawPath(using: .fillStroke)
        fill(0x5D6B7A)
        for r in 0..<4 {
            for k in 0..<9 {
                let u0 = 0.08 + CGFloat(k) * 0.094, v0 = 0.42 + CGFloat(r) * 0.125
                poly([deck(u0, v0), deck(u0 + 0.075, v0), deck(u0 + 0.075, v0 + 0.09), deck(u0, v0 + 0.09)]); c.fillPath()
            }
        }
        fill(0xB9C3CE); stroke(0x8996A5, 0.9); poly([deck(0.36, 0.06), deck(0.66, 0.06), deck(0.66, 0.33), deck(0.36, 0.33)]); c.drawPath(using: .fillStroke)
    }

    private func yarnPosition(_ beat: Int, _ s: CGFloat, _ u: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        switch beat {
        case 1: return (102, groundY - 8 - sin(u * .pi) * 4, s * 0.5)
        case 2: return (104 + sin(s * 5) * 8, groundY - 8 - abs(sin(s * 5)) * 3, s * 5)
        case 3: return (lerp(112, 124, u), groundY - 8, s * 7)
        case 4: return (58 + sin(s * 6) * 3, 58 + cos(s * 6) * 2, s * 4)
        case 5: return (74, groundY - 8, 0)
        default: return (102, groundY - 8, s * 0.5)
        }
    }

    private func showerFixture() {
        stroke(outline, 5.6); c.setLineCap(.round); c.beginPath(); c.move(to: P(106, 66)); c.addLine(to: P(106, 8)); quad(106, 3, 100, 3); c.addLine(to: P(72, 3)); quad(67, 3, 67, 10); c.strokePath()
        stroke(0xC9D3DC, 2.2); c.beginPath(); c.move(to: P(106, 66)); c.addLine(to: P(106, 8)); quad(106, 3, 100, 3); c.addLine(to: P(72, 3)); quad(67, 3, 67, 10); c.strokePath()
        rounded(98, 62, 16, 7, 3, fillHex: 0xC9D3DC, line: 1.8)
        fill(0xC9D3DC); stroke(outline, 2.2); c.beginPath(); c.move(to: P(45, 19)); quad(67, 3, 89, 19); c.closePath(); c.drawPath(using: .fillStroke)
        fill(0x9FB0BD); stroke(outline, 2); c.beginPath(); oval(67, 19, 22, 3.6); c.drawPath(using: .fillStroke)
    }

    private func waterStreams(_ sec: CGFloat, xs: [CGFloat], alpha: CGFloat) {
        stroke(0x5DB7EA, 1.9, alpha); c.setLineCap(.round); c.setLineDash(phase: -sec * 70, lengths: [7, 6]); c.beginPath()
        for x in xs { c.move(to: P(x, 23)); c.addLine(to: P(67 + (x - 67) * 1.25, groundY - 2)) }
        c.strokePath(); c.setLineDash(phase: 0, lengths: [])
    }

    /// 젖은 털: 등과 가슴 윤곽에 뭉친 털끝을 세우고 물방울을 떨어뜨린다.
    private func wetFur(_ raw: Pose, sec: CGFloat, shaking: Bool) {
        let hip = mapBody(raw.hip), mid = mapBody(raw.mid), sh = mapBody(raw.sh)
        let spine = catmull([hip, mid, sh])
        c.setLineJoin(.round); c.setLineCap(.round)
        for side: CGFloat in [1, -1] {
            let first = side > 0 ? 2 : 6
            for i in stride(from: first, to: spine.count - 1, by: 3) {
                let u = CGFloat(i) / CGFloat(spine.count - 1), q = spine[i], next = spine[i + 1]
                let len = max(0.01, hypot(next.x - q.x, next.y - q.y))
                let nx = (next.y - q.y) / len * side, ny = -(next.x - q.x) / len * side
                let r = lerp(raw.rh + 5, raw.rs + 4.4, u) + sin(u * .pi) * raw.rm
                func at(_ d: CGFloat, _ along: CGFloat) -> CGPoint { P(q.x + nx * d + (next.x - q.x) / len * along, q.y + ny * d + (next.y - q.y) / len * along) }
                let a = at(r - 1.5, -3), tip = at(r + 5.5, -4.5), b = at(r - 1.5, 3)
                fill(white); poly([a, tip, b]); c.fillPath()
                stroke(outline, outlineWidth * 0.8); c.beginPath(); c.move(to: at(r, -3)); c.addLine(to: tip); c.addLine(to: at(r, 3)); c.strokePath()
            }
        }
        fill(0x8FD0F2); stroke(outline, 0.9)
        c.beginPath()
        for (i, x) in [CGFloat(34), 46, 62, 80, 88].enumerated() {
            let z = wrap(sec * 1.2 + CGFloat(i) * 0.23, 1)
            if shaking {
                let a = CGFloat(i) * 1.26 + 0.4
                oval(60 + cos(a) * (24 + z * 30), 66 + sin(a) * (20 + z * 24), 2, 2.4)
            } else {
                oval(x, 72 + z * (groundY - 74), 1.6, 2.6)
            }
        }
        c.drawPath(using: .fillStroke)
    }

    /// 로봇 청소기. x가 움직이면 옆 솔이 돌고 뒤에 먼지가 일어난다.
    private func vacuum(_ x: CGFloat, _ sec: CGFloat, dir: CGFloat) {
        fill(0x000000, 0.14); c.beginPath(); oval(x, groundY + 1, 42, 5); c.fillPath()
        fill(0x3A4048); stroke(outline, 2.2); c.beginPath(); oval(x, groundY - 5, 38, 8); c.drawPath(using: .fillStroke)
        c.beginPath(); c.addRect(CGRect(x: x - 38, y: groundY - 12, width: 76, height: 7)); fill(0x3A4048); c.fillPath()
        stroke(outline, 2.2); c.beginPath(); c.move(to: P(x - 38, groundY - 12)); c.addLine(to: P(x - 38, groundY - 5)); c.move(to: P(x + 38, groundY - 12)); c.addLine(to: P(x + 38, groundY - 5)); c.strokePath()
        fill(0x68727E); stroke(outline, 2.2); c.beginPath(); oval(x, groundY - 12, 38, 8); c.drawPath(using: .fillStroke)
        let on = wrap(sec, 1) < 0.5
        fill(on ? 0x62E08A : 0x2F8F54); stroke(outline, 1); c.beginPath(); circle(x + dir * 29, groundY - 12, 2.2); c.drawPath(using: .fillStroke)
        // 옆 솔
        let bx = x + dir * 33, by = groundY + 1
        stroke(outline, 1.3); c.beginPath()
        for i in 0..<3 { let a = sec * 16 + CGFloat(i) * tau / 3; c.move(to: P(bx, by)); c.addLine(to: P(bx + cos(a) * 7, by + sin(a) * 2.2)) }
        c.strokePath()
        // 먼지
        for i in 0..<3 {
            let z = wrap(sec * 0.9 + CGFloat(i) * 0.33, 1)
            fill(0xB9B2A4, 0.8 * (1 - z)); c.beginPath(); circle(x - dir * (40 + z * 14), groundY - 1 - z * 7, 2 + z * 2.4); c.fillPath()
        }
    }

    private func foldedMap() {
        let top: CGFloat = 78, bottom: CGFloat = 110
        let xs: [CGFloat] = [28, 46, 64, 82, 100]
        c.setLineJoin(.round); c.setLineCap(.round)
        for i in 0..<4 {
            let lift: CGFloat = i % 2 == 0 ? 0 : 4
            let next: CGFloat = i % 2 == 0 ? 4 : 0
            fill(i % 2 == 0 ? 0xFFFDF4 : 0xF3E8CC); stroke(outline, 2.2)
            poly([P(xs[i], top + lift), P(xs[i + 1], top + next), P(xs[i + 1], bottom + next), P(xs[i], bottom + lift)]); c.drawPath(using: .fillStroke)
        }
        fill(0xBFD9A0); c.beginPath(); oval(40, 94, 8, 6); oval(88, 100, 7, 5); c.fillPath()
        stroke(0xE96A8A, 1.8); c.setLineDash(phase: 0, lengths: [3, 3]); c.beginPath(); c.move(to: P(34, 104)); quad(52, 84, 66, 98); quad(78, 106, 92, 88); c.strokePath(); c.setLineDash(phase: 0, lengths: [])
    }

    private func pawprint(_ x: CGFloat, _ y: CGFloat, _ k: CGFloat, alpha: CGFloat, color: UInt32 = 0xF08DA6) {
        fill(color, alpha); c.beginPath(); oval(x, y + 2.4 * k, 4 * k, 3.2 * k)
        for d in [P(-4.2, -1.4), P(-1.4, -4), P(1.6, -4), P(4.4, -1.4)] { circle(x + d.x * k, y + d.y * k, 1.5 * k) }
        c.fillPath()
    }

    /// 세계 좌표(가로 146)로 장면 하나를 그린다.
    mutating func render(_ scene: HwarangScene, sec: CGFloat, facesLeft: Bool, showsBackdrop: Bool) {
        var st = sceneState(scene, sec)
        c.saveGState()
        if facesLeft { c.translateBy(x: 118, y: 0); c.scaleBy(x: -1, y: 1) }
        if scene != .sleep {
            // 머리·귀가 몸을 조금 늦게 따라오고, 내려앉을 때 살짝 눌린다.
            let dt: CGFloat = 0.09
            let previous = sceneState(scene, max(0, sec - dt)).pose
            let vy = (st.pose.hip.y - previous.hip.y) / dt, hv = (st.pose.head.y - previous.head.y) / dt
            st.pose.head = lerp(st.pose.head, previous.head, 0.55)
            st.pose.h.ear += clamp(hv * 0.012, -0.25, 0.25)
            st.pose.h.blink = wrap(sec * 0.29 + CGFloat(scene.beatCount) * 0.13, 1) < 0.035
            st.pose.squash = clamp(1 - abs(vy) * 0.0016 + (vy > 0 ? -0.012 : 0.012) * min(1, abs(vy) * 0.03), 0.9, 1.08)
        }
        if showsBackdrop, scene == .stroll { trees(st.progress) }
        if scene == .wheel { wheel(st.progress) }
        if scene == .work { laptop(sec) }
        if scene == .shower {
            fill(0xBFE3F2, 0.8); stroke(0x8FC6E2, 1.2); c.beginPath(); oval(62, groundY + 1, 46, 5); c.drawPath(using: .fillStroke)
            showerFixture()
            waterStreams(sec, xs: [50, 56, 62, 68, 74, 80, 86], alpha: 0.85)
        }
        let turn = cos(sec * 0.9), vacuumX = 58 + sin(sec * 0.9) * 14
        if scene == .robotVacuum { vacuum(vacuumX, sec, dir: turn >= 0 ? 1 : -1) }
        if scene == .bicycle { bicycle(sec, progress: st.progress) }
        switch scene {
        case .carFront: carFront(st.pose.h, sec: sec, progress: st.progress)
        case .subway: railTrain(st.pose.h, sec: sec, progress: st.progress, stripe: 0x2FA84F, pantograph: false)
        case .train: railTrain(st.pose.h, sec: sec, progress: st.progress, stripe: 0xC8473A, pantograph: true)
        case .bus: cityBus(st.pose.h, sec: sec, progress: st.progress)
        case .airplane: airplane(st.pose.h, sec: sec, progress: st.progress)
        case .boat: boat(st.pose.h, sec: sec, progress: st.progress)
        case .sleep:
            loaf(st.pose)
            sleepLetters(sec)
        default:
            let q = st.pose.squash
            c.saveGState()
            if scene == .bicycle {
                let k: CGFloat = 0.7
                lineScale = 1 / k
                c.translateBy(x: 58, y: groundY - 12); c.scaleBy(x: k, y: k); c.translateBy(x: -58, y: -groundY)
            }
            if scene == .robotVacuum {
                // 청소기 위에 앉아 가는 쪽으로 몸을 돌린다.
                let k: CGFloat = 0.86
                lineScale = 1 / k
                c.translateBy(x: vacuumX, y: groundY - 15); c.scaleBy(x: clamp(turn * 5, -1, 1) * k, y: k); c.translateBy(x: -62, y: -groundY)
            }
            if scene == .wheel {
                lineScale = 1 / wheelScale
                c.translateBy(x: wheelCenter.x, y: wheelGround); c.scaleBy(x: wheelScale, y: wheelScale); c.translateBy(x: -58, y: -groundY)
                st.pose.head.x -= 8
                st.pose.headX = 2
            }
            c.translateBy(x: 58, y: groundY); c.scaleBy(x: 1 / sqrt(q), y: q); c.translateBy(x: -58, y: -groundY)
            cat(st.pose)
            if scene == .shower { wetFur(st.pose, sec: sec, shaking: st.beat == 1) }
            c.restoreGState()
            lineScale = 1
        }
        switch scene {
        case .yarn:
            let y = yarnPosition(st.beat, sec, st.u)
            yarn(y.0, y.1, y.2)
        case .eat: bowl()
        case .confused: questionMark(sec)
        case .shower: waterStreams(sec, xs: [52, 64, 76, 84], alpha: 0.5)
        case .atlas:
            // 발자국이 하나씩 찍히며 걸어가고, 끝까지 가면 앞에서부터 사라진다.
            let cycle: CGFloat = 2.8, stepGap: CGFloat = 0.5
            let t = wrap(sec, cycle)
            for (i, q) in [P(94, 58), P(110, 44), P(122, 56), P(136, 40)].enumerated() {
                let age = t - CGFloat(i) * stepGap
                guard age > 0 else { continue }
                let fade = clamp((cycle - 0.5 - t) / 0.5, 0, 1)
                pawprint(q.x, q.y, 1.35, alpha: clamp(age / 0.12, 0, 1) * fade, color: 0xC2415E)
            }
        default: break
        }
        c.restoreGState()
    }
}

// MARK: - 화면

/// 장면 하나를 정한 시각으로 그린다. 발이 `anchorHeight` 틀의 바닥에 닿게 놓는다.
/// `width`는 세계 가로 146에 해당하는 폭이라 장면이 달라도 몸통 크기가 같다.
struct HwarangSceneView: View {
    let scene: HwarangScene
    let sec: Double
    let width: CGFloat
    var anchorHeight: CGFloat
    var facesLeft = false
    var hatAssetName: String? = nil
    var showsBackdrop = true
    /// 캣휠 안 화랑이도 다른 장면과 같은 몸통 크기로 그린다. 좁은 메뉴 칸에서는 끈다.
    var keepsBodySize = true

    static let worldWidth: CGFloat = 146
    static let worldHeight: CGFloat = 134
    /// 머리 위 모자가 잘리지 않게 위쪽에 남기는 세계 좌표 높이.
    static let hatHeadroom: CGFloat = 40

    var body: some View {
        let hat = hatAssetName.flatMap { UIImage(named: $0) }
        let small = width < 70
        let headroom = hat == nil ? 0 : Self.hatHeadroom
        let isWheel = scene == .wheel
        let scale = width / Self.worldWidth * (isWheel && keepsBodySize ? 1 / wheelScale : 1)
        let height = (Self.worldHeight + headroom) * scale
        let ground = ((isWheel ? wheelGround : groundY) + headroom - 8) * scale
        Canvas { context, size in
            context.withCGContext { cg in
                let k = size.width / Self.worldWidth
                cg.scaleBy(x: k, y: k)
                cg.translateBy(x: 14, y: headroom - 8)
                var painter = HwarangPainter(c: cg, small: small, hatImage: hat)
                painter.render(scene, sec: CGFloat(sec), facesLeft: facesLeft, showsBackdrop: showsBackdrop)
            }
        }
        .frame(width: Self.worldWidth * scale, height: height)
        .offset(y: anchorHeight / 2 - (ground - height / 2))
    }
}

enum HwarangDiagnostics {
    /// 시험용: 장면을 비트맵에 그려 칠해진 화소 수를 돌려준다.
    /// 장면 한 프레임을 그림으로 낸다. 자세 검토 시트를 만들 때 쓴다.
    static func frame(scene: HwarangScene, sec: Double, side: CGFloat = 438) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { renderer in
            let context = renderer.cgContext
            context.scaleBy(x: side / 146, y: side / 146)
            context.translateBy(x: 14, y: -8)
            var painter = HwarangPainter(c: context, small: false, hatImage: nil)
            painter.render(scene, sec: CGFloat(sec), facesLeft: false, showsBackdrop: false)
        }
    }

    static func paintedPixels(scene: HwarangScene, sec: Double, hat: String? = nil, side: Int = 146) -> Int {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        return pixels.withUnsafeMutableBytes { raw -> Int in
            guard let context = CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return 0 }
            context.translateBy(x: 14, y: -8)
            var painter = HwarangPainter(c: context, small: false, hatImage: hat.flatMap { UIImage(named: $0) })
            painter.render(scene, sec: CGFloat(sec), facesLeft: false, showsBackdrop: true)
            let bytes = raw.bindMemory(to: UInt8.self)
            return stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + (bytes[$1] > 0 ? 1 : 0) }
        }
    }
}
