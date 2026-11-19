import Foundation

/// 산타 같은 액터의 등장 시각. 처음 한 번은 바로, 그다음은 3~5분 간격(기기에서 결정적으로: 같은 시각이면 늘 같은 간격).
public struct SeasonPackDemoThrottle: Sendable {
    public static let defaultInterval: ClosedRange<Double> = 180...300
    static let shownPrefix = "seasonPack.demoShown."

    private let defaults: SeasonPackDefaults

    public init(defaults: SeasonPackDefaults = SeasonPackDefaults()) { self.defaults = defaults }

    private func key(_ ref: SeasonPackRef) -> String { "\(Self.shownPrefix)\(ref.id).\(ref.version)" }

    public func hasShownFirstDemo(_ ref: SeasonPackRef) -> Bool { defaults.bool(key(ref)) }
    public func markFirstDemoShown(_ ref: SeasonPackRef) { defaults.set(true, key(ref)) }

    /// 다음 비행 시각. 줄이기·저전력이면 nil(시연 1회도 생략). `lastFlight`가 없고 아직 시연 전이면 `now`(첫 수신 직후 1회).
    public func nextFlight(ref: SeasonPackRef, now: Date, lastFlight: Date?, interval: [Double]?, reduced: Bool) -> Date? {
        if reduced { return nil }
        if !hasShownFirstDemo(ref) { return now }
        guard let lastFlight else { return now.addingTimeInterval(Self.seededInterval(ref: ref, after: now, interval: interval)) }
        return lastFlight.addingTimeInterval(Self.seededInterval(ref: ref, after: lastFlight, interval: interval))
    }

    public static func seededInterval(ref: SeasonPackRef, after date: Date, interval: [Double]?) -> TimeInterval {
        let low = max(60, interval?.first ?? defaultInterval.lowerBound)
        let high = max(low, interval.flatMap { $0.count > 1 ? $0[1] : nil } ?? defaultInterval.upperBound)
        var hash: UInt64 = 14_695_981_039_346_656_037 // FNV-1a: 프로세스마다 바뀌는 hashValue 대신.
        for byte in "\(ref.id)#\(ref.version)#\(Int(date.timeIntervalSince1970 / 60))".utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let fraction = Double(hash % 10_000) / 10_000
        return low + (high - low) * fraction
    }
}

/// 비행 위치와 선물 흩뿌리기(모두 같은 입력이면 같은 값).
public enum SeasonPackActorMath {
    /// 화면 비율 좌표(0…1)에서 진행도 `t`(0…1)의 위치. 살짝 위로 호를 그린다.
    public static func flightPoint(_ flight: SeasonPackManifest.Actor.Flight, progress t: Double) -> (x: Double, y: Double) {
        let t = min(max(t, 0), 1)
        let sx = flight.start.first ?? 0, sy = flight.start.count > 1 ? flight.start[1] : 0
        let ex = flight.end.first ?? 1, ey = flight.end.count > 1 ? flight.end[1] : 0
        return (sx + (ex - sx) * t, sy + (ey - sy) * t - 0.03 * sin(t * .pi))
    }

    public struct Gift: Sendable, Equatable {
        public var image: Int
        public var vx: Double
        public var vy: Double
        public var spin: Double
    }

    public static let burstSeconds = 1.2
    static let gravity = 1.9

    public static func gifts(count: Int, imageCount: Int, seed: UInt64) -> [Gift] {
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 33) / Double(1 << 31)
        }
        return (0..<min(max(count, 0), 40)).map { index in
            Gift(image: imageCount > 0 ? index % imageCount : 0, vx: (next() - 0.5) * 0.9, vy: -(0.5 + next() * 0.7), spin: (next() - 0.5) * 6)
        }
    }

    /// 선물 하나의 시작점(산타 위치) 기준 변위: 위로 튀었다 중력으로 내려온다.
    public static func giftOffset(_ gift: Gift, at seconds: Double) -> (dx: Double, dy: Double) {
        (gift.vx * seconds, gift.vy * seconds + 0.5 * gravity * seconds * seconds)
    }
}
