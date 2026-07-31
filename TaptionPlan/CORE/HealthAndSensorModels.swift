import Foundation

// MARK: - Sleep

enum SleepStage: String, Codable, CaseIterable, Hashable, Sendable {
    case inBed
    case awake
    case core
    case deep
    case rem
    case asleepUnspecified

    var isAsleep: Bool {
        switch self {
        case .core, .deep, .rem, .asleepUnspecified:
            true
        case .inBed, .awake:
            false
        }
    }

    var displayName: String {
        switch self {
        case .inBed: "침대에 있음"
        case .awake: "깨어 있음"
        case .core: "코어 수면"
        case .deep: "깊은 수면"
        case .rem: "REM 수면"
        case .asleepUnspecified: "수면"
        }
    }
}

struct SleepSegment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var stage: SleepStage
    var span: TimeSpan
    var sourceName: String
    var sourceBundleIdentifier: String
    var deviceName: String?
    var timeZoneIdentifier: String?
    var isUserEntered: Bool

    init(
        id: UUID = UUID(),
        stage: SleepStage,
        span: TimeSpan,
        sourceName: String,
        sourceBundleIdentifier: String = "",
        deviceName: String? = nil,
        timeZoneIdentifier: String? = nil,
        isUserEntered: Bool = false
    ) {
        self.id = id
        self.stage = stage
        self.span = span
        self.sourceName = sourceName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.deviceName = deviceName
        self.timeZoneIdentifier = timeZoneIdentifier
        self.isUserEntered = isUserEntered
    }
}

struct SleepSession: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var span: TimeSpan
    var asleepDuration: TimeInterval
    var awakeDuration: TimeInterval
    var inBedDuration: TimeInterval
    var stageDurations: [SleepStage: TimeInterval]
    var sourceNames: [String]
    var segments: [SleepSegment]

    var sleepEfficiency: Double? {
        let denominator = inBedDuration > 0
            ? inBedDuration
            : asleepDuration + awakeDuration
        guard denominator > 0 else { return nil }
        return min(1, max(0, asleepDuration / denominator))
    }
}

// MARK: - Motion and pedometer

struct SensorVector3: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var z: Double
}

struct DeviceMotionSnapshot: Codable, Hashable, Sendable {
    var gravity: SensorVector3
    var userAcceleration: SensorVector3
    var rotationRate: SensorVector3
    var attitudeRadians: SensorVector3
}

struct MotionActivityRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var span: TimeSpan
    var motion: MotionKind
    var confidence: ConfidenceLevel

    init(
        id: UUID = UUID(),
        span: TimeSpan,
        motion: MotionKind,
        confidence: ConfidenceLevel
    ) {
        self.id = id
        self.span = span
        self.motion = motion
        self.confidence = confidence
    }
}

struct PedometerSummary: Codable, Hashable, Sendable {
    var span: TimeSpan
    var stepCount: Int
    var distanceMeters: Double?
    var floorsAscended: Int?
    var floorsDescended: Int?
    var averageActivePaceSecondsPerMeter: Double?
}

struct SensorHardwareAvailability: Codable, Hashable, Sendable {
    var location: Bool
    var motionActivity: Bool
    var deviceMotion: Bool
    var relativeAltitude: Bool
    var stepCounting: Bool
    var distance: Bool
    var floorCounting: Bool
}

struct SensorCollectionConfiguration: Codable, Hashable, Sendable {
    var highAccuracyDuringMovement: Bool
    var collectsDeviceMotion: Bool
    var allowsBackgroundLocation: Bool
    var minimumEmissionInterval: TimeInterval

    static let standard = SensorCollectionConfiguration(
        highAccuracyDuringMovement: true,
        collectsDeviceMotion: true,
        allowsBackgroundLocation: false,
        minimumEmissionInterval: 15
    )
}
