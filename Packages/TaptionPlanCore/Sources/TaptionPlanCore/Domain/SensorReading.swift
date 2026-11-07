import Foundation

public enum DevicePowerState: String, Codable, Hashable, Sendable {
    case unknown
    case unplugged
    case charging
    case full

    public var isCharging: Bool { self == .charging || self == .full }
}

public enum LocationFixQuality: String, Codable, Hashable, Sendable {
    case precise
    case approximate
}

public struct SensorReading: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var point: GeoPoint?
    /// `approximate` is a system-provided Wi-Fi/cellular/visit anchor. It is
    /// preserved for place context but excluded from precise route inference.
    public var locationFixQuality: LocationFixQuality?
    public var speedMetersPerSecond: Double?
    public var speedAccuracyMetersPerSecond: Double?
    public var courseDegrees: Double?
    public var courseAccuracyDegrees: Double?
    public var motion: MotionKind
    public var motionConfidence: ConfidenceLevel
    public var relativeAltitudeMeters: Double?
    public var pressureKilopascals: Double?
    public var altimeterSessionID: UUID?
    public var floorsAscended: Int?
    public var floorsDescended: Int?
    public var stepCount: Int?
    public var walkingRunningDistanceMeters: Double?
    public var currentPaceSecondsPerMeter: Double?
    public var currentCadenceStepsPerSecond: Double?
    public var averageActivePaceSecondsPerMeter: Double?
    public var deviceMotion: DeviceMotionSnapshot?
    public var deviceMotionSummary: DeviceMotionSummary?
    public var watchAccelerationAverageG: SensorVector3?
    public var watchAccelerationStandardDeviationG: Double?
    public var watchAccelerationMeanJerkGPerSecond: Double?
    public var systemFloor: Int?
    public var powerState: DevicePowerState?
    /// The last screen state observed by the app. iOS does not expose a
    /// background lux sensor, so brightness and screen state are persisted as
    /// the display-light proxy for sleep/wake inference.
    public var screenBrightness: Double?
    public var screenIsOn: Bool?
    public var gpsAvailable: Bool
    /// The SSID returned by Apple's current-network API, when available.
    /// It is nil when Wi-Fi information access or location authorization is
    /// unavailable; no surrounding networks are scanned.
    public var connectedWiFiSSID: String?
    /// Number of consecutive persisted observations whose current SSID is an
    /// allow-listed subway carrier network.
    public var subwayWiFiObservationStreak: Int?
    public var nearbyStation: Bool
    /// Apple 지도에서 확인한 가장 가까운 철도·버스 정류장 이름입니다.
    /// 원시 GPS와 함께 보관해 역과 역 사이 이동을 판정할 때 사용합니다.
    public var nearbyStationName: String?
    public var matchesRailRoute: Bool
    public var matchesPublicTransitRoute: Bool
    public var frequentStops: Bool
    public var rideHailingHint: Bool
    public var nearAirport: Bool
    public var nearPort: Bool
    public var onWater: Bool
    public var watchWorkoutKind: String?
    /// Fine-grained behavior emitted by the Watch rule/model layer.  The
    /// coarse `motion` value is retained for existing travel inference.
    public var behavior: String?
    public var behaviorConfidenceScore: Double?
    public var behaviorEvidence: [String]?
    public var behaviorModelVersion: String?
    public var trackingSessionID: UUID?
    public var trackingKind: TrackingKind?
    public var trackingWasAutomaticallyDetected: Bool?
    public var sourceDevice: TrackingDevice?
    public var sequence: Int?
    public var trackingSessionEnded: Bool?
    /// 표본 시각에 연결돼 있던 차량 오디오(CarPlay·블루투스) 출력 이름. iOS가 보고한
    /// 그대로 보관하고, nil은 차량 경로 없음 또는 알 수 없음이다(CAR1029A01).
    public var carAudioRouteName: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        point: GeoPoint? = nil,
        locationFixQuality: LocationFixQuality? = nil,
        speedMetersPerSecond: Double? = nil,
        speedAccuracyMetersPerSecond: Double? = nil,
        courseDegrees: Double? = nil,
        courseAccuracyDegrees: Double? = nil,
        motion: MotionKind = .unknown,
        motionConfidence: ConfidenceLevel = .low,
        relativeAltitudeMeters: Double? = nil,
        pressureKilopascals: Double? = nil,
        altimeterSessionID: UUID? = nil,
        floorsAscended: Int? = nil,
        floorsDescended: Int? = nil,
        stepCount: Int? = nil,
        walkingRunningDistanceMeters: Double? = nil,
        currentPaceSecondsPerMeter: Double? = nil,
        currentCadenceStepsPerSecond: Double? = nil,
        averageActivePaceSecondsPerMeter: Double? = nil,
        deviceMotion: DeviceMotionSnapshot? = nil,
        deviceMotionSummary: DeviceMotionSummary? = nil,
        watchAccelerationAverageG: SensorVector3? = nil,
        watchAccelerationStandardDeviationG: Double? = nil,
        watchAccelerationMeanJerkGPerSecond: Double? = nil,
        systemFloor: Int? = nil,
        powerState: DevicePowerState? = nil,
        screenBrightness: Double? = nil,
        screenIsOn: Bool? = nil,
        gpsAvailable: Bool = true,
        connectedWiFiSSID: String? = nil,
        subwayWiFiObservationStreak: Int? = nil,
        nearbyStation: Bool = false,
        nearbyStationName: String? = nil,
        matchesRailRoute: Bool = false,
        matchesPublicTransitRoute: Bool = false,
        frequentStops: Bool = false,
        rideHailingHint: Bool = false,
        nearAirport: Bool = false,
        nearPort: Bool = false,
        onWater: Bool = false,
        watchWorkoutKind: String? = nil,
        behavior: String? = nil,
        behaviorConfidenceScore: Double? = nil,
        behaviorEvidence: [String]? = nil,
        behaviorModelVersion: String? = nil,
        trackingSessionID: UUID? = nil,
        trackingKind: TrackingKind? = nil,
        trackingWasAutomaticallyDetected: Bool? = nil,
        sourceDevice: TrackingDevice? = nil,
        sequence: Int? = nil,
        trackingSessionEnded: Bool? = nil,
        carAudioRouteName: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.point = point
        self.locationFixQuality = locationFixQuality
        self.speedMetersPerSecond = speedMetersPerSecond
        self.speedAccuracyMetersPerSecond = speedAccuracyMetersPerSecond
        self.courseDegrees = courseDegrees
        self.courseAccuracyDegrees = courseAccuracyDegrees
        self.motion = motion
        self.motionConfidence = motionConfidence
        self.relativeAltitudeMeters = relativeAltitudeMeters
        self.pressureKilopascals = pressureKilopascals
        self.altimeterSessionID = altimeterSessionID
        self.floorsAscended = floorsAscended
        self.floorsDescended = floorsDescended
        self.stepCount = stepCount
        self.walkingRunningDistanceMeters = walkingRunningDistanceMeters
        self.currentPaceSecondsPerMeter = currentPaceSecondsPerMeter
        self.currentCadenceStepsPerSecond = currentCadenceStepsPerSecond
        self.averageActivePaceSecondsPerMeter =
            averageActivePaceSecondsPerMeter
        self.deviceMotion = deviceMotion
        self.deviceMotionSummary = deviceMotionSummary
        self.watchAccelerationAverageG = watchAccelerationAverageG
        self.watchAccelerationStandardDeviationG =
            watchAccelerationStandardDeviationG
        self.watchAccelerationMeanJerkGPerSecond =
            watchAccelerationMeanJerkGPerSecond
        self.systemFloor = systemFloor
        self.powerState = powerState
        self.screenBrightness = screenBrightness.map { min(1, max(0, $0)) }
        self.screenIsOn = screenIsOn
        self.gpsAvailable = gpsAvailable
        self.connectedWiFiSSID = connectedWiFiSSID
        self.subwayWiFiObservationStreak = subwayWiFiObservationStreak.map {
            max(0, $0)
        }
        self.nearbyStation = nearbyStation
        self.nearbyStationName = nearbyStationName
        self.matchesRailRoute = matchesRailRoute
        self.matchesPublicTransitRoute = matchesPublicTransitRoute
        self.frequentStops = frequentStops
        self.rideHailingHint = rideHailingHint
        self.nearAirport = nearAirport
        self.nearPort = nearPort
        self.onWater = onWater
        self.watchWorkoutKind = watchWorkoutKind
        self.behavior = behavior
        self.behaviorConfidenceScore = behaviorConfidenceScore
        self.behaviorEvidence = behaviorEvidence
        self.behaviorModelVersion = behaviorModelVersion
        self.trackingSessionID = trackingSessionID
        self.trackingKind = trackingKind
        self.trackingWasAutomaticallyDetected =
            trackingWasAutomaticallyDetected
        self.sourceDevice = sourceDevice
        self.sequence = sequence
        self.trackingSessionEnded = trackingSessionEnded
        self.carAudioRouteName = carAudioRouteName
    }
}

public enum MotionKind: String, Codable, CaseIterable, Sendable {
    case stationary
    case walking
    case running
    case cycling
    case automotive
    case unknown

    public var activityTitle: String? {
        switch self {
        case .stationary: "정지·휴식"
        case .walking: "걷기"
        case .running: "달리기"
        case .cycling: "자전거"
        case .automotive: "자동차"
        case .unknown: nil
        }
    }

    public var isMovement: Bool {
        switch self {
        case .walking, .running, .cycling, .automotive:
            true
        case .stationary, .unknown:
            false
        }
    }

    /// 걷기·달리기. 걸음·층 이동 근거로 쓴다.
    public var isOnFoot: Bool { self == .walking || self == .running }
}

public enum TrackingKind: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case walking
    case running

    public var displayName: String {
        switch self {
        case .automatic: "자동 감지"
        case .walking: "걷기"
        case .running: "달리기"
        }
    }
}

public enum TrackingDevice: String, Codable, Hashable, Sendable {
    case iPhone
    case appleWatch
}

public struct SensorVector3: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    @inlinable
    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct DeviceMotionSnapshot: Codable, Hashable, Sendable {
    public var gravity: SensorVector3
    public var userAcceleration: SensorVector3
    public var rotationRate: SensorVector3
    public var attitudeRadians: SensorVector3
    public var magneticFieldMicroteslas: SensorVector3? = nil
    public var magneticFieldAccuracy: Int? = nil
    public var headingDegrees: Double? = nil

    public init(
        gravity: SensorVector3,
        userAcceleration: SensorVector3,
        rotationRate: SensorVector3,
        attitudeRadians: SensorVector3,
        magneticFieldMicroteslas: SensorVector3? = nil,
        magneticFieldAccuracy: Int? = nil,
        headingDegrees: Double? = nil
    ) {
        self.gravity = gravity
        self.userAcceleration = userAcceleration
        self.rotationRate = rotationRate
        self.attitudeRadians = attitudeRadians
        self.magneticFieldMicroteslas = magneticFieldMicroteslas
        self.magneticFieldAccuracy = magneticFieldAccuracy
        self.headingDegrees = headingDegrees
    }
}

/// A compact statistical window of the high-frequency motion stream.
/// The raw stream is too large to place on the timeline, so every persisted
/// sensor reading carries the features needed for movement classification.
public struct DeviceMotionSummary: Codable, Hashable, Sendable {
    public var sampleCount: Int
    public var meanUserAccelerationG: Double
    public var userAccelerationStandardDeviationG: Double
    public var peakUserAccelerationG: Double
    public var meanRotationRateRadiansPerSecond: Double
    public var rotationRateStandardDeviationRadiansPerSecond: Double
    public var peakRotationRateRadiansPerSecond: Double

    public init(
        sampleCount: Int,
        meanUserAccelerationG: Double,
        userAccelerationStandardDeviationG: Double,
        peakUserAccelerationG: Double,
        meanRotationRateRadiansPerSecond: Double,
        rotationRateStandardDeviationRadiansPerSecond: Double,
        peakRotationRateRadiansPerSecond: Double
    ) {
        self.sampleCount = sampleCount
        self.meanUserAccelerationG = meanUserAccelerationG
        self.userAccelerationStandardDeviationG = userAccelerationStandardDeviationG
        self.peakUserAccelerationG = peakUserAccelerationG
        self.meanRotationRateRadiansPerSecond = meanRotationRateRadiansPerSecond
        self.rotationRateStandardDeviationRadiansPerSecond = rotationRateStandardDeviationRadiansPerSecond
        self.peakRotationRateRadiansPerSecond = peakRotationRateRadiansPerSecond
    }
}
