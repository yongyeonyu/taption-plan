import CoreGraphics
import SwiftUI
import Synchronization

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

    /// 송이 한 개의 움직임을 정하는 상수들(번호에서만 정해진다). 눈 내리기는 시각의 함수라, 그릴 때와 Core Animation 값으로 옮길 때 같은 식을 쓴다.
    struct Track {
        var size: Double, depth: Double, speed: Double, travel: Double
        var fallPhase: Double          // 시각 0에서 떨어진 거리(pt)
        var swayOmega: Double, swayPhase: Double, swayAmp: Double
        var baseX: Double
        var spin0: Double, spinRate: Double
        var opacity: Double
    }

    static func track(index: Int, config: SeasonPackManifest.Slots.Effects.Snow, height: Double) -> Track {
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
        return Track(size: size, depth: depth, speed: speed, travel: travel, fallPhase: rand(3) * travel,
                     swayOmega: 0.35 + rand(4) * 0.5, swayPhase: rand(5) * 6.28, swayAmp: 10 + 14 * rand(6),
                     baseX: rand(0) * 1,
                     spin0: rand(7) * 6.28, spinRate: (0.2 + rand(8) * 0.5) * (rand(9) < 0.5 ? -1 : 1),
                     opacity: 0.55 + 0.4 * (0.4 + 0.6 * depth))
    }

    public static func make(index: Int, count: Int, config: SeasonPackManifest.Slots.Effects.Snow, at time: TimeInterval, height: Double) -> SeasonPackSnowflake {
        let k = track(index: index, config: config, height: height)
        let fall = (k.fallPhase + time * k.speed).truncatingRemainder(dividingBy: k.travel)
        let sway = sin(time * k.swayOmega + k.swayPhase) * k.swayAmp
        return SeasonPackSnowflake(x: k.baseX + sway / 400, y: (fall - k.size * 2) / max(height, 1), size: k.size,
                                   rotation: k.spin0 + time * k.spinRate, opacity: k.opacity)
    }
}

/// 눈꽃송이 그림을 한 번만 그려 둔다(LAG1120A01). 송이마다 크기·밝기는 번호로 정해져 있고 움직이는 것은 자리와 기울기뿐이라,
/// 가지 18개를 매 프레임 다시 긋지 않고 만들어 둔 그림을 옮기고 돌려 찍는다. 모양·색·크기는 전과 같다.
enum SeasonPackSnowSprites {
    /// 그림이 그려질 배율. 화면 배율(3x)에 맞춘다.
    static let scale: CGFloat = 3
    private static let cache = Mutex<[String: [Int: CGImage]]>([:])

    /// 송이 한 개의 그림과 그 한 변(pt).
    static func sprite(index: Int, config: SeasonPackManifest.Slots.Effects.Snow) -> (image: CGImage, side: CGFloat)? {
        let flake = SeasonPackSnowflake.make(index: index, count: 1, config: config, at: 0, height: 1)
        let side = (flake.size * 1.4).rounded(.up) + 6
        let key = "\(config.minSize)-\(config.maxSize)"
        // 크기를 0.5pt 칸으로 묶어 같은 그림을 나눠 쓴다.
        let bucket = Int((flake.size * 2).rounded())
        if let hit = cache.withLock({ $0[key]?[bucket] }) { return (hit, CGFloat(side)) }
        guard let image = render(size: Double(bucket) / 2, side: side) else { return nil }
        cache.withLock { $0[key, default: [:]][bucket] = image }
        return (image, CGFloat(side))
    }

    /// 전과 같은 그림: 푸른 그림자 한 겹 위에 흰 가지, 가운데 흰 점. 투명도는 찍을 때 준다.
    private static func render(size: Double, side: CGFloat) -> CGImage? {
        let pixels = Int((side * scale).rounded())
        guard let cg = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // 여섯 갈래라 위아래를 뒤집어도 같은 모양이다.
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: side / 2, y: side / 2)
        let r = size / 2
        let arms = armsPath(radius: r)
        let width = max(0.9, r * 0.2)
        cg.setLineCap(.round)
        cg.addPath(arms.cgPath)
        cg.setLineWidth(width + 1.2)
        cg.setStrokeColor(CGColor(red: 0.38, green: 0.5, blue: 0.7, alpha: 0.5))
        cg.strokePath()
        cg.addPath(arms.cgPath)
        cg.setLineWidth(width)
        cg.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cg.strokePath()
        cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cg.fillEllipse(in: CGRect(x: -r * 0.16, y: -r * 0.16, width: r * 0.32, height: r * 0.32))
        return cg.makeImage()
    }

    /// 여섯 갈래와 가지 두 쌍(큰 눈꽃송이만 자세히).
    static func armsPath(radius r: Double) -> Path {
        var arms = Path()
        for k in 0..<6 {
            let a = Double(k) * .pi / 3
            let tip = CGPoint(x: cos(a) * r, y: sin(a) * r)
            arms.move(to: .zero); arms.addLine(to: tip)
            for (frac, len) in [(0.55, 0.34), (0.8, 0.22)] where r > 3.2 || frac < 0.6 {
                let base = CGPoint(x: tip.x * frac, y: tip.y * frac)
                for side in [-1.0, 1.0] {
                    let b = a + side * .pi / 4.2
                    arms.move(to: base); arms.addLine(to: CGPoint(x: base.x + cos(b) * r * len, y: base.y + sin(b) * r * len))
                }
            }
        }
        return arms
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

    private static func snowCount(_ config: SeasonPackManifest.Slots.Effects.Snow, lowPower: Bool) -> Int {
        let count = lowPower ? max(config.count / 2, 6) : config.count
        #if DEBUG || BENCH
        // 측정 전용(LAG1120A01): `-seasonSnowCount N`으로 송이 수를 바꿔 비용이 송이 수에 비례하는지 본다.
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "-seasonSnowCount"), arguments.indices.contains(i + 1), let n = Int(arguments[i + 1]) { return n }
        #endif
        return count
    }

    public var body: some View {
        let count = Self.snowCount(config, lowPower: lowPower)
        #if canImport(UIKit)
        // 눈은 시각만으로 정해지는 움직임이라, 프레임마다 앱이 그리지 않고 Core Animation에 맡긴다(LAG1120A01: 메인 스레드 0에 가깝다).
        SeasonPackSnowAnimationView(config: config, count: reduced ? max(count / 2, 6) : count, reduced: reduced)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        #else
        let config = config, reduced = reduced
        let sprites = (0..<count).map { SeasonPackSnowSprites.sprite(index: $0, config: config) }
        TimelineView(.animation(minimumInterval: lowPower ? 1.0 / 12 : 1.0 / 24, paused: reduced)) { context in
            let t = reduced ? 0 : context.date.timeIntervalSinceReferenceDate
            Canvas(opaque: false, rendersAsynchronously: true) { gc, size in
                for i in 0..<(reduced ? max(count / 2, 6) : count) {
                    guard let sprite = sprites[i] else { continue }
                    let f = SeasonPackSnowflake.make(index: i, count: count, config: config, at: t, height: Double(size.height))
                    guard f.y > -0.05, f.y < 1.05 else { continue }
                    var g = gc
                    g.opacity = f.opacity
                    g.translateBy(x: f.x * size.width, y: f.y * size.height)
                    g.rotate(by: .radians(f.rotation))
                    let rect = CGRect(x: -sprite.side / 2, y: -sprite.side / 2, width: sprite.side, height: sprite.side)
                    g.draw(Image(decorative: sprite.image, scale: SeasonPackSnowSprites.scale), in: rect)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        #endif
    }
}

#if canImport(UIKit)
import UIKit

private struct SeasonPackSnowAnimationView: UIViewRepresentable {
    let config: SeasonPackManifest.Slots.Effects.Snow
    let count: Int
    let reduced: Bool

    func makeUIView(context: Context) -> SeasonPackSnowHostView {
        let v = SeasonPackSnowHostView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.layer.masksToBounds = true
        return v
    }

    func updateUIView(_ view: SeasonPackSnowHostView, context: Context) {
        view.configure(config: config, count: count, reduced: reduced)
    }
}

/// 송이마다 레이어 하나. 떨어짐(선형)·흔들림(사인)·돌기(선형)를 각각 반복 애니메이션으로 걸어 렌더 서버가 움직인다.
final class SeasonPackSnowHostView: UIView {
    private var config: SeasonPackManifest.Slots.Effects.Snow?
    private var count = 0
    private var reduced = false
    private var builtKey = ""

    func configure(config: SeasonPackManifest.Slots.Effects.Snow, count: Int, reduced: Bool) {
        self.config = config; self.count = count; self.reduced = reduced
        rebuildIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rebuildIfNeeded()
    }

    private func rebuildIfNeeded() {
        guard let config, bounds.width > 1, bounds.height > 1 else { return }
        let key = "\(config.count)-\(config.minSize)-\(config.maxSize)-\(config.minSpeed)-\(config.maxSpeed)-\(count)-\(reduced)-\(Int(bounds.width))x\(Int(bounds.height))"
        guard key != builtKey else { return }
        builtKey = key
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let w = Double(bounds.width), h = Double(bounds.height)
        let t0 = Date().timeIntervalSinceReferenceDate
        for i in 0..<count {
            guard let sprite = SeasonPackSnowSprites.sprite(index: i, config: config) else { continue }
            let k = SeasonPackSnowflake.track(index: i, config: config, height: h)
            let flake = CALayer()
            flake.contents = sprite.image
            flake.contentsScale = SeasonPackSnowSprites.scale
            flake.bounds = CGRect(x: 0, y: 0, width: sprite.side, height: sprite.side)
            flake.opacity = Float(k.opacity)
            flake.actions = ["position": NSNull(), "transform": NSNull()]
            layer.addSublayer(flake)
            if reduced {
                let f = SeasonPackSnowflake.make(index: i, count: count, config: config, at: 0, height: h)
                flake.position = CGPoint(x: f.x * w, y: f.y * h)
                flake.transform = CATransform3DMakeRotation(f.rotation, 0, 0, 1)
                continue
            }
            // 떨어짐: 시각 t0에서 이미 fallPhase만큼 내려온 자리부터 이어진다.
            let startY = -k.size * 2
            let fall = CABasicAnimation(keyPath: "position.y")
            fall.fromValue = startY; fall.toValue = startY + k.travel
            fall.duration = k.travel / k.speed
            fall.timeOffset = ((k.fallPhase + t0 * k.speed).truncatingRemainder(dividingBy: k.travel)) / k.speed
            fall.repeatCount = .infinity; fall.isRemovedOnCompletion = false
            flake.position = CGPoint(x: k.baseX * w, y: startY)
            flake.add(fall, forKey: "fall")
            // 흔들림: 사인 한 주기를 표본으로 옮긴다.
            let period = 2 * Double.pi / k.swayOmega
            let phase0 = t0 * k.swayOmega + k.swayPhase
            let steps = 32
            let xs: [Double] = (0...steps).map { n in
                (k.baseX + sin(2 * Double.pi * Double(n) / Double(steps) + phase0) * k.swayAmp / 400) * w
            }
            let sway = CAKeyframeAnimation(keyPath: "position.x")
            sway.values = xs; sway.calculationMode = .cubic
            sway.duration = period; sway.repeatCount = .infinity; sway.isRemovedOnCompletion = false
            flake.add(sway, forKey: "sway")
            // 돌기: 한 바퀴를 선형으로 반복.
            let a0 = k.spin0 + t0 * k.spinRate
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = a0; spin.toValue = a0 + (k.spinRate < 0 ? -2 : 2) * Double.pi
            spin.duration = 2 * Double.pi / abs(k.spinRate)
            spin.repeatCount = .infinity; spin.isRemovedOnCompletion = false
            flake.add(spin, forKey: "spin")
        }
    }
}
#endif
