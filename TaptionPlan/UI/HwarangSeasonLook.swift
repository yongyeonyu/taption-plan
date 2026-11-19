import CoreGraphics

/// 시즌 팩이 모든 동작의 화랑이에게 입히는 복장(SEA1119A01). 모자는 그림 파일, 목도리·리본은 천 장식 색이고,
/// 여기서는 빨간 코만 머리 좌표에 직접 그린다. 세 고양이(화랑이·춘향이·윤복이)에 똑같이 나온다.
struct HwarangSeasonLook: Equatable, Sendable {
    var redNose = false
    /// 목도리 자리에 망토를 그린다(`scarf` 색을 망토 천 색으로 쓴다).
    var cape = false
    var scarf: HwarangClothStyle?
    var ribbon: HwarangClothStyle?

    var isEmpty: Bool { !redNose && scarf == nil && ribbon == nil }
}

extension HwarangPainter {
    /// 코 자리(`mx`, `my`)에 빨간 코를 얹는다. 작은 크기에서도 보이게 분홍 코보다 크게 그린다.
    func drawRedNose(x: CGFloat, y: CGFloat, lineWidth: CGFloat) {
        fill(0xE5392F); stroke(outline, max(lineWidth * 0.55, 0.9))
        c.beginPath(); circle(x, y - 1.5, 1.75); c.drawPath(using: .fillStroke)
        fill(0xB82A22); c.beginPath(); oval(x + 0.4, y - 0.6, 1.1, 0.5); c.fillPath()
        fill(white, 0.9); c.beginPath(); oval(x - 0.6, y - 2.3, 0.6, 0.4); c.fillPath()
    }

    private static func darkened(_ hex: UInt32, _ f: CGFloat) -> UInt32 { scaled(hex) { $0 * f } }
    private static func lightened(_ hex: UInt32, _ f: CGFloat) -> UInt32 { scaled(hex) { $0 + (255 - $0) * f } }
    private static func scaled(_ hex: UInt32, _ f: (CGFloat) -> CGFloat) -> UInt32 {
        func ch(_ s: UInt32) -> UInt32 { UInt32(max(0, min(255, f(CGFloat((hex >> s) & 0xFF))))) }
        return ch(16) << 16 | ch(8) << 8 | ch(0)
    }
}

/// 망토를 몸 자세에 따라 세 가지로 나눠 그린다(SEA1119A01).
/// - 누운·엎드린·책상 자세(`paintSeasonCape(clip:)`): 몸통이 가로로 길게 놓여 몸통 위쪽 반을 어깨에서 엉덩이까지 덮는다.
/// - 서거나 걷는 자세(`paintSeasonCape(blobs:spine:radius:upright: false)`): 등뼈선을 따라 등과 옆구리 위쪽 절반을 덮는다.
/// - 앉아서 다리를 든(그루밍) 자세(`upright: true`): 몸이 세워져 등 쪽 전체와 옆구리 대부분을 덮는다.
extension HwarangPainter {
    /// 누운 자세: 몸통 모양 안에서 등과 옆구리를 덮는 빨간 망토 천(하얀 털단 포함).
    func paintSeasonCape(clip: () -> Void) {
        guard let look = seasonLook, look.cape, let cloth = look.scarf else { return }
        c.saveGState(); clip(); c.clip()
        fill(cloth.base); c.beginPath(); oval(35, 70, 36, 17); c.fillPath()
        fill(cloth.shade, 0.55); c.beginPath(); oval(26, 80, 30, 9); c.fillPath()           // 아래·뒤쪽 그늘
        fill(white, 0.22); c.beginPath(); oval(44, 62, 20, 3.2); c.fillPath()                // 등 위쪽 빛
        stroke(0x1E120A, 0.9, 0.22); c.beginPath()
        for x: CGFloat in [20, 32, 44] { c.move(to: P(x, 62)); c.addQuadCurve(to: P(x - 3, 84), control: P(x + 2, 74)) }
        c.strokePath()
        var spots: [CGPoint] = stride(from: CGFloat(4), through: 62, by: 6.2).map { P($0, 85.5 - 1.2 * sin(($0 - 4) / 58 * .pi)) }
        spots += stride(from: CGFloat(62), through: 85, by: 5.5).map { P(1.5, $0) }
        furTrim(spots)
        c.restoreGState()
    }

    /// 서거나 걷거나(upright false) 앉아서 다리를 든(true) 자세: 등뼈선(`spine`: 엉덩이 → 어깨)과 몸 두께(`radius`)로 망토를 얹는다.
    func paintSeasonCape(blobs: [Blob], spine: [CGPoint], radius: (CGFloat) -> CGFloat, upright: Bool) {
        guard let look = seasonLook, look.cape, let cloth = look.scarf, spine.count >= 3 else { return }
        let count = spine.count
        // 등 쪽 법선: 왼쪽·위쪽(고양이는 오른쪽을 본다)을 향하는 수직 방향.
        func normal(_ i: Int) -> CGPoint {
            let a = spine[max(i - 1, 0)], b = spine[min(i + 1, count - 1)]
            let len = max(hypot(b.x - a.x, b.y - a.y), 0.01), n = P(-(b.y - a.y) / len, (b.x - a.x) / len)
            return (-n.y - n.x * 0.7) >= (n.y + n.x * 0.7) ? n : P(-n.x, -n.y)
        }
        // 몸이 세워진(앉은·밥 먹는) 자세는 등뼈선이 가파르다: 세워진 자세와 같은 방식(등 쪽 거의 전체)으로 덮는다.
        let steep = abs(spine[count - 1].y - spine[0].y) > abs(spine[count - 1].x - spine[0].x) * 0.55
        let coverage: CGFloat = (upright || steep) ? 0.95 : 0.72     // 몸 두께 중 등에서 아래로 덮는 비율
        var upper: [CGPoint] = [], lower: [CGPoint] = []
        // 엉덩이 끝을 조금 더 뒤로 연장해 엉덩이를 감싼다.
        let first = spine[0], second = spine[1], tail = P(first.x - (second.x - first.x) * 0.9, first.y - (second.y - first.y) * 0.9)
        for (k, q) in ([tail] + spine).enumerated() {
            let i = max(k - 1, 0), u = CGFloat(i) / CGFloat(count - 1), r = radius(u), n = normal(i)
            upper.append(P(q.x + n.x * (r + 1.8), q.y + n.y * (r + 1.8)))
            let drop = r * (1 - 2 * coverage)
            lower.append(P(q.x + n.x * drop, q.y + n.y * drop))
        }
        c.saveGState(); c.beginPath(); addBlobs(blobs); c.clip()
        func polygon(_ points: [CGPoint]) { c.beginPath(); c.move(to: points[0]); for q in points.dropFirst() { c.addLine(to: q) }; c.closePath() }
        fill(cloth.base); polygon(upper + lower.reversed()); c.fillPath()
        fill(cloth.shade, 0.5); polygon(lower + zip(lower, upper).map { P(lerp($0.x, $1.x, 0.55), lerp($0.y, $1.y, 0.55)) }.reversed()); c.fillPath()
        stroke(0x1E120A, 0.9, 0.22); c.beginPath()
        for i in stride(from: 2, to: count, by: 3) { c.move(to: upper[i]); c.addQuadCurve(to: lower[i], control: P(lerp(upper[i].x, lower[i].x, 0.5) + 1.5, lerp(upper[i].y, lower[i].y, 0.5))) }
        c.strokePath()
        // 털단: 아래 가장자리와 엉덩이 쪽 끝.
        var spots = lower.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element }
        let rump = (upper[0], lower[0])
        spots += (0...1).map { P(lerp(rump.0.x, rump.1.x, CGFloat($0) * 0.6), lerp(rump.0.y, rump.1.y, CGFloat($0) * 0.6)) }
        furTrim(spots)
        c.restoreGState()
    }

    /// 하얀 털단: 겹친 동그라미(윤곽 → 털색).
    private func furTrim(_ spots: [CGPoint]) {
        for pass in 0..<2 {
            for p in spots {
                if pass == 0 { fill(outline); c.beginPath(); circle(p.x, p.y, 4.5); c.fillPath() } else { fill(0xFFFDF8); c.beginPath(); circle(p.x, p.y, 3.5); c.fillPath() }
            }
        }
    }
}

extension HwarangPainter {
    /// 엉덩이 그루밍 자세의 작은 X 표시. 어두운 털(윤복이) 위에서도 보이게 진한 윤곽을 두르고 밝은 분홍빨강으로 칠한다.
    func drawRumpMark(at mark: CGPoint) {
        let r: CGFloat = 2.9
        c.setLineCap(.round)
        for (hex, width) in [(outline, CGFloat(3.9)), (0xFF4F78, CGFloat(2.0))] {
            stroke(hex, width); c.beginPath()
            c.move(to: P(mark.x - r, mark.y - r)); c.addLine(to: P(mark.x + r, mark.y + r))
            c.move(to: P(mark.x + r, mark.y - r)); c.addLine(to: P(mark.x - r, mark.y + r)); c.strokePath()
        }
    }
}
