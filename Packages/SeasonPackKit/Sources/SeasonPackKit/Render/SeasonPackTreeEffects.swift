import SwiftUI

/// 트리 전구 시퀀스의 밝기(0.18...1). 한 주기(11초)는 번지는 추격 → 홀짝 교대 → 전체 숨쉬기 순서이고, 시각만 주면 값이 정해져 시험할 수 있다.
public enum SeasonPackBulbSequence {
    public static let floor = 0.18
    public static let chaseSeconds = 6.0, alternateSeconds = 3.0, pulseSeconds = 2.0
    public static var cycleSeconds: Double { chaseSeconds + alternateSeconds + pulseSeconds }

    public static func level(group: Int, groups: Int, stepMs: Int, at time: TimeInterval) -> Double {
        let n = max(groups, 1), step = max(Double(stepMs), 60) / 1000
        let t = time.truncatingRemainder(dividingBy: cycleSeconds)
        let u = t < 0 ? t + cycleSeconds : t
        if u < chaseSeconds {
            // 켜진 묶음이 한 칸씩 앞으로 가고 뒤에는 잔광이 남는다.
            var d = (u / step - Double(group)).truncatingRemainder(dividingBy: Double(n))
            if d < 0 { d += Double(n) }
            if d < 1 { return 1 }
            let nd = Double(n)
            if d > nd - 0.35 { return floor + (1 - floor) * (1 - (nd - d) / 0.35) } // 켜지기 직전 짧게 올라온다
            return max(floor, 1 - (d - 1) * 0.45)
        }
        if u < chaseSeconds + alternateSeconds {
            let k = Int((u - chaseSeconds) / 0.5)
            return (k + group) % 2 == 0 ? 1 : floor
        }
        let phase = (u - chaseSeconds - alternateSeconds) / pulseSeconds
        return floor + (1 - floor) * (0.5 - 0.5 * cos(phase * 2 * .pi * 2))
    }

    /// 동작 줄이기·저전력에서 쓰는 정지 밝기.
    public static let steady = 0.85
}

/// 점등한 트리 위에 얹는 전구 불빛. 그림은 꺼진 전구만 담고, 빛은 여기서 시퀀스로 그린다.
struct SeasonPackBulbsView: View {
    let bulbs: SeasonPackManifest.Slots.House.Bulbs
    let animated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !animated)) { context in
            Canvas { gc, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let s = min(size.width, size.height)
                gc.blendMode = .plusLighter
                for bulb in bulbs.points {
                    let level = animated ? SeasonPackBulbSequence.level(group: bulb.group, groups: bulbs.groups, stepMs: bulbs.stepMs, at: t) : SeasonPackBulbSequence.steady
                    let color = Color(seasonHex: bulb.color)
                    let center = CGPoint(x: bulb.x * size.width, y: bulb.y * size.height)
                    let halo = s * 0.024 * (0.7 + 0.5 * level)
                    gc.fill(Path(ellipseIn: CGRect(x: center.x - halo * 2.4, y: center.y - halo * 2.4, width: halo * 4.8, height: halo * 4.8)),
                            with: .radialGradient(Gradient(colors: [color.opacity(0.75 * level), color.opacity(0.22 * level), color.opacity(0)]),
                                                  center: center, startRadius: 0, endRadius: halo * 2.4))
                    let core = s * 0.0105
                    gc.fill(Path(ellipseIn: CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2)),
                            with: .color(Color(white: 1).opacity(0.35 + 0.65 * level)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 눈꽃송이 한 송이의 움직임. 시각만 주면 위치가 정해져(저장하는 상태 없음) 화면이 다시 그려져도 이어진다.
public struct SeasonPackSnowflake: Sendable, Equatable {
    public var x: Double      // 0...1
    public var y: Double      // 0...1 (아래로 갈수록 큼)
    public var size: Double   // pt
    public var rotation: Double
    public var opacity: Double

    public static func make(index: Int, count: Int, config: SeasonPackManifest.Slots.Effects.Snow, at time: TimeInterval, height: Double) -> SeasonPackSnowflake {
        func rand(_ k: Int) -> Double {
            var h = UInt64(truncatingIfNeeded: index &* 7919 &+ k &* 104_729 &+ 12_345)
            h = (h ^ (h >> 15)) &* 0x2C1B_3C6D; h = (h ^ (h >> 12)) &* 0x297A_2D39; h ^= h >> 15
            return Double(h % 10_000) / 10_000
        }
        let size = config.minSize + (config.maxSize - config.minSize) * pow(rand(1), 1.4)
        // 큰 송이는 가까워서 빠르고 또렷하다.
        let depth = (size - config.minSize) / max(config.maxSize - config.minSize, 0.001)
        let speed = config.minSpeed + (config.maxSpeed - config.minSpeed) * (0.35 + 0.65 * depth) * (0.8 + 0.4 * rand(2))
        let travel = height + size * 4
        let fall = (rand(3) * travel + time * speed).truncatingRemainder(dividingBy: travel)
        let sway = sin(time * (0.35 + rand(4) * 0.5) + rand(5) * 6.28) * (10 + 14 * rand(6))
        let baseX = rand(0) * 1
        return SeasonPackSnowflake(x: baseX + sway / 400, y: (fall - size * 2) / max(height, 1), size: size,
                                   rotation: rand(7) * 6.28 + time * (0.2 + rand(8) * 0.5) * (rand(9) < 0.5 ? -1 : 1),
                                   opacity: 0.55 + 0.4 * (0.4 + 0.6 * depth))
    }
}

/// 집 그림(트리)이 나와 있는 동안 날씨와 상관없이 눈꽃송이가 사르르 내린다. 터치는 통과시킨다.
public struct SeasonPackSnowLayer: View {
    private let config: SeasonPackManifest.Slots.Effects.Snow
    private let reduced: Bool
    private let lowPower: Bool

    public init(config: SeasonPackManifest.Slots.Effects.Snow, motion: SeasonPackMotionPolicy) {
        self.config = config; reduced = motion.reduceMotion; lowPower = motion.lowPower
    }

    public var body: some View {
        let count = lowPower ? max(config.count / 2, 6) : config.count
        TimelineView(.animation(minimumInterval: lowPower ? 1.0 / 12 : 1.0 / 24, paused: reduced)) { context in
            Canvas { gc, size in
                let t = reduced ? 0 : context.date.timeIntervalSinceReferenceDate
                for i in 0..<(reduced ? max(count / 2, 6) : count) {
                    let f = SeasonPackSnowflake.make(index: i, count: count, config: config, at: t, height: Double(size.height))
                    guard f.y > -0.05, f.y < 1.05 else { continue }
                    Self.draw(f, in: &gc, at: CGPoint(x: f.x * size.width, y: f.y * size.height))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 여섯 갈래 눈꽃. 밝은 지도 위에서도 보이게 푸른 그림자를 한 겹 깐다.
    private static func draw(_ f: SeasonPackSnowflake, in gc: inout GraphicsContext, at p: CGPoint) {
        var g = gc
        g.translateBy(x: p.x, y: p.y)
        g.rotate(by: .radians(f.rotation))
        let r = f.size / 2
        var arms = Path()
        for k in 0..<6 {
            let a = Double(k) * .pi / 3
            let tip = CGPoint(x: cos(a) * r, y: sin(a) * r)
            arms.move(to: .zero); arms.addLine(to: tip)
            // 가지 두 쌍(큰 눈꽃송이만 자세히).
            for (frac, len) in [(0.55, 0.34), (0.8, 0.22)] where r > 3.2 || frac < 0.6 {
                let base = CGPoint(x: tip.x * frac, y: tip.y * frac)
                for side in [-1.0, 1.0] {
                    let b = a + side * .pi / 4.2
                    arms.move(to: base); arms.addLine(to: CGPoint(x: base.x + cos(b) * r * len, y: base.y + sin(b) * r * len))
                }
            }
        }
        let width = max(0.9, r * 0.2)
        g.stroke(arms, with: .color(Color(red: 0.38, green: 0.5, blue: 0.7).opacity(f.opacity * 0.5)), style: StrokeStyle(lineWidth: width + 1.2, lineCap: .round))
        g.stroke(arms, with: .color(.white.opacity(f.opacity)), style: StrokeStyle(lineWidth: width, lineCap: .round))
        g.fill(Path(ellipseIn: CGRect(x: -r * 0.16, y: -r * 0.16, width: r * 0.32, height: r * 0.32)), with: .color(.white.opacity(f.opacity)))
    }
}
