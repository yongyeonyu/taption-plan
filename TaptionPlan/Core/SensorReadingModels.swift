import Foundation
import TaptionPlanCore

struct HealthActual: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: String
    var span: TimeSpan
    var duration: TimeInterval
    var distanceMeters: Double?
    var energyKilocalories: Double?
    var sourceName: String
    var linkedPlanID: UUID? = nil
    var linkedTitle: String? = nil
    var linkedCategoryID: String? = nil
}

// `GeoPoint`는 `TaptionPlanCore/Domain/GeoPoint.swift`에 있다.

enum DevicePowerState: String, Codable, Hashable, Sendable {
    case unknown
    case unplugged
    case charging
    case full

    var isCharging: Bool { self == .charging || self == .full }
}

enum LocationFixQuality: String, Codable, Hashable, Sendable {
    case precise
    case approximate
}

struct SensorReading: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var timestamp: Date
    var point: GeoPoint?
    /// `approximate` is a system-provided Wi-Fi/cellular/visit anchor. It is
    /// preserved for place context but excluded from precise route inference.
    var locationFixQuality: LocationFixQuality?
    var speedMetersPerSecond: Double?
    var speedAccuracyMetersPerSecond: Double?
    var courseDegrees: Double?
    var courseAccuracyDegrees: Double?
    var motion: MotionKind
    var motionConfidence: ConfidenceLevel
    var relativeAltitudeMeters: Double?
    var pressureKilopascals: Double?
    var altimeterSessionID: UUID?
    var floorsAscended: Int?
    var floorsDescended: Int?
    var stepCount: Int?
    var walkingRunningDistanceMeters: Double?
    var currentPaceSecondsPerMeter: Double?
    var currentCadenceStepsPerSecond: Double?
    var averageActivePaceSecondsPerMeter: Double?
    var deviceMotion: DeviceMotionSnapshot?
    var deviceMotionSummary: DeviceMotionSummary?
    var watchAccelerationAverageG: SensorVector3?
    var watchAccelerationStandardDeviationG: Double?
    var watchAccelerationMeanJerkGPerSecond: Double?
    var systemFloor: Int?
    var powerState: DevicePowerState?
    /// The last screen state observed by the app. iOS does not expose a
    /// background lux sensor, so brightness and screen state are persisted as
    /// the display-light proxy for sleep/wake inference.
    var screenBrightness: Double?
    var screenIsOn: Bool?
    var gpsAvailable: Bool
    /// The SSID returned by Apple's current-network API, when available.
    /// It is nil when Wi-Fi information access or location authorization is
    /// unavailable; no surrounding networks are scanned.
    var connectedWiFiSSID: String?
    /// Number of consecutive persisted observations whose current SSID is an
    /// allow-listed subway carrier network.
    var subwayWiFiObservationStreak: Int?
    var nearbyStation: Bool
    /// Apple 지도에서 확인한 가장 가까운 철도·버스 정류장 이름입니다.
    /// 원시 GPS와 함께 보관해 역과 역 사이 이동을 판정할 때 사용합니다.
    var nearbyStationName: String?
    var matchesRailRoute: Bool
    var matchesPublicTransitRoute: Bool
    var frequentStops: Bool
    var rideHailingHint: Bool
    var nearAirport: Bool
    var nearPort: Bool
    var onWater: Bool
    var watchWorkoutKind: String?
    /// Fine-grained behavior emitted by the Watch rule/model layer.  The
    /// coarse `motion` value is retained for existing travel inference.
    var behavior: String?
    var behaviorConfidenceScore: Double?
    var behaviorEvidence: [String]?
    var behaviorModelVersion: String?
    var trackingSessionID: UUID?
    var trackingKind: TrackingKind?
    var trackingWasAutomaticallyDetected: Bool?
    var sourceDevice: TrackingDevice?
    var sequence: Int?
    var trackingSessionEnded: Bool?
    /// 표본 시각에 연결돼 있던 차량 오디오(CarPlay·블루투스) 출력 이름. iOS가 보고한
    /// 그대로 보관하고, nil은 차량 경로 없음 또는 알 수 없음이다(CAR1029A01).
    var carAudioRouteName: String?

    init(
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
