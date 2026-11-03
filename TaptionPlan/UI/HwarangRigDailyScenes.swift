import CoreGraphics

/// 직접 고르는 일상 분류(낮잠·요리…)의 화랑이 장면(RIG1103A02). 장면마다 뚜렷한 동작 하나를 되풀이한다.
extension HwarangScene {
    static let dailyScenes: [HwarangScene] = [
        .nap, .cook, .groceries, .laundry, .dishes, .coffee, .meeting, .friends, .date, .family, .phoneCall,
        .meditate, .hospital, .salon, .readBook, .game, .music, .video, .petCare
    ]

    /// 관절 자세 대신 누운 몸통을 직접 그리는 장면(SLP1103A01).
    var drawsLyingBody: Bool {
        switch self {
        case .sleepBelly, .sleepEyeMask, .recoverySuperman, .medicated, .hospital, .restStarfish, .restCroissant, .restDonut, .restLoaf, .restBox: true
        default: false
        }
    }

    /// 곁에 다른 고양이를 함께 그려 화랑이를 작게 비켜 앉히는 장면의 배율과 왼쪽 이동.
    var companionLayout: (scale: CGFloat, shift: CGFloat)? {
        switch self {
        case .friends, .meeting: (0.8, -24)
        case .date: (0.8, -14)
        case .family: (0.76, -24)
        default: nil
        }
    }
}

extension HwarangPainter {
    func lyingBody(_ scene: HwarangScene, pose p: Pose, sec: CGFloat) {
        switch scene {
        case .sleepBelly: bellyUp(p)
        case .sleepEyeMask: eyeMaskSleep(p)
        case .recoverySuperman: superman(p)
        case .medicated: sickLoaf(p, sec: sec); pillBottle()
        case .hospital:
            sickLoaf(p, sec: sec)
            hospitalGear(sickHead, tilt: p.h.tilt)
        case .restStarfish: starfish(p)
        case .restCroissant: croissant(p)
        case .restDonut: donut(p)
        case .restLoaf: restingLoaf(p)
        case .restBox: boxRest(p)
        default: break
        }
    }

    private func tailBlobs(_ points: [CGPoint]) -> (points: [CGPoint], blobs: [Blob]) {
        let path = catmull(points)
        return (path, path.enumerated().map { i, q in Blob(x: q.x, y: q.y, r: lerp(7, 6, CGFloat(i) / CGFloat(path.count - 1))) })
    }

    private func finish(_ p: Pose, tail: [CGPoint]?, head q: CGPoint, shoulder: CGPoint) {
        if let tail, let ribbon { drawTailRibbon(ribbon, tail: tail, radius: 6.3, sway: 0.22, phase: p.tp * 1.1, along: Self.canvasEdgeRibbonAlong) }
        if let scarf { drawScarf(scarf, neck: HwarangNeck(head: q, shoulder: shoulder, tilt: p.h.tilt), swing: [], wind: 0, phase: 0) }
        head(q.x, q.y, p.h)
    }

    /// 슈퍼맨: 배를 깔고 앞발과 뒷발을 앞뒤로 쭉 뻗는다. 힘든 활동 뒤의 회복.
    private func superman(_ p: Pose) {
        let top = 74 - p.breath, tw = sin(p.tp * 1.1) * 2
        let tail = tailBlobs([P(26, groundY - 14), P(12, groundY - 22), P(4, groundY - 32 + tw), P(-1, groundY - 44 + tw)])
        let hind = limb([P(38, groundY - 9), P(20, groundY - 6), P(4, groundY - 5)], radius: 5.6)
        let fore = limb([P(64, groundY - 9), P(94, groundY - 6), P(118, groundY - 5)], radius: 5.6)
        unionBody({
            c.beginPath(); c.move(to: P(28, groundY))
            cubic(16, groundY, 18, 84, 32, 80); cubic(44, top, 62, top, 72, 80)
            cubic(82, 86, 84, groundY, 74, groundY); c.closePath()
        }, parts: tail.blobs + hind + fore)
        crease([P(30, 86), P(40, 92), P(40, groundY - 7)])
        toes(at: P(118, groundY - 5))
        toes(at: P(4, groundY - 5))
        finish(p, tail: tail.points, head: P(80, groundY - 30 + p.breath * 0.3), shoulder: P(66, 86))
    }

    private var sickHead: CGPoint { P(74, groundY - 19) }

    /// 아픈 식빵 자세: 머리를 바닥까지 떨구고 몸을 웅크린다.
    private func sickLoaf(_ p: Pose, sec: CGFloat) {
        let top = 64 - p.breath, tail = tailBlobs([P(28, groundY - 4), P(40, groundY - 1), P(54, groundY - 1)])
        unionBody({
            c.beginPath(); c.move(to: P(26, groundY + 1))
            cubic(12, groundY + 1, 12, 82, 24, 74); cubic(34, top, 58, top, 68, 76)
            cubic(78, 86, 78, groundY + 1, 70, groundY + 1); c.closePath()
        }, parts: tail.blobs)
        finish(p, tail: tail.points, head: sickHead, shoulder: P(64, 90))
        // 끙끙 앓는 물결선.
        stroke(0x7A8CB0, 1.8, 0.8); c.setLineCap(.round)
        for (i, x) in [CGFloat(34), 44].enumerated() {
            let w = sin(sec * 2.4 + CGFloat(i)) * 1.5, y: CGFloat = 56 - CGFloat(i) * 2
            c.beginPath(); c.move(to: P(x, y)); c.addCurve(to: P(x + 2, y - 14), control1: P(x + 5 + w, y - 4), control2: P(x - 3 - w, y - 9)); c.strokePath()
        }
    }

    private func pillBottle() {
        rounded(107, groundY - 22, 15, 22, 3, fillHex: 0xE9A04B, line: 1.8)
        rounded(105, groundY - 28, 19, 7, 2, fillHex: white, line: 1.8)
        rounded(109, groundY - 15, 11, 8, 1, fillHex: 0xFFF6E2, line: 1)
        c.saveGState(); c.translateBy(x: 127, y: groundY - 3); c.rotate(by: -0.3)
        rounded(-5, -2.6, 10, 5.2, 2.6, fillHex: 0xE5484D, line: 1.3)
        c.restoreGState()
    }

    /// 불가사리: 옆으로 벌렁 누워 네 다리를 사방으로 편다.
    private func starfish(_ p: Pose) {
        let top = 72 - p.breath, tw = sin(p.tp) * 2
        // 꼬리는 엉덩이에서 위로 굽어 오르고, 뒷다리는 왼쪽 바닥으로 뻗는다.
        let tail = tailBlobs([P(24, 86), P(12, 76), P(9, 62 + tw), P(16, 50 + tw)])
        let legs = limb([P(28, groundY - 6), P(12, groundY - 4), P(-4, groundY - 6)], radius: 5.4)
            + limb([P(54, 80), P(46, 64), P(50, 48)], radius: 5.2)
            + limb([P(70, groundY - 6), P(96, groundY - 3), P(120, groundY - 5)], radius: 5.2)
        unionBody({
            c.beginPath(); c.move(to: P(24, groundY + 1))
            cubic(12, groundY + 1, 14, 86, 26, 80); cubic(38, top, 60, top, 72, 78)
            cubic(84, 86, 82, groundY + 1, 72, groundY + 1); c.closePath()
        }, parts: tail.blobs + legs)
        fill(0xFFE3DC, 0.7); c.beginPath(); oval(46, top + 15, 15, 7 + p.breath * 0.4); c.fillPath()
        jelly(at: P(-4, groundY - 6), angle: -.pi / 2)
        jelly(at: P(50, 48), angle: 0)
        finish(p, tail: tail.points, head: P(90, groundY - 23 + p.breath * 0.3), shoulder: P(72, 88))
    }

    /// 크루아상: 등을 둥글게 말고 옆으로 눕는다.
    private func croissant(_ p: Pose) {
        let b = p.breath
        let tail = tailBlobs([P(18, groundY - 8), P(26, groundY - 2), P(40, groundY - 2), P(50, groundY - 5)])
        let back = catmull([P(24, groundY - 12), P(30, 76 - b), P(52, 66 - b), P(72, 76 - b), P(74, groundY - 14)])
        unionBody({
            c.beginPath(); c.move(to: P(14, groundY - 8))
            cubic(12, 70, 34, 54 - b, 54, 54 - b); cubic(72, 54 - b, 86, 70, 84, groundY - 12)
            cubic(70, groundY - 12, 66, 84, 50, 84); cubic(36, 84, 34, groundY - 4, 28, groundY)
            cubic(20, groundY + 1, 15, groundY - 2, 14, groundY - 8); c.closePath()
        }, parts: tail.blobs + back.map { Blob(x: $0.x, y: $0.y, r: 5) })
        foldedLeg([P(66, 86), P(58, 94), P(62, groundY - 3)], radius: 5)
        finish(p, tail: tail.points, head: P(84, groundY - 19), shoulder: P(72, 84))
    }

    /// 도넛: 코끝이 꼬리에 닿게 동그랗게 만다.
    private func donut(_ p: Pose) {
        let b = p.breath
        unionBody({ c.beginPath(); oval(52, 80 - b * 0.4, 37, 24 + b * 0.4); c.closePath() }, parts: [])
        finish(p, tail: nil, head: P(70, groundY - 21), shoulder: P(58, 80))
        let tail = catmull([P(18, groundY - 12), P(30, groundY - 2), P(54, groundY), P(78, groundY - 5), P(92, groundY - 13)])
        limpLeg(tail, radius: 5.2)
        if let ribbon { drawTailRibbon(ribbon, tail: tail, radius: 5.5, sway: 0.2, phase: p.tp, along: 0.25) }
    }

    /// 박스 안: 상자에 쏙 들어가 턱을 걸치고 쉰다.
    private func boxRest(_ p: Pose) {
        let rim = groundY - 30
        // 뒤쪽 날개
        fill(0xC98F58); stroke(outline, outlineWidth); c.setLineJoin(.round)
        poly([P(36, rim), P(46, rim - 11), P(92, rim - 11), P(102, rim)]); c.drawPath(using: .fillStroke)
        unionBody({ c.beginPath(); oval(58, rim - 7 - p.breath, 26, 15 + p.breath * 0.4); c.closePath() }, parts: [])
        finish(p, tail: nil, head: P(76, rim - 21 + p.breath * 0.3), shoulder: P(68, rim - 3))
        // 앞면과 양쪽 날개
        fill(0xE0AC72); stroke(outline, outlineWidth)
        poly([P(36, rim), P(102, rim), P(102, groundY), P(36, groundY)]); c.drawPath(using: .fillStroke)
        fill(0xEEC08A)
        poly([P(36, rim), P(24, rim + 11), P(50, rim + 11), P(58, rim)]); c.drawPath(using: .fillStroke)
        poly([P(102, rim), P(114, rim + 11), P(88, rim + 11), P(80, rim)]); c.drawPath(using: .fillStroke)
        limpLeg([P(68, rim - 1), P(70, rim + 3)], radius: 4.6)
        limpLeg([P(86, rim - 1), P(88, rim + 3)], radius: 4.6)
        let tail = catmull([P(40, rim - 2), P(26, rim + 2), P(20, rim + 14), P(26, rim + 24)])
        limpLeg(tail, radius: 4.8)
        if let ribbon { drawTailRibbon(ribbon, tail: tail, radius: 5, sway: 0.2, phase: p.tp, along: 0.5) }
    }

    /// 식빵: 발을 안으로 넣고 편하게 웅크린다.
    private func restingLoaf(_ p: Pose) {
        let top = 62 - p.breath * 1.2, tail = tailBlobs([P(30, groundY - 4), P(44, groundY - 1), P(60, groundY - 1)])
        unionBody({
            c.beginPath(); c.move(to: P(30, groundY + 1))
            cubic(14, groundY + 1, 14, 84, 26, 74); cubic(34, top, 62, top, 72, 74)
            cubic(82, 84, 84, groundY + 1, 74, groundY + 1); c.closePath()
        }, parts: tail.blobs)
        finish(p, tail: tail.points, head: P(84, 72 + p.breath * 0.5), shoulder: P(70, 90))
    }

    /// 몸통과 한 윤곽으로 합쳐 그릴 다리. 관절 경계선이 생기지 않는다.
    private func limb(_ points: [CGPoint], radius r: CGFloat) -> [Blob] {
        catmull(points, seg: 24).map { Blob(x: $0.x, y: $0.y, r: r) }
    }

    /// 발바닥 젤리. `angle`은 발끝이 향하는 쪽이다.
    private func jelly(at q: CGPoint, angle: CGFloat) {
        c.saveGState(); c.translateBy(x: q.x, y: q.y); c.rotate(by: angle)
        fill(0xF7A8BC); c.beginPath(); oval(0, 1.6, 2.7, 2.1)
        for x: CGFloat in [-2.7, 0, 2.7] { circle(x, x == 0 ? -2.9 : -1.9, 1.1) }
        c.fillPath(); c.restoreGState()
    }

    private func toes(at q: CGPoint) {
        stroke(outline, 1.2); c.setLineCap(.round); c.beginPath()
        for dx: CGFloat in [-1.8, 1.8] { c.move(to: P(q.x + dx, q.y + 1.5)); c.addLine(to: P(q.x + dx, q.y + 4.4)) }
        c.strokePath()
    }

    /// 몸통 안쪽의 근육 주름. 양 끝을 열어 둔다.
    private func crease(_ points: [CGPoint]) {
        stroke(outline, outlineWidth * 0.7); c.setLineCap(.round)
        c.beginPath(); c.addLines(between: catmull(points)); c.strokePath()
    }

    /// 몸 위에 포갠 발. 뿌리의 선을 지워 몸통에서 이어져 나오게 한다.
    private func foldedLeg(_ points: [CGPoint], radius r: CGFloat) {
        limpLeg(points, radius: r)
        let path = catmull(points)
        stroke(coat.fur, r * 2 + outlineWidth * 2); c.setLineCap(.butt)
        c.beginPath(); c.addLines(between: Array(path.prefix(max(2, path.count * 2 / 5)))); c.strokePath()
        c.setLineCap(.round)
    }

    /// 앞발·뒷발 하나를 몸 위나 바닥에 늘어뜨린다. 몸통 윤곽 위에 겹쳐 그린다.
    private func limpLeg(_ points: [CGPoint], radius r: CGFloat) {
        let path = catmull(points)
        c.setLineCap(.round); c.setLineJoin(.round)
        for (color, width) in [(outline, r * 2 + outlineWidth * 2), (coat.fur, r * 2)] {
            stroke(color, width); c.beginPath(); c.addLines(between: path); c.strokePath()
        }
    }

    /// 배를 까고 베개에 누운 자세. 앞발은 가슴에 얹고 뒷발은 힘 없이 내린 채 숨 쉴 때 배만 오르내린다.
    func bellyUp(_ p: Pose) {
        let top = 72 - p.breath * 1.4, sag = p.breath * 0.4, tw = sin(p.tp * 1.1) * 2.2
        rounded(64, groundY - 22, 62, 22, 10, fillHex: 0xBFD8EE, line: outlineWidth)
        let tail = tailBlobs([P(24, groundY - 6), P(11, groundY - 3), P(0, groundY - 5), P(-6, groundY - 13 + tw)])
        unionBody({
            c.beginPath(); c.move(to: P(26, groundY + 1))
            cubic(12, groundY + 1, 14, 86, 28, 80); cubic(38, top, 60, top, 72, 80)
            cubic(82, 86, 82, groundY + 1, 72, groundY + 1); c.closePath()
        }, parts: tail.blobs)
        fill(0xFFE3DC, 0.75); c.beginPath(); oval(44, top + 14 - p.breath * 0.2, 15, 7 + p.breath * 0.4); c.fillPath()
        crease([P(26, 86), P(36, 92), P(36, groundY - 4)])
        foldedLeg([P(70, 88 + sag), P(56, 84 + sag), P(47, 90 + sag)], radius: 4.4)
        finish(p, tail: tail.points, head: P(88, groundY - 28 + p.breath * 0.3), shoulder: P(72, 88))
    }

    /// 머리를 떨구고 수면 안대를 낀 채 잔다.
    func eyeMaskSleep(_ p: Pose) {
        let top = 66 - p.breath * 1.3, tail = tailBlobs([P(28, groundY - 5), P(14, groundY - 3), P(2, groundY - 5), P(-6, groundY - 12), P(-3, groundY - 20 + sin(p.tp) * 2)])
        unionBody({
            c.beginPath(); c.move(to: P(26, groundY + 1))
            cubic(14, groundY + 1, 14, 86, 24, 76); cubic(32, top + 1, 56, top, 66, 76)
            cubic(76, 84, 78, groundY + 1, 70, groundY + 1); c.closePath()
        }, parts: tail.blobs)
        let q = P(80, groundY - 20)
        finish(p, tail: tail.points, head: q, shoulder: P(64, 88))
        let hs: CGFloat = small ? 1.72 : 1.5
        c.saveGState(); c.translateBy(x: q.x, y: q.y); c.rotate(by: p.h.tilt); c.scaleBy(x: hs, y: hs)
        sleepMask()
        c.restoreGState()
    }

    /// 머리 좌표계의 안대. 끈이 머리 옆으로 돌아가고 눈 자리에 감은 눈을 수놓았다.
    private func sleepMask() {
        let line = outlineWidth / (small ? 1.72 : 1.5)
        c.setLineCap(.round); c.setLineJoin(.round)
        // 끈은 머리 양옆까지만 잇고, 안대는 코 위로 살짝 파인 둥근 띠 하나로 그린다.
        stroke(0x8E7CC3, line * 1.1); c.beginPath(); c.move(to: P(-16.8, -1)); c.addLine(to: P(16.8, -1)); c.strokePath()
        fill(0xCDBEF0); stroke(outline, line * 0.8)
        c.beginPath(); c.move(to: P(-9, -3.6))
        c.addLine(to: P(9, -3.6))
        c.addCurve(to: P(9, 4.6), control1: P(17.5, -3.6), control2: P(17.5, 4.6))
        c.addCurve(to: P(-9, 4.6), control1: P(4, 4.6), control2: P(-4, 4.6))
        c.addCurve(to: P(-9, -3.6), control1: P(-17.5, 4.6), control2: P(-17.5, -3.6))
        c.closePath(); c.drawPath(using: .fillStroke)
        stroke(outline, line * 0.8); c.beginPath()
        for x: CGFloat in [-8.5, 8.5] { c.move(to: P(x - 3.6, -0.2)); c.addQuadCurve(to: P(x + 3.6, -0.2), control: P(x, 2.6)) }
        c.strokePath()
    }
}

func dailyPose(_ scene: HwarangScene, s: CGFloat) -> Pose {
    switch scene {
    case .sleepBelly:
        var p = Pose()
        p.breath = sin(s * tau / 3.6); p.tp = s * 0.8
        p.h = HeadPose(tilt: 0.42, ear: sin(s * 0.7) * 0.05, mouthOpen: 0.12, eye: .closed)
        return p
    case .recoverySuperman, .restLoaf, .restStarfish, .restCroissant, .restDonut, .restBox:
        var p = Pose()
        p.breath = sin(s * tau / 3.8); p.tp = s * 0.7
        let tilt: CGFloat = switch scene {
        case .recoverySuperman: 0.04
        case .restStarfish: 0.55
        case .restCroissant: 0.5
        case .restDonut: 0.46
        case .restBox: 0.03
        default: 0.05
        }
        p.h = HeadPose(tilt: tilt, ear: sin(s * 0.7) * 0.05, eye: .closed)
        return p
    case .medicated, .hospital:
        // 아플 때: 머리를 떨군 채 눈을 반쯤 감고 잘게 떤다.
        var p = Pose()
        p.breath = sin(s * tau / 2.6) * 0.7; p.tp = s * 0.4
        p.h = HeadPose(tilt: 0.14 + sin(s * 1.1) * 0.02, ear: -0.28, eye: .half)
        return p
    case .sleepEyeMask:
        var p = Pose()
        p.breath = sin(s * tau / 3.8); p.tp = s * 0.8
        p.h = HeadPose(tilt: 0.3, ear: sin(s * 0.8) * 0.06, eye: .closed)
        return p
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
    case .dishes:
        var p = sit(s, HeadPose(tilt: sin(s * 2.2) * 0.06, look: 3, eye: blink(s, 3)))
        p.fn = P(92 + sin(s * 7) * 5, 74 + cos(s * 7) * 3)
        return p
    case .laundry:
        return sit(s, HeadPose(tilt: sin(s * 2.6) * 0.1, look: 3, eye: blink(s, 2.4)))
    case .meeting:
        // 회의: 불꽃을 등지고 서로 노려본다. 앞발은 휘두르지 않는다.
        return sit(s, HeadPose(tilt: 0.06 + sin(s * 2.4) * 0.03, look: 2.6, mouthOpen: max(0, sin(s * 3)) * 0.4, eye: .half))
    case .coffee:
        // 카페: 앞발로 잔을 들어 천천히 마신다.
        var p = sit(s, HeadPose(tilt: sin(s * 0.9) * 0.05, look: 2.2, mouthOpen: 0.08, eye: blink(s, 3.4)))
        p.fn = P(92, 78)
        return p
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
        case .meeting: meetingFlames(sec)
        case .dishes: sink(sec)
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
        case .meeting:
            let p = sit(sec + 1.3, HeadPose(tilt: 0.06 - sin(sec * 2.4) * 0.03, look: 2.4, mouthOpen: max(0, sin(sec * 3 + 1)) * 0.4, eye: .half))
            companion(p, x: 92, scale: 0.72, ground: groundY, bow: 0xE5484D)
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
        case .coffee: cafeTable(sec)
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

    /// 회의 배경: 두 고양이 뒤로 타오르는 불꽃.
    private func meetingFlames(_ sec: CGFloat) {
        for (x, height, phase) in [(CGFloat(-2), CGFloat(52), CGFloat(0)), (24, 74, 1.1), (54, 84, 2.3), (84, 72, 3.2), (116, 54, 4.4)] {
            let sway = sin(sec * 7 + phase) * 4, h = height + sin(sec * 11 + phase) * 6
            for (scale, color) in [(CGFloat(1), UInt32(0xE5484D)), (0.68, 0xF28C28), (0.38, 0xF9D648)] {
                let w = 19 * scale, tip = h * scale
                fill(color, 0.92); c.beginPath(); c.move(to: P(x - w, groundY))
                cubic(x - w, groundY - tip * 0.45, x + sway - w * 0.35, groundY - tip * 0.7, x + sway, groundY - tip)
                cubic(x + sway + w * 0.35, groundY - tip * 0.7, x + w, groundY - tip * 0.45, x + w, groundY)
                c.closePath(); c.fillPath()
            }
        }
    }

    /// 카페 탁자와 찻잔, 올라오는 김.
    private func cafeTable(_ sec: CGFloat) {
        rounded(84, 86, 48, 6, 3, fillHex: 0xC78A5B, line: 2)
        stroke(outline, 3); c.beginPath(); c.move(to: P(108, 92)); c.addLine(to: P(108, groundY)); c.strokePath()
        rounded(98, 72, 18, 14, 4, fillHex: 0xFFFDF4, line: 2)
        stroke(outline, 1.8); c.beginPath(); oval(118, 79, 3.6, 4.4); c.strokePath()
        fill(0x7A4A2E); c.beginPath(); oval(107, 74, 7, 1.6); c.fillPath()
        stroke(0xB9A794, 1.6, 0.8); c.setLineCap(.round)
        for (i, x) in [CGFloat(103), 110].enumerated() {
            let w = sin(sec * 2 + CGFloat(i)) * 1.6
            c.beginPath(); c.move(to: P(x, 68)); c.addCurve(to: P(x, 54), control1: P(x + 3 + w, 64), control2: P(x - 3 - w, 59)); c.strokePath()
        }
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

    /// 싱크대와 접시, 거품. 앞발이 접시를 닦는다.
    private func sink(_ sec: CGFloat) {
        rounded(84, 78, 48, groundY - 77, 3, fillHex: 0xD9C3A0, line: 2.2)
        rounded(80, 72, 56, 8, 3, fillHex: 0xC6D3DC, line: 2)
        stroke(outline, 2.4); c.setLineCap(.round); c.beginPath(); c.move(to: P(122, 72)); c.addLine(to: P(122, 58)); quad(122, 52, 114, 54); c.strokePath()
        for i in 0..<3 where wrap(sec * 1.4 + CGFloat(i) * 0.33, 1) < 0.8 {
            let t = wrap(sec * 1.4 + CGFloat(i) * 0.33, 1)
            fill(0x8CCBEF); c.beginPath(); circle(114, 56 + t * 16, 1.3); c.fillPath()
        }
        fill(0xFFFFFF); stroke(outline, 1.8); c.beginPath(); oval(98, 68, 11, 5); c.drawPath(using: .fillStroke)
        for (i, q) in [P(90, 60), P(102, 58), P(108, 62), P(96, 54)].enumerated() {
            let wobble = sin(sec * 3 + CGFloat(i)) * 1.5
            fill(0xFFFFFF, 0.92); stroke(0x8CCBEF, 1.1); c.beginPath(); circle(q.x, q.y + wobble, 2.4 + CGFloat(i % 2)); c.drawPath(using: .fillStroke)
        }
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

    private func hospitalGear(_ head: CGPoint, tilt: CGFloat) {
        // 이마에 붙인 반창고.
        c.saveGState(); c.translateBy(x: head.x, y: head.y); c.rotate(by: tilt)
        c.saveGState(); c.translateBy(x: -13, y: -14); c.rotate(by: -0.6)
        rounded(-8, -2.8, 16, 5.6, 2.6, fillHex: 0xF4D9B0, line: 1.3)
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
