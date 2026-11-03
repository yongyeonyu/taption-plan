import CoreGraphics

/// 직접 고르는 일상 분류(낮잠·요리…)의 화랑이 장면(RIG1103A02). 장면마다 뚜렷한 동작 하나를 되풀이한다.
extension HwarangScene {
    static let dailyScenes: [HwarangScene] = [
        .nap, .cook, .groceries, .laundry, .friends, .date, .family, .phoneCall,
        .meditate, .hospital, .salon, .readBook, .game, .music, .video, .petCare
    ]

    /// 곁에 다른 고양이를 함께 그려 화랑이를 작게 비켜 앉히는 장면의 배율과 왼쪽 이동.
    var companionLayout: (scale: CGFloat, shift: CGFloat)? {
        switch self {
        case .friends: (0.8, -24)
        case .date: (0.8, -14)
        case .family: (0.76, -24)
        default: nil
        }
    }
}

func dailyPose(_ scene: HwarangScene, s: CGFloat) -> Pose {
    switch scene {
    case .nap:
        var p = Pose()
        p.breath = sin(s * tau / 3.4) * 1.1; p.tp = s * 0.7
        p.h = HeadPose(tilt: 0.06, ear: sin(s * 0.8) * 0.06, eye: .closed)
        return p
    case .cook:
        let toss = max(0, sin(s * 3.4))
        var p = stand(s, HeadPose(tilt: -0.06 - toss * 0.1, look: 3, mouthOpen: toss * 0.4, eye: .open))
        p.fn = P(90, 84 - toss * 7)
        return p
    case .groceries:
        var p = walk(s, period: 1.3, stride: 16)
        p.h.eye = wrap(s, 3) < 1 ? .happy : blink(s)
        return p
    case .laundry:
        return sit(s, HeadPose(tilt: sin(s * 2.6) * 0.1, look: 3, eye: blink(s, 2.4)))
    case .friends:
        let wave = sin(s * 7)
        var p = sit(s, HeadPose(tilt: 0.05, look: 2.4, mouthOpen: max(0, sin(s * 5)) * 0.7, eye: wrap(s, 4) < 1.4 ? .happy : blink(s)))
        // 머리 뒤로 올린 앞발만 머리 옆으로 보이며 흔든다.
        p.fn = P(lerp(94, 102, (wave + 1) / 2), 30)
        return p
    case .date:
        return sit(s, HeadPose(tilt: 0.14 + sin(s * 1.3) * 0.04, look: 2.4, mouthOpen: 0.12, eye: .happy))
    case .family:
        return sit(s, HeadPose(tilt: sin(s * 1.4) * 0.05, look: 2, mouthOpen: 0.15, eye: .happy))
    case .phoneCall:
        var p = sit(s, HeadPose(tilt: -0.12, look: 1.6, mouthOpen: max(0, sin(s * 6.5)) * 0.8, eye: blink(s, 2.2)))
        p.fn = P(94, 62 + sin(s * 1.5))
        return p
    case .meditate:
        var p = sit(s, HeadPose(eye: .closed))
        let breath = sin(s * tau / 4.5)
        p.sh.y -= breath; p.head.y -= breath * 2; p.rm = 1 + breath * 0.6
        p.tw = 0.05; p.tp = s * 0.5; p.tc = -1.2
        return p
    case .hospital:
        return sit(s, HeadPose(tilt: -0.06 + sin(s * 1.1) * 0.03, look: 1.2, eye: wrap(s, 3.4) < 1.2 ? .half : blink(s, 3.4)))
    case .salon:
        return sit(s, HeadPose(tilt: sin(s * 0.9) * 0.05, look: 2.4, eye: wrap(s, 3) < 1 ? .closed : .open))
    case .readBook:
        var p = sit(s, HeadPose(tilt: 0.1, look: 2.8, eye: blink(s, 3.3)))
        p.fn = P(92, 92); p.ff = P(96, 94); p.foreBend = 1
        return p
    case .game:
        let tap = sin(s * 16)
        var p = sit(s, HeadPose(tilt: 0.14, look: 1.6 + sin(s * 3) * 1.4, mouthOpen: wrap(s, 2.4) < 0.5 ? 0.8 : 0.12, eye: wrap(s, 2.4) < 0.5 ? .happy : .open))
        p.fn = P(84, 86 + tap); p.ff = P(92, 86 - tap); p.foreBend = 1
        return p
    case .music:
        let bob = sin(s * 5.4)
        var p = sit(s, HeadPose(tilt: bob * 0.16, ear: bob * 0.1, look: 1, mouthOpen: 0.1, eye: .happy))
        p.head.y += abs(bob) * 1.6; p.tw = 0.7; p.tp = s * 5.4
        return p
    case .video:
        return sit(s, HeadPose(tilt: 0.04, look: 3.4, mouthOpen: wrap(s, 4.4) < 0.7 ? 0.7 : 0, eye: blink(s, 3.7)))
    case .petCare:
        let pat = sin(s * 5)
        var p = sit(s, HeadPose(tilt: 0.14, look: 3, mouthOpen: 0.12, eye: .happy))
        p.fn = P(94, 88 - pat * 3)
        return p
    default:
        return Pose()
    }
}

extension HwarangPainter {
    /// 고양이 뒤에 깔리는 소품.
    func dailyBackdrop(_ scene: HwarangScene, sec: CGFloat) {
        c.setLineJoin(.round); c.setLineCap(.round)
        switch scene {
        case .nap:
            napCushion()
            sun(sec)
        case .laundry: washer(sec)
        case .meditate: zafu(sec)
        case .hospital: crossSign()
        case .salon: mirror()
        case .video: television(sec)
        default: break
        }
    }

    /// 화랑이의 뒤나 곁에 있는 다른 고양이. 화랑이 장식은 걸치지 않는다.
    mutating func dailyCompanions(_ scene: HwarangScene, sec: CGFloat) {
        switch scene {
        case .friends:
            var p = sit(sec + 1.3, HeadPose(tilt: -0.04, look: 2.2, mouthOpen: max(0, sin(sec * 5 + .pi)) * 0.7, eye: wrap(sec, 3.6) < 1.2 ? .happy : blink(sec, 2.7)))
            p.tp = sec * 3; p.tw = 0.5
            companion(p, x: 97, scale: 0.72, ground: groundY, bow: 0x5DA9E9)
        case .date:
            let p = sit(sec + 0.7, HeadPose(tilt: 0.12 + sin(sec * 1.3) * 0.04, look: 2.2, mouthOpen: 0.1, eye: .happy))
            companion(p, x: 84, scale: 0.72, ground: groundY, bow: 0xE9557B)
        case .family:
            for (x, phase, color) in [(CGFloat(78), CGFloat(0), UInt32(0xF7C948)), (106, 1.4, 0x7FB069)] {
                let hop = abs(sin(sec * 3.2 + phase)) * 7
                let p = sit(sec + phase, HeadPose(tilt: sin(sec * 2 + phase) * 0.1, look: 2, mouthOpen: 0.15, eye: .happy))
                companion(p, x: x, scale: 0.46, ground: groundY - hop, bow: color)
            }
        default: break
        }
    }

    private mutating func companion(_ pose: Pose, x: CGFloat, scale: CGFloat, ground: CGFloat, bow: UInt32) {
        let saved = (scarf, ribbon, hatImage, lineScale)
        scarf = nil; ribbon = nil; hatImage = nil; lineScale = 1 / scale
        c.saveGState()
        // 화랑이 쪽을 바라보도록 좌우를 뒤집는다.
        c.translateBy(x: x, y: ground); c.scaleBy(x: -scale, y: scale); c.translateBy(x: -58, y: -groundY)
        cat(pose)
        let top = headAnchor(pose)
        bowTie(P(top.x + 19, top.y - 19), color: bow)
        c.restoreGState()
        (scarf, ribbon, hatImage, lineScale) = saved
    }

    /// 고양이 위에 얹는 소품. 머리 위치를 따라가는 것은 몸과 같은 좌표계에서 그린다.
    func dailyOverlay(_ scene: HwarangScene, pose: Pose, sec: CGFloat) {
        let head = headAnchor(pose)
        c.setLineJoin(.round); c.setLineCap(.round)
        switch scene {
        case .phoneCall: phone(P(99, 50 + sin(sec * 1.5)), sec: sec)
        case .hospital: hospitalGear(head, tilt: pose.h.tilt, sec: sec)
        case .salon: scissors(head, sec: sec)
        case .readBook: heldBook(sec)
        case .game: console(sec)
        case .music: headphones(head, tilt: pose.h.tilt, sec: sec)
        default: break
        }
    }

    /// 맨 앞에 그리는 소품과 기호.
    func dailyForeground(_ scene: HwarangScene, sec: CGFloat) {
        c.setLineJoin(.round); c.setLineCap(.round)
        switch scene {
        case .nap:
            let z = wrap(sec * 0.4, 1)
            napLetter(102 + z * 7, 58 - z * 14, size: 6 + z * 3, alpha: 1 - z)
        case .cook: pan(sec)
        case .groceries: shoppingBag(sec)
        case .friends:
            bubble(P(66, 24), sec: sec)
        case .date:
            for i in 0..<3 {
                let z = wrap(sec * 0.42 + CGFloat(i) / 3, 1)
                heart(50 + CGFloat(i) * 11 + sin(z * 7 + CGFloat(i)) * 3, 36 - z * 18, 0.8 + z * 0.5, alpha: 1 - z * z)
            }
        case .meditate:
            for i in 0..<3 {
                let z = wrap(sec * 0.3 + CGFloat(i) / 3, 1)
                sparkle(P(CGFloat([14, 118, 104][i]), 60 - z * 30), size: 3 + sin(z * .pi) * 2, alpha: sin(z * .pi))
            }
        case .salon:
            for i in 0..<4 {
                let z = wrap(sec * 0.55 + CGFloat(i) * 0.25, 1)
                furTuft(P(40 + CGFloat(i) * 14 + sin(z * 6) * 3, 26 + z * 76), alpha: 1 - z * z * z)
            }
        case .game:
            let z = wrap(sec / 2.4, 1)
            if z < 0.26 { for i in 0..<3 { sparkle(P(CGFloat(102 + i * 10), CGFloat(70 - i * 9) - z * 20), size: 3.4, alpha: 1 - z / 0.26) } }
        case .music:
            for i in 0..<3 {
                let z = wrap(sec * 0.5 + CGFloat(i) / 3, 1)
                musicNote(P(104 + CGFloat(i) * 8 + sin(z * 6) * 3, 62 - z * 44), alpha: 1 - z * z, color: i == 1 ? 0xE96A8A : 0x7A5FC6)
            }
        case .video: popcorn()
        case .petCare:
            hamster(sec)
            let z = wrap(sec * 0.5, 1)
            heart(112, 68 - z * 22, 0.7 + z * 0.3, alpha: 1 - z * z)
        default: break
        }
    }

    // MARK: - 기호

    private func heart(_ x: CGFloat, _ y: CGFloat, _ k: CGFloat, alpha: CGFloat) {
        fill(0xF0567F, alpha); stroke(outline, 1.1, alpha)
        c.beginPath(); c.move(to: P(x, y + 5 * k))
        c.addCurve(to: P(x, y - 2 * k), control1: P(x - 8 * k, y - 1 * k), control2: P(x - 4 * k, y - 7 * k))
        c.addCurve(to: P(x, y + 5 * k), control1: P(x + 4 * k, y - 7 * k), control2: P(x + 8 * k, y - 1 * k))
        c.closePath(); c.drawPath(using: .fillStroke)
    }

    private func sparkle(_ q: CGPoint, size: CGFloat, alpha: CGFloat) {
        fill(0xF7C948, alpha); c.beginPath(); c.move(to: P(q.x, q.y - size))
        for (dx, dy) in [(0.26, -0.26), (1, 0), (0.26, 0.26), (0, 1), (-0.26, 0.26), (-1, 0), (-0.26, -0.26)] as [(CGFloat, CGFloat)] {
            c.addLine(to: P(q.x + dx * size, q.y + dy * size))
        }
        c.closePath(); c.fillPath()
    }

    private func musicNote(_ q: CGPoint, alpha: CGFloat, color: UInt32) {
        fill(color, alpha); c.beginPath(); oval(q.x, q.y, 3.2, 2.4); c.fillPath()
        stroke(color, 1.7, alpha); c.beginPath(); c.move(to: P(q.x + 2.8, q.y)); c.addLine(to: P(q.x + 2.8, q.y - 9)); c.addLine(to: P(q.x + 7, q.y - 7)); c.strokePath()
    }

    private func napLetter(_ x: CGFloat, _ y: CGFloat, size: CGFloat, alpha: CGFloat) {
        stroke(0x5E78C4, max(1.4, size * 0.2), alpha); c.beginPath()
        c.addLines(between: [P(x, y - size), P(x + size * 0.7, y - size), P(x, y), P(x + size * 0.7, y)]); c.strokePath()
    }

    private func bowTie(_ q: CGPoint, color: UInt32) {
        fill(color); stroke(outline, 1.2); c.beginPath()
        c.move(to: q); c.addLine(to: P(q.x - 6, q.y - 4)); c.addLine(to: P(q.x - 6, q.y + 4)); c.closePath()
        c.move(to: q); c.addLine(to: P(q.x + 6, q.y - 4)); c.addLine(to: P(q.x + 6, q.y + 4)); c.closePath()
        c.drawPath(using: .fillStroke)
        fill(white); c.beginPath(); circle(q.x, q.y, 1.5); c.drawPath(using: .fillStroke)
    }

    private func furTuft(_ q: CGPoint, alpha: CGFloat) {
        fill(white, alpha); stroke(outline, 1, alpha); c.beginPath()
        c.move(to: P(q.x - 3, q.y)); c.addQuadCurve(to: P(q.x + 3, q.y - 1), control: P(q.x, q.y - 4)); c.addQuadCurve(to: P(q.x - 3, q.y), control: P(q.x, q.y + 2))
        c.drawPath(using: .fillStroke)
    }

    private func bubble(_ q: CGPoint, sec: CGFloat) {
        fill(white); stroke(outline, 1.6)
        rounded(q.x - 16, q.y - 8, 32, 16, 8, fillHex: white, line: 1.6)
        c.beginPath(); c.move(to: P(q.x - 5, q.y + 7.5)); c.addLine(to: P(q.x - 8, q.y + 13)); c.addLine(to: P(q.x + 1, q.y + 7.5)); c.drawPath(using: .fillStroke)
        for i in 0..<3 {
            let on = wrap(sec * 1.6, 1) * 3 >= CGFloat(i)
            fill(outline, on ? 1 : 0.25); c.beginPath(); circle(q.x - 7 + CGFloat(i) * 7, q.y, 1.9); c.fillPath()
        }
    }

    // MARK: - 소품

    private func napCushion() {
        fill(0xF3B6C6); stroke(outline, 2.2); c.beginPath(); oval(56, groundY + 1, 62, 10); c.drawPath(using: .fillStroke)
        stroke(0xE48AA3, 1.4); c.beginPath(); c.move(to: P(0, groundY + 4)); c.addQuadCurve(to: P(112, groundY + 4), control: P(56, groundY + 12)); c.strokePath()
    }

    private func sun(_ sec: CGFloat) {
        let q = P(114, 27)
        stroke(0xF7B23B, 2, 0.9); c.beginPath()
        for i in 0..<8 {
            let a = CGFloat(i) / 8 * tau + sec * 0.3
            c.move(to: P(q.x + cos(a) * 11, q.y + sin(a) * 11)); c.addLine(to: P(q.x + cos(a) * 15, q.y + sin(a) * 15))
        }
        c.strokePath()
        fill(0xFBD45B); stroke(outline, 1.6); c.beginPath(); circle(q.x, q.y, 8); c.drawPath(using: .fillStroke)
    }

    private func pan(_ sec: CGFloat) {
        let toss = max(0, sin(sec * 3.4)), tilt = -toss * 0.22, q = P(112, 80 - toss * 6)
        c.saveGState(); c.translateBy(x: q.x, y: q.y); c.rotate(by: tilt)
        stroke(outline, 5); c.beginPath(); c.move(to: P(-24, 2)); c.addLine(to: P(-12, 0)); c.strokePath()
        stroke(0x8B5A2B, 2.6); c.beginPath(); c.move(to: P(-24, 2)); c.addLine(to: P(-12, 0)); c.strokePath()
        fill(0x46525F); stroke(outline, 2); c.beginPath(); c.move(to: P(-14, -2)); c.addLine(to: P(14, -2)); c.addQuadCurve(to: P(-14, -2), control: P(0, 9)); c.drawPath(using: .fillStroke)
        c.restoreGState()
        // 팬케이크가 공중에서 한 바퀴 돈다.
        let phase = wrap(sec * 3.4 / tau, 1), air = phase < 0.5 ? sin(phase * 2 * .pi) : 0
        c.saveGState(); c.translateBy(x: q.x, y: q.y - 6 - air * 26); c.rotate(by: air * .pi * 1.2)
        fill(0xE9B872); stroke(outline, 1.6); c.beginPath(); oval(0, 0, 10, 3.2); c.drawPath(using: .fillStroke)
        c.restoreGState()
    }

    private func shoppingBag(_ sec: CGFloat) {
        let sway = sin(sec * 4.8) * 1.6, x: CGFloat = 104 + sway
        // 빵과 사과가 봉투 위로 삐져나온다.
        c.saveGState(); c.translateBy(x: x + 6, y: 68); c.rotate(by: 0.25)
        rounded(-3.4, -14, 6.8, 22, 3.4, fillHex: 0xE9B872, line: 1.6)
        c.restoreGState()
        fill(0xE5484D); stroke(outline, 1.6); c.beginPath(); circle(x - 6, 70, 5.4); c.drawPath(using: .fillStroke)
        fill(0xF4E3C1); stroke(outline, 2); poly([P(x - 14, 72), P(x + 14, 72), P(x + 12, 100), P(x - 12, 100)]); c.drawPath(using: .fillStroke)
        stroke(0xC9A671, 1.6); c.beginPath(); c.move(to: P(x - 8, 79)); c.addLine(to: P(x + 8, 79)); c.strokePath()
    }

    private func washer(_ sec: CGFloat) {
        let x: CGFloat = 97, top: CGFloat = 58, w: CGFloat = 32, h = groundY - top + 1
        rounded(x, top, w, h, 4, fillHex: 0xE6ECF1, line: 2.2)
        stroke(outline, 1.2); c.beginPath(); c.move(to: P(x, top + 9)); c.addLine(to: P(x + w, top + 9)); c.strokePath()
        fill(0x5FD38D); c.beginPath(); circle(x + w - 6, top + 4.6, 1.8); c.fillPath()
        let q = P(x + w / 2, top + 26)
        fill(0x9CC9E8); stroke(outline, 2); c.beginPath(); circle(q.x, q.y, 13); c.drawPath(using: .fillStroke)
        c.saveGState(); c.translateBy(x: q.x, y: q.y); c.rotate(by: sec * 3.2)
        fill(0xE96A8A); c.beginPath(); oval(6, 0, 4.4, 3); c.fillPath()
        fill(0xF7C948); c.beginPath(); oval(-5, 4, 4, 2.8); c.fillPath()
        fill(0xFFFFFF); c.beginPath(); oval(-2, -6, 3.2, 2.2); c.fillPath()
        c.restoreGState()
    }

    private func zafu(_ sec: CGFloat) {
        let glow = (sin(sec * tau / 4.5) + 1) / 2
        for (r, a) in [(CGFloat(40), CGFloat(0.14)), (47, 0.08)] {
            fill(0xB9A7E8, a + glow * 0.06); c.beginPath(); circle(66, 60, r + glow * 3); c.fillPath()
        }
        fill(0x8C79D6); stroke(outline, 2.2); c.beginPath(); oval(58, groundY + 1, 40, 8); c.drawPath(using: .fillStroke)
    }

    private func crossSign() {
        stroke(outline, 4); c.beginPath(); c.move(to: P(116, groundY)); c.addLine(to: P(116, 56)); c.strokePath()
        rounded(102, 28, 28, 28, 5, fillHex: white, line: 2.2)
        fill(0xE5484D); c.fill(CGRect(x: 112.5, y: 33, width: 7, height: 18)); c.fill(CGRect(x: 107, y: 38.5, width: 18, height: 7))
    }

    private func hospitalGear(_ head: CGPoint, tilt: CGFloat, sec: CGFloat) {
        // 이마에 붙인 반창고와 입에 문 체온계.
        c.saveGState(); c.translateBy(x: head.x, y: head.y); c.rotate(by: tilt)
        c.saveGState(); c.translateBy(x: -13, y: -14); c.rotate(by: -0.6)
        rounded(-8, -2.8, 16, 5.6, 2.6, fillHex: 0xF4D9B0, line: 1.3)
        c.restoreGState()
        c.saveGState(); c.translateBy(x: 3, y: 19); c.rotate(by: 0.42)
        rounded(0, -1.6, 20, 3.2, 1.6, fillHex: white, line: 1.2)
        fill(0xE5484D); c.beginPath(); circle(20, 0, 2.3); c.fillPath()
        c.restoreGState()
        c.restoreGState()
    }

    private func mirror() {
        stroke(outline, 3.4); c.beginPath(); c.move(to: P(116, groundY)); c.addLine(to: P(116, 80)); c.strokePath()
        fill(0xC6E4F2); stroke(0xC78A5B, 3.4); c.beginPath(); oval(116, 56, 13, 25); c.drawPath(using: .fillStroke)
        stroke(white, 2, 0.9); c.beginPath(); c.move(to: P(110, 44)); c.addLine(to: P(116, 36)); c.move(to: P(110, 54)); c.addLine(to: P(121, 40)); c.strokePath()
    }

    private func scissors(_ head: CGPoint, sec: CGFloat) {
        let open = (sin(sec * 11) + 1) / 2 * 0.42 + 0.06, q = P(head.x + 16, head.y - 27)
        c.saveGState(); c.translateBy(x: q.x, y: q.y); c.rotate(by: 2.5)
        for side: CGFloat in [-1, 1] {
            c.saveGState(); c.rotate(by: side * open)
            fill(0xC9D3DC); stroke(outline, 1.3); poly([P(-1, -1.6), P(17, -0.4), P(17, 0.4), P(-1, 1.6)]); c.drawPath(using: .fillStroke)
            fill(white, 0); stroke(0xE5484D, 2.2); c.beginPath(); oval(-6, side * -1.8, 4.4, 3.2); c.strokePath()
            c.restoreGState()
        }
        c.restoreGState()
    }

    private func phone(_ q: CGPoint, sec: CGFloat) {
        c.saveGState(); c.translateBy(x: q.x, y: q.y); c.rotate(by: 0.18)
        rounded(-6, -13, 12, 26, 3, fillHex: 0x46525F, line: 2)
        fill(0x9CC9E8); c.fill(CGRect(x: -3.8, y: -9.6, width: 7.6, height: 19))
        c.restoreGState()
        let z = wrap(sec * 1.4, 1)
        stroke(0x5DA9E9, 1.8, 1 - z * 0.6); c.beginPath()
        for r: CGFloat in [10, 15] { c.addArc(center: P(q.x + 8, q.y - 6), radius: r + z * 2, startAngle: -0.9, endAngle: 0.3, clockwise: false); c.move(to: P(q.x + 8 + cos(-0.9) * 15, q.y - 6 + sin(-0.9) * 15)) }
        c.strokePath()
    }

    private func heldBook(_ sec: CGFloat) {
        let q = P(103, 80)
        fill(0x2F6FB5); stroke(outline, 2); poly([P(q.x - 17, q.y - 12), P(q.x + 17, q.y - 12), P(q.x + 17, q.y + 12), P(q.x - 17, q.y + 12)]); c.drawPath(using: .fillStroke)
        fill(0xFFFDF4); stroke(outline, 1.4); poly([P(q.x - 15, q.y - 10), P(q.x, q.y - 8), P(q.x + 15, q.y - 10), P(q.x + 15, q.y + 9), P(q.x, q.y + 11), P(q.x - 15, q.y + 9)]); c.drawPath(using: .fillStroke)
        stroke(0xBDB199, 1); c.beginPath()
        for i in 0..<3 {
            let y = q.y - 3 + CGFloat(i) * 4
            c.move(to: P(q.x - 12, y)); c.addLine(to: P(q.x - 3, y + 1)); c.move(to: P(q.x + 3, y + 1)); c.addLine(to: P(q.x + 12, y))
        }
        c.strokePath()
        let flip = clamp((wrap(sec, 3.6) - 2.9) / 0.6, 0, 1)
        if flip > 0, flip < 1 {
            let tip = q.x + cos(flip * .pi) * 14
            fill(0xFFF3D6); stroke(outline, 1.2); poly([P(q.x, q.y - 8), P(tip, q.y - 11), P(tip, q.y + 8), P(q.x, q.y + 11)]); c.drawPath(using: .fillStroke)
        }
    }

    private func console(_ sec: CGFloat) {
        let q = P(96, 77)
        rounded(q.x - 22, q.y - 10, 44, 20, 8, fillHex: 0x5D6B7A, line: 2)
        let bright = wrap(sec * 4, 1) < 0.5
        fill(bright ? 0x8FE3B0 : 0x5FD38D); c.fill(CGRect(x: q.x - 9, y: q.y - 7, width: 18, height: 14))
        fill(0x17243A); c.fill(CGRect(x: q.x - 6 + wrap(sec * 6, 8), y: q.y - 1, width: 3, height: 3))
        stroke(0x17243A, 1.8); c.beginPath(); c.move(to: P(q.x - 18, q.y)); c.addLine(to: P(q.x - 12, q.y)); c.move(to: P(q.x - 15, q.y - 3)); c.addLine(to: P(q.x - 15, q.y + 3)); c.strokePath()
        fill(bright ? 0xF0567F : 0xB23A5A); c.beginPath(); circle(q.x + 14, q.y - 2, 2.1); c.fillPath()
        fill(bright ? 0xB23A5A : 0xF0567F); c.beginPath(); circle(q.x + 18, q.y + 2, 2.1); c.fillPath()
    }

    private func headphones(_ head: CGPoint, tilt: CGFloat, sec: CGFloat) {
        c.saveGState(); c.translateBy(x: head.x, y: head.y); c.rotate(by: tilt)
        stroke(outline, 5.6); c.beginPath(); c.addArc(center: P(0, 4), radius: 29, startAngle: .pi * 1.14, endAngle: .pi * 1.86, clockwise: false); c.strokePath()
        stroke(0x7A5FC6, 3); c.beginPath(); c.addArc(center: P(0, 4), radius: 29, startAngle: .pi * 1.14, endAngle: .pi * 1.86, clockwise: false); c.strokePath()
        for side: CGFloat in [-1, 1] { rounded(side * 30 - 6, -3, 12, 19, 5, fillHex: 0xE96A8A, line: 2) }
        c.restoreGState()
    }

    private func television(_ sec: CGFloat) {
        let x: CGFloat = 100, top: CGFloat = 44, w: CGFloat = 32, h: CGFloat = 40
        stroke(outline, 3); c.beginPath(); c.move(to: P(x + 8, top + h)); c.addLine(to: P(x + 4, groundY)); c.move(to: P(x + w - 8, top + h)); c.addLine(to: P(x + w - 4, groundY)); c.strokePath()
        rounded(x, top, w, h, 3, fillHex: 0x46525F, line: 2.2)
        let colors: [UInt32] = [0x7CC4FF, 0xF2A7C3, 0xA6E3A1, 0xF7C948]
        fill(colors[Int(wrap(sec * 0.8, 4))]); c.fill(CGRect(x: x + 3, y: top + 3, width: w - 6, height: h - 6))
        fill(white, 0.9); poly([P(x + w / 2 - 4, top + h / 2 - 6), P(x + w / 2 + 6, top + h / 2), P(x + w / 2 - 4, top + h / 2 + 6)]); c.fillPath()
    }

    private func popcorn() {
        let x: CGFloat = 94, y: CGFloat = groundY + 10
        fill(0xFFF3C4); stroke(outline, 1.2); c.beginPath()
        for (dx, dy) in [(-5, -14), (0, -17), (5, -14), (-2, -12), (3, -12)] as [(CGFloat, CGFloat)] { circle(x + dx, y + dy, 3.2) }
        c.drawPath(using: .fillStroke)
        fill(0xE5484D); stroke(outline, 1.8); poly([P(x - 9, y - 12), P(x + 9, y - 12), P(x + 6, y), P(x - 6, y)]); c.drawPath(using: .fillStroke)
        stroke(white, 2); c.beginPath(); c.move(to: P(x - 3, y - 11)); c.addLine(to: P(x - 2, y - 1)); c.move(to: P(x + 3, y - 11)); c.addLine(to: P(x + 2, y - 1)); c.strokePath()
    }

    private func hamster(_ sec: CGFloat) {
        let squash = sin(sec * 5) * 0.08, x: CGFloat = 112, y = groundY - 9
        fill(0xE9B872); stroke(outline, 2); c.beginPath(); circle(x - 8, y - 9, 3.2); circle(x + 8, y - 9, 3.2); c.drawPath(using: .fillStroke)
        c.beginPath(); oval(x, y, 13 * (1 + squash), 10 * (1 - squash)); c.drawPath(using: .fillStroke)
        fill(0xFFF4E4); c.beginPath(); oval(x, y + 3, 7, 5.4); c.fillPath()
        fill(outline); c.beginPath(); circle(x - 5, y - 2, 1.4); circle(x + 5, y - 2, 1.4); c.fillPath()
    }
}
