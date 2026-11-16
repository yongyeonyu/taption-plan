import Foundation
import TaptionPlanCore

/// 휴대폰 수면 판정(충전·정지, 점수형). 하루 자동 분류가 부른다(RFT1116A03).
extension AppModel {
    func applyChargingInactivitySleepRecords(
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
    func applyPhoneSleepScoreRecords(
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
}
