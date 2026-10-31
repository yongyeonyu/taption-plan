import Foundation
import TaptionPlanCore

extension AppModel {
    @discardableResult
    func enableLocationCollection(
        always: Bool = true,
        opensSettingsWhenBlocked: Bool = false
    ) async -> Bool {
        guard !isRequestingPermission else { return false }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        guard let sensorService else {
            snapshot.settings.permissions[.location] = .unavailable
            userFacingError = AppLanguagePreference.text(
                korean: sensorStorageErrorDescription == nil
                    ? "이 기기에서는 위치·동작 센서를 사용할 수 없습니다."
                    : "센서 저장소를 열지 못해 위치 기록을 시작할 수 없습니다. 진단 로그를 확인해주세요.",
                english: sensorStorageErrorDescription == nil
                    ? "Location and motion sensors are unavailable on this device."
                    : "The sensor archive could not be opened, so location recording cannot start. Check the diagnostics log."
            )
            return false
        }

        sensorAvailability = await sensorService.hardwareAvailability()
        var status = sensorService.locationAuthorizationStatus()
        let startedDenied = status == .denied || status == .restricted
        snapshot.settings.permissions[.location] =
            sensorService.locationPermissionState()
        snapshot.settings.permissions[.motion] = sensorService.motionPermissionState()

        if status == .notDetermined {
            sensorService.requestLocationPermission(always: false)
            for _ in 0..<120 where status == .notDetermined {
                guard !Task.isCancelled else { return false }
                try? await Task.sleep(for: .milliseconds(100))
                status = sensorService.locationAuthorizationStatus()
            }
        }
        if always, status == .authorizedWhenInUse {
            sensorService.requestLocationPermission(always: true)
            for _ in 0..<120 where status == .authorizedWhenInUse {
                guard !Task.isCancelled else { return false }
                try? await Task.sleep(for: .milliseconds(100))
                status = sensorService.locationAuthorizationStatus()
            }
        }

        let refreshed = sensorService.locationPermissionState()
        snapshot.settings.permissions[.location] = refreshed
        snapshot.settings.permissions[.motion] = sensorService.motionPermissionState()
        snapshot.settings.locationEnabled = refreshed.isGranted
        let allowsBackgroundLocation =
            BackgroundLocationCollectionPolicy.isEnabled(
                hasAlwaysAuthorization:
                    sensorService.hasAlwaysLocationAuthorization()
            )
        snapshot.settings.backgroundPreciseLocationEnabled =
            allowsBackgroundLocation
        updateForegroundLiveLocationTracking()

        if refreshed.isGranted {
            sensorService.startCollection(configuration: sensorCollectionConfiguration(
                profile: settings.sensorCollectionProfile,
                allowsBackgroundLocation: allowsBackgroundLocation
            ))
            isSensorCollecting = true
            receiveSensorWake(.foregroundResume)
            reconcileBackgroundSensorSession()
        }
        // 사용자가 권한 항목을 직접 눌렀는데 시스템 팝업이 더 뜰 수 없는 상태(거부됨·'항상' 승격 팝업을 이미 봄)면
        // 앱 설정으로 바로 보낸다. 시작·자동 수집 경로에서는 설정을 열지 않는다.
        if opensSettingsWhenBlocked,
           startedDenied || (always && !sensorService.hasAlwaysLocationAuthorization()) {
            openSystemSettings()
        }
        publishWatchPayload()
        await persist()
        return true
    }

    @discardableResult
    func requestMapCurrentLocation(
        requiresFreshReading: Bool = false
    ) async -> Bool {
        guard let sensorService else {
            snapshot.settings.permissions[.location] = .unavailable
            userFacingError = AppLanguagePreference.text(
                korean: sensorStorageErrorDescription == nil
                    ? "이 기기에서는 현재 위치를 확인할 수 없습니다."
                    : "센서 저장소를 열지 못해 현재 위치를 기록할 수 없습니다.",
                english: sensorStorageErrorDescription == nil
                    ? "Current location is unavailable on this device."
                    : "The sensor archive could not be opened."
            )
            return false
        }

        var state = sensorService.locationPermissionState()
        if state == .notDetermined {
            sensorService.requestLocationPermission(always: false)
            for _ in 0..<120 where state == .notDetermined {
                guard !Task.isCancelled else { return false }
                try? await Task.sleep(for: .milliseconds(100))
                state = sensorService.locationPermissionState()
            }
        }
        snapshot.settings.permissions[.location] = state
        guard state.isGranted else {
            presentPermissionOnboarding(for: .location)
            return false
        }

        let persistenceToken = sensorService.persistenceToken()
        let mapConfiguration = sensorCollectionConfiguration(
            profile: settings.sensorCollectionProfile,
            allowsBackgroundLocation: settings.backgroundPreciseLocationEnabled,
            minimumEmissionInterval: requiresFreshReading ? 1 : nil
        )
        if settings.locationEnabled {
            sensorService.startCollection(configuration: mapConfiguration)
            isSensorCollecting = true
            receiveSensorWake(.foregroundResume)
            reconcileBackgroundSensorSession()
        } else {
            await enableLocationCollection(always: false)
            if requiresFreshReading, settings.locationEnabled {
                sensorService.startCollection(configuration: mapConfiguration)
                isSensorCollecting = true
            }
        }
        let cachedAnchor = MapCurrentLocationAnchorPolicy.latestValidReading(
            in: [latestSensorReading, liveRouteState.readings.last]
                .compactMap { $0 }
        )
        if cachedAnchor == nil {
            await hydrateLatestMapLocationAnchor()
        }
        let hasAnchor = MapCurrentLocationAnchorPolicy.latestValidReading(
            in: [latestSensorReading, liveRouteState.readings.last]
                .compactMap { $0 }
        ) != nil
        var receivedFreshReading = false
        if requiresFreshReading || !hasAnchor {
            receivedFreshReading = await sensorService.waitForPersistedReading(
                after: persistenceToken,
                timeout: Self.mapLocationReadingTimeout
            )
            await hydrateLatestMapLocationAnchor()
        }
        if requiresFreshReading {
            sensorService.startCollection(configuration: sensorCollectionConfiguration(
                profile: settings.sensorCollectionProfile,
                allowsBackgroundLocation:
                    settings.backgroundPreciseLocationEnabled
            ))
        }
        let currentAnchor = MapCurrentLocationAnchorPolicy.latestValidReading(
            in: [latestSensorReading, liveRouteState.readings.last]
                .compactMap { $0 }
        )
        return currentAnchor != nil
            && (!requiresFreshReading
                || receivedFreshReading && currentAnchor?.id != cachedAnchor?.id)
    }

    func disableLocationCollection() async {
        await sensorService?.stopCollectionAndWait()
        sensorBackgroundCoordinator.cancel()
        syncSensorBackgroundState()
        isSensorCollecting = false
        snapshot.settings.locationEnabled = false
        snapshot.settings.backgroundPreciseLocationEnabled = false
        updateForegroundLiveLocationTracking()
        publishWatchPayload()
        await persist()
    }

    func setSensorCollectionProfile(
        _ profile: SensorCollectionProfile
    ) {
        let intervalSeconds = Int(profile.interval)
        let batteryMinimal = profile == .batterySaver
        guard snapshot.settings.sensorCollectionProfile != profile
                || snapshot.settings.gpsLoggingPreferences.intervalSeconds != intervalSeconds
                || snapshot.settings.gpsLoggingPreferences.isBatteryMinimal != batteryMinimal else {
            return
        }
        snapshot.settings.sensorCollectionProfile = profile
        snapshot.settings.gpsLoggingPreferences.intervalSeconds = intervalSeconds
        snapshot.settings.gpsLoggingPreferences.isBatteryMinimal = batteryMinimal
        if settings.locationEnabled,
           permissionState(for: .location).isGranted,
           let sensorService {
            sensorService.startCollection(configuration: sensorCollectionConfiguration(
                profile: profile,
                allowsBackgroundLocation:
                    settings.backgroundPreciseLocationEnabled
            ))
            isSensorCollecting = true
            reconcileBackgroundSensorSession()
        }
        Task { await persist() }
    }

    func setGPSLoggingBatteryMinimal(_ enabled: Bool) {
        guard snapshot.settings.gpsLoggingPreferences.isBatteryMinimal != enabled else {
            return
        }
        snapshot.settings.gpsLoggingPreferences.isBatteryMinimal = enabled
        if enabled {
            snapshot.settings.sensorCollectionProfile = .batterySaver
            snapshot.settings.gpsLoggingPreferences.intervalSeconds =
                GPSLoggingPreferences.batteryMinimalIntervalSeconds
        } else {
            let interval = snapshot.settings.gpsLoggingPreferences.intervalSeconds
            if interval >= GPSLoggingPreferences.batteryMinimalIntervalSeconds {
                snapshot.settings.sensorCollectionProfile = .balanced
                snapshot.settings.gpsLoggingPreferences.intervalSeconds =
                    GPSLoggingPreferences.Preset.balanced.intervalSeconds
            } else {
                snapshot.settings.sensorCollectionProfile = sensorCollectionProfile(
                    for: interval
                )
            }
        }
        refreshActiveGPSLoggingPreferences()
        Task { await persist() }
    }

    /// 센싱 주기를 1~15분 중에서 고른다(모드 없이 분 단위로 바로 설정).
    func setSensorIntervalMinutes(_ minutes: Int) {
        let clamped = min(max(minutes, 1), 15)
        let seconds = clamped * 60
        guard snapshot.settings.gpsLoggingPreferences.intervalSeconds != seconds
                || snapshot.settings.gpsLoggingPreferences.isBatteryMinimal else {
            return
        }
        snapshot.settings.gpsLoggingPreferences.intervalSeconds = seconds
        snapshot.settings.gpsLoggingPreferences.isBatteryMinimal = false
        snapshot.settings.sensorCollectionProfile = sensorCollectionProfile(for: seconds)
        refreshActiveGPSLoggingPreferences()
        Task { await persist() }
    }

    func setGPSLoggingIntervalSeconds(_ seconds: Int) {
        let clamped = GPSLoggingPreferences.clampedSeconds(seconds)
        guard snapshot.settings.gpsLoggingPreferences.intervalSeconds != clamped
                || snapshot.settings.gpsLoggingPreferences.isBatteryMinimal else {
            return
        }
        snapshot.settings.gpsLoggingPreferences.intervalSeconds = clamped
        snapshot.settings.gpsLoggingPreferences.isBatteryMinimal =
            clamped == GPSLoggingPreferences.batteryMinimalIntervalSeconds
        snapshot.settings.sensorCollectionProfile = sensorCollectionProfile(
            for: clamped
        )
        refreshActiveGPSLoggingPreferences()
        Task { await persist() }
    }

    func setGPSLoggingPreset(_ preset: GPSLoggingPreferences.Preset) {
        let profile: SensorCollectionProfile
        switch preset {
        case .batterySaver: profile = .batterySaver
        case .balanced: profile = .balanced
        case .realtime: profile = .accuracy
        }
        setSensorCollectionProfile(profile)
    }

    func sensorCollectionProfile(for intervalSeconds: Int) -> SensorCollectionProfile {
        switch intervalSeconds {
        case 900...: .batterySaver
        case 120...600: .balanced
        default: .accuracy
        }
    }

    @available(*, deprecated, message: "Use setGPSLoggingIntervalSeconds")
    func setGPSLoggingIntervalMinutes(_ minutes: Int) {
        setGPSLoggingIntervalSeconds(minutes * 60)
    }

    private func refreshActiveGPSLoggingPreferences() {
        if activeTrackingSession != nil {
            sensorService?.updateTrackingPreferences(
                settings.gpsLoggingPreferences
            )
            return
        }
        guard settings.locationEnabled,
              permissionState(for: .location).isGranted,
              let sensorService else { return }
        sensorService.startCollection(
            configuration: sensorCollectionConfiguration(
                profile: settings.sensorCollectionProfile,
                allowsBackgroundLocation:
                    settings.backgroundPreciseLocationEnabled,
                minimumEmissionInterval:
                    settings.gpsLoggingPreferences.interval
            )
        )
        isSensorCollecting = true
        reconcileBackgroundSensorSession()
    }

    private func sensorCollectionConfiguration(
        profile: SensorCollectionProfile,
        allowsBackgroundLocation: Bool,
        minimumEmissionInterval: TimeInterval? = nil
    ) -> SensorCollectionConfiguration {
        var configuration = SensorCollectionConfiguration.configured(
            for: profile,
            allowsBackgroundLocation: allowsBackgroundLocation
        )
        if let minimumEmissionInterval {
            configuration.minimumEmissionInterval = minimumEmissionInterval
        } else {
            configuration.minimumEmissionInterval =
                settings.gpsLoggingPreferences.interval
        }
        return configuration
    }

    func receiveSensorWake(_ reason: SensorWakeReason) {
        let accepted = sensorBackgroundCoordinator.receiveWake(reason)
        syncSensorBackgroundState()
        Self.integrationLogger.notice(
            "Sensor wake: reason=\(reason.rawValue, privacy: .public), accepted=\(accepted, privacy: .public), token=\(self.sensorSaveToken, privacy: .public)"
        )
        if accepted {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_background_wake",
                fields: [
                    "reason": reason.rawValue,
                    "save_token": String(sensorSaveToken),
                ]
            )
        }
    }

    func syncSensorBackgroundState() {
        let previousState = sensorCollectionSessionState
        if sensorCollectionSessionState != sensorBackgroundCoordinator.sessionState {
            sensorCollectionSessionState = sensorBackgroundCoordinator.sessionState
        }
        if sensorCollectionSessionID != sensorBackgroundCoordinator.sessionID {
            sensorCollectionSessionID = sensorBackgroundCoordinator.sessionID
        }
        if sensorCollectionStartedAt != sensorBackgroundCoordinator.sessionStartedAt {
            sensorCollectionStartedAt = sensorBackgroundCoordinator.sessionStartedAt
        }
        if lastSensorWakeReason != sensorBackgroundCoordinator.lastWakeReason {
            lastSensorWakeReason = sensorBackgroundCoordinator.lastWakeReason
        }
        if lastSensorSavedAt != sensorBackgroundCoordinator.lastSavedAt {
            lastSensorSavedAt = sensorBackgroundCoordinator.lastSavedAt
        }
        if sensorSaveToken != sensorBackgroundCoordinator.saveToken {
            sensorSaveToken = sensorBackgroundCoordinator.saveToken
        }
        if previousState != sensorCollectionSessionState {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_collection_state",
                fields: [
                    "state": sensorCollectionSessionState.rawValue,
                    "save_token": String(sensorSaveToken),
                    "saved_at": lastSensorSavedAt.map {
                        String($0.timeIntervalSince1970)
                    } ?? "none",
                ]
            )
        }
    }

    func startTracking(_ kind: TrackingKind) async {
        guard kind != .automatic else { return }
        if !settings.locationEnabled
            || !permissionState(for: .location).isGranted {
            await enableLocationCollection(always: true)
        }
        guard let sensorService,
              permissionState(for: .location).isGranted else {
            userFacingError = AppLanguagePreference.text(
                korean: "위치 권한을 허용해야 걷기·달리기 경로를 기록할 수 있습니다.",
                english: "Allow location access to record walking and running routes."
            )
            return
        }
        if activeTrackingSession != nil {
            await stopTracking()
        }
        // Exercise records remain unlinked until the user taps an item in the
        // detail panel. Time/category overlap is not an implicit relationship.
        let linkedPlanID: UUID? = nil
        let session = sensorService.beginTracking(
            kind: kind,
            linkedPlanID: linkedPlanID,
            preferences: settings.gpsLoggingPreferences
        )
        activeTrackingSession = session
        TaptionPlanDiagnosticsLogger.shared.record(
            "tracking_started",
            fields: ["kind": kind.rawValue]
        )
        trackingSessionWasRecovered = false
        TrackingSessionRecoveryStore.save(session)
        lastTrackingSessionRecoveryPersistAt = .now
        liveRouteState = LiveRouteState(
            session: session,
            readings: [],
            lastUpdatedAt: .now
        )

    }

    func stopTracking() async {
        guard let completed = sensorService?.endTracking()
            ?? activeTrackingSession.map({ session in
                var value = session
                value.endedAt = .now
                return value
            }) else {
            return
        }
        finalizeTrackingSession(completed)
        TaptionPlanDiagnosticsLogger.shared.record(
            "tracking_stopped",
            fields: [
                "kind": completed.kind.rawValue,
                "duration_seconds": String(
                    Int((completed.endedAt ?? .now).timeIntervalSince(
                        completed.startedAt
                    ))
                ),
            ]
        )
        TrackingSessionRecoveryStore.clear()
        lastTrackingSessionRecoveryPersistAt = nil
        activeTrackingSession = nil
        trackingSessionWasRecovered = false
        liveRouteState.session = nil
        scheduleSensorAnalysis(
            containing: completed.startedAt,
            immediately: true
        )
        if let endedAt = completed.endedAt,
           !Calendar.autoupdatingCurrent.isDate(
               completed.startedAt,
               inSameDayAs: endedAt
           ) {
            scheduleSensorAnalysis(containing: endedAt, immediately: true)
        }
    }

    func liveSensorReadings(in span: TimeSpan) -> [SensorReading] {
        liveRouteState.readings.filter { span.contains($0.timestamp) }
    }

    func mergingLiveSensorReadings(
        _ archived: [SensorReading],
        in span: TimeSpan
    ) -> [SensorReading] {
        let cacheKey = LiveMergeCacheKey(
            spanStart: span.start.timeIntervalSinceReferenceDate,
            spanEnd: span.end.timeIntervalSinceReferenceDate,
            archivedCount: archived.count,
            archivedFirstID: archived.first?.id,
            archivedLastID: archived.last?.id,
            archivedFirstTimestamp: archived.first?.timestamp,
            archivedLastTimestamp: archived.last?.timestamp,
            liveCount: liveRouteState.readings.count,
            liveLastUpdatedAt: liveRouteState.lastUpdatedAt
        )
        if liveMergeCacheKey == cacheKey {
            return liveMergeCacheValue
        }

        let live = liveSensorReadings(in: span)
        guard !live.isEmpty else {
            liveMergeCacheKey = cacheKey
            liveMergeCacheValue = archived
            return archived
        }

        // Both sources are chronological: the archive reader and the live
        // route append path preserve timestamp order. Merge them linearly so
        // a live GPS tick does not sort and allocate the entire route again.
        var merged: [SensorReading] = []
        merged.reserveCapacity(archived.count + live.count)
        var seen = Set<UUID>()
        seen.reserveCapacity(archived.count + live.count)
        var archivedIndex = 0
        var liveIndex = 0

        while archivedIndex < archived.count || liveIndex < live.count {
            let takeArchived: Bool
            if liveIndex == live.count {
                takeArchived = true
            } else if archivedIndex == archived.count {
                takeArchived = false
            } else {
                // Keep the archive first for equal timestamps, matching the
                // previous stable-sort behavior when an ID is duplicated.
                takeArchived = archived[archivedIndex].timestamp
                    <= live[liveIndex].timestamp
            }

            let reading: SensorReading
            if takeArchived {
                reading = archived[archivedIndex]
                archivedIndex += 1
            } else {
                reading = live[liveIndex]
                liveIndex += 1
            }
            if seen.insert(reading.id).inserted {
                merged.append(reading)
            }
        }
        liveMergeCacheKey = cacheKey
        liveMergeCacheValue = merged
        return merged
    }

    private func resumeSensorCollectionIfNeeded() {
        guard settings.locationEnabled,
              permissionState(for: .location).isGranted,
              let sensorService else {
            updateForegroundLiveLocationTracking()
            isSensorCollecting = false
            sensorBackgroundCoordinator.cancel()
            syncSensorBackgroundState()
            return
        }
        let allowsBackgroundLocation =
            BackgroundLocationCollectionPolicy.isEnabled(
                hasAlwaysAuthorization:
                    sensorService.hasAlwaysLocationAuthorization()
            )
        snapshot.settings.backgroundPreciseLocationEnabled =
            allowsBackgroundLocation
        sensorService.startCollection(configuration: sensorCollectionConfiguration(
            profile: settings.sensorCollectionProfile,
            allowsBackgroundLocation: allowsBackgroundLocation
        ))
        updateForegroundLiveLocationTracking()
        isSensorCollecting = true
        if sensorBackgroundCoordinator.lastWakeReason == nil {
            receiveSensorWake(.foregroundResume)
        } else {
            syncSensorBackgroundState()
        }
        reconcileBackgroundSensorSession()
    }

    func updateForegroundLiveLocationTracking() {
        let enabled = ForegroundLiveLocationPolicy.shouldTrack(
            sceneIsActive: isSceneActive,
            locationCollectionEnabled: settings.locationEnabled,
            hasLocationPermission:
                permissionState(for: .location).isGranted
        )
        sensorService?.setForegroundLiveLocationTrackingEnabled(enabled)
    }

    private var hasContinuousBackgroundCollection: Bool {
        isSensorCollecting
            && sensorService?.isCollectionLive() == true
            && settings.backgroundPreciseLocationEnabled
            && sensorService?.hasAlwaysLocationAuthorization() == true
    }

    private func reconcileBackgroundSensorSession(at date: Date = .now) {
        SensorBackgroundRefreshPolicy.save(
            intervalSeconds: settings.gpsLoggingPreferences
                .effectiveIntervalSeconds
        )
        guard hasContinuousBackgroundCollection else {
            if activeTrackingSession == nil {
                sensorBackgroundCoordinator.endSession()
                syncSensorBackgroundState()
            }
            return
        }
        _ = sensorBackgroundCoordinator.beginCollectionSession(at: date)
        syncSensorBackgroundState()
    }

    func resumeSensorCollectionAndRestoreTrackingIfNeeded() async {
        guard acceptsDataMutation() else {
            await sensorService?.stopCollectionAndWait()
            isSensorCollecting = false
            return
        }
        resumeSensorCollectionIfNeeded()
        await restoreTrackingSessionIfNeeded()
    }

    private func restoreTrackingSessionIfNeeded() async {
        let generation = dataDeletionGeneration
        guard activeTrackingSession == nil,
              acceptsDataMutation(),
              settings.locationEnabled,
              permissionState(for: .location).isGranted,
              let sensorService,
              var session = TrackingSessionRecoveryStore.read() else {
            return
        }

        let now = Date.now
        // A running/walking session left open for more than a day is almost
        // certainly a stale crash record rather than a real workout.
        guard session.endedAt == nil,
              now.timeIntervalSince(session.startedAt) <= 24 * 60 * 60 else {
            TrackingSessionRecoveryStore.clear()
            return
        }
        guard !Task.isCancelled,
              generation == dataDeletionGeneration,
              acceptsDataMutation(capturedAt: session.startedAt) else {
            return
        }

        session.endedAt = nil
        guard generation == dataDeletionGeneration,
              acceptsDataMutation(capturedAt: session.startedAt),
              !Task.isCancelled else { return }
        let restored = sensorService.resumeTracking(
            session,
            preferences: settings.gpsLoggingPreferences
        )
        activeTrackingSession = restored
        trackingSessionWasRecovered = true
        lastTrackingSessionRecoveryPersistAt = now
        let readings = (try? await sensorService.archivedRouteReadings(
            for: restored,
            through: now
        )) ?? []
        guard generation == dataDeletionGeneration,
              acceptsDataMutation(capturedAt: restored.startedAt),
              !Task.isCancelled else {
            await sensorService.stopCollectionAndWait()
            activeTrackingSession = nil
            trackingSessionWasRecovered = false
            isSensorCollecting = false
            return
        }
        let routeReadings = readings
            .filter(TrackingSessionPolicy.isPreciseRouteReading)
            .suffix(4_000)
        liveRouteState = LiveRouteState(
            session: restored,
            readings: Array(routeReadings),
            lastUpdatedAt: readings.last?.timestamp ?? restored.startedAt
        )
        TrackingSessionRecoveryStore.save(restored)
        if restored.wasAutomaticallyDetected,
           settings.gpsLoggingPreferences.effectiveIntervalSeconds
                == GPSLoggingPreferences.Preset.realtime.intervalSeconds {
            _ = sensorBackgroundCoordinator.beginAutomaticSession(at: now)
            syncSensorBackgroundState()
        }
        Self.integrationLogger.notice(
            "Recovered tracking session \(restored.id.uuidString, privacy: .public) with \(readings.count, privacy: .public) archived samples"
        )
    }

    func updateFloorEstimate(
        with reading: SensorReading
    ) {
        latestSensorReading = reading
        scheduleWeatherDayFixIfNeeded()
        guard let point = reading.point,
              let match = settings.frequentPlaces
                .compactMap({ place -> (FrequentPlace, Double)? in
                    guard place.isAutomaticRecordingEnabled,
                          let reference = place.point,
                          place.floorCalibration != nil else {
                        return nil
                    }
                    let distance = distanceMeters(point, reference)
                    return distance <= place.radiusMeters
                        ? (place, distance)
                        : nil
                })
                .min(by: { $0.1 < $1.1 })?.0,
              let calibration = match.floorCalibration else {
            latestAltitudeEstimate = nil
            return
        }
        guard let estimate = FloorCalibrationEngine().estimate(
            reading: reading,
            calibration: calibration
        ) else {
            latestAltitudeEstimate = nil
            return
        }
        if altitudeGatePlaceID != match.id {
            altitudeGatePlaceID = match.id
            altitudeSpikeGate.reset()
        }
        // 튀는 고도 표본은 이상치로 스킵하고 직전 추정을 유지한다.
        guard altitudeSpikeGate.accept(estimate.seaLevelAltitudeMeters) else {
            return
        }
        latestAltitudeEstimate = estimate
        let knownFloors = calibration.knownFloors
        guard !knownFloors.contains(estimate.floor),
              abs(estimate.floor - calibration.referenceFloor) >= 1,
              estimate.confidence != .low else {
            return
        }
        let key = "\(match.id.uuidString):\(estimate.floor)"
        guard lastAutoFloorCalibrationKey != key else { return }
        lastAutoFloorCalibrationKey = key
        // 보정은 사용자 확인 없이 감지된 위치의 장소에 바로 적용하고
        // 결과만 알린다. 이미 알고 있는 층이면 위 guard에서 끝난다.
        if recordFloorCalibration(
            placeID: match.id,
            floor: estimate.floor,
            reading: reading,
            seaLevelAltitudeMeters: estimate.seaLevelAltitudeMeters
        ) {
            showFloorCalibrationNotice(
                AppLanguagePreference.text(
                    korean: "\(match.name) \(FloorLabel.korean(estimate.floor)) 고도 보정을 적용했습니다.",
                    english: "Applied altitude calibration for \(match.name) \(FloorLabel.english(estimate.floor))."
                )
            )
        }
    }

    func handlePersistedSensorReadings(
        _ readings: [SensorReading]
    ) {
        let validReadings = readings.filter {
            RouteTimelineTimestamp.isValid($0.timestamp)
        }
        guard let latest = validReadings.max(by: {
            $0.timestamp < $1.timestamp
        }) else { return }
        if let sensorService {
            _ = sensorBackgroundCoordinator.markSaved(
                at: latest.timestamp,
                persistedToken: sensorService.persistenceToken()
            )
            if !settings.backgroundPreciseLocationEnabled {
                _ = sensorBackgroundCoordinator.expireIfNeeded(
                    at: latest.timestamp
                )
            }
            syncSensorBackgroundState()
        }
        for reading in validReadings.sorted(by: {
            $0.timestamp < $1.timestamp
        }) {
            handleLiveSensorReading(reading)
        }
        Task { [weak self] in
            guard let self else { return }
            await self.reconcileSensorCollectionLiveActivity(
                isForeground: self.isSceneActive
            )
        }
    }

    /// 앱이 열려 있을 때 저장·일자 로딩을 기다리지 않고 현재 위치와 경로를 바로 반영한다.
    func applyLiveReadingPreview(_ reading: SensorReading) {
        guard isSceneActive, let point = reading.point,
              RouteTimelineTimestamp.isValid(reading.timestamp) else { return }
        if let latest = latestSensorReading, latest.timestamp > reading.timestamp {
            return
        }
        if latestSensorReading?.id != reading.id {
            latestSensorReading = reading
        }
        guard TrackingSessionPolicy.isPreciseRouteReading(reading),
              !liveRouteState.readings.suffix(3).contains(where: { $0.id == reading.id })
        else { return }
        let moved = liveRouteState.readings.last?.point.map {
            distanceMeters($0, point) >= 2
        } ?? true
        guard moved else { return }
        liveRouteState.readings.append(reading)
        if liveRouteState.readings.count > Self.liveRouteSoftLimit {
            liveRouteState.readings.removeFirst(
                liveRouteState.readings.count - Self.liveRouteHardLimit
            )
        }
        liveRouteState.lastUpdatedAt = reading.timestamp
    }

    private func handleLiveSensorReading(_ reading: SensorReading) {
        if reading.locationFixQuality == .approximate {
            latestSensorReading = reading
        } else {
            updateFloorEstimate(with: reading)
        }
        let session: TrackingSession?
        if let sessionID = reading.trackingSessionID,
           let kind = reading.trackingKind {
            if activeTrackingSession?.id == sessionID {
                session = activeTrackingSession
            } else {
                session = TrackingSession(
                    id: sessionID,
                    kind: kind,
                    startedAt: reading.timestamp,
                    linkedPlanID: nil,
                    sourceDevice: reading.sourceDevice ?? .iPhone,
                    wasAutomaticallyDetected:
                        reading.trackingWasAutomaticallyDetected
                        ?? (kind == .automatic
                            && reading.sourceDevice == .iPhone)
                )
                activeTrackingSession = session
            }
            if liveRouteState.session?.id != sessionID {
                liveRouteState.readings = []
            }
        } else {
            session = activeTrackingSession
        }

        if reading.trackingSessionEnded == true {
            sensorBackgroundCoordinator.finishTrackingSession(
                continuesCollection: hasContinuousBackgroundCollection,
                at: reading.timestamp
            )
        } else if session?.wasAutomaticallyDetected == true,
                  settings.gpsLoggingPreferences.effectiveIntervalSeconds
                    == GPSLoggingPreferences.Preset.realtime.intervalSeconds {
            _ = sensorBackgroundCoordinator.beginAutomaticSession(
                at: reading.timestamp
            )
        }
        syncSensorBackgroundState()

        reconcileBackgroundSensorSession(at: reading.timestamp)

        if let session {
            let shouldPersistSession = reading.trackingSessionEnded == true
                || lastTrackingSessionRecoveryPersistAt.map {
                    reading.timestamp.timeIntervalSince($0) >= 30
                } ?? true
            if shouldPersistSession {
                if reading.trackingSessionEnded == true {
                    TrackingSessionRecoveryStore.clear()
                    lastTrackingSessionRecoveryPersistAt = nil
                } else {
                    TrackingSessionRecoveryStore.save(session)
                    lastTrackingSessionRecoveryPersistAt = reading.timestamp
                }
            }
        }

        if let point = reading.point {
            if TrackingSessionPolicy.isPreciseRouteReading(reading),
               !liveRouteState.readings.suffix(3).contains(where: { $0.id == reading.id }) {
                let lastPoint = liveRouteState.readings.last?.point
                let shouldAppend = lastPoint.map {
                    distanceMeters($0, point) >= 2
                } ?? true
                if shouldAppend {
                    liveRouteState.readings.append(reading)
                    if liveRouteState.readings.count > Self.liveRouteSoftLimit {
                        liveRouteState.readings.removeFirst(
                            liveRouteState.readings.count - Self.liveRouteHardLimit
                        )
                    }
                }
            }
            if reading.locationFixQuality != .approximate {
                refreshCurrentEnvironmentIfNeeded(
                    point: point,
                    at: reading.timestamp
                )
            }
        }
        liveRouteState.session = session
        liveRouteState.lastUpdatedAt = reading.timestamp

        if reading.trackingSessionEnded == true,
           var completed = session {
            completed.endedAt = reading.timestamp
            if reading.sourceDevice != .appleWatch {
                finalizeTrackingSession(completed)
            }
            activeTrackingSession = nil
            trackingSessionWasRecovered = false
            liveRouteState.session = nil
            scheduleSensorAnalysis(
                containing: reading.timestamp,
                immediately: true
            )
        } else {
            scheduleSensorAnalysis(
                containing: reading.timestamp,
                immediately: false
            )
        }
    }

    func scheduleSensorAnalysis(
        containing date: Date,
        immediately: Bool
    ) {
        let day = Calendar.autoupdatingCurrent.startOfDay(for: date)
        // 확정한 지나간 날은 경로·이동 구간을 다시 만들지 않는다.
        guard allowsRecalculation(of: day) else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_analysis_skipped_sealed",
                fields: ["day": String(Int(day.timeIntervalSince1970))]
            )
            return
        }
        sensorAnalysisRequestRevision &+= 1
        pendingSensorAnalysisRevisions[day] = sensorAnalysisRequestRevision
        startSensorAnalysis(immediately: immediately)
    }

    func startSensorAnalysis(immediately: Bool) {
        guard isSceneActive else { return }
        if !immediately, sensorAnalysisDebounceTask != nil { return }
        if immediately { sensorAnalysisDebounceTask?.cancel() }
        sensorAnalysisTaskGeneration &+= 1
        let generation = sensorAnalysisTaskGeneration
        let debounceDelay = sensorAnalysisDebounceDelay
        sensorAnalysisDebounceTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: debounceDelay)
            }
            guard !Task.isCancelled,
                  let self,
                  self.sensorAnalysisTaskGeneration == generation else {
                return
            }
            let batch = self.pendingSensorAnalysisRevisions.sorted {
                $0.key < $1.key
            }
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_analysis_batch_started",
                fields: [
                    "days": String(batch.count),
                    "immediate": String(immediately),
                ]
            )
            var failedDays = 0
            for (day, revision) in batch {
                guard !Task.isCancelled,
                      self.sensorAnalysisTaskGeneration == generation else {
                    return
                }
                let succeeded = await self.refreshSensorTimeline(
                    containing: day
                )
                if succeeded,
                   self.pendingSensorAnalysisRevisions[day] == revision {
                    self.pendingSensorAnalysisRevisions[day] = nil
                } else if !succeeded {
                    failedDays += 1
                }
            }
            guard !Task.isCancelled,
                  self.sensorAnalysisTaskGeneration == generation else {
                return
            }
            await self.persistDeviceLocalSnapshot()
            guard self.sensorAnalysisTaskGeneration == generation else {
                return
            }
            self.sensorAnalysisDebounceTask = nil
            if failedDays > 0 {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "sensor_analysis_retry_scheduled",
                    level: .notice,
                    fields: ["days": String(failedDays)]
                )
            }
            if !self.pendingSensorAnalysisRevisions.isEmpty {
                self.startSensorAnalysis(immediately: false)
            }
        }
    }

    func cancelSensorAnalysisUntilForeground() {
        sensorAnalysisTaskGeneration &+= 1
        sensorAnalysisDebounceTask?.cancel()
        sensorAnalysisDebounceTask = nil
    }

    private func finalizeTrackingSession(_ session: TrackingSession) {
        guard finalizedTrackingSessionIDs.insert(session.id).inserted else {
            return
        }
        let end = max(session.startedAt, session.endedAt ?? .now)
        let kind = session.kind == .running ? "달리기" : "걷기"
        let linkedPlan = session.linkedPlanID.flatMap { planID in
            snapshot.plans.first { $0.id == planID }
        }
        snapshot.actuals.append(
            ActualRecord(
                id: session.id,
                planID: linkedPlan?.id,
                title: linkedPlan?.title ?? kind,
                categoryID: linkedPlan?.categoryID ?? "activity",
                startedAt: session.startedAt,
                endedAt: end,
                source: session.sourceDevice == .appleWatch
                    ? .appleWatch
                    : .location,
                confidence: .high
            )
        )
    }
}
