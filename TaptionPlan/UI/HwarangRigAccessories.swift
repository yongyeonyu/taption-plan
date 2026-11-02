import CoreGraphics

/// 화랑이가 걸치는 천 장식의 색과 무늬(ACC1102A01). 표는 `HwarangRigAccessoryStyles.swift`에 있다.
enum HwarangClothPattern: Sendable {
    case stripes, bands, dots, waves, check, diamonds, zigzag, scales
}

struct HwarangClothStyle: Equatable, Sendable {
    let base: UInt32, shade: UInt32, accent: UInt32, trim: UInt32
    let pattern: HwarangClothPattern
}

/// 머리와 어깨 위치로 정해지는 목 자세. 스카프는 머리 뒤에서 나와 턱 밑을 감싼다.
struct HwarangNeck {
    var head: CGPoint
    var tilt: CGFloat
    /// 머리 중심에서 어깨로 가는 단위 벡터.
    var toward: CGPoint
    /// 머리가 어깨에 가까울수록 0에 가깝다. 띠를 머리 쪽으로 당겨 몸 밖으로 삐져나오지 않게 한다.
    var snug: CGFloat

    init(head: CGPoint, shoulder: CGPoint, tilt: CGFloat) {
        self.head = head
        self.tilt = tilt
        // 머리가 어깨에 바짝 붙어도 방향이 튀지 않게 아래쪽으로 조금 끌어 잡는다.
        let dx = shoulder.x - head.x, dy = shoulder.y - head.y + 6
        let length = max(hypot(dx, dy), 0.01)
        toward = P(dx / length, dy / length)
        snug = clamp((length - 10) / 14, 0, 1)
    }
}

extension HwarangPainter {
    /// 머리 윤곽 반지름. 턱이 넓은 머리에 맞춰 3제곱 초타원으로 잰다.
    private func headRadius(_ angle: CGFloat, hs: CGFloat) -> CGFloat {
        let a = 20.6 * hs, b = 15 * hs
        return 1 / cbrt(pow(abs(cos(angle)) / a, 3) + pow(abs(sin(angle)) / b, 3))
    }

    private func ribbonPolygon(_ points: [CGPoint], widths: [CGFloat]) -> [CGPoint] {
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in points.indices {
            let a = points[max(i - 1, 0)], b = points[min(i + 1, points.count - 1)]
            let length = max(hypot(b.x - a.x, b.y - a.y), 0.01)
            let nx = -(b.y - a.y) / length, ny = (b.x - a.x) / length
            left.append(P(points[i].x + nx * widths[i], points[i].y + ny * widths[i]))
            right.append(P(points[i].x - nx * widths[i], points[i].y - ny * widths[i]))
        }
        return left + right.reversed()
    }

    private func addSmooth(_ points: [CGPoint]) {
        c.beginPath(); c.addLines(between: points); c.closePath()
    }

    /// 천 위의 (u, v)를 화면 좌표로 옮기는 함수를 받아 무늬를 얹는다. u는 길이 방향(0...length), v는 폭(-1...1).
    private func drawPattern(_ style: HwarangClothStyle, length: CGFloat, map: (CGFloat, CGFloat) -> CGPoint) {
        let color = style.accent
        func line(_ points: [CGPoint], _ width: CGFloat, alpha: CGFloat = 1) {
            stroke(color, width, alpha); c.setLineCap(.butt); c.beginPath(); c.addLines(between: points); c.strokePath()
        }
        func along(_ v: (CGFloat) -> CGFloat) -> [CGPoint] {
            stride(from: 0, through: length, by: 1).map { map($0, v($0)) }
        }
        switch style.pattern {
        case .stripes:
            for u in stride(from: CGFloat(1.5), to: length, by: 4.4) { line([map(u, -1), map(u + 1.4, 1)], 1.7) }
        case .bands:
            line(along { _ in -0.42 }, 1.5); line(along { _ in 0.42 }, 0.9)
        case .dots:
            fill(color); c.beginPath()
            for (i, u) in stride(from: CGFloat(1.5), to: length, by: 3.1).enumerated() {
                let q = map(u, i % 2 == 0 ? -0.45 : 0.45)
                circle(q.x, q.y, 0.95)
            }
            c.fillPath()
        case .waves:
            line(along { sin($0 * 1.15) * 0.42 }, 1.15)
        case .check:
            for u in stride(from: CGFloat(1), to: length, by: 3.6) { line([map(u, -1), map(u, 1)], 1.15, alpha: 0.8) }
            line(along { _ in -0.3 }, 1.15, alpha: 0.8); line(along { _ in 0.4 }, 1.15, alpha: 0.8)
        case .diamonds:
            fill(color); c.beginPath()
            for (i, u) in stride(from: CGFloat(1.5), to: length, by: 3.4).enumerated() {
                let v: CGFloat = i % 2 == 0 ? -0.42 : 0.42
                c.addLines(between: [map(u - 1.1, v), map(u, v - 0.38), map(u + 1.1, v), map(u, v + 0.38)]); c.closePath()
            }
            c.fillPath()
        case .zigzag:
            line(along { abs(($0 / 2.4).truncatingRemainder(dividingBy: 2) - 1) * 1.1 - 0.55 }, 1.2)
        case .scales:
            for (i, u) in stride(from: CGFloat(1.5), to: length, by: 2.8).enumerated() {
                let v: CGFloat = i % 2 == 0 ? -0.42 : 0.42
                line([map(u - 1.4, v + 0.2), map(u, v - 0.34), map(u + 1.4, v + 0.2)], 0.9)
            }
        }
    }

    // MARK: - 스카프

    /// 천 끝 한 가닥의 중심선. 위쪽 마디는 지금 움직임, 끝 마디는 조금 전 움직임에 끌려 끝이 늦게 따라온다.
    private func strandPoints(from start: CGPoint, count: Int, step: CGFloat, swing: [CGVector], wind: CGFloat, phase: CGFloat, spread: CGFloat) -> [CGPoint] {
        var points = [start]
        var q = start
        for i in 0..<count {
            let u = CGFloat(i + 1) / CGFloat(count)
            let v = swing.isEmpty ? CGVector.zero : swing[min(i, swing.count - 1)]
            let lean = clamp(v.dx * 0.018 + wind + spread, -1.15, 1.3)
            let lift = clamp(v.dy * 0.006, -0.25, 0.25)
            let a = .pi / 2 + lean * (0.55 + u * 0.45) + lift * lean + sin(phase - CGFloat(i) * 0.8) * (0.05 + abs(wind) * 0.22) * u
            q.x += cos(a) * step; q.y += sin(a) * step
            // 바닥에 닿으면 늘어지는 쪽으로 눕는다.
            if q.y > groundY - 1 { q.y = groundY - 1; q.x += (lean >= 0 ? -1 : 1) * step * 0.35 }
            points.append(q)
        }
        return points
    }

    /// 납작한 천 한 가닥: 바탕 → 무늬 → 끝단 띠 → 접힘 그늘 → 윤곽 → 술.
    private func drawStrand(_ points: [CGPoint], rootWidth: CGFloat, tipWidth: CGFloat, style: HwarangClothStyle, base: UInt32, patterned: Bool) {
        let count = CGFloat(points.count - 1)
        let widths = points.indices.map { lerp(rootWidth, tipWidth, CGFloat($0) / count) }
        let outlinePath = ribbonPolygon(points, widths: widths)
        let line = max(outlineWidth * 0.72, 1.5)
        c.setLineJoin(.round); c.setLineCap(.round)
        // 술은 면보다 먼저 그려 뿌리가 끝단 뒤로 숨는다.
        let tip = points[points.count - 1], before = points[points.count - 2]
        let len = max(hypot(tip.x - before.x, tip.y - before.y), 0.01)
        let tx = (tip.x - before.x) / len, ty = (tip.y - before.y) / len
        if !small {
            stroke(outline, 1); c.beginPath()
            for d in stride(from: -0.7, through: 0.7, by: 0.35) {
                let root = P(tip.x - ty * tipWidth * d, tip.y + tx * tipWidth * d)
                c.move(to: root); c.addLine(to: P(root.x + tx * 2.6, root.y + ty * 2.6))
            }
            c.strokePath()
        }
        fill(base); addSmooth(outlinePath); c.fillPath()
        c.saveGState(); addSmooth(outlinePath); c.clip()
        if patterned, !small {
            func map(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
                let f = clamp(u / max(count * 3.2, 1), 0, 1) * count, i = min(Int(f), points.count - 2), r = f - CGFloat(i)
                let a = points[i], b = points[i + 1]
                let l = max(hypot(b.x - a.x, b.y - a.y), 0.01)
                let w = lerp(rootWidth, tipWidth, f / count) * v
                return P(lerp(a.x, b.x, r) - (b.y - a.y) / l * w, lerp(a.y, b.y, r) + (b.x - a.x) / l * w)
            }
            drawPattern(style, length: count * 3.2, map: map)
        }
        // 끝단 띠
        stroke(style.trim, small ? 3 : 2.6); c.setLineCap(.butt); c.beginPath()
        let band = P(tip.x - tx * 1.5, tip.y - ty * 1.5)
        c.move(to: P(band.x - ty * tipWidth * 1.2, band.y + tx * tipWidth * 1.2)); c.addLine(to: P(band.x + ty * tipWidth * 1.2, band.y - tx * tipWidth * 1.2)); c.strokePath()
        // 매듭 쪽으로 드리운 그늘
        fill(0x1E120A, 0.24); c.beginPath()
        let root = points[0], next = points[min(1, points.count - 1)]
        let rl = max(hypot(next.x - root.x, next.y - root.y), 0.01)
        c.addEllipse(in: CGRect(x: root.x - rootWidth * 1.3, y: root.y - rootWidth * 0.9 + (next.y - root.y) / rl, width: rootWidth * 2.6, height: rootWidth * 1.9))
        c.fillPath()
        c.restoreGState()
        stroke(outline, line); c.setLineCap(.round); addSmooth(outlinePath); c.strokePath()
    }

    /// 머리보다 먼저, 몸보다 나중에 부른다. 띠는 머리 윤곽을 따라 돌고 양 끝은 머리 뒤로 숨는다.
    /// `swing`은 지금부터 과거로 갈수록 오래된 머리 속도(세계 좌표/초), `wind`는 달리는 바람(뒤쪽이 양수)이다.
    func drawScarf(_ style: HwarangClothStyle, neck: HwarangNeck, swing: [CGVector], wind: CGFloat, phase: CGFloat, showsStrands: Bool = true) {
        let hs: CGFloat = small ? 1.72 : 1.5
        let center = atan2(neck.toward.y, neck.toward.x)
        let span: CGFloat = 0.92, half: CGFloat = small ? 5 : 4.4, peak: CGFloat = small ? 4.6 : 4
        let samples = 24
        func pointOn(_ t: CGFloat, _ v: CGFloat) -> CGPoint {
            let a = center + t * span
            let tuck = pow(abs(t), 1.7)
            // 가운데는 턱 밖으로 나오고, 양 끝으로 갈수록 머리 안쪽으로 들어간다.
            let r = headRadius(a - neck.tilt, hs: hs) + peak * (1 - tuck) - 5 * tuck + half * v * (1 - tuck * 0.35) - (1 - neck.snug) * 7
            return P(neck.head.x + cos(a) * r, neck.head.y + sin(a) * r)
        }
        let line = max(outlineWidth * 0.8, 1.6)
        c.setLineJoin(.round); c.setLineCap(.round)

        let knotT: CGFloat = 0.1
        let knot = pointOn(knotT, 0.35)
        if showsStrands {
            // 뒤 가닥은 짧고 어둡게, 앞 가닥은 길게. 몸 뒤쪽으로 벌어진다.
            let behind = strandPoints(from: P(knot.x - 1, knot.y), count: 4, step: 3, swing: swing, wind: wind, phase: phase + 1.2, spread: 0.42)
            drawStrand(behind, rootWidth: 2.7, tipWidth: 3.5, style: style, base: style.shade, patterned: false)
        }

        // 고리 띠
        let upper = (0...samples).map { pointOn(CGFloat($0) / CGFloat(samples) * 2 - 1, -1) }
        let lower = (0...samples).map { pointOn(CGFloat($0) / CGFloat(samples) * 2 - 1, 1) }
        let band = upper + lower.reversed()
        fill(style.base); addSmooth(band); c.fillPath()
        c.saveGState(); addSmooth(band); c.clip()
        if !small {
            let length: CGFloat = 40
            drawPattern(style, length: length) { u, v in pointOn(u / length * 2 - 1, v) }
        }
        // 턱 밑 그늘과 바깥쪽 접힘, 위쪽 빛.
        stroke(0x1E120A, small ? 2.2 : 1.8, 0.2); c.beginPath(); c.addLines(between: (0...samples).map { pointOn(CGFloat($0) / CGFloat(samples) * 2 - 1, -0.55) }); c.strokePath()
        if !small {
            stroke(0x1E120A, 0.9, 0.3); c.beginPath(); c.addLines(between: (4...20).map { pointOn(CGFloat($0) / CGFloat(samples) * 2 - 1, 0.45) }); c.strokePath()
            stroke(white, 1, 0.42); c.beginPath(); c.addLines(between: (15...22).map { pointOn(CGFloat($0) / CGFloat(samples) * 2 - 1, 0.74) }); c.strokePath()
        }
        c.restoreGState()
        stroke(outline, line); addSmooth(band); c.strokePath()

        if showsStrands {
            let front = strandPoints(from: knot, count: 5, step: small ? 3.2 : 3.3, swing: swing, wind: wind, phase: phase, spread: -0.08)
            drawStrand(front, rootWidth: 3, tipWidth: small ? 4.6 : 4.2, style: style, base: style.base, patterned: true)
        }
        // 매듭
        let knotR: CGFloat = small ? 4.2 : 3.5
        c.saveGState(); c.translateBy(x: knot.x, y: knot.y); c.rotate(by: center - .pi / 2 + neck.tilt * 0.3)
        fill(style.base); stroke(outline, line); c.beginPath()
        c.addPath(CGPath(roundedRect: CGRect(x: -knotR, y: -knotR * 0.86, width: knotR * 2, height: knotR * 1.72), cornerWidth: knotR * 0.6, cornerHeight: knotR * 0.6, transform: nil))
        c.drawPath(using: .fillStroke)
        if !small {
            stroke(0x1E120A, 0.8, 0.34); c.beginPath(); c.move(to: P(-knotR * 0.42, -knotR * 0.5)); c.addQuadCurve(to: P(-knotR * 0.42, knotR * 0.5), control: P(-knotR * 0.1, 0))
            c.move(to: P(knotR * 0.42, -knotR * 0.5)); c.addQuadCurve(to: P(knotR * 0.42, knotR * 0.5), control: P(knotR * 0.1, 0)); c.strokePath()
            fill(style.trim); c.beginPath(); circle(0, 0, 0.9); c.fillPath()
        }
        c.restoreGState()
    }

    // MARK: - 꼬리 리본

    /// 꼬리 중심선을 받아 끝 근처에 띠를 감고 나비매듭을 묶는다. 끈은 꼬리 흔들림을 조금 늦게 따른다.
    /// `along`은 꼬리 뿌리(0)에서 끝(1) 사이 묶는 자리다.
    func drawTailRibbon(_ style: HwarangClothStyle, tail: [CGPoint], radius: CGFloat, sway: CGFloat, phase: CGFloat, along: CGFloat = 0.74) {
        guard tail.count >= 3 else { return }
        let index = max(1, min(Int((CGFloat(tail.count - 1) * along).rounded()), tail.count - 2))
        let q = tail[index], a = tail[index - 1], b = tail[index + 1]
        let heading = atan2(b.y - a.y, b.x - a.x)
        let line = max(outlineWidth * 0.72, 1.4), k: CGFloat = small ? 1.18 : 1
        c.setLineJoin(.round); c.setLineCap(.round)
        c.saveGState(); c.translateBy(x: q.x, y: q.y); c.rotate(by: heading)

        // 꼬리를 감은 띠. 원통을 도는 것처럼 살짝 휜다.
        let wrap = radius + 0.3
        fill(style.base); stroke(outline, line); c.beginPath()
        c.move(to: P(-2.4, -wrap)); c.addQuadCurve(to: P(-2.4, wrap), control: P(-0.6, 0))
        c.addLine(to: P(2.4, wrap)); c.addQuadCurve(to: P(2.4, -wrap), control: P(4.2, 0)); c.closePath()
        c.drawPath(using: .fillStroke)

        // 끈: 나비매듭에서 꼬리 뿌리 쪽으로 늘어진다.
        for (i, side) in [CGFloat(-1), 1].enumerated() {
            var points = [CGPoint.zero], p = CGPoint.zero
            for j in 0..<4 {
                let u = CGFloat(j + 1) / 4
                let angle = .pi - side * (0.42 + u * 0.12) + sin(phase - CGFloat(j) * 0.7 - CGFloat(i) * 0.6) * (0.12 + sway * 0.5) * u
                p.x += cos(angle) * 3 * k; p.y += sin(angle) * 3 * k
                points.append(p)
            }
            drawRibbonTail(points, style: style)
        }

        // 나비 고리: 꼬리와 수직으로 벌어지고 끈보다 조금 늦게 까딱인다.
        let flutter = sin(phase - 0.9) * (0.05 + sway * 0.16)
        for side: CGFloat in [-1, 1] {
            c.saveGState(); c.rotate(by: flutter * side); c.scaleBy(x: k, y: k * side)
            let length: CGFloat = 10.2 + sin(phase - 0.4 + side) * 0.5
            func loop() {
                c.beginPath(); c.move(to: P(0, 0.6))
                c.addCurve(to: P(5.4, length), control1: P(4.6, 2), control2: P(7.4, length - 2.6))
                c.addCurve(to: P(-5.4, length), control1: P(2.8, length + 1.8), control2: P(-2.8, length + 1.8))
                c.addCurve(to: P(0, 0.6), control1: P(-7.4, length - 2.6), control2: P(-4.6, 2))
                c.closePath()
            }
            fill(style.base); loop(); c.fillPath()
            c.saveGState(); loop(); c.clip()
            if !small {
                drawPattern(style, length: 10) { u, v in P(v * 5.6, 1 + u) }
            }
            // 고리 안쪽 그늘과 바깥 빛.
            fill(style.shade, 0.92); c.beginPath(); c.move(to: P(0, 2)); c.addCurve(to: P(0, length - 3.2), control1: P(3.4, 4), control2: P(3.2, length - 3.4)); c.addCurve(to: P(0, 2), control1: P(-3.2, length - 3.4), control2: P(-3.4, 4)); c.fillPath()
            if !small {
                stroke(white, 0.9, 0.5); c.beginPath(); c.move(to: P(-3.6, length - 0.2)); c.addQuadCurve(to: P(3.6, length - 0.2), control: P(0, length + 1.4)); c.strokePath()
            }
            c.restoreGState()
            stroke(outline, line / k); loop(); c.strokePath()
            c.restoreGState()
        }
        // 매듭
        fill(style.trim); stroke(outline, line); c.beginPath()
        let r: CGFloat = 2.9 * k
        c.addPath(CGPath(roundedRect: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), cornerWidth: r * 0.6, cornerHeight: r * 0.6, transform: nil)); c.drawPath(using: .fillStroke)
        c.restoreGState()
    }

    private func drawRibbonTail(_ points: [CGPoint], style: HwarangClothStyle) {
        let widths = points.indices.map { lerp(1.6, 2.5, CGFloat($0) / CGFloat(points.count - 1)) * (small ? 1.2 : 1) }
        let polygon = ribbonPolygon(points, widths: widths)
        // 끝을 제비꼬리로 판다.
        let tip = points[points.count - 1], before = points[points.count - 2]
        let notch = P(lerp(tip.x, before.x, 0.55), lerp(tip.y, before.y, 0.55))
        let mid = polygon.count / 2
        let shape = Array(polygon[0..<mid]) + [notch] + Array(polygon[mid...])
        fill(style.shade); addSmooth(shape); c.fillPath()
        stroke(outline, max(outlineWidth * 0.66, 1.2)); addSmooth(shape); c.strokePath()
    }
}
