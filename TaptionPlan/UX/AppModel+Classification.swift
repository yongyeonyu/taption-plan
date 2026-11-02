import Foundation
import TaptionPlanCore

extension AppModel {
    /// 이번 갱신이 실제로 신호를 들여다본 구간. 사진·건강 앱에서 메운 점은
    /// 연속 수집이 아니라 드문드문한 복원이므로 근거로 세지 않는다.
    /// 정지 구간을 "정지·휴식" 한 덩어리로 남기지 않고 장소·캘린더·시간
    /// 문맥으로 바꾼다. 새 권한이나 새 수집 없이 이미 모은 신호만 쓴다.
    private func applyStationaryContextRecords(
        stays: [PlaceStay],
        stationarySpans: [TimeSpan],
        travel: [TravelSegment],
        readings: [SensorReading],
        watchSummaries: [TaptionWatchSensorSummary],
        watchAccelerationSamples: [TaptionWatchAccelerationSample],
        evidence: TimeSpan?,
        inside span: TimeSpan
    ) async {
        guard !Task.isCancelled, acceptsDataMutation() else { return }
        let placeKinds = FrequentPlaceResolutionEngine()
            .kindsByPlaceKey(settings.frequentPlaces)
        let restaurantMealSpans = snapshot.actuals.compactMap { actual -> TimeSpan? in
            guard isAutomaticRestaurantMeal(actual) else { return nil }
            return actual.span(asOf: span.end).intersection(with: span)
        }
        let contextStays = stays.filter { stay in
            guard placeKinds[stay.placeKey] == .restaurant else { return true }
            return !restaurantMealSpans.contains {
                $0.intersection(with: stay.span) != nil
            }
        }
        let contextRecords = StationaryContextActualEngine.records(
            stays: contextStays,
            placeKinds: placeKinds,
            placeAnchors: FrequentPlaceResolutionEngine()
                .anchorsByPlaceKey(settings.frequentPlaces),
            stationarySpans: stationarySpans,
            readings: readings,
            calendarEvents: snapshot.calendarEvents,
            actuals: snapshot.actuals,
            travel: travel.filter {
                $0.span.intersection(with: span) != nil
            },
            watchSummaries: watchSummaries,
            watchAccelerationSamples: watchAccelerationSamples,
            inside: span
        ).filter { !snapshot.settings.suppressedActualIDs.contains($0.id) }
        let stableContextRecords = ActivityClassificationLockEngine
            .mergingLockedClassifications(
                existing: snapshot.actuals.filter {
                    $0.source == .location
                        && !isAutomaticRestaurantMeal($0)
                },
                fresh: contextRecords,
                inside: span
            )
        // 판독은 7일만 남는다. 그보다 오래된 날을 열면 문맥을 다시 만들 근거가
        // 없는데, 그때 저장된 기록까지 지우면 되살릴 길이 없다. 이번 갱신이
        // 실제로 들여다본 구간과 새로 만든 기록의 구간만 갈아끼운다.
        let refreshed = stableContextRecords.map { $0.span(asOf: span.end) }
            + [evidence].compactMap { $0?.intersection(with: span) }
        snapshot.actuals.removeAll { actual in
            guard actual.source == .location,
                  AutomaticModelVersion.matches(actual.modelVersion, StationaryContextClassifier.modelVersion),
                  !isAutomaticRestaurantMeal(actual) else {
                return false
            }
            let stored = actual.span(asOf: span.end)
            return refreshed.contains {
                $0.intersection(with: stored) != nil
            }
        }
        guard !stableContextRecords.isEmpty else { return }
        snapshot.actuals = StationaryContextActualEngine
            .suppressingStationaryMotion(
                snapshot.actuals,
                coveredBy: stableContextRecords,
                asOf: span.end
            ) + stableContextRecords
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
    }

    private func applyPlaceActivityRecords(
        stays: [PlaceStay],
        inside span: TimeSpan
    ) {
        let kinds = FrequentPlaceResolutionEngine()
            .kindsByPlaceKey(settings.frequentPlaces)
        let candidates = stays.compactMap { stay in
            TaptionActivityEngineAdapter.placeActivityActual(
                for: stay, registeredKind: kinds[stay.placeKey], inside: span)
        }
        snapshot.actuals = PlaceActivityRefreshEngine.merge(
            existing: snapshot.actuals, candidates: candidates, inside: span,
            suppressedIDs: snapshot.settings.suppressedActualIDs)
        snapshot.actuals.sort {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func isAutomaticRestaurantMeal(_ actual: ActualRecord) -> Bool {
        guard actual.source == .location else { return false }
        if AutomaticModelVersion.matches(actual.modelVersion, RestaurantMealActualEngine.modelVersion) {
            return true
        }
        return AutomaticModelVersion.matches(actual.modelVersion, StationaryContextClassifier.modelVersion)
            && actual.behavior == StationaryContextKind.mealPlace.rawValue
            && actual.evidence.contains { $0.contains("자주가는 곳: 식당") }
    }

    private func applyRestaurantMealRecords(
        readings: [SensorReading],
        watchSummaries: [TaptionWatchSensorSummary],
        watchAccelerationSamples: [TaptionWatchAccelerationSample],
        inside span: TimeSpan
    ) {
        guard !readings.isEmpty else { return }
        let fresh = RestaurantMealActualEngine.records(
            restaurants: settings.frequentPlaces,
            readings: readings,
            watchSummaries: watchSummaries,
            watchAccelerationSamples: watchAccelerationSamples,
            inside: span
        )
        snapshot.actuals.removeAll { actual in
            guard actual.source == .location,
                  actual.span(asOf: span.end).intersection(with: span) != nil
            else { return false }
            return isAutomaticRestaurantMeal(actual)
        }
        guard !fresh.isEmpty else { return }
        snapshot.actuals.append(contentsOf: fresh)
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
    }

    @discardableResult
    func refreshSensorTimeline(containing date: Date? = nil) async -> Bool {
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let day = Calendar.autoupdatingCurrent.startOfDay(for: date ?? selectedDate)
        let recomputes = await classificationRecompute?.needsRecompute(day) ?? false
        let key = "\(day.timeIntervalSince1970):\(rawDataRevision(for: day)):\(settings.hashValue):\(recomputes)"
        if sensorTimelineRequestKey == key, let sensorTimelineTask {
            return await sensorTimelineTask.value
        }
        let previous = sensorTimelineTask
        previous?.cancel()
        let requestID = UUID()
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, !Task.isCancelled else { return false }
            return await self.performSensorTimelineRefresh(containing: day, recomputing: recomputes)
        }
        sensorTimelineTask = task
        sensorTimelineRequestID = requestID
        sensorTimelineRequestKey = key
        defer {
            if sensorTimelineRequestID == requestID {
                sensorTimelineTask = nil
                sensorTimelineRequestID = nil
                sensorTimelineRequestKey = nil
            }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performSensorTimelineRefresh(containing date: Date, recomputing: Bool = false) async -> Bool {
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let snapshotBeforeRefresh = snapshot
        let latestSensorReadingBeforeRefresh = latestSensorReading
        let snapshotRevisionBeforeRefresh = snapshotRevision
        let dayProjectionRevisionBeforeRefresh = dayProjectionRevision
        let timelineRevisionBeforeRefresh = timelineRevision
        let needsLocalRecordNormalizationBeforeRefresh =
            needsLocalRecordNormalization
        let refreshFingerprintBeforeRefresh = sensorRefreshFingerprints[
            Calendar.autoupdatingCurrent.startOfDay(for: date)
        ]
        var committed = false
        isSensorTimelineRefreshing = true
        userEditedDuringSensorRefresh = false
        activeDataMutationCount += 1
        defer {
            if !committed, userEditedDuringSensorRefresh {
                // Keep the edit and the revisions that already guard its save.
                // Derived records are recomputed because the fingerprint is cleared.
                sensorRefreshFingerprints.removeValue(
                    forKey: Calendar.autoupdatingCurrent.startOfDay(for: date)
                )
                needsLocalRecordNormalization = true
                TaptionPlanDiagnosticsLogger.shared.record(
                    "sensor_refresh_rollback_skipped_for_user_edit"
                )
            } else if !committed {
                snapshot = snapshotBeforeRefresh
                latestSensorReading = latestSensorReadingBeforeRefresh
                let day = Calendar.autoupdatingCurrent.startOfDay(for: date)
                if let refreshFingerprintBeforeRefresh {
                    sensorRefreshFingerprints[day] = refreshFingerprintBeforeRefresh
                } else {
                    sensorRefreshFingerprints.removeValue(forKey: day)
                }
                snapshotRevision = snapshotRevisionBeforeRefresh
                dayProjectionRevision = dayProjectionRevisionBeforeRefresh
                timelineRevision = timelineRevisionBeforeRefresh
                needsLocalRecordNormalization =
                    needsLocalRecordNormalizationBeforeRefresh
                activityClassificationRevisionFence.advance(
                    to: snapshotRevisionBeforeRefresh
                )
            }
            activeDataMutationCount -= 1
            isSensorTimelineRefreshing = false
            userEditedDuringSensorRefresh = false
        }
        let span = TimelineAggregationEngine().interval(
            for: .day,
            containing: date
        )
        let archivedReadings: [SensorReading]
        TaptionPlanDiagnosticsLogger.shared.record(
            "sensor_timeline_refresh_started",
            fields: [
                "span_start": String(span.start.timeIntervalSinceReferenceDate),
                "span_end": String(span.end.timeIntervalSinceReferenceDate),
            ]
        )
        await restoreRawWeather(in: span)
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        guard let sensorService else {
            committed = true
            return true
        }
        let watchData = await watchSensorTimelineData(in: span)
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let watchSummaries = watchData.summaries
        let watchAccelerationSamples = watchData.accelerationSamples
        applyReplayedWatchSummaries(watchSummaries)
        do {
            archivedReadings = try await sensorService.archivedReadings(
                in: span
            )
        } catch is CancellationError {
            return false
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_timeline_read_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
            userFacingError = AppModelMessage
                .locationReadFailed(error.localizedDescription).text()
            return false
        }
        // Raw readings stay in the archive. Every downstream algorithm uses
        // a copy whose scalar and route outliers are excluded with provenance.
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let qualityTask = Task.detached(priority: .utility) {
            try TaptionActivityEngineAdapter.qualityProjection(
                from: archivedReadings,
                cancellationCheck: { try Task.checkCancellation() }
            )
        }
        let sensorQuality: TaptionSensorQualityProjection
        do {
            sensorQuality = try await withTaskCancellationHandler {
                try await qualityTask.value
            } onCancel: {
                qualityTask.cancel()
            }
        } catch is CancellationError {
            return false
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_quality_projection_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
            return false
        }
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let filteredArchivedReadings = sensorQuality.routeReadings
        let sleepSpan = SleepAnalysisEngine.overnightSpan(
            containing: span.start
        )
        // The overnight session may begin before midnight. Read that raw
        // window separately so today's sensor-based result is not clipped to
        // 00:00, while route/place inference remains day-scoped.
        let sleepReadings = (try? await sensorService.archivedReadings(
            in: sleepSpan
        )) ?? []
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        if Calendar.autoupdatingCurrent.isDate(span.start, inSameDayAs: .now),
           let latest = MapCurrentLocationAnchorPolicy.latestValidReading(
            in: filteredArchivedReadings
           ) {
            // Seed the live map anchor when the app is reopened before the
            // next Core Location callback arrives. Historical-day refreshes
            // must never replace the current-location anchor.
            latestSensorReading = latest
        }
        let motionActivities =
            (try? await sensorService.motionActivities(in: span)) ?? []
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        TaptionPlanDiagnosticsLogger.shared.record(
            "sensor_timeline_evidence_loaded",
            fields: [
                "gps": String(archivedReadings.count),
                "gps_filtered": String(filteredArchivedReadings.count),
                "motion": String(motionActivities.count),
                "quality_rejections": String(
                    sensorQuality.rejectionCounts.values.reduce(0, +)
                ),
                "impossible_location_count": String(sensorQuality.impossibleLocationCount),
                "innovation_outlier_count": String(sensorQuality.innovationOutlierCount),
            ]
        )
        let pedometer =
            try? await sensorService.pedometerSummary(in: span)
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let healthKitMovementEvidence: [AppleMovementEvidence]
        if settings.healthEnabled {
            healthKitMovementEvidence =
                (try? await healthService.movementEvidence(in: span)) ?? []
        } else {
            healthKitMovementEvidence = []
        }
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let refreshFingerprint = SensorRefreshFingerprint(
            readingCount: archivedReadings.count,
            latestReadingID: archivedReadings.last?.id,
            latestMotionEnd: motionActivities.map(\.span.end).max(),
            motionHash: motionActivities.hashValue,
            pedometerEnd: pedometer?.span.end,
            pedometerHash: pedometer?.hashValue,
            latestHealthEvidenceEnd: healthKitMovementEvidence
                .map(\.span.end)
                .max(),
            healthEvidenceHash: healthKitMovementEvidence.hashValue,
            watchSummaryCount: watchSummaries.count,
            latestWatchSummaryEnd: watchSummaries.map(\.endedAt).max(),
            watchAccelerationSampleCount: watchAccelerationSamples.count,
            latestWatchAccelerationSampleAt: watchAccelerationSamples
                .map(\.capturedAt).max(),
            transportEnrichmentModelVersion:
                AppleTransportContextService.enrichmentModelVersion,
            settingsHash: settings.hashValue
        )
        let latestReadingWithPoint = filteredArchivedReadings
            .filter { $0.point != nil }
            .max { $0.timestamp < $1.timestamp }
        var recomputeOutcome: ClassificationRecomputeCoordinator.Outcome?
        if recomputing { (snapshot.actuals, recomputeOutcome) = ClassificationRecomputeCoordinator.prepare(snapshot.actuals, rawSampleCount: archivedReadings.count + motionActivities.count, inside: span, activityCorrections: snapshot.settings.activityCorrections) }
        let fingerprintUnchanged = recomputeOutcome != .recomputed
            && sensorRefreshFingerprints[span.start] == refreshFingerprint
        if fingerprintUnchanged {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_timeline_refresh_skipped",
                fields: ["reason": "fingerprint_unchanged"]
            )
            // A restaurant can be registered after the last sensor pass. The
            // archived GPS samples are enough to backfill its meal record
            // without rebuilding the route and place lanes.
            guard await applyClassifierOutput(ClassifierRefreshInput(
                span: span, mealReadings: filteredArchivedReadings,
                contextStays: snapshot.places, contextTravel: snapshot.travel,
                contextReadings: sensorQuality.readings, motionActivities: motionActivities,
                archivedReadings: archivedReadings, watchSummaries: watchSummaries,
                watchAccelerationSamples: watchAccelerationSamples,
                sleepReadings: sleepReadings, sleepSpan: sleepSpan,
                classifiedReadings: sensorQuality.routeReadings, gapReadings: sensorQuality.readings
            )) else { return false }
            await classificationRecompute?.complete(recomputeOutcome, day: span.start)
            guard (settings.locationEnabled || settings.weatherEnabled),
                  weatherNeedsRefresh(for: latestReadingWithPoint) else {
                committed = true
                return true
            }
            await refreshWeather(
                in: span,
                fallbackReading: latestReadingWithPoint
            )
            committed = true
            return true
        }
        let iPhonePedometerEvidence =
            await sensorService.pedometerEvidence(for: motionActivities)
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        if !motionActivities.isEmpty {
            let existingAutomatic = snapshot.actuals.filter {
                $0.source != .motion
            }
            let generatedMotionActuals = MotionActivityActualEngine.records(
                from: motionActivities,
                existing: existingAutomatic,
                inside: span
            ).filter {
                !snapshot.settings.suppressedActualIDs.contains($0.id)
            }
            let existingMotionActuals = snapshot.actuals.filter {
                $0.source == .motion
                    && !AutomaticModelVersion.matches($0.modelVersion, AutomaticModelVersion.phoneSleep)
            }
            let mergedMotionActuals = ActivityClassificationLockEngine
                .mergingLockedClassifications(
                    existing: existingMotionActuals,
                    fresh: generatedMotionActuals,
                    inside: span
                )
            Self.integrationLogger.notice(
                "Motion history refresh: activities=\(motionActivities.count, privacy: .public), generated=\(generatedMotionActuals.count, privacy: .public), spanStart=\(span.start.timeIntervalSince1970, privacy: .public), observationEnd=\(min(span.end, Date.now).timeIntervalSince1970, privacy: .public)"
            )
            snapshot.actuals.removeAll {
                $0.source == .motion
                    && !AutomaticModelVersion.matches($0.modelVersion, AutomaticModelVersion.phoneSleep)
                    && $0.span(asOf: span.end).intersection(with: span) != nil
            }
            snapshot.actuals.append(contentsOf: mergedMotionActuals)
            snapshot.actuals.sort { $0.startedAt < $1.startedAt }
        }
        if let capturedAt = motionActivities.map(\.span.end).max() {
            await archiveRawDeviceData(
                source: .iPhoneMotion,
                kind: "motion-activities",
                payload: motionActivities,
                capturedAt: capturedAt
            )
        }
        if let pedometer {
            await archiveRawDeviceData(
                source: .iPhonePedometer,
                kind: "pedometer-summary",
                payload: pedometer,
                capturedAt: pedometer.span.end
            )
        }
        if let capturedAt = healthKitMovementEvidence.map(\.span.end).max() {
            await archiveRawDeviceData(
                source: .healthKit,
                kind: "movement-evidence",
                payload: healthKitMovementEvidence,
                capturedAt: capturedAt
            )
        }
        let healthMovementEvidence =
            iPhonePedometerEvidence + healthKitMovementEvidence
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let photoLocationReadings = photoBackfillReadings(
            in: span,
            existingReadings: archivedReadings
        )
        // 다른 앱·Apple Watch가 HealthKit에 남긴 경로로 빈 구간을 채운다.
        let healthRouteReadings: [SensorReading]
        if settings.healthEnabled {
            healthRouteReadings = HealthRouteMergeEngine.merging(
                (try? await healthService.workoutRouteReadings(in: span)) ?? [],
                into: archivedReadings
            )
        } else {
            healthRouteReadings = []
        }
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let filteredHealthRouteReadings = TaptionRouteEngineAdapter
            .filteredReadings(
                from: healthRouteReadings,
                includeLowConfidenceBoundaries: false
            )
        if archivedReadings.isEmpty,
           photoLocationReadings.isEmpty,
           healthRouteReadings.isEmpty,
           motionActivities.isEmpty,
           healthMovementEvidence.isEmpty,
           sleepReadings.isEmpty,
           watchSummaries.isEmpty,
           watchAccelerationSamples.isEmpty {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_travel_inference_completed",
                fields: [
                    "gps_readings": String(archivedReadings.count),
                    "gps_filtered_readings": String(filteredArchivedReadings.count),
                    "health_route_readings": String(healthRouteReadings.count),
                    "motion_activities": String(motionActivities.count),
                    "places": "0",
                    "travel": "0",
                    "persisted": "false",
                    "reason": "no_evidence",
                ]
            )
            sensorRefreshFingerprints[span.start] = refreshFingerprint
            await classificationRecompute?.complete(recomputeOutcome, day: span.start)
            committed = true
            return true
        }

        var readings = AppleDeviceGroundTruthEngine
            .applyingMotionHistory(
                to: (
                    filteredArchivedReadings
                        + photoLocationReadings
                        + filteredHealthRouteReadings
                ).filter { RouteTimelineTimestamp.isValid($0.timestamp) }
                    .sorted { $0.timestamp < $1.timestamp },
                activities: motionActivities
            )
        readings = await transportContextService.enriching(
            readings,
            userTransitLocations: settings.userTransitLocations
        )
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let knownPlaces = snapshot.places
        let knownNames = knownPlaces.reduce(into: [String: String]()) {
            $0[$1.placeKey] = $1.displayName
        }
        var detectedPlaces = PlaceDetectionEngine().detectStays(
            readings: readings,
            knownNames: knownNames
        )
        for index in detectedPlaces.indices
            where detectedPlaces[index].displayName == "자동 감지 장소" {
            guard !Task.isCancelled, acceptsDataMutation() else { return false }
            guard let point = detectedPlaces[index].point,
                  let name = await placeNameResolver.displayName(
                      latitude: point.latitude,
                      longitude: point.longitude
                  ) else {
                continue
            }
            detectedPlaces[index].displayName = name
        }
        guard !Task.isCancelled, acceptsDataMutation() else { return false }

        detectedPlaces = FrequentPlaceResolutionEngine().applying(
            settings.frequentPlaces,
            to: detectedPlaces,
            readings: readings
        )

        let floorTimeline = FloorTimelineEngine().apply(
            readings: readings,
            to: detectedPlaces,
            knownPlaces: knownPlaces
        )
        let basePlaces = floorTimeline.places
        let walkingLocations = WalkingLocationEngine()
            .build(readings: readings)
            .filter { walkingLocation in
                !basePlaces.contains { place in
                    guard let placePoint = place.point,
                          let walkingPoint = walkingLocation.point,
                          place.span.intersection(
                              with: walkingLocation.span
                          ) != nil else {
                        return false
                    }
                    return distanceMeters(placePoint, walkingPoint) <= 100
                }
            }
        let places = basePlaces + walkingLocations
        let floors = floorTimeline.transitions
        let gpsSegments = MovementRouteBuilder().build(
            stays: basePlaces,
            readings: readings,
            healthEvidence: healthMovementEvidence,
            userTransitLocations: settings.userTransitLocations,
            registeredCarAudioNames: Set(settings.registeredCarAudioNames)
        )
        let previousSubwaySegments = snapshot.travel.filter {
            $0.mode == .subway
                && $0.span.intersection(with: span) != nil
        }
        let inferredTravel = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: gpsSegments,
            motionActivities: motionActivities,
            pedometer: pedometer,
            healthEvidence: healthMovementEvidence,
            readings: readings,
            preservedSubwaySegments: previousSubwaySegments,
            userTransitLocations: settings.userTransitLocations,
            registeredCarAudioNames: Set(settings.registeredCarAudioNames)
        )
        guard let travelTimeline = try? await ClassifierAdapter.travelTimelineInBackground(readings: readings, in: span),
              !Task.isCancelled, acceptsDataMutation() else { return false }
        let correctedTravel = AppleDeviceGroundTruthEngine.resolvingOverlaps(
            AppleDeviceGroundTruthEngine.enforcingMotionFamily(
                MovementCorrectionEngine.applying(
                    snapshot.settings.movementCorrections,
                    to: ClassifierAdapter.resolvingTravelModes(inferredTravel, timeline: travelTimeline),
                    places: basePlaces,
                    readings: readings
                ),
                activities: motionActivities,
                readings: readings
            )
        )
        let generatedTravel = AppleDeviceGroundTruthEngine.coalescingTravel(
            TransitBoardingDecisionEngine.applying(
                snapshot.settings.transitBoardingDecisions,
                to: correctedTravel
            ),
            stays: basePlaces,
            maximumGap: max(
                5 * 60,
                snapshot.settings.gpsLoggingPreferences.interval + 60
            )
        )
        let recentCarAudio = CarAudioTravelConfirmation.recentNames(
            from: generatedTravel, merging: snapshot.settings.recentCarAudioNames
        )
        if recentCarAudio != snapshot.settings.recentCarAudioNames {
            snapshot.settings.recentCarAudioNames = recentCarAudio
        }
        let travel = CarAudioTravelConfirmation.enforcingRegisteredCar(
            ActivityClassificationLockEngine.mergingLockedTravel(
                existing: snapshot.travel,
                fresh: generatedTravel,
                inside: span
            ),
            readings: readings,
            registered: Set(settings.registeredCarAudioNames),
            corrections: snapshot.settings.movementCorrections
        )

        // A photo location is only a fallback anchor. It must not erase a
        // previously recorded route when the sensor archive is temporarily
        // unavailable. HealthKit workout routes are valid primary evidence.
        let hasPrimaryLocationEvidence = !filteredArchivedReadings.isEmpty
            || !filteredHealthRouteReadings.isEmpty
        var travelDiagnostics =
            TaptionPlanDiagnosticsTravelSummary.fields(for: travel)
        travelDiagnostics["gps_readings"] = String(archivedReadings.count)
        travelDiagnostics["health_route_readings"] = String(
            healthRouteReadings.count
        )
        travelDiagnostics["motion_activities"] = String(
            motionActivities.count
        )
        travelDiagnostics["places"] = String(places.count)
        travelDiagnostics["base_places"] = String(basePlaces.count)
        travelDiagnostics["persisted"] = String(hasPrimaryLocationEvidence)
        let subwayCount = travel.filter { $0.mode == .subway }.count
        if !previousSubwaySegments.isEmpty,
           subwayCount > 0 {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_subway_stabilized",
                fields: [
                    "previous": String(previousSubwaySegments.count),
                    "current": String(subwayCount),
                ]
            )
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "sensor_travel_inference_completed",
            fields: travelDiagnostics
        )

        if hasPrimaryLocationEvidence {
            snapshot.travel.removeAll {
                $0.span.intersection(with: span) != nil
            }
            snapshot.places.removeAll {
                $0.span.intersection(with: span) != nil
            }
            snapshot.floorTransitions.removeAll {
                $0.span.intersection(with: span) != nil
            }
            snapshot.places.append(contentsOf: places)
            snapshot.floorTransitions.append(contentsOf: floors)
            snapshot.travel.append(contentsOf: SleepTravelReconciliationEngine
                .removingAutomaticTravel(travel, sessions: sleepSessions, inside: span))
        }
        snapshot.places.sort { $0.span.start < $1.span.start }
        snapshot.travel.sort { $0.span.start < $1.span.start }
        snapshot.floorTransitions.sort { $0.span.start < $1.span.start }

        // 이번 갱신에서 만든 이동과 장소를 모두 확정한 다음에 정지 구간
        // 문맥을 붙인다. 예전 이동만 보고 있으면 "대기"를 찾을 수 없었다.
        guard await applyClassifierOutput(ClassifierRefreshInput(
            span: span, mealReadings: readings,
            contextStays: hasPrimaryLocationEvidence ? places : snapshot.places,
            contextTravel: hasPrimaryLocationEvidence ? travel : snapshot.travel,
            contextReadings: readings, motionActivities: motionActivities,
            archivedReadings: archivedReadings, watchSummaries: watchSummaries,
            watchAccelerationSamples: watchAccelerationSamples,
            sleepReadings: sleepReadings, sleepSpan: sleepSpan,
            classifiedReadings: readings, gapReadings: sensorQuality.readings
        )) else { return false }

        if snapshot.settings.locationEnabled || snapshot.settings.weatherEnabled {
            await refreshWeather(
                in: span,
                fallbackReading: latestReadingWithPoint
            )
        }
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        sensorRefreshFingerprints[span.start] = refreshFingerprint
        await classificationRecompute?.complete(recomputeOutcome, day: span.start)
        committed = true
        return true
    }

    private func applyReplayedWatchSummaries(
        _ summaries: [TaptionWatchSensorSummary]
    ) {
        for summary in summaries {
            let linkedPlan = summary.linkedPlanID.flatMap { planID in
                snapshot.plans.first { $0.id == planID }
            }
            snapshot.actuals = AppleWatchSensorActivityEngine.upserting(
                summary,
                into: snapshot.actuals,
                linkedPlan: linkedPlan,
                atHome: isWatchSummaryAtHome(summary)
            )
        }
        snapshot.actuals = ActualRecordSuppressionEngine.visibleRecords(
            from: snapshot.actuals,
            suppressedIDs: snapshot.settings.suppressedActualIDs
        )
    }

    /// 하루 자동 분류를 한 순서로 적용한다(식사 → 정지 문맥 → 장소 활동 → 수면 → 확정 수면
    /// → 활동 분류 → 공백 추정 → 분류 점수). 갱신 경로 둘이 같은 순서를 따로 들고 있던 것을 합쳤다.
    private func applyClassifierOutput(_ input: ClassifierRefreshInput) async -> Bool {
        let span = input.span
        applyRestaurantMealRecords(
            readings: input.mealReadings,
            watchSummaries: input.watchSummaries,
            watchAccelerationSamples: input.watchAccelerationSamples,
            inside: span
        )
        await applyStationaryContextRecords(
            stays: input.contextStays,
            stationarySpans: input.motionActivities.filter { $0.motion == .stationary }.map(\.span),
            travel: input.contextTravel,
            readings: input.contextReadings,
            watchSummaries: input.watchSummaries,
            watchAccelerationSamples: input.watchAccelerationSamples,
            evidence: ClassifierAdapter.sensorEvidenceSpan(
                readings: input.archivedReadings, activities: input.motionActivities, inside: span
            ),
            inside: span
        )
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        applyPlaceActivityRecords(stays: input.contextStays, inside: span)
        // Sleep inference depends on the current observation cutoff and also
        // consumes motion-only samples without a GPS point.
        applyChargingInactivitySleepRecords(readings: input.sleepReadings, inside: input.sleepSpan)
        snapshot.settings.confirmedSleepSpans =
            TaptionActivityEngineAdapter.migratedConfirmedSleepSpans(
                existing: snapshot.settings.confirmedSleepSpans,
                corrections: snapshot.settings.activityCorrections,
                actuals: snapshot.actuals
            )
        snapshot.actuals = TaptionActivityEngineAdapter.applyingConfirmedSleepSpans(
            snapshot.settings.confirmedSleepSpans,
            to: snapshot.actuals
        )
        guard await applyClassifiedActivityRecords(readings: input.classifiedReadings, inside: span) else {
            return false
        }
        applyInferredGapRecords(readings: input.gapReadings, travel: snapshot.travel, inside: span)
        await applyClassificationScores(readings: input.classifiedReadings, inside: span)
        return !Task.isCancelled
    }

    /// 분류 패키지 HMM의 사후 확률을 자동 이동 기록의 `classificationScore`로 남긴다.
    /// 분류(범주·제목)는 바꾸지 않고, 사용자 소유 기록은 건드리지 않는다.
    private func applyClassificationScores(readings: [SensorReading], inside span: TimeSpan) async {
        guard !readings.isEmpty else { return }
        guard let timeline = try? await ClassifierAdapter.travelTimelineInBackground(readings: readings, in: span),
              !Task.isCancelled else { return }
        let scored = ClassifierAdapter.scoring(
            snapshot.actuals, timeline: timeline, inside: span,
            activityCorrections: snapshot.settings.activityCorrections
        )
        if scored != snapshot.actuals { snapshot.actuals = scored }
    }

    private func applyInferredGapRecords(
        readings: [SensorReading],
        travel: [TravelSegment],
        inside span: TimeSpan
    ) {
        let existing = snapshot.actuals.filter {
            AutomaticModelVersion.matches($0.modelVersion, TaptionActivityEngineAdapter.inferredGapModelVersion)
                && $0.span(asOf: span.end).intersection(with: span) != nil
        }
        let fresh = TaptionActivityEngineAdapter.inferredGapActuals(
            readings: readings,
            travel: travel,
            actuals: snapshot.actuals,
            inside: span
        ).filter { !snapshot.settings.suppressedActualIDs.contains($0.id) }
        // Sparse refreshes are not evidence that an earlier inference vanished.
        guard !fresh.isEmpty else { return }
        let merged = ActivityClassificationLockEngine
            .mergingLockedClassifications(
                existing: existing,
                fresh: fresh,
                inside: span
            )
        snapshot.actuals.removeAll {
            AutomaticModelVersion.matches($0.modelVersion, TaptionActivityEngineAdapter.inferredGapModelVersion)
                && $0.span(asOf: span.end).intersection(with: span) != nil
        }
        snapshot.actuals.append(contentsOf: merged)
        snapshot.actuals.sort {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "sensor_activity_gap_inference_completed",
            fields: [
                "fresh": String(fresh.count),
                "persisted": String(merged.count),
                "model": TaptionActivityEngineAdapter.inferredGapModelVersion,
            ]
        )
    }

    private func applyClassifiedActivityRecords(
        readings: [SensorReading],
        inside span: TimeSpan
    ) async -> Bool {
        let classifiedModelVersion =
            TaptionActivityEngineAdapter.classifiedActivityModelVersion
        let revisionFence = activityClassificationRevisionFence
        return await ActivityClassificationRetry.apply(
            capture: {
                ActivityClassificationSourceSnapshot(
                    revision: snapshotRevision,
                    snapshot: snapshot
                )
            },
            currentRevision: { snapshotRevision },
            classify: { source -> ([ActualRecord], Int, Int)? in
                guard !Task.isCancelled else { return nil }
                let calculation = Task.detached(priority: .utility) {
                    () throws -> ([ActualRecord], Int, Int)? in
                    var existing: [ActualRecord] = []
                    var baseActuals: [ActualRecord] = []
                    var updatedActuals: [ActualRecord] = []
                    for (index, actual) in source.actuals.enumerated() {
                        if index.isMultiple(of: 512), Task.isCancelled { return nil }
                        let isInSpan = actual.span(asOf: span.end)
                            .intersection(with: span) != nil
                        if AutomaticModelVersion.matches(actual.modelVersion, classifiedModelVersion) {
                            if isInSpan {
                                existing.append(actual)
                            } else {
                                updatedActuals.append(actual)
                            }
                        } else {
                            if isInSpan { baseActuals.append(actual) }
                            updatedActuals.append(actual)
                        }
                    }
                    guard !Task.isCancelled else { return nil }
                    try revisionFence.check(source.revision)
                    let fresh = try TaptionActivityEngineAdapter.classifiedActivityActuals(
                        readings: readings,
                        travel: source.travel,
                        corrections: source.corrections,
                        actuals: baseActuals,
                        inside: span,
                        cancellationCheck: {
                            try Task.checkCancellation()
                            try revisionFence.check(source.revision)
                        }
                    ).filter { !source.suppressedIDs.contains($0.id) }
                    let merged = ActivityClassificationLockEngine
                        .mergingLockedClassifications(
                            existing: existing,
                            fresh: fresh,
                            inside: span
                        )
                    updatedActuals.append(contentsOf: merged)
                    guard !Task.isCancelled else { return nil }
                    try revisionFence.check(source.revision)
                    updatedActuals = try ActivityClassificationRecordOrdering.sorted(
                        updatedActuals,
                        cancellationCheck: {
                            try Task.checkCancellation()
                            try revisionFence.check(source.revision)
                        }
                    )
                    try revisionFence.check(source.revision)
                    return (updatedActuals, fresh.count, merged.count)
                }
                let result = await withTaskCancellationHandler {
                    do {
                        return try await calculation.value
                    } catch {
                        return nil
                    }
                } onCancel: {
                    calculation.cancel()
                }
                guard !Task.isCancelled, let result, acceptsDataMutation() else {
                    return nil
                }
                return result
            },
            commit: { _, result in
                if snapshot.actuals != result.0 {
                    snapshot.actuals = result.0
                }
                TaptionPlanDiagnosticsLogger.shared.record(
                    "sensor_activity_classification_completed",
                    fields: [
                        "fresh": String(result.1),
                        "persisted": String(result.2),
                        "model": classifiedModelVersion,
                    ]
                )
            }
        )
    }

    private func applyChargingInactivitySleepRecords(
        readings: [SensorReading],
        inside span: TimeSpan
    ) {
        let maximumSampleGap = max(
            20 * 60,
            settings.gpsLoggingPreferences.interval * 1.6 + 60
        )
        guard !readings.isEmpty else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sleep_inference_completed",
                fields: [
                    "health_enabled": String(settings.healthEnabled),
                    "home_point": String(
                        settings.frequentPlaces.contains {
                            $0.kind == .home
                                && $0.isAutomaticRecordingEnabled
                                && $0.point != nil
                        }
                    ),
                    "readings": "0",
                    "records": "0",
                    "reason": "no_readings",
                ]
            )
            return
        }
        let evidenceSpan = TimeSpan(
            start: readings.map(\.timestamp).min() ?? span.start,
            end: readings.map(\.timestamp).max() ?? span.start
        )
        let homePoint = settings.frequentPlaces.first {
            $0.kind == .home && $0.isAutomaticRecordingEnabled
        }?.point
        let strictRecords = TaptionActivityEngineAdapter.strictSleepActuals(
            readings: readings,
            actuals: snapshot.actuals,
            inside: span,
            homePoint: homePoint,
            maximumSampleGap: maximumSampleGap,
            authoritativeSleepSpans: sleepSessions.compactMap {
                $0.span.intersection(with: span)
            }
        ).filter { !snapshot.settings.suppressedActualIDs.contains($0.id) }
        let records = PhoneSleepFusion.records(
            readings: readings,
            actuals: snapshot.actuals,
            inside: span,
            nominalMaximumSampleGap: maximumSampleGap,
            authoritativeSleepSpans: sleepSessions.map(\.span),
            strict: strictRecords
        ).filter { !snapshot.settings.suppressedActualIDs.contains($0.id) }
        let fusedStrictCount = records.filter { strictRecords.contains($0) }.count
        let ordered = readings
            .filter { RouteTimelineTimestamp.isValid($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
        let largeGapCount = zip(ordered, ordered.dropFirst()).filter {
            $1.timestamp.timeIntervalSince($0.timestamp) > maximumSampleGap
        }.count
        TaptionPlanDiagnosticsLogger.shared.record(
            "sleep_inference_completed",
            fields: [
                "charging": String(readings.filter {
                    $0.powerState?.isCharging == true
                }.count),
                "first": String(evidenceSpan.start.timeIntervalSince1970),
                "engine": records.isEmpty ? "none" : (fusedStrictCount > 0 ? "strict" : "iphone-fallback"),
                "health_enabled": String(settings.healthEnabled),
                "home_point": String(homePoint != nil),
                "large_gaps": String(largeGapCount),
                "max_gap_seconds": String(Int(zip(ordered, ordered.dropFirst()).map {
                    $1.timestamp.timeIntervalSince($0.timestamp)
                }.max() ?? 0)),
                "stationary": String(ordered.filter { $0.motion == .stationary }.count),
                "stationary_dark": String(ordered.filter {
                    $0.motion == .stationary && $0.screenIsOn == false
                }.count),
                "last": String(evidenceSpan.end.timeIntervalSince1970),
                "readings": String(readings.count),
                "records": String(records.count),
                "reason": records.isEmpty
                    ? "conditions_or_continuity_not_met"
                    : "recorded",
                "strict_records": String(fusedStrictCount),
                "fallback_records": String(records.count - fusedStrictCount),
                "screen_missing": String(readings.filter {
                    $0.screenIsOn == nil
                }.count),
                "screen_off": String(readings.filter {
                    $0.screenIsOn == false
                }.count),
                "screen_on": String(readings.filter {
                    $0.screenIsOn == true
                }.count),
            ]
        )
        snapshot.actuals.removeAll { actual in
            AutomaticModelVersion.matches(actual.modelVersion, AutomaticModelVersion.phoneSleep)
                && actual.span(asOf: span.end)
                    .intersection(with: evidenceSpan) != nil
        }
        snapshot.actuals.removeAll { actual in
            AutomaticModelVersion.matches(actual.modelVersion, TaptionActivityEngineAdapter.strictSleepModelVersion)
                && actual.span(asOf: span.end)
                    .intersection(with: evidenceSpan) != nil
        }
        snapshot.actuals.append(contentsOf: records)
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
    }
}
