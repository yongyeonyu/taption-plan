import Foundation

public struct ClassifiedSegment: Codable, Hashable, Sendable {
    public var interval: ClassifierInterval
    public var mode: TransportMode
    /// 구간 안 창들의 사후 확률 평균(0…1).
    public var score: Double
    public var distanceMeters: Double
    public var evidence: [String]

    public init(interval: ClassifierInterval, mode: TransportMode, score: Double, distanceMeters: Double, evidence: [String]) {
        self.interval = interval
        self.mode = mode
        self.score = score
        self.distanceMeters = distanceMeters
        self.evidence = evidence
    }
}

/// 점수에서 계산하는 3단계 신뢰도.
public enum ClassifierConfidence: String, Codable, Sendable {
    case low, medium, high

    public init(score: Double) {
        self = score >= 0.8 ? .high : (score >= 0.55 ? .medium : .low)
    }
}

public enum TravelSegmenter {
    /// HMM 결과를 같은 수단끼리 이어 구간으로 만든다.
    public static func segments(steps: [ModeHMM.Step], samples: [ClassifierSample], maximumGap: TimeInterval = 10 * 60) -> [ClassifiedSegment] {
        var groups: [[ModeHMM.Step]] = []
        for step in steps {
            if let last = groups.last?.last, last.mode == step.mode,
               step.window.interval.start.timeIntervalSince(last.window.interval.end) <= maximumGap {
                groups[groups.count - 1].append(step)
            } else {
                groups.append([step])
            }
        }
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        return groups.compactMap { group -> ClassifiedSegment? in
            guard let first = group.first, let last = group.last else { return nil }
            let interval = ClassifierInterval(start: first.window.interval.start, end: last.window.interval.end)
            let inside = ordered.filter { $0.timestamp >= interval.start && $0.timestamp <= interval.end }
            let evidence = Array(Set(group.flatMap(\.evidence))).sorted()
            return ClassifiedSegment(
                interval: interval,
                mode: first.mode,
                score: group.map(\.posterior).reduce(0, +) / Double(group.count),
                distanceMeters: TravelDistance.meters(samples: inside, mode: first.mode),
                evidence: evidence
            )
        }
    }
}

/// 이동 거리. 위치 흔들림은 기준점·오차 반경으로 거르고, 비행은 끝점 대권 거리.
public enum TravelDistance {
    public static let jitterFloorMeters = 20.0
    public static let accuracyMultiplier = 2.0
    public static let maximumAccuracyMeters = 150.0
    /// 지상 이동에서 이 속도(m/s)를 넘는 점프는 튄 점으로 본다.
    public static let maximumGroundSpeed = 70.0
    public static let smoothingSeconds = 5.0

    public static func meters(samples: [ClassifierSample], mode: TransportMode) -> Double {
        if mode == .airplane { return greatCircleMeters(samples: samples) }
        if mode == .stationary { return 0 }
        return pathMeters(samples: samples)
    }

    /// 첫·마지막 유효 위치 사이 대권 거리.
    public static func greatCircleMeters(samples: [ClassifierSample]) -> Double {
        let located = samples.sorted { $0.timestamp < $1.timestamp }.filter { sample in
            sample.point != nil && (sample.horizontalAccuracy ?? 0) <= maximumAccuracyMeters
        }
        guard let first = located.first?.point, let last = located.last?.point else { return 0 }
        return first.distance(to: last)
    }

    public static func pathMeters(samples: [ClassifierSample]) -> Double {
        struct Fix { var point: ClassifierPoint; let time: Date; let accuracy: Double }
        let raw: [Fix] = samples.sorted { $0.timestamp < $1.timestamp }.compactMap { sample in
            let accuracy = sample.horizontalAccuracy ?? 0
            guard let point = sample.point, point.latitude.isFinite, point.longitude.isFinite,
                  accuracy >= 0, accuracy <= maximumAccuracyMeters,
                  sample.motion != .stationary else { return nil }
            return Fix(point: point, time: sample.timestamp, accuracy: accuracy)
        }
        guard raw.count >= 2 else { return 0 }
        var smoothed = raw
        var lower = 0, upper = 0
        for index in raw.indices {
            while raw[lower].time.timeIntervalSince(raw[index].time) < -smoothingSeconds { lower += 1 }
            while upper + 1 < raw.count, raw[upper + 1].time.timeIntervalSince(raw[index].time) <= smoothingSeconds { upper += 1 }
            let window = raw[lower...max(lower, upper)]
            smoothed[index].point = ClassifierPoint.centroid(window.map(\.point)) ?? raw[index].point
        }
        var total = 0.0
        var anchor = smoothed[0]
        for fix in smoothed.dropFirst() {
            let meters = anchor.point.distance(to: fix.point)
            let threshold = max(jitterFloorMeters, accuracyMultiplier * max(anchor.accuracy, fix.accuracy))
            guard meters >= threshold else { continue }
            let seconds = fix.time.timeIntervalSince(anchor.time)
            if seconds > 0, meters / seconds > maximumGroundSpeed { continue }
            total += meters
            anchor = fix
        }
        return total
    }

    /// 두 체류 사이 점프가 비행인가. 지상에서 불가능한 속도(70m/s 초과)이고
    /// 100km 넘게 떨어졌거나 양끝이 공항 근처일 때만. 이름만으로는 정하지 않는다.
    public static func isFlightJump(distanceMeters: Double, duration: TimeInterval, originNearAirport: Bool, destinationNearAirport: Bool) -> Bool {
        guard duration > 0, distanceMeters / duration > maximumGroundSpeed else { return false }
        return distanceMeters >= 100_000 || (originNearAirport && destinationNearAirport)
    }
}
