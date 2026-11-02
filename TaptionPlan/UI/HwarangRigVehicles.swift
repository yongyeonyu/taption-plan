import SwiftUI
import UIKit

/// 화랑이가 타는 탈것 그림(CAT1102A02).
extension HwarangPainter {
    func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, fillHex: UInt32, line: CGFloat = 2.2) {
        fill(fillHex); stroke(outline, line); c.beginPath(); c.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)); c.drawPath(using: .fillStroke)
    }

    /// 탈것 창이나 구멍으로 얼굴만 보여 준다.
    mutating func face(_ x: CGFloat, _ y: CGFloat, _ k: CGFloat, _ h: HeadPose, showsScarf: Bool = false) {
        let saved = lineScale
        lineScale = 1 / k
        c.saveGState(); c.translateBy(x: x, y: y); c.scaleBy(x: k, y: k)
        if showsScarf, let scarf {
            drawScarf(scarf, neck: HwarangNeck(head: .zero, shoulder: P(0, 30), tilt: h.tilt), swing: [], wind: 0, phase: 0, showsStrands: false)
        }
        head(0, 0, h)
        c.restoreGState()
        lineScale = saved
    }

    func wheelTire(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ rotation: CGFloat) {
        fill(0x3A3A40); stroke(outline, 2.2); c.beginPath(); circle(x, y, r); c.drawPath(using: .fillStroke)
        fill(0xC9D3DC); c.beginPath(); circle(x, y, r * 0.5); c.fillPath()
        stroke(0x7A848C, 1.4); c.beginPath()
        for i in 0..<4 { let a = rotation + CGFloat(i) * .pi / 2; c.move(to: P(x, y)); c.addLine(to: P(x + cos(a) * r * 0.5, y + sin(a) * r * 0.5)) }
        c.strokePath()
    }

    func roadDashes(_ progress: CGFloat, y: CGFloat) {
        stroke(0x8E949A, 2.6); c.setLineCap(.butt); c.setLineDash(phase: wrap(progress, 26), lengths: [14, 12]); c.beginPath(); c.move(to: P(-14, y)); c.addLine(to: P(132, y)); c.strokePath(); c.setLineDash(phase: 0, lengths: []); c.setLineCap(.round)
    }

    /// 정면에서 본 자동차. 앞유리 너머로 운전하는 화랑이 얼굴이 보인다.
    mutating func carFront(_ h: HeadPose, sec: CGFloat, progress: CGFloat) {
        let turn = sin(sec * 0.9), bob = sin(sec * 6) * 0.7
        fill(0x000000, 0.14); c.beginPath(); oval(58, groundY + 3, 54, 5); c.fillPath()
        // 달리는 느낌을 주는 옆 선
        stroke(0x8E949A, 2.2); c.beginPath()
        for (i, x) in [CGFloat(-8), 124].enumerated() {
            let y = 40 + wrap(progress * 0.8 + CGFloat(i) * 22, 60)
            c.move(to: P(x, y)); c.addLine(to: P(x, y + 12))
        }
        c.strokePath()
        c.saveGState(); c.translateBy(x: 58 + turn * 2.5, y: groundY); c.rotate(by: turn * 0.02); c.translateBy(x: -58, y: -groundY + bob)
        rounded(14, 90, 18, 16, 4, fillHex: 0x3A3A40); rounded(84, 90, 18, 16, 4, fillHex: 0x3A3A40)
        fill(0xE8675A); stroke(outline, 2.2); c.beginPath(); c.move(to: P(16, 84)); cubic(18, 40, 30, 16, 58, 16); cubic(86, 16, 98, 40, 100, 84); c.closePath(); c.drawPath(using: .fillStroke)
        fill(0xCFE9F5); stroke(outline, 2); c.beginPath(); c.move(to: P(24, 84)); cubic(26, 48, 36, 25, 58, 25); cubic(80, 25, 90, 48, 92, 84); c.closePath(); c.drawPath(using: .fillStroke)
        rounded(38, 34, 40, 50, 12, fillHex: 0xB7695A, line: 1.4)
        // 앞유리 너머로 턱 밑 스카프 띠만 보인다. 끈은 핸들과 차체에 가려 그리지 않는다.
        face(58, 57, 0.9, h, showsScarf: true)
        // 핸들과 핸들을 쥔 앞발
        let angle = turn * 0.35
        stroke(outline, 5.4); c.beginPath(); oval(58, 80, 16, 7); c.strokePath()
        stroke(0x4A4A52, 3); c.beginPath(); oval(58, 80, 16, 7); c.strokePath()
        for side: CGFloat in [-1, 1] {
            let px = 58 + cos(angle) * side * 15, py = 79 + sin(angle) * side * 5
            fill(white); stroke(outline, 2); c.beginPath(); circle(px, py, 5); c.drawPath(using: .fillStroke)
        }
        fill(0xE8675A); stroke(outline, 2.2); c.beginPath(); c.move(to: P(6, 94)); quad(6, 84, 18, 84); c.addLine(to: P(98, 84)); quad(110, 84, 110, 94); c.addLine(to: P(110, 100)); quad(110, 104, 104, 104); c.addLine(to: P(12, 104)); quad(6, 104, 6, 100); c.closePath(); c.drawPath(using: .fillStroke)
        for x: CGFloat in [20, 96] { fill(0xFFF0B0); stroke(outline, 1.8); c.beginPath(); circle(x, 93, 5.5); c.drawPath(using: .fillStroke) }
        rounded(40, 88, 36, 9, 3, fillHex: 0x3F3F46, line: 1.6)
        stroke(0x8A8A92, 1.1); c.beginPath(); for x: CGFloat in [47, 54, 61, 68] { c.move(to: P(x, 90)); c.addLine(to: P(x, 95)) }; c.strokePath()
        rounded(48, 98.5, 20, 4.5, 1, fillHex: 0xFFFDF4, line: 1)
        c.restoreGState()
    }

    func railCar(_ x: CGFloat, _ w: CGFloat, nose: Bool, stripe: UInt32) {
        let top: CGFloat = 44, bottom: CGFloat = 96
        fill(0xF3F5F7); stroke(outline, 2.2); c.beginPath()
        c.move(to: P(x + 4, top)); c.addLine(to: P(x + w - (nose ? 16 : 4), top))
        if nose { quad(x + w, top + 4, x + w, top + 30); c.addLine(to: P(x + w, bottom)) } else { quad(x + w, top, x + w, top + 4); c.addLine(to: P(x + w, bottom)) }
        c.addLine(to: P(x, bottom)); c.addLine(to: P(x, top + 4)); quad(x, top, x + 4, top); c.closePath(); c.drawPath(using: .fillStroke)
        fill(stripe); c.fill(CGRect(x: x + 1.2, y: 84, width: w - 2.4, height: 7))
        fill(0xC9D3DC); c.fill(CGRect(x: x + 1.2, y: top + 1.2, width: w - (nose ? 18 : 2.4), height: 3))
        for wheelX in [x + w * 0.22, x + w * 0.78] { wheelTire(wheelX, 100, 5.5, wheelX) }
    }

    /// 두 량짜리 열차. 앞칸 창 안에 화랑이가 있다. 지하철은 초록 띠, 기차는 빨간 띠와 집전 장치로 구분한다.
    mutating func railTrain(_ h: HeadPose, sec: CGFloat, progress: CGFloat, stripe: UInt32, pantograph: Bool) {
        stroke(outline, 2.4); c.beginPath(); c.move(to: P(-14, 106)); c.addLine(to: P(132, 106)); c.strokePath()
        roadDashes(progress, y: 110)
        let bob = sin(sec * 9) * 0.6
        c.saveGState(); c.translateBy(x: 0, y: bob)
        rounded(46, 76, 8, 6, 1, fillHex: 0x5D6B7A, line: 1.6)
        railCar(-12, 58, nose: false, stripe: stripe)
        railCar(52, 78, nose: true, stripe: stripe)
        if pantograph {
            stroke(outline, 2); c.beginPath(); c.addLines(between: [P(14, 44), P(24, 32), P(16, 26), P(34, 26)]); c.strokePath()
        }
        for x: CGFloat in [-6, 18] { rounded(x, 52, 18, 24, 3, fillHex: 0xCFE9F5, line: 1.8) }
        rounded(58, 50, 50, 32, 4, fillHex: 0xCFE9F5, line: 1.8)
        rounded(112, 52, 14, 22, 3, fillHex: 0xCFE9F5, line: 1.8)
        face(82 + sin(sec * 0.5) * 6, 70, 0.6, h)
        // 창틀을 앞에 다시 그려 화랑이가 차 안에 있어 보이게 한다.
        fill(0xF3F5F7); c.fill(CGRect(x: 54, y: 83, width: 58, height: 1))
        stroke(0xFFFFFF, 2, 0.7); c.beginPath(); let shine = wrap(progress * 0.4, 60) + 58; c.move(to: P(min(shine, 104), 80)); c.addLine(to: P(min(shine + 6, 106), 54)); c.strokePath()
        c.restoreGState()
    }

    /// 옆에서 본 버스. 넓은 창 안에 화랑이가 앉아 있다.
    mutating func cityBus(_ h: HeadPose, sec: CGFloat, progress: CGFloat) {
        roadDashes(progress, y: 110)
        let bob = sin(sec * 7) * 0.7
        c.saveGState(); c.translateBy(x: 0, y: bob)
        rounded(40, 22, 40, 9, 2, fillHex: 0xF7C948, line: 1.8)
        rounded(0, 30, 118, 66, 10, fillHex: 0x3E8FDC)
        fill(0xFFFDF4); c.fill(CGRect(x: 1.2, y: 76, width: 115.6, height: 7))
        rounded(6, 37, 22, 34, 4, fillHex: 0xCFE9F5, line: 1.8)
        rounded(31, 37, 50, 34, 4, fillHex: 0xCFE9F5, line: 1.8)
        rounded(84, 37, 28, 34, 5, fillHex: 0xCFE9F5, line: 1.8)
        rounded(87, 74, 18, 21, 2, fillHex: 0xCFE9F5, line: 1.6)
        face(56, 57, 0.6, h)
        // 창 아래 앞발
        fill(white); stroke(outline, 1.8); c.beginPath(); circle(48, 70, 3.8); circle(64, 70, 3.8); c.drawPath(using: .fillStroke)
        c.restoreGState()
        wheelTire(24, 96 + bob, 10, progress * 0.12); wheelTire(94, 96 + bob, 10, progress * 0.12)
    }

    /// 옆에서 본 자전거. 화랑이는 프레임 위에 그린다.
    func bicycle(_ sec: CGFloat, progress: CGFloat) {
        roadDashes(progress, y: 110)
        let rear = P(20, 90), front = P(100, 90), crank = P(58, 92), seat = P(48, 70), head = P(88, 66)
        wheelTire(rear.x, rear.y, 14, progress * 0.2); wheelTire(front.x, front.y, 14, progress * 0.2)
        for (color, width) in [(outline, CGFloat(5.2)), (UInt32(0x3E8FDC), 2.8)] {
            stroke(color, width); c.setLineCap(.round); c.setLineJoin(.round); c.beginPath()
            c.addLines(between: [rear, crank, seat, rear]); c.move(to: crank); c.addLine(to: head); c.addLine(to: seat)
            c.move(to: head); c.addLine(to: front)
            c.strokePath()
        }
        stroke(outline, 3.4); c.beginPath(); c.move(to: head); c.addLine(to: P(90, 58)); c.addLine(to: P(99, 57)); c.strokePath()
        rounded(38, 66, 20, 5, 2.5, fillHex: 0x5A4033, line: 1)
        stroke(outline, 2.4); c.beginPath(); circle(crank.x, crank.y, 5); c.strokePath()
    }

    /// 로봇 청소기. x가 움직이면 옆 솔이 돌고 뒤에 먼지가 일어난다.
    func vacuum(_ x: CGFloat, _ sec: CGFloat, dir: CGFloat) {
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

    func cloud(_ x: CGFloat, _ y: CGFloat, _ k: CGFloat) {
        fill(0xFFFFFF, 0.95); stroke(0xB9C7D2, 1.4); c.beginPath(); circle(x, y, 7 * k); circle(x + 8 * k, y - 3 * k, 8 * k); circle(x + 17 * k, y, 6 * k); c.drawPath(using: .fillStroke)
    }

    /// 옆에서 본 비행기. 동체 위로 얼굴만 내밀고 갸웃거린다.
    mutating func airplane(_ h: HeadPose, sec: CGFloat, progress: CGFloat) {
        cloud(wrap(90 - progress, 180) - 30, 24, 1)
        cloud(wrap(190 - progress * 1.3, 180) - 30, 96, 1.2)
        c.saveGState(); c.translateBy(x: 60, y: 70); c.rotate(by: sin(sec * 0.8) * 0.03); c.translateBy(x: -60, y: -70 + sin(sec * 1.4) * 1.4)
        fill(0xE8675A); stroke(outline, 2.2); poly([P(8, 62), P(-6, 28), P(12, 28), P(32, 56)]); c.drawPath(using: .fillStroke)
        face(78, 37, 0.82, h)
        fill(0xF7F9FB); stroke(outline, 2.2); c.beginPath(); c.move(to: P(4, 68)); cubic(4, 54, 30, 52, 60, 52); c.addLine(to: P(96, 52)); cubic(116, 52, 130, 60, 132, 70); cubic(130, 82, 114, 88, 96, 88); c.addLine(to: P(30, 88)); cubic(14, 88, 4, 80, 4, 68); c.closePath(); c.drawPath(using: .fillStroke)
        fill(0x3E8FDC); c.fill(CGRect(x: 8, y: 74, width: 118, height: 5))
        fill(0x8EC7E8); stroke(outline, 1.4); c.beginPath(); for x: CGFloat in [22, 32, 42, 104] { circle(x, 66, 3) }; c.drawPath(using: .fillStroke)
        fill(0x8EC7E8); stroke(outline, 1.8); c.beginPath(); c.move(to: P(112, 60)); quad(124, 62, 127, 69); c.addLine(to: P(112, 69)); c.closePath(); c.drawPath(using: .fillStroke)
        rounded(56, 49, 44, 6, 3, fillHex: 0x5D6B7A, line: 1.6)
        fill(0xC9D3DC); stroke(outline, 2.2); poly([P(52, 76), P(80, 76), P(60, 106), P(40, 106)]); c.drawPath(using: .fillStroke)
        rounded(66, 92, 20, 9, 4, fillHex: 0x8A97A3, line: 1.8)
        c.restoreGState()
    }

    /// 옆에서 본 배. 선체 위로 얼굴만 내밀고 파도에 흔들린다.
    mutating func boat(_ h: HeadPose, sec: CGFloat, progress: CGFloat) {
        c.saveGState(); c.translateBy(x: 58, y: 92); c.rotate(by: sin(sec * 1.1) * 0.05); c.translateBy(x: -58, y: -92 + sin(sec * 1.7) * 1.2)
        fill(0xE7E9EC, 0.9); stroke(0xB9C7D2, 1.2); c.beginPath(); let z = wrap(sec * 0.5, 1); circle(24 - z * 10, 26 - z * 18, 4 + z * 4); circle(30 - z * 6, 34 - z * 12, 3 + z * 3); c.drawPath(using: .fillStroke)
        rounded(18, 36, 15, 34, 2, fillHex: 0xE8675A)
        fill(0xFFFDF4); c.fill(CGRect(x: 19.2, y: 44, width: 12.6, height: 5))
        stroke(outline, 2); c.beginPath(); c.move(to: P(104, 72)); c.addLine(to: P(104, 28)); c.strokePath()
        fill(0xF7C948); stroke(outline, 1.6); poly([P(104, 28), P(118, 33 + sin(sec * 5) * 1.5), P(104, 38)]); c.drawPath(using: .fillStroke)
        face(66, 54, 0.96, h)
        fill(0xFFFDF4); stroke(outline, 2.2); c.beginPath(); c.move(to: P(0, 68)); c.addLine(to: P(122, 68)); c.addLine(to: P(106, 100)); quad(104, 104, 98, 104); c.addLine(to: P(18, 104)); quad(12, 104, 10, 100); c.closePath(); c.drawPath(using: .fillStroke)
        fill(0x3E6FB0); c.beginPath(); c.move(to: P(5.8, 86)); c.addLine(to: P(113, 86)); c.addLine(to: P(106, 100)); quad(104, 103, 98, 103); c.addLine(to: P(18, 103)); quad(12, 103, 11, 100); c.closePath(); c.fillPath()
        fill(0x8EC7E8); stroke(outline, 1.5); c.beginPath(); for x: CGFloat in [26, 46, 86] { circle(x, 77, 3.6) }; c.drawPath(using: .fillStroke)
        c.restoreGState()
        fill(0x6EC1E4, 0.95); stroke(outline, 2); c.beginPath(); c.move(to: P(-14, 112)); c.addLine(to: P(-14, 100))
        var x: CGFloat = -14
        while x < 132 { let y = 100 + sin((x + progress) * 0.22) * 2.6; c.addLine(to: P(x, y)); x += 3 }
        c.addLine(to: P(132, 112)); c.closePath(); c.drawPath(using: .fillStroke)
    }
}
