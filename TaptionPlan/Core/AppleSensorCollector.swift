import AVFoundation
import CoreLocation
import CoreMotion
import Foundation
import UIKit
import TaptionPlanCore

// MARK: - Live sensor collection

struct AltimeterSensorUpdate: Sendable {
    var relativeAltitudeMeters: Double?
    var pressureKilopascals: Double?
    var sessionID: UUID
}

struct PedometerSensorUpdate: Sendable {
    var floorsAscended: Int?
    var floorsDescended: Int?
    var stepCount: Int?
    var walkingRunningDistanceMeters: Double?
    var currentPaceSecondsPerMeter: Double?
    var currentCadenceStepsPerSecond: Double?
    var averageActivePaceSecondsPerMeter: Double?
}

struct DeviceMotionAccumulator {
    private(set) var sampleCount = 0
    private var accelerationMean = 0.0
    private var accelerationM2 = 0.0
    private var accelerationPeak = 0.0
    private var rotationMean = 0.0
    private var rotationM2 = 0.0
    private var rotationPeak = 0.0

    mutating func append(_ snapshot: DeviceMotionSnapshot) {
        let acceleration = Self.magnitude(snapshot.userAcceleration)
        let rotation = Self.magnitude(snapshot.rotationRate)
        sampleCount += 1
        let count = Double(sampleCount)

        let accelerationDelta = acceleration - accelerationMean
        accelerationMean += accelerationDelta / count
        accelerationM2 += accelerationDelta * (acceleration - accelerationMean)
        accelerationPeak = max(accelerationPeak, acceleration)

        let rotationDelta = rotation - rotationMean
        rotationMean += rotationDelta / count
        rotationM2 += rotationDelta * (rotation - rotationMean)
        rotationPeak = max(rotationPeak, rotation)
    }

    var summary: DeviceMotionSummary? {
        guard sampleCount > 0 else { return nil }
        let divisor = Double(max(1, sampleCount - 1))
        return DeviceMotionSummary(
            sampleCount: sampleCount,
            meanUserAccelerationG: accelerationMean,
            userAccelerationStandardDeviationG:
                sqrt(max(0, accelerationM2 / divisor)),
            peakUserAccelerationG: accelerationPeak,
            meanRotationRateRadiansPerSecond: rotationMean,
            rotationRateStandardDeviationRadiansPerSecond:
                sqrt(max(0, rotationM2 / divisor)),
            peakRotationRateRadiansPerSecond: rotationPeak
        )
    }

    mutating func reset() {
        self = DeviceMotionAccumulator()
    }

    private static func magnitude(_ vector: SensorVector3) -> Double {
        sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
    }
}


@MainActor
final class AppleSensorCollector: NSObject, @preconcurrency CLLocationManagerDelegate {
    let locationManager = CLLocationManager()
    private let activityManager = CMMotionActivityManager()
    private let deviceMotionManager = CMMotionManager()
    private let altimeter = CMAltimeter()
    /// 모션·고도 갱신은 메인 큐 대신 이 직렬 큐에서 받고, 모션은 묶어서 메인으로 보낸다(PRF1101A01).
    private let sensorUpdateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "TaptionPlan.sensorUpdates"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private let pedometer = CMPedometer()

    var continuation: AsyncStream<SensorReading>.Continuation?
    private var readingStreamGeneration: UInt64 = 0
    var samplingTask: Task<Void, Never>?
    var movementCandidateTask: Task<Void, Never>?
    var movementCandidateMotion: MotionKind?
    var movementCandidateGeneration: UInt64 = 0
    var stationaryStopTask: Task<Void, Never>?
    var backgroundWakeTask: Task<Void, Never>?
    var configuration: SensorCollectionConfiguration = .standard
    var isCollecting = false
    var isLocationDenied = false
    var sensorStreamsRunning = false
    private var sensorStreamGeneration: UInt64 = 0
    var lastEmissionAt: Date?
    var lastPersistedLocationTimestamp: Date?
    var lastForegroundLocationTimestamp: Date?
    var lastForegroundLocationEmissionAt: Date?
    var latestLocation: CLLocation?
    var latestPreciseLocation: CLLocation?
    var lastBackgroundWakeLocation: CLLocation?
    var latestMotion: MotionKind = .unknown
    var latestMotionConfidence: ConfidenceLevel = .low
    var latestRelativeAltitude: Double?
    var latestPressureKilopascals: Double?
    var altimeterSessionID: UUID?
    var latestFloorsAscended: Int?
    var latestFloorsDescended: Int?
    var latestStepCount: Int?
    var latestWalkingRunningDistance: Double?
    var latestCurrentPace: Double?
    var latestCurrentCadence: Double?
    var latestAverageActivePace: Double?
    var latestDeviceMotion: DeviceMotionSnapshot?
    var latestConnectedWiFiSSID: String?
    var subwayWiFiObservationStreak = 0
    private var currentWiFiFetchInFlight = false
    private var lastWiFiFetchAt: Date?
    var deviceMotionAccumulator = DeviceMotionAccumulator()
    var stillnessTracker = DeviceStillnessTracker()
    var lastAcceptedLocationAt: Date?
    var gateAcceptedCount = 0
    var gateIgnoredCount = 0
    var gateWindowStartedAt: Date?
    var activeTrackingSession: TrackingSession?
    var activeTrackingPreferences = GPSLoggingPreferences.standard
    var trackingStreamsAreContinuous = false
    var isForegroundLiveLocationTrackingEnabled = false
    var trackingSequence = 0
    /// nil이 아니면 층 보정용 표본을 모으는 중이다.
    var altitudeBurstSamples: [AltitudeBurstSample]?
    /// 지금 연결된 차량 오디오(CarPlay·블루투스) 출력 이름. iOS 보고값 그대로(CAR1029A01).
    var latestCarAudioRouteName: String?
    private var audioRouteObserver: NSObjectProtocol?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.activityType = .other
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50
        locationManager.pausesLocationUpdatesAutomatically = true
        observeCarAudioRoute()
    }

    /// 차량 오디오 연결은 수집 중이 아니어도 수집기가 사는 동안 계속 지켜본다.
    private func observeCarAudioRoute() {
        refreshCarAudioRoute()
        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshCarAudioRoute() }
        }
    }

    private func refreshCarAudioRoute() {
        let output = AVAudioSession.sharedInstance().currentRoute.outputs.first {
            Self.isCarAudioPort($0.portType)
        }
        let name = output?.portName
        guard name != latestCarAudioRouteName else { return }
        latestCarAudioRouteName = name
        TaptionPlanDiagnosticsLogger.shared.record(
            "car_audio_route_changed",
            fields: [
                "connected": String(name != nil),
                "port_type": output?.portType.rawValue ?? "",
                "name": name ?? "",
            ]
        )
    }

    /// iOS는 클래식 블루투스를 직접 보여 주지 않아 오디오 출력 종류로 차량을 본다.
    private static func isCarAudioPort(_ port: AVAudioSession.Port) -> Bool {
        [.carAudio, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains(port)
    }

    func hardwareAvailability() async -> SensorHardwareAvailability {
        let locationServicesEnabled = await Task.detached(priority: .utility) {
            CLLocationManager.locationServicesEnabled()
        }.value
        return SensorHardwareAvailability(
            location: locationServicesEnabled,
            motionActivity: CMMotionActivityManager.isActivityAvailable(),
            deviceMotion: deviceMotionManager.isDeviceMotionAvailable,
            magnetometer: deviceMotionManager.isMagnetometerAvailable,
            relativeAltitude: CMAltimeter.isRelativeAltitudeAvailable(),
            stepCounting: CMPedometer.isStepCountingAvailable(),
            distance: CMPedometer.isDistanceAvailable(),
            floorCounting: CMPedometer.isFloorCountingAvailable(),
            pace: CMPedometer.isPaceAvailable(),
            cadence: CMPedometer.isCadenceAvailable()
        )
    }

    func permissionState() -> PermissionState {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .restricted, .denied:
            return .denied
        case .authorizedAlways, .authorizedWhenInUse:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func motionPermissionState() -> PermissionState {
        switch CMMotionActivityManager.authorizationStatus() {
        case .notDetermined:
            return .notDetermined
        case .restricted, .denied:
            return .denied
        case .authorized:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func hasAlwaysLocationAuthorization() -> Bool {
        locationManager.authorizationStatus == .authorizedAlways
    }

    func locationAuthorizationStatus() -> CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    func hasPreciseLocationAuthorization() -> Bool {
        locationManager.accuracyAuthorization == .fullAccuracy
    }

    func requestLocationPermission(always: Bool = false) {
        if always {
            locationManager.requestAlwaysAuthorization()
        } else {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func requestImmediateSample() {
        guard isCollecting,
              activeTrackingSession == nil,
              configuration.minimumEmissionInterval > 1 else { return }
        restartSamplingTask()
    }

    func setForegroundLiveLocationTrackingEnabled(_ enabled: Bool) {
        guard isForegroundLiveLocationTrackingEnabled != enabled else { return }
        isForegroundLiveLocationTrackingEnabled = enabled
        lastForegroundLocationTimestamp = nil
        lastForegroundLocationEmissionAt = nil
        TaptionPlanDiagnosticsLogger.shared.record(
            "foreground_live_location_tracking",
            fields: ["enabled": String(enabled)]
        )
        guard isCollecting else { return }
        applyLocationPolicy(isMoving: enabled || latestMotion != .stationary)
        if !enabled, !shouldKeepHardwareStreamsActive {
            stopHardwareStreams()
        }
        restartSamplingTask()
    }

    func readings(highAccuracyDuringMovement: Bool = true) -> AsyncStream<SensorReading> {
        var configuration = SensorCollectionConfiguration.standard
        configuration.highAccuracyDuringMovement = highAccuracyDuringMovement
        return readings(configuration: configuration)
    }

    func readings(
        configuration: SensorCollectionConfiguration
    ) -> AsyncStream<SensorReading> {
        let configuration = configuration.normalized
        readingStreamGeneration &+= 1
        let generation = readingStreamGeneration
        return AsyncStream { continuation in
            self.continuation = continuation
            self.configuration = configuration
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard self?.readingStreamGeneration == generation else {
                        return
                    }
                    self?.stop()
                }
            }
            start()
        }
    }

    func stop() {
        readingStreamGeneration &+= 1
        isForegroundLiveLocationTrackingEnabled = false
        samplingTask?.cancel()
        samplingTask = nil
        cancelMovementCandidate()
        stationaryStopTask?.cancel()
        stationaryStopTask = nil
        backgroundWakeTask?.cancel()
        backgroundWakeTask = nil
        stopHardwareStreams(forceLocationStop: true)
        locationManager.stopMonitoringVisits()
        locationManager.stopMonitoringSignificantLocationChanges()
        locationManager.allowsBackgroundLocationUpdates = false
        isCollecting = false
        isLocationDenied = false
        lastPersistedLocationTimestamp = nil
        lastForegroundLocationTimestamp = nil
        lastForegroundLocationEmissionAt = nil
        lastEmissionAt = nil
        latestLocation = nil
        latestPreciseLocation = nil
        latestRelativeAltitude = nil
        latestPressureKilopascals = nil
        altimeterSessionID = nil
        latestFloorsAscended = nil
        latestFloorsDescended = nil
        latestStepCount = nil
        latestWalkingRunningDistance = nil
        latestCurrentPace = nil
        latestCurrentCadence = nil
        latestAverageActivePace = nil
        latestDeviceMotion = nil
        latestConnectedWiFiSSID = nil
        subwayWiFiObservationStreak = 0
        currentWiFiFetchInFlight = false
        lastWiFiFetchAt = nil
        lastBackgroundWakeLocation = nil
        deviceMotionAccumulator.reset()
        stillnessTracker.reset()
        activeTrackingSession = nil
        activeTrackingPreferences = .standard
        trackingStreamsAreContinuous = false
        trackingSequence = 0
        continuation?.finish()
        continuation = nil
    }

    func beginTracking(
        kind: TrackingKind,
        linkedPlanID: UUID? = nil,
        sessionID: UUID = UUID(),
        preferences: GPSLoggingPreferences = .standard
    ) -> TrackingSession {
        let session = TrackingSession(
            id: sessionID,
            kind: kind,
            linkedPlanID: linkedPlanID,
            wasAutomaticallyDetected: false
        )
        activeTrackingSession = session
        activeTrackingPreferences = preferences
        trackingStreamsAreContinuous = true
        trackingSequence = 0
        lastEmissionAt = nil
        lastPersistedLocationTimestamp = nil
        cancelMovementCandidate()
        stationaryStopTask?.cancel()
        applyLocationPolicy(isMoving: true)
        if sensorStreamsRunning {
            stopHardwareStreams()
        }
        updateBackgroundWakeMonitoring()
        restartSamplingTask()
        return session
    }

    @discardableResult
    func resumeTracking(
        _ session: TrackingSession,
        preferences: GPSLoggingPreferences = .standard
    ) -> TrackingSession {
        activeTrackingSession = session
        activeTrackingPreferences = preferences
        trackingStreamsAreContinuous = true
        trackingSequence = 0
        lastEmissionAt = nil
        lastPersistedLocationTimestamp = nil
        cancelMovementCandidate()
        stationaryStopTask?.cancel()
        applyLocationPolicy(isMoving: true)
        if sensorStreamsRunning {
            stopHardwareStreams()
        }
        updateBackgroundWakeMonitoring()
        restartSamplingTask()
        return session
    }

    func updateTrackingPreferences(_ preferences: GPSLoggingPreferences) {
        guard activeTrackingSession != nil else { return }
        if activeTrackingSession?.wasAutomaticallyDetected == true,
           activeTrackingPreferences != preferences {
            endTracking()
            return
        }
        activeTrackingPreferences = preferences
        applyLocationPolicy(isMoving: true)
        if sensorStreamsRunning { stopHardwareStreams() }
        updateBackgroundWakeMonitoring()
        restartSamplingTask()
    }

    @discardableResult
    func endTracking(
        at date: Date = .now,
        includesFinalLocation: Bool = true
    ) -> TrackingSession? {
        guard var session = activeTrackingSession else { return nil }
        session.endedAt = date
        let preferences = activeTrackingPreferences
        activeTrackingSession = nil
        trackingStreamsAreContinuous = false
        stationaryStopTask?.cancel()
        stationaryStopTask = nil
        if !includesFinalLocation {
            latestLocation = nil
            latestPreciseLocation = nil
            emit(force: true, completedSession: session)
        } else if session.wasAutomaticallyDetected {
            emit(force: true, completedSession: session)
        } else if let location = preferredTrackingLocation(
            batteryMinimal: preferences.isBatteryMinimal
        ) {
            latestLocation = location
            emit(force: true, completedSession: session)
        }
        activeTrackingPreferences = .standard
        stopHardwareStreams()
        applyLocationPolicy(isMoving: latestMotion != .stationary)
        restartSamplingTask()
        return session
    }

    private func start() {
        guard !isCollecting else { return }
        isCollecting = true
        isLocationDenied = false
        applyLocationPolicy(isMoving: false)
        locationManager.allowsBackgroundLocationUpdates =
            configuration.allowsBackgroundLocation
            && locationManager.authorizationStatus == .authorizedAlways
        updateBackgroundWakeMonitoring()
        restartSamplingTask()
    }

    /// 듀티사이클 사이에 앱이 suspend되어도 위치 이벤트로 다시 깨어나
    /// 표본을 남길 수 있도록 저전력 모니터링을 켠다. 이것이 없으면
    /// 예약된 간격 기록이 포그라운드에서만 동작한다.
    func updateBackgroundWakeMonitoring() {
        guard isCollecting,
              configuration.allowsBackgroundLocation,
              locationManager.authorizationStatus == .authorizedAlways else {
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.stopMonitoringVisits()
            return
        }
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            locationManager.startMonitoringSignificantLocationChanges()
        }
        locationManager.startMonitoringVisits()
    }

    func restartSamplingTask() {
        samplingTask?.cancel()
        samplingTask = nil
        guard isCollecting,
              !isLocationDenied else {
            return
        }
        if shouldKeepHardwareStreamsActive {
            startHardwareStreams()
            return
        }
        samplingTask = Task { [weak self] in
            await self?.runSamplingLoop()
        }
    }

    private func runSamplingLoop() async {
        while !Task.isCancelled, isCollecting {
            let startedAt = Date.now
            await sampleOnce()
            guard !Task.isCancelled, isCollecting else { break }
            let interval = max(1, activeEmissionInterval)
            let nextStart = startedAt.addingTimeInterval(interval)
            let delay = max(0, nextStart.timeIntervalSinceNow)
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func sampleOnce() async {
        guard isCollecting else { return }
        let session = activeTrackingSession
        if session?.wasAutomaticallyDetected == false {
            // A cached location from the previous window must not win over a
            // fresh fix (or become a stale fallback) for this sample.
            clearSampleState()
        }

        startHardwareStreams()
        try? await Task.sleep(
            for: .seconds(configuration.profile.samplingWindowDuration)
        )
        guard !Task.isCancelled else { return }

        if let activeSession = activeTrackingSession,
           !activeSession.wasAutomaticallyDetected {
            if let location = preferredTrackingLocation(
                batteryMinimal: activeTrackingPreferences.isBatteryMinimal
            ) {
                latestLocation = location
                emit(force: true, allowManualTrackingSample: true)
            }
            stopHardwareStreams()
            clearSampleState()
            return
        }

        // A manual session may have ended while its sampling window was
        // asleep. Its final record was handled by endTracking; do not emit a
        // blank baseline record from this now-obsolete window.
        if session?.wasAutomaticallyDetected == false {
            stopHardwareStreams()
            clearSampleState()
            return
        }

        // Motion can promote this window to a tracking session. In that case
        // the streams stay on and the route continues without a duty-cycle
        // gap until the session ends.
        if let movementCandidateTask {
            await movementCandidateTask.value
            guard !Task.isCancelled else { return }
        }
        guard activeTrackingSession == nil else { return }
        emit(force: true)
        // 층 보정 표본을 모으는 중이면 이 창을 끄지 않는다. 끄면 사용자가
        // 기다리는 동안 표본이 끊긴다.
        guard altitudeBurstSamples == nil else { return }
        stopHardwareStreams()
        clearSampleState()
    }

    private func preferredTrackingLocation(
        batteryMinimal: Bool
    ) -> CLLocation? {
        let freshness = max(90, activeTrackingPreferences.interval * 1.5)
        let now = Date.now
        let candidates = [
            latestPreciseLocation,
            latestLocation,
            locationManager.location,
        ].compactMap { location -> CLLocation? in
            guard let location,
                  CLLocationCoordinate2DIsValid(location.coordinate),
                  location.horizontalAccuracy.isFinite,
                  location.horizontalAccuracy >= 0,
                  now.timeIntervalSince(location.timestamp) >= -5,
                  now.timeIntervalSince(location.timestamp) <= freshness,
                  TrackingSessionPolicy.allowsPersistingLocation(
                      horizontalAccuracy: location.horizontalAccuracy,
                      batteryMinimal: batteryMinimal
                  ) else {
                return nil
            }
            return location
        }
        guard !candidates.isEmpty else { return nil }
        if let precise = candidates.first(where: {
            $0.horizontalAccuracy
                <= TrackingSessionPolicy.activeHorizontalAccuracyLimit
        }) {
            return precise
        }
        return candidates.max(by: { $0.timestamp < $1.timestamp })
    }

    func startHardwareStreams() {
        guard !sensorStreamsRunning else { return }
        sensorStreamGeneration &+= 1
        let generation = sensorStreamGeneration
        sensorStreamsRunning = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshConnectedWiFiIfNeeded(force: true)
        locationManager.allowsBackgroundLocationUpdates =
            configuration.allowsBackgroundLocation
            && locationManager.authorizationStatus == .authorizedAlways
        locationManager.showsBackgroundLocationIndicator =
            locationManager.allowsBackgroundLocationUpdates
        applyLocationPolicy(
            isMoving: activeTrackingSession != nil
                || configuration.minimumEmissionInterval <= 1
        )
        if permissionState() == .authorized {
            locationManager.startUpdatingLocation()
        }

        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: .main) { [weak self] activity in
                guard let activity else { return }
                Task { @MainActor in
                    guard let self,
                          self.isCollecting,
                          self.sensorStreamsRunning,
                          self.sensorStreamGeneration == generation else {
                        return
                    }
                    self.latestMotion = Self.motionKind(activity)
                    self.latestMotionConfidence = Self.confidence(activity.confidence)
                    self.updateAutomaticTracking(for: self.latestMotion)
                    if self.configuration.highAccuracyDuringMovement
                        || self.isForegroundLiveLocationTrackingEnabled {
                        self.applyLocationPolicy(
                            isMoving: !activity.stationary
                        )
                    }
                    self.emit()
                }
            }
        }

        if configuration.collectsDeviceMotion,
           deviceMotionManager.isDeviceMotionAvailable {
            deviceMotionManager.deviceMotionUpdateInterval =
                configuration.profile == .accuracy ? 0.25 : 2
            let availableFrames =
                CMMotionManager.availableAttitudeReferenceFrames()
            let referenceFrame: CMAttitudeReferenceFrame =
                availableFrames.contains(.xArbitraryCorrectedZVertical)
                    ? .xArbitraryCorrectedZVertical
                    : .xArbitraryZVertical
            let batch = DeviceMotionBatch(flushInterval: DeviceMotionBatch.flushInterval)
            deviceMotionManager.startDeviceMotionUpdates(
                using: referenceFrame,
                to: sensorUpdateQueue
            ) { [weak self] motion, _ in
                guard let motion else { return }
                let snapshot = DeviceMotionSnapshot(
                    gravity: SensorVector3(
                        x: motion.gravity.x,
                        y: motion.gravity.y,
                        z: motion.gravity.z
                    ),
                    userAcceleration: SensorVector3(
                        x: motion.userAcceleration.x,
                        y: motion.userAcceleration.y,
                        z: motion.userAcceleration.z
                    ),
                    rotationRate: SensorVector3(
                        x: motion.rotationRate.x,
                        y: motion.rotationRate.y,
                        z: motion.rotationRate.z
                    ),
                    attitudeRadians: SensorVector3(
                        x: motion.attitude.roll,
                        y: motion.attitude.pitch,
                        z: motion.attitude.yaw
                    ),
                    magneticFieldMicroteslas: SensorVector3(
                        x: motion.magneticField.field.x,
                        y: motion.magneticField.field.y,
                        z: motion.magneticField.field.z
                    ),
                    magneticFieldAccuracy:
                        Int(motion.magneticField.accuracy.rawValue),
                    headingDegrees: motion.heading >= 0
                        ? motion.heading
                        : nil
                )
                // 이 큐 안에서만 쌓고, 1초마다(또는 처음 한 번) 묶음을 메인으로 넘긴다. 정확도 모드(4Hz)에서
                // 표본마다 메인 작업을 만들던 것을 줄인다. 시각은 받은 순간으로 남겨 정지 판정이 그대로다.
                guard let samples = batch.append(snapshot, at: Date.now) else { return }
                Task { @MainActor in
                    guard let self,
                          self.isCollecting,
                          self.sensorStreamsRunning,
                          self.sensorStreamGeneration == generation,
                          let last = samples.last else {
                        return
                    }
                    self.latestDeviceMotion = last.snapshot
                    for (snapshot, receivedAt) in samples {
                        self.deviceMotionAccumulator.append(snapshot)
                        self.stillnessTracker.append(
                            userAccelerationMagnitudeG: sqrt(
                                snapshot.userAcceleration.x * snapshot.userAcceleration.x
                                    + snapshot.userAcceleration.y * snapshot.userAcceleration.y
                                    + snapshot.userAcceleration.z * snapshot.userAcceleration.z
                            ),
                            rotationRateMagnitude: sqrt(
                                snapshot.rotationRate.x * snapshot.rotationRate.x
                                    + snapshot.rotationRate.y * snapshot.rotationRate.y
                                    + snapshot.rotationRate.z * snapshot.rotationRate.z
                            ),
                            at: receivedAt
                        )
                    }
                    self.emit()
                }
            }
        }

        if CMAltimeter.isRelativeAltitudeAvailable() {
            let sessionID = UUID()
            altimeterSessionID = sessionID
            altimeter.startRelativeAltitudeUpdates(to: sensorUpdateQueue) { [weak self] data, _ in
                let update = AltimeterSensorUpdate(
                    relativeAltitudeMeters:
                        data?.relativeAltitude.doubleValue,
                    pressureKilopascals: data?.pressure.doubleValue,
                    sessionID: sessionID
                )
                Task { @MainActor in
                    guard let self,
                          self.isCollecting,
                          self.sensorStreamsRunning,
                          self.sensorStreamGeneration == generation else {
                        return
                    }
                    self.apply(update)
                }
            }
        }

        if CMPedometer.isStepCountingAvailable() {
            let handler:
                @Sendable (CMPedometerData?, Error?) -> Void = {
                    [weak self] data, _ in
                    let update = PedometerSensorUpdate(
                        floorsAscended: data?.floorsAscended?.intValue,
                        floorsDescended: data?.floorsDescended?.intValue,
                        stepCount: data?.numberOfSteps.intValue,
                        walkingRunningDistanceMeters:
                            data?.distance?.doubleValue,
                        currentPaceSecondsPerMeter:
                            data?.currentPace?.doubleValue,
                        currentCadenceStepsPerSecond:
                            data?.currentCadence?.doubleValue,
                        averageActivePaceSecondsPerMeter:
                            data?.averageActivePace?.doubleValue
                    )
                    Task { @MainActor in
                        guard let self,
                              self.isCollecting,
                              self.sensorStreamsRunning,
                              self.sensorStreamGeneration == generation else {
                            return
                        }
                        self.apply(update)
                    }
                }
            pedometer.startUpdates(from: .now, withHandler: handler)
        }
    }

    func stopHardwareStreams(forceLocationStop: Bool = false) {
        sensorStreamGeneration &+= 1
        if forceLocationStop
            || !isCollecting
            || !isForegroundLiveLocationTrackingEnabled {
            locationManager.stopUpdatingLocation()
            locationManager.allowsBackgroundLocationUpdates = false
            locationManager.showsBackgroundLocationIndicator = false
        }
        activityManager.stopActivityUpdates()
        deviceMotionManager.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        pedometer.stopUpdates()
        UIDevice.current.isBatteryMonitoringEnabled = false
        sensorStreamsRunning = false
        currentWiFiFetchInFlight = false
        if activeTrackingSession == nil {
            cancelMovementCandidate()
        }
    }

    func clearSampleState() {
        latestLocation = nil
        latestPreciseLocation = nil
        latestMotion = .unknown
        latestMotionConfidence = .low
        latestRelativeAltitude = nil
        latestPressureKilopascals = nil
        altimeterSessionID = nil
        latestFloorsAscended = nil
        latestFloorsDescended = nil
        latestStepCount = nil
        latestWalkingRunningDistance = nil
        latestCurrentPace = nil
        latestCurrentCadence = nil
        latestAverageActivePace = nil
        latestDeviceMotion = nil
        deviceMotionAccumulator.reset()
        stillnessTracker.reset()
    }

    func refreshConnectedWiFiIfNeeded(force: Bool = false) {
        guard permissionState() == .authorized,
              !currentWiFiFetchInFlight else { return }
        if !force,
           let lastWiFiFetchAt,
           Date.now.timeIntervalSince(lastWiFiFetchAt) < 30 {
            return
        }
        let generation = sensorStreamGeneration
        currentWiFiFetchInFlight = true
        lastWiFiFetchAt = .now
        CurrentConnectedWiFiService.fetchSSID(
            authorizationStatus: locationManager.authorizationStatus
        ) { [weak self] ssid in
            Task { @MainActor in
                guard let self,
                      self.sensorStreamGeneration == generation else { return }
                self.currentWiFiFetchInFlight = false
                guard self.isCollecting,
                      self.sensorStreamsRunning else { return }
                self.latestConnectedWiFiSSID = ssid
                if SubwayWiFiSSID.isAllowed(ssid) {
                    self.subwayWiFiObservationStreak += 1
                } else {
                    self.subwayWiFiObservationStreak = 0
                }
            }
        }
    }
}
