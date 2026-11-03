import CoreGraphics
import CoreText
import Foundation

/// 스티커 한 장의 색 규칙. 단색 2D(`mono`)만 사용자가 색을 바꾼다.
enum StickerStyle: String, Sendable {
    case mono = "m"
    case multi = "c"
    case puffy = "d"

    var isRecolorable: Bool { self == .mono }
}

/// 100×100 격자 위 벡터 문구를 읽어 CoreGraphics로 그린다. 외부 이미지를 쓰지 않는다.
///
/// 한 줄 = 그림 하나, `;`로 층을 나눈다. 층 = `색 모양 인자…`.
/// - 색: `T`(사용자 색), `k`(검정), 이름표 색, `#RRGGBB`, 파츠 안의 `A`·`B`·`C`. 뒤에 `!`를 붙이면 테두리를 두르지 않는다.
/// - 모양: `o cx cy r` · `e cx cy rx ry [각도]` · `b x y w h r [각도]` · `p 둥글기 x y x y…` · `s M..L..Q..C..Z`
///   `l 굵기 x y x y…` · `q 굵기 x0 y0 cx cy x1 y1` · `t cx cy 크기 글자` · `star cx cy R r n [각도]` · `heart cx cy 크기`
/// - 파츠: `@이름 cx cy 배율 [각도] [A=색 B=색]`
enum StickerArtEngine {
    static let ink = CGColor(srgbRed: 0.09, green: 0.08, blue: 0.09, alpha: 1)
    /// 바깥 테두리 두께(격자 단위). 작게 줄여도 잘 보이게 두껍게 둔다.
    static let outerWidth: CGFloat = 3.6
    static let innerWidth: CGFloat = 2.4

    static let palette: [String: UInt32] = [
        "w": 0xFFFFFF, "cream": 0xFFF6E3, "rose": 0xF28FA9, "sky": 0xA9CFF0, "mint": 0x8FD9C5,
        "butter": 0xF2D58D, "lilac": 0xC2B4E9, "peach": 0xF2B18D, "red": 0xE8655F, "orange": 0xF39A4A,
        "yellow": 0xF9D65C, "green": 0x7CC46F, "leaf": 0x5FAE6B, "blue": 0x5BA8E5, "navy": 0x3E5C9A,
        "purple": 0x9C7FD6, "pink": 0xF7B6C6, "brown": 0xA9744F, "tan": 0xD9AE7E, "choco": 0x6F4A36,
        "gray": 0xB9BEC6, "dark": 0x5A5560
    ]

    enum Paint: Hashable, Sendable {
        case tint
        case ink
        case rgb(UInt32)
    }

    enum Shape {
        case fill(CGPath)
        case stroke(CGPath, width: CGFloat)
    }

    struct Layer {
        var paint: Paint
        var shape: Shape
        var outlined: Bool
    }

    /// 파싱 결과. 문구가 잘못되면 `problems`에 남겨 테스트가 잡는다.
    struct Drawing {
        var layers: [Layer] = []
        var problems: [String] = []

        var usesTint: Bool { layers.contains { $0.paint == .tint } }
        var usesOtherColor: Bool {
            layers.contains { if case .rgb = $0.paint { true } else { false } }
        }
    }

    static func parse(_ source: String, parts: [String: String]) -> Drawing {
        var drawing = Drawing()
        append(source, transform: .identity, colors: [:], parts: parts, depth: 0, into: &drawing)
        return drawing
    }

    private static func append(
        _ source: String,
        transform: CGAffineTransform,
        colors: [String: String],
        parts: [String: String],
        depth: Int,
        into drawing: inout Drawing
    ) {
        for rawOp in source.split(separator: ";") {
            let tokens = rawOp.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let head = tokens.first else { continue }
            if head.hasPrefix("@") {
                appendPart(tokens, transform: transform, colors: colors, parts: parts, depth: depth, into: &drawing)
                continue
            }
            let outlined = !head.hasSuffix("!")
            let colorName = outlined ? head : String(head.dropLast())
            guard tokens.count >= 2, let paint = paint(colorName, colors: colors) else {
                drawing.problems.append("색 또는 층을 읽지 못함: \(rawOp)")
                continue
            }
            guard let shape = shape(Array(tokens.dropFirst()), transform: transform) else {
                drawing.problems.append("모양을 읽지 못함: \(rawOp)")
                continue
            }
            drawing.layers.append(Layer(paint: paint, shape: shape, outlined: outlined))
        }
    }

    private static func appendPart(
        _ tokens: [String],
        transform: CGAffineTransform,
        colors: [String: String],
        parts: [String: String],
        depth: Int,
        into drawing: inout Drawing
    ) {
        let name = String(tokens[0].dropFirst())
        guard depth < 4, let source = parts[name] else {
            drawing.problems.append("파츠 없음: \(name)")
            return
        }
        var numbers: [CGFloat] = []
        var inner = colors
        for token in tokens.dropFirst() {
            if let split = token.firstIndex(of: "=") {
                let value = String(token[token.index(after: split)...])
                inner[String(token[..<split])] = colors[value] ?? value
            } else if let number = Double(token) {
                numbers.append(CGFloat(number))
            }
        }
        let center = CGPoint(x: numbers.count > 0 ? numbers[0] : 50, y: numbers.count > 1 ? numbers[1] : 50)
        let scale = numbers.count > 2 ? numbers[2] : 1
        let degrees = numbers.count > 3 ? numbers[3] : 0
        // 파츠는 (50,50)을 기준으로 그려 두고 옮겨 쓴다. 적용 순서: 기준점 이동 → 회전·배율 → 자리로.
        var next = CGAffineTransform(translationX: -50, y: -50)
        next = next.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        next = next.concatenating(CGAffineTransform(rotationAngle: degrees * .pi / 180))
        next = next.concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        append(source, transform: next.concatenating(transform), colors: inner, parts: parts, depth: depth + 1, into: &drawing)
    }

    private static func paint(_ name: String, colors: [String: String]) -> Paint? {
        if let mapped = colors[name], mapped != name { return paint(mapped, colors: colors) }
        if name == "T" { return .tint }
        if name == "k" { return .ink }
        if let value = palette[name] { return .rgb(value) }
        if name.hasPrefix("#"), let value = UInt32(name.dropFirst(), radix: 16) { return .rgb(value) }
        return nil
    }

    private static func shape(_ tokens: [String], transform: CGAffineTransform) -> Shape? {
        let kind = tokens[0]
        let args = tokens.dropFirst()
        let numbers = args.compactMap { Double($0).map { CGFloat($0) } }
        var t = transform
        switch kind {
        case "o":
            guard numbers.count == 3 else { return nil }
            return .fill(CGPath(ellipseIn: CGRect(x: numbers[0] - numbers[2], y: numbers[1] - numbers[2], width: numbers[2] * 2, height: numbers[2] * 2), transform: &t))
        case "e":
            guard numbers.count >= 4 else { return nil }
            let rect = CGRect(x: -numbers[2], y: -numbers[3], width: numbers[2] * 2, height: numbers[3] * 2)
            var local = rotation(numbers.count > 4 ? numbers[4] : 0, around: CGPoint(x: numbers[0], y: numbers[1])).concatenating(t)
            return .fill(CGPath(ellipseIn: rect, transform: &local))
        case "b":
            guard numbers.count >= 5 else { return nil }
            let radius = min(numbers[4], min(numbers[2], numbers[3]) / 2)
            let rect = CGRect(x: -numbers[2] / 2, y: -numbers[3] / 2, width: numbers[2], height: numbers[3])
            let center = CGPoint(x: numbers[0] + numbers[2] / 2, y: numbers[1] + numbers[3] / 2)
            var local = rotation(numbers.count > 5 ? numbers[5] : 0, around: center).concatenating(t)
            return .fill(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: &local))
        case "p":
            guard numbers.count >= 7, numbers.count % 2 == 1 else { return nil }
            return .fill(roundedPolygon(points(numbers.dropFirst()), radius: numbers[0], transform: t))
        case "s":
            guard let path = svgPath(args.joined(separator: " "), transform: t) else { return nil }
            return .fill(path)
        case "l":
            guard numbers.count >= 5, numbers.count % 2 == 1 else { return nil }
            let path = CGMutablePath()
            path.addLines(between: points(numbers.dropFirst()), transform: t)
            return .stroke(path, width: numbers[0] * scaleOf(t))
        case "q":
            guard numbers.count == 7 else { return nil }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: numbers[1], y: numbers[2]), transform: t)
            path.addQuadCurve(to: CGPoint(x: numbers[5], y: numbers[6]), control: CGPoint(x: numbers[3], y: numbers[4]), transform: t)
            return .stroke(path, width: numbers[0] * scaleOf(t))
        case "t":
            guard tokens.count >= 5,
                  let x = Double(tokens[1]), let y = Double(tokens[2]), let size = Double(tokens[3]) else { return nil }
            let text = tokens[4...].joined(separator: " ")
            return textPath(text, center: CGPoint(x: x, y: y), size: CGFloat(size), transform: t).map(Shape.fill)
        case "star":
            guard numbers.count >= 5 else { return nil }
            let center = CGPoint(x: numbers[0], y: numbers[1])
            let tips = Int(numbers[4])
            let start = (numbers.count > 5 ? numbers[5] : 0) - 90
            let vertices = (0..<(tips * 2)).map { index -> CGPoint in
                let radius = index.isMultiple(of: 2) ? numbers[2] : numbers[3]
                let angle = (start + CGFloat(index) * 180 / CGFloat(tips)) * .pi / 180
                return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            }
            return .fill(roundedPolygon(vertices, radius: numbers[2] * 0.12, transform: t))
        case "heart":
            guard numbers.count == 3 else { return nil }
            return .fill(heartPath(CGPoint(x: numbers[0], y: numbers[1]), size: numbers[2], transform: t))
        default:
            return nil
        }
    }

    private static func points(_ numbers: ArraySlice<CGFloat>) -> [CGPoint] {
        let values = Array(numbers)
        return stride(from: 0, to: values.count - 1, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) }
    }

    private static func rotation(_ degrees: CGFloat, around center: CGPoint) -> CGAffineTransform {
        CGAffineTransform(rotationAngle: degrees * .pi / 180)
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }

    private static func scaleOf(_ t: CGAffineTransform) -> CGFloat {
        hypot(t.a, t.b)
    }

    private static func roundedPolygon(_ vertices: [CGPoint], radius: CGFloat, transform: CGAffineTransform) -> CGPath {
        let path = CGMutablePath()
        let count = vertices.count
        let last = vertices[count - 1], first = vertices[0]
        path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2), transform: transform)
        for index in 0..<count {
            let corner = vertices[index]
            let next = vertices[(index + 1) % count]
            path.addArc(tangent1End: corner, tangent2End: CGPoint(x: (corner.x + next.x) / 2, y: (corner.y + next.y) / 2), radius: radius, transform: transform)
        }
        path.closeSubpath()
        return path
    }

    /// 통통한 하트. (x, y) 가운데, `size`는 전체 폭.
    private static func heartPath(_ center: CGPoint, size: CGFloat, transform: CGAffineTransform) -> CGPath {
        let w = size / 2
        let path = CGMutablePath()
        func p(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: center.x + dx * w, y: center.y + dy * w) }
        path.move(to: p(0, 0.9), transform: transform)
        path.addCurve(to: p(-1, -0.3), control1: p(-0.5, 0.55), control2: p(-1, 0.2), transform: transform)
        path.addCurve(to: p(0, -0.42), control1: p(-1, -1.0), control2: p(-0.25, -1.05), transform: transform)
        path.addCurve(to: p(1, -0.3), control1: p(0.25, -1.05), control2: p(1, -1.0), transform: transform)
        path.addCurve(to: p(0, 0.9), control1: p(1, 0.2), control2: p(0.5, 0.55), transform: transform)
        path.closeSubpath()
        return path
    }

    /// 절대 좌표 `M L Q C Z`만 읽는다.
    private static func svgPath(_ text: String, transform: CGAffineTransform) -> CGPath? {
        let path = CGMutablePath()
        var scanner = Array(text.replacingOccurrences(of: ",", with: " ").split(whereSeparator: \.isWhitespace).map(String.init).flatMap(splitCommand))
        scanner.reverse()
        func number() -> CGFloat? { scanner.popLast().flatMap(Double.init).map { CGFloat($0) } }
        func point() -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: x, y: y)
        }
        while let command = scanner.popLast() {
            switch command {
            case "M":
                guard let target = point() else { return nil }
                path.move(to: target, transform: transform)
            case "L":
                guard let target = point(), !path.isEmpty else { return nil }
                path.addLine(to: target, transform: transform)
            case "Q":
                guard let control = point(), let target = point(), !path.isEmpty else { return nil }
                path.addQuadCurve(to: target, control: control, transform: transform)
            case "C":
                guard let a = point(), let b = point(), let target = point(), !path.isEmpty else { return nil }
                path.addCurve(to: target, control1: a, control2: b, transform: transform)
            case "Z":
                path.closeSubpath()
            default:
                return nil
            }
        }
        return path.isEmpty ? nil : path
    }

    private static func splitCommand(_ token: String) -> [String] {
        guard let first = token.first, first.isLetter, token.count > 1 else { return [token] }
        return [String(first), String(token.dropFirst())]
    }

    /// 글자는 윤곽 경로로 바꿔 테두리와 크기를 그림과 똑같이 다룬다. 폭이 넘치면 줄인다.
    private static func textPath(_ text: String, center: CGPoint, size: CGFloat, transform: CGAffineTransform) -> CGPath? {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        let line = CTLineCreateWithAttributedString(attributed)
        let glyphs = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            // 글꼴에 없는 글자는 CoreText가 대체 글꼴로 돌리므로 런의 글꼴로 윤곽을 얻는다.
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName as String] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var runGlyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &runGlyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for index in 0..<count {
                guard let glyph = CTFontCreatePathForGlyph(runFont, runGlyphs[index], nil) else { continue }
                glyphs.addPath(glyph, transform: CGAffineTransform(translationX: positions[index].x, y: positions[index].y))
            }
        }
        guard !glyphs.isEmpty else { return nil }
        let bounds = glyphs.boundingBoxOfPath
        let shrink = min(1, 84 / max(bounds.width, 1))
        // 글자 좌표는 위로 커지므로 뒤집어 격자에 맞춘다.
        var place = CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY)
        place = place.concatenating(CGAffineTransform(scaleX: shrink, y: -shrink))
        place = place.concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        place = place.concatenating(transform)
        return glyphs.copy(using: &place)
    }

    // MARK: - 그리기

    /// y가 아래로 커지는 `side`×`side` 컨텍스트에 그린다.
    static func draw(_ drawing: Drawing, style: StickerStyle, tint: UInt32, in context: CGContext, side: CGFloat) {
        context.saveGState()
        context.scaleBy(x: side / 100, y: side / 100)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        drawSilhouette(drawing, in: context)
        for layer in drawing.layers {
            draw(layer, style: style, color: color(layer.paint, tint: tint), in: context)
        }
        context.restoreGState()
    }

    /// 모든 층을 먼저 검게 두껍게 그려 바깥 테두리를 하나로 잇는다.
    private static func drawSilhouette(_ drawing: Drawing, in context: CGContext) {
        context.setStrokeColor(ink)
        context.setFillColor(ink)
        for layer in drawing.layers where layer.outlined {
            switch layer.shape {
            case .fill(let path):
                context.addPath(path)
                context.fillPath()
                context.addPath(path)
                context.setLineWidth(outerWidth * 2)
                context.strokePath()
            case .stroke(let path, let width):
                context.addPath(path)
                context.setLineWidth(width + outerWidth * 2)
                context.strokePath()
            }
        }
    }

    private static func draw(_ layer: Layer, style: StickerStyle, color: CGColor, in context: CGContext) {
        switch layer.shape {
        case .stroke(let path, let width):
            context.addPath(path)
            context.setStrokeColor(color)
            context.setLineWidth(width)
            context.strokePath()
        case .fill(let path):
            if style == .puffy, layer.paint != .ink, layer.outlined {
                fillPuffy(path, color: color, in: context)
            } else {
                context.addPath(path)
                context.setFillColor(color)
                context.fillPath()
            }
            if layer.outlined, layer.paint != .ink {
                context.addPath(path)
                context.setStrokeColor(ink)
                context.setLineWidth(innerWidth)
                context.strokePath()
            }
        }
    }

    /// 입체 스티커: 메뉴 아이콘처럼 위가 밝고 아래가 어두운 면에 윗쪽 광택을 얹는다.
    private static func fillPuffy(_ path: CGPath, color: CGColor, in context: CGContext) {
        let bounds = path.boundingBoxOfPath
        context.saveGState()
        context.addPath(path)
        context.clip()
        let colors = [mix(color, toward: 1, by: 0.32), color, mix(color, toward: 0, by: 0.18)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.55, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX, y: bounds.minY), end: CGPoint(x: bounds.midX, y: bounds.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        if min(bounds.width, bounds.height) >= 14 {
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5))
            context.fillEllipse(in: CGRect(
                x: bounds.minX + bounds.width * 0.14,
                y: bounds.minY + bounds.height * 0.07,
                width: bounds.width * 0.5,
                height: bounds.height * 0.2
            ))
        }
        context.restoreGState()
    }

    private static func color(_ paint: Paint, tint: UInt32) -> CGColor {
        switch paint {
        case .ink: ink
        case .tint: cgColor(tint)
        case .rgb(let value): cgColor(value)
        }
    }

    static func cgColor(_ value: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func mix(_ color: CGColor, toward target: CGFloat, by amount: CGFloat) -> CGColor {
        let c = color.components ?? [0, 0, 0, 1]
        return CGColor(
            srgbRed: c[0] + (target - c[0]) * amount,
            green: c[1] + (target - c[1]) * amount,
            blue: c[2] + (target - c[2]) * amount,
            alpha: 1
        )
    }
}
