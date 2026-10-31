import Foundation

public struct SleepSource: Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case appleWatch, healthKit }
    public var interval: ClassifierInterval
    public var kind: Kind

    public init(interval: ClassifierInterval, kind: Kind) {
        self.interval = interval
        self.kind = kind
    }
}

public struct SleepSession: Codable, Hashable, Sendable {
    public enum Origin: String, Codable, Sendable { case appleWatch, healthKit, phone }
    public var interval: ClassifierInterval
    public var origin: Origin
    public var score: Double
    public var evidence: [String]
}

/// 수면 판정 하나. 워치·HealthKit이 있으면 그것을 쓰고, 없을 때만 휴대폰의
/// 화면 꺼짐·정지 최장 구간을 충전·어둠으로 가중한다. 밝기 값이 없으면 어둠으로
/// 치지 않는다.
public enum SleepFusion {
    public static let minimumPhoneSleep: TimeInterval = 3 * 3_600
    public static let maximumSampleGap: TimeInterval = 75 * 60
    public static let mergeGap: TimeInterval = 30 * 60
    public static let darkBrightness = 0.1

    public static func sessions(health: [SleepSource], phone: [ClassifierSample], night: ClassifierInterval) -> [SleepSession] {
        let wearable = health.filter { $0.interval.overlap(with: night) > 0 }
        if !wearable.isEmpty {
            let origin: SleepSession.Origin = wearable.contains { $0.kind == .appleWatch } ? .appleWatch : .healthKit
            return ClassifierInterval.union(wearable.map(\.interval), gap: mergeGap).map {
                SleepSession(interval: $0, origin: origin, score: 0.95, evidence: [origin == .appleWatch ? "Apple Watch 수면" : "HealthKit 수면"])
            }
        }
        return phoneSession(phone.filter { $0.timestamp >= night.start && $0.timestamp <= night.end }).map { [$0] } ?? []
    }

    /// 여러 휴대폰 수면 감지기의 후보를 한 번에 고른다. `tiers`는 우선순위 순서다.
    /// 첫 층에 후보가 있으면 그 층만 쓰고(`exclusiveFirstTier`), 아니면 다음 층들을 차례로
    /// 보며 이미 고른 것과 겹치지 않는 후보만 더한다. 마지막으로 워치·HealthKit 수면과
    /// 겹치는 후보는 모두 버린다(웨어러블 우선). 결과는 (층, 층 안 순번).
    public static func arbitrate(
        wearable: [ClassifierInterval],
        tiers: [[ClassifierInterval]],
        exclusiveFirstTier: Bool = true
    ) -> [(tier: Int, index: Int)] {
        var chosen: [(tier: Int, index: Int)] = []
        var accepted: [ClassifierInterval] = []
        for (tier, candidates) in tiers.enumerated() {
            if exclusiveFirstTier, tier > 0, let first = tiers.first, !first.isEmpty { break }
            for (index, candidate) in candidates.enumerated()
            where !accepted.contains(where: { $0.overlap(with: candidate) > 0 || $0 == candidate }) {
                chosen.append((tier, index))
                accepted.append(candidate)
            }
        }
        let wearable = ClassifierInterval.union(wearable)
        return chosen.filter { pick in
            let candidate = tiers[pick.tier][pick.index]
            return !wearable.contains { $0.overlap(with: candidate) > 0 }
        }
    }

    static func isQuiet(_ sample: ClassifierSample) -> Bool {
        guard sample.screenIsOn != true else { return false }
        switch sample.motion {
        case .walking, .running, .cycling, .automotive: return false
        case .stationary: return true
        case .unknown:
            return sample.accelerationStandardDeviationG.map { $0 <= IdleThresholds.accelerationStandardDeviationG * 3 } ?? (sample.screenIsOn == false)
        }
    }

    static func phoneSession(_ samples: [ClassifierSample]) -> SleepSession? {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        var runs: [[ClassifierSample]] = []
        var current: [ClassifierSample] = []
        for sample in ordered {
            let broken = current.last.map { sample.timestamp.timeIntervalSince($0.timestamp) > maximumSampleGap } ?? false
            if !isQuiet(sample) || broken {
                if current.count >= 2 { runs.append(current) }
                current = isQuiet(sample) ? [sample] : []
            } else {
                current.append(sample)
            }
        }
        if current.count >= 2 { runs.append(current) }
        guard let longest = runs.max(by: { duration($0) < duration($1) }), duration(longest) >= minimumPhoneSleep else { return nil }
        let count = Double(longest.count)
        let charging = Double(longest.filter { $0.isCharging == true }.count) / count
        let dark = Double(longest.filter { sample in sample.screenBrightness.map { $0 <= darkBrightness } ?? false }.count) / count
        var score = 0.5
        var evidence = ["화면 꺼짐·정지 \(Int(duration(longest) / 3_600))시간"]
        if charging >= 0.5 { score += 0.15; evidence.append("충전 중") }
        if dark >= 0.5 { score += 0.15; evidence.append("어두운 화면") }
        return SleepSession(
            interval: ClassifierInterval(start: longest.first!.timestamp, end: longest.last!.timestamp),
            origin: .phone, score: score, evidence: evidence
        )
    }

    static func duration(_ run: [ClassifierSample]) -> TimeInterval {
        guard let first = run.first, let last = run.last else { return 0 }
        return last.timestamp.timeIntervalSince(first.timestamp)
    }
}
