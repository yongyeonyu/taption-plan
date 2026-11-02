import CoreLocation
import SwiftUI

/// 하늘 그림이 읽는 지도 위쪽 방위. 관찰하지 않는 값이라 지도가 돌아도 화면 전체를 다시 그리지 않는다.
enum MapHomeHomeSkyHeading {
    @MainActor static var current = 0.0
}

/// 집 하늘에 필요한 위치와 시각 출처. 재생 분은 관찰하지 않는 값을 프레임마다 읽는다.
struct MapHomeHomeSkyInput {
    let coordinate: CLLocationCoordinate2D
    let selectedDay: Date
    var progress: MapHomePlaybackProgress? = nil
    var isPlaybackRunning = false

    /// 지도가 보여 주는 시각. 재생 중이면 재생 분, 시간을 골랐으면 그 분, 오늘이면 지금, 지난 날이면 그날 23:59다.
    @MainActor
    func displayDate(now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let dayStart = calendar.startOfDay(for: selectedDay)
        if let minute = progress?.rawCurrentMinute ?? progress?.rawSelectedMinute.map(Double.init) {
            return dayStart.addingTimeInterval(min(minute, 1_439) * 60)
        }
        if calendar.isDate(selectedDay, inSameDayAs: now) { return now }
        return dayStart.addingTimeInterval(1_439 * 60)
    }

    @MainActor
    func state(now: Date) -> MapHomeSkyState {
        let date = displayDate(now: now)
        return MapHomeSkyState(date: date, window: .current(at: date, coordinate: coordinate))
    }
}

/// 집 그림 조각들이 함께 쓰는 시계. 저전력·동작 줄이기·조도 낮음에서는 움직임을 멈추고 시각만 분 단위로 맞춘다.
struct MapHomeHomeArtClock<Content: View>: View {
    var minimumInterval = 1.0 / 24
    var progress: MapHomePlaybackProgress? = nil
    @ViewBuilder let content: (_ date: Date, _ sec: Double) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        Group {
            if reduceMotion || isLuminanceReduced || isLowPower {
                // 시계가 멈춰 있어도 시간을 고르거나 재생하면 그 시각으로 다시 그린다.
                let _ = progress?.selectedMinute
                let _ = progress?.coarseTick
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    content(context.date, 1)
                }
            } else {
                TimelineView(.animation(minimumInterval: minimumInterval)) { context in
                    content(context.date, HwarangClock.seconds(at: context.date))
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)
        ) { _ in
            isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}

/// 집 뒤에 그리는 하늘. 재생 중에는 해·달 위치만 따라가면 되므로 갱신을 줄인다.
struct MapHomeHomeSkyArt: View {
    let input: MapHomeHomeSkyInput
    var kind: MapHomeHomeWeatherKind?
    var windSpeed: Double = 0
    var size: CGFloat = MapHomePlacePinLayout.avatarSize

    var body: some View {
        MapHomeHomeArtClock(
            minimumInterval: input.isPlaybackRunning ? 1.0 / 8 : 1.0 / 24,
            progress: input.progress
        ) { date, sec in
            MapHomeHomeSkyFrame(
                state: input.state(now: date),
                kind: kind,
                sec: sec,
                windSpeed: windSpeed,
                headingDegrees: MapHomeHomeSkyHeading.current,
                size: size
            )
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension MapHomeHomeWeatherKind {
    /// 하늘을 가리는 정도. 해·달의 진하기와 하늘의 채도를 줄인다.
    var skyCover: Double {
        switch self {
        case .sun, .moon: 0
        case .wind: 0.1
        case .partlyCloudy: 0.2
        case .snow: 0.62
        case .cloud: 0.68
        case .fog: 0.75
        case .rain: 0.8
        case .heavyRain: 0.92
        case .thunder, .typhoon: 1
        }
    }
}

private struct MapHomeSkyRGB {
    let r, g, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r / 255
        self.g = g / 255
        self.b = b / 255
    }

    private init(raw r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    func mixed(_ other: Self, _ u: Double) -> Self {
        Self(raw: r + (other.r - r) * u, g + (other.g - g) * u, b + (other.b - b) * u)
    }

    /// 같은 밝기의 회색 쪽으로 옮긴다. 구름 낀 하늘은 시간대 밝기를 지키며 색만 빠진다.
    func clouded(_ cover: Double) -> Self {
        let gray = (r * 0.3 + g * 0.59 + b * 0.11) * 0.92
        return mixed(Self(raw: gray, gray, min(1, gray * 1.05)), cover)
    }

    var color: Color { Color(red: r, green: g, blue: b) }
}

/// 고도별 하늘색. 같은 고도라도 동틀 때는 분홍·살구, 질 때는 주황·자주 쪽이다.
private enum MapHomeSkyPalette {
    struct Stop {
        let altitude: Double
        let top, bottom: MapHomeSkyRGB
    }

    static let night = MapHomeSkyRGB(13, 19, 66), nightLow = MapHomeSkyRGB(30, 40, 104)
    static let day = MapHomeSkyRGB(84, 170, 238), dayLow = MapHomeSkyRGB(198, 232, 250)
    static let noon = MapHomeSkyRGB(68, 158, 236), noonLow = MapHomeSkyRGB(178, 224, 248)

    static let morning: [Stop] = [
        Stop(altitude: -16, top: night, bottom: nightLow),
        Stop(altitude: -9, top: .init(30, 40, 112), bottom: .init(122, 78, 150)),
        Stop(altitude: -3, top: .init(70, 104, 182), bottom: .init(255, 170, 150)),
        Stop(altitude: 2, top: .init(124, 182, 232), bottom: .init(255, 206, 132)),
        Stop(altitude: 12, top: day, bottom: dayLow),
        Stop(altitude: 50, top: noon, bottom: noonLow)
    ]

    static let evening: [Stop] = [
        Stop(altitude: -16, top: night, bottom: nightLow),
        Stop(altitude: -9, top: .init(38, 30, 104), bottom: .init(146, 58, 122)),
        Stop(altitude: -3, top: .init(78, 66, 150), bottom: .init(255, 104, 84)),
        Stop(altitude: 2, top: .init(118, 138, 204), bottom: .init(255, 150, 82)),
        Stop(altitude: 12, top: day, bottom: dayLow),
        Stop(altitude: 50, top: noon, bottom: noonLow)
    ]

    static func colors(_ state: MapHomeSkyState, cover: Double) -> (top: Color, bottom: Color) {
        let stops = state.isMorning ? morning : evening
        let upper = stops.firstIndex { state.altitude < $0.altitude } ?? stops.count
        let pair: (top: MapHomeSkyRGB, bottom: MapHomeSkyRGB)
        if upper == 0 {
            pair = (stops[0].top, stops[0].bottom)
        } else if upper == stops.count {
            pair = (stops[upper - 1].top, stops[upper - 1].bottom)
        } else {
            let low = stops[upper - 1], high = stops[upper]
            let u = (state.altitude - low.altitude) / (high.altitude - low.altitude)
            pair = (low.top.mixed(high.top, u), low.bottom.mixed(high.bottom, u))
        }
        return (pair.top.clouded(cover).color, pair.bottom.clouded(cover).color)
    }
}

/// 시간대에 맞춰 구름에 덧칠하는 색.
struct MapHomeSkyShade: Equatable {
    let color: Color
    let opacity: Double
    /// 안개처럼 밝은 그림을 어둡게 줄일 비율.
    let brightness: Double

    init(state: MapHomeSkyState) {
        let warmth = state.horizonWeight * (state.isMorning ? 0.34 : 0.46)
        let dark = (1 - state.daylight) * 0.68
        brightness = 0.45 + 0.55 * state.daylight
        if dark >= warmth {
            color = Color(hex: "#141C4E")
            opacity = dark
        } else {
            color = Color(hex: state.isMorning ? "#FF9E86" : "#F2684A")
            opacity = warmth
        }
    }
}

/// 정한 순간의 하늘 한 장. 좌표는 원 지름 78 기준이다.
struct MapHomeHomeSkyFrame: View {
    let state: MapHomeSkyState
    var kind: MapHomeHomeWeatherKind?
    let sec: Double
    var windSpeed: Double = 0
    var headingDegrees: Double = 0
    var size: CGFloat = MapHomePlacePinLayout.avatarSize

    private typealias Layout = MapHomeHomeSkyLayout
    private static let stars: [(CGFloat, CGFloat, CGFloat)] = [
        (14, 30, 1.0), (24, 15, 0.8), (33, 34, 0.7), (45, 12, 1.0), (58, 18, 0.8),
        (66, 33, 1.0), (51, 40, 0.6), (9, 42, 0.7), (70, 46, 0.6), (38, 23, 0.6)
    ]

    private var cover: Double { kind?.skyCover ?? 0 }

    var body: some View {
        Canvas { context, canvasSize in
            let k = canvasSize.width / 78
            context.scaleBy(x: k, y: k)
            draw(&context, t: CGFloat(sec))
        }
        .frame(width: size, height: size)
    }

    private func draw(_ c: inout GraphicsContext, t: CGFloat) {
        let palette = MapHomeSkyPalette.colors(state, cover: cover)
        c.fill(
            Path(CGRect(x: 0, y: 0, width: 78, height: 78)),
            with: .linearGradient(
                Gradient(colors: [palette.top, palette.bottom]),
                startPoint: CGPoint(x: 39, y: 0),
                endPoint: CGPoint(x: 39, y: Layout.horizonY)
            )
        )
        let peak = Layout.peak(noonAltitude: state.noonAltitude)
        stars(&c, t: t)
        horizonGlow(&c, t: t, peak: peak)
        if state.starVisibility > 0.5, cover < 0.5 { shootingStar(&c, t: t) }
        if let progress = state.moonProgress, (-0.2...1.2).contains(progress) {
            moon(&c, t: t, at: Layout.point(progress: progress, peak: peak, headingDegrees: headingDegrees))
        }
        if let progress = state.sunProgress, (-0.25...1.25).contains(progress) {
            sun(&c, t: t, at: Layout.point(progress: progress, peak: peak, headingDegrees: headingDegrees))
        }
        ambientClouds(&c, t: t)
        ground(&c)
    }

    private func wrap(_ value: CGFloat, _ modulus: CGFloat) -> CGFloat {
        let r = value.truncatingRemainder(dividingBy: modulus)
        return r < 0 ? r + modulus : r
    }

    private func stars(_ c: inout GraphicsContext, t: CGFloat) {
        let visibility = state.starVisibility * (1 - cover)
        guard visibility > 0.01 else { return }
        // 밤하늘이 천천히 돌아 별이 동에서 서로 흐른다.
        let drift = wrap(t * 0.35, 78) * Layout.eastFactor(headingDegrees: headingDegrees)
        for (i, star) in Self.stars.enumerated() {
            let n = CGFloat(i)
            let x = wrap(star.0 - drift, 78)
            let twinkle = (sin(t * (1.8 + n * 0.37) + n * 1.9) + 1) / 2
            let r = star.2 * (0.7 + twinkle * 0.7)
            c.fill(
                Path(ellipseIn: CGRect(x: x - r, y: star.1 - r, width: r * 2, height: r * 2)),
                with: .color(.white.opacity(visibility * (0.45 + Double(twinkle) * 0.55)))
            )
        }
    }

    /// 해가 뜨고 지는 쪽 지평선이 번지며 물결친다.
    private func horizonGlow(_ c: inout GraphicsContext, t: CGFloat, peak: CGFloat) {
        let weight = state.horizonWeight * (1 - cover * 0.75)
        guard weight > 0.01 else { return }
        let side = state.isMorning ? 0.0 : 1.0
        let x = Layout.point(progress: side, peak: peak, headingDegrees: headingDegrees).x
        let pulse = 1 + sin(t * 0.9) * 0.1
        let tint = Color(hex: state.isMorning ? "#FFD08A" : "#FF7A45")
        c.fill(
            Path(CGRect(x: 0, y: 0, width: 78, height: 78)),
            with: .radialGradient(
                Gradient(colors: [tint.opacity(0.95 * weight), tint.opacity(0.32 * weight), tint.opacity(0)]),
                center: CGPoint(x: x, y: Layout.horizonY),
                startRadius: 2,
                endRadius: 46 * pulse
            )
        )
        // 지평선을 따라 흐르는 빛줄기
        for i in 0..<2 {
            let n = CGFloat(i)
            let y = Layout.horizonY - 7 - n * 7 + sin(t * 0.7 + n) * 1.2
            let shift = wrap(t * (5 + n * 2) + n * 37, 90) - 12
            var band = Path()
            band.move(to: CGPoint(x: shift - 14, y: y))
            band.addLine(to: CGPoint(x: shift + 14, y: y))
            c.stroke(
                band,
                with: .color(tint.opacity(0.42 * weight)),
                style: StrokeStyle(lineWidth: 1.6 - n * 0.4, lineCap: .round)
            )
        }
    }

    private func shootingStar(_ c: inout GraphicsContext, t: CGFloat) {
        let u = wrap(t, 13) / 0.8
        guard u < 1 else { return }
        let start = CGPoint(x: 62, y: 10)
        let head = CGPoint(x: start.x - u * 34, y: start.y + u * 15)
        var tail = Path()
        tail.move(to: head)
        tail.addLine(to: CGPoint(x: head.x + 8, y: head.y - 3.5))
        c.stroke(tail, with: .color(.white.opacity(Double(1 - u) * 0.9)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
    }

    private func sun(_ c: inout GraphicsContext, t: CGFloat, at point: CGPoint) {
        let weight = CGFloat(state.horizonWeight)
        let r: CGFloat = 7.5
        var layer = c
        layer.opacity = 1 - cover * 0.85
        let center = CGPoint(x: point.x, y: point.y + sin(t * 1.1) * (0.7 + weight * 1.1))
        let body = Color(hex: "#FFD24D").mix(with: Color(hex: state.isMorning ? "#FF8A4A" : "#FF5A3C"), by: Double(weight))
        let rayColor = Color(hex: "#F7A733").mix(with: Color(hex: "#FF6F3C"), by: Double(weight))

        let glow = r * 2.5 + sin(t * 1.7) * 2 + weight * 7
        layer.fill(
            Path(ellipseIn: CGRect(x: center.x - glow, y: center.y - glow, width: glow * 2, height: glow * 2)),
            with: .radialGradient(
                Gradient(colors: [body.opacity(0.62), body.opacity(0)]),
                center: center,
                startRadius: r * 0.7,
                endRadius: glow
            )
        )
        // 뜰 때는 빛 고리가 밖으로 퍼지고, 질 때는 안으로 모인다.
        if weight > 0.02 {
            for i in 0..<2 {
                let u = wrap(t / 2.6 + CGFloat(i) * 0.5, 1)
                let travel = state.isMorning ? u : 1 - u
                let radius = r + 2 + travel * 20
                let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                layer.stroke(ring, with: .color(body.opacity(Double(weight * sin(u * .pi)) * 0.75)), lineWidth: 1.4)
            }
        }
        var rays = Path()
        let spin = t * 0.9 * (state.isMorning ? 1 : -1)
        for i in 0..<8 {
            let n = CGFloat(i)
            let a = spin + n * .pi / 4
            let inner = r + 2 + sin(t * 2.4 + n) * 0.5
            let outer = r + 5.5 + sin(t * 3 + n * 1.3) * 1.5 + weight * (2.5 + sin(t * 1.8) * 1.5)
            rays.move(to: CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
            rays.addLine(to: CGPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
        }
        layer.stroke(rays, with: .color(rayColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        // 지평선 가까이에서는 해가 납작해 보인다.
        let squash = 1 - weight * 0.14
        let disk = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r * squash, width: r * 2, height: r * 2 * squash))
        layer.fill(disk, with: .color(body))
        layer.stroke(disk, with: .color(MapHomeHomeWeatherFrame.outline), lineWidth: 1)
    }

    private func moon(_ c: inout GraphicsContext, t: CGFloat, at point: CGPoint) {
        let r: CGFloat = 7.5
        var layer = c
        layer.opacity = (1 - cover * 0.85) * (0.35 + 0.65 * min(1, (1 - state.daylight) * 1.6))
        let center = CGPoint(x: point.x + sin(t * 0.5) * 1, y: point.y + sin(t * 0.8) * 1.5)
        let illumination = state.moon.illumination
        let glow = r * (1.7 + CGFloat(illumination) * 0.8) + sin(t * 1.2) * 1.6
        layer.fill(
            Path(ellipseIn: CGRect(x: center.x - glow, y: center.y - glow, width: glow * 2, height: glow * 2)),
            with: .radialGradient(
                Gradient(colors: [Color(hex: "#FFF1B8").opacity(0.2 + illumination * 0.42), Color(hex: "#FFF1B8").opacity(0)]),
                center: center,
                startRadius: r * 0.7,
                endRadius: glow
            )
        )
        let disk = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        layer.fill(disk, with: .color(Color(hex: "#5A6496").opacity(0.3)))
        layer.stroke(disk, with: .color(.white.opacity(0.22)), lineWidth: 0.6)
        let lit = litPart(center: center, radius: r)
        layer.fill(lit, with: .color(Color(hex: "#FFE9A6")))
        var craters = layer
        craters.clip(to: lit)
        for (dx, dy, cr) in [(CGFloat(-2.6), CGFloat(-2.4), CGFloat(1.5)), (2.8, 1.6, 1.8), (-1.2, 3.6, 1.0), (3.4, -3.2, 0.9)] {
            craters.fill(
                Path(ellipseIn: CGRect(x: center.x + dx - cr, y: center.y + dy - cr, width: cr * 2, height: cr * 2)),
                with: .color(Color(hex: "#E5C87A").opacity(0.8))
            )
        }
        layer.stroke(lit, with: .color(MapHomeHomeWeatherFrame.outline), lineWidth: 0.8)
    }

    /// 달의 밝은 부분. 보이는 모양은 실제 하늘과 같아서 북반구의 차오르는 달은 오른쪽이 밝다.
    /// 삭 무렵에도 밤에는 달이 보이도록 가는 초승달까지만 줄인다.
    private func litPart(center: CGPoint, radius r: CGFloat) -> Path {
        let side: CGFloat = state.moon.isWaxing == state.isNorthernHemisphere ? 1 : -1
        let terminator = CGFloat(cos(min(315, max(45, state.moon.elongation)) * .pi / 180))
        var path = Path()
        for i in 0...24 {
            let a = (CGFloat(i) / 24 - 0.5) * .pi
            let point = CGPoint(x: center.x + side * r * cos(a), y: center.y + r * sin(a))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        for i in stride(from: 24, through: 0, by: -1) {
            let a = (CGFloat(i) / 24 - 0.5) * .pi
            path.addLine(to: CGPoint(x: center.x + side * r * terminator * cos(a), y: center.y + r * sin(a)))
        }
        path.closeSubpath()
        return path
    }

    /// 맑은 하늘에 떠가는 구름. 날씨 구름과 달리 집 뒤로 지나간다.
    private func ambientClouds(_ c: inout GraphicsContext, t: CGFloat) {
        guard cover < 0.5 else { return }
        let speed = MapHomeHomeWeatherFrame.windMotion(speed: windSpeed)
        let shade = MapHomeSkyShade(state: state)
        for (base, y, k, rate) in [(CGFloat(8), CGFloat(27), CGFloat(0.5), CGFloat(2.6)), (70, 38, 0.38, 1.7)] {
            let x = wrap(base - t * rate * speed, 112) - 28
            let shape = MapHomeHomeWeatherFrame.cloudShape(x: x, y: y, k: k)
            c.fill(shape, with: .color(.white.opacity(0.92)))
            c.fill(shape, with: .color(shade.color.opacity(shade.opacity)))
        }
    }

    /// 해와 달이 넘어가는 언덕. 시간대에 따라 어두워진다.
    private func ground(_ c: inout GraphicsContext) {
        var hill = Path()
        hill.move(to: CGPoint(x: 0, y: Layout.horizonY + 3))
        hill.addCurve(
            to: CGPoint(x: 78, y: Layout.horizonY + 2),
            control1: CGPoint(x: 22, y: Layout.horizonY - 4),
            control2: CGPoint(x: 52, y: Layout.horizonY + 5)
        )
        hill.addLine(to: CGPoint(x: 78, y: 78))
        hill.addLine(to: CGPoint(x: 0, y: 78))
        hill.closeSubpath()
        let shade = MapHomeSkyShade(state: state)
        c.fill(hill, with: .color(Color(hex: "#A9D57B")))
        // 노을빛은 땅에 약하게만 받는다.
        c.fill(hill, with: .color(shade.color.opacity(shade.opacity * (state.daylight < 0.5 ? 1 : 0.45))))
    }
}
