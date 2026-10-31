import Foundation

public struct StepSample: Hashable, Sendable {
    public enum Device: String, Codable, Sendable { case appleWatch, iPhone }
    public var interval: ClassifierInterval
    public var count: Double
    public var device: Device

    public init(interval: ClassifierInterval, count: Double, device: Device) {
        self.interval = interval
        self.count = count
        self.device = device
    }
}

/// 걸음·거리·시간 지표. 화면·위젯·연봉이 같은 값을 쓴다.
public enum DayMetrics {
    /// 걸음 = 워치 우선, 워치가 덮지 않은 시간의 아이폰 걸음만 더한다.
    /// 아이폰·워치 중 큰 값(max)은 서로 다른 시간의 걸음을 버리므로 쓰지 않는다.
    public static func steps(_ samples: [StepSample], in day: ClassifierInterval) -> Double {
        let watch = samples.filter { $0.device == .appleWatch && $0.count > 0 }
        let watchCover = ClassifierInterval.union(watch.map(\.interval))
        let watchSteps = watch.reduce(0.0) { $0 + prorated($1, day) }
        let phoneSteps = samples.filter { $0.device == .iPhone && $0.count > 0 }.reduce(0.0) { sum, sample in
            guard sample.interval.duration > 0 else {
                let covered = watchCover.contains { $0.start <= sample.interval.start && sample.interval.start < $0.end }
                return sum + (!covered && day.start <= sample.interval.start && sample.interval.start < day.end ? sample.count : 0)
            }
            let free = ClassifierInterval.subtracting(watchCover, from: [sample.interval])
            let freeInDay = free.compactMap { $0.intersection(with: day)?.duration }.reduce(0, +)
            return sum + sample.count * freeInDay / sample.interval.duration
        }
        return watchSteps + phoneSteps
    }

    static func prorated(_ sample: StepSample, _ day: ClassifierInterval) -> Double {
        guard sample.interval.duration > 0 else {
            return day.start <= sample.interval.start && sample.interval.start < day.end ? sample.count : 0
        }
        return sample.count * sample.interval.overlap(with: day) / sample.interval.duration
    }

    /// 수단별 거리. 날을 걸친 구간은 겹친 시간 비율만큼.
    public static func distanceByMode(_ segments: [ClassifiedSegment], in day: ClassifierInterval) -> [TransportMode: Double] {
        segments.reduce(into: [:]) { result, segment in
            guard segment.distanceMeters.isFinite, segment.distanceMeters > 0 else { return }
            let fraction = segment.interval.duration > 0 ? segment.interval.overlap(with: day) / segment.interval.duration : 1
            guard fraction > 0 else { return }
            result[segment.mode, default: 0] += segment.distanceMeters * min(1, fraction)
        }
    }

    public static func seconds(_ intervals: [ClassifierInterval], in day: ClassifierInterval) -> TimeInterval {
        ClassifierInterval.union(intervals.compactMap { $0.intersection(with: day) }).reduce(0) { $0 + $1.duration }
    }

    public struct Away: Hashable, Sendable {
        /// 집 밖 체류 + 이동.
        public var awaySeconds: TimeInterval
        /// 집 체류.
        public var homeSeconds: TimeInterval
        /// 기록이 없어 어디였는지 모르는 시간. 외출로 세지 않는다.
        public var unknownSeconds: TimeInterval
    }

    /// 외출 = 집 밖 체류 + 이동의 합. 기록 공백은 따로 '알 수 없음'.
    public static func away(home: [ClassifierInterval], elsewhere: [ClassifierInterval], travel: [ClassifierInterval], in day: ClassifierInterval) -> Away {
        let homeUnion = ClassifierInterval.union(home.compactMap { $0.intersection(with: day) })
        let outside = ClassifierInterval.subtracting(homeUnion, from: ClassifierInterval.union((elsewhere + travel).compactMap { $0.intersection(with: day) }))
        let homeSeconds = homeUnion.reduce(0) { $0 + $1.duration }
        let awaySeconds = outside.reduce(0) { $0 + $1.duration }
        return Away(awaySeconds: awaySeconds, homeSeconds: homeSeconds, unknownSeconds: max(0, day.duration - homeSeconds - awaySeconds))
    }

    /// 업무 시간 × 시급. 연봉 화면과 Live Activity가 같은 업무 시간을 쓴다.
    public static func earnings(workSeconds: TimeInterval, hourlyRate: Double) -> Double {
        guard workSeconds > 0, hourlyRate > 0 else { return 0 }
        return workSeconds / 3_600 * hourlyRate
    }
}
