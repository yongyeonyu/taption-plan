import Foundation
import TaptionPlanEngine

/// HealthKit·Watch 수면 기록을 보완할 때 충전 중인 iPhone의
/// 무활동을 수면 후보로 쓴다. 원본 센서와 앱 사용 기록은 그대로
/// 두고, 한 시간 이상 이어진 구간만 수정 불가 파생 기록으로 만든다.
enum ChargingInactivitySleepEngine {
    static let modelVersion = AutomaticModelVersion.phoneSleep
    static let minimumDuration: TimeInterval = 60 * 60

    static func records(
        readings: [SensorReading],
        actuals: [ActualRecord],
        inside span: TimeSpan,
        watchAvailable: Bool,
        maximumSampleGap: TimeInterval,
        asOf: Date = .now
    ) -> [ActualRecord] {
        guard !watchAvailable else { return [] }
        let observed = TimeSpan(start: span.start, end: min(span.end, asOf))
        guard observed.duration >= minimumDuration else { return [] }
        // 걸음 수는 누적값이다. 낮에 걸은 만큼 쌓인 값이 아니라 표본 사이 늘어난 만큼을 본다.
        var lastSteps: Int?
        let samples = readings
            .filter {
                RouteTimelineTimestamp.isValid($0.timestamp)
                    && observed.contains($0.timestamp)
            }
            .sorted { $0.timestamp < $1.timestamp }
            .filter { reading in
                let increase = reading.stepCount.flatMap { count in
                    lastSteps.map { DeviceStepCounter.stepIncrease(from: $0, to: count) }
                } ?? 0
                lastSteps = reading.stepCount ?? lastSteps
                return isInactiveCharging(reading, stepIncrease: increase)
            }
        guard samples.count >= 3 else { return [] }

        let allowedGap = max(20 * 60, maximumSampleGap)
        var runs: [[SensorReading]] = []
        for sample in samples {
            if let last = runs.last?.last,
               sample.timestamp.timeIntervalSince(last.timestamp) <= allowedGap {
                runs[runs.count - 1].append(sample)
            } else {
                runs.append([sample])
            }
        }
        let blockers = actuals.compactMap { actual -> TimeSpan? in
            guard actual.source == .appUsage
                    || AutomaticRecordTimelineEngine.isSleep(actual)
                    || AutomaticRecordTimelineEngine.isConfirmedWorkout(actual)
                    || ActualRecordCategoryResolver.categoryID(for: actual)
                        == "movement" else {
                return nil
            }
            return actual.span(asOf: asOf).intersection(with: observed)
        }

        return runs.flatMap { run -> [TimeSpan] in
            guard run.count >= 3,
                  let first = run.first?.timestamp,
                  let last = run.last?.timestamp,
                  last.timeIntervalSince(first) >= minimumDuration else {
                return []
            }
            return ActualIntervalMergeEngine.subtracting(
                blockers,
                from: TimeSpan(start: first, end: last)
            ).filter { $0.duration >= minimumDuration }
        }.map { value in
            ActualRecord(
                id: stableID(value),
                planID: nil,
                title: "수면",
                categoryID: "sleep",
                startedAt: value.start,
                endedAt: value.end,
                source: .motion,
                confidence: .medium,
                createdAt: value.end,
                behavior: "charging-inactivity-sleep",
                evidence: ["iPhone 충전 중", "가속도·걸음·앱 사용 없음", "1시간 이상 지속"],
                modelVersion: modelVersion
            )
        }
    }

    private static func isInactiveCharging(_ reading: SensorReading, stepIncrease: Int) -> Bool {
        guard reading.powerState?.isCharging == true,
              stepIncrease <= 2 else { return false }
        if reading.motion == .stationary { return true }
        guard reading.motion == .unknown,
              let summary = reading.deviceMotionSummary,
              summary.sampleCount >= 2 else { return false }
        return summary.userAccelerationStandardDeviationG <= 0.01
            && summary.meanRotationRateRadiansPerSecond <= 0.03
    }

    private static func stableID(_ span: TimeSpan) -> UUID {
        let key = "\(modelVersion)|\(Int(span.start.timeIntervalSince1970))|\(Int(span.end.timeIntervalSince1970))"
        var hash: UInt64 = 14_695_981_039_346_656_037
        var bytes = [UInt8](repeating: 0, count: 16)
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        for index in bytes.indices {
            hash = (hash ^ UInt64(index + 1)) &* 1_099_511_628_211
            bytes[index] = UInt8(truncatingIfNeeded: hash >> ((index % 8) * 8))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// Infers sleep and wake transitions from iPhone-only observations. A sleep
/// candidate needs five minutes of inactivity while the display is dark/off;
/// the candidate is confirmed after one hour (or thirty minutes when charging)
/// and starts at the expected-sleep timestamp. A wake candidate follows the
/// same explicit one-hour confirmation and is cancelled when the phone settles
/// again, allowing an interrupted sleep to continue.
enum PhoneSleepWakeEngine {
    static let modelVersion = AutomaticModelVersion.phoneSleep
    static let inactivityDuration: TimeInterval = 5 * 60
    static let confirmationDuration: TimeInterval = 60 * 60
    static let chargingConfirmationDuration: TimeInterval = 30 * 60
    static let wakeConfirmationDuration: TimeInterval = 60 * 60
    /// 화면 켜짐이나 걸음 증가 같은 강한 깸 신호가 있으면 이 시간만 이어져도 기상으로 확정한다.
    static let fastWakeConfirmationDuration: TimeInterval = 15 * 60
    static let fastWakeStepIncrease = 30
    static let darkBrightness = 0.25
    static let brightBrightness = 0.60

    static func records(
        readings: [SensorReading],
        actuals: [ActualRecord],
        inside span: TimeSpan,
        watchAvailable: Bool,
        maximumSampleGap: TimeInterval,
        asOf: Date = .now
    ) -> [ActualRecord] {
        guard !watchAvailable else { return [] }
        let observed = readings
            .filter {
                RouteTimelineTimestamp.isValid($0.timestamp)
                    && span.contains($0.timestamp)
                    && $0.timestamp <= asOf
            }
            .sorted { $0.timestamp < $1.timestamp }
        guard observed.count >= 2 else { return [] }

        let blockers = actuals.compactMap { actual -> TimeSpan? in
            guard actual.source == .appUsage
                    || AutomaticRecordTimelineEngine.isSleep(actual)
                    || ActualRecordCategoryResolver.categoryID(for: actual) == "movement" else {
                return nil
            }
            return actual.span(asOf: asOf).intersection(with: span)
        }
        var state = InferenceState()
        var sleepSpans: [TimeSpan] = []
        var previous: SensorReading?
        for reading in observed {
            if let previous,
               reading.timestamp.timeIntervalSince(previous.timestamp) > maximumSampleGap {
                state.sleepCandidateStart = nil
                state.wakeCandidateStart = nil
            }
            let wasSleeping = state.sleepStartedAt
            advance(
                &state,
                reading: reading,
                previous: previous,
                maximumSampleGap: maximumSampleGap,
                blocked: blockers.contains { $0.contains(reading.timestamp) }
            )
            if let started = wasSleeping,
               state.sleepStartedAt == nil,
               let wakeExpected = state.lastWakeExpectedAt,
               wakeExpected > started {
                sleepSpans.append(TimeSpan(start: started, end: wakeExpected))
                state.lastWakeExpectedAt = nil
            }
            previous = reading
        }
        if let started = state.sleepStartedAt,
           let last = observed.last?.timestamp,
           last > started {
            sleepSpans.append(TimeSpan(start: started, end: min(last, asOf)))
        }

        return sleepSpans
            .filter { $0.duration >= chargingConfirmationDuration }
            .map { span in
                ActualRecord(
                    id: stableID(for: span),
                    planID: nil,
                    title: "수면",
                    categoryID: "sleep",
                    startedAt: span.start,
                    endedAt: span.end,
                    source: .motion,
                    confidence: .medium,
                    createdAt: span.end,
                    behavior: "iphone-sleep",
                    evidence: [
                        "iPhone 가속도·걸음 무활동",
                        "화면 꺼짐·어두움",
                        "수면 예상 1시간 확인",
                    ],
                    modelVersion: modelVersion
                )
            }
    }

    private struct InferenceState {
        var sleepCandidateStart: Date?
        var sleepExpectedAt: Date?
        var sleepStartedAt: Date?
        var sleepCharging = false
        var wakeCandidateStart: Date?
        var wakeCandidateSteps: Int?
        var lastWakeExpectedAt: Date?
        var lastStepCount: Int?
    }

    private static func advance(
        _ state: inout InferenceState,
        reading: SensorReading,
        previous: SensorReading?,
        maximumSampleGap: TimeInterval,
        blocked: Bool = false
    ) {
        if let previous,
           reading.timestamp.timeIntervalSince(previous.timestamp) > maximumSampleGap {
            state.sleepCandidateStart = nil
            state.wakeCandidateStart = nil
        }
        let stepsSincePrevious = reading.stepCount.flatMap { count in
            state.lastStepCount.map { DeviceStepCounter.stepIncrease(from: $0, to: count) }
        } ?? 0
        state.lastStepCount = reading.stepCount ?? state.lastStepCount

        if state.sleepStartedAt != nil {
            if isWakeSignal(reading, stepIncrease: stepsSincePrevious) {
                if state.wakeCandidateStart == nil { state.wakeCandidateSteps = reading.stepCount }
                state.wakeCandidateStart = state.wakeCandidateStart ?? reading.timestamp
                state.lastWakeExpectedAt = state.wakeCandidateStart
                let elapsed = reading.timestamp.timeIntervalSince(state.wakeCandidateStart ?? reading.timestamp)
                let stepIncrease = (reading.stepCount ?? 0) - (state.wakeCandidateSteps ?? reading.stepCount ?? 0)
                let strongWake = reading.screenIsOn == true || stepIncrease >= fastWakeStepIncrease
                if elapsed >= wakeConfirmationDuration
                    || (strongWake && elapsed >= fastWakeConfirmationDuration) {
                    state.sleepStartedAt = nil
                    state.sleepExpectedAt = nil
                    state.sleepCandidateStart = nil
                    state.sleepCharging = false
                    state.wakeCandidateStart = nil
                    state.wakeCandidateSteps = nil
                }
            } else if isSleepSignal(reading, stepIncrease: stepsSincePrevious) || blocked {
                // A brief awakening that settles before confirmation is part
                // of the same sleep session; a later movement can start a new
                // wake candidate.
                state.wakeCandidateStart = nil
                state.wakeCandidateSteps = nil
                state.lastWakeExpectedAt = nil
            }
            return
        }

        guard !blocked, isSleepSignal(reading, stepIncrease: stepsSincePrevious) else {
            state.sleepCandidateStart = nil
            state.sleepExpectedAt = nil
            state.sleepCharging = false
            return
        }
        let candidateStart = state.sleepCandidateStart ?? reading.timestamp
        state.sleepCandidateStart = candidateStart
        let expectedAt = candidateStart.addingTimeInterval(inactivityDuration)
        guard reading.timestamp >= expectedAt else { return }
        if state.sleepExpectedAt == nil {
            state.sleepExpectedAt = expectedAt
            state.sleepCharging = reading.powerState?.isCharging == true
        }
        let confirmation = state.sleepCharging
            ? chargingConfirmationDuration
            : confirmationDuration
        guard reading.timestamp.timeIntervalSince(expectedAt) >= confirmation else {
            return
        }
        state.sleepStartedAt = expectedAt
        state.wakeCandidateStart = nil
    }

    private static func isSleepSignal(_ reading: SensorReading, stepIncrease: Int) -> Bool {
        let inactive: Bool
        switch reading.motion {
        case .stationary: inactive = true
        case .unknown:
            let summary = reading.deviceMotionSummary
            inactive = stepIncrease <= 2
                && (summary == nil
                    || (summary?.userAccelerationStandardDeviationG ?? 1) <= 0.01
                    && (summary?.meanRotationRateRadiansPerSecond ?? 1) <= 0.03)
        default: inactive = false
        }
        // Older background archives often omit display telemetry entirely.
        // A missing brightness value must not turn an otherwise continuous
        // stationary run into an awake run; an explicit screen-on signal is
        // still treated as wake evidence below.
        let screenOff = reading.screenIsOn == false
            || (reading.screenIsOn == nil && reading.screenBrightness == nil)
        let dark = reading.screenBrightness.map { $0 <= darkBrightness }
            ?? screenOff
        return inactive && screenOff && dark
    }

    private static func isWakeSignal(_ reading: SensorReading, stepIncrease: Int) -> Bool {
        reading.motion.isMovement
            || stepIncrease > 0
            || reading.screenIsOn == true
            || reading.screenBrightness.map { $0 >= brightBrightness } == true
    }

    private static func stableID(for span: TimeSpan) -> UUID {
        let key = "\(modelVersion)|\(Int(span.start.timeIntervalSince1970))|\(Int(span.end.timeIntervalSince1970))"
        var hash: UInt64 = 14_695_981_039_346_656_037
        var bytes = [UInt8](repeating: 0, count: 16)
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        for index in bytes.indices {
            hash = (hash ^ UInt64(index + 1)) &* 1_099_511_628_211
            bytes[index] = UInt8(truncatingIfNeeded: hash >> ((index % 8) * 8))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
            bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
