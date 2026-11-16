import Foundation
import TaptionPlanCore

/// 위치 원본 밖에서 빈 구간을 메우는 근거(사진 위치·건강 앱 경로)와 걸음 근거(RFT1116A03).
struct SensorRouteEvidence {
    let photoLocationReadings: [SensorReading]
    let healthRouteReadings: [SensorReading]
    let filteredHealthRouteReadings: [SensorReading]
    let healthMovementEvidence: [AppleMovementEvidence]
}

/// 하루 원본에서 새로 만든 머무름·층·이동(RFT1116A03). 저장 전의 계산 결과다.
struct SensorDayDerivation {
    let readings: [SensorReading]
    let basePlaces: [PlaceStay]
    let places: [PlaceStay]
    let floors: [FloorTransition]
    let travel: [TravelSegment]
    let railJourneys: [RailJourneyRecognizer.Journey]
    let previousSubwaySegments: [TravelSegment]
}

extension AppModel {
    /// 입력 지문이 같은 날. 경로와 장소는 그대로 두고 자동 분류와 이름만 다시 붙인다.
    func refreshUnchangedSensorDay(
        _ evidence: SensorRefreshEvidence,
        recomputeOutcome: ClassificationRecomputeCoordinator.Outcome?
    ) async -> Bool {
        let span = evidence.span
        TaptionPlanDiagnosticsLogger.shared.record(
            "sensor_timeline_refresh_skipped",
            fields: ["reason": "fingerprint_unchanged"]
        )
        // A restaurant can be registered after the last sensor pass. The
        // archived GPS samples are enough to backfill its meal record
        // without rebuilding the route and place lanes.
        guard await applyClassifierOutput(ClassifierRefreshInput(
            span: span, mealReadings: evidence.filteredArchivedReadings,
            contextStays: snapshot.places, contextTravel: snapshot.travel,
            contextReadings: evidence.sensorQuality.readings, motionActivities: evidence.motionActivities,
            archivedReadings: evidence.archivedReadings, watchSummaries: evidence.watchSummaries,
            watchAccelerationSamples: evidence.watchAccelerationSamples,
            sleepReadings: evidence.sleepReadings, sleepSpan: evidence.sleepSpan,
            classifiedReadings: evidence.sensorQuality.routeReadings, gapReadings: evidence.sensorQuality.readings,
            sleepMotionActivities: evidence.sleepMotionActivities
        )) else { return false }
        // 입력이 같아도 장소 이름·결제 확정은 다시 붙인다(늦게 온 카카오 후보·새 결제, 다시 만들어진 집 기록 — PAY1114A01).
        applyBusRecordTitles(in: span, asOf: span.end)
        applyStayPlaceNames(asOf: span.end)
        applyPaymentAnchors(in: span)
        await classificationRecompute?.complete(recomputeOutcome, day: span.start)
        let latestReadingWithPoint = evidence.latestReadingWithPoint
        guard (settings.locationEnabled || settings.weatherEnabled),
              weatherNeedsRefresh(for: latestReadingWithPoint) else {
            return true
        }
        await refreshWeather(
            in: span,
            fallbackReading: latestReadingWithPoint
        )
        return true
    }

    /// 입력이 바뀐 날. 동작 기록·경로·장소·이동을 다시 만들고 자동 분류를 붙인다.
    func rebuildSensorDay(
        _ evidence: SensorRefreshEvidence,
        fingerprint: SensorRefreshFingerprint,
        recomputeOutcome: ClassificationRecomputeCoordinator.Outcome?,
        sensorService: AppleSensorDataService
    ) async -> Bool {
        let span = evidence.span
        let iPhonePedometerEvidence =
            await sensorService.pedometerEvidence(for: evidence.motionActivities)
        guard sensorRefreshMayContinue else { return false }
        if !evidence.motionActivities.isEmpty {
            applyMotionActivityRecords(evidence.motionActivities, inside: span)
        }
        await archiveSensorRefreshRawData(evidence)
        let healthMovementEvidence =
            iPhonePedometerEvidence + evidence.healthKitMovementEvidence
        guard sensorRefreshMayContinue,
              let route = await loadSensorRouteEvidence(
                  evidence, healthMovementEvidence: healthMovementEvidence
              ) else { return false }
        if Self.hasNoSensorEvidence(evidence, route: route) {
            recordNoSensorEvidence(evidence, route: route)
            sensorRefreshFingerprints[span.start] = fingerprint
            await classificationRecompute?.complete(recomputeOutcome, day: span.start)
            return true
        }
        guard let derivation = await deriveSensorDay(evidence, route: route) else { return false }

        // A photo location is only a fallback anchor. It must not erase a
        // previously recorded route when the sensor archive is temporarily
        // unavailable. HealthKit workout routes are valid primary evidence.
        let hasPrimaryLocationEvidence = !evidence.filteredArchivedReadings.isEmpty
            || !route.filteredHealthRouteReadings.isEmpty
        recordSensorTravelInference(
            derivation, evidence: evidence, route: route,
            persisted: hasPrimaryLocationEvidence
        )
        commitSensorDay(derivation, inside: span, replacing: hasPrimaryLocationEvidence)

        // 이번 갱신에서 만든 이동과 장소를 모두 확정한 다음에 정지 구간
        // 문맥을 붙인다. 예전 이동만 보고 있으면 "대기"를 찾을 수 없었다.
        let readings = derivation.readings
        guard await applyClassifierOutput(ClassifierRefreshInput(
            span: span, mealReadings: readings,
            contextStays: hasPrimaryLocationEvidence ? derivation.places : snapshot.places,
            contextTravel: hasPrimaryLocationEvidence ? derivation.travel : snapshot.travel,
            contextReadings: readings, motionActivities: evidence.motionActivities,
            archivedReadings: evidence.archivedReadings, watchSummaries: evidence.watchSummaries,
            watchAccelerationSamples: evidence.watchAccelerationSamples,
            sleepReadings: evidence.sleepReadings, sleepSpan: evidence.sleepSpan,
            classifiedReadings: readings, gapReadings: evidence.sensorQuality.readings,
            sleepMotionActivities: evidence.sleepMotionActivities
        )) else { return false }
        applyRebuiltRecordNames(railJourneys: derivation.railJourneys, inside: span)

        if snapshot.settings.locationEnabled || snapshot.settings.weatherEnabled {
            await refreshWeather(
                in: span,
                fallbackReading: evidence.latestReadingWithPoint
            )
        }
        guard sensorRefreshMayContinue else { return false }
        sensorRefreshFingerprints[span.start] = fingerprint
        await classificationRecompute?.complete(recomputeOutcome, day: span.start)
        return true
    }

    private func applyMotionActivityRecords(
        _ motionActivities: [MotionActivityRecord],
        inside span: TimeSpan
    ) {
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

    private func archiveSensorRefreshRawData(_ evidence: SensorRefreshEvidence) async {
        if let capturedAt = evidence.motionActivities.map(\.span.end).max() {
            await archiveRawDeviceData(
                source: .iPhoneMotion,
                kind: "motion-activities",
                payload: evidence.motionActivities,
                capturedAt: capturedAt
            )
        }
        if let pedometer = evidence.pedometer {
            await archiveRawDeviceData(
                source: .iPhonePedometer,
                kind: "pedometer-summary",
                payload: pedometer,
                capturedAt: pedometer.span.end
            )
        }
        if let capturedAt = evidence.healthKitMovementEvidence.map(\.span.end).max() {
            await archiveRawDeviceData(
                source: .healthKit,
                kind: "movement-evidence",
                payload: evidence.healthKitMovementEvidence,
                capturedAt: capturedAt
            )
        }
    }

    private func loadSensorRouteEvidence(
        _ evidence: SensorRefreshEvidence,
        healthMovementEvidence: [AppleMovementEvidence]
    ) async -> SensorRouteEvidence? {
        let span = evidence.span
        let photoLocationReadings = photoBackfillReadings(
            in: span,
            existingReadings: evidence.archivedReadings
        )
        // 다른 앱·Apple Watch가 HealthKit에 남긴 경로로 빈 구간을 채운다.
        let healthRouteReadings: [SensorReading]
        if settings.healthEnabled {
            healthRouteReadings = HealthRouteMergeEngine.merging(
                (try? await healthService.workoutRouteReadings(in: span)) ?? [],
                into: evidence.archivedReadings
            )
        } else {
            healthRouteReadings = []
        }
        guard sensorRefreshMayContinue else { return nil }
        let filteredHealthRouteReadings = TaptionRouteEngineAdapter
            .filteredReadings(
                from: healthRouteReadings,
                includeLowConfidenceBoundaries: false
            )
        return SensorRouteEvidence(
            photoLocationReadings: photoLocationReadings,
            healthRouteReadings: healthRouteReadings,
            filteredHealthRouteReadings: filteredHealthRouteReadings,
            healthMovementEvidence: healthMovementEvidence
        )
    }

    private static func hasNoSensorEvidence(
        _ evidence: SensorRefreshEvidence,
        route: SensorRouteEvidence
    ) -> Bool {
        evidence.archivedReadings.isEmpty
            && route.photoLocationReadings.isEmpty
            && route.healthRouteReadings.isEmpty
            && evidence.motionActivities.isEmpty
            && route.healthMovementEvidence.isEmpty
            && evidence.sleepReadings.isEmpty
            && evidence.watchSummaries.isEmpty
            && evidence.watchAccelerationSamples.isEmpty
    }

    private func recordNoSensorEvidence(
        _ evidence: SensorRefreshEvidence,
        route: SensorRouteEvidence
    ) {
        TaptionPlanDiagnosticsLogger.shared.record(
            "sensor_travel_inference_completed",
            fields: [
                "gps_readings": String(evidence.archivedReadings.count),
                "gps_filtered_readings": String(evidence.filteredArchivedReadings.count),
                "health_route_readings": String(route.healthRouteReadings.count),
                "motion_activities": String(evidence.motionActivities.count),
                "places": "0",
                "travel": "0",
                "persisted": "false",
                "reason": "no_evidence",
            ]
        )
    }

    /// 원본을 경로용으로 다듬고 머무름·이동을 계산한다. 계산은 주 스레드 밖에서 하고(RFA1105A02),
    /// 저장은 `commitSensorDay`에서 최신 snapshot에 한 번에 한다. 취소·삭제면 nil이다.
    private func deriveSensorDay(
        _ evidence: SensorRefreshEvidence,
        route: SensorRouteEvidence
    ) async -> SensorDayDerivation? {
        let span = evidence.span
        let motionActivities = evidence.motionActivities
        var readings = await SensorStayDerivation.routeReadingsInBackground(
            evidence.filteredArchivedReadings + route.photoLocationReadings + route.filteredHealthRouteReadings,
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
        guard sensorRefreshMayContinue else { return nil }
        let knownPlaces = snapshot.places
        guard let detectedPlaces = await namedDetectedPlaces(
            readings: readings, knownPlaces: knownPlaces
        ) else { return nil }

        let previousSubwaySegments = snapshot.travel.filter {
            $0.mode == .subway
                && $0.span.intersection(with: span) != nil
        }
        let stayInput = SensorStayDerivation.Input(
            detectedPlaces: detectedPlaces,
            readings: readings,
            knownPlaces: knownPlaces,
            frequentPlaces: settings.frequentPlaces,
            healthMovementEvidence: route.healthMovementEvidence,
            userTransitLocations: settings.userTransitLocations,
            registeredCarAudioNames: Set(settings.registeredCarAudioNames),
            motionActivities: motionActivities,
            pedometer: evidence.pedometer,
            previousSubwaySegments: previousSubwaySegments
        )
        let stayOutput = await SensorStayDerivation.runInBackground(stayInput)
        guard sensorRefreshMayContinue else { return nil }
        guard let travelTimeline = try? await ClassifierAdapter.travelTimelineInBackground(readings: readings, in: span),
              sensorRefreshMayContinue else { return nil }
        let travelInput = SensorTravelDerivation.Input(
            inferredTravel: stayOutput.inferredTravel,
            timeline: travelTimeline,
            basePlaces: stayOutput.basePlaces,
            readings: readings,
            motionActivities: motionActivities,
            corrections: snapshot.settings.movementCorrections,
            boardingDecisions: snapshot.settings.transitBoardingDecisions,
            maximumGap: max(5 * 60, snapshot.settings.gpsLoggingPreferences.interval + 60),
            registeredCarAudioNames: Set(settings.registeredCarAudioNames),
            rules: AssistantRuleSnapshot.rules
        )
        let generated = await SensorTravelDerivation.generatedInBackground(travelInput)
        guard sensorRefreshMayContinue else { return nil }
        rememberSuggestedCarAudio(
            readings: audioReadings, travel: generated.travel, registered: registeredCars
        )
        guard let travel = await finishedLockedTravel(
            travelInput, generated: generated, inside: span
        ) else { return nil }
        return SensorDayDerivation(
            readings: readings,
            basePlaces: stayOutput.basePlaces,
            places: stayOutput.places,
            floors: stayOutput.floors,
            travel: travel,
            railJourneys: generated.railJourneys,
            previousSubwaySegments: previousSubwaySegments
        )
    }

    /// 이름 없는 감지 장소에 주소 이름을 붙인다. 취소·삭제면 nil이다.
    private func namedDetectedPlaces(
        readings: [SensorReading],
        knownPlaces: [PlaceStay]
    ) async -> [PlaceStay]? {
        var detectedPlaces = await SensorStayDerivation.detect(readings: readings, knownPlaces: knownPlaces)
        for index in detectedPlaces.indices
            where detectedPlaces[index].displayName == "자동 감지 장소" {
            guard sensorRefreshMayContinue else { return nil }
            guard let point = detectedPlaces[index].point,
                  let name = await placeNameResolver.displayName(
                      latitude: point.latitude,
                      longitude: point.longitude
                  ) else {
                continue
            }
            detectedPlaces[index].displayName = name
        }
        guard sensorRefreshMayContinue else { return nil }
        return detectedPlaces
    }

    private func rememberSuggestedCarAudio(
        readings audioReadings: [SensorReading],
        travel generatedTravel: [TravelSegment],
        registered registeredCars: Set<String>
    ) {
        let recentCarAudio = CarAudioTravelConfirmation.recentNames(
            CarAudioTravelConfirmation.suggestedNames(readings: audioReadings, travel: generatedTravel, registered: registeredCars),
            merging: snapshot.settings.recentCarAudioNames
        )
        if recentCarAudio != snapshot.settings.recentCarAudioNames {
            snapshot.settings.recentCarAudioNames = recentCarAudio
        }
    }

    /// 잠근 이동은 사용자 값이다. 계산 뒤 최신 snapshot으로 합치고, 계산 중 바뀌면 그 자리에서 다시 한다.
    private func finishedLockedTravel(
        _ travelInput: SensorTravelDerivation.Input,
        generated: SensorTravelDerivation.Generated,
        inside span: TimeSpan
    ) async -> [TravelSegment]? {
        let generatedTravel = generated.travel
        var mergedTravel = ActivityClassificationLockEngine.mergingLockedTravel(
            existing: snapshot.travel,
            fresh: generatedTravel,
            inside: span
        )
        let revisionBeforeTravel = snapshotRevision
        var travel = await SensorTravelDerivation.finishedInBackground(travelInput, merged: mergedTravel, railJourneys: generated.railJourneys)
        guard sensorRefreshMayContinue else { return nil }
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
        return travel
    }

    private func recordSensorTravelInference(
        _ derivation: SensorDayDerivation,
        evidence: SensorRefreshEvidence,
        route: SensorRouteEvidence,
        persisted hasPrimaryLocationEvidence: Bool
    ) {
        let travel = derivation.travel
        var travelDiagnostics =
            TaptionPlanDiagnosticsTravelSummary.fields(for: travel)
        travelDiagnostics["gps_readings"] = String(evidence.archivedReadings.count)
        travelDiagnostics["health_route_readings"] = String(
            route.healthRouteReadings.count
        )
        travelDiagnostics["motion_activities"] = String(
            evidence.motionActivities.count
        )
        travelDiagnostics["places"] = String(derivation.places.count)
        travelDiagnostics["base_places"] = String(derivation.basePlaces.count)
        travelDiagnostics["persisted"] = String(hasPrimaryLocationEvidence)
        let subwayCount = travel.filter { $0.mode == .subway }.count
        if !derivation.previousSubwaySegments.isEmpty,
           subwayCount > 0 {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_subway_stabilized",
                fields: [
                    "previous": String(derivation.previousSubwaySegments.count),
                    "current": String(subwayCount),
                ]
            )
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "sensor_travel_inference_completed",
            fields: travelDiagnostics
        )
    }

    /// 하루 구간의 이동·장소·층을 새 값으로 갈아끼운다. 위치 근거가 없으면 정렬만 한다.
    private func commitSensorDay(
        _ derivation: SensorDayDerivation,
        inside span: TimeSpan,
        replacing hasPrimaryLocationEvidence: Bool
    ) {
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
            nextSnapshot.places.append(contentsOf: derivation.places)
            nextSnapshot.floorTransitions.append(contentsOf: derivation.floors)
            nextSnapshot.travel.append(contentsOf: SleepTravelReconciliationEngine
                .removingAutomaticTravel(derivation.travel, sessions: sleepSessions, inside: span))
        }
        nextSnapshot.places.sort { $0.span.start < $1.span.start }
        nextSnapshot.travel.sort { $0.span.start < $1.span.start }
        nextSnapshot.floorTransitions.sort { $0.span.start < $1.span.start }
        snapshot = nextSnapshot
    }

    /// 다시 만든 이동에 맞춰 기록 이름을 고친다(지하철 여정·버스·머무른 곳·결제).
    private func applyRebuiltRecordNames(
        railJourneys: [RailJourneyRecognizer.Journey],
        inside span: TimeSpan
    ) {
        snapshot.actuals = RailJourneyRecognizer.retitling(
            snapshot.actuals,
            subwaySpans: railJourneys.map(\.span),
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
    }
}
