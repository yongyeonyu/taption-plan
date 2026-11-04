import CoreGraphics

/// 장면 소품: 글자·책·실타래·밥그릇·매트·나무·쳇바퀴·노트북·모니터·샤워기.
extension HwarangPainter {
    func letterZ(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat, alpha: CGFloat) {
        stroke(0x5E78C4, max(1.4, size * 0.2), alpha); c.setLineJoin(.round); c.beginPath()
        c.addLines(between: [P(x, y - size), P(x + size * 0.7, y - size), P(x, y), P(x + size * 0.7, y)]); c.strokePath()
    }

    func sleepLetters(_ sec: CGFloat) {
        let z = wrap(sec * 0.5, 1)
        letterZ(98 + z * 10, 48 - z * 16, 7 + z * 4, alpha: 1 - z)
        letterZ(110 + z * 8, 34 - z * 8, 8 + z * 4, alpha: max(0, 1 - abs(z - 0.5) * 2))
    }

    func questionMark(_ sec: CGFloat) {
        let y = 16 + sin(sec * 2.2) * 3
        stroke(0x7A5FC6, 3.6); c.setLineCap(.round); c.beginPath()
        c.addArc(center: P(106, y), radius: 5.4, startAngle: .pi, endAngle: .pi * 0.4 + tau, clockwise: false)
        c.addLine(to: P(106, y + 11)); c.strokePath()
        fill(0x7A5FC6); c.beginPath(); circle(106, y + 16.5, 2.2); c.fillPath()
    }

    func book(_ flip: CGFloat) {
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

    func yarn(_ x: CGFloat, _ y: CGFloat, _ rot: CGFloat) {
        fill(0xE96A8A); stroke(outline, 2.2); c.beginPath(); circle(x, y, 8); c.drawPath(using: .fillStroke)
        stroke(0xA83E5C, 1.1); c.beginPath(); c.addArc(center: P(x - 1, y), radius: 5, startAngle: 0.5 + rot, endAngle: 3 + rot, clockwise: false); c.strokePath()
        c.beginPath(); c.addArc(center: P(x + 1, y), radius: 5, startAngle: -1 + rot, endAngle: 1.5 + rot, clockwise: false); c.strokePath()
    }

    /// 밥그릇은 발 앞 낮은 곳에 놓아 숙인 머리와 겹치지 않는다.
    func bowl() {
        let x: CGFloat = 86, rim: CGFloat = 113
        fill(0xE46F7E); stroke(outline, 2.2); c.setLineJoin(.round); poly([P(x - 17, rim), P(x + 17, rim), P(x + 12, rim + 12), P(x - 12, rim + 12)]); c.drawPath(using: .fillStroke)
        fill(0x8B5A2B); c.beginPath(); oval(x, rim - 1, 15, 3.2); c.drawPath(using: .fillStroke)
    }

    /// 건강 장면 바닥의 요가 매트. 오른쪽 끝은 말려 있다.
    func yogaMat() {
        let top: CGFloat = groundY - 7, bottom: CGFloat = groundY + 11
        c.setLineJoin(.round); c.setLineCap(.round)
        fill(0x6F5BB5); stroke(outline, 2.2); poly([P(-11, bottom), P(120, bottom), P(120, bottom + 3), P(-11, bottom + 3)]); c.drawPath(using: .fillStroke)
        fill(0xA796E6); poly([P(-5, top), P(118, top), P(120, bottom), P(-11, bottom)]); c.drawPath(using: .fillStroke)
        stroke(0xC7BBF2, 1.4); c.beginPath()
        for x: CGFloat in stride(from: 8, through: 100, by: 23) { c.move(to: P(x, top + 2.5)); c.addLine(to: P(x - 2, bottom - 2.5)) }
        c.strokePath()
        fill(0x8C79D6); stroke(outline, 2.2); c.beginPath(); circle(121, groundY + 2, 9); c.drawPath(using: .fillStroke)
        stroke(0x5A4799, 1.3); c.beginPath(); c.addArc(center: P(121, groundY + 2), radius: 5.2, startAngle: 0.4, endAngle: 0.4 + tau * 0.8, clockwise: false); c.addArc(center: P(121, groundY + 2), radius: 2, startAngle: 0.4, endAngle: 0.4 + tau * 0.6, clockwise: false); c.strokePath()
    }

    func trees(_ offset: CGFloat) {
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

    func wheel(_ rotation: CGFloat) {
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
    func laptop(_ sec: CGFloat) {
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

    /// 업무 휴식 소품: 낮은 책상과 켜 둔 모니터. 고양이 앞발이 책상 위에 얹힌다.
    func deskMonitor(_ sec: CGFloat) {
        c.setLineJoin(.round); c.setLineCap(.round)
        for x: CGFloat in [84, 122] { rounded(x, deskTop + 3, 5, groundY - deskTop - 3, 1, fillHex: 0x9A6B43) }
        rounded(78, deskTop, 53, 6, 2, fillHex: 0xC98F58)
        rounded(108, 72, 8, deskTop - 74, 1, fillHex: 0x8996A5)
        rounded(100, deskTop - 4, 24, 4.5, 2, fillHex: 0xB9C3CE)
        rounded(93, 38, 38, 36, 3, fillHex: 0x46525F)
        fill(0x17243A); c.fill(CGRect(x: 96.5, y: 41.5, width: 31, height: 29))
        let widths: [CGFloat] = [20, 14, 24, 10], colors: [UInt32] = [0x7CC4FF, 0xF2A7C3, 0xA6E3A1, 0xF7C948]
        for i in 0..<4 {
            let y = 47 + CGFloat(i) * 5.5
            stroke(colors[i], 1.6, 0.85); c.beginPath(); c.move(to: P(100, y)); c.addLine(to: P(100 + widths[i], y)); c.strokePath()
        }
        if wrap(sec * 1.1, 1) < 0.55 {
            stroke(white, 1.4); c.beginPath(); c.move(to: P(112.5, 62)); c.addLine(to: P(112.5, 66)); c.strokePath()
        }
    }

    /// 옆구리에 낀 닫힌 노트북. 몸 쪽에서 덮개 면이 보인다. 차지한 윤곽을 돌려줘 앞다리가 그 위에 얹히게 한다.
    func heldLaptop(center q: CGPoint) -> CGPath {
        let box = CGRect(x: -21, y: -13, width: 42, height: 26)
        var place = CGAffineTransform(translationX: q.x, y: q.y).rotated(by: -0.1)
        var lower = place.translatedBy(x: 0, y: 3.2)
        let lid = CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: &place)
        let base = CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: &lower)
        c.setLineJoin(.round)
        fill(0x8996A5); stroke(outline, outlineWidth * 0.8); c.addPath(base); c.drawPath(using: .fillStroke)
        fill(0xC6CFD9); stroke(outline, outlineWidth * 0.8); c.addPath(lid); c.drawPath(using: .fillStroke)
        fill(0xF7FAFC); c.beginPath(); circle(q.x - 7, q.y + 2, 3.4); c.fillPath()
        return CGPath(roundedRect: CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height + 3.2), cornerWidth: 3, cornerHeight: 3, transform: &place)
    }

    func yarnPosition(_ beat: Int, _ s: CGFloat, _ u: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        switch beat {
        case 1: return (102, groundY - 8 - sin(u * .pi) * 4, s * 0.5)
        case 2: return (104 + sin(s * 5) * 8, groundY - 8 - abs(sin(s * 5)) * 3, s * 5)
        case 3: return (lerp(112, 124, u), groundY - 8, s * 7)
        case 4: return (58 + sin(s * 6) * 3, 58 + cos(s * 6) * 2, s * 4)
        case 5: return (74, groundY - 8, 0)
        default: return (102, groundY - 8, s * 0.5)
        }
    }

    func showerFixture() {
        stroke(outline, 5.6); c.setLineCap(.round); c.beginPath(); c.move(to: P(106, 66)); c.addLine(to: P(106, 8)); quad(106, 3, 100, 3); c.addLine(to: P(72, 3)); quad(67, 3, 67, 10); c.strokePath()
        stroke(0xC9D3DC, 2.2); c.beginPath(); c.move(to: P(106, 66)); c.addLine(to: P(106, 8)); quad(106, 3, 100, 3); c.addLine(to: P(72, 3)); quad(67, 3, 67, 10); c.strokePath()
        rounded(98, 62, 16, 7, 3, fillHex: 0xC9D3DC, line: 1.8)
        fill(0xC9D3DC); stroke(outline, 2.2); c.beginPath(); c.move(to: P(45, 19)); quad(67, 3, 89, 19); c.closePath(); c.drawPath(using: .fillStroke)
        fill(0x9FB0BD); stroke(outline, 2); c.beginPath(); oval(67, 19, 22, 3.6); c.drawPath(using: .fillStroke)
    }

    func waterStreams(_ sec: CGFloat, xs: [CGFloat], alpha: CGFloat) {
        stroke(0x5DB7EA, 1.9, alpha); c.setLineCap(.round); c.setLineDash(phase: -sec * 70, lengths: [7, 6]); c.beginPath()
        for x in xs { c.move(to: P(x, 23)); c.addLine(to: P(67 + (x - 67) * 1.25, groundY - 2)) }
        c.strokePath(); c.setLineDash(phase: 0, lengths: [])
    }
}
