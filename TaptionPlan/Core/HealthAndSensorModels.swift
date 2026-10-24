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
        case .inBed:
            AppLanguagePreference.text(korean: "침대에 있음", english: "In bed")
        case .awake:
            AppLanguagePreference.text(korean: "깨어 있음", english: "Awake")
        case .core:
            AppLanguagePreference.text(korean: "코어 수면", english: "Core sleep")
        case .deep:
            AppLanguagePreference.text(korean: "깊은 수면", english: "Deep sleep")
        case .rem:
            AppLanguagePreference.text(korean: "REM 수면", english: "REM sleep")
        case .asleepUnspecified:
            AppLanguagePreference.text(korean: "수면", english: "Sleep")
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

extension SleepSession {
    /// Apple Watch sleep is a derived provenance check. The HealthKit sample
    /// and its source metadata remain untouched.
    var isAppleWatchConfirmed: Bool {
        guard asleepDuration > 0 else { return false }
        let provenance = sourceNames + segments.flatMap {
            [$0.sourceName, $0.sourceBundleIdentifier, $0.deviceName ?? ""]
        }
        return provenance.contains {
            $0.localizedCaseInsensitiveContains("watch")
        }
    }
}

// MARK: - Sleep provenance

/// 수면 기록을 만든 기기의 등급. 값이 클수록 그 주장을 먼저 믿는다.
///
/// 애플워치는 몸에 붙어 수면 단계를 직접 재고, 아이폰은 기기 사용 흔적으로
/// 잠을 추정한다. 그래서 워치가 없는 동안에는 아이폰 기록으로 먼저 결과를
/// 만들고(`isProvisional`), 워치 기록이 도착하면 그 밤의 수면·기상 주장을
/// 워치 것으로 갈아 끼운다. `inBed`는 수면 주장이 아니라 "침대에 있었다"는
/// 별개 사실이고 수면 효율의 분모라서 등급과 무관하게 합친다.
enum SleepSourceTier: String, Codable, CaseIterable, Hashable, Sendable {
    case unknown
    case iPhone
    case thirdParty
    case appleWatch

    var priority: Int {
        switch self {
        case .unknown: 0
        case .iPhone: 10
        case .thirdParty: 20
        case .appleWatch: 30
        }
    }

    /// 이 등급으로 만든 결과를 더 높은 등급이 나중에 보정할 수 있는지.
    var needsConfirmation: Bool {
        self != .appleWatch
    }

    var displayName: String {
        switch self {
        case .unknown:
            AppLanguagePreference.text(korean: "출처 미상", english: "Unknown source")
        case .iPhone:
            AppLanguagePreference.text(korean: "아이폰", english: "iPhone")
        case .thirdParty:
            AppLanguagePreference.text(korean: "다른 앱", english: "Other app")
        case .appleWatch:
            AppLanguagePreference.text(korean: "애플워치", english: "Apple Watch")
        }
    }
}

extension SleepSegment {
    /// 이 표본을 만든 기기의 등급. HealthKit이 주는 출처 메타데이터만 본다.
    var sourceTier: SleepSourceTier {
        Self.sourceTier(
            sourceName: sourceName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            deviceName: deviceName
        )
    }

    static func sourceTier(
        sourceName: String,
        sourceBundleIdentifier: String,
        deviceName: String?
    ) -> SleepSourceTier {
        let device = (deviceName ?? "").lowercased()
        let name = sourceName.lowercased()
        let bundle = sourceBundleIdentifier.lowercased()
        if device.contains("watch") || name.contains("watch") {
            return .appleWatch
        }
        // 워치·타 기기에서 올라온 HealthKit 표본의 출처 번들은
        // `com.apple.health.<기기 UUID>` 꼴이고, 아이폰 건강 앱이 직접 만든
        // 표본은 `com.apple.Health`다.
        if bundle.hasPrefix("com.apple.health.") {
            return .appleWatch
        }
        if device.contains("iphone") || name.contains("iphone") {
            return .iPhone
        }
        if bundle == "com.apple.health" {
            return .iPhone
        }
        if bundle.isEmpty && name.isEmpty && device.isEmpty {
            return .unknown
        }
        return .thirdParty
    }
}

extension SleepSession {
    /// 이 세션을 이끈 가장 높은 등급. 구간에서 파생하므로 저장하지 않는다.
    /// 구간이 비어 있는 세션(테스트·복원 경로)은 출처 이름으로 대신 판정한다.
    var sourceTier: SleepSourceTier {
        if let fromSegments = segments
            .map(\.sourceTier)
            .max(by: { $0.priority < $1.priority }),
           fromSegments != .unknown {
            return fromSegments
        }
        return sourceNames
            .map {
                SleepSegment.sourceTier(
                    sourceName: $0,
                    sourceBundleIdentifier: "",
                    deviceName: nil
                )
            }
            .max(by: { $0.priority < $1.priority }) ?? .unknown
    }

    /// 워치 기록 없이 만든 잠정 결과인지. 워치 데이터가 오면 보정 대상이다.
    var isProvisional: Bool {
        sourceTier.needsConfirmation
    }

    /// 워치가 이 밤의 수면 시간을 확정했는지.
    var isWatchAuthoritative: Bool {
        sourceTier == .appleWatch && asleepDuration > 0
    }
}

/// 워치 기록이 늦게 도착해 아이폰 추정 결과를 갈아 끼웠을 때 남기는 기록.
/// 값 자체를 되돌릴 수는 없으므로, 무엇이 얼마나 달라졌는지만 보관한다.
struct SleepReconciliation: Identifiable, Codable, Hashable, Sendable {
    enum Reason: String, Codable, Hashable, Sendable {
        /// 잠정(아이폰) 추정을 워치가 확정으로 대체했다.
        case watchReplacedEstimate
        /// 워치 기록만 있던 밤에 잠정 추정이 없었다가 워치가 채웠다.
        case watchFilledGap
    }

    var id: UUID
    /// 그 밤을 가리키는 날짜(기상일 기준 자정).
    var overnightDate: Date
    var estimatedTier: SleepSourceTier
    var estimatedSpan: TimeSpan?
    var estimatedAsleepDuration: TimeInterval
    var authoritativeTier: SleepSourceTier
    var authoritativeSpan: TimeSpan
    var authoritativeAsleepDuration: TimeInterval
    var reason: Reason
    var reconciledAt: Date

    var asleepDurationDelta: TimeInterval {
        authoritativeAsleepDuration - estimatedAsleepDuration
    }

    var spanStartDelta: TimeInterval {
        guard let estimatedSpan else { return 0 }
        return authoritativeSpan.start.timeIntervalSince(estimatedSpan.start)
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
        case .batterySaver: 15 * 60
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
        case .batterySaver:
            AppLanguagePreference.text(korean: "배터리 최소화", english: "Battery saver")
        case .balanced:
            AppLanguagePreference.text(korean: "균형", english: "Balanced")
        case .accuracy:
            AppLanguagePreference.text(korean: "정확도 최적화", english: "Best accuracy")
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

    var normalized: SensorCollectionConfiguration {
        var copy = self
        copy.minimumEmissionInterval = TimeInterval(
            GPSLoggingPreferences.clampedSeconds(
                Int(minimumEmissionInterval.rounded())
            )
        )
        return copy
    }
}

struct GPSLoggingPreferences: Codable, Hashable, Sendable {
    /// User-facing cadence presets shared by Settings and the hamburger menu.
    enum Preset: Int, CaseIterable, Hashable, Sendable {
        case batterySaver = 900
        case balanced = 300
        case realtime = 60

        var intervalSeconds: Int { rawValue }
    }

    /// 1분 단위로 1~15분. 5분 눈금(5·10·15분) 근처 ±1분은 그 눈금에 붙는다.
    static let supportedIntervalSeconds = Array(stride(from: 60, through: 900, by: 60))
    static let snapIntervalSeconds = [300, 600, 900]
    static let batteryMinimalIntervalSeconds = 900

    var isBatteryMinimal: Bool
    var intervalSeconds: Int

    static let standard = GPSLoggingPreferences(intervalSeconds: 300)

    init(
        isBatteryMinimal: Bool = false,
        intervalSeconds: Int = 300
    ) {
        self.isBatteryMinimal = isBatteryMinimal
        self.intervalSeconds = Self.clampedSeconds(intervalSeconds)
    }

    var interval: TimeInterval {
        TimeInterval(effectiveIntervalSeconds)
    }

    var effectiveIntervalSeconds: Int {
        isBatteryMinimal ? Self.batteryMinimalIntervalSeconds : intervalSeconds
    }

    var preset: Preset {
        get {
            Preset(rawValue: effectiveIntervalSeconds)
                ?? (effectiveIntervalSeconds > Preset.balanced.rawValue
                    ? .batterySaver : .realtime)
        }
        set {
            isBatteryMinimal = newValue == .batterySaver
            intervalSeconds = newValue.intervalSeconds
        }
    }

    var isContinuous: Bool {
        effectiveIntervalSeconds < 60
    }

    @available(*, deprecated, message: "Use intervalSeconds")
    var intervalMinutes: Int {
        max(1, Int(ceil(Double(intervalSeconds) / 60)))
    }

    @available(*, deprecated, message: "Use effectiveIntervalSeconds")
    var effectiveIntervalMinutes: Int {
        max(1, Int(ceil(Double(effectiveIntervalSeconds) / 60)))
    }

    private enum CodingKeys: String, CodingKey {
        case isBatteryMinimal
        case intervalSeconds
        case intervalMinutes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let isBatteryMinimal = try values.decodeIfPresent(
            Bool.self,
            forKey: .isBatteryMinimal
        ) ?? false
        let seconds = try values.decodeIfPresent(
            Int.self,
            forKey: .intervalSeconds
        ) ?? (try values.decodeIfPresent(Int.self, forKey: .intervalMinutes))
            .map { $0 * 60 }
            ?? Self.standard.intervalSeconds
        self.init(
            isBatteryMinimal: isBatteryMinimal,
            intervalSeconds: seconds
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(isBatteryMinimal, forKey: .isBatteryMinimal)
        try values.encode(intervalSeconds, forKey: .intervalSeconds)
    }

    static func clampedSeconds(_ value: Int) -> Int {
        let minute = supportedIntervalSeconds.min {
            abs($0 - value) < abs($1 - value)
        } ?? standard.intervalSeconds
        if let snap = snapIntervalSeconds.first(where: { abs($0 - minute) <= 60 }) {
            return snap
        }
        return minute
    }

    @available(*, deprecated, message: "Use clampedSeconds")
    static func clampedMinutes(_ value: Int) -> Int {
        max(1, Int(ceil(Double(clampedSeconds(value * 60)) / 60)))
    }
}

/// SSIDs used by the carrier-operated subway Wi-Fi networks.  This is an
/// exact allow-list: generic/legacy names such as `ollehWiFi` are not
/// evidence of a subway ride.  Matching is deliberately independent from
/// the UI and movement classifier so archived readings can be re-analysed.
enum SubwayWiFiSSID {
    static let minimumContinuousObservations = 2
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
        minimumObservations: Int = minimumContinuousObservations
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

    static func hasContinuousEvidence(streak: Int?) -> Bool {
        (streak ?? 0) >= minimumContinuousObservations
    }
}

enum TrackingSessionPolicy {
    static let automaticStartDuration: TimeInterval = 10
    static let automaticStopStationaryDuration: TimeInterval = 2 * 60
    static let activeHorizontalAccuracyLimit: Double = 50
    static let activeDistanceFilterMeters: Double = 5
    static let automaticEmissionThrottleInterval: TimeInterval = 1

    static func allowsAutomaticTracking(
        interval: TimeInterval
    ) -> Bool {
        interval == TimeInterval(GPSLoggingPreferences.Preset.realtime.intervalSeconds)
            || interval == TimeInterval(GPSLoggingPreferences.Preset.balanced.intervalSeconds)
    }

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

    static func isPreciseRouteReading(_ reading: SensorReading) -> Bool {
        guard reading.gpsAvailable,
              reading.locationFixQuality != .approximate,
              let point = reading.point else { return false }
        return point.latitude.isFinite
            && point.longitude.isFinite
            && (-90...90).contains(point.latitude)
            && (-180...180).contains(point.longitude)
            && point.horizontalAccuracy.isFinite
            && (0...activeHorizontalAccuracyLimit)
                .contains(point.horizontalAccuracy)
    }

    static func shouldPromoteBackgroundMovement(
        speedMetersPerSecond: Double,
        displacementMeters: Double,
        elapsed: TimeInterval,
        horizontalAccuracy: Double = 0,
        speedAccuracy: Double = 0
    ) -> Bool {
        guard horizontalAccuracy.isFinite,
              (0...activeHorizontalAccuracyLimit).contains(horizontalAccuracy),
              speedAccuracy.isFinite,
              speedAccuracy >= 0 else { return false }
        return speedMetersPerSecond >= 3
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
