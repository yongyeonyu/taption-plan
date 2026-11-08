import Foundation
import TaptionWatchSync
import TaptionPlanCore

// MARK: - Sleep

public enum SleepStage: String, Codable, CaseIterable, Hashable, Sendable {
    case inBed
    case awake
    case core
    case deep
    case rem
    case asleepUnspecified

    public var isAsleep: Bool {
        switch self {
        case .core, .deep, .rem, .asleepUnspecified:
            true
        case .inBed, .awake:
            false
        }
    }

    public var displayName: String {
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
    public var overlapPriority: Int {
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

public struct SleepSegment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var stage: SleepStage
    public var span: TimeSpan
    public var sourceName: String
    public var sourceBundleIdentifier: String
    public var deviceName: String?
    public var timeZoneIdentifier: String?
    public var isUserEntered: Bool

    public init(
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

public struct SleepSession: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var span: TimeSpan
    public var asleepDuration: TimeInterval
    public var awakeDuration: TimeInterval
    public var inBedDuration: TimeInterval
    public var stageDurations: [SleepStage: TimeInterval]
    public var sourceNames: [String]
    public var segments: [SleepSegment]

    public var sleepEfficiency: Double? {
        let denominator = inBedDuration > 0
            ? inBedDuration
            : asleepDuration + awakeDuration
        guard denominator > 0 else { return nil }
        return min(1, max(0, asleepDuration / denominator))
    }

    public init(
        id: UUID,
        span: TimeSpan,
        asleepDuration: TimeInterval,
        awakeDuration: TimeInterval,
        inBedDuration: TimeInterval,
        stageDurations: [SleepStage: TimeInterval],
        sourceNames: [String],
        segments: [SleepSegment]
    ) {
        self.id = id
        self.span = span
        self.asleepDuration = asleepDuration
        self.awakeDuration = awakeDuration
        self.inBedDuration = inBedDuration
        self.stageDurations = stageDurations
        self.sourceNames = sourceNames
        self.segments = segments
    }
}

extension SleepSession {
    /// Apple Watch sleep is a derived provenance check. The HealthKit sample
    /// and its source metadata remain untouched.
    public var isAppleWatchConfirmed: Bool {
        guard asleepDuration > 0 else { return false }
        let provenance = sourceNames + segments.flatMap {
            [$0.sourceName, $0.sourceBundleIdentifier, $0.deviceName ?? ""]
        }
        return provenance.contains {
            $0.localizedCaseInsensitiveContains("watch")
        }
    }
}

/// HealthKit 수면은 자동 이동 추정보다 앞선다(대표 확정, CAT1029A01).
///
/// 자는 동안 실내 GPS가 끊기거나 튀면 지하철·이동 구간이 만들어진다. 그 시간의
/// 대분류는 수면이므로, 수면에 대부분 덮인 **자동** 이동 구간은 지운다. 사용자가
/// 확인·교정한 이동은 남기고, GPS 원본은 이 구간과 따로 보관되어 그대로 남는다.
public enum SleepTravelReconciliationEngine {
    /// 구간 길이 중 이 비율 이상이 수면에 덮이면 자동 이동을 지운다.
    public static let coveredFraction = 0.5

    public static func removingAutomaticTravel(
        _ travel: [TravelSegment],
        sessions: [SleepSession],
        inside span: TimeSpan,
        asOf date: Date = .now
    ) -> [TravelSegment] {
        let sleep = sessions.compactMap { session -> TimeSpan? in
            guard session.asleepDuration > 0,
                  let clipped = session.span.intersection(with: span),
                  min(clipped.end, date) > clipped.start else { return nil }
            return TimeSpan(start: clipped.start, end: min(clipped.end, date))
        }
        guard !sleep.isEmpty else { return travel }
        return travel.filter { segment in
            guard !isUserConfirmed(segment), segment.span.duration > 0 else { return true }
            let covered = ActualIntervalMergeEngine.union(
                sleep.compactMap { segment.span.intersection(with: $0) },
                mergeGap: 0
            ).reduce(0) { $0 + $1.duration }
            return covered < segment.span.duration * coveredFraction
        }
    }

    public static func isUserConfirmed(_ segment: TravelSegment) -> Bool {
        segment.isConfirmed || segment.evidence.contains {
            $0.hasPrefix("사용자 확인") || $0 == "사용자 교정"
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
public enum SleepSourceTier: String, Codable, CaseIterable, Hashable, Sendable {
    case unknown
    case iPhone
    case thirdParty
    case appleWatch

    public var priority: Int {
        switch self {
        case .unknown: 0
        case .iPhone: 10
        case .thirdParty: 20
        case .appleWatch: 30
        }
    }

    /// 이 등급으로 만든 결과를 더 높은 등급이 나중에 보정할 수 있는지.
    public var needsConfirmation: Bool {
        self != .appleWatch
    }

    public var displayName: String {
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
    public var sourceTier: SleepSourceTier {
        Self.sourceTier(
            sourceName: sourceName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            deviceName: deviceName
        )
    }

    public static func sourceTier(
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
    public var sourceTier: SleepSourceTier {
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
    public var isProvisional: Bool {
        sourceTier.needsConfirmation
    }

    /// 워치가 이 밤의 수면 시간을 확정했는지.
    public var isWatchAuthoritative: Bool {
        sourceTier == .appleWatch && asleepDuration > 0
    }
}

/// 워치 기록이 늦게 도착해 아이폰 추정 결과를 갈아 끼웠을 때 남기는 기록.
/// 값 자체를 되돌릴 수는 없으므로, 무엇이 얼마나 달라졌는지만 보관한다.
public struct SleepReconciliation: Identifiable, Codable, Hashable, Sendable {
    public enum Reason: String, Codable, Hashable, Sendable {
        /// 잠정(아이폰) 추정을 워치가 확정으로 대체했다.
        case watchReplacedEstimate
        /// 워치 기록만 있던 밤에 잠정 추정이 없었다가 워치가 채웠다.
        case watchFilledGap
    }

    public var id: UUID
    /// 그 밤을 가리키는 날짜(기상일 기준 자정).
    public var overnightDate: Date
    public var estimatedTier: SleepSourceTier
    public var estimatedSpan: TimeSpan?
    public var estimatedAsleepDuration: TimeInterval
    public var authoritativeTier: SleepSourceTier
    public var authoritativeSpan: TimeSpan
    public var authoritativeAsleepDuration: TimeInterval
    public var reason: Reason
    public var reconciledAt: Date

    public var asleepDurationDelta: TimeInterval {
        authoritativeAsleepDuration - estimatedAsleepDuration
    }

    public var spanStartDelta: TimeInterval {
        guard let estimatedSpan else { return 0 }
        return authoritativeSpan.start.timeIntervalSince(estimatedSpan.start)
    }

    public init(
        id: UUID,
        overnightDate: Date,
        estimatedTier: SleepSourceTier,
        estimatedSpan: TimeSpan? = nil,
        estimatedAsleepDuration: TimeInterval,
        authoritativeTier: SleepSourceTier,
        authoritativeSpan: TimeSpan,
        authoritativeAsleepDuration: TimeInterval,
        reason: Reason,
        reconciledAt: Date
    ) {
        self.id = id
        self.overnightDate = overnightDate
        self.estimatedTier = estimatedTier
        self.estimatedSpan = estimatedSpan
        self.estimatedAsleepDuration = estimatedAsleepDuration
        self.authoritativeTier = authoritativeTier
        self.authoritativeSpan = authoritativeSpan
        self.authoritativeAsleepDuration = authoritativeAsleepDuration
        self.reason = reason
        self.reconciledAt = reconciledAt
    }
}

// MARK: - Motion and pedometer

// `SensorVector3`·`DeviceMotionSnapshot`·`DeviceMotionSummary`는 `TaptionPlanCore/Domain/SensorReading.swift`에 있다.

public struct MotionActivityRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var span: TimeSpan
    public var motion: MotionKind
    public var confidence: ConfidenceLevel

    public init(
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

public enum MotionKindResolver {
    public static func resolve(
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

public struct PedometerSummary: Codable, Hashable, Sendable {
    public var span: TimeSpan
    public var stepCount: Int
    public var distanceMeters: Double?
    public var floorsAscended: Int?
    public var floorsDescended: Int?
    public var averageActivePaceSecondsPerMeter: Double?

    public init(
        span: TimeSpan,
        stepCount: Int,
        distanceMeters: Double? = nil,
        floorsAscended: Int? = nil,
        floorsDescended: Int? = nil,
        averageActivePaceSecondsPerMeter: Double? = nil
    ) {
        self.span = span
        self.stepCount = stepCount
        self.distanceMeters = distanceMeters
        self.floorsAscended = floorsAscended
        self.floorsDescended = floorsDescended
        self.averageActivePaceSecondsPerMeter = averageActivePaceSecondsPerMeter
    }
}

public enum AppleMovementEvidenceSource: String, Codable, Hashable, Sendable {
    case iPhone
    case appleWatch
    case other
}

public enum AppleMovementEvidenceKind: String, Codable, Hashable, Sendable {
    case workout
    case steps
}

public struct AppleMovementEvidence: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var span: TimeSpan
    public var source: AppleMovementEvidenceSource
    public var kind: AppleMovementEvidenceKind
    public var workoutMode: TravelMode?
    public var stepCount: Int?
    public var distanceMeters: Double?
    public var sourceName: String
    public var deviceName: String?

    public init(
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

public struct SensorHardwareAvailability: Codable, Hashable, Sendable {
    public var location: Bool
    public var motionActivity: Bool
    public var deviceMotion: Bool
    public var magnetometer: Bool
    public var relativeAltitude: Bool
    public var stepCounting: Bool
    public var distance: Bool
    public var floorCounting: Bool
    public var pace: Bool
    public var cadence: Bool

    public init(
        location: Bool,
        motionActivity: Bool,
        deviceMotion: Bool,
        magnetometer: Bool,
        relativeAltitude: Bool,
        stepCounting: Bool,
        distance: Bool,
        floorCounting: Bool,
        pace: Bool,
        cadence: Bool
    ) {
        self.location = location
        self.motionActivity = motionActivity
        self.deviceMotion = deviceMotion
        self.magnetometer = magnetometer
        self.relativeAltitude = relativeAltitude
        self.stepCounting = stepCounting
        self.distance = distance
        self.floorCounting = floorCounting
        self.pace = pace
        self.cadence = cadence
    }
}

public enum SensorCollectionProfile: Int, Codable, CaseIterable, Hashable, Sendable {
    case batterySaver = 0
    case balanced = 1
    case accuracy = 2

    public var interval: TimeInterval {
        switch self {
        case .batterySaver: 15 * 60
        case .balanced: 5 * 60
        case .accuracy: 60
        }
    }

    public var intervalMinutes: Int {
        Int(interval / 60)
    }

    /// Hardware is awake only for this short sampling window. The interval
    /// remains the time between sample starts; tracking sessions are the only
    /// mode that intentionally keeps the streams alive.
    public var samplingWindowDuration: TimeInterval {
        switch self {
        case .batterySaver: 8
        case .balanced: 10
        case .accuracy: 12
        }
    }

    public var displayName: String {
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

public struct SensorCollectionConfiguration: Codable, Hashable, Sendable {
    public var profile: SensorCollectionProfile
    public var highAccuracyDuringMovement: Bool
    public var collectsDeviceMotion: Bool
    public var allowsBackgroundLocation: Bool
    public var minimumEmissionInterval: TimeInterval

    public static let standard = SensorCollectionConfiguration(
        profile: .balanced,
        highAccuracyDuringMovement: true,
        collectsDeviceMotion: true,
        allowsBackgroundLocation: false,
        minimumEmissionInterval: SensorCollectionProfile.balanced.interval
    )

    public static func configured(
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

    public var normalized: SensorCollectionConfiguration {
        var copy = self
        copy.minimumEmissionInterval = TimeInterval(
            GPSLoggingPreferences.restoredSeconds(
                Int(minimumEmissionInterval.rounded())
            )
        )
        return copy
    }
}

public struct GPSLoggingPreferences: Codable, Hashable, Sendable {
    /// User-facing cadence presets shared by Settings and the hamburger menu.
    public enum Preset: Int, CaseIterable, Hashable, Sendable {
        case batterySaver = 900
        case balanced = 300
        case realtime = 60

        public var intervalSeconds: Int { rawValue }
    }

    /// 30초 단위로 30초~30분.
    public static let intervalStepSeconds = 30
    public static let supportedIntervalSeconds = Array(
        stride(from: intervalStepSeconds, through: 1_800, by: intervalStepSeconds)
    )
    /// 슬라이더 큰 눈금과 그 위치. 30초·1분이 겹치지 않게 시간에 비례시키지 않는다.
    public static let majorTickSeconds = [30, 60, 300, 600, 900, 1_800]
    public static let majorTickPositions: [Double] = [0, 1, 2, 3, 4, 6]
    public static let batteryMinimalIntervalSeconds = 900

    public var intervalSeconds: Int

    public static let standard = GPSLoggingPreferences(intervalSeconds: 300)

    public init(intervalSeconds: Int = 300) {
        self.intervalSeconds = Self.clampedSeconds(intervalSeconds)
    }

    /// 15분 이상이면 저전력 수집(낮은 정확도 표본도 저장)을 쓴다.
    public var isBatteryMinimal: Bool {
        intervalSeconds >= Self.batteryMinimalIntervalSeconds
    }

    public var interval: TimeInterval {
        TimeInterval(effectiveIntervalSeconds)
    }

    public var effectiveIntervalSeconds: Int {
        intervalSeconds
    }

    public var preset: Preset {
        get {
            Preset(rawValue: effectiveIntervalSeconds)
                ?? (effectiveIntervalSeconds > Preset.balanced.rawValue
                    ? .batterySaver : .realtime)
        }
        set {
            intervalSeconds = newValue.intervalSeconds
        }
    }

    @available(*, deprecated, message: "Use intervalSeconds")
    public var intervalMinutes: Int {
        max(1, Int(ceil(Double(intervalSeconds) / 60)))
    }

    private enum CodingKeys: String, CodingKey {
        case isBatteryMinimal
        case intervalSeconds
        case intervalMinutes
    }

    public init(from decoder: Decoder) throws {
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
        // 이전 빌드의 최소 모드는 저장된 간격과 상관없이 15분으로 수집했다.
        self.init(
            intervalSeconds: isBatteryMinimal
                ? max(seconds, Self.batteryMinimalIntervalSeconds)
                : Self.restoredSeconds(seconds)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(isBatteryMinimal, forKey: .isBatteryMinimal)
        try values.encode(intervalSeconds, forKey: .intervalSeconds)
    }

    public static func clampedSeconds(_ value: Int) -> Int {
        let step = intervalStepSeconds
        let snapped = (value + step / 2) / step * step
        return min(max(snapped, step), supportedIntervalSeconds.last ?? snapped)
    }

    /// 예전 연속 수집 값(30초 미만)은 이전 빌드처럼 1분으로 읽는다.
    public static func restoredSeconds(_ value: Int) -> Int {
        value < intervalStepSeconds
            ? Preset.realtime.intervalSeconds
            : clampedSeconds(value)
    }

    public static func sliderPosition(forSeconds seconds: Int) -> Double {
        let clamped = clampedSeconds(seconds)
        let upper = majorTickSeconds.firstIndex { $0 >= clamped } ?? 0
        guard upper > 0 else { return majorTickPositions[0] }
        let span = Double(majorTickSeconds[upper] - majorTickSeconds[upper - 1])
        let progress = Double(clamped - majorTickSeconds[upper - 1]) / span
        return majorTickPositions[upper - 1]
            + progress * (majorTickPositions[upper] - majorTickPositions[upper - 1])
    }

    public static func seconds(forSliderPosition position: Double) -> Int {
        let upper = majorTickPositions.firstIndex { $0 >= position }
            ?? majorTickPositions.count - 1
        guard upper > 0 else { return majorTickSeconds[0] }
        let span = majorTickPositions[upper] - majorTickPositions[upper - 1]
        let progress = (position - majorTickPositions[upper - 1]) / span
        let seconds = Double(majorTickSeconds[upper - 1])
            + progress * Double(majorTickSeconds[upper] - majorTickSeconds[upper - 1])
        return clampedSeconds(Int(seconds.rounded()))
    }

    /// 30초, 1분, 2분 30초처럼 짧게 적는다.
    public static func intervalText(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let rest = seconds % 60
        return [
            minutes > 0 ? AppLanguagePreference.text("\(minutes)분", "\(minutes)m") : nil,
            rest > 0 ? AppLanguagePreference.text("\(rest)초", "\(rest)s") : nil,
        ].compactMap { $0 }.joined(separator: " ")
    }

}

/// SSIDs used by the carrier-operated subway Wi-Fi networks.  This is an
/// exact allow-list: generic/legacy names such as `ollehWiFi` are not
/// evidence of a subway ride.  Matching is deliberately independent from
/// the UI and movement classifier so archived readings can be re-analysed.
public enum SubwayWiFiSSID {
    public static let minimumContinuousObservations = 2
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

    public static func normalized(_ ssid: String) -> String {
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

    public static func isAllowed(_ ssid: String?) -> Bool {
        guard let ssid else { return false }
        return allowed.contains(normalized(ssid))
    }

    /// A run of accepted, connected SSIDs is a stronger signal than a single
    /// scan.  Secure/open variants may alternate while the device remains in
    /// the train, so the name itself need not remain identical.
    public static func hasContinuousEvidence(
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

    public static func hasContinuousEvidence(streak: Int?) -> Bool {
        (streak ?? 0) >= minimumContinuousObservations
    }
}

public enum TrackingSessionPolicy {
    public static let automaticStartDuration: TimeInterval = 10
    public static let automaticStopStationaryDuration: TimeInterval = 2 * 60
    public static let activeHorizontalAccuracyLimit: Double = 50
    public static let activeDistanceFilterMeters: Double = 5
    public static let automaticEmissionThrottleInterval: TimeInterval = 1

    public static func allowsAutomaticTracking(
        interval: TimeInterval
    ) -> Bool {
        interval >= TimeInterval(GPSLoggingPreferences.intervalStepSeconds)
            && interval <= TimeInterval(GPSLoggingPreferences.Preset.balanced.intervalSeconds)
    }

    public static func allowsPersistingLocation(
        horizontalAccuracy: Double,
        batteryMinimal: Bool
    ) -> Bool {
        horizontalAccuracy >= 0
            && (
                batteryMinimal
                    || horizontalAccuracy <= activeHorizontalAccuracyLimit
            )
    }

    public static func isPreciseRouteReading(_ reading: SensorReading) -> Bool {
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

    public static func shouldPromoteBackgroundMovement(
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

    public static func shouldAutomaticallyStart(
        motion: MotionKind,
        confidence: ConfidenceLevel,
        sustainedFor duration: TimeInterval
    ) -> Bool {
        motion.isOnFoot
            && confidence != .low
            && duration >= automaticStartDuration
    }

    public static func shouldAutomaticallyStop(
        motion: MotionKind,
        stationaryFor duration: TimeInterval
    ) -> Bool {
        motion == .stationary
            && duration >= automaticStopStationaryDuration
    }
}

/// Combines overlapping measured intervals without changing the source records.
/// Automatic sensors can emit the same activity from more than one device.
public enum ActualIntervalMergeEngine {
    public static func union(
        _ spans: [TimeSpan],
        mergeGap: TimeInterval = 1
    ) -> [TimeSpan] {
        let ordered = spans
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        guard var current = ordered.first else { return [] }

        var merged: [TimeSpan] = []
        for span in ordered.dropFirst() {
            if span.start <= current.end.addingTimeInterval(max(0, mergeGap)) {
                current.end = max(current.end, span.end)
            } else {
                merged.append(current)
                current = span
            }
        }
        merged.append(current)
        return merged
    }

    public static func duration(
        of spans: [TimeSpan],
        mergeGap: TimeInterval = 1
    ) -> TimeInterval {
        union(spans, mergeGap: mergeGap).reduce(0) {
            $0 + $1.duration
        }
    }

    /// `span` 에서 `covered` 가 덮은 시간을 뺀 나머지 조각. 조각은 시작 시각
    /// 순이고 서로 겹치지 않는다. `covered` 는 정렬돼 있지 않아도 된다.
    public static func subtracting(
        _ covered: [TimeSpan],
        from span: TimeSpan
    ) -> [TimeSpan] {
        guard span.duration > 0 else { return [] }
        var remaining: [TimeSpan] = []
        var cursor = span.start
        for block in union(covered, mergeGap: 0)
        where block.end > span.start && block.start < span.end {
            if block.start > cursor {
                remaining.append(
                    TimeSpan(start: cursor, end: min(block.start, span.end))
                )
            }
            cursor = max(cursor, block.end)
            if cursor >= span.end { break }
        }
        if cursor < span.end {
            remaining.append(TimeSpan(start: cursor, end: span.end))
        }
        return remaining.filter { $0.duration > 0 }
    }
}
