import CoreLocation
import Foundation
import TaptionPlanEngine

/// 휴대폰 점수형 수면(SLP1110A01)을 앱 기록으로 바꾼다. 화면·충전 표본이 없어도(위치를 끈 밤)
/// iOS 동작 기록으로 판정한다. 워치·HealthKit 수면이나 다른 휴대폰 수면이 있는 밤에는 쓰지 않는다.
enum PhoneSleepScoreAdapter {
    static let modelVersion = ClassifierPipeline.modelVersion("sleep-score")
    /// 개인 수면 시간대를 배우는 기간.
    static let learningDays = 30

    static func records(
        night: TimeSpan,
        readings: [SensorReading],
        motionActivities: [MotionActivityRecord],
        actuals: [ActualRecord],
        homePoint: GeoPoint?,
        homeRadiusMeters: Double,
        wearableSleepSpans: [TimeSpan],
        asOf: Date = .now,
        createdAt: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ActualRecord] {
        guard night.start < asOf else { return [] }
        let clipped = TimeSpan(start: night.start, end: min(night.end, asOf))
        let otherSleep = actuals.filter {
            AutomaticRecordTimelineEngine.isSleep($0) && !AutomaticModelVersion.matches($0.modelVersion, modelVersion)
        }.map { $0.span(asOf: asOf) } + wearableSleepSpans
        guard !otherSleep.contains(where: { $0.intersection(with: clipped) != nil }) else { return [] }

        let signals = PhoneSleepScore.Signals(
            night: interval(clipped),
            wakeEvents: wakeEvents(readings: readings, motionActivities: motionActivities, actuals: actuals, inside: clipped, asOf: asOf),
            stillEvents: motionActivities.filter { $0.motion == .stationary }.map { interval($0.span) },
            samples: readings.filter { clipped.contains($0.timestamp) && $0.sourceDevice != .appleWatch }.map { reading in
                PhoneSleepScore.Sample(
                    timestamp: reading.timestamp,
                    screenIsOn: reading.screenIsOn,
                    isCharging: reading.powerState.map(\.isCharging),
                    isAtHome: homePoint.flatMap { home in
                        reading.point.map { distance($0, home) <= max(homeRadiusMeters, 150) }
                    }
                )
            },
            usualWindow: PhoneSleepScore.usualWindow(pastSleeps: pastWatchSleeps(actuals, before: night.start, calendar: calendar), calendar: calendar)
        )
        guard let verdict = PhoneSleepScore.evaluate(signals, calendar: calendar), verdict.isSleep,
              SleepFusion.acceptsPhoneOnly(verdict.interval, calendar: calendar) else { return [] }
        return [ActualRecord(
            id: ActivityStableID.uuid(seed: "\(modelVersion)|\(verdict.interval.start.timeIntervalSince1970)|\(verdict.interval.end.timeIntervalSince1970)"),
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: verdict.interval.start,
            endedAt: verdict.interval.end,
            source: .motion,
            confidence: ConfidenceLevel(score: min(0.9, Double(verdict.score) / 100)),
            createdAt: createdAt,
            behavior: "sleep-score",
            evidence: ["휴대폰 수면 점수 \(verdict.score)"] + verdict.factors,
            modelVersion: modelVersion
        )]
    }

    /// 깨어 있던 근거. 걷기·차 동작은 구간, 휴대폰을 집어 들어 동작 기록이 바뀐 순간은 길이 0으로 넣는다.
    static func wakeEvents(
        readings: [SensorReading],
        motionActivities: [MotionActivityRecord],
        actuals: [ActualRecord],
        inside night: TimeSpan,
        asOf: Date
    ) -> [ClassifierInterval] {
        var events: [ClassifierInterval] = []
        for activity in motionActivities {
            switch activity.motion {
            case .walking, .running, .cycling, .automotive:
                events.append(interval(activity.span))
            case .stationary, .unknown:
                events.append(ClassifierInterval(start: activity.span.start, end: activity.span.start))
                events.append(ClassifierInterval(start: activity.span.end, end: activity.span.end))
            }
        }
        for reading in readings where night.contains(reading.timestamp) && reading.sourceDevice != .appleWatch {
            if reading.screenIsOn == true || (reading.stepCount ?? 0) > 0
                || [.walking, .running, .cycling, .automotive].contains(reading.motion) {
                events.append(ClassifierInterval(start: reading.timestamp, end: reading.timestamp))
            }
        }
        for actual in actuals where actual.source == .appUsage || AutomaticRecordTimelineEngine.isConfirmedWorkout(actual) {
            let span = actual.span(asOf: asOf)
            if span.intersection(with: night) != nil { events.append(interval(span)) }
        }
        return events
    }

    /// 워치·HealthKit이 잰 지난 밤들(최근 30일). 평소 잠드는·깨는 시각을 배운다.
    static func pastWatchSleeps(_ actuals: [ActualRecord], before date: Date, calendar: Calendar) -> [ClassifierInterval] {
        let earliest = calendar.date(byAdding: .day, value: -learningDays, to: date) ?? date
        return actuals.filter {
            ($0.source == .healthKit || $0.source == .appleWatch) && AutomaticRecordTimelineEngine.isSleep($0)
                && $0.startedAt >= earliest && $0.startedAt < date
        }
        .compactMap { actual in actual.endedAt.map { ClassifierInterval(start: actual.startedAt, end: $0) } }
    }

    private static func interval(_ span: TimeSpan) -> ClassifierInterval {
        ClassifierInterval(start: span.start, end: span.end)
    }

    private static func distance(_ lhs: GeoPoint, _ rhs: GeoPoint) -> Double {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
            .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
    }
}
