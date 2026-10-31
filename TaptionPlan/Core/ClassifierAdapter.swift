import Foundation
import TaptionPlanEngine

extension ActualRecord {
    /// 사용자가 직접 만들거나 고친 기록. 자동 재계산이 바꾸지 않는다.
    /// 교정표를 먼저 보고, 한국어 근거 문구는 예전 기록을 위한 대체 경로로만 쓴다.
    static func userOwned(
        _ actual: ActualRecord,
        activityCorrections: [UUID: ActivityCorrection] = [:]
    ) -> Bool {
        if actual.source == .manual || actual.manuallyCorrected
            || actual.lockReason == .user
            || activityCorrections[actual.id] != nil {
            return true
        }
        return actual.evidence.contains {
            $0.contains("사용자 확인") || $0.contains("사용자 교정")
        }
    }

    /// 새로 잠글 때의 이유: 사용자 소유면 user, 아니면 파이프라인이 바뀔 때 풀리는 stability.
    var defaultLockReason: ActualLockReason {
        Self.userOwned(self) ? .user : .stability
    }
}

extension ActivityClassificationLockEngine {
    /// 분류 파이프라인이 바뀐 날을 다시 만들기 전에, 사용자 소유가 아닌 자동
    /// 기록의 안정 잠금을 푼다. 사용자 기록·수동 기록은 그대로 둔다.
    static func releasingStabilityLocks(
        _ actuals: [ActualRecord],
        inside span: TimeSpan,
        activityCorrections: [UUID: ActivityCorrection]
    ) -> (records: [ActualRecord], released: Int) {
        var released = 0
        let records = actuals.map { actual -> ActualRecord in
            guard actual.isClassificationLocked,
                  actual.source.usesAutomaticClassification,
                  actual.span(asOf: span.end).intersection(with: span) != nil,
                  !ActualRecord.userOwned(actual, activityCorrections: activityCorrections)
            else { return actual }
            var value = actual
            value.isClassificationLocked = false
            value.lockReason = nil
            released += 1
            return value
        }
        return (records, released)
    }
}

/// 날짜별 재계산 표식. 앱 저장소에 `migration_markers`가 생기면 그쪽으로 바꾼다.
protocol ClassificationRecomputeMarkerStore: AnyObject, Sendable {
    func isCompleted(_ key: String) -> Bool
    func markCompleted(_ key: String)
}

final class UserDefaultsClassificationRecomputeMarkers: ClassificationRecomputeMarkerStore, Sendable {
    static let defaultsKey = "classifierRecomputeMarkers.v1"
    /// UserDefaults는 Sendable이 아니라 이름만 들고 매번 연다(nil이면 standard).
    private let suiteName: String?
    private let lock = NSLock()

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func isCompleted(_ key: String) -> Bool {
        lock.withLock { (defaults.stringArray(forKey: Self.defaultsKey) ?? []).contains(key) }
    }

    func markCompleted(_ key: String) {
        lock.withLock {
            var keys = defaults.stringArray(forKey: Self.defaultsKey) ?? []
            guard !keys.contains(key) else { return }
            keys.append(key)
            defaults.set(keys, forKey: Self.defaultsKey)
        }
    }
}

/// 분류 파이프라인이 바뀐 뒤 과거 자동 분류를 날짜별로 한 번만 다시 만든다.
///
/// 원본이 부족한 날은 기존 결과를 그대로 두고 표식만 남긴다(`skippedNoRaw`).
/// 원본이 있으면 사용자 소유가 아닌 자동 기록의 안정 잠금을 풀고 다시 분류한다.
/// 실패·취소한 날은 표식을 남기지 않아 다음에 이어 한다.
struct ClassificationRecomputeCoordinator: Sendable {
    enum Outcome: String, Sendable {
        case recomputed
        case skippedNoRaw = "skipped-no-raw"
        case alreadyDone
        case failed
        case cancelled
    }

    let markers: any ClassificationRecomputeMarkerStore

    /// 앱 기본값: UserDefaults 표식. 시험 실행에서는 nil(시험이 직접 만든다).
    static var automatic: ClassificationRecomputeCoordinator? {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            ? ClassificationRecomputeCoordinator(markers: UserDefaultsClassificationRecomputeMarkers())
            : nil
    }

    /// 원본이 충분하면 그날 사용자 소유가 아닌 자동 기록의 안정 잠금을 푼다.
    /// 부족하면 기존 결과를 그대로 둔다. 되돌림은 갱신 전 스냅숏이 맡는다.
    static func prepare(
        _ actuals: [ActualRecord],
        rawSampleCount: Int,
        inside span: TimeSpan,
        activityCorrections: [UUID: ActivityCorrection]
    ) -> (records: [ActualRecord], outcome: Outcome) {
        guard TaptionClassifier.hasEnoughRawData(sampleCount: rawSampleCount) else {
            return (actuals, .skippedNoRaw)
        }
        let released = ActivityClassificationLockEngine.releasingStabilityLocks(
            actuals, inside: span, activityCorrections: activityCorrections
        )
        TaptionPlanDiagnosticsLogger.shared.record(
            "classifier_recompute_released",
            fields: ["released": String(released.released)]
        )
        return (released.records, .recomputed)
    }

    /// 갱신이 성공한 뒤에만 표식을 남긴다. 실패·취소한 날은 다음에 이어 한다.
    func complete(_ outcome: Outcome?, day: Date) {
        // 오늘은 원본이 아직 쌓이는 중이라 '원본 부족'으로 닫지 않는다.
        guard let outcome, outcome != .skippedNoRaw || !Calendar.autoupdatingCurrent.isDateInToday(day) else { return }
        markers.markCompleted(Self.markerKey(for: day))
        TaptionPlanDiagnosticsLogger.shared.record(
            "classifier_recompute_day",
            fields: ["outcome": outcome.rawValue]
        )
    }

    static func markerKey(for day: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%@:%04d-%02d-%02d", ClassifierPipeline.version, parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func needsRecompute(_ day: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        !markers.isCompleted(Self.markerKey(for: day, calendar: calendar))
    }

    /// 최신 날부터 하나씩. `rawSampleCount`·`recompute`는 앱이 넘긴다.
    func run(
        days: [Date],
        calendar: Calendar = .autoupdatingCurrent,
        rawSampleCount: (Date) async -> Int,
        recompute: (Date) async -> Bool
    ) async -> [(day: Date, outcome: Outcome)] {
        let ordered = Array(Set(days.map { calendar.startOfDay(for: $0) })).sorted(by: >)
        var results: [(day: Date, outcome: Outcome)] = []
        for day in ordered {
            guard !Task.isCancelled else {
                results.append((day, .cancelled))
                continue
            }
            let key = Self.markerKey(for: day, calendar: calendar)
            guard !markers.isCompleted(key) else {
                results.append((day, .alreadyDone))
                continue
            }
            guard TaptionClassifier.hasEnoughRawData(sampleCount: await rawSampleCount(day)) else {
                markers.markCompleted(key)
                results.append((day, .skippedNoRaw))
                continue
            }
            if await recompute(day) {
                markers.markCompleted(key)
                results.append((day, .recomputed))
            } else {
                results.append((day, Task.isCancelled ? .cancelled : .failed))
            }
        }
        return results
    }
}

/// 분류 패키지(`TaptionClassifierEngine`)와 앱 모델 사이의 어댑터. UI는 엔진을
/// 모르므로 걸음·외출 같은 파생 지표도 여기서 앱 타입으로 돌려준다.
enum ClassifierAdapter {
    /// 하루 갱신에서 실제로 들여다본 원본의 시간 범위.
    static func sensorEvidenceSpan(
        readings: [SensorReading],
        activities: [MotionActivityRecord],
        inside span: TimeSpan
    ) -> TimeSpan? {
        let moments = readings.map(\.timestamp)
            + activities.flatMap { [$0.span.start, $0.span.end] }
        guard let start = moments.min(), let end = moments.max() else {
            return nil
        }
        return TimeSpan(start: start, end: end).intersection(with: span)
    }

    static func interval(_ span: TimeSpan) -> ClassifierInterval {
        ClassifierInterval(start: span.start, end: span.end)
    }

    /// 원본 판독을 그대로 옮긴다(값을 고치지 않는다).
    static func sample(_ reading: SensorReading) -> ClassifierSample {
        let motion: MotionHint = switch reading.motion {
        case .stationary: .stationary
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        case .automotive: .automotive
        case .unknown: .unknown
        }
        return ClassifierSample(
            timestamp: reading.timestamp,
            point: reading.point.map { ClassifierPoint(latitude: $0.latitude, longitude: $0.longitude) },
            horizontalAccuracy: reading.point?.horizontalAccuracy,
            speed: reading.speedMetersPerSecond,
            course: reading.courseDegrees,
            pressureKilopascals: reading.pressureKilopascals,
            accelerationStandardDeviationG: reading.deviceMotionSummary?.userAccelerationStandardDeviationG
                ?? reading.watchAccelerationStandardDeviationG,
            accelerationJerkGPerSecond: reading.watchAccelerationMeanJerkGPerSecond,
            rotationRate: reading.deviceMotionSummary?.meanRotationRateRadiansPerSecond,
            motion: motion,
            nearTransitStop: reading.frequentStops || reading.matchesPublicTransitRoute,
            nearRailStation: reading.nearbyStation || reading.matchesRailRoute,
            nearAirport: reading.nearAirport,
            onWater: reading.onWater,
            isCharging: reading.powerState.map(\.isCharging),
            screenIsOn: reading.screenIsOn,
            screenBrightness: reading.screenBrightness,
            stepCadence: reading.currentCadenceStepsPerSecond
        )
    }

    static func travelMode(_ mode: TransportMode) -> TravelMode? {
        switch mode {
        case .stationary: nil
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        case .car: .car
        case .bus: .bus
        case .subway: .subway
        case .train: .train
        case .ship: .ship
        case .airplane: .airplane
        }
    }

    /// 하루 수단 구간을 앱 타입으로(정지는 mode nil). 시험·진단이 패키지 타입을 몰라도 된다.
    static func travelTimeline(readings: [SensorReading], in span: TimeSpan) throws -> [(span: TimeSpan, mode: TravelMode?, meters: Double)] {
        try classifyDay(readings: readings, in: span).segments.map {
            (TimeSpan(start: $0.interval.start, end: $0.interval.end), travelMode($0.mode), $0.distanceMeters)
        }
    }

    /// 하루 원본으로 수단 구간을 만든다. 취소는 `Task.checkCancellation`을 따른다.
    static func classifyDay(readings: [SensorReading], in span: TimeSpan) throws -> ClassifierDayOutput {
        try TaptionClassifier.classifyDay(
            ClassifierDayInput(day: interval(span), samples: readings.map(sample)),
            cancellation: { try Task.checkCancellation() }
        )
    }

    /// 기기별 하루 누적 걸음을 구간 증가분으로 바꿔, 워치가 덮은 시간은 워치 걸음만,
    /// 나머지 시간은 아이폰 걸음을 더한다(아이폰·워치 max 금지).
    static func stepCount(readings: [SensorReading], in span: TimeSpan) -> Int? {
        let samples = Dictionary(grouping: readings.filter { ($0.stepCount ?? 0) > 0 }) {
            $0.sourceDevice == .appleWatch
        }.flatMap { isWatch, values -> [StepSample] in
            let ordered = values.sorted { $0.timestamp < $1.timestamp }
            var previous: (time: Date, steps: Int)?
            return ordered.compactMap { reading in
                let steps = reading.stepCount ?? 0
                defer { previous = (reading.timestamp, steps) }
                guard let last = previous else {
                    return StepSample(interval: ClassifierInterval(start: reading.timestamp, end: reading.timestamp), count: Double(steps), device: isWatch ? .appleWatch : .iPhone)
                }
                // 누적값이 줄면 측정이 다시 시작된 것이다. 그 값 전체가 새 걸음이다.
                let delta = steps >= last.steps ? steps - last.steps : steps
                guard delta > 0 else { return nil }
                return StepSample(interval: ClassifierInterval(start: last.time, end: reading.timestamp), count: Double(delta), device: isWatch ? .appleWatch : .iPhone)
            }
        }
        guard !samples.isEmpty else { return nil }
        let total = DayMetrics.steps(samples, in: interval(span))
        return total > 0 ? Int(total.rounded()) : nil
    }

    /// 외출 시간 = 집 밖 체류 + 이동. 기록 공백은 외출로 세지 않는다.
    static func awaySeconds(stays: [PlaceStay], travel: [TravelSegment], homeKeys: Set<String>, in span: TimeSpan) -> TimeInterval? {
        guard !homeKeys.isEmpty, !stays.isEmpty, span.duration > 0 else { return nil }
        let away = DayMetrics.away(
            home: stays.filter { homeKeys.contains($0.placeKey) }.map { interval($0.span) },
            elsewhere: stays.filter { !homeKeys.contains($0.placeKey) }.map { interval($0.span) },
            travel: travel.map { interval($0.span) },
            in: interval(span)
        )
        return away.awaySeconds
    }

    /// 날짜별 걸음: 건강 앱 값은 HealthKit이 이미 기기 간 겹침을 정리한 합계라 우선한다.
    /// 건강 앱 값이 없는 날만 센서 값을 쓴다(둘의 max는 다른 시간의 걸음을 버린다).
    static func mergedDailySteps(health: [Date: Double], sensor: [Date: Double]) -> [Date: Double] {
        health.filter { $0.value > 0 }.merging(sensor.filter { $0.value > 0 }) { health, _ in health }
    }
}
