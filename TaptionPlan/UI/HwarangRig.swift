import SwiftUI
import UIKit

/// 코드로 그리는 화랑이(RIG1101A01). 부품과 관절을 CoreGraphics로 그리고 장면마다 여러 동작을 이어 재생한다.
/// 위젯·워치는 기존 그림(`TaptionCatAtlasSprite`)을 그대로 쓴다.
enum HwarangScene: CaseIterable, Hashable, Sendable {
    case walkLoop, runLoop, walkLaptop
    case stroll, groom, work, study, yarn, sleep, eat, wheel, stretch, confused
    case shower, robotVacuum, carFront, subway, train, bus, bicycle, airplane, boat, atlas
    case sleepBelly, sleepEyeMask, recoverySuperman, medicated, restStarfish, restCroissant, restDonut, restLoaf, restBox
    case nap, cook, groceries, laundry, dishes, coffee, meeting, friends, date, family, phoneCall, meditate, hospital, salon, readBook, game, music, video, petCare

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
        case .sleepBelly, .sleepEyeMask, .recoverySuperman, .medicated, .restStarfish, .restCroissant, .restDonut, .restLoaf, .restBox, .walkLaptop, .nap, .cook, .groceries, .laundry, .dishes, .coffee, .meeting, .friends, .date, .family, .phoneCall, .meditate, .hospital, .salon, .readBook, .game, .music, .video, .petCare: [(6, 0)]
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

enum PoseProp {
    case none
    case book(flip: CGFloat)
    case map
    case laptop
}

struct Pose {
    var hip = CGPoint.zero, mid = CGPoint.zero, sh = CGPoint.zero, head = CGPoint.zero
    var bn = CGPoint.zero, bf = CGPoint.zero, fn = CGPoint.zero, ff = CGPoint.zero
    var headX: CGFloat = 8, headY: CGFloat = 9
    var rh: CGFloat = 11.6, rs: CGFloat = 9.8, rm: CGFloat = 1.6
    var hindBend: CGFloat = 1, farHindBend: CGFloat? = nil, foreBend: CGFloat = -1
    var ta: CGFloat = 0, tc: CGFloat = 0, tw: CGFloat = 0, tp: CGFloat = 0
    /// 꼬리 부풀림 정도와 터지는 선의 진행(1이면 사라짐).
    var tailPuff: CGFloat = 0, tailBurst: CGFloat = 1
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
let wheelCenter = CGPoint(x: 58, y: 62)
let wheelRadius: CGFloat = 48
let wheelGround: CGFloat = 106
let wheelScale: CGFloat = 0.76
let dozeCycle: CGFloat = 6
let deskTop: CGFloat = 86
let bookCenter: CGFloat = 66, bookY: CGFloat = groundY + 8, bookWidth: CGFloat = 34

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t)) }
func ease(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }
func clamp(_ v: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat { max(a, min(b, v)) }
func wrap(_ v: CGFloat, _ m: CGFloat) -> CGFloat { let r = v.truncatingRemainder(dividingBy: m); return r < 0 ? r + m : r }
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func blink(_ s: CGFloat, _ every: CGFloat = 3.1) -> Eye { wrap(s, every) < 0.14 ? .closed : .open }

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
    o.tailPuff = lerp(a.tailPuff, b.tailPuff, u); o.tailBurst = lerp(a.tailBurst, b.tailBurst, u)
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

func walk(_ s: CGFloat, period: CGFloat = 1.15, stride: CGFloat = 20) -> Pose {
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

func stand(_ s: CGFloat, _ h: HeadPose = HeadPose(look: 1.6)) -> Pose {
    let br = sin(s * tau / 2.4) * 0.5
    var p = Pose()
    p.headX = 3
    p.hip = P(40, 76); p.mid = P(54, 74 + br * 0.4); p.sh = P(68, 75 - br * 0.4); p.head = P(76, 56 - br * 0.5)
    p.bn = P(30, groundY); p.bf = P(46, groundY); p.fn = P(68, groundY); p.ff = P(84, groundY)
    p.ta = -2.2; p.tc = 0.9; p.tw = 0.3; p.tp = s * 2.2
    p.h = h
    return p
}

func sit(_ s: CGFloat, _ h: HeadPose = HeadPose(look: 1.4)) -> Pose {
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

/// 앉아서 뒷다리를 안테나처럼 머리보다 높이 들고, 몸을 둥글게 말아 엉덩이를 핥는 자세. k: 다리 올림, d: 머리 숙임.
private func lick(_ s: CGFloat, k: CGFloat, d: CGFloat, _ h: HeadPose, spread: CGFloat = 0, shake: CGFloat = 0, along: CGFloat = 0, tw: CGFloat = 0.25) -> Pose {
    let up = ease(clamp(k * 1.6, 0, 1)), jitter = shake * sin(s * 30)
    var p = sit(s)
    p.flat = k; p.legUp = k; p.spread = spread
    p.hip = P(lerp(50, 46, k), lerp(88, 84, k)); p.mid = P(lerp(56, 68, k), lerp(76, 64, k)); p.sh = P(lerp(62, 86, k), lerp(67, 82, k))
    p.rh = lerp(13, 12, k); p.rs = lerp(9.5, 12, k); p.rm = lerp(1, 6, k)
    p.bn = P(lerp(56, 34, up) + jitter, lerp(groundY, 8 + sin(s * 3) * 1.2, up))
    // 가까운 앞다리는 얼굴 왼쪽 아래에서 바깥 바닥으로 뻗어 몸을 받치고, 먼 앞다리는 턱 밑을 짚는다.
    // 든 다리 반대쪽 뒷다리는 바닥을 따라 앞으로 뻗는다.
    p.bf = P(lerp(62, 110, k), groundY)
    p.fn = P(lerp(69, 0.5, k), groundY); p.ff = P(lerp(76, 84, k), groundY)
    p.head = P(lerp(66, lerp(70, lerp(55, 50, along), d), k), lerp(48, lerp(58, lerp(74, 62, along), d), k))
    p.headX = lerp(2, 0, k); p.headY = lerp(6, 0, k)
    p.ta = lerp(3.25, 2.7, k); p.tc = lerp(-0.95, 0.35, k); p.tw = tw; p.tp = s * 2.2
    p.h = h
    p.h.tilt = h.tilt != 0 ? h.tilt : k * d * lerp(1, 0.55, along)
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

/// 조는 정도(0: 고개 든 상태, 1: 끝까지 떨군 상태). 천천히 떨어졌다 순식간에 들려 살짝 젖혔다 돌아온다.
func dozeDroop(_ s: CGFloat) -> CGFloat {
    let t = wrap(s, dozeCycle)
    switch t {
    case ..<0.5: return 0
    case ..<4.7: return ease((t - 0.5) / 4.2)
    case ..<5.1: return 1
    case ..<5.3: return lerp(1, -0.14, ease((t - 5.1) / 0.2))
    default: return lerp(-0.14, 0, ease((t - 5.3) / 0.7))
    }
}

/// 책상 앞에 앉아 모니터를 보며 존다. 눈은 반쯤 감겼다 감기고, 깜짝 깰 때만 뜬다.
private func dozing(_ s: CGFloat) -> Pose {
    let droop = dozeDroop(s), t = wrap(s, dozeCycle)
    let eye: Eye = t >= 5.1 ? .open : (droop < 0.55 ? .half : .closed)
    var p = desk(s, 0, 0, HeadPose(tilt: 0.05 + droop * 0.3, ear: -droop * 0.1, mouthOpen: droop > 0.8 ? 0.12 : 0, turn: 1, eye: eye))
    p.tp = s * 0.9
    p.sh = P(62, 84 + droop * 3)
    p.head = P(58 + droop * 5, 58 + droop * 15)
    p.fnAbs = P(88, deskTop); p.ffAbs = P(100, deskTop)
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

/// 기분 좋을 때 꼬리가 팡 부풀었다 가라앉는다. `t`는 박자 시작 뒤 초로, 앞 박자와 섞이는 동안은 기다린다.
private func tailPop(_ pose: Pose, t: CGFloat) -> Pose {
    let t = t - 0.45
    guard t > 0 else { return pose }
    var p = pose
    let rise = ease(clamp(t / 0.13, 0, 1)), settle = 1 - ease(clamp((t - 0.45) / 0.6, 0, 1))
    let up = rise * settle
    p.tailPuff = up * (1 + 0.2 * sin(clamp(t / 0.4, 0, 1) * .pi))
    p.tailBurst = clamp(t / 0.34, 0, 1)
    // 부푸는 동안 꼬리를 뒤로 치켜들어 머리에 가리지 않게 한다.
    p.ta += remainder(-2.6 - p.ta, tau) * up
    p.tc = lerp(p.tc, 0.7, up); p.tw = lerp(p.tw, 0.1, up)
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
        case 1: return lick(s, k: ease(clamp(u * 1.5, 0, 1)), d: 0, HeadPose(look: -1, mouthOpen: u * 0.3, tongue: u), spread: u)
        case 2:
            let v = (sin(s * 3.2) + 1) / 2, m = (sin(s * 11) + 1) / 2
            return lick(s, k: 1, d: 1 - m * 0.1, HeadPose(ear: sin(s * 2) * 0.08, look: 1, mouthOpen: 0.4, tongue: 1 + m * 0.8, eye: .closed), along: v, tw: 0.3)
        case 3: return lick(s, k: 1, d: 1 - l * 0.12, HeadPose(look: 1, mouthOpen: 0.4, tongue: 1 + l * 0.8, eye: .closed), tw: 0.35)
        case 4: return lick(s, k: 1, d: 0.05, HeadPose(ear: sin(s * 6) * 0.15, look: 1, mouthOpen: 0.3, tongue: 1.3, eye: wrap(s, 1.2) < 0.12 ? .closed : .open), tw: 0.15)
        case 5: return lick(s, k: 1, d: 0.2, HeadPose(look: 1, mouthOpen: 0.3, tongue: 1, eye: .closed), spread: 1, shake: 2.6)
        case 6: return lick(s, k: 1, d: 1 - l * 0.12, HeadPose(look: 1, mouthOpen: 0.4, tongue: 1 + l * 0.8, eye: .closed))
        case 7: return lick(s, k: 1 - ease(u), d: 0, HeadPose(look: 1, mouthOpen: 0.3, tongue: 1, eye: .happy))
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
        default: return tailPop(sit(s, HeadPose(tilt: sin(s * 3) * 0.06, look: 1.4, eye: .happy)), t: u * scene.beats[i].duration)
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
        case 0, 3:
            // 입을 크게 벌리며 고개를 숙이고, 다물며 든다.
            let bite = max(0, sin(s * 8))
            return eating(s, dip: 0.86 + bite * 0.14, HeadPose(tilt: 0.2, look: 1.6, mouthOpen: bite * 1.1, eye: .happy))
        case 1: return eating(s, dip: 0, HeadPose(look: 1.6, mouthOpen: max(0, sin(s * 10)) * 0.9, eye: .happy))
        case 2: return eating(s, dip: 0, HeadPose(tilt: 0.06, look: 1.6, tongue: (sin(s * 8) + 1) * 0.45, eye: .happy))
        default: return tailPop(sit(s, HeadPose(look: 1.4, tongue: 0.2, eye: .happy)), t: u * scene.beats[i].duration)
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
        default: return tailPop(stand(s, HeadPose(look: 1.6, mouthOpen: 0.5 + sin(s * 14) * 0.3, tongue: 0.5, eye: .happy)), t: u * scene.beats[i].duration)
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
    case .restCroissant:
        return dozing(s)
    case .sleepBelly, .sleepEyeMask, .recoverySuperman, .medicated, .restStarfish, .restDonut, .restLoaf, .restBox, .walkLaptop, .nap, .cook, .groceries, .laundry, .dishes, .coffee, .meeting, .friends, .date, .family, .phoneCall, .meditate, .hospital, .salon, .readBook, .game, .music, .video, .petCare:
        return dailyPose(scene, s: s)
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

struct Blob { var x: CGFloat, y: CGFloat, r: CGFloat }

struct HwarangPainter {
    let c: CGContext
    let small: Bool
    var hatImage: UIImage?
    var scarf: HwarangClothStyle? = nil, ribbon: HwarangClothStyle? = nil
    var lineScale: CGFloat = 1
    var toes: [CGPoint] = []
    /// 스카프 끝이 따라올 지난 머리 속도(최근 것부터)와 달리는 바람, 펄럭임 위상.
    var scarfSwing: [CGVector] = []
    var scarfWind: CGFloat = 0, scarfPhase: CGFloat = 0
    /// 잠금화면 그림을 설정한 털색으로 뽑을 때만 바꾼다. 앱 화면은 늘 흰 화랑이다.
    var coat: HwarangCoat = .white

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
    var outline: UInt32 { coat.outline }
    let white: UInt32 = 0xFFFFFF
    private var farLimb: UInt32 { coat.far }

    var outlineWidth: CGFloat { (small ? 3.3 : 2.2) * lineScale }

    private func addBlobs(_ list: [Blob], grow: CGFloat = 0) {
        for b in list { circle(b.x, b.y, b.r + grow) }
    }

    private func paint(_ list: [Blob], fillColor: UInt32) {
        fill(outline); c.beginPath(); addBlobs(list, grow: outlineWidth); c.fillPath()
        fill(fillColor); c.beginPath(); addBlobs(list); c.fillPath()
    }

    private mutating func drawToes() {
        stroke(outline, 1.1); c.setLineCap(.round); c.beginPath()
        paintSocks()
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

    /// 꼬리 마디를 덧붙이고 중심선을 돌려준다. 리본이 이 선 위에 묶인다.
    @discardableResult
    private func tail(_ list: inout [Blob], _ base: CGPoint, _ angle: CGFloat, _ curl: CGFloat, _ amp: CGFloat, _ phase: CGFloat, puff: CGFloat = 0) -> [CGPoint] {
        var x = base.x, y = base.y
        var points = [base], radii: [CGFloat] = [7.4]
        for i in 1...10 {
            let u = CGFloat(i) / 10, a = angle + curl * u + amp * u * sin(phase - CGFloat(i) * 0.55)
            x += cos(a) * 2.9; y += sin(a) * 2.9
            points.append(P(x, y)); radii.append(lerp(7.4, 6.2, u) + sin(u * .pi) * 0.8 + Self.tailGrowth(u, puff))
        }
        chain(&list, points, radii)
        if puff > 0.05 {
            // 곤두선 털: 윤곽 양옆에 작은 덩이를 번갈아 붙여 들쭉날쭉하게 만든다.
            for i in 4..<points.count {
                let a = points[i - 1], b = points[i], length = max(hypot(b.x - a.x, b.y - a.y), 0.01)
                let side: CGFloat = i % 2 == 0 ? 1 : -1, reach = radii[i] + 0.4
                for flip: CGFloat in [side, -side * 0.9] {
                    list.append(Blob(x: b.x - (b.y - a.y) / length * reach * flip, y: b.y + (b.x - a.x) / length * reach * flip, r: 2.7 * min(puff, 1)))
                }
            }
        }
        return points
    }

    /// 부푼 꼬리가 굵어지는 양. 뿌리는 그대로 두고 끝 쪽을 굵게 해 몸통과 뭉치지 않는다. 리본도 이 굵기를 따른다.
    private static func tailGrowth(_ u: CGFloat, _ puff: CGFloat) -> CGFloat {
        let swell = sin(min(u * 1.15, 1) * .pi / 2)
        return puff * 7 * swell * swell
    }

    /// 꼬리가 터지듯 부풀 때 끝 둘레로 잠깐 튀는 짧은 선.
    private func tailBurstLines(around tip: CGPoint, radius: CGFloat, progress: CGFloat) {
        guard progress < 1 else { return }
        stroke(0xF7B23B, 1.9, 1 - progress * progress); c.setLineCap(.round); c.beginPath()
        for i in 0..<7 {
            let a = -CGFloat.pi * 1.25 + CGFloat(i) * 0.5, near = radius + 3 + progress * 7, far = near + 4.5 - progress * 2.5
            c.move(to: P(tip.x + cos(a) * near, tip.y + sin(a) * near)); c.addLine(to: P(tip.x + cos(a) * far, tip.y + sin(a) * far))
        }
        c.strokePath()
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
        fill(coat.fur); stroke(outline, lineWidth)
        c.beginPath(); c.move(to: P(-6.5, 4)); quad(-4.5, -8, 0, -8.6); quad(4.5, -8, 6.5, 4); c.closePath(); c.drawPath(using: .fillStroke)
        fill(0xFFC9D4); c.beginPath(); c.move(to: P(-3.4, 2.6)); quad(-2.4, -4.8, 0, -5.2); quad(2.4, -4.8, 3.4, 2.6); c.closePath(); c.fillPath()
        c.restoreGState()
    }

    private func openEye(_ ex: CGFloat, _ ey: CGFloat, look: CGFloat, t: CGFloat) {
        fill(coat.iris); stroke(outline, 1.2); c.beginPath(); oval(ex, ey, 5.9, 6.5); c.drawPath(using: .fillStroke)
        fill(coat.irisLight); c.beginPath(); oval(ex, ey + 3, 4.7, 3.1); c.fillPath()
        fill(0x10203A); c.beginPath(); oval(ex + look * 0.2 + t * 1.4, ey - 0.2, 3.7, 4.5); c.fillPath()
        fill(white); c.beginPath(); circle(ex - 1.8 + t, ey - 2.5, 2); circle(ex + 2 + t, ey + 1.8, 1); circle(ex + 1.9 + t, ey - 3, 0.6); c.fillPath()
    }

    func head(_ x: CGFloat, _ y: CGFloat, _ o: HeadPose) {
        let eye: Eye = o.eye == .open && o.blink ? .closed : o.eye
        let hs: CGFloat = small ? 1.72 : 1.5, t = clamp(o.turn, 0, 1), look = o.look
        c.saveGState(); c.translateBy(x: x, y: y); c.rotate(by: o.tilt + coat.headTilt); c.scaleBy(x: hs, y: hs)
        c.setLineJoin(.round); c.setLineCap(.round)
        let lineWidth = (small ? 3.3 : 2.2) / hs * lineScale
        ear(1, t, o.ear, lineWidth); ear(-1, t, o.ear, lineWidth)
        fill(coat.fur); stroke(outline, lineWidth); headPath(); c.drawPath(using: .fillStroke)
        paintPatches(coat.headPatches) { headPath() }
        if !coat.headPatches.isEmpty { stroke(outline, lineWidth); headPath(); c.strokePath() }
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
            if coat.lashes { lashes(side: side, ex: ex, ey: ey, eye: eye) }
            c.restoreGState()
        }
        let mx = lerp(look * 0.7, 7.4, t), my: CGFloat = 6.2
        fill(0xF2758F); c.beginPath(); c.move(to: P(mx - 1.3, my)); quad(mx, my - 0.5, mx + 1.3, my); quad(mx + 0.6, my + 1.5, mx, my + 1.5); quad(mx - 0.6, my + 1.5, mx - 1.3, my); c.fillPath()
        stroke(outline, 1.05)
        if o.mouthOpen > 0.05 {
            // 위턱을 코 밑에 두고 아래로만 벌린다.
            let ry = 0.8 + o.mouthOpen * 2
            fill(0xE0637C); c.beginPath(); oval(mx, my + 1.6 + ry, 2.1 + o.mouthOpen * 0.7, ry); c.drawPath(using: .fillStroke)
        } else {
            c.beginPath(); c.move(to: P(mx - 2.4, my + 2)); quad(mx - 1.2, my + 3.6, mx, my + 2); quad(mx + 1.2, my + 3.6, mx + 2.4, my + 2); c.strokePath()
        }
        if o.tongue > 0.05 {
            // 작은 크기에서도 보이도록 입 너비보다 넓고 길게, 진한 분홍으로 내민다.
            let halfWidth: CGFloat = (small ? 2.9 : 2.5) + max(0, o.tongue - 1) * 0.8, top = my + 2.6, length = 1.6 + o.tongue * 3.6
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
            fill(coat.fur); c.beginPath(); c.move(to: P(-10, -13)); c.addLine(to: P(-7, -19.5)); c.addLine(to: P(-3.6, -14)); c.addLine(to: P(0, -21)); c.addLine(to: P(3.6, -14)); c.addLine(to: P(7, -19.5)); c.addLine(to: P(10, -13)); c.closePath(); c.fillPath()
            stroke(outline, lineWidth); c.beginPath(); c.move(to: P(-10, -14)); c.addLine(to: P(-7, -19.5)); c.addLine(to: P(-3.6, -14)); c.addLine(to: P(0, -21)); c.addLine(to: P(3.6, -14)); c.addLine(to: P(7, -19.5)); c.addLine(to: P(10, -14))
            for side: CGFloat in [-1, 1] { c.move(to: P(side * 19, 1)); c.addLine(to: P(side * 25, 5)); c.addLine(to: P(side * 19.5, 6)); c.addLine(to: P(side * 24, 11)); c.addLine(to: P(side * 17, 11)) }
            c.strokePath()
        }
        if let bow = coat.bow { bow_(bow, lineWidth: lineWidth) }
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
    func unionBody(_ body: () -> Void, parts: [Blob]) {
        let w = outlineWidth
        c.setLineJoin(.round); c.setLineCap(.round)
        let slim = CGAffineTransform(translationX: 0, y: groundY).scaledBy(x: 1, y: coat.bodyHeight).translatedBy(x: 0, y: -groundY)
        func shaped() { c.concatenate(slim); body(); c.concatenate(slim.inverted()) }
        stroke(outline, w * 2); shaped(); c.strokePath()
        fill(outline); c.beginPath(); addBlobs(parts, grow: w); c.fillPath()
        fill(coat.fur); shaped(); c.fillPath()
        c.beginPath(); addBlobs(parts); c.fillPath()
        paintPatches(coat.bodyPatches) { shaped() }
    }

    /// 엎드린 자세의 꼬리 끝은 캔버스 왼쪽 끝에 가까워 리본을 뿌리 쪽으로 옮겨 잘리지 않게 한다.
    static let canvasEdgeRibbonAlong: CGFloat = 0.42

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
        if let ribbon { drawTailRibbon(ribbon, tail: tailPoints, radius: 6.3, sway: 0.25, phase: p.tp * 0.8, along: Self.canvasEdgeRibbonAlong) }
        let headPoint = P(p.head.x + 1, groundY - (groundY - p.head.y) * 0.86 - 7)
        paintChest(head: headPoint, shoulder: P(54, sh.y + 4))
        if let scarf {
            // 책상 앞 화랑이는 머리가 몸 위에 얹혀 있어 어깨 대신 몸통 윗부분을 향한다.
            drawScarf(scarf, neck: HwarangNeck(head: headPoint, shoulder: P(54, sh.y + 4), tilt: p.h.tilt), swing: scarfSwing, wind: 0, phase: scarfPhase)
        }
        head(headPoint.x, headPoint.y, p.h)
    }

    /// 그루밍 때 몸 앞으로 나온 반대쪽 뒷발. 뿌리는 몸 안으로 사라진다.
    private mutating func tuckedFoot(_ paw: CGPoint) {
        var foot: [Blob] = []
        let root = P(paw.x - 36, paw.y - 6)
        chain(&foot, [root, P(paw.x - 8, paw.y - 5), P(paw.x + 1, paw.y - 4.5)], [4.6, 5.2, 5.6])
        paint(foot, fillColor: coat.fur)
        fill(coat.fur); c.beginPath(); circle(root.x - 1, root.y, 4.6 + outlineWidth + 0.4); c.fillPath()
        fill(0xFFB5C4); c.beginPath(); oval(paw.x + 2.6, paw.y - 4.4, 2.2, 2.6); c.fillPath()
    }

    /// 그루밍 때 바닥을 짚어 몸을 받치는 앞다리. 뒷발 위로 겹치고 윗부분은 몸 안으로 사라진다.
    private mutating func plantedForeleg(_ paw: CGPoint, from top: CGPoint) {
        var leg: [Blob] = []
        chain(&leg, [top, P(lerp(top.x, paw.x, 0.65), lerp(top.y, paw.y - 4.5, 0.65)), P(paw.x, paw.y - 4.5)], [5, 5.2, 6])
        paint(leg, fillColor: coat.fur)
        fill(coat.fur); c.beginPath(); circle(top.x, top.y - 1, 5 + outlineWidth + 0.4); c.fillPath()
        toes = [P(paw.x, paw.y)]
        drawToes()
    }

    /// 그루밍 때 꼬리. 엉덩이 밑에서 내려와 몸 앞 바닥을 따라 앞으로 돌아온다. 중심선을 돌려줘 리본이 그 위에 묶인다.
    private func forwardTail(phase: CGFloat) -> [CGPoint] {
        // 끝으로 갈수록 크게, 조금 늦게 따라오며 좌우로 살랑인다.
        let sway = sin(phase * 2), lag = sin(phase * 2 - 0.9)
        let line = catmull([P(35, 99), P(29, 106), P(40, 111), P(60 + lag * 1.5, 112), P(78 + lag * 4, 111 + sway), P(90 + sway * 9, 107 - abs(sway) * 2)])
        var parts: [Blob] = []
        for (i, q) in line.enumerated() { parts.append(Blob(x: q.x, y: q.y, r: lerp(6.4, 5, CGFloat(i) / CGFloat(line.count - 1)))) }
        paint(parts, fillColor: coat.fur)
        // 뿌리의 윤곽을 지워 몸과 한 덩어리로 잇는다.
        fill(coat.fur); c.beginPath(); circle(38, 96, 6.4 + outlineWidth); c.fillPath()
        return line
    }

    func headAnchor(_ raw: Pose) -> CGPoint {
        let q = mapBody(raw.head)
        return P(q.x + raw.headX, q.y - raw.headY)
    }

    mutating func cat(_ raw: Pose) {
        if raw.desk { deskCat(raw); return }
        let hip = mapBody(raw.hip), mid = mapBody(raw.mid), sh = mapBody(raw.sh)
        let bn = mapPaw(raw.bn), bf = mapPaw(raw.bf), fn = mapPaw(raw.fn), ff = mapPaw(raw.ff)
        let headPoint = headAnchor(raw)
        toes = []
        var far: [Blob] = []
        if raw.legUp < 0.5 { hind(&far, P(hip.x + 6, hip.y + 1), bf, raw.farHindBend ?? raw.hindBend) }
        if raw.legUp < 0.5 { fore(&far, P(sh.x + 6, sh.y + 2), ff, raw.foreBend) }
        paint(far, fillColor: farLimb)
        toes = []
        var near: [Blob] = []
        var tailLine: [CGPoint]
        if raw.legUp >= 0.5 {
            // 뒷다리를 든 자세의 꼬리는 몸을 그린 뒤 앞쪽 바닥으로 돌려 그린다.
            tailLine = []
        } else {
            tailLine = tail(&near, P(hip.x - 7, hip.y - 3), raw.ta, raw.tc, raw.tw, raw.tp, puff: raw.tailPuff)
        }
        let spine = catmull([hip, mid, sh])
        for (i, q) in spine.enumerated() {
            let u = CGFloat(i) / CGFloat(spine.count - 1)
            near.append(Blob(x: q.x, y: q.y, r: lerp(raw.rh + 5, raw.rs + 4.4, u) + sin(u * .pi) * raw.rm))
        }
        if raw.flat > 0.5 {
            var x = hip.x
            while x <= sh.x + 6 { near.append(Blob(x: x, y: groundY - 7, r: 7)); x += 2 }
        }
        if raw.legUp < 0.5 {
            hind(&near, hip, bn, raw.hindBend)
        } else {
            let root = P(hip.x - 2, hip.y - 2), knee = P(lerp(root.x, bn.x, 0.5) - 1, lerp(root.y, bn.y, 0.5))
            chain(&near, [root, knee, bn], [11.5, 8.4, 6.6])
            near.append(Blob(x: bn.x, y: bn.y - 1, r: 7.4))
        }
        if !raw.foreOver, raw.legUp < 0.5 { fore(&near, sh, fn, raw.foreBend) }
        paint(near, fillColor: coat.fur)
        drawToes()
        if raw.legUp >= 0.5 {
            tuckedFoot(bf)
            plantedForeleg(ff, from: P(ff.x - 3, groundY - 24))
            tailLine = forwardTail(phase: raw.tp)
            plantedForeleg(fn, from: P(hip.x - 5, hip.y - 3))
        }
        if raw.tailPuff > 0.05, let tip = tailLine.last { tailBurstLines(around: tip, radius: 6.2 + Self.tailGrowth(1, raw.tailPuff), progress: raw.tailBurst) }
        if let ribbon, !tailLine.isEmpty { drawTailRibbon(ribbon, tail: tailLine, radius: 6.6 + Self.tailGrowth(0.74, raw.tailPuff), sway: raw.tw, phase: raw.tp, along: raw.legUp >= 0.5 ? 0.88 : 0.74) }
        // 가슴 털
        if raw.legUp < 0.5 {
            fill(0xFFF4E4); c.beginPath(); c.move(to: P(sh.x - 6, sh.y - 2)); quad(sh.x + 2, sh.y - 6, sh.x + 10, sh.y - 2)
            for q in [P(7, 6), P(4, 3), P(2, 9), P(-1, 3), P(-4, 6)] { c.addLine(to: P(sh.x + q.x, sh.y + q.y)) }
            c.closePath(); c.fillPath()
        }
        if raw.legUp >= 0.5 {
            // 다리를 든 그루밍 자세에서 보이는 엉덩이 표시. 작은 X로 귀엽게 그린다.
            let mark = P(hip.x - 8, hip.y + 9)
            stroke(0xC9607E, 1.3); c.setLineCap(.round); c.beginPath()
            c.move(to: P(mark.x - 1.6, mark.y - 1.6)); c.addLine(to: P(mark.x + 1.6, mark.y + 1.6))
            c.move(to: P(mark.x + 1.6, mark.y - 1.6)); c.addLine(to: P(mark.x - 1.6, mark.y + 1.6)); c.strokePath()
            fill(0xFFB5C4); c.beginPath(); oval(bn.x + 0.6, bn.y + 0.6, 3.4, 2.8)
            let sp = 1 + raw.spread * 0.28
            for d in [P(-3.8, -2.8), P(-0.2, -4.4), P(3.6, -2.6)] { circle(bn.x + 0.6 + d.x * sp, bn.y + d.y * sp, 1.35 + raw.spread * 0.2) }
            c.fillPath()
        }
        // 옆구리에 낀 노트북은 몸과 앞다리 사이에 있어 머리보다 먼저 그린다.
        var heldLaptop: CGPath?
        if case .laptop = raw.prop {
            heldLaptop = self.heldLaptop(center: P(mid.x - 6, mid.y + 3))
            overForeleg(raw, shoulder: sh, keepingLineOver: heldLaptop, body: near)
        }
        paintChest(head: headPoint, shoulder: sh)
        if let scarf {
            drawScarf(scarf, neck: HwarangNeck(head: headPoint, shoulder: sh, tilt: raw.h.tilt), swing: scarfSwing, wind: scarfWind, phase: scarfPhase)
        }
        head(headPoint.x, headPoint.y, raw.h)
        switch raw.prop {
        case .none, .laptop: break
        case let .book(flip): book(flip)
        case .map: foldedMap()
        }
        if raw.foreOver, heldLaptop == nil { overForeleg(raw, shoulder: sh, keepingLineOver: nil, body: near) }
    }

    /// 몸 위에 겹쳐 그리는 앞다리. 몸 안쪽 윤곽은 지우되 `prop`(몸에 얹은 소품) 위에서는 다리 선을 남긴다.
    private mutating func overForeleg(_ raw: Pose, shoulder sh: CGPoint, keepingLineOver prop: CGPath?, body near: [Blob]) {
        var top: [Blob] = []
        toes = []
        fore(&top, sh, mapPaw(raw.fn), raw.foreBend)
        paint(top, fillColor: coat.fur)
        c.saveGState()
        if let prop {
            c.beginPath(); c.addRect(c.boundingBoxOfClipPath); c.addPath(prop); c.clip(using: .evenOdd)
        }
        c.beginPath(); addBlobs(near); c.clip()
        fill(coat.fur); c.beginPath(); addBlobs(top, grow: outlineWidth + 0.3); c.fillPath()
        c.restoreGState()
        drawToes()
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
        if let ribbon { drawTailRibbon(ribbon, tail: tailPoints, radius: 6.3, sway: 0.22, phase: p.tp * 1.1, along: Self.canvasEdgeRibbonAlong) }
        var h = p.h
        if h.tilt == 0 { h.tilt = 0.03 }
        let headPoint = P(82, 68 + br * 0.6 + p.drop)
        paintChest(head: headPoint, shoulder: P(70, 88))
        if let scarf {
            drawScarf(scarf, neck: HwarangNeck(head: headPoint, shoulder: P(70, 88), tilt: h.tilt), swing: [], wind: 0, phase: 0)
        }
        head(headPoint.x, headPoint.y, h)
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
                fill(coat.fur); poly([a, tip, b]); c.fillPath()
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

    /// 스카프 끝을 움직일 지난 머리 속도와 바람을 구한다. 자세는 시각만의 함수라 과거 시각을 다시 계산한다.
    private mutating func prepareScarfMotion(_ scene: HwarangScene, sec: CGFloat, beat: Int) {
        func anchor(_ t: CGFloat) -> CGPoint {
            headAnchor(sceneState(scene, max(0, t)).pose)
        }
        let step: CGFloat = 0.07
        var past = anchor(sec)
        scarfSwing = (1...5).map { i in
            let older = anchor(sec - step * CGFloat(i))
            defer { past = older }
            return CGVector(dx: (past.x - older.x) / step, dy: (past.y - older.y) / step)
        }
        let speed = scene.beats[beat].speed
        scarfWind = switch scene {
        case .walkLoop, .walkLaptop: 0.32
        case .runLoop: 1.0
        case .stroll: speed / 30 * 0.7
        case .wheel: speed / 4.4 * 0.9
        case .bicycle: 0.75
        case .robotVacuum: 0.12
        default: 0
        }
        scarfPhase = sec * (scarfWind > 0.5 ? 13 : 7)
    }

    /// 머리·귀가 몸을 조금 늦게 따라오고, 내려앉을 때 살짝 눌린다.
    private func laggedState(_ scene: HwarangScene, _ sec: CGFloat) -> SceneState {
        var st = sceneState(scene, sec)
        guard scene != .sleep, scene != .nap, !scene.drawsLyingBody else { return st }
        let dt: CGFloat = 0.09
        let previous = sceneState(scene, max(0, sec - dt)).pose
        let vy = (st.pose.hip.y - previous.hip.y) / dt, hv = (st.pose.head.y - previous.head.y) / dt
        st.pose.head = lerp(st.pose.head, previous.head, 0.55)
        st.pose.h.ear += clamp(hv * 0.012, -0.25, 0.25)
        st.pose.h.blink = wrap(sec * 0.29 + CGFloat(scene.beatCount) * 0.13, 1) < 0.035
        st.pose.squash = clamp(1 - abs(vy) * 0.0016 + (vy > 0 ? -0.012 : 0.012) * min(1, abs(vy) * 0.03), 0.9, 1.08)
        return st
    }

    /// 시험용: 식사 장면의 머리나 그릇만 그린다. 둘이 겹치는지 화소로 재려고 쓴다.
    func drawEatPart(bowlOnly: Bool, sec: CGFloat) {
        if bowlOnly { bowl(); return }
        let pose = laggedState(.eat, sec).pose, anchor = headAnchor(pose)
        c.saveGState()
        c.translateBy(x: 58, y: groundY); c.scaleBy(x: 1 / sqrt(pose.squash), y: pose.squash); c.translateBy(x: -58, y: -groundY)
        head(anchor.x, anchor.y, pose.h)
        c.restoreGState()
    }

    /// 세계 좌표(가로 146)로 장면 하나를 그린다.
    mutating func render(_ scene: HwarangScene, sec: CGFloat, facesLeft: Bool, showsBackdrop: Bool) {
        let sec = sec * coat.tempo + coat.phase
        var st = laggedState(scene, sec)
        c.saveGState()
        if facesLeft { c.translateBy(x: 118, y: 0); c.scaleBy(x: -1, y: 1) }
        // 샤워할 때는 장식을 모두 벗어 옷걸이에 건다.
        let worn = (hatImage, scarf, ribbon)
        defer { (hatImage, scarf, ribbon) = worn }
        if scene == .shower {
            hangAccessories(hat: hatImage, scarf: scarf, ribbon: ribbon)
            hatImage = nil; scarf = nil; ribbon = nil
        }
        if scarf != nil { prepareScarfMotion(scene, sec: sec, beat: st.beat) }
        if showsBackdrop, scene == .stroll { trees(st.progress) }
        if scene == .wheel { wheel(st.progress) }
        if scene == .work { laptop(sec) }
        if scene == .stretch { yogaMat() }
        dailyBackdrop(scene, sec: sec)
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
        case .train: ktxTrain(st.pose.h, sec: sec, progress: st.progress)
        case .bus: cityBus(st.pose.h, sec: sec, progress: st.progress)
        case .airplane: airplane(st.pose.h, sec: sec, progress: st.progress)
        case .boat: boat(st.pose.h, sec: sec, progress: st.progress)
        case .sleep:
            loaf(st.pose)
            sleepLetters(sec)
        case .nap:
            loaf(st.pose)
        case _ where scene.drawsLyingBody:
            lyingBody(scene, pose: st.pose, sec: sec)
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
            dailyCompanions(scene, sec: sec)
            if let layout = scene.companionLayout {
                lineScale = 1 / layout.scale
                c.translateBy(x: 58 + layout.shift, y: groundY); c.scaleBy(x: layout.scale, y: layout.scale); c.translateBy(x: -58, y: -groundY)
            }
            c.translateBy(x: 58, y: groundY); c.scaleBy(x: 1 / sqrt(q), y: q); c.translateBy(x: -58, y: -groundY)
            cat(st.pose)
            dailyOverlay(scene, pose: st.pose, sec: sec)
            if scene == .shower { wetFur(st.pose, sec: sec, shaking: st.beat == 1) }
            c.restoreGState()
            lineScale = 1
        }
        switch scene {
        case .yarn:
            let y = yarnPosition(st.beat, sec, st.u)
            yarn(y.0, y.1, y.2)
        case .eat: bowl()
        case .sleepBelly, .sleepEyeMask: sleepLetters(sec)
        case .restCroissant, .nap, .cook, .groceries, .coffee, .friends, .date, .meditate, .salon, .game, .music, .video, .petCare: dailyForeground(scene, sec: sec)
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
    var scarf: HwarangClothStyle? = nil
    var ribbon: HwarangClothStyle? = nil
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
        let isWheel = scene == .wheel, coat = HwarangCoat.selected
        let scale = width / Self.worldWidth * (isWheel && keepsBodySize ? 1 / wheelScale : 1)
        let height = (Self.worldHeight + headroom) * scale
        let ground = ((isWheel ? wheelGround : groundY) + headroom - 8) * scale
        Canvas { context, size in
            context.withCGContext { cg in
                let k = size.width / Self.worldWidth
                cg.scaleBy(x: k, y: k)
                cg.translateBy(x: 14, y: headroom - 8)
                var painter = HwarangPainter(c: cg, small: small, hatImage: hat, scarf: scarf, ribbon: ribbon, coat: coat)
                painter.render(scene, sec: CGFloat(sec), facesLeft: facesLeft, showsBackdrop: showsBackdrop)
            }
        }
        .frame(width: Self.worldWidth * scale, height: height)
        .offset(y: anchorHeight / 2 - (ground - height / 2))
    }
}
