import CoreGraphics

/// 시즌 팩이 모든 동작의 화랑이에게 입히는 복장(SEA1119A01). 모자는 그림 파일, 목도리·리본은 천 장식 색이고,
/// 여기서는 빨간 코와 사슴뿔 머리띠만 머리 좌표에 직접 그린다. 세 고양이(화랑이·춘향이·윤복이)에 똑같이 나온다.
struct HwarangSeasonLook: Equatable, Sendable {
    var redNose = false
    /// 사슴뿔 머리띠 색(RRGGBB). nil이면 달지 않는다.
    var antlers: UInt32?
    var scarf: HwarangClothStyle?
    var ribbon: HwarangClothStyle?

    var isEmpty: Bool { !redNose && antlers == nil && scarf == nil && ribbon == nil }
}

extension HwarangPainter {
    /// 머리 좌표계(머리 중심이 원점, 이미 기울고 크기가 맞춰진 상태)에서 사슴뿔 머리띠를 단다. 띠는 머리 윗선을 따라 모자 속으로 들어가고,
    /// 뿔은 모자 양옆으로 솟는다. 모자보다 먼저 그려 모자 밑단이 띠를 덮는다. 뿔은 끝으로 갈수록 가늘고 껍질 무늬·밝은 끝·방울이 있다.
    func drawAntlerHeadband(_ color: UInt32, turn t: CGFloat, lineWidth: CGFloat) {
        let shade = Self.darkened(color, 0.62), light = Self.lightened(color, 0.34), tip = Self.lightened(color, 0.62)
        let l = lerp(-17, -13, t), r = lerp(17, 21, t)
        // 머리띠: 겉선·본색·윗면 하이라이트.
        for (hex, w, dy): (UInt32, CGFloat, CGFloat) in [(outline, 3.8 + lineWidth * 0.2, 0), (shade, 2.3, 0), (light, 0.7, -0.5)] {
            stroke(hex, w, hex == light ? 0.7 : 1); c.beginPath(); c.move(to: P(l, -4 + dy)); quad(0, -22 + dy, r, -4 + dy); c.strokePath()
        }
        /// 점들을 지나는 부드러운 곡선을 마디마다 굵기를 줄여 그린다(끝이 가늘어지는 가지).
        func taper(_ pts: [CGPoint], _ w0: CGFloat, _ w1: CGFloat, grow: CGFloat, hex: UInt32, alpha: CGFloat = 1) {
            var samples: [CGPoint] = []
            for i in 0..<(pts.count - 1) {
                let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
                for k in 0..<6 {
                    let u = CGFloat(k) / 6, u2 = u * u, u3 = u2 * u
                    func cr(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat { 0.5 * (2 * b + (-a + c) * u + (2 * a - 5 * b + 4 * c - d) * u2 + (-a + 3 * b - 3 * c + d) * u3) }
                    samples.append(P(cr(p0.x, p1.x, p2.x, p3.x), cr(p0.y, p1.y, p2.y, p3.y)))
                }
            }
            samples.append(pts[pts.count - 1])
            for i in 0..<(samples.count - 1) {
                let u = CGFloat(i) / CGFloat(samples.count - 1)
                stroke(hex, lerp(w0, w1, u) + grow, alpha)
                c.beginPath(); c.move(to: samples[i]); c.addLine(to: samples[i + 1]); c.strokePath()
            }
        }
        let beam = [P(0, 2), P(2.2, -5), P(4.2, -12), P(6.4, -19), P(8.6, -25), P(9.6, -29.5)]
        let tines: [([CGPoint], CGFloat, CGFloat)] = [
            ([P(3.2, -9), P(1.6, -12.5), P(0.2, -16.8)], 2.3, 1),
            ([P(5.4, -15.5), P(8.4, -17), P(11.6, -17.4), P(13.8, -20)], 2.3, 1),
            ([P(7.6, -22.4), P(10.2, -24), P(11.6, -26.8)], 1.9, 0.9),
        ]
        for side: CGFloat in [-1, 1] {
            let bx = side < 0 ? lerp(-15.5, -12.5, t) : lerp(15.5, 18.5, t)
            let sx: CGFloat = side < 0 ? 1 : lerp(1, 0.88, t)
            c.saveGState(); c.translateBy(x: bx, y: -12); c.scaleBy(x: sx * side * 0.86, y: 0.86)
            c.setLineCap(.round); c.setLineJoin(.round)
            // 1) 겉선 2) 본색 3) 밝은 면 4) 껍질 무늬 5) 밝은 끝.
            taper(beam, 4, 1.6, grow: 1.9, hex: outline)
            for (pts, w0, w1) in tines { taper(pts, w0, w1, grow: 1.9, hex: outline) }
            taper(beam, 4, 1.6, grow: 0, hex: color)
            for (pts, w0, w1) in tines { taper(pts, w0, w1, grow: 0, hex: color) }
            taper(beam.map { P($0.x - 0.7, $0.y) }, 1.2, 0.4, grow: 0, hex: light, alpha: 0.75)
            stroke(shade, 0.7, 0.8); c.beginPath()
            for (x, y): (CGFloat, CGFloat) in [(2.0, -4), (3.4, -9.5), (5.4, -15), (7.4, -21)] { c.move(to: P(x - 1.3, y + 0.4)); c.addLine(to: P(x + 1.3, y - 0.5)) }
            c.strokePath()
            taper([P(8.6, -25), P(9.6, -29.5)], 1.7, 1.2, grow: 0, hex: tip)
            taper(Array(tines[0].0.suffix(2)), 1.2, 1, grow: 0, hex: tip)
            taper(Array(tines[1].0.suffix(2)), 1.3, 1, grow: 0, hex: tip)
            taper(Array(tines[2].0.suffix(2)), 1.1, 0.9, grow: 0, hex: tip)
            // 뿔 밑동의 작은 금빛 방울과 호랑가시 열매.
            fill(0xF4C84A); stroke(outline, 0.8); c.beginPath(); circle(-1.6, 2.2, 2.1); c.drawPath(using: .fillStroke)
            stroke(0xB88A22, 0.5); c.beginPath(); c.move(to: P(-3.4, 2.5)); c.addLine(to: P(0.2, 2.5)); c.strokePath()
            fill(white, 0.85); c.beginPath(); circle(-2.3, 1.4, 0.55); c.fillPath()
            fill(0x2F9E58); stroke(outline, 0.6); c.beginPath(); oval(2.2, 3.4, 2.4, 1.1); c.drawPath(using: .fillStroke)
            fill(0xE5392F); c.beginPath(); circle(1.2, 3.6, 0.9); circle(2.4, 3.9, 0.9); c.fillPath()
            c.restoreGState()
        }
    }

    /// 코 자리(`mx`, `my`)에 빨간 코를 얹는다. 작은 크기에서도 보이게 분홍 코보다 크게 그린다.
    func drawRedNose(x: CGFloat, y: CGFloat, lineWidth: CGFloat) {
        fill(0xE5392F); stroke(outline, max(lineWidth * 0.55, 0.9))
        c.beginPath(); circle(x, y - 0.6, 2.4); c.drawPath(using: .fillStroke)
        fill(0xB82A22); c.beginPath(); oval(x + 0.5, y + 0.6, 1.5, 0.7); c.fillPath()
        fill(white, 0.9); c.beginPath(); oval(x - 0.9, y - 1.5, 0.8, 0.55); c.fillPath()
        fill(white, 0.5); c.beginPath(); circle(x + 0.9, y - 0.3, 0.3); c.fillPath()
    }

    private static func darkened(_ hex: UInt32, _ f: CGFloat) -> UInt32 { scaled(hex) { $0 * f } }
    private static func lightened(_ hex: UInt32, _ f: CGFloat) -> UInt32 { scaled(hex) { $0 + (255 - $0) * f } }
    private static func scaled(_ hex: UInt32, _ f: (CGFloat) -> CGFloat) -> UInt32 {
        func ch(_ s: UInt32) -> UInt32 { UInt32(max(0, min(255, f(CGFloat((hex >> s) & 0xFF))))) }
        return ch(16) << 16 | ch(8) << 8 | ch(0)
    }
}
