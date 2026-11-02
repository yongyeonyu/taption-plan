import AVFoundation
import CoreLocation
import CoreMotion
import Foundation
import UIKit
import TaptionPlanCore

extension AppleSensorCollector {
    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard isCollecting else { return }
        let previousWakeLocation = lastBackgroundWakeLocation
        let isFirstLocationFix = latestLocation == nil
        let now = Date.now
        let validLocations = locations.filter {
            let age = now.timeIntervalSince($0.timestamp)
            return CLLocationCoordinate2DIsValid($0.coordinate)
                && $0.horizontalAccuracy.isFinite
                && $0.horizontalAccuracy >= 0
                && age >= -5
                && age < 5 * 60
        }.sorted { $0.timestamp < $1.timestamp }
        guard let newestLocation = validLocations.last else { return }
        // 휴대폰이 가속도·회전 센서로 확실히 멈춰 있으면 새 위치를 반영하지 않는다.
        if StationaryLocationGate.shouldIgnoreFixes(
            isTrulyStill: stillnessTracker.isTrulyStill(at: now),
            motionIsStationary: latestMotion == .stationary,
            hasPreviousLocation: latestLocation != nil,
            hasManualTrackingSession: activeTrackingSession?.wasAutomaticallyDetected == false,
            lastAcceptedAt: lastAcceptedLocationAt,
            now: now
        ) {
            gateIgnoredCount += 1
            flushLocationGateSummary(at: now)
            recordForegroundGPSFix(
                newestLocation,
                accepted: false,
                isFirstFix: isFirstLocationFix,
                batchCount: validLocations.count,
                at: now
            )
            return
        }
        gateAcceptedCount += 1
        flushLocationGateSummary(at: now)
        recordForegroundGPSFix(
            newestLocation,
            accepted: true,
            isFirstFix: isFirstLocationFix,
            batchCount: validLocations.count,
            at: now
        )
        lastAcceptedLocationAt = now
        latestLocation = newestLocation
        if let precise = validLocations.last(where: {
            $0.horizontalAccuracy
                <= TrackingSessionPolicy.activeHorizontalAccuracyLimit
        }) {
            latestPreciseLocation = precise
        }
        if let latestLocation {
            lastBackgroundWakeLocation = latestLocation
            promoteBackgroundMovementIfNeeded(
                latestLocation,
                previous: previousWakeLocation,
                batch: validLocations
            )
        }
        if isForegroundLiveLocationTrackingEnabled {
            guard ForegroundLiveLocationPolicy.isNewFix(
                newestLocation.timestamp,
                after: lastForegroundLocationTimestamp
            ),
            lastForegroundLocationEmissionAt.map({
                Date.now.timeIntervalSince($0)
                    >= ForegroundLiveLocationPolicy.minimumEmissionInterval
            }) ?? true else { return }
            emit(
                force: true,
                allowManualTrackingSample: true,
                foregroundLiveLocationUpdate: true
            )
            lastForegroundLocationTimestamp = newestLocation.timestamp
        } else if activeTrackingSession?.wasAutomaticallyDetected == true {
            emit(force: true)
        } else if activeTrackingSession?.wasAutomaticallyDetected == false,
                  trackingStreamsAreContinuous {
            emit(force: true, allowManualTrackingSample: true)
        } else if activeTrackingSession == nil,
                  latestLocation != nil {
            if configuration.minimumEmissionInterval <= 1 {
                emit()
            } else if isFirstLocationFix {
                emit(force: true)
            }
        }
    }

    /// 앱이 포그라운드일 때 받은 fix를 좌표 없이 남긴다. 1초에 한 번을 넘는 기록은
    /// 로거의 소음 게이트가 합치고 `suppressed_since_last`로 개수를 붙인다.
    private func recordForegroundGPSFix(
        _ location: CLLocation,
        accepted: Bool,
        isFirstFix: Bool,
        batchCount: Int,
        at now: Date
    ) {
        guard isForegroundLiveLocationTrackingEnabled else { return }
        let source = location.sourceInformation
        TaptionPlanDiagnosticsLogger.shared.record(
            GPSFixDiagnostics.eventName,
            fields: GPSFixDiagnostics.fields(
                accepted: accepted,
                reason: GPSFixDiagnostics.reason(
                    accepted: accepted,
                    hasPreviousLocation: !isFirstFix,
                    isTrulyStill: stillnessTracker.isTrulyStill(at: now),
                    motionIsStationary: latestMotion == .stationary
                ),
                source: GPSFixDiagnostics.source(
                    isSimulated: source?.isSimulatedBySoftware ?? false,
                    isFromAccessory: source?.isProducedByAccessory ?? false
                ),
                hasAltitude: location.verticalAccuracy >= 0
            ),
            metrics: GPSFixDiagnostics.metrics(
                horizontalAccuracy: location.horizontalAccuracy,
                speed: location.speed,
                course: location.course,
                batchCount: batchCount
            )
        )
    }

    /// 정지 판정이 위치를 얼마나 걸러냈는지 1분마다 요약해 남긴다(검증·분석용).
    private func flushLocationGateSummary(at now: Date) {
        guard let started = gateWindowStartedAt else {
            gateWindowStartedAt = now
            return
        }
        let window = now.timeIntervalSince(started)
        guard window >= 60, gateAcceptedCount + gateIgnoredCount > 0 else { return }
        TaptionPlanDiagnosticsLogger.shared.record(
            "location_gate_summary",
            metrics: [
                "accepted": Double(gateAcceptedCount),
                "ignored_still": Double(gateIgnoredCount),
                "window_s": window.rounded(),
                "still_s": stillnessTracker.stillDuration(at: now).rounded(),
            ]
        )
        gateAcceptedCount = 0
        gateIgnoredCount = 0
        gateWindowStartedAt = now
    }

    private func promoteBackgroundMovementIfNeeded(
        _ location: CLLocation,
        previous: CLLocation?,
        batch: [CLLocation]
    ) {
        guard isCollecting,
              configuration.allowsBackgroundLocation,
              TrackingSessionPolicy.allowsAutomaticTracking(
                interval: configuration.minimumEmissionInterval
              ),
              !sensorStreamsRunning,
              activeTrackingSession == nil,
              location.horizontalAccuracy
                <= TrackingSessionPolicy.activeHorizontalAccuracyLimit else {
            return
        }
        let previous = previous.flatMap {
            $0.horizontalAccuracy
                <= TrackingSessionPolicy.activeHorizontalAccuracyLimit
                ? $0
                : nil
        }
        let batchStart = batch.first {
            $0.horizontalAccuracy
                <= TrackingSessionPolicy.activeHorizontalAccuracyLimit
        }
        let distance = previous.map(location.distance)
            ?? batchStart.map(location.distance)
            ?? 0
        let elapsed = previous.map {
            location.timestamp.timeIntervalSince($0.timestamp)
        } ?? batchStart.map {
            location.timestamp.timeIntervalSince($0.timestamp)
        } ?? .greatestFiniteMagnitude
        let speed = location.speed.isFinite
            && location.speedAccuracy.isFinite
            && location.speedAccuracy >= 0 ? location.speed : -1
        guard TrackingSessionPolicy.shouldPromoteBackgroundMovement(
            speedMetersPerSecond: speed,
            displacementMeters: distance,
            elapsed: elapsed,
            horizontalAccuracy: location.horizontalAccuracy,
            speedAccuracy: location.speedAccuracy
        ) else {
            return
        }

        activeTrackingSession = TrackingSession(
            kind: .automatic,
            wasAutomaticallyDetected: true
        )
        trackingStreamsAreContinuous = true
        activeTrackingPreferences = GPSLoggingPreferences(
            intervalSeconds: max(1, Int(configuration.minimumEmissionInterval))
        )
        trackingSequence = 0
        startHardwareStreams()
        applyLocationPolicy(isMoving: true)

        backgroundWakeTask?.cancel()
        backgroundWakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self,
                  self.activeTrackingSession?.wasAutomaticallyDetected == true,
                  self.latestMotion == .stationary
                    || self.latestMotion == .unknown else { return }
            self.endTracking()
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didVisit visit: CLVisit
    ) {
        guard isCollecting,
              CLLocationCoordinate2DIsValid(visit.coordinate),
              visit.horizontalAccuracy.isFinite,
              visit.horizontalAccuracy >= 0 else { return }
        let date = visit.departureDate == .distantFuture
            ? visit.arrivalDate
            : visit.departureDate
        let location = CLLocation(
            coordinate: visit.coordinate,
            altitude: 0,
            horizontalAccuracy: visit.horizontalAccuracy,
            verticalAccuracy: -1,
            timestamp: date
        )
        latestLocation = location
        latestPreciseLocation = location.horizontalAccuracy
            <= TrackingSessionPolicy.activeHorizontalAccuracyLimit
            ? location
            : nil
        latestMotion = .stationary
        latestMotionConfidence = .high
        // 방문 이벤트는 백그라운드 웨이크업으로 드물게 도착하므로
        // 발행 간격 제한 없이 즉시 기록한다.
        if activeTrackingSession?.wasAutomaticallyDetected == true
            || activeTrackingSession == nil {
            emit(force: true)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if permissionState() == .authorized {
            isLocationDenied = false
            manager.allowsBackgroundLocationUpdates =
                configuration.allowsBackgroundLocation
                && manager.authorizationStatus == .authorizedAlways
            updateBackgroundWakeMonitoring()
            if sensorStreamsRunning {
                manager.startUpdatingLocation()
            } else {
                manager.stopUpdatingLocation()
                restartSamplingTask()
            }
        } else if permissionState() == .denied {
            isLocationDenied = true
            samplingTask?.cancel()
            samplingTask = nil
            stopHardwareStreams()
            if activeTrackingSession != nil {
                endTracking(includesFinalLocation: false)
            }
            updateBackgroundWakeMonitoring()
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        guard (error as? CLError)?.code == .denied else { return }
        // 스트림을 끝내면 권한을 다시 허용해도 수집이 재개되지 않는다.
        // 하드웨어만 멈추고 권한 변경 콜백에서 다시 시작한다.
        isLocationDenied = true
        samplingTask?.cancel()
        samplingTask = nil
        stopHardwareStreams()
        if activeTrackingSession != nil {
            endTracking(includesFinalLocation: false)
        }
        locationManager.stopMonitoringSignificantLocationChanges()
        locationManager.stopMonitoringVisits()
    }

    func emit(
        force: Bool = false,
        completedSession: TrackingSession? = nil,
        allowManualTrackingSample: Bool = false,
        foregroundLiveLocationUpdate: Bool = false
    ) {
        guard isCollecting, continuation != nil else { return }
        refreshConnectedWiFiIfNeeded()
        if activeTrackingSession?.wasAutomaticallyDetected == false,
           completedSession == nil,
           !allowManualTrackingSample {
            return
        }
        let now = Date.now
        if foregroundLiveLocationUpdate {
            if let lastForegroundLocationEmissionAt,
               now.timeIntervalSince(lastForegroundLocationEmissionAt)
                    < ForegroundLiveLocationPolicy.minimumEmissionInterval {
                return
            }
        } else {
            if force,
               completedSession == nil,
               activeTrackingSession?.wasAutomaticallyDetected == true,
               let lastEmissionAt,
               now.timeIntervalSince(lastEmissionAt)
                    < max(
                        TrackingSessionPolicy.automaticEmissionThrottleInterval,
                        activeEmissionInterval
                    ) {
                return
            }
            if !force,
               let lastEmissionAt,
               now.timeIntervalSince(lastEmissionAt)
                    < max(0.25, activeEmissionInterval) {
                return
            }
            if force,
               completedSession == nil,
               activeTrackingSession?.wasAutomaticallyDetected == false,
               let lastEmissionAt,
               now.timeIntervalSince(lastEmissionAt) < activeEmissionInterval {
                return
            }
        }
        let location = latestLocation
        if activeTrackingSession != nil,
           completedSession == nil,
           trackingStreamsAreContinuous {
            guard let location,
                  lastPersistedLocationTimestamp.map({
                      location.timestamp > $0
                  }) ?? true else {
                return
            }
        }
        lastEmissionAt = now
        if activeTrackingSession != nil,
           completedSession == nil {
            lastPersistedLocationTimestamp = location?.timestamp
        }
        let locationFixQuality = Self.locationFixQuality(
            for: location,
            hasFullAccuracyAuthorization:
                locationManager.accuracyAuthorization == .fullAccuracy
        )
        let capturedAt = location?.timestamp ?? now
        let point = location.map {
            GeoPoint(
                latitude: $0.coordinate.latitude,
                longitude: $0.coordinate.longitude,
                altitude: $0.altitude,
                horizontalAccuracy: $0.horizontalAccuracy,
                verticalAccuracy: $0.verticalAccuracy
            )
        }
        let session = completedSession ?? activeTrackingSession
        let screen = screenSnapshot()
        if session != nil { trackingSequence += 1 }
        continuation?.yield(
            SensorReading(
                timestamp: capturedAt,
                point: point,
                locationFixQuality: locationFixQuality,
                speedMetersPerSecond: location.flatMap { $0.speed >= 0 ? $0.speed : nil },
                speedAccuracyMetersPerSecond: location.flatMap {
                    $0.speedAccuracy >= 0 ? $0.speedAccuracy : nil
                },
                courseDegrees: location.flatMap { $0.course >= 0 ? $0.course : nil },
                courseAccuracyDegrees: location.flatMap {
                    $0.courseAccuracy >= 0 ? $0.courseAccuracy : nil
                },
                motion: latestMotion,
                motionConfidence: latestMotionConfidence,
                relativeAltitudeMeters: latestRelativeAltitude,
                pressureKilopascals: latestPressureKilopascals,
                altimeterSessionID: altimeterSessionID,
                floorsAscended: latestFloorsAscended,
                floorsDescended: latestFloorsDescended,
                stepCount: latestStepCount,
                walkingRunningDistanceMeters: latestWalkingRunningDistance,
                currentPaceSecondsPerMeter: latestCurrentPace,
                currentCadenceStepsPerSecond: latestCurrentCadence,
                averageActivePaceSecondsPerMeter: latestAverageActivePace,
                deviceMotion: latestDeviceMotion,
                deviceMotionSummary: deviceMotionAccumulator.summary,
                systemFloor: location?.floor?.level,
                powerState: Self.powerState(UIDevice.current.batteryState),
                screenBrightness: screen.brightness,
                screenIsOn: screen.isOn,
                gpsAvailable: locationFixQuality == .precise,
                connectedWiFiSSID: latestConnectedWiFiSSID,
                subwayWiFiObservationStreak: subwayWiFiObservationStreak,
                trackingSessionID: session?.id,
                trackingKind: session?.kind,
                trackingWasAutomaticallyDetected:
                    session?.wasAutomaticallyDetected,
                sourceDevice: .iPhone,
                sequence: session == nil ? nil : trackingSequence,
                trackingSessionEnded: completedSession != nil,
                carAudioRouteName: latestCarAudioRouteName
            )
        )
        if foregroundLiveLocationUpdate {
            lastForegroundLocationEmissionAt = now
        }
        deviceMotionAccumulator.reset()
    }

    private func screenSnapshot() -> PhoneScreenSnapshot {
        if UIApplication.shared.applicationState == .active {
            let snapshot = PhoneScreenSnapshot(
                brightness: Double(UIScreen.main.brightness),
                isOn: true
            )
            PhoneScreenActivityStore.update(
                brightness: snapshot.brightness,
                isOn: snapshot.isOn
            )
            return snapshot
        }
        return PhoneScreenActivityStore.snapshot()
    }

    private static func powerState(
        _ value: UIDevice.BatteryState
    ) -> DevicePowerState {
        switch value {
        case .unplugged: .unplugged
        case .charging: .charging
        case .full: .full
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }

    func updateAutomaticTracking(for motion: MotionKind) {
        guard sensorStreamsRunning else {
            cancelMovementCandidate()
            return
        }
        if let session = activeTrackingSession,
           session.wasAutomaticallyDetected {
            if motion == .stationary {
                guard stationaryStopTask == nil else { return }
                stationaryStopTask = Task { [weak self] in
                    try? await Task.sleep(
                        for: .seconds(
                            TrackingSessionPolicy.automaticStopStationaryDuration
                        )
                    )
                    guard !Task.isCancelled, let self,
                          self.latestMotion == .stationary,
                          self.activeTrackingSession?.wasAutomaticallyDetected == true else {
                        return
                    }
                    self.endTracking()
                }
            } else {
                stationaryStopTask?.cancel()
                stationaryStopTask = nil
            }
            return
        }

        // 차량·자전거 이동도 연속 추적으로 승격한다. 듀티사이클 표본만으로는
        // 경로가 출발·도착을 잇는 직선으로만 남는다.
        guard activeTrackingSession == nil,
              TrackingSessionPolicy.allowsAutomaticTracking(
                interval: configuration.minimumEmissionInterval
              ),
              motion == .walking
                || motion == .running
                || motion == .cycling
                || motion == .automotive,
              latestMotionConfidence != .low else {
            cancelMovementCandidate()
            return
        }
        if movementCandidateTask != nil {
            guard movementCandidateMotion != motion else { return }
            cancelMovementCandidate()
        }
        movementCandidateGeneration &+= 1
        let generation = movementCandidateGeneration
        movementCandidateMotion = motion
        movementCandidateTask = Task { [weak self] in
            defer {
                if let self,
                   self.movementCandidateGeneration == generation {
                    self.movementCandidateTask = nil
                    self.movementCandidateMotion = nil
                }
            }
            try? await Task.sleep(
                for: .seconds(TrackingSessionPolicy.automaticStartDuration)
            )
            guard !Task.isCancelled, let self,
                  self.movementCandidateGeneration == generation,
                  self.activeTrackingSession == nil,
                  self.sensorStreamsRunning,
                  self.latestMotion == motion,
                  self.latestMotionConfidence != .low else {
                return
            }
            let kind: TrackingKind = switch motion {
            case .running: .running
            case .walking: .walking
            default: .automatic
            }
            self.activeTrackingSession = TrackingSession(
                kind: kind,
                wasAutomaticallyDetected: true
            )
            self.trackingStreamsAreContinuous = true
            self.activeTrackingPreferences = GPSLoggingPreferences(
                intervalSeconds: max(
                    1,
                    Int(self.configuration.minimumEmissionInterval)
                )
            )
            self.trackingSequence = 0
            self.applyLocationPolicy(isMoving: true)
            self.emit(force: true)
        }
    }

    func cancelMovementCandidate() {
        movementCandidateGeneration &+= 1
        movementCandidateTask?.cancel()
        movementCandidateTask = nil
        movementCandidateMotion = nil
    }

    func apply(_ update: AltimeterSensorUpdate) {
        latestRelativeAltitude = update.relativeAltitudeMeters
        latestPressureKilopascals = update.pressureKilopascals
        altimeterSessionID = update.sessionID
        if altitudeBurstSamples != nil {
            altitudeBurstSamples?.append(
                AltitudeBurstSample(
                    relativeAltitudeMeters: update.relativeAltitudeMeters,
                    pressureKilopascals: update.pressureKilopascals,
                    altimeterSessionID: update.sessionID,
                    timestamp: .now
                )
            )
        }
        emit()
    }

    /// 층 보정은 한 표본이 아니라 짧은 묶음으로 잰다. 기압 갱신은 약 1초에
    /// 한 번 오므로 듀티사이클로 꺼져 있던 센서를 이 동안만 켜고, 끝나면
    /// 원래 주기로 돌려준다.
    func captureAltitudeBurst(
        count: Int,
        timeout: TimeInterval,
        onProgress: @MainActor (Int) -> Void = { _ in }
    ) async -> [AltitudeBurstSample] {
        guard CMAltimeter.isRelativeAltitudeAvailable(),
              altitudeBurstSamples == nil else {
            return []
        }
        let wasRunning = sensorStreamsRunning
        altitudeBurstSamples = []
        if !wasRunning { startHardwareStreams() }
        let deadline = Date.now.addingTimeInterval(timeout)
        var reported = 0
        while !Task.isCancelled, Date.now < deadline {
            let collected = altitudeBurstSamples?.count ?? 0
            if collected != reported {
                reported = collected
                onProgress(collected)
            }
            if collected >= count { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let samples = altitudeBurstSamples ?? []
        altitudeBurstSamples = nil
        if !wasRunning, activeTrackingSession == nil {
            stopHardwareStreams()
            clearSampleState()
        }
        return samples
    }

    func apply(_ update: PedometerSensorUpdate) {
        latestFloorsAscended = update.floorsAscended
        latestFloorsDescended = update.floorsDescended
        latestStepCount = update.stepCount
        latestWalkingRunningDistance =
            update.walkingRunningDistanceMeters
        latestCurrentPace = update.currentPaceSecondsPerMeter
        latestCurrentCadence = update.currentCadenceStepsPerSecond
        latestAverageActivePace = update.averageActivePaceSecondsPerMeter
        emit()
    }

    func applyLocationPolicy(isMoving: Bool) {
        if activeTrackingSession != nil {
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter =
                isForegroundLiveLocationTrackingEnabled
                    ? ForegroundLiveLocationPolicy.distanceFilterMeters
                    : TrackingSessionPolicy.activeDistanceFilterMeters
            locationManager.activityType = latestMotion == .automotive
                || (latestLocation?.speed ?? 0) >= 5
                ? .automotiveNavigation
                : .fitness
            locationManager.pausesLocationUpdatesAutomatically = false
            return
        }
        locationManager.activityType = .other
        if isForegroundLiveLocationTrackingEnabled {
            let policy = ForegroundLiveLocationPolicy.accuracy(
                stationary: ForegroundLiveLocationPolicy.isStationary(
                    motionIsStationary: latestMotion == .stationary,
                    speed: latestLocation.map { $0.speed >= 0 ? $0.speed : 0 }
                )
            )
            if locationManager.desiredAccuracy != policy.desired { locationManager.desiredAccuracy = policy.desired }
            if locationManager.distanceFilter != policy.distanceFilter { locationManager.distanceFilter = policy.distanceFilter }
            locationManager.pausesLocationUpdatesAutomatically = false
            return
        }
        switch configuration.profile {
        case .batterySaver:
            locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
            locationManager.distanceFilter = 500
        case .balanced:
            locationManager.desiredAccuracy = isMoving
                ? kCLLocationAccuracyBest
                : kCLLocationAccuracyHundredMeters
            locationManager.distanceFilter = isMoving ? 10 : 50
        case .accuracy:
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter = 5
        }
        locationManager.pausesLocationUpdatesAutomatically =
            configuration.minimumEmissionInterval > 1
                && configuration.profile != .accuracy
    }

    var activeEmissionInterval: TimeInterval {
        if activeTrackingSession != nil, trackingStreamsAreContinuous {
            return TrackingSessionPolicy.automaticEmissionThrottleInterval
        }
        return activeTrackingSession == nil
            ? configuration.minimumEmissionInterval
            : activeTrackingPreferences.interval
    }

    var shouldKeepHardwareStreamsActive: Bool {
        isForegroundLiveLocationTrackingEnabled
            || configuration.minimumEmissionInterval <= 1
            || (activeTrackingSession != nil && trackingStreamsAreContinuous)
    }

    private static func locationFixQuality(
        for location: CLLocation?,
        hasFullAccuracyAuthorization: Bool
    ) -> LocationFixQuality? {
        guard let location, location.horizontalAccuracy >= 0 else {
            return nil
        }
        guard hasFullAccuracyAuthorization else { return .approximate }
        return location.horizontalAccuracy
            <= TrackingSessionPolicy.activeHorizontalAccuracyLimit
            ? .precise
            : .approximate
    }

    nonisolated static func motionKind(_ activity: CMMotionActivity) -> MotionKind {
        MotionKindResolver.resolve(
            stationary: activity.stationary,
            walking: activity.walking,
            running: activity.running,
            cycling: activity.cycling,
            automotive: activity.automotive
        )
    }

    nonisolated static func confidence(
        _ confidence: CMMotionActivityConfidence
    ) -> ConfidenceLevel {
        switch confidence {
        case .high: .high
        case .medium: .medium
        case .low: .low
        @unknown default: .low
        }
    }
}
