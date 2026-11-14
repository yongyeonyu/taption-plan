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
            calendarTitleDetails: snapshot.settings.calendarTitleDetails,
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
            // 이 작업이 바꾼 것만 실패 때 되돌린다. 다른 작업의 변경은 남긴다(REV1110A04).
            return await SensorRefreshMutationScope.$isActive.withValue(true) {
                await self.performSensorTimelineRefresh(containing: day, recomputing: recomputes)
            }
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
                // 편집뿐 아니라 갱신 밖의 모든 변경(다시 읽기·시계·가져오기)이 이 길로 온다(REV1110A04).
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
        await applyReplayedWatchSummaries(watchSummaries)
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
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
        // 하루와 밤 구간은 서로 기다리지 않고 함께 읽는다(REV1110A02).
        async let dayMotion = try? sensorService.motionActivities(in: span)
        async let nightMotion = try? sensorService.motionActivities(in: sleepSpan)
        let motionActivities = await dayMotion ?? []
        let sleepMotionActivities = await nightMotion ?? []
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
                classifiedReadings: sensorQuality.routeReadings, gapReadings: sensorQuality.readings,
                sleepMotionActivities: sleepMotionActivities
            )) else { return false }
            // 입력이 같아도 장소 이름·결제 확정은 다시 붙인다(늦게 온 카카오 후보·새 결제, 다시 만들어진 집 기록 — PAY1114A01).
            applyBusRecordTitles(in: span, asOf: span.end)
            applyStayPlaceNames(asOf: span.end)
            applyPaymentAnchors(in: span)
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
                inside: span,
                // 수정·숨김이 붙은 뒤 조각은 합치지 않고, 합친 기록(첫 조각 식별자)의 수정·숨김은 합친 채로 따른다 (REV1110A06).
                protectedIDs: snapshot.settings.suppressedActualIDs.union(snapshot.settings.activityCorrections.keys)
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
            // 쓰기마다 didSet이 돌지 않게 모아서 한 번에 넣는다(ARC1103A01 A안).
            var actuals = snapshot.actuals
            actuals.removeAll {
                $0.source == .motion
                    && !AutomaticModelVersion.matches($0.modelVersion, AutomaticModelVersion.phoneSleep)
                    && $0.span(asOf: span.end).intersection(with: span) != nil
            }
            actuals.append(contentsOf: mergedMotionActuals)
            actuals.sort { $0.startedAt < $1.startedAt }
            snapshot.actuals = actuals
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

        var readings = await SensorStayDerivation.routeReadingsInBackground(
            filteredArchivedReadings + photoLocationReadings + filteredHealthRouteReadings,
            activities: motionActivities
        )
        readings = await transportContextService.enriching(
            readings,
            userTransitLocations: settings.userTransitLocations
        )
        // 하루 판정은 등록한 차의 오디오만 본다. 등록 안내 후보는 아래에서 원본 이름으로 찾는다. 저장된 원본은 그대로다(CAR1111A01).
        let registeredCars = Set(settings.registeredCarAudioNames)
        let audioReadings = readings
        readings = CarAudioTravelConfirmation.registeredOnly(readings, registered: registeredCars)
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let knownPlaces = snapshot.places
        // 계산은 주 스레드 밖에서 한다(RFA1105A02). 저장은 아래에서 최신 snapshot에 한 번에 한다.
        let readingsForDetection = readings
        var detectedPlaces = await SensorStayDerivation.detect(readings: readingsForDetection, knownPlaces: knownPlaces)
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

        let previousSubwaySegments = snapshot.travel.filter {
            $0.mode == .subway
                && $0.span.intersection(with: span) != nil
        }
        let stayInput = SensorStayDerivation.Input(
            detectedPlaces: detectedPlaces,
            readings: readings,
            knownPlaces: knownPlaces,
            frequentPlaces: settings.frequentPlaces,
            healthMovementEvidence: healthMovementEvidence,
            userTransitLocations: settings.userTransitLocations,
            registeredCarAudioNames: Set(settings.registeredCarAudioNames),
            motionActivities: motionActivities,
            pedometer: pedometer,
            previousSubwaySegments: previousSubwaySegments
        )
        let stayOutput = await SensorStayDerivation.runInBackground(stayInput)
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let basePlaces = stayOutput.basePlaces
        let places = stayOutput.places
        let floors = stayOutput.floors
        let inferredTravel = stayOutput.inferredTravel
        guard let travelTimeline = try? await ClassifierAdapter.travelTimelineInBackground(readings: readings, in: span),
              !Task.isCancelled, acceptsDataMutation() else { return false }
        let travelInput = SensorTravelDerivation.Input(
            inferredTravel: inferredTravel,
            timeline: travelTimeline,
            basePlaces: basePlaces,
            readings: readings,
            motionActivities: motionActivities,
            corrections: snapshot.settings.movementCorrections,
            boardingDecisions: snapshot.settings.transitBoardingDecisions,
            maximumGap: max(5 * 60, snapshot.settings.gpsLoggingPreferences.interval + 60),
            registeredCarAudioNames: Set(settings.registeredCarAudioNames),
            rules: AssistantRuleSnapshot.rules
        )
        let generated = await SensorTravelDerivation.generatedInBackground(travelInput)
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        let generatedTravel = generated.travel
        let recentCarAudio = CarAudioTravelConfirmation.recentNames(
            CarAudioTravelConfirmation.suggestedNames(readings: audioReadings, travel: generatedTravel, registered: registeredCars),
            merging: snapshot.settings.recentCarAudioNames
        )
        if recentCarAudio != snapshot.settings.recentCarAudioNames {
            snapshot.settings.recentCarAudioNames = recentCarAudio
        }
        // 잠근 이동은 사용자 값이다. 계산 뒤 최신 snapshot으로 합치고, 계산 중 바뀌면 그 자리에서 다시 한다.
        var mergedTravel = ActivityClassificationLockEngine.mergingLockedTravel(
            existing: snapshot.travel,
            fresh: generatedTravel,
            inside: span
        )
        let revisionBeforeTravel = snapshotRevision
        var travel = await SensorTravelDerivation.finishedInBackground(travelInput, merged: mergedTravel, railJourneys: generated.railJourneys)
        guard !Task.isCancelled, acceptsDataMutation() else { return false }
        if snapshotRevision != revisionBeforeTravel {
            mergedTravel = ActivityClassificationLockEngine.mergingLockedTravel(
                existing: snapshot.travel,
                fresh: generatedTravel,
                inside: span
            )
            var freshInput = travelInput
            freshInput.corrections = snapshot.settings.movementCorrections
            travel = SensorTravelDerivation.finished(freshInput, merged: mergedTravel, railJourneys: generated.railJourneys)
        }

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

        // 쓰기마다 didSet이 돌지 않게 모아서 한 번에 넣는다.
        var nextSnapshot = snapshot
        if hasPrimaryLocationEvidence {
            nextSnapshot.travel.removeAll {
                $0.span.intersection(with: span) != nil
            }
            nextSnapshot.places.removeAll {
                $0.span.intersection(with: span) != nil
            }
            nextSnapshot.floorTransitions.removeAll {
                $0.span.intersection(with: span) != nil
            }
            nextSnapshot.places.append(contentsOf: places)
            nextSnapshot.floorTransitions.append(contentsOf: floors)
            nextSnapshot.travel.append(contentsOf: SleepTravelReconciliationEngine
                .removingAutomaticTravel(travel, sessions: sleepSessions, inside: span))
        }
        nextSnapshot.places.sort { $0.span.start < $1.span.start }
        nextSnapshot.travel.sort { $0.span.start < $1.span.start }
        nextSnapshot.floorTransitions.sort { $0.span.start < $1.span.start }
        snapshot = nextSnapshot

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
            classifiedReadings: readings, gapReadings: sensorQuality.readings,
            sleepMotionActivities: sleepMotionActivities
        )) else { return false }
        snapshot.actuals = RailJourneyRecognizer.retitling(
            snapshot.actuals,
            subwaySpans: generated.railJourneys.map(\.span),
            activityCorrections: snapshot.settings.activityCorrections,
            asOf: span.end
        )
        // 이동 구간이 버스면 그 시간의 자동 「자동차」 기록도 「버스」로(BST1113A01).
        applyBusRecordTitles(in: span, asOf: span.end)
        // 「머무름」 기록에 기억해 둔 장소 이름을 붙이고, 모르는 곳은 뒤에서 찾아 다시 붙인다(KKP1113A01).
        applyStayPlaceNames(asOf: span.end)
        scheduleStayPlaceNameLookup(asOf: span.end)
        // 결제 시각으로 머문 곳·활동을 확정한다(PAY1114A01).
        applyPaymentAnchors(in: span)

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
    ) async {
        // 받을 때와 같은 심박·걸음 근거로 다시 판정해야 결과가 뒤바뀌지 않는다.
        let vitals = await watchChunkVitals(for: summaries)
        guard !Task.isCancelled, acceptsDataMutation() else { return }
        for summary in summaries {
            let linkedPlan = summary.linkedPlanID.flatMap { planID in
                snapshot.plans.first { $0.id == planID }
            }
            snapshot.actuals = AppleWatchSensorActivityEngine.upserting(
                summary,
                into: snapshot.actuals,
                linkedPlan: linkedPlan,
                atHome: isWatchSummaryAtHome(summary),
                vitals: vitals[WatchChunkVitals.key(for: summary)]
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
        // 충전·정지 수면이 먼저 들어가야 점수형 수면이 그 밤을 건너뛴다.
        applyPhoneSleepScoreRecords(readings: input.sleepReadings, motionActivities: input.sleepMotionActivities, night: input.sleepSpan)
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
        applyUnobservedMealCandidates(readings: input.mealReadings, motionActivities: input.motionActivities, inside: span)
        let carved = RestaurantMealActualEngine.carvingMeals(
            from: snapshot.actuals, activityCorrections: snapshot.settings.activityCorrections, asOf: span.end
        )
        if carved != snapshot.actuals { snapshot.actuals = carved.sorted { $0.startedAt < $1.startedAt } }
        await applyClassificationScores(readings: input.classifiedReadings, inside: span)
        return !Task.isCancelled
    }

    /// 위치가 끊긴 식사 시간을 낮은 신뢰도 후보로 둔다. 사용자가 확인·수정한 후보는 그대로 남고, 지운 후보는 되살리지 않는다.
    private func applyUnobservedMealCandidates(
        readings: [SensorReading],
        motionActivities: [MotionActivityRecord],
        inside span: TimeSpan
    ) {
        guard !readings.isEmpty else { return }
        let corrections = snapshot.settings.activityCorrections
        var kept = snapshot.actuals.filter { actual in
            guard AutomaticModelVersion.matches(actual.modelVersion, UnobservedStayEngine.modelVersion),
                  !ActualRecord.userOwned(actual, activityCorrections: corrections) else { return true }
            return actual.span(asOf: span.end).intersection(with: span) == nil
        }
        // 앱이 꺼져 있던 시간(표본이 전혀 없음)은 식사 후보로도 채우지 않는다(MOV1110A01).
        let unobserved = UnobservedAppSpans.spans(readings: readings, travel: snapshot.travel, inside: span)
        let footSpans = motionActivities.filter { $0.motion.isOnFoot }.map(\.span)
        let meetings = snapshot.calendarEvents.filter(\.isMeetingLike).map(\.span)
        let fresh = UnobservedStayEngine.mealCandidates(
            readings: readings, footSpans: footSpans, actuals: kept, activityCorrections: corrections, busySpans: meetings, inside: span
        ).filter { !snapshot.settings.suppressedActualIDs.contains($0.id) && !UnobservedAppSpans.covers(unobserved, $0.span(asOf: span.end)) }
        kept.append(contentsOf: fresh)
        kept.sort { $0.startedAt < $1.startedAt }
        if kept != snapshot.actuals { snapshot.actuals = kept }
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
        // 앱이 꺼져 표본이 하나도 없던 긴 시간은 추정으로 채우지 않고 미확인으로 둔다(MOV1110A01).
        let unobserved = UnobservedAppSpans.spans(readings: readings, travel: travel, inside: span)
        let fresh = TaptionActivityEngineAdapter.inferredGapActuals(
            readings: readings,
            travel: travel,
            actuals: snapshot.actuals,
            inside: span
        ).filter { !snapshot.settings.suppressedActualIDs.contains($0.id) && !UnobservedAppSpans.covers(unobserved, $0.span(asOf: span.end)) }
        let stale = snapshot.actuals.filter {
            AutomaticModelVersion.matches($0.modelVersion, TaptionActivityEngineAdapter.inferredGapModelVersion)
                && !ActualRecord.userOwned($0, activityCorrections: snapshot.settings.activityCorrections)
                && UnobservedAppSpans.covers(unobserved, $0.span(asOf: span.end))
        }.map(\.id)
        if !stale.isEmpty { snapshot.actuals.removeAll { stale.contains($0.id) } }
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

    /// 다른 수면 판정이 없는 밤만 점수로 판정한다. 위치를 꺼 표본이 없어도 동작 기록으로 판정한다(SLP1110A01).
    private func applyPhoneSleepScoreRecords(
        readings: [SensorReading],
        motionActivities: [MotionActivityRecord],
        night: TimeSpan
    ) {
        snapshot.actuals.removeAll { actual in
            AutomaticModelVersion.matches(actual.modelVersion, PhoneSleepScoreAdapter.modelVersion)
                && actual.span(asOf: night.end).intersection(with: night) != nil
        }
        let home = settings.frequentPlaces.first { $0.kind == .home && $0.isAutomaticRecordingEnabled }
        let records = PhoneSleepScoreAdapter.records(
            night: night,
            readings: readings,
            motionActivities: motionActivities,
            actuals: snapshot.actuals,
            homePoint: home?.point,
            homeRadiusMeters: home?.radiusMeters ?? 100,
            wearableSleepSpans: sleepSessions.map(\.span)
        ).filter { !snapshot.settings.suppressedActualIDs.contains($0.id) }
        TaptionPlanDiagnosticsLogger.shared.record(
            "sleep_score_completed",
            fields: [
                "readings": String(readings.count),
                "motion_activities": String(motionActivities.count),
                "records": String(records.count),
                "evidence": records.first?.evidence.joined(separator: ";") ?? "none",
            ]
        )
        guard !records.isEmpty else { return }
        snapshot.actuals.append(contentsOf: records)
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
    }

    func applyStayPlaceNames(asOf now: Date) {
        let named = StayPlaceNaming.retitling(
            snapshot.actuals, places: snapshot.places, names: NLENearbyPlaceNames.storedNames,
            candidates: NLENearbyPlaceNames.storedCandidates,
            activityCorrections: snapshot.settings.activityCorrections, asOf: now
        )
        if named != snapshot.actuals { snapshot.actuals = named }
    }

    /// 버스 구간의 기록 이름을 맞춘다(「버스 · 80번」). 버스가 아니게 된 구간의 기록은 「자동차」로 돌아간다.
    func applyBusRecordTitles(in span: TimeSpan, asOf now: Date) {
        let busSegments = snapshot.travel.filter { $0.mode == .bus && $0.span.intersection(with: span) != nil }
        let titled = BusRideRecognizer.retitling(
            snapshot.actuals,
            busSpans: busSegments.map(\.span),
            titles: busSegments.map { BusRouteCheck.title(BusRouteCheck.known($0) ?? []) },
            activityCorrections: snapshot.settings.activityCorrections,
            asOf: now
        )
        if titled != snapshot.actuals { snapshot.actuals = titled }
    }

    func applyPaymentAnchors(in span: TimeSpan) {
        let anchored = PaymentStayAnchor.applying(
            snapshot.actuals, payments: PaymentStayAnchor.payments(LedgerBook.shared.entries, in: span), places: snapshot.places,
            candidates: NLENearbyPlaceNames.storedCandidates, activityCorrections: snapshot.settings.activityCorrections, asOf: span.end
        )
        if anchored != snapshot.actuals { snapshot.actuals = anchored }
    }

    private func scheduleStayPlaceNameLookup(asOf now: Date) {
        let points = StayPlaceNaming.pointsNeedingNames(
            snapshot.actuals, places: snapshot.places, known: NLENearbyPlaceNames.storedCandidates.mapValues { $0.first?.name ?? "" }, asOf: now
        )
        guard !points.isEmpty else { return }
        Task { @MainActor [weak self] in
            let found = await NLENearbyPlaceNames.names(for: points)
            guard let self, !found.isEmpty, !Task.isCancelled, self.acceptsDataMutation() else { return }
            self.applyStayPlaceNames(asOf: now)
        }
    }

}
