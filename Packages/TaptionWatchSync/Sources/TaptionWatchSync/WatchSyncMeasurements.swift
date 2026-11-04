import Foundation
import TaptionPlanCore

// 워치 측정값·건강·수면·센서 요약과 알림 정책. (WatchSyncModels.swift에서 나눴다.)

/// 지금 무엇이 워치를 재고 있는지.
public enum TaptionWatchMeasurementSource: String, Codable, Hashable, Sendable {
    /// 명시적 운동 세션. 25Hz로 가속도·자이로·심박을 함께 받는다.
    case workout
    /// `CMSensorRecorder`가 앱과 무관하게 남기는 배경 가속도 기록.
    case ambient
    /// 자동 기록이 꺼져 있거나 아직 아무것도 재지 않는 상태.
    case idle

    public var title: String {
        switch self {
        case .workout: "운동 측정 중"
        case .ambient: "배경 기록 중"
        case .idle: "측정 대기"
        }
    }

    public func localizedTitle(
        _ language: AppLanguagePreference.ResolvedLanguage =
            AppLanguagePreference.current.resolvedLanguage
    ) -> String {
        switch (self, language) {
        case (.workout, .korean): "운동 측정 중"
        case (.ambient, .korean): "배경 기록 중"
        case (.idle, .korean): "측정 대기"
        case (.workout, .english): UITextPack.translate(english: "Workout measuring")
        case (.ambient, .english): UITextPack.translate(english: "Background recording")
        case (.idle, .english): UITextPack.translate(english: "Waiting to measure")
        }
    }
}

/// 워치 앱이 앱 그룹에 남기는 "지금 재고 있는 것" 스냅숏.
///
/// 워치 위젯은 별도 프로세스라 워치 앱의 관측 상태를 직접 볼 수 없다.
/// 위젯이 현재 측정을 보여주려면 이 스냅숏만 읽으면 된다.
public struct TaptionWatchMeasurementSnapshot: Codable, Hashable, Sendable {
    public var updatedAt: Date
    public var source: TaptionWatchMeasurementSource
    public var behavior: WatchBehaviorKind?
    public var confidenceScore: Double
    /// 마지막으로 분류된 구간의 끝. 위젯의 "n분 전"이 쓰는 값이다.
    public var measuredAt: Date?
    /// iPhone 설정이 자동 가속도 기록을 켜 두었는가.
    public var isRecordingRequested: Bool
    /// 이 워치에서 `CMSensorRecorder`를 실제로 쓸 수 있는가.
    public var isRecorderAvailable: Bool
    public var isMotionAccessDenied: Bool
    /// 기록 읽기가 예외로 끊긴 횟수(`ambient-drain-exception`).
    public var drainFailureCount: Int
    /// 운동·기록 실패 문구. 워치 화면과 위젯이 같은 문장을 쓴다.
    public var failureMessage: String?

    public init(
        updatedAt: Date = .now,
        source: TaptionWatchMeasurementSource = .idle,
        behavior: WatchBehaviorKind? = nil,
        confidenceScore: Double = 0,
        measuredAt: Date? = nil,
        isRecordingRequested: Bool = false,
        isRecorderAvailable: Bool = false,
        isMotionAccessDenied: Bool = false,
        drainFailureCount: Int = 0,
        failureMessage: String? = nil
    ) {
        self.updatedAt = updatedAt
        self.source = source
        self.behavior = behavior
        self.confidenceScore = min(1, max(0, confidenceScore))
        self.measuredAt = measuredAt
        self.isRecordingRequested = isRecordingRequested
        self.isRecorderAvailable = isRecorderAvailable
        self.isMotionAccessDenied = isMotionAccessDenied
        self.drainFailureCount = max(0, drainFailureCount)
        self.failureMessage = failureMessage
    }
}

public enum TaptionWatchAlertKind: String, Codable, Hashable, Sendable, CaseIterable {
    case recordingFailed
    case motionAccessDenied
    case recorderUnavailable
    case recordingGap
    case measurementStalled

    public var symbolName: String {
        switch self {
        case .recordingFailed: "exclamationmark.triangle.fill"
        case .motionAccessDenied: "hand.raised.fill"
        case .recorderUnavailable: "sensor.tag.radiowaves.forward.fill"
        case .recordingGap: "chart.line.downtrend.xyaxis"
        case .measurementStalled: "clock.badge.exclamationmark.fill"
        }
    }
}

public struct TaptionWatchAlert: Identifiable, Codable, Hashable, Sendable {
    public var kind: TaptionWatchAlertKind
    public var title: String
    public var detail: String

    public var id: String { kind.rawValue }
    public var symbolName: String { kind.symbolName }

    public init(
        kind: TaptionWatchAlertKind,
        title: String,
        detail: String
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

/// 워치가 사용자를 불러야 하는 상황만 고른다.
///
/// 새 알림 종류를 만들지 않는다. 이미 워치가 알고 있는 사실(기록 실패,
/// 권한, 읽기 예외, 마지막 측정 시각)만 문장으로 옮긴다. 알림 권한을
/// 새로 요구하지 않도록 결과는 화면과 위젯 안에서만 쓴다.
public enum TaptionWatchAlertPolicy {
    /// `CMSensorRecorder`는 앱이 꺼져 있어도 계속 기록하지만, 쌓인 표본은
    /// 워치 앱이 실행될 때만 비워진다. 이만큼 새 측정이 없으면 앱을 한 번
    /// 열어야 한다는 뜻이다.
    public static let stalledMeasurementInterval: TimeInterval = 6 * 3_600

    public static func alerts(
        for snapshot: TaptionWatchMeasurementSnapshot?,
        now: Date = .now,
        language: AppLanguagePreference.ResolvedLanguage =
            AppLanguagePreference.current.resolvedLanguage
    ) -> [TaptionWatchAlert] {
        // 워치 앱이 한 번도 실행되지 않았으면 상태를 단정할 근거가 없다.
        guard let snapshot else { return [] }
        var alerts: [TaptionWatchAlert] = []
        if let message = snapshot.failureMessage, !message.isEmpty {
            alerts.append(
                TaptionWatchAlert(
                    kind: .recordingFailed,
                    title: language == .korean
                        ? "기록이 멈췄어요"
                        : "Recording stopped",
                    detail: message
                )
            )
        }
        if snapshot.isMotionAccessDenied {
            alerts.append(
                TaptionWatchAlert(
                    kind: .motionAccessDenied,
                    title: language == .korean
                        ? "동작 권한 없음"
                        : "Motion access unavailable",
                    detail: language == .korean
                        ? "워치 설정에서 동작 및 피트니스를 켜 주세요"
                        : "Turn on Motion & Fitness in Watch settings"
                )
            )
        } else if snapshot.isRecordingRequested, !snapshot.isRecorderAvailable {
            alerts.append(
                TaptionWatchAlert(
                    kind: .recorderUnavailable,
                    title: language == .korean
                        ? "배경 기록 불가"
                        : "Background recording unavailable",
                    detail: language == .korean
                        ? "이 워치에서 가속도 기록을 쓸 수 없어요"
                        : "This Watch cannot record acceleration"
                )
            )
        }
        if snapshot.drainFailureCount > 0 {
            alerts.append(
                TaptionWatchAlert(
                    kind: .recordingGap,
                    title: language == .korean
                        ? "기록 일부 유실"
                        : "Recording gap",
                    detail: language == .korean
                        ? "읽지 못한 구간 \(snapshot.drainFailureCount)회"
                        : "\(snapshot.drainFailureCount) unread interval(s)"
                )
            )
        }
        if isMeasurementStalled(snapshot, now: now) {
            alerts.append(
                TaptionWatchAlert(
                    kind: .measurementStalled,
                    title: language == .korean
                        ? "새 측정 없음"
                        : "No new measurement",
                    detail: language == .korean
                        ? "워치 앱을 한 번 열면 밀린 기록을 가져와요"
                        : "Open the Watch app once to fetch pending records"
                )
            )
        }
        return alerts
    }

    public static func primary(
        for snapshot: TaptionWatchMeasurementSnapshot?,
        now: Date = .now,
        language: AppLanguagePreference.ResolvedLanguage =
            AppLanguagePreference.current.resolvedLanguage
    ) -> TaptionWatchAlert? {
        alerts(for: snapshot, now: now, language: language).first
    }

    private static func isMeasurementStalled(
        _ snapshot: TaptionWatchMeasurementSnapshot,
        now: Date
    ) -> Bool {
        guard snapshot.isRecordingRequested,
              snapshot.isRecorderAvailable,
              !snapshot.isMotionAccessDenied else {
            return false
        }
        // 운동 세션이 도는 동안에는 30초마다 새 요약이 나온다.
        guard snapshot.source != .workout else { return false }
        // 측정이 한 번도 없었던 기기는 "끊겼다"고 말할 근거가 없다.
        // 설치 직후를 경고로 만들지 않는다.
        guard let measuredAt = snapshot.measuredAt else { return false }
        return now.timeIntervalSince(measuredAt) >= stalledMeasurementInterval
    }
}

/// 워치 위젯 새로고침은 시스템 예산을 쓴다. 실제로 보이는 값이 바뀌었을
/// 때만 다시 그리고, 그렇지 않으면 최소 간격을 지킨다.
public enum TaptionWatchWidgetRefreshPolicy {
    public static let minimumInterval: TimeInterval = 5 * 60

    public static func shouldReload(
        previous: TaptionWatchMeasurementSnapshot?,
        next: TaptionWatchMeasurementSnapshot,
        lastReloadedAt: Date?,
        now: Date = .now
    ) -> Bool {
        guard let previous, let lastReloadedAt else { return true }
        guard displayIdentity(previous) == displayIdentity(next) else {
            return true
        }
        return now.timeIntervalSince(lastReloadedAt) >= minimumInterval
    }

    /// 위젯이 실제로 그리는 값만 모은다. 신뢰도는 10% 단위로 뭉쳐,
    /// 30초마다 도착하는 같은 분류가 새로고침을 태우지 않게 한다.
    public static func displayIdentity(
        _ snapshot: TaptionWatchMeasurementSnapshot
    ) -> String {
        let confidence = Int((snapshot.confidenceScore * 10).rounded())
        let alerts = TaptionWatchAlertPolicy
            .alerts(for: snapshot, now: snapshot.updatedAt)
            .map(\.kind.rawValue)
            .joined(separator: ",")
        return [
            snapshot.source.rawValue,
            snapshot.behavior?.rawValue ?? "none",
            String(confidence),
            alerts,
        ].joined(separator: "|")
    }
}

public struct TaptionWatchHealthSnapshot: Codable, Hashable, Sendable {
    public var capturedAt: Date
    public var dayStart: Date
    public var activeEnergyKilocalories: Double?
    public var exerciseMinutes: Double?
    public var standHours: Double?
    public var sleepMinutes: Double?
    public var sleepSegments: [TaptionWatchSleepSegment]? = nil
    public var workoutCount: Int
    public var source: String

    public init(
        capturedAt: Date,
        dayStart: Date,
        activeEnergyKilocalories: Double? = nil,
        exerciseMinutes: Double? = nil,
        standHours: Double? = nil,
        sleepMinutes: Double? = nil,
        sleepSegments: [TaptionWatchSleepSegment]? = nil,
        workoutCount: Int,
        source: String
    ) {
        self.capturedAt = capturedAt
        self.dayStart = dayStart
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.exerciseMinutes = exerciseMinutes
        self.standHours = standHours
        self.sleepMinutes = sleepMinutes
        self.sleepSegments = sleepSegments
        self.workoutCount = workoutCount
        self.source = source
    }
}

public struct TaptionWatchSleepSegment: Codable, Hashable, Sendable {
    public var id: UUID
    public var stage: String
    public var startDate: Date
    public var endDate: Date
    public var sourceName: String
    public var sourceBundleIdentifier: String
    public var deviceName: String?
    public var timeZoneIdentifier: String?
    public var isUserEntered: Bool

    public init(
        id: UUID,
        stage: String,
        startDate: Date,
        endDate: Date,
        sourceName: String,
        sourceBundleIdentifier: String,
        deviceName: String? = nil,
        timeZoneIdentifier: String? = nil,
        isUserEntered: Bool
    ) {
        self.id = id
        self.stage = stage
        self.startDate = startDate
        self.endDate = endDate
        self.sourceName = sourceName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.deviceName = deviceName
        self.timeZoneIdentifier = timeZoneIdentifier
        self.isUserEntered = isUserEntered
    }
}

public enum TaptionWatchSleepDuration {
    private static let asleepStages: Set<String> = [
        "core",
        "deep",
        "rem",
        "asleepUnspecified",
    ]

    public static func minutes(for segments: [TaptionWatchSleepSegment]) -> Double? {
        let asleep = segments
            .filter {
                asleepStages.contains($0.stage)
                    && $0.endDate > $0.startDate
            }
            .sorted {
                if $0.startDate != $1.startDate {
                    return $0.startDate < $1.startDate
                }
                return $0.endDate < $1.endDate
            }
        guard let first = asleep.first else { return nil }

        var start = first.startDate
        var end = first.endDate
        var seconds: TimeInterval = 0
        for segment in asleep.dropFirst() {
            if segment.startDate <= end {
                end = max(end, segment.endDate)
            } else {
                seconds += end.timeIntervalSince(start)
                start = segment.startDate
                end = segment.endDate
            }
        }
        seconds += end.timeIntervalSince(start)
        let minutes = seconds / 60
        return minutes > 0 ? minutes : nil
    }
}

public struct TaptionWatchSensorVector3: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public var magnitude: Double {
        sqrt(x * x + y * y + z * z)
    }

    public init(
        x: Double,
        y: Double,
        z: Double
    ) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct TaptionWatchLocationPoint: Codable, Hashable, Sendable {
    public var id: UUID
    public var capturedAt: Date
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double
    public var speedMetersPerSecond: Double?
    public var courseDegrees: Double?

    public func belongs(toWorkoutStartingAt startDate: Date) -> Bool {
        capturedAt >= startDate
    }

    public init(
        id: UUID,
        capturedAt: Date,
        latitude: Double,
        longitude: Double,
        altitude: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double,
        speedMetersPerSecond: Double? = nil,
        courseDegrees: Double? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speedMetersPerSecond = speedMetersPerSecond
        self.courseDegrees = courseDegrees
    }
}

/// A cumulative, battery-conscious summary of the sensors collected during an
/// explicit Apple Watch workout. The Watch samples motion locally and sends a
/// summary periodically instead of streaming every high-frequency event.
public struct TaptionWatchSensorSummary: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID { sessionID }
    public var sessionID: UUID
    public var sequence: Int
    public var workoutKind: TaptionWatchWorkoutKind
    public var linkedPlanID: UUID?
    public var linkedPlanTitle: String?
    public var linkedCategoryID: String?
    public var startedAt: Date
    public var endedAt: Date
    public var isFinal: Bool

    public var accelerometerSampleCount: Int
    public var accelerometerAverageG: TaptionWatchSensorVector3?
    public var peakAccelerationG: Double?
    /// Window statistics used to distinguish rail vibration from footsteps.
    /// Optional so summaries written by older builds remain readable.
    public var accelerometerStandardDeviationG: Double? = nil
    public var accelerometerMeanJerkGPerSecond: Double? = nil
    public var gyroscopeSampleCount: Int
    public var gyroscopeAverageRadiansPerSecond: TaptionWatchSensorVector3?
    public var peakRotationRateRadiansPerSecond: Double?
    public var gravity: TaptionWatchSensorVector3?
    public var userAccelerationG: TaptionWatchSensorVector3?
    public var rotationRateRadiansPerSecond: TaptionWatchSensorVector3?
    public var attitudeRadians: TaptionWatchSensorVector3?

    public var relativeAltitudeMeters: Double?
    public var pressureKilopascals: Double?
    public var stepCount: Int?
    public var distanceMeters: Double?
    public var floorsAscended: Int?
    public var floorsDescended: Int?

    public var latestHeartRate: Double?
    public var averageHeartRate: Double?
    public var maximumHeartRate: Double?
    public var activeEnergyKilocalories: Double?
    public var routePoints: [TaptionWatchLocationPoint]?
    /// Rule/Core ML output for this 30-second sensor chunk. Optional for
    /// backwards compatibility with summaries already queued on either side.
    public var behavior: WatchBehaviorKind? = nil
    public var behaviorConfidenceScore: Double? = nil
    public var behaviorEvidence: [String]? = nil
    public var behaviorModelVersion: String? = nil
    public var behaviorSegments: [WatchBehaviorSegment]? = nil
    /// Low-power accelerometer capture outside an explicit workout session.
    /// Optional so summaries queued by older Watch builds remain readable.
    public var isAmbient: Bool? = nil
    /// Stable 10-minute source window and its append-only summary revision.
    /// Nil remains valid for summaries created by older Watch builds.
    public var ambientWindowStart: Date? = nil
    public var ambientRevision: Int? = nil
    /// 직접적인 물방울 센서가 아니라 Watch의 Water Lock 상태다.
    /// 지원되는 수중 센서가 없는 기기에서도 샤워 후보의 보조 근거가 된다.
    public var waterLockEnabled: Bool? = nil

    public var rawEventID: String {
        let base = "\(sessionID.uuidString):\(sequence)"
        guard let ambientRevision, ambientRevision > 0 else { return base }
        return "\(base):r\(ambientRevision)"
    }

    public init(
        sessionID: UUID,
        sequence: Int,
        workoutKind: TaptionWatchWorkoutKind,
        linkedPlanID: UUID? = nil,
        linkedPlanTitle: String? = nil,
        linkedCategoryID: String? = nil,
        startedAt: Date,
        endedAt: Date,
        isFinal: Bool,
        accelerometerSampleCount: Int,
        accelerometerAverageG: TaptionWatchSensorVector3? = nil,
        peakAccelerationG: Double? = nil,
        accelerometerStandardDeviationG: Double? = nil,
        accelerometerMeanJerkGPerSecond: Double? = nil,
        gyroscopeSampleCount: Int,
        gyroscopeAverageRadiansPerSecond: TaptionWatchSensorVector3? = nil,
        peakRotationRateRadiansPerSecond: Double? = nil,
        gravity: TaptionWatchSensorVector3? = nil,
        userAccelerationG: TaptionWatchSensorVector3? = nil,
        rotationRateRadiansPerSecond: TaptionWatchSensorVector3? = nil,
        attitudeRadians: TaptionWatchSensorVector3? = nil,
        relativeAltitudeMeters: Double? = nil,
        pressureKilopascals: Double? = nil,
        stepCount: Int? = nil,
        distanceMeters: Double? = nil,
        floorsAscended: Int? = nil,
        floorsDescended: Int? = nil,
        latestHeartRate: Double? = nil,
        averageHeartRate: Double? = nil,
        maximumHeartRate: Double? = nil,
        activeEnergyKilocalories: Double? = nil,
        routePoints: [TaptionWatchLocationPoint]? = nil,
        behavior: WatchBehaviorKind? = nil,
        behaviorConfidenceScore: Double? = nil,
        behaviorEvidence: [String]? = nil,
        behaviorModelVersion: String? = nil,
        behaviorSegments: [WatchBehaviorSegment]? = nil,
        isAmbient: Bool? = nil,
        ambientWindowStart: Date? = nil,
        ambientRevision: Int? = nil,
        waterLockEnabled: Bool? = nil
    ) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.workoutKind = workoutKind
        self.linkedPlanID = linkedPlanID
        self.linkedPlanTitle = linkedPlanTitle
        self.linkedCategoryID = linkedCategoryID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.isFinal = isFinal
        self.accelerometerSampleCount = accelerometerSampleCount
        self.accelerometerAverageG = accelerometerAverageG
        self.peakAccelerationG = peakAccelerationG
        self.accelerometerStandardDeviationG = accelerometerStandardDeviationG
        self.accelerometerMeanJerkGPerSecond = accelerometerMeanJerkGPerSecond
        self.gyroscopeSampleCount = gyroscopeSampleCount
        self.gyroscopeAverageRadiansPerSecond = gyroscopeAverageRadiansPerSecond
        self.peakRotationRateRadiansPerSecond = peakRotationRateRadiansPerSecond
        self.gravity = gravity
        self.userAccelerationG = userAccelerationG
        self.rotationRateRadiansPerSecond = rotationRateRadiansPerSecond
        self.attitudeRadians = attitudeRadians
        self.relativeAltitudeMeters = relativeAltitudeMeters
        self.pressureKilopascals = pressureKilopascals
        self.stepCount = stepCount
        self.distanceMeters = distanceMeters
        self.floorsAscended = floorsAscended
        self.floorsDescended = floorsDescended
        self.latestHeartRate = latestHeartRate
        self.averageHeartRate = averageHeartRate
        self.maximumHeartRate = maximumHeartRate
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.routePoints = routePoints
        self.behavior = behavior
        self.behaviorConfidenceScore = behaviorConfidenceScore
        self.behaviorEvidence = behaviorEvidence
        self.behaviorModelVersion = behaviorModelVersion
        self.behaviorSegments = behaviorSegments
        self.isAmbient = isAmbient
        self.ambientWindowStart = ambientWindowStart
        self.ambientRevision = ambientRevision
        self.waterLockEnabled = waterLockEnabled
    }
}
