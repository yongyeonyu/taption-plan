import SwiftUI

/// 집 아이콘 원 안에 그리는 날씨 그림의 종류(WTH1102A01).
enum MapHomeHomeWeatherKind: CaseIterable, Sendable {
    case sun, partlyCloudy, moon, cloud, fog, rain, heavyRain, snow, thunder, wind, typhoon

    init(symbolName: String) {
        let symbol = symbolName.lowercased()
        if symbol.contains("hurricane") || symbol.contains("tropicalstorm") || symbol.contains("tornado") {
            self = .typhoon
        } else if symbol.contains("bolt") || symbol.contains("thunder") {
            self = .thunder
        } else if symbol.contains("snow") || symbol.contains("sleet") || symbol.contains("hail") {
            self = .snow
        } else if symbol.contains("heavyrain") {
            self = .heavyRain
        } else if symbol.contains("rain") || symbol.contains("drizzle") {
            self = .rain
        } else if symbol.contains("wind") {
            self = .wind
        } else if symbol.contains("fog") || symbol.contains("haze") || symbol.contains("smoke") || symbol.contains("dust") {
            self = .fog
        } else if symbol.contains("cloud.sun") || symbol.contains("sun.cloud") || symbol.contains("cloud.moon") {
            self = .partlyCloudy
        } else if symbol.contains("cloud") {
            self = .cloud
        } else if symbol.contains("moon") {
            self = .moon
        } else {
            self = .sun
        }
    }
}

extension MapHomeHomeWeatherKind {
    /// 사이드바 날씨 칸의 아이콘. 비·눈·번개·바람·태풍을 서로 다른 기호로 보여 준다.
    var sidebarSymbol: String {
        switch self {
        case .sun: "sun.max.fill"
        case .partlyCloudy: "cloud.sun.fill"
        case .moon: "moon.stars.fill"
        case .cloud: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .rain: "cloud.rain.fill"
        case .heavyRain: "cloud.heavyrain.fill"
        case .snow: "cloud.snow.fill"
        case .thunder: "cloud.bolt.rain.fill"
        case .wind: "wind"
        case .typhoon: "hurricane"
        }
    }

    /// 남은 시간대 칸의 배경색. 흰 글자가 읽히는 진하기로 맞췄다.
    var sidebarFillHex: String {
        switch self {
        case .sun: "#D9902B"
        case .partlyCloudy: "#6E9CC2"
        case .moon: "#4A5490"
        case .cloud: "#7F8B98"
        case .fog: "#8F99A3"
        case .rain: "#4279B5"
        case .heavyRain: "#2F5A86"
        case .snow: "#7BA6C8"
        case .thunder: "#544B88"
        case .wind: "#4F9C92"
        case .typhoon: "#4A5663"
        }
    }
}

/// 날씨 애니메이션. 화랑이와 같은 시계·같은 갱신 간격으로 움직인다.
struct MapHomeHomeWeatherArt: View {
    let kind: MapHomeHomeWeatherKind
    var windSpeed: Double = 0
    var size: CGFloat = MapHomePlacePinLayout.avatarSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let isStatic = reduceMotion || isLuminanceReduced
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: isStatic)) { context in
            MapHomeHomeWeatherFrame(kind: kind, sec: isStatic ? 1 : HwarangClock.seconds(at: context.date), windSpeed: windSpeed, size: size)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 정한 시각의 날씨 그림 한 장. 좌표는 원 지름 78 기준이다.
struct MapHomeHomeWeatherFrame: View {
    let kind: MapHomeHomeWeatherKind
    let sec: Double
    /// 초속(m/s). 바람 그림 속도와 비·눈이 기우는 정도를 정한다.
    var windSpeed: Double = 0
    var size: CGFloat = MapHomePlacePinLayout.avatarSize

    /// 이 풍속부터는 맑은 날에도 바람 줄기를 함께 그린다.
    static let visibleWindSpeed = 7.0

    /// 그림이 움직이는 배속. 잔잔하면 천천히, 강풍이면 최대 4배로 빠르다.
    static func windMotion(speed: Double) -> CGFloat {
        CGFloat(min(4, max(0.7, speed / 4)))
    }

    private var slant: CGFloat { CGFloat(min(22, windSpeed * 1.1)) }

    private static let outline = Color(hex: "#5A4033")

    var body: some View {
        Canvas { context, canvasSize in
            let k = canvasSize.width / 78
            context.scaleBy(x: k, y: k)
            draw(&context, t: CGFloat(sec))
            if windSpeed >= Self.visibleWindSpeed, kind != .wind, kind != .typhoon {
                wind(&context, t: CGFloat(sec))
            }
        }
        .frame(width: size, height: size)
    }

    private func wrap(_ value: CGFloat, _ modulus: CGFloat) -> CGFloat {
        let r = value.truncatingRemainder(dividingBy: modulus)
        return r < 0 ? r + modulus : r
    }

    private func draw(_ c: inout GraphicsContext, t: CGFloat) {
        switch kind {
        case .sun:
            sun(&c, t: t, x: 18, y: 24, r: 8)
        case .partlyCloudy:
            sun(&c, t: t, x: 18, y: 22, r: 7)
            cloud(&c, x: 30 + sin(t * 0.5) * 4, y: 27, k: 0.95, color: Color(hex: "#FFFFFF"))
        case .moon:
            sky(&c, Color(hex: "#27306B"), 0.28)
            moon(&c, t: t)
        case .cloud:
            sky(&c, Color(hex: "#7B8794"), 0.12)
            cloud(&c, x: 10 + sin(t * 0.4) * 3, y: 25, k: 1, color: Color(hex: "#C8D0D8"))
            cloud(&c, x: 38 - sin(t * 0.5) * 4, y: 29, k: 1.05, color: Color(hex: "#E4E8EC"))
        case .fog:
            sky(&c, Color(hex: "#9AA5AE"), 0.2)
            fog(&c, t: t)
        case .rain:
            sky(&c, Color(hex: "#5F7486"), 0.2)
            rain(&c, t: t, count: 9, slant: 3 + slant, speed: 62)
            cloud(&c, x: 8 + sin(t * 0.4) * 2, y: 24, k: 1.1, color: Color(hex: "#98A5B1"))
            cloud(&c, x: 36 - sin(t * 0.45) * 3, y: 26, k: 1.1, color: Color(hex: "#AEBAC4"))
        case .heavyRain:
            sky(&c, Color(hex: "#46586A"), 0.3)
            rain(&c, t: t, count: 16, slant: 6 + slant, speed: 92)
            cloud(&c, x: 6 + sin(t * 0.5) * 2, y: 24, k: 1.2, color: Color(hex: "#6F7D8A"))
            cloud(&c, x: 36 - sin(t * 0.55) * 3, y: 25, k: 1.2, color: Color(hex: "#7F8D9A"))
        case .snow:
            sky(&c, Color(hex: "#A9C3D8"), 0.2)
            snow(&c, t: t)
            cloud(&c, x: 10 + sin(t * 0.4) * 3, y: 24, k: 1, color: Color(hex: "#DDE5EC"))
            cloud(&c, x: 38 - sin(t * 0.4) * 3, y: 27, k: 1, color: Color(hex: "#EEF2F6"))
        case .thunder:
            sky(&c, Color(hex: "#303A4A"), 0.34)
            rain(&c, t: t, count: 11, slant: 5 + slant, speed: 84)
            let flash = wrap(t, 3.4)
            if flash < 0.32 {
                bolt(&c, x: 34)
                if flash < 0.1 || (flash > 0.18 && flash < 0.24) {
                    c.fill(Path(CGRect(x: 0, y: 0, width: 78, height: 78)), with: .color(.white.opacity(0.42)))
                }
            }
            cloud(&c, x: 7, y: 24, k: 1.2, color: Color(hex: "#59636F"))
            cloud(&c, x: 36, y: 25, k: 1.2, color: Color(hex: "#6B7581"))
        case .wind:
            wind(&c, t: t)
        case .typhoon:
            sky(&c, Color(hex: "#3F4C5A"), 0.3)
            rain(&c, t: t, count: 14, slant: 16 + slant, speed: 96)
            typhoon(&c, t: t)
        }
    }

    private func sky(_ c: inout GraphicsContext, _ color: Color, _ alpha: Double) {
        c.fill(Path(CGRect(x: 0, y: 0, width: 78, height: 78)), with: .color(color.opacity(alpha)))
    }

    private func sun(_ c: inout GraphicsContext, t: CGFloat, x: CGFloat, y: CGFloat, r: CGFloat) {
        var rays = Path()
        for i in 0..<8 {
            let a = t * 0.7 + CGFloat(i) * .pi / 4
            let reach = r + 5 + sin(t * 2 + CGFloat(i)) * 1
            rays.move(to: CGPoint(x: x + cos(a) * (r + 2), y: y + sin(a) * (r + 2)))
            rays.addLine(to: CGPoint(x: x + cos(a) * reach, y: y + sin(a) * reach))
        }
        c.stroke(rays, with: .color(Color(hex: "#F2A93B")), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        let disk = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        c.fill(disk, with: .color(Color(hex: "#FFD24D")))
        c.stroke(disk, with: .color(Self.outline), lineWidth: 1)
    }

    private func moon(_ c: inout GraphicsContext, t: CGFloat) {
        var crescent = Path()
        crescent.addArc(center: CGPoint(x: 20, y: 24), radius: 9, startAngle: .degrees(60), endAngle: .degrees(-60 + 360), clockwise: false)
        crescent.addQuadCurve(to: CGPoint(x: 24.5, y: 31.8), control: CGPoint(x: 15, y: 24))
        crescent.closeSubpath()
        c.fill(crescent, with: .color(Color(hex: "#FFE08A")))
        c.stroke(crescent, with: .color(Self.outline), lineWidth: 1)
        for (i, star) in [CGPoint(x: 38, y: 19), CGPoint(x: 50, y: 25), CGPoint(x: 62, y: 18), CGPoint(x: 32, y: 32)].enumerated() {
            let r = 1 + (sin(t * 2.4 + CGFloat(i) * 1.7) + 1) * 0.55
            c.fill(Path(ellipseIn: CGRect(x: star.x - r, y: star.y - r, width: r * 2, height: r * 2)), with: .color(.white))
        }
    }

    private func cloud(_ c: inout GraphicsContext, x: CGFloat, y: CGFloat, k: CGFloat, color: Color) {
        var shape = Path()
        for (dx, dy, r) in [(CGFloat(5), CGFloat(3), CGFloat(5)), (13, -1, 7.5), (23, 1, 6), (30, 4, 4.5)] {
            shape.addEllipse(in: CGRect(x: x + (dx - r) * k, y: y + (dy - r) * k, width: r * 2 * k, height: r * 2 * k))
        }
        shape.addRoundedRect(in: CGRect(x: x + 1 * k, y: y + 3 * k, width: 33 * k, height: 5.5 * k), cornerSize: CGSize(width: 2.7 * k, height: 2.7 * k))
        // 겹친 원 안쪽 선이 보이지 않게 윤곽을 먼저 그리고 면으로 덮는다.
        c.stroke(shape, with: .color(Self.outline), lineWidth: 2)
        c.fill(shape, with: .color(color))
    }

    private func rain(_ c: inout GraphicsContext, t: CGFloat, count: Int, slant: CGFloat, speed: CGFloat) {
        var drops = Path()
        for i in 0..<count {
            let n = CGFloat(i)
            let y = 28 + wrap(t * speed + n * 37, 44)
            let x = wrap(n * 23.7 + 6 + (y - 28) * slant / 44 * -1, 78)
            drops.move(to: CGPoint(x: x, y: y))
            drops.addLine(to: CGPoint(x: x - slant * 0.12, y: y + 5))
        }
        c.stroke(drops, with: .color(Color(hex: "#4B9FDB")), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }

    /// 눈꽃 결정. 크기·모양·회전이 송이마다 다르다.
    private func snow(_ c: inout GraphicsContext, t: CGFloat) {
        for i in 0..<12 {
            let n = CGFloat(i)
            let speed = 9 + wrap(n * 5.3, 7)
            let y = 24 + wrap(t * speed + n * 21, 52)
            let drift = (y - 24) * slant / 52
            let x = wrap(n * 19.3 + 5 + drift, 78) + sin(t * 1.1 + n * 1.7) * 2.6
            let radius = 2 + wrap(n * 1.37, 1) * 2.8
            let spin = Double(t) * (i % 2 == 0 ? 0.8 : -0.6) + Double(n)
            snowflake(&c, x: x, y: y, radius: radius, spin: spin, style: i % 4)
        }
    }

    private func snowflake(_ c: inout GraphicsContext, x: CGFloat, y: CGFloat, radius r: CGFloat, spin: Double, style: Int) {
        var flake = Path()
        for arm in 0..<6 {
            let a = CGFloat(arm) * .pi / 3
            let dx = cos(a), dy = sin(a)
            flake.move(to: .zero)
            flake.addLine(to: CGPoint(x: dx * r, y: dy * r))
            // 모양마다 곁가지 위치와 수가 다르다.
            let branches: [(CGFloat, CGFloat)] = switch style {
            case 0: [(0.62, 0.34)]
            case 1: [(0.42, 0.28), (0.74, 0.24)]
            case 2: [(0.8, 0.42)]
            default: []
            }
            for (at, length) in branches {
                let base = CGPoint(x: dx * r * at, y: dy * r * at)
                for side: CGFloat in [-1, 1] {
                    let b = a + side * .pi / 3
                    flake.move(to: base)
                    flake.addLine(to: CGPoint(x: base.x + cos(b) * r * length, y: base.y + sin(b) * r * length))
                }
            }
        }
        var layer = c
        layer.translateBy(x: x, y: y)
        layer.rotate(by: .radians(spin))
        layer.stroke(flake, with: .color(Color(hex: "#7E9DB6")), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        layer.stroke(flake, with: .color(.white), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
        if style == 3 {
            let dot = Path(ellipseIn: CGRect(x: -r * 0.3, y: -r * 0.3, width: r * 0.6, height: r * 0.6))
            layer.fill(dot, with: .color(.white))
        }
    }

    private func bolt(_ c: inout GraphicsContext, x: CGFloat) {
        var path = Path()
        path.addLines([
            CGPoint(x: x + 5, y: 30), CGPoint(x: x - 3, y: 44), CGPoint(x: x + 2, y: 44),
            CGPoint(x: x - 4, y: 58), CGPoint(x: x + 9, y: 40), CGPoint(x: x + 3, y: 40), CGPoint(x: x + 10, y: 30)
        ])
        path.closeSubpath()
        c.fill(path, with: .color(Color(hex: "#FFD84D")))
        c.stroke(path, with: .color(Self.outline), lineWidth: 1)
    }

    private func fog(_ c: inout GraphicsContext, t: CGFloat) {
        for i in 0..<4 {
            let n = CGFloat(i)
            let y = 22 + n * 13
            var band = Path()
            let shift = sin(t * 0.6 + n) * 7
            band.move(to: CGPoint(x: 4 + shift, y: y))
            band.addCurve(to: CGPoint(x: 74 + shift, y: y), control1: CGPoint(x: 26 + shift, y: y - 3), control2: CGPoint(x: 50 + shift, y: y + 3))
            c.stroke(band, with: .color(.white.opacity(0.78)), style: StrokeStyle(lineWidth: 4.4, lineCap: .round))
        }
    }

    private func wind(_ c: inout GraphicsContext, t rawT: CGFloat) {
        let t = rawT * Self.windMotion(speed: windSpeed)
        for i in 0..<3 {
            let n = CGFloat(i)
            let y = 22 + n * 12
            let x = wrap(t * 26 + n * 31, 110) - 34
            var gust = Path()
            gust.move(to: CGPoint(x: x, y: y))
            gust.addLine(to: CGPoint(x: x + 24, y: y))
            gust.addArc(center: CGPoint(x: x + 24, y: y - 3.5), radius: 3.5, startAngle: .degrees(90), endAngle: .degrees(-120), clockwise: true)
            c.stroke(gust, with: .color(Self.outline), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            c.stroke(gust, with: .color(Color(hex: "#CFE3EC")), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            // 바람에 날리는 잎
            let leafX = wrap(t * 34 + n * 47, 100) - 12
            let leafY = y + 7 + sin(t * 4 + n) * 3
            var leaf = c
            leaf.translateBy(x: leafX, y: leafY)
            leaf.rotate(by: .radians(Double(t) * 3 + Double(n)))
            let shape = Path(ellipseIn: CGRect(x: -2.6, y: -1.3, width: 5.2, height: 2.6))
            leaf.fill(shape, with: .color(Color(hex: "#8DB255")))
            leaf.stroke(shape, with: .color(Self.outline), lineWidth: 0.7)
        }
    }

    private func typhoon(_ c: inout GraphicsContext, t: CGFloat) {
        var spin = c
        spin.translateBy(x: 26, y: 28)
        spin.rotate(by: .radians(-Double(t) * 3 * Double(Self.windMotion(speed: windSpeed))))
        for arm in 0..<3 {
            var path = Path()
            for j in 0...16 {
                let u = CGFloat(j) / 16
                let a = u * 3.4 + CGFloat(arm) * 2 * .pi / 3
                let r = 2.5 + u * 17
                let point = CGPoint(x: cos(a) * r, y: sin(a) * r * 0.82)
                if j == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            spin.stroke(path, with: .color(Self.outline), style: StrokeStyle(lineWidth: 4.6, lineCap: .round))
            spin.stroke(path, with: .color(Color(hex: "#D5DCE3")), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        }
    }
}
