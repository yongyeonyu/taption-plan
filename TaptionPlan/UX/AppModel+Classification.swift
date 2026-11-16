import Foundation
import TaptionPlanCore

/// 하루 센서 갱신이 실패·취소될 때 되돌릴 값(RFT1116A03). 갱신을 시작할 때 한 번 찍는다.
struct SensorRefreshRollbackPoint {
    let date: Date
    let snapshot: TaptionDataSnapshot
    let latestSensorReading: SensorReading?
    let snapshotRevision: UInt64
    let dayProjectionRevision: UInt64
    let timelineRevision: UInt64
    let needsLocalRecordNormalization: Bool
    let fingerprint: AppModel.SensorRefreshFingerprint?
}

extension AppModel {
    /// 취소되지 않았고 데이터를 바꿔도 되는지. 하루 갱신은 기다릴 때마다 이것을 다시 본다.
    var sensorRefreshMayContinue: Bool {
        !Task.isCancelled && acceptsDataMutation()
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

    /// 성공(참)이면 바뀐 값을 남기고, 실패·취소(거짓)면 `endSensorRefresh`가 되돌린다.
    private func performSensorTimelineRefresh(containing date: Date, recomputing: Bool = false) async -> Bool {
        guard sensorRefreshMayContinue else { return false }
        let rollback = beginSensorRefresh(containing: date)
        var committed = false
        defer { endSensorRefresh(rollback, committed: committed) }
        committed = await runSensorTimelineRefresh(containing: date, recomputing: recomputing)
        return committed
    }

    private func beginSensorRefresh(containing date: Date) -> SensorRefreshRollbackPoint {
        let rollback = SensorRefreshRollbackPoint(
            date: date,
            snapshot: snapshot,
            latestSensorReading: latestSensorReading,
            snapshotRevision: snapshotRevision,
            dayProjectionRevision: dayProjectionRevision,
            timelineRevision: timelineRevision,
            needsLocalRecordNormalization: needsLocalRecordNormalization,
            fingerprint: sensorRefreshFingerprints[
                Calendar.autoupdatingCurrent.startOfDay(for: date)
            ]
        )
        isSensorTimelineRefreshing = true
        userEditedDuringSensorRefresh = false
        activeDataMutationCount += 1
        return rollback
    }

    private func endSensorRefresh(_ rollback: SensorRefreshRollbackPoint, committed: Bool) {
        if !committed, userEditedDuringSensorRefresh {
            // 편집뿐 아니라 갱신 밖의 모든 변경(다시 읽기·시계·가져오기)이 이 길로 온다(REV1110A04).
            // Keep the edit and the revisions that already guard its save.
            // Derived records are recomputed because the fingerprint is cleared.
            sensorRefreshFingerprints.removeValue(
                forKey: Calendar.autoupdatingCurrent.startOfDay(for: rollback.date)
            )
            needsLocalRecordNormalization = true
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_refresh_rollback_skipped_for_user_edit"
            )
        } else if !committed {
            restoreSensorRefresh(rollback)
        }
        activeDataMutationCount -= 1
        isSensorTimelineRefreshing = false
        userEditedDuringSensorRefresh = false
    }

    private func restoreSensorRefresh(_ rollback: SensorRefreshRollbackPoint) {
        snapshot = rollback.snapshot
        latestSensorReading = rollback.latestSensorReading
        let day = Calendar.autoupdatingCurrent.startOfDay(for: rollback.date)
        if let fingerprint = rollback.fingerprint {
            sensorRefreshFingerprints[day] = fingerprint
        } else {
            sensorRefreshFingerprints.removeValue(forKey: day)
        }
        snapshotRevision = rollback.snapshotRevision
        dayProjectionRevision = rollback.dayProjectionRevision
        timelineRevision = rollback.timelineRevision
        needsLocalRecordNormalization = rollback.needsLocalRecordNormalization
        activityClassificationRevisionFence.advance(
            to: rollback.snapshotRevision
        )
    }

    /// 근거 읽기 → 지문 비교 → 같으면 분류만, 다르면 하루를 다시 만든다.
    private func runSensorTimelineRefresh(containing date: Date, recomputing: Bool) async -> Bool {
        let span = TimelineAggregationEngine().interval(
            for: .day,
            containing: date
        )
        TaptionPlanDiagnosticsLogger.shared.record(
            "sensor_timeline_refresh_started",
            fields: [
                "span_start": String(span.start.timeIntervalSinceReferenceDate),
                "span_end": String(span.end.timeIntervalSinceReferenceDate),
            ]
        )
        await restoreRawWeather(in: span)
        guard sensorRefreshMayContinue else { return false }
        guard let sensorService else { return true }
        guard let evidence = await loadSensorRefreshEvidence(in: span, from: sensorService) else {
            return false
        }
        let refreshFingerprint = evidence.fingerprint(settingsHash: settings.hashValue)
        var recomputeOutcome: ClassificationRecomputeCoordinator.Outcome?
        if recomputing { (snapshot.actuals, recomputeOutcome) = ClassificationRecomputeCoordinator.prepare(snapshot.actuals, rawSampleCount: evidence.archivedReadings.count + evidence.motionActivities.count, inside: span, activityCorrections: snapshot.settings.activityCorrections) }
        let fingerprintUnchanged = recomputeOutcome != .recomputed
            && sensorRefreshFingerprints[span.start] == refreshFingerprint
        if fingerprintUnchanged {
            return await refreshUnchangedSensorDay(evidence, recomputeOutcome: recomputeOutcome)
        }
        return await rebuildSensorDay(
            evidence,
            fingerprint: refreshFingerprint,
            recomputeOutcome: recomputeOutcome,
            sensorService: sensorService
        )
    }
}
