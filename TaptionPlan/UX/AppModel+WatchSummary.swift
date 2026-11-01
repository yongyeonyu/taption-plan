import Foundation
import TaptionPlanCore

extension AppModel {
    func noteAppleWatchDataReceived(
        _ kinds: Set<AppleWatchDataKind>,
        measuredAt: Date,
        receivedAt: Date = .now,
        requestID: String? = nil
    ) {
        guard !kinds.isEmpty else { return }
        let hadPendingRequest = appleWatchDataSyncRequestedAt != nil
        let receipt = appleWatchDataReceiptStore.record(
            kinds,
            measuredAt: measuredAt,
            receivedAt: receivedAt
        )
        let latestDataAt = receipt.latestDataAt
        if appleWatchLastDataReceivedAt != latestDataAt {
            appleWatchLastDataReceivedAt = latestDataAt
        }
        let clearedPendingRequest: Bool
        if let requestedAt = appleWatchDataSyncRequestedAt,
           AppleWatchDataSyncReceiptPolicy.satisfiesPendingRequest(
               requestedAt: requestedAt,
               expectedRequestID: appleWatchDataSyncRequestID,
               receivedRequestID: requestID,
               measuredAt: measuredAt,
               receivedAt: receivedAt
           ) {
            appleWatchDataSyncRequestedAt = nil
            appleWatchDataSyncRequestID = nil
            appleWatchDataSyncRequestStatus = nil
            clearedPendingRequest = true
        } else {
            clearedPendingRequest = false
        }
        let recentKinds = receipt.recentKinds(at: receivedAt)
        if appleWatchReceivedDataKinds != recentKinds {
            appleWatchReceivedDataKinds = recentKinds
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_receipt_recorded",
            fields: [
                "kinds": kinds.map(\.rawValue).sorted().joined(separator: ","),
                "measured_at": String(measuredAt.timeIntervalSince1970),
                "received_at": String(receivedAt.timeIntervalSince1970),
                "latest_received_at": receipt.latestDataAt.map {
                    String($0.timeIntervalSince1970)
                } ?? "none",
                "pending_before": String(hadPendingRequest),
                "pending_cleared": String(clearedPendingRequest),
                "request_id": requestID ?? "none",
                "pending_after": String(
                    appleWatchDataSyncRequestedAt != nil
                ),
                "recent_kinds": recentKinds.map(\.rawValue)
                    .sorted().joined(separator: ","),
            ]
        )
    }

    func applyWatchAccelerationChunk(
        _ chunk: TaptionWatchAccelerationChunk,
        receivedAt: Date,
        requestID: String?
    ) async -> Bool {
        let deletionCutoff = TaptionDataDeletionFence.cutoff()
        guard let chunk = chunk.retainingData(
            after: deletionCutoff,
            receivedAt: receivedAt
        ) else {
            return deletionCutoff.map { cutoff in
                chunk.endedAt <= cutoff
                    || chunk.samples.allSatisfy { $0.capturedAt <= cutoff }
            } ?? false
        }
        guard acceptsDataMutation(capturedAt: chunk.endedAt) else { return false }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_acceleration_chunk_apply_started",
            fields: [
                "chunk": chunk.id.uuidString,
                "samples": String(chunk.samples.count),
                "start": String(chunk.startedAt.timeIntervalSince1970),
                "end": String(chunk.endedAt.timeIntervalSince1970),
                "received_at": String(receivedAt.timeIntervalSince1970),
                "request_id": requestID ?? "none",
            ]
        )
        var storedInDayDatabase = false
        if let dayDatabase {
            do {
                try await dayDatabase.recordWatchAccelerationChunk(chunk)
                storedInDayDatabase = true
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_acceleration_day_database_recorded",
                    fields: ["chunk": chunk.id.uuidString]
                )
            } catch {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_acceleration_day_database_failed",
                    level: .error,
                    fields: TaptionDiagnosticError.fields(for: error).merging([
                        "chunk": chunk.id.uuidString,
                    ]) { _, new in new }
                )
            }
        }
        guard storedInDayDatabase else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_acceleration_persistence_failed",
                level: .error,
                fields: ["chunk": chunk.id.uuidString]
            )
            return false
        }
        noteAppleWatchDataReceived(
            [.motion],
            measuredAt: chunk.endedAt,
            receivedAt: receivedAt,
            requestID: requestID
        )
        invalidateRawDays([chunk.startedAt, chunk.endedAt])
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_acceleration_chunk_applied",
            fields: [
                "chunk": chunk.id.uuidString,
                "samples": String(chunk.samples.count),
            ]
        )
        guard acceptsDataMutation(capturedAt: chunk.endedAt) else { return true }
        scheduleSensorAnalysis(
            containing: chunk.startedAt,
            immediately: chunk.isFinal
        )
        if !Calendar.autoupdatingCurrent.isDate(
            chunk.startedAt,
            inSameDayAs: chunk.endedAt
        ) {
            scheduleSensorAnalysis(
                containing: chunk.endedAt,
                immediately: chunk.isFinal
            )
        }
        return true
    }

    func applyWatchSensorSummary(
        _ summary: TaptionWatchSensorSummary,
        receivedAt: Date,
        requestID: String?
    ) async -> Bool {
        let deletionCutoff = TaptionDataDeletionFence.cutoff()
        guard let summary = summary.retainingData(
            after: deletionCutoff,
            receivedAt: receivedAt
        ) else {
            return deletionCutoff.map {
                summary.startedAt <= $0 || summary.endedAt <= $0
            } ?? false
        }
        guard acceptsDataMutation(capturedAt: summary.endedAt) else {
            return false
        }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        do {
            try await restoreWatchSummaryHighWaterIfNeeded(for: summary)
        } catch {
            return false
        }
        let version = WatchSummaryVersion(
            sequence: summary.sequence,
            revision: summary.ambientRevision ?? 0
        )
        let previousVersion = latestWatchSummaryVersion[summary.sessionID]
        let appliedVersion = appliedWatchSummaryVersion[summary.sessionID]
        let isOlder = previousVersion.map { version < $0 } ?? false
        let isAlreadyApplied = appliedVersion.map { version <= $0 } ?? false
        if isOlder {
            guard await persistWatchSummaryForDelivery(summary) else {
                return false
            }
            guard await persistWatchSummaryReadings(summary),
                  acceptsDataMutation(capturedAt: summary.endedAt) else {
                return false
            }
            Self.persistWatchSummaryHighWater(version, for: summary.sessionID)
            if let previousVersion,
               appliedVersion.map({ $0 < previousVersion }) ?? true {
                let latest: TaptionWatchSensorSummary?
                do {
                    latest = try await latestPersistedWatchSummary(
                        for: summary.sessionID
                    )
                } catch {
                    return false
                }
                guard let latest,
                      Self.watchSummaryVersion(latest) == previousVersion else {
                    return false
                }
                return await applyWatchSensorSummary(
                    latest,
                    receivedAt: receivedAt,
                    requestID: requestID
                )
            }
            return true
        }
        if isAlreadyApplied {
            guard await persistWatchSummaryForDelivery(summary),
                  await persistWatchSummaryReadings(summary),
                  acceptsDataMutation(capturedAt: summary.endedAt) else {
                return false
            }
            Self.persistWatchSummaryHighWater(version, for: summary.sessionID)
            return true
        }
        latestWatchSummaryVersion[summary.sessionID] = version
        if summary.isFinal {
            finalizedWatchSummarySessionIDs.insert(summary.sessionID)
        }
        var dataKinds: Set<AppleWatchDataKind> = [.motion, .activity]
        if summary.latestHeartRate != nil
            || summary.averageHeartRate != nil
            || summary.maximumHeartRate != nil {
            dataKinds.insert(.heartRate)
        }
        if !(summary.routePoints ?? []).isEmpty {
            dataKinds.insert(.route)
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "watch_sensor_summary_apply_started",
            fields: [
                "sequence": String(summary.sequence),
                "samples": String(summary.accelerometerSampleCount),
                "final": String(summary.isFinal),
                "ambient": String(summary.isAmbient == true),
                "has_route": String(!(summary.routePoints ?? []).isEmpty),
                "data_kinds": dataKinds.map(\.rawValue)
                    .sorted().joined(separator: ","),
            ]
        )
        var storedInDayDatabase = false
        if let dayDatabase {
            do {
                try await dayDatabase.recordWatchSummary(summary)
                storedInDayDatabase = true
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_day_database_merge_succeeded",
                    fields: ["sequence": String(summary.sequence)]
                )
            } catch {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "watch_day_database_merge_failed",
                    level: .error,
                    fields: TaptionDiagnosticError.fields(for: error).merging([
                        "sequence": String(summary.sequence),
                    ]) { _, new in new }
                )
            }
        }
        guard storedInDayDatabase else {
            if acceptsDataMutation(capturedAt: summary.endedAt) {
                userFacingError = AppLanguagePreference.text(
                    korean: "Apple Watch 센서 기록을 저장하지 못했습니다.",
                    english: "Could not save Apple Watch sensor records."
                )
            }
            if latestWatchSummaryVersion[summary.sessionID] == version {
                latestWatchSummaryVersion[summary.sessionID] = previousVersion
                if summary.isFinal {
                    finalizedWatchSummarySessionIDs.remove(summary.sessionID)
                }
            }
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_sensor_summary_persistence_failed",
                level: .error,
                fields: [
                    "session": summary.sessionID.uuidString,
                    "sequence": String(summary.sequence),
                ]
            )
            return false
        }
        Self.persistWatchSummaryHighWater(version, for: summary.sessionID)
        guard latestWatchSummaryVersion[summary.sessionID] == version else {
            return false
        }
        noteAppleWatchDataReceived(
            dataKinds,
            measuredAt: summary.endedAt,
            receivedAt: receivedAt,
            requestID: requestID
        )
        if let heartRate = summary.latestHeartRate,
           heartRate.isFinite, heartRate > 0 {
            latestHeartRate = heartRate
            latestHeartRateUpdatedAt = summary.endedAt
        }
        if summary.isFinal {
            if activeTrackingSession?.id == summary.sessionID {
                activeTrackingSession = nil
                trackingSessionWasRecovered = false
                liveRouteState.session = nil
                TrackingSessionRecoveryStore.clear()
                lastTrackingSessionRecoveryPersistAt = nil
            }
        } else if summary.isAmbient != true,
                  activeTrackingSession == nil {
            let kind: TrackingKind = summary.workoutKind == .running
                ? .running
                : .walking
            let session = TrackingSession(
                id: summary.sessionID,
                kind: kind,
                startedAt: summary.startedAt,
                linkedPlanID: summary.linkedPlanID,
                sourceDevice: .appleWatch,
                iPhoneActive: false,
                watchActive: true,
                wasAutomaticallyDetected: false
            )
            activeTrackingSession = session
            liveRouteState = LiveRouteState(
                session: session,
                readings: [],
                lastUpdatedAt: summary.endedAt
            )
            TrackingSessionRecoveryStore.save(session)
            lastTrackingSessionRecoveryPersistAt = summary.endedAt
        }
        await archiveRawDeviceData(
            source: .appleWatch,
            kind: "watch-sensor-summary",
            payload: summary,
            capturedAt: summary.endedAt
        )
        guard acceptsDataMutation(capturedAt: summary.endedAt),
              isCurrentWatchSummary(summary, version: version)
        else { return false }
        dayLoadCoordinator?.invalidate(day: summary.startedAt)
        if !Calendar.autoupdatingCurrent.isDate(
            summary.startedAt,
            inSameDayAs: summary.endedAt
        ) {
            dayLoadCoordinator?.invalidate(day: summary.endedAt)
        }
        let atHome = isWatchSummaryAtHome(summary)
        let resolution = WatchActivityPersonalizationEngine.resolve(
            summary,
            atHome: atHome,
            learnedSamples: WatchActivityLearningStore.read()
        )
        var interpretedSummary = summary
        if let learned = resolution.learnedBehavior {
            interpretedSummary.behavior = learned.kind
            interpretedSummary.behaviorConfidenceScore = learned.confidenceScore
            interpretedSummary.behaviorEvidence = Array(Set(
                (summary.behaviorEvidence ?? []) + learned.evidence
            )).sorted()
            interpretedSummary.behaviorModelVersion = learned.modelVersion
        }
        let previousSuggestion = pendingWatchActivitySuggestion
        if let suggestion = resolution.suggestion {
            pendingWatchActivitySuggestion = mergingWatchSuggestion(suggestion)
        } else if resolution.learnedBehavior != nil
                    || (pendingWatchActivitySuggestion?.sensorSessionID
                        == summary.sessionID && summary.isFinal) {
            pendingWatchActivitySuggestion = nil
        }
        if previousSuggestion != pendingWatchActivitySuggestion {
            publishWatchPayload()
        }
        if summary.isAmbient != true {
            guard await persistWatchSummaryReadings(summary),
                  acceptsDataMutation(capturedAt: summary.endedAt),
                  isCurrentWatchSummary(summary, version: version) else {
                return false
            }
        }
        let linkedPlan = summary.linkedPlanID.flatMap { planID in
            snapshot.plans.first { $0.id == planID }
        }
        if resolution.suggestion == nil {
            snapshot.actuals = AppleWatchSensorActivityEngine.upserting(
                interpretedSummary,
                into: snapshot.actuals,
                linkedPlan: linkedPlan,
                atHome: atHome
            )
        } else {
            // 답변 전에는 후보를 최종 활동으로 보이지 않는다. 원시 센서와
            // 요약 아카이브는 위에서 이미 보존했다.
            snapshot.actuals.removeAll {
                $0.source == .appleWatch
                    && !$0.manuallyCorrected
                    && ($0.id == summary.sessionID
                        || $0.sensorChunkID == summary.sessionID)
            }
        }
        snapshot.actuals = ActualRecordSuppressionEngine.visibleRecords(
            from: snapshot.actuals,
            suppressedIDs: snapshot.settings.suppressedActualIDs
        )
        guard await persistDeviceLocalSnapshot() else { return false }
        guard acceptsDataMutation(capturedAt: summary.endedAt),
              isCurrentWatchSummary(summary, version: version) else {
            return false
        }
        markWatchSummaryApplied(version, for: summary.sessionID)
        scheduleSensorAnalysis(
            containing: summary.startedAt,
            immediately: summary.isFinal
        )
        if !Calendar.autoupdatingCurrent.isDate(
            summary.startedAt,
            inSameDayAs: summary.endedAt
        ) {
            scheduleSensorAnalysis(
                containing: summary.endedAt,
                immediately: summary.isFinal
            )
        }
        return true
    }

    private func persistWatchSummaryReadings(
        _ summary: TaptionWatchSensorSummary
    ) async -> Bool {
        guard summary.isAmbient != true, let sensorService else { return true }
        let routePoints = summary.routePoints ?? []
        let watchAccelerationAverageG = summary.accelerometerAverageG.map {
            SensorVector3(x: $0.x, y: $0.y, z: $0.z)
        }
        let routeSpeeds = routePoints.compactMap(\.speedMetersPerSecond)
            .filter { $0.isFinite && $0 >= 0 }
        let routeAverageSpeed = routeSpeeds.isEmpty
            ? nil
            : routeSpeeds.reduce(0, +) / Double(routeSpeeds.count)
        let behavior = summary.behavior.map {
            WatchBehaviorInference(
                kind: $0,
                confidenceScore: summary.behaviorConfidenceScore ?? 0.5,
                evidence: summary.behaviorEvidence ?? [],
                modelVersion: summary.behaviorModelVersion
                    ?? WatchBehaviorClassifier.rulesVersion
            )
        } ?? WatchBehaviorClassifier.classify(
            WatchBehaviorInput(
                workoutKind: summary.workoutKind,
                duration: summary.endedAt.timeIntervalSince(
                    summary.startedAt
                ),
                accelerometerSampleCount: summary.accelerometerSampleCount,
                accelerometerStandardDeviationG:
                    summary.accelerometerStandardDeviationG,
                accelerometerMeanJerkGPerSecond:
                    summary.accelerometerMeanJerkGPerSecond,
                peakAccelerationG: summary.peakAccelerationG,
                peakRotationRateRadiansPerSecond:
                    summary.peakRotationRateRadiansPerSecond,
                steps: summary.stepCount,
                distanceMeters: summary.distanceMeters,
                floorsAscended: summary.floorsAscended,
                floorsDescended: summary.floorsDescended,
                averageHeartRate: summary.averageHeartRate,
                gpsAverageSpeedMetersPerSecond: routeAverageSpeed,
                gpsAvailable: !routePoints.isEmpty,
                gpsLossRatio: routePoints.isEmpty ? 1 : 0
            )
        )
        let watchMotion: MotionKind = switch behavior.kind {
        case .running: .running
        case .walking, .stairsUp, .stairsDown: .walking
        case .cycling: .cycling
        case .automotive, .publicTransit, .subway: .automotive
        case .stationary, .standing, .sitting, .lying, .elevator,
             .exercise, .brushingTeeth, .eating, .typing, .housework,
             .showering,
             .sleep, .unknown:
            .stationary
        }
        let behaviorSegments = summary.behaviorSegments ?? []
        func behaviorAt(_ date: Date) -> WatchBehaviorInference {
            guard let segment = behaviorSegments.first(where: {
                $0.startedAt <= date && date < $0.endedAt
            }) else { return behavior }
            return WatchBehaviorInference(
                kind: segment.behavior,
                confidenceScore: segment.confidenceScore,
                evidence: segment.evidence,
                modelVersion: segment.modelVersion
            )
        }
        func motionKind(for inference: WatchBehaviorInference) -> MotionKind {
            switch inference.kind {
            case .running: .running
            case .walking, .stairsUp, .stairsDown: .walking
            case .cycling: .cycling
            case .automotive, .publicTransit, .subway: .automotive
            default: .stationary
            }
        }
        var readings = routePoints.enumerated().map { offset, point in
            let pointBehavior = behaviorAt(point.capturedAt)
            return SensorReading(
                id: point.id,
                timestamp: point.capturedAt,
                point: GeoPoint(
                    latitude: point.latitude,
                    longitude: point.longitude,
                    altitude: point.altitude,
                    horizontalAccuracy: point.horizontalAccuracy,
                    verticalAccuracy: point.verticalAccuracy
                ),
                speedMetersPerSecond: point.speedMetersPerSecond,
                courseDegrees: point.courseDegrees,
                motion: motionKind(for: pointBehavior),
                motionConfidence: ConfidenceLevel(
                    score: pointBehavior.confidenceScore
                ),
                relativeAltitudeMeters: summary.relativeAltitudeMeters,
                pressureKilopascals: summary.pressureKilopascals,
                altimeterSessionID: summary.sessionID,
                floorsAscended: summary.floorsAscended,
                floorsDescended: summary.floorsDescended,
                stepCount: summary.stepCount,
                walkingRunningDistanceMeters: summary.distanceMeters,
                watchAccelerationAverageG: watchAccelerationAverageG,
                watchAccelerationStandardDeviationG:
                    summary.accelerometerStandardDeviationG,
                watchAccelerationMeanJerkGPerSecond:
                    summary.accelerometerMeanJerkGPerSecond,
                gpsAvailable: true,
                watchWorkoutKind: summary.workoutKind.rawValue,
                behavior: pointBehavior.kind.rawValue,
                behaviorConfidenceScore: pointBehavior.confidenceScore,
                behaviorEvidence: pointBehavior.evidence,
                behaviorModelVersion: pointBehavior.modelVersion,
                trackingSessionID: summary.sessionID,
                trackingKind: summary.workoutKind == .running
                    ? .running
                    : .walking,
                sourceDevice: .appleWatch,
                sequence: summary.sequence * 10_000 + offset,
                trackingSessionEnded: false
            )
        }
        if readings.isEmpty,
           summary.accelerometerSampleCount > 0,
           !summary.isFinal {
            readings.append(
                SensorReading(
                    id: summary.fallbackReadingID,
                    timestamp: summary.endedAt,
                    motion: watchMotion,
                    motionConfidence: .medium,
                    relativeAltitudeMeters: summary.relativeAltitudeMeters,
                    pressureKilopascals: summary.pressureKilopascals,
                    altimeterSessionID: summary.sessionID,
                    floorsAscended: summary.floorsAscended,
                    floorsDescended: summary.floorsDescended,
                    stepCount: summary.stepCount,
                    walkingRunningDistanceMeters: summary.distanceMeters,
                    watchAccelerationAverageG: watchAccelerationAverageG,
                    watchAccelerationStandardDeviationG:
                        summary.accelerometerStandardDeviationG,
                    watchAccelerationMeanJerkGPerSecond:
                        summary.accelerometerMeanJerkGPerSecond,
                    gpsAvailable: false,
                    watchWorkoutKind: summary.workoutKind.rawValue,
                    behavior: behavior.kind.rawValue,
                    behaviorConfidenceScore: behavior.confidenceScore,
                    behaviorEvidence: behavior.evidence,
                    behaviorModelVersion: behavior.modelVersion,
                    trackingSessionID: summary.sessionID,
                    trackingKind: summary.workoutKind == .running
                        ? .running
                        : .walking,
                    sourceDevice: .appleWatch,
                    sequence: summary.sequence * 10_000,
                    trackingSessionEnded: summary.isFinal
                )
            )
        }
        if summary.isFinal {
            readings.append(
                SensorReading(
                    id: summary.sessionID,
                    timestamp: summary.endedAt,
                    motion: watchMotion,
                    motionConfidence: ConfidenceLevel(
                        score: behavior.confidenceScore
                    ),
                    relativeAltitudeMeters: summary.relativeAltitudeMeters,
                    pressureKilopascals: summary.pressureKilopascals,
                    altimeterSessionID: summary.sessionID,
                    floorsAscended: summary.floorsAscended,
                    floorsDescended: summary.floorsDescended,
                    stepCount: summary.stepCount,
                    walkingRunningDistanceMeters: summary.distanceMeters,
                    watchAccelerationAverageG: watchAccelerationAverageG,
                    watchAccelerationStandardDeviationG:
                        summary.accelerometerStandardDeviationG,
                    watchAccelerationMeanJerkGPerSecond:
                        summary.accelerometerMeanJerkGPerSecond,
                    gpsAvailable: false,
                    watchWorkoutKind: summary.workoutKind.rawValue,
                    behavior: behavior.kind.rawValue,
                    behaviorConfidenceScore: behavior.confidenceScore,
                    behaviorEvidence: behavior.evidence,
                    behaviorModelVersion: behavior.modelVersion,
                    trackingSessionID: summary.sessionID,
                    trackingKind: summary.workoutKind == .running
                        ? .running
                        : .walking,
                    sourceDevice: .appleWatch,
                    sequence: summary.sequence * 10_000 + routePoints.count,
                    trackingSessionEnded: true
                )
            )
        }
        do {
            try await sensorService.recordExternalReadings(readings)
        } catch {
            Self.integrationLogger.error(
                "Watch route archive failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        return true
    }

    private func persistWatchSummaryForDelivery(
        _ summary: TaptionWatchSensorSummary
    ) async -> Bool {
        if let dayDatabase {
            do {
                try await dayDatabase.recordWatchSummary(summary)
                return true
            } catch { }
        }
        return false
    }

    private func latestPersistedWatchSummary(
        for sessionID: UUID
    ) async throws -> TaptionWatchSensorSummary? {
        try await dayDatabase?.latestWatchSummary(for: sessionID)
    }

    private func restoreWatchSummaryHighWaterIfNeeded(
        for summary: TaptionWatchSensorSummary
    ) async throws {
        let sessionID = summary.sessionID
        guard !restoredWatchSummarySessions.contains(sessionID) else { return }

        var restored = latestWatchSummaryVersion[sessionID]
        let cached = Self.persistedWatchSummaryHighWater(for: sessionID)
        if let saved = cached {
            restored = max(restored ?? saved, saved)
        }
        let applied = Self.persistedAppliedWatchSummaryHighWater(
            for: sessionID
        )
        if let applied {
            appliedWatchSummaryVersion[sessionID] = applied
            restored = max(restored ?? applied, applied)
        }

        var persisted: WatchSummaryVersion?
        if let dayDatabase,
           let latest = try await dayDatabase.latestWatchSummary(for: sessionID) {
            persisted = WatchSummaryVersion(
                sequence: latest.sequence,
                revision: latest.ambientRevision ?? 0
            )
        }
        if let persisted {
            restored = max(restored ?? persisted, persisted)
            Self.persistWatchSummaryHighWater(persisted, for: sessionID)
        }

        if let latest = latestWatchSummaryVersion[sessionID] {
            latestWatchSummaryVersion[sessionID] = max(restored ?? latest, latest)
        } else {
            latestWatchSummaryVersion[sessionID] = restored
        }
        restoredWatchSummarySessions.insert(sessionID)
    }

    private func isCurrentWatchSummary(
        _ summary: TaptionWatchSensorSummary,
        version: WatchSummaryVersion
    ) -> Bool {
        latestWatchSummaryVersion[summary.sessionID] == version
            && (summary.isFinal
                || !finalizedWatchSummarySessionIDs.contains(summary.sessionID))
    }

    private static func persistedWatchSummaryHighWater(
        for sessionID: UUID
    ) -> WatchSummaryVersion? {
        let key = watchSummaryHighWaterKeyPrefix + sessionID.uuidString
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        return try? PropertyListDecoder().decode(
            WatchSummaryVersion.self,
            from: data
        )
    }

    private static func persistedAppliedWatchSummaryHighWater(
        for sessionID: UUID
    ) -> WatchSummaryVersion? {
        let key = watchSummaryAppliedHighWaterKeyPrefix + sessionID.uuidString
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return nil
        }
        return try? PropertyListDecoder().decode(
            WatchSummaryVersion.self,
            from: data
        )
    }

    private func markWatchSummaryApplied(
        _ version: WatchSummaryVersion,
        for sessionID: UUID
    ) {
        let applied = max(
            appliedWatchSummaryVersion[sessionID] ?? version,
            version
        )
        appliedWatchSummaryVersion[sessionID] = applied
        Self.persistAppliedWatchSummaryHighWater(applied, for: sessionID)
    }

    private static func persistWatchSummaryHighWater(
        _ version: WatchSummaryVersion,
        for sessionID: UUID
    ) {
        let defaults = UserDefaults.standard
        let key = watchSummaryHighWaterKeyPrefix + sessionID.uuidString
        if let current = persistedWatchSummaryHighWater(for: sessionID),
           current >= version {
            return
        }
        guard let data = try? PropertyListEncoder().encode(version) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    private static func persistAppliedWatchSummaryHighWater(
        _ version: WatchSummaryVersion,
        for sessionID: UUID
    ) {
        let defaults = UserDefaults.standard
        let key = watchSummaryAppliedHighWaterKeyPrefix + sessionID.uuidString
        if let current = persistedAppliedWatchSummaryHighWater(for: sessionID),
           current >= version {
            return
        }
        guard let data = try? PropertyListEncoder().encode(version) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    private static func watchSummaryVersion(
        _ summary: TaptionWatchSensorSummary
    ) -> WatchSummaryVersion {
        WatchSummaryVersion(
            sequence: summary.sequence,
            revision: summary.ambientRevision ?? 0
        )
    }

    static func clearPersistedWatchSummaryHighWater() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(watchSummaryHighWaterKeyPrefix)
                || key.hasPrefix(watchSummaryAppliedHighWaterKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Watch의 답을 파생 기록과 개인화 표본에 반영한다. 원시 센서 아카이브는
    /// 수정하지 않으며 같은 패턴이 충분히 쌓이기 전까지 자동 확정하지 않는다.
    func applyWatchActivityConfirmation(
        _ confirmation: TaptionWatchActivityConfirmation,
        receivedAt: Date
    ) async {
        guard let confirmation = confirmation.retainingData(
            after: TaptionDataDeletionFence.cutoff(),
            receivedAt: receivedAt
        ) else { return }
        guard acceptsDataMutation(capturedAt: confirmation.respondedAt) else {
            return
        }
        guard let suggestion = pendingWatchActivitySuggestion,
              let confirmationToken = suggestion.confirmationToken,
              confirmation.suggestionID == suggestion.id,
              confirmation.sensorSessionID == suggestion.sensorSessionID,
              confirmation.confirmationToken == confirmationToken,
              confirmation.observedStartedAt == suggestion.startedAt,
              confirmation.observedEndedAt == suggestion.endedAt,
              confirmation.observedBehavior == suggestion.proposedBehavior
        else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "watch_activity_confirmation_rejected",
                level: .notice,
                fields: ["reason": "missing_or_invalid_capability"]
            )
            return
        }
        activeDataMutationCount += 1
        defer { activeDataMutationCount -= 1 }
        guard !WatchActivityConfirmationStore.read().contains(where: {
            $0.id == confirmation.id
        }) else { return }
        WatchActivityConfirmationStore.append(confirmation)
        let label = confirmation.isCorrect
            ? confirmation.observedBehavior
            : confirmation.correctedBehavior
        if let label {
            let pattern = suggestion.pattern
            WatchActivityLearningStore.append(
                WatchActivityPatternSample(
                    id: confirmation.id,
                    capturedAt: confirmation.respondedAt,
                    pattern: pattern,
                    label: label
                )
            )
        }
        if let label {
            let sessionID = confirmation.sensorSessionID
                ?? suggestion.sensorSessionID
            let previous = snapshot.actuals.first {
                $0.id == sessionID && $0.source == .appleWatch
            }
            snapshot.actuals.removeAll {
                $0.source == .appleWatch
                    && !$0.manuallyCorrected
                    && ($0.id == sessionID || $0.sensorChunkID == sessionID)
            }
            snapshot.actuals.append(
                ActualRecord(
                    id: sessionID,
                    planID: nil,
                    title: label.title,
                    categoryID: watchCategoryID(for: label),
                    startedAt: confirmation.observedStartedAt,
                    endedAt: confirmation.observedEndedAt,
                    source: .appleWatch,
                    confidence: .high,
                    createdAt: previous?.createdAt
                        ?? confirmation.observedStartedAt,
                    behavior: label.rawValue,
                    evidence: Array(Set(
                        suggestion.evidence + ["사용자 확인"]
                    )).sorted(),
                    sensorChunkID: sessionID,
                    modelVersion:
                        WatchActivityPersonalizationEngine.modelVersion,
                    manuallyCorrected: true
                )
            )
            snapshot.actuals.sort { $0.startedAt < $1.startedAt }
            dayLoadCoordinator?.invalidate(day: confirmation.observedStartedAt)
            if !Calendar.autoupdatingCurrent.isDate(
                confirmation.observedStartedAt,
                inSameDayAs: confirmation.observedEndedAt
            ) {
                dayLoadCoordinator?.invalidate(day: confirmation.observedEndedAt)
            }
        }
        if pendingWatchActivitySuggestion?.id == confirmation.suggestionID {
            pendingWatchActivitySuggestion = nil
        }
        Self.integrationLogger.notice(
            "Watch activity confirmation received: correct=\(confirmation.isCorrect, privacy: .public)"
        )
        await persistDeviceLocalSnapshot()
    }

    private func mergingWatchSuggestion(
        _ candidate: TaptionWatchActivitySuggestion
    ) -> TaptionWatchActivitySuggestion {
        guard let current = pendingWatchActivitySuggestion,
              current.sensorSessionID == candidate.sensorSessionID,
              current.proposedBehavior == candidate.proposedBehavior,
              candidate.startedAt <= current.endedAt.addingTimeInterval(10 * 60)
        else { return candidate }
        var merged = candidate
        merged.id = current.id
        merged.startedAt = min(current.startedAt, candidate.startedAt)
        merged.evidence = Array(Set(current.evidence + candidate.evidence))
            .sorted()
        return merged
    }

    private func watchCategoryID(for behavior: WatchBehaviorKind) -> String {
        if behavior.isMovement { return "movement" }
        if behavior == .sleep { return "sleep" }
        return "activity"
    }
}
