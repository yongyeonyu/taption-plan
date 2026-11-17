import Foundation
import TaptionPlanCore

/// 하루 자동 분류 단계(식사·정지 문맥·장소 활동·활동 분류·공백 추정·분류 점수). 센서 갱신 두 길이 함께 쓴다(RFT1116A03).
extension AppModel {
    /// 하루 자동 분류를 한 순서로 적용한다(식사 → 정지 문맥 → 장소 활동 → 수면 → 확정 수면
    /// → 활동 분류 → 공백 추정 → 분류 점수). 갱신 경로 둘이 같은 순서를 따로 들고 있던 것을 합쳤다.
    func applyClassifierOutput(_ input: ClassifierRefreshInput) async -> Bool {
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

    func applyRestaurantMealRecords(
        readings: [SensorReading],
        watchSummaries: [TaptionWatchSensorSummary],
        watchAccelerationSamples: [TaptionWatchAccelerationSample],
        inside span: TimeSpan
    ) {
        guard !readings.isEmpty else { return }
        // 다른 단계처럼 숨긴 기록은 되살리지 않고, 사용자가 고친 기록은 지우거나 같은 ID로 다시 만들지 않는다(REV1117A03).
        let corrections = snapshot.settings.activityCorrections
        let ownedIDs = Set(snapshot.actuals.filter {
            ActualRecord.userOwned($0, activityCorrections: corrections)
        }.map(\.id))
        let fresh = RestaurantMealActualEngine.records(
            restaurants: settings.frequentPlaces,
            readings: readings,
            watchSummaries: watchSummaries,
            watchAccelerationSamples: watchAccelerationSamples,
            inside: span
        ).filter { !snapshot.settings.suppressedActualIDs.contains($0.id) && !ownedIDs.contains($0.id) }
        snapshot.actuals.removeAll { actual in
            guard actual.source == .location,
                  !ownedIDs.contains(actual.id),
                  actual.span(asOf: span.end).intersection(with: span) != nil
            else { return false }
            return isAutomaticRestaurantMeal(actual)
        }
        guard !fresh.isEmpty else { return }
        snapshot.actuals.append(contentsOf: fresh)
        snapshot.actuals.sort { $0.startedAt < $1.startedAt }
    }
}
