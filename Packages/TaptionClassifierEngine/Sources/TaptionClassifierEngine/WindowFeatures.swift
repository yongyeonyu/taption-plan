import Foundation

/// 30초(GPS만 있으면 60초) 창 하나의 특징.
public struct WindowFeatures: Codable, Hashable, Sendable {
    public var interval: ClassifierInterval
    public var sampleCount: Int
    public var speedMedian: Double?
    public var speedP90: Double?
    /// 창 안 첫·마지막 위치의 직선 거리를 시간으로 나눈 값. GPS 속도가 없을 때 쓴다.
    public var displacementSpeed: Double?
    public var accelerationStandardDeviationG: Double?
    public var jerk: Double?
    /// 기압 기울기(kPa/분). 비행기 순항은 거의 0, 이착륙은 크다.
    public var pressureSlope: Double?
    public var pressureLevel: Double?
    public var headingEntropy: Double?
    public var nearTransitStop: Bool
    public var nearRailStation: Bool
    public var nearAirport: Bool
    public var onWater: Bool
    public var hasLocation: Bool
    public var motion: MotionHint
    public var stepCadence: Double?
    public var isIdle: Bool

    public var bestSpeed: Double? { speedMedian ?? displacementSpeed }
}

public enum WindowFeatureExtractor {
    public static let motionWindow: TimeInterval = 30
    public static let gpsOnlyWindow: TimeInterval = 60

    /// 시간순 원본을 창으로 자른다. 원본이 없는 창은 만들지 않는다(공백은 HMM이 메우지 않는다).
    public static func windows(_ samples: [ClassifierSample]) -> [WindowFeatures] {
        windows(samples, cancellation: {})
    }

    public static func windows(_ samples: [ClassifierSample], cancellation: () throws -> Void) rethrows -> [WindowFeatures] {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        guard let first = ordered.first else { return [] }
        let hasMotion = ordered.contains { $0.accelerationStandardDeviationG != nil || $0.motion != .unknown }
        let length = hasMotion ? motionWindow : gpsOnlyWindow
        var result: [WindowFeatures] = []
        var bucket: [ClassifierSample] = []
        var bucketStart = first.timestamp
        for sample in ordered {
            if sample.timestamp.timeIntervalSince(bucketStart) >= length {
                if !bucket.isEmpty {
                    try cancellation()
                    result.append(features(bucket, start: bucketStart, length: length))
                }
                bucket = []
                let skipped = floor(sample.timestamp.timeIntervalSince(bucketStart) / length)
                bucketStart = bucketStart.addingTimeInterval(skipped * length)
            }
            bucket.append(sample)
        }
        if !bucket.isEmpty { result.append(features(bucket, start: bucketStart, length: length)) }
        return result
    }

    public static func features(_ samples: [ClassifierSample], start: Date, length: TimeInterval) -> WindowFeatures {
        let speeds = samples.compactMap(\.speed).filter { $0 >= 0 }.sorted()
        let located = samples.filter { $0.point != nil && ($0.horizontalAccuracy ?? 0) <= 100 }
        var displacement: Double?
        if let a = located.first, let b = located.last, let pa = a.point, let pb = b.point {
            let seconds = b.timestamp.timeIntervalSince(a.timestamp)
            if seconds >= 5 { displacement = pa.distance(to: pb) / seconds }
        }
        let accel = samples.compactMap(\.accelerationStandardDeviationG)
        let jerks = samples.compactMap(\.accelerationJerkGPerSecond)
        let pressures = samples.compactMap { sample in sample.pressureKilopascals.map { (sample.timestamp, $0) } }
        let headings = samples.compactMap(\.course).filter { $0 >= 0 }
        let motion = dominantMotion(samples)
        let accelMean = accel.isEmpty ? nil : accel.reduce(0, +) / Double(accel.count)
        let rotation = samples.compactMap(\.rotationRate).max()
        return WindowFeatures(
            interval: ClassifierInterval(start: start, end: start.addingTimeInterval(length)),
            sampleCount: samples.count,
            speedMedian: percentile(speeds, 0.5),
            speedP90: percentile(speeds, 0.9),
            displacementSpeed: displacement,
            accelerationStandardDeviationG: accelMean,
            jerk: jerks.isEmpty ? nil : jerks.reduce(0, +) / Double(jerks.count),
            pressureSlope: slopePerMinute(pressures),
            pressureLevel: pressures.isEmpty ? nil : pressures.map(\.1).reduce(0, +) / Double(pressures.count),
            headingEntropy: entropy(headings),
            nearTransitStop: samples.contains(where: \.nearTransitStop),
            nearRailStation: samples.contains(where: \.nearRailStation),
            nearAirport: samples.contains(where: \.nearAirport),
            onWater: samples.filter(\.onWater).count * 2 >= max(1, located.count) && samples.contains(where: \.onWater),
            hasLocation: !located.isEmpty,
            motion: motion,
            stepCadence: samples.compactMap(\.stepCadence).max(),
            isIdle: IdleThresholds.isIdle(accelerationStandardDeviationG: accelMean, rotationRate: rotation)
        )
    }

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }

    static func slopePerMinute(_ values: [(Date, Double)]) -> Double? {
        guard values.count >= 2, let origin = values.first?.0 else { return nil }
        let xs = values.map { $0.0.timeIntervalSince(origin) / 60 }
        let ys = values.map(\.1)
        let meanX = xs.reduce(0, +) / Double(xs.count), meanY = ys.reduce(0, +) / Double(ys.count)
        let denominator = xs.map { ($0 - meanX) * ($0 - meanX) }.reduce(0, +)
        guard denominator > 0 else { return nil }
        return zip(xs, ys).map { ($0 - meanX) * ($1 - meanY) }.reduce(0, +) / denominator
    }

    /// 진행 방향 8방위 엔트로피(0…3비트). 걷기·정지는 높고 차량·기차는 낮다.
    static func entropy(_ headings: [Double]) -> Double? {
        guard headings.count >= 3 else { return nil }
        var bins = [Double](repeating: 0, count: 8)
        for heading in headings { bins[Int(heading.truncatingRemainder(dividingBy: 360) / 45) % 8] += 1 }
        let total = Double(headings.count)
        return -bins.filter { $0 > 0 }.map { ($0 / total) * log2($0 / total) }.reduce(0, +)
    }

    static func dominantMotion(_ samples: [ClassifierSample]) -> MotionHint {
        let counts = samples.reduce(into: [MotionHint: Int]()) { $0[$1.motion, default: 0] += 1 }
        return counts.filter { $0.key != .unknown }.max { $0.value == $1.value ? $0.key.rawValue > $1.key.rawValue : $0.value < $1.value }?.key ?? .unknown
    }
}
