import Foundation

/// 분류 파이프라인 버전. 자동 기록의 `modelVersion`은 `classifier-v1/<단계>`.
public enum ClassifierPipeline {
    public static let version = "classifier-v1"

    public static func modelVersion(_ stage: String) -> String { "\(version)/\(stage)" }
}

/// 창 점수·HMM이 다루는 10개 상태.
public enum TransportMode: String, CaseIterable, Codable, Hashable, Sendable {
    case stationary, walking, running, cycling, car, bus, subway, train, ship, airplane

    public var isVehicle: Bool {
        switch self {
        case .car, .bus, .subway, .train, .ship, .airplane: true
        default: false
        }
    }

    public var isOnFoot: Bool { self == .walking || self == .running }
}

/// 정지 판정 임계값 하나. 휴대폰·워치 모두 이 값을 쓴다.
public enum IdleThresholds {
    /// 가속도 크기 표준편차(g)가 이 값 이하이면 손에 들거나 몸에 붙어 있지 않다.
    public static let accelerationStandardDeviationG = 0.01
    /// 회전 속도(rad/s)가 이 값 이하이면 정지.
    public static let rotationRadiansPerSecond = 0.03
    /// GPS 속도가 이 값 이하이면 정지로 본다.
    public static let stationarySpeed = 0.5

    public static func isIdle(accelerationStandardDeviationG: Double?, rotationRate: Double?) -> Bool {
        guard let accelerationStandardDeviationG else { return false }
        return accelerationStandardDeviationG <= Self.accelerationStandardDeviationG
            && (rotationRate ?? 0) <= rotationRadiansPerSecond
    }
}

public struct ClassifierPoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// 대권(haversine) 거리, 미터.
    public func distance(to other: ClassifierPoint) -> Double {
        let radius = 6_371_008.8
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    public func bearing(to other: ClassifierPoint) -> Double {
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    public static func centroid(_ points: [ClassifierPoint]) -> ClassifierPoint? {
        guard !points.isEmpty else { return nil }
        let count = Double(points.count)
        return ClassifierPoint(
            latitude: points.map(\.latitude).reduce(0, +) / count,
            longitude: points.map(\.longitude).reduce(0, +) / count
        )
    }
}

/// 운영체제가 준 동작 힌트. 원본 값을 그대로 근거로 남긴다.
public enum MotionHint: String, Codable, Hashable, Sendable {
    case unknown, stationary, walking, running, cycling, automotive
}

/// 원본 센서 한 점. 앱 어댑터가 `SensorReading`에서 복사한다.
public struct ClassifierSample: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var point: ClassifierPoint?
    public var horizontalAccuracy: Double?
    public var speed: Double?
    public var course: Double?
    public var pressureKilopascals: Double?
    public var accelerationStandardDeviationG: Double?
    public var accelerationJerkGPerSecond: Double?
    public var rotationRate: Double?
    public var motion: MotionHint
    public var nearTransitStop: Bool
    public var nearRailStation: Bool
    public var nearAirport: Bool
    public var onWater: Bool
    public var isCharging: Bool?
    public var screenIsOn: Bool?
    public var screenBrightness: Double?
    public var stepCadence: Double?

    public init(
        timestamp: Date,
        point: ClassifierPoint? = nil,
        horizontalAccuracy: Double? = nil,
        speed: Double? = nil,
        course: Double? = nil,
        pressureKilopascals: Double? = nil,
        accelerationStandardDeviationG: Double? = nil,
        accelerationJerkGPerSecond: Double? = nil,
        rotationRate: Double? = nil,
        motion: MotionHint = .unknown,
        nearTransitStop: Bool = false,
        nearRailStation: Bool = false,
        nearAirport: Bool = false,
        onWater: Bool = false,
        isCharging: Bool? = nil,
        screenIsOn: Bool? = nil,
        screenBrightness: Double? = nil,
        stepCadence: Double? = nil
    ) {
        self.timestamp = timestamp
        self.point = point
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.course = course
        self.pressureKilopascals = pressureKilopascals
        self.accelerationStandardDeviationG = accelerationStandardDeviationG
        self.accelerationJerkGPerSecond = accelerationJerkGPerSecond
        self.rotationRate = rotationRate
        self.motion = motion
        self.nearTransitStop = nearTransitStop
        self.nearRailStation = nearRailStation
        self.nearAirport = nearAirport
        self.onWater = onWater
        self.isCharging = isCharging
        self.screenIsOn = screenIsOn
        self.screenBrightness = screenBrightness
        self.stepCadence = stepCadence
    }
}

public struct ClassifierInterval: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = max(start, end)
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public func overlap(with other: ClassifierInterval) -> TimeInterval {
        max(0, min(end, other.end).timeIntervalSince(max(start, other.start)))
    }

    public func intersection(with other: ClassifierInterval) -> ClassifierInterval? {
        let lower = max(start, other.start), upper = min(end, other.end)
        return lower < upper ? ClassifierInterval(start: lower, end: upper) : nil
    }

    /// 겹치는 구간을 합쳐 정렬된 서로소 목록으로.
    public static func union(_ values: [ClassifierInterval], gap: TimeInterval = 0) -> [ClassifierInterval] {
        var result: [ClassifierInterval] = []
        for value in values.sorted(by: { $0.start < $1.start }) where value.duration > 0 {
            if let last = result.last, value.start.timeIntervalSince(last.end) <= gap {
                result[result.count - 1].end = max(last.end, value.end)
            } else {
                result.append(value)
            }
        }
        return result
    }

    /// `values`에서 `cuts`를 뺀 나머지.
    public static func subtracting(_ cuts: [ClassifierInterval], from values: [ClassifierInterval]) -> [ClassifierInterval] {
        let cuts = union(cuts)
        return values.flatMap { value -> [ClassifierInterval] in
            var pieces = [value]
            for cut in cuts {
                pieces = pieces.flatMap { piece -> [ClassifierInterval] in
                    guard piece.overlap(with: cut) > 0 else { return [piece] }
                    return [
                        ClassifierInterval(start: piece.start, end: cut.start),
                        ClassifierInterval(start: cut.end, end: piece.end),
                    ].filter { $0.duration > 0 }
                }
            }
            return pieces
        }
    }
}
