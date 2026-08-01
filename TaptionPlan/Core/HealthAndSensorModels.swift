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
    var magneticFieldMicroteslas: SensorVector3? = nil
    var magneticFieldAccuracy: Int? = nil
    var headingDegrees: Double? = nil
}

/// A compact statistical window of the high-frequency motion stream.
/// The raw stream is too large to place on the timeline, so every persisted
/// sensor reading carries the features needed for movement classification.
struct DeviceMotionSummary: Codable, Hashable, Sendable {
    var sampleCount: Int
    var meanUserAccelerationG: Double
    var userAccelerationStandardDeviationG: Double
    var peakUserAccelerationG: Double
    var meanRotationRateRadiansPerSecond: Double
    var rotationRateStandardDeviationRadiansPerSecond: Double
    var peakRotationRateRadiansPerSecond: Double
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

enum MotionKindResolver {
    static func resolve(
        stationary: Bool,
        walking: Bool,
        running: Bool,
        cycling: Bool,
        automotive: Bool
    ) -> MotionKind {
        if running { return .running }
        if cycling { return .cycling }
        if walking { return .walking }
        // Core Motion may report automotive and stationary together while a
        // vehicle waits at a light. Preserve the enclosing vehicle segment.
        if automotive { return .automotive }
        if stationary { return .stationary }
        return .unknown
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

enum AppleMovementEvidenceSource: String, Codable, Hashable, Sendable {
    case iPhone
    case appleWatch
    case other
}

enum AppleMovementEvidenceKind: String, Codable, Hashable, Sendable {
    case workout
    case steps
}

struct AppleMovementEvidence: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var span: TimeSpan
    var source: AppleMovementEvidenceSource
    var kind: AppleMovementEvidenceKind
    var workoutMode: TravelMode?
    var stepCount: Int?
    var distanceMeters: Double?
    var sourceName: String
    var deviceName: String?

    init(
        id: UUID = UUID(),
        span: TimeSpan,
        source: AppleMovementEvidenceSource,
        kind: AppleMovementEvidenceKind,
        workoutMode: TravelMode? = nil,
        stepCount: Int? = nil,
        distanceMeters: Double? = nil,
        sourceName: String,
        deviceName: String? = nil
    ) {
        self.id = id
        self.span = span
        self.source = source
        self.kind = kind
        self.workoutMode = workoutMode
        self.stepCount = stepCount
        self.distanceMeters = distanceMeters
        self.sourceName = sourceName
        self.deviceName = deviceName
    }
}

struct SensorHardwareAvailability: Codable, Hashable, Sendable {
    var location: Bool
    var motionActivity: Bool
    var deviceMotion: Bool
    var magnetometer: Bool
    var relativeAltitude: Bool
    var stepCounting: Bool
    var distance: Bool
    var floorCounting: Bool
    var pace: Bool
    var cadence: Bool
}

enum SensorCollectionProfile: Int, Codable, CaseIterable, Hashable, Sendable {
    case batterySaver = 0
    case balanced = 1
    case accuracy = 2

    var interval: TimeInterval {
        switch self {
        case .batterySaver: 15 * 60
        case .balanced: 5 * 60
        case .accuracy: 60
        }
    }

    var intervalMinutes: Int {
        Int(interval / 60)
    }

    var displayName: String {
        switch self {
        case .batterySaver: "배터리 최소화"
        case .balanced: "균형"
        case .accuracy: "정확도 최적화"
        }
    }
}

struct SensorCollectionConfiguration: Codable, Hashable, Sendable {
    var profile: SensorCollectionProfile
    var highAccuracyDuringMovement: Bool
    var collectsDeviceMotion: Bool
    var allowsBackgroundLocation: Bool
    var minimumEmissionInterval: TimeInterval

    static let standard = SensorCollectionConfiguration(
        profile: .balanced,
        highAccuracyDuringMovement: true,
        collectsDeviceMotion: true,
        allowsBackgroundLocation: false,
        minimumEmissionInterval: SensorCollectionProfile.balanced.interval
    )

    static func configured(
        for profile: SensorCollectionProfile,
        allowsBackgroundLocation: Bool
    ) -> SensorCollectionConfiguration {
        SensorCollectionConfiguration(
            profile: profile,
            highAccuracyDuringMovement: profile != .batterySaver,
            collectsDeviceMotion: profile != .batterySaver,
            allowsBackgroundLocation: allowsBackgroundLocation,
            minimumEmissionInterval: profile.interval
        )
    }
}

enum TrackingSessionPolicy {
    static let automaticStartDuration: TimeInterval = 10
    static let automaticStopStationaryDuration: TimeInterval = 2 * 60
    static let activeHorizontalAccuracyLimit: Double = 50
    static let activeDistanceFilterMeters: Double = 5

    static func shouldAutomaticallyStart(
        motion: MotionKind,
        confidence: ConfidenceLevel,
        sustainedFor duration: TimeInterval
    ) -> Bool {
        (motion == .walking || motion == .running)
            && confidence != .low
            && duration >= automaticStartDuration
    }

    static func shouldAutomaticallyStop(
        motion: MotionKind,
        stationaryFor duration: TimeInterval
    ) -> Bool {
        motion == .stationary
            && duration >= automaticStopStationaryDuration
    }
}
