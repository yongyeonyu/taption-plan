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

    /// HealthKit은 같은 시각에 여러 단계를 겹쳐 보낸다(침대에 있음이 밤 전체를
    /// 덮고 그 위에 코어·깊은 수면이 얹힌다). 겹친 구간을 한 단계로 정할 때
    /// 쓰는 우선순위로, 구체적인 관측이 포괄적인 관측을 이긴다.
    var overlapPriority: Int {
        switch self {
        case .awake: 60
        case .deep: 50
        case .rem: 40
        case .core: 30
        case .asleepUnspecified: 20
        case .inBed: 10
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
        // Core Motion flags are not mutually exclusive. Vehicle vibration can
        // surface as walking, so keep automotive ahead of the pedestrian flag.
        if automotive { return .automotive }
        if walking { return .walking }
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
        case .batterySaver: 10 * 60
        case .balanced: 5 * 60
        case .accuracy: 60
        }
    }

    var intervalMinutes: Int {
        Int(interval / 60)
    }

    /// Hardware is awake only for this short sampling window. The interval
    /// remains the time between sample starts; tracking sessions are the only
    /// mode that intentionally keeps the streams alive.
    var samplingWindowDuration: TimeInterval {
        switch self {
        case .batterySaver: 8
        case .balanced: 10
        case .accuracy: 12
        }
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
            collectsDeviceMotion: true,
            allowsBackgroundLocation: allowsBackgroundLocation,
            minimumEmissionInterval: profile.interval
        )
    }
}

struct GPSLoggingPreferences: Codable, Hashable, Sendable {
    var isBatteryMinimal: Bool
    var intervalMinutes: Int

    static let standard = GPSLoggingPreferences()

    init(
        isBatteryMinimal: Bool = false,
        intervalMinutes: Int = 5
    ) {
        self.isBatteryMinimal = isBatteryMinimal
        self.intervalMinutes = Self.clampedMinutes(intervalMinutes)
    }

    var interval: TimeInterval {
        TimeInterval(effectiveIntervalMinutes * 60)
    }

    /// Battery-minimal tracking is intentionally fixed at one sample every
    /// five minutes. The stored minute value remains available for the other
    /// mode so changing modes does not lose the user's cadence choice.
    var effectiveIntervalMinutes: Int {
        isBatteryMinimal ? 5 : intervalMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case isBatteryMinimal
        case intervalMinutes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isBatteryMinimal: try values.decodeIfPresent(
                Bool.self,
                forKey: .isBatteryMinimal
            ) ?? false,
            intervalMinutes: try values.decodeIfPresent(
                Int.self,
                forKey: .intervalMinutes
            ) ?? Self.standard.intervalMinutes
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(isBatteryMinimal, forKey: .isBatteryMinimal)
        try values.encode(intervalMinutes, forKey: .intervalMinutes)
    }

    static func clampedMinutes(_ value: Int) -> Int {
        min(max(value, 1), 15)
    }
}

/// SSIDs used by the carrier-operated subway Wi-Fi networks.  This is an
/// exact allow-list: generic/legacy names such as `ollehWiFi` are not
/// evidence of a subway ride.  Matching is deliberately independent from
/// the UI and movement classifier so archived readings can be re-analysed.
enum SubwayWiFiSSID {
    private static let allowed: Set<String> = [
        "t wifi",
        "t wifi secure",
        "kt wifi",
        "kt wifi secure",
        "u+ zone",
        "t wifi zone secure",
        "free u+zone",
        "free utzone 2.4ghz",
        "kt giga wifi",
        "kt free wifi",
        "t free wifi zone",
        "t wifi zone",
    ]

    static func normalized(_ ssid: String) -> String {
        ssid
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
            .lowercased()
    }

    static func isAllowed(_ ssid: String?) -> Bool {
        guard let ssid else { return false }
        return allowed.contains(normalized(ssid))
    }

    /// A run of accepted, connected SSIDs is a stronger signal than a single
    /// scan.  Secure/open variants may alternate while the device remains in
    /// the train, so the name itself need not remain identical.
    static func hasContinuousEvidence(
        _ ssids: [String?],
        minimumObservations: Int = 2
    ) -> Bool {
        guard minimumObservations > 0 else { return false }
        var run = 0
        for ssid in ssids {
            if isAllowed(ssid) {
                run += 1
                if run >= minimumObservations { return true }
            } else {
                run = 0
            }
        }
        return false
    }
}

enum TrackingSessionPolicy {
    static let automaticStartDuration: TimeInterval = 10
    static let automaticStopStationaryDuration: TimeInterval = 2 * 60
    static let activeHorizontalAccuracyLimit: Double = 50
    static let activeDistanceFilterMeters: Double = 5
    static let automaticEmissionThrottleInterval: TimeInterval = 1

    static func allowsPersistingLocation(
        horizontalAccuracy: Double,
        batteryMinimal: Bool
    ) -> Bool {
        horizontalAccuracy >= 0
            && (
                batteryMinimal
                    || horizontalAccuracy <= activeHorizontalAccuracyLimit
            )
    }

    static func shouldPromoteBackgroundMovement(
        speedMetersPerSecond: Double,
        displacementMeters: Double,
        elapsed: TimeInterval
    ) -> Bool {
        speedMetersPerSecond >= 3
            || elapsed > 0 && elapsed <= 10 * 60
                && displacementMeters >= 80
    }

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
