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

/// 수면 규칙 하나(ALG1102A01). 워치·HealthKit이 있으면 그것을 쓰고, 없을 때만 휴대폰의
/// 화면 꺼짐·정지 최장 구간을 충전·어둠으로 가중한다. 밝기 값이 없으면 어둠으로
/// 치지 않는다. 앱의 휴대폰 수면(`PhoneSleepFusion`)과 낮잠(`AppleWatchNapPolicy`)도
/// 아래 `phoneOnly`·`acceptsPhoneOnly`·`isNap`으로 같은 낮 창·길이 기준을 쓴다.
public enum SleepFusion {
    public static let minimumPhoneSleep: TimeInterval = 3 * 3_600
    public static let maximumSampleGap: TimeInterval = 75 * 60
    public static let mergeGap: TimeInterval = 30 * 60
    public static let darkBrightness = 0.1
    /// 낮 창: 이 지역 시각 안에서 시작하고 끝나야 낮 수면이다(대표 결정 2026-11-08: 9~21시).
    public static let daytimeStartHour = 9
    public static let daytimeEndHour = 21
    /// 낮잠은 4시간 이하다(대표 결정 2026-11-08).
    public static let maximumNap: TimeInterval = 4 * 3_600
    /// 휴대폰만으로 잡힌 수면의 최소 길이. 감지기 확정 시간 중 가장 짧은 값(충전 중 30분)이다.
    public static let minimumPhoneOnlySleep: TimeInterval = 30 * 60

    public static func sessions(
        health: [SleepSource], phone: [ClassifierSample], night: ClassifierInterval,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [SleepSession] {
        let wearable = health.filter { $0.interval.overlap(with: night) > 0 }
        if !wearable.isEmpty {
            let origin: SleepSession.Origin = wearable.contains { $0.kind == .appleWatch } ? .appleWatch : .healthKit
            return ClassifierInterval.union(wearable.map(\.interval), gap: mergeGap).map {
                SleepSession(interval: $0, origin: origin, score: 0.95, evidence: [origin == .appleWatch ? "Apple Watch 수면" : "HealthKit 수면"])
            }
        }
        return phoneSession(phone.filter { $0.timestamp >= night.start && $0.timestamp <= night.end })
            .flatMap { acceptsPhoneOnly($0.interval, calendar: calendar) ? [$0] : nil } ?? []
    }

    /// 낮 창(9~21시) 안에서 시작하고 끝나는가.
    public static func isDaytime(_ interval: ClassifierInterval, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard let (start, end) = daytimeWindow(on: interval.start, calendar: calendar) else { return false }
        return interval.start >= start && interval.end <= end
    }

    /// 낮잠: 워치가 직접 잰 수면이 낮 창 안에서 4시간 이하이고 그 밤의 주 수면이 아니다.
    public static func isNap(
        _ interval: ClassifierInterval, watchMeasured: Bool, isMainSleep: Bool,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        watchMeasured && !isMainSleep && interval.duration <= maximumNap && isDaytime(interval, calendar: calendar)
    }

    /// 낮 창에 시작해 그날 자정 전에 끝나는가. 저녁 책상 위 충전은 21시를 넘겨도 밤잠이 아니다(ALG1108A01).
    static func endsSameDayAfterDaytimeStart(_ interval: ClassifierInterval, calendar: Calendar) -> Bool {
        let day = calendar.startOfDay(for: interval.start)
        guard let (start, end) = daytimeWindow(on: interval.start, calendar: calendar),
              let midnight = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
        return interval.start >= start && interval.start < end && interval.end <= midnight
    }

    /// 그날 벽시계 9시·21시. 자정+시간으로 더하면 서머타임 바뀌는 날 한 시간 밀린다 (REV1110A04).
    static func daytimeWindow(on date: Date, calendar: Calendar) -> (Date, Date)? {
        guard let start = calendar.date(bySettingHour: daytimeStartHour, minute: 0, second: 0, of: date),
              let end = calendar.date(bySettingHour: daytimeEndHour, minute: 0, second: 0, of: date) else { return nil }
        return (start, end)
    }

    /// 휴대폰만으로 잡힌 수면을 받을지. 휴대폰 정지는 낮잠이 되지 않으므로(대표 결정) 낮 창에 시작해
    /// 그날 안에 끝나는 후보는 버리고, 30분보다 짧은 조각도 버린다.
    public static func acceptsPhoneOnly(_ interval: ClassifierInterval, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        interval.duration >= minimumPhoneOnlySleep && !endsSameDayAfterDaytimeStart(interval, calendar: calendar)
    }

    /// 휴대폰 수면 후보를 고르는 단일 입구: 받을 수 없는 후보를 먼저 빼고 `arbitrate`한다.
    /// 버린 조각이 아래 층의 밤 전체 후보를 막지 않게 하려고 거르기를 먼저 한다. 결과 순번은 원래 층 안 순번이다.
    public static func phoneOnly(
        wearable: [ClassifierInterval],
        tiers: [[ClassifierInterval]],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [(tier: Int, index: Int)] {
        let kept = tiers.map { candidates in candidates.indices.filter { acceptsPhoneOnly(candidates[$0], calendar: calendar) } }
        let filtered = kept.enumerated().map { tier, indices in indices.map { tiers[tier][$0] } }
        return arbitrate(wearable: wearable, tiers: filtered).map { ($0.tier, kept[$0.tier][$0.index]) }
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
