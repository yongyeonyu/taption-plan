import Foundation
import TaptionPlanCore

/// 하루 센서 갱신이 처음에 모으는 근거(RFT1116A03). 원본은 바꾸지 않고, 뒤 단계는 이 값만 읽는다.
struct SensorRefreshEvidence {
    let span: TimeSpan
    let watchSummaries: [TaptionWatchSensorSummary]
    let watchAccelerationSamples: [TaptionWatchAccelerationSample]
    let archivedReadings: [SensorReading]
    let sensorQuality: TaptionSensorQualityProjection
    let sleepSpan: TimeSpan
    let sleepReadings: [SensorReading]
    let motionActivities: [MotionActivityRecord]
    let sleepMotionActivities: [MotionActivityRecord]
    let pedometer: PedometerSummary?
    let healthKitMovementEvidence: [AppleMovementEvidence]

    var filteredArchivedReadings: [SensorReading] { sensorQuality.routeReadings }

    var latestReadingWithPoint: SensorReading? {
        filteredArchivedReadings
            .filter { $0.point != nil }
            .max { $0.timestamp < $1.timestamp }
    }

    @MainActor
    func fingerprint(settingsHash: Int) -> AppModel.SensorRefreshFingerprint {
        AppModel.SensorRefreshFingerprint(
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
            settingsHash: settingsHash
        )
    }
}

extension AppModel {
    /// 하루 근거를 읽는다. 취소·삭제·읽기 실패면 nil이다.
    func loadSensorRefreshEvidence(
        in span: TimeSpan,
        from sensorService: AppleSensorDataService
    ) async -> SensorRefreshEvidence? {
        let watchData = await watchSensorTimelineData(in: span)
        guard sensorRefreshMayContinue else { return nil }
        let watchSummaries = watchData.summaries
        let watchAccelerationSamples = watchData.accelerationSamples
        await applyReplayedWatchSummaries(watchSummaries)
        guard sensorRefreshMayContinue,
              let archivedReadings = await readArchivedSensorReadings(in: span, from: sensorService),
              sensorRefreshMayContinue,
              let sensorQuality = await sensorQualityProjection(of: archivedReadings),
              sensorRefreshMayContinue else { return nil }
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
        guard sensorRefreshMayContinue else { return nil }
        seedLiveLocationAnchor(in: span, from: filteredArchivedReadings)
        // 하루와 밤 구간은 서로 기다리지 않고 함께 읽는다(REV1110A02).
        async let dayMotion = try? sensorService.motionActivities(in: span)
        async let nightMotion = try? sensorService.motionActivities(in: sleepSpan)
        let motionActivities = await dayMotion ?? []
        let sleepMotionActivities = await nightMotion ?? []
        guard sensorRefreshMayContinue else { return nil }
        recordSensorEvidenceLoaded(
            archivedReadings: archivedReadings,
            quality: sensorQuality,
            motionActivities: motionActivities
        )
        let pedometer =
            try? await sensorService.pedometerSummary(in: span)
        guard sensorRefreshMayContinue else { return nil }
        let healthKitMovementEvidence: [AppleMovementEvidence]
        if settings.healthEnabled {
            healthKitMovementEvidence =
                (try? await healthService.movementEvidence(in: span)) ?? []
        } else {
            healthKitMovementEvidence = []
        }
        guard sensorRefreshMayContinue else { return nil }
        return SensorRefreshEvidence(
            span: span,
            watchSummaries: watchSummaries,
            watchAccelerationSamples: watchAccelerationSamples,
            archivedReadings: archivedReadings,
            sensorQuality: sensorQuality,
            sleepSpan: sleepSpan,
            sleepReadings: sleepReadings,
            motionActivities: motionActivities,
            sleepMotionActivities: sleepMotionActivities,
            pedometer: pedometer,
            healthKitMovementEvidence: healthKitMovementEvidence
        )
    }

    /// 저장된 원본을 읽는다. 취소는 조용히, 다른 실패는 기록하고 사용자에게 알린다.
    private func readArchivedSensorReadings(
        in span: TimeSpan,
        from sensorService: AppleSensorDataService
    ) async -> [SensorReading]? {
        do {
            return try await sensorService.archivedReadings(
                in: span
            )
        } catch is CancellationError {
            return nil
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_timeline_read_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
            userFacingError = AppModelMessage
                .locationReadFailed(error.localizedDescription).text()
            return nil
        }
    }

    /// Raw readings stay in the archive. Every downstream algorithm uses
    /// a copy whose scalar and route outliers are excluded with provenance.
    private func sensorQualityProjection(
        of archivedReadings: [SensorReading]
    ) async -> TaptionSensorQualityProjection? {
        let qualityTask = Task.detached(priority: .utility) {
            try TaptionActivityEngineAdapter.qualityProjection(
                from: archivedReadings,
                cancellationCheck: { try Task.checkCancellation() }
            )
        }
        do {
            return try await withTaskCancellationHandler {
                try await qualityTask.value
            } onCancel: {
                qualityTask.cancel()
            }
        } catch is CancellationError {
            return nil
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_quality_projection_failed",
                level: .error,
                fields: ["error": String(describing: type(of: error))]
            )
            return nil
        }
    }

    /// Seed the live map anchor when the app is reopened before the
    /// next Core Location callback arrives. Historical-day refreshes
    /// must never replace the current-location anchor.
    private func seedLiveLocationAnchor(in span: TimeSpan, from readings: [SensorReading]) {
        if Calendar.autoupdatingCurrent.isDate(span.start, inSameDayAs: .now),
           let latest = MapCurrentLocationAnchorPolicy.latestValidReading(
            in: readings
           ) {
            latestSensorReading = latest
        }
    }

    private func recordSensorEvidenceLoaded(
        archivedReadings: [SensorReading],
        quality sensorQuality: TaptionSensorQualityProjection,
        motionActivities: [MotionActivityRecord]
    ) {
        TaptionPlanDiagnosticsLogger.shared.record(
            "sensor_timeline_evidence_loaded",
            fields: [
                "gps": String(archivedReadings.count),
                "gps_filtered": String(sensorQuality.routeReadings.count),
                "motion": String(motionActivities.count),
                "quality_rejections": String(
                    sensorQuality.rejectionCounts.values.reduce(0, +)
                ),
                "impossible_location_count": String(sensorQuality.impossibleLocationCount),
                "innovation_outlier_count": String(sensorQuality.innovationOutlierCount),
            ]
        )
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
                homeWindow: watchSummaryHomeWindow(summary),
                vitals: vitals[WatchChunkVitals.key(for: summary)]
            )
        }
        snapshot.actuals = WatchHomeWindow.trimmingAwayFromHome(snapshot.actuals, away: awayFromHomeSpans(), asOf: Date())
        snapshot.actuals = ActualRecordSuppressionEngine.visibleRecords(
            from: snapshot.actuals,
            suppressedIDs: snapshot.settings.suppressedActualIDs
        )
    }
}
