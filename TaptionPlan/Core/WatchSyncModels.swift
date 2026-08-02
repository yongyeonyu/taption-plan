import Foundation

enum TaptionWatchCommandKind: String, Codable, CaseIterable, Sendable {
    case start
    case complete
    case postponeThirtyMinutes
    case skip
    case stopCurrentActivity
}

struct TaptionWatchCommand: Codable, Hashable, Sendable {
    var id: UUID
    var planID: UUID
    var kind: TaptionWatchCommandKind
    var requestedAt: Date

    init(
        id: UUID = UUID(),
        planID: UUID,
        kind: TaptionWatchCommandKind,
        requestedAt: Date = .now
    ) {
        self.id = id
        self.planID = planID
        self.kind = kind
        self.requestedAt = requestedAt
    }
}

enum TaptionWatchWorkoutKind: String, Codable, CaseIterable, Sendable {
    case walking
    case running
    case cycling

    var title: String {
        switch self {
        case .walking: "걷기"
        case .running: "달리기"
        case .cycling: "자전거"
        }
    }

    var symbolName: String {
        switch self {
        case .walking: "figure.walk"
        case .running: "figure.run"
        case .cycling: "bicycle"
        }
    }
}

/// Fine-grained behavior labels shared by the Watch and iPhone.  The Watch
/// emits a conservative label from the current sensor window; the iPhone can
/// later replace it with a trained Core ML result without changing the archive
/// format.
enum WatchBehaviorKind: String, Codable, CaseIterable, Sendable {
    case stationary
    case standing
    case sitting
    case lying
    case walking
    case running
    case cycling
    case stairsUp
    case stairsDown
    case elevator
    case automotive
    case publicTransit
    case subway
    case exercise
    case brushingTeeth
    case eating
    case typing
    case housework
    case sleep
    case unknown

    var title: String {
        switch self {
        case .stationary: "정지·휴식"
        case .standing: "서기"
        case .sitting: "앉기"
        case .lying: "눕기"
        case .walking: "걷기"
        case .running: "달리기"
        case .cycling: "자전거"
        case .stairsUp: "계단 오르기"
        case .stairsDown: "계단 내려가기"
        case .elevator: "엘리베이터"
        case .automotive: "자동차"
        case .publicTransit: "대중교통"
        case .subway: "지하철"
        case .exercise: "운동"
        case .brushingTeeth: "양치"
        case .eating: "식사"
        case .typing: "타이핑"
        case .housework: "집안일"
        case .sleep: "수면"
        case .unknown: "활동"
        }
    }

    var isMovement: Bool {
        switch self {
        case .walking, .running, .cycling, .stairsUp, .stairsDown,
             .elevator, .automotive, .publicTransit, .subway:
            true
        default:
            false
        }
    }
}

struct WatchBehaviorInference: Codable, Hashable, Sendable {
    var kind: WatchBehaviorKind
    var confidenceScore: Double
    var evidence: [String]
    var modelVersion: String
}

struct WatchBehaviorInput: Hashable, Sendable {
    var workoutKind: TaptionWatchWorkoutKind?
    var duration: TimeInterval
    var accelerometerSampleCount: Int
    var accelerometerStandardDeviationG: Double?
    var accelerometerMeanJerkGPerSecond: Double?
    var peakAccelerationG: Double?
    var peakRotationRateRadiansPerSecond: Double?
    var steps: Int?
    var distanceMeters: Double?
    var floorsAscended: Int?
    var floorsDescended: Int?
    var averageHeartRate: Double?
    var gpsAverageSpeedMetersPerSecond: Double?
    var gpsAvailable: Bool
    var gpsLossRatio: Double
    var altitudeDeltaMeters: Double?
    var nearRailContext: Bool
    var repeatedStops: Bool
    var accelerationBodyRMSG: Double?
    var accelerationZeroCrossingRateHz: Double?
    var dominantMotionFrequencyHz: Double?
    var gyroscopeRMSG: Double?
    var posturePitchRadians: Double?
    var postureRollRadians: Double?

    init(
        workoutKind: TaptionWatchWorkoutKind? = nil,
        duration: TimeInterval,
        accelerometerSampleCount: Int = 0,
        accelerometerStandardDeviationG: Double? = nil,
        accelerometerMeanJerkGPerSecond: Double? = nil,
        peakAccelerationG: Double? = nil,
        peakRotationRateRadiansPerSecond: Double? = nil,
        steps: Int? = nil,
        distanceMeters: Double? = nil,
        floorsAscended: Int? = nil,
        floorsDescended: Int? = nil,
        averageHeartRate: Double? = nil,
        gpsAverageSpeedMetersPerSecond: Double? = nil,
        gpsAvailable: Bool = false,
        gpsLossRatio: Double = 1,
        altitudeDeltaMeters: Double? = nil,
        nearRailContext: Bool = false,
        repeatedStops: Bool = false,
        accelerationBodyRMSG: Double? = nil,
        accelerationZeroCrossingRateHz: Double? = nil,
        dominantMotionFrequencyHz: Double? = nil,
        gyroscopeRMSG: Double? = nil,
        posturePitchRadians: Double? = nil,
        postureRollRadians: Double? = nil
    ) {
        self.workoutKind = workoutKind
        self.duration = duration
        self.accelerometerSampleCount = accelerometerSampleCount
        self.accelerometerStandardDeviationG = accelerometerStandardDeviationG
        self.accelerometerMeanJerkGPerSecond = accelerometerMeanJerkGPerSecond
        self.peakAccelerationG = peakAccelerationG
        self.peakRotationRateRadiansPerSecond = peakRotationRateRadiansPerSecond
        self.steps = steps
        self.distanceMeters = distanceMeters
        self.floorsAscended = floorsAscended
        self.floorsDescended = floorsDescended
        self.averageHeartRate = averageHeartRate
        self.gpsAverageSpeedMetersPerSecond = gpsAverageSpeedMetersPerSecond
        self.gpsAvailable = gpsAvailable
        self.gpsLossRatio = gpsLossRatio
        self.altitudeDeltaMeters = altitudeDeltaMeters
        self.nearRailContext = nearRailContext
        self.repeatedStops = repeatedStops
        self.accelerationBodyRMSG = accelerationBodyRMSG
        self.accelerationZeroCrossingRateHz = accelerationZeroCrossingRateHz
        self.dominantMotionFrequencyHz = dominantMotionFrequencyHz
        self.gyroscopeRMSG = gyroscopeRMSG
        self.posturePitchRadians = posturePitchRadians
        self.postureRollRadians = postureRollRadians
    }
}

struct WatchMotionSample: Hashable, Sendable {
    var capturedAt: Date
    var acceleration: TaptionWatchSensorVector3
    var rotationRate: TaptionWatchSensorVector3?
    var gravity: TaptionWatchSensorVector3?

    var accelerationMagnitude: Double {
        sqrt(acceleration.x * acceleration.x
            + acceleration.y * acceleration.y
            + acceleration.z * acceleration.z)
    }
    var rotationMagnitude: Double {
        guard let rotationRate else { return 0 }
        return sqrt(rotationRate.x * rotationRate.x
            + rotationRate.y * rotationRate.y
            + rotationRate.z * rotationRate.z)
    }
}

struct WatchBehaviorWindowFeatures: Hashable, Sendable {
    var startedAt: Date
    var endedAt: Date
    var sampleCount: Int
    var sampleRateHz: Double
    var accelerationMeanG: Double
    var accelerationStandardDeviationG: Double
    var bodyAccelerationRMSG: Double
    var jerkRMSGPerSecond: Double
    var zeroCrossingRateHz: Double
    var dominantFrequencyHz: Double?
    var gyroscopeRMSGPerSecond: Double
    var posturePitchRadians: Double?
    var postureRollRadians: Double?

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

struct WatchBehaviorSegment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var behavior: WatchBehaviorKind
    var confidenceScore: Double
    var evidence: [String]
    var modelVersion: String

    init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        behavior: WatchBehaviorKind,
        confidenceScore: Double,
        evidence: [String],
        modelVersion: String
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = max(startedAt, endedAt)
        self.behavior = behavior
        self.confidenceScore = min(1, max(0, confidenceScore))
        self.evidence = Array(Set(evidence)).sorted()
        self.modelVersion = modelVersion
    }

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

enum WatchBehaviorWindowAnalyzer {
    static let windowDuration: TimeInterval = 2.56
    static let strideDuration: TimeInterval = 1.28

    static func features(
        from samples: [WatchMotionSample]
    ) -> WatchBehaviorWindowFeatures? {
        let ordered = samples.sorted { $0.capturedAt < $1.capturedAt }
        guard let first = ordered.first, let last = ordered.last,
              ordered.count >= 8 else { return nil }
        let duration = last.capturedAt.timeIntervalSince(first.capturedAt)
        guard duration >= 1.5 else { return nil }

        let acceleration = ordered.map(\.accelerationMagnitude)
        let body = acceleration.map { abs($0 - 1) }
        let rotation = ordered.map(\.rotationMagnitude)
        let sampleRate = Double(ordered.count - 1) / duration
        let accelerationMean = mean(acceleration)
        let accelerationStd = standardDeviation(acceleration)
        let bodyRMS = sqrt(mean(body.map { $0 * $0 }))
        let jerk = zip(body.dropFirst(), body).map { current, previous in
            abs(current - previous) * sampleRate
        }
        let jerkRMS = jerk.isEmpty
            ? 0
            : sqrt(mean(jerk.map { $0 * $0 }))
        let centered = body.map { $0 - mean(body) }
        let crossings = zip(centered.dropFirst(), centered).reduce(0) {
            $0 + (($1.0 >= 0) != ($1.1 >= 0) ? 1 : 0)
        }
        let pitch = ordered.compactMap { sample -> Double? in
            guard let gravity = sample.gravity else { return nil }
            return atan2(gravity.y, gravity.z)
        }
        let roll = ordered.compactMap { sample -> Double? in
            guard let gravity = sample.gravity else { return nil }
            return atan2(-gravity.x, sqrt(gravity.y * gravity.y + gravity.z * gravity.z))
        }
        return WatchBehaviorWindowFeatures(
            startedAt: first.capturedAt,
            endedAt: last.capturedAt,
            sampleCount: ordered.count,
            sampleRateHz: sampleRate,
            accelerationMeanG: accelerationMean,
            accelerationStandardDeviationG: accelerationStd,
            bodyAccelerationRMSG: bodyRMS,
            jerkRMSGPerSecond: jerkRMS,
            zeroCrossingRateHz: Double(crossings) / duration / 2,
            dominantFrequencyHz: dominantFrequency(body, sampleRate: sampleRate),
            gyroscopeRMSGPerSecond: sqrt(mean(rotation.map { $0 * $0 })),
            posturePitchRadians: pitch.isEmpty ? nil : mean(pitch),
            postureRollRadians: roll.isEmpty ? nil : mean(roll)
        )
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let average = mean(values)
        let variance = values.reduce(0) { partial, value in
            partial + (value - average) * (value - average)
        } / Double(values.count - 1)
        return sqrt(max(0, variance))
    }

    private static func dominantFrequency(
        _ values: [Double],
        sampleRate: Double
    ) -> Double? {
        guard values.count >= 12, sampleRate > 0 else { return nil }
        let centered = values.map { $0 - mean(values) }
        let minimumLag = max(2, Int(sampleRate / 3.5))
        let maximumLag = min(
            centered.count / 2,
            max(minimumLag, Int(sampleRate / 0.35))
        )
        guard minimumLag <= maximumLag else { return nil }
        var bestLag = minimumLag
        var bestCorrelation = -Double.infinity
        for lag in minimumLag...maximumLag {
            let lhs = centered.dropLast(lag)
            let rhs = centered.dropFirst(lag)
            let correlation = zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }
        return sampleRate / Double(bestLag)
    }
}

/// A deterministic baseline that is safe to run on the Watch.  It deliberately
/// prefers false negatives over inventing fine-grained actions.  A future
/// bundled Core ML model can be inserted before this fallback and report its
/// own modelVersion/evidence.
enum WatchBehaviorClassifier {
    static let rulesVersion = "watch-har-v2"

    static func classifyWindow(
        _ features: WatchBehaviorWindowFeatures,
        context: WatchBehaviorInput
    ) -> WatchBehaviorInference {
        let inference = classify(
            WatchBehaviorInput(
                // A workout session identifies the broad activity, but the
                // 2.56-second window is what separates walking, stairs and
                // hand actions inside that session.  Keep the workout kind
                // as the final fallback in makeSensorSummary instead of
                // short-circuiting this classifier.
                workoutKind: nil,
                duration: features.duration,
                accelerometerSampleCount: features.sampleCount,
                accelerometerStandardDeviationG:
                    features.accelerationStandardDeviationG,
                accelerometerMeanJerkGPerSecond:
                    features.jerkRMSGPerSecond,
                peakAccelerationG: nil,
                peakRotationRateRadiansPerSecond:
                    features.gyroscopeRMSGPerSecond,
                steps: context.steps,
                distanceMeters: context.distanceMeters,
                floorsAscended: context.floorsAscended,
                floorsDescended: context.floorsDescended,
                averageHeartRate: context.averageHeartRate,
                gpsAverageSpeedMetersPerSecond:
                    context.gpsAverageSpeedMetersPerSecond,
                gpsAvailable: context.gpsAvailable,
                gpsLossRatio: context.gpsLossRatio,
                altitudeDeltaMeters: context.altitudeDeltaMeters,
                nearRailContext: context.nearRailContext,
                repeatedStops: context.repeatedStops,
                accelerationBodyRMSG: features.bodyAccelerationRMSG,
                accelerationZeroCrossingRateHz: features.zeroCrossingRateHz,
                dominantMotionFrequencyHz: features.dominantFrequencyHz,
                gyroscopeRMSG: features.gyroscopeRMSGPerSecond,
                posturePitchRadians: features.posturePitchRadians,
                postureRollRadians: features.postureRollRadians
            )
        )
        guard let workoutKind = context.workoutKind else { return inference }
        let lowSignal = features.bodyAccelerationRMSG < 0.04
            && features.gyroscopeRMSGPerSecond < 0.15
        guard inference.kind == .unknown
            || (inference.kind == .stationary && lowSignal) else {
            return inference
        }
        let fallback: WatchBehaviorKind = switch workoutKind {
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        }
        return result(
            fallback,
            score: 0.72,
            evidence: ["Apple Watch 운동 종류", "창 센서 근거 부족"]
        )
    }

    static func aggregate(
        _ segments: [WatchBehaviorSegment],
        fallback: WatchBehaviorInference
    ) -> WatchBehaviorInference {
        guard let segment = segments.max(by: {
            if $0.duration != $1.duration { return $0.duration < $1.duration }
            return $0.confidenceScore < $1.confidenceScore
        }) else { return fallback }
        return WatchBehaviorInference(
            kind: segment.behavior,
            confidenceScore: segment.confidenceScore,
            evidence: Array(Set(segment.evidence + ["2.56초 IMU 창"])).sorted(),
            modelVersion: segment.modelVersion
        )
    }

    static func classify(_ input: WatchBehaviorInput) -> WatchBehaviorInference {
        if let workoutKind = input.workoutKind {
            let kind: WatchBehaviorKind = switch workoutKind {
            case .walking: .walking
            case .running: .running
            case .cycling: .cycling
            }
            return result(
                kind,
                score: 0.97,
                evidence: ["Apple Watch 운동 종류", "HealthKit 운동 세션"]
            )
        }

        let duration = max(1, input.duration)
        let steps = max(0, input.steps ?? 0)
        let cadence = Double(steps) / duration
        let speed = input.gpsAverageSpeedMetersPerSecond ?? 0
        let altitude = abs(input.altitudeDeltaMeters ?? 0)
        let floorsUp = max(0, input.floorsAscended ?? 0)
        let floorsDown = max(0, input.floorsDescended ?? 0)
        let hasSteps = steps >= 4 || cadence >= 0.15
        let acceleration = input.accelerationBodyRMSG
            ?? input.accelerometerStandardDeviationG
            ?? 0
        let jerk = input.accelerometerMeanJerkGPerSecond ?? 0
        let measuredFrequency = input.dominantMotionFrequencyHz ?? 0
        // Magnitude-only IMU signals mirror each gait cycle, so the strongest
        // autocorrelation peak can be the second harmonic. Fold it back to a
        // cadence-like frequency before applying walking/running thresholds.
        let cadenceHz = measuredFrequency > 2.8 && measuredFrequency < 5.5
            ? measuredFrequency / 2
            : measuredFrequency
        let zeroCrossing = input.accelerationZeroCrossingRateHz ?? 0
        let gyro = input.gyroscopeRMSG ?? 0

        if floorsUp > 0 && hasSteps && altitude >= 1.2
            && (input.workoutKind == .walking || input.workoutKind == nil) {
            return result(
                .stairsUp,
                score: 0.84,
                evidence: ["상대고도 상승", "걸음·층수 증가", "창 기반 보행"]
            )
        }
        if floorsDown > 0 && hasSteps && altitude >= 1.2
            && (input.workoutKind == .walking || input.workoutKind == nil) {
            return result(
                .stairsDown,
                score: 0.84,
                evidence: ["상대고도 하강", "걸음·층수 감소", "창 기반 보행"]
            )
        }

        if altitude >= 2.5 && !hasSteps && jerk < 0.16 {
            return result(
                .elevator,
                score: 0.72,
                evidence: ["상대고도 변화", "걸음 거의 없음", "저진동"]
            )
        }

        if input.gpsLossRatio >= 0.45,
           !hasSteps,
           altitude >= 1.2,
           input.nearRailContext || input.repeatedStops {
            return result(
                .subway,
                score: 0.68,
                evidence: ["GPS 단절", "지하·철도 문맥", "걸음 거의 없음"]
            )
        }

        if speed >= 2.0, speed < 12, steps == 0, gyro >= 0.6 {
            return result(
                .cycling,
                score: 0.62,
                evidence: ["GPS 자전거 속도", "발걸음 없음", "손목 회전"]
            )
        }

        if speed >= 5.5 && !hasSteps {
            let kind: WatchBehaviorKind = input.repeatedStops
                ? .publicTransit
                : .automotive
            return result(
                kind,
                score: input.repeatedStops ? 0.64 : 0.78,
                evidence: ["GPS 차량 속도", "걸음 거의 없음"]
                    + (input.repeatedStops ? ["반복 정차"] : [])
            )
        }

        if speed >= 2.2 || cadence >= 1.75 || cadenceHz >= 2.2 {
            return result(
                .running,
                score: 0.81,
                evidence: ["속도·케이던스 달리기 범위", "IMU 주기성"]
            )
        }
        if speed >= 0.5 || cadence >= 0.15 || (cadenceHz >= 1.0 && acceleration >= 0.04) {
            return result(
                .walking,
                score: 0.79,
                evidence: ["GPS·걸음 보행 범위", "IMU 보행 주기"]
            )
        }

        if steps == 0, speed < 0.5, gyro >= 1.4, acceleration >= 0.025 {
            return result(
                .brushingTeeth,
                score: 0.56,
                evidence: ["반복 손목 회전", "걸음 없음", "저속"]
            )
        }
        if steps == 0, speed < 0.5, gyro >= 0.15, acceleration < 0.12,
           zeroCrossing >= 0.35 {
            return result(
                .typing,
                score: 0.5,
                evidence: ["미세 손목 움직임", "걸음 없음", "짧은 진동 창"]
            )
        }
        if steps == 0, speed < 0.5, acceleration >= 0.025,
           acceleration < 0.2, cadenceHz > 0.2, cadenceHz < 1.0 {
            return result(
                .eating,
                score: 0.45,
                evidence: ["느린 반복 손동작", "걸음 없음", "저속 주기성"]
            )
        }

        if acceleration >= 0.08 || jerk >= 0.25,
           (input.averageHeartRate ?? 0) >= 105 {
            return result(
                .exercise,
                score: 0.58,
                evidence: ["가속도 변화", "심박 상승"]
            )
        }
        if input.accelerometerSampleCount > 0,
           acceleration < 0.02,
           jerk < 0.08,
           !hasSteps {
            return result(
                .stationary,
                score: 0.55,
                evidence: ["저진동", "걸음 없음"]
            )
        }
        return result(.unknown, score: 0.25, evidence: ["센서 근거 부족"])
    }

    private static func result(
        _ kind: WatchBehaviorKind,
        score: Double,
        evidence: [String]
    ) -> WatchBehaviorInference {
        WatchBehaviorInference(
            kind: kind,
            confidenceScore: min(1, max(0, score)),
            evidence: evidence,
            modelVersion: rulesVersion
        )
    }
}

enum TaptionWatchWorkoutRequestAction: String, Codable, Sendable {
    case start
    case stop
}

struct TaptionWatchWorkoutRequest: Codable, Hashable, Sendable {
    var id: UUID
    var sessionID: UUID
    var action: TaptionWatchWorkoutRequestAction
    var kind: TaptionWatchWorkoutKind
    var linkedPlanID: UUID?
    var requestedAt: Date

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        action: TaptionWatchWorkoutRequestAction,
        kind: TaptionWatchWorkoutKind,
        linkedPlanID: UUID? = nil,
        requestedAt: Date = .now
    ) {
        self.id = id
        self.sessionID = sessionID
        self.action = action
        self.kind = kind
        self.linkedPlanID = linkedPlanID
        self.requestedAt = requestedAt
    }
}

struct TaptionWatchPlanItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var categoryID: String
    var startsAt: Date
    var endsAt: Date
    var status: String
    var actualStartedAt: Date?
    var categoryName: String?
    var categoryHex: String?
    /// Goals and their child plans are both sent to the Watch.  Keeping this
    /// bit on the item lets the Watch distinguish the two without having to
    /// re-read the phone's plan hierarchy.
    var isGoal: Bool = false
    var parentID: UUID? = nil

    private enum CodingKeys: String, CodingKey {
        case id, title, categoryID, startsAt, endsAt, status
        case actualStartedAt, categoryName, categoryHex, isGoal, parentID
    }

    init(
        id: UUID,
        title: String,
        categoryID: String,
        startsAt: Date,
        endsAt: Date,
        status: String,
        actualStartedAt: Date?,
        categoryName: String?,
        categoryHex: String?,
        isGoal: Bool = false,
        parentID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.categoryID = categoryID
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.status = status
        self.actualStartedAt = actualStartedAt
        self.categoryName = categoryName
        self.categoryHex = categoryHex
        self.isGoal = isGoal
        self.parentID = parentID
    }

    /// Older cached Watch payloads predate goal metadata.  Decode those
    /// payloads as ordinary plans instead of dropping the entire payload.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        categoryID = try container.decode(String.self, forKey: .categoryID)
        startsAt = try container.decode(Date.self, forKey: .startsAt)
        endsAt = try container.decode(Date.self, forKey: .endsAt)
        status = try container.decode(String.self, forKey: .status)
        actualStartedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .actualStartedAt
        )
        categoryName = try container.decodeIfPresent(
            String.self,
            forKey: .categoryName
        )
        categoryHex = try container.decodeIfPresent(
            String.self,
            forKey: .categoryHex
        )
        isGoal = try container.decodeIfPresent(Bool.self, forKey: .isGoal)
            ?? false
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
    }
}

/// The Watch receives a live window, not a historical archive.  A goal that
/// started earlier is retained while it is still active, but anything that
/// has ended or was completed/skipped is never sent to the Watch UI.
enum TaptionWatchLiveItemPolicy {
    static func isLive(_ item: TaptionWatchPlanItem, at date: Date) -> Bool {
        guard item.endsAt > date else { return false }
        return item.status == "planned" || item.status == "running"
    }

    static func current(
        _ items: [TaptionWatchPlanItem],
        at date: Date
    ) -> [TaptionWatchPlanItem] {
        items
            .filter {
                isLive($0, at: date)
                    && $0.startsAt <= date
                    && date < $0.endsAt
            }
            .sorted(by: sort)
    }

    static func upcoming(
        _ items: [TaptionWatchPlanItem],
        at date: Date
    ) -> [TaptionWatchPlanItem] {
        items
            .filter { isLive($0, at: date) && $0.startsAt > date }
            .sorted(by: sort)
    }

    private static func sort(
        _ lhs: TaptionWatchPlanItem,
        _ rhs: TaptionWatchPlanItem
    ) -> Bool {
        if lhs.startsAt != rhs.startsAt {
            return lhs.startsAt < rhs.startsAt
        }
        // Goals are shown before their child plans when they start together.
        if lhs.isGoal != rhs.isGoal {
            return lhs.isGoal && !rhs.isGoal
        }
        return lhs.title.localizedStandardCompare(rhs.title)
            == .orderedAscending
    }
}

struct TaptionWatchDaySummary: Codable, Hashable, Sendable {
    var date: Date
    var scheduledCount: Int
    var completedCount: Int
    var recordedMinutes: Int
    var activeMinutes: Int
}

struct TaptionWatchPayload: Codable, Hashable, Sendable {
    var generatedAt: Date
    var viewportStart: Date
    var viewportEnd: Date
    var items: [TaptionWatchPlanItem]
    var catStyle: String
    var reducesMotion: Bool
    var todaySummary: TaptionWatchDaySummary? = nil
}

struct TaptionWatchSensorVector3: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var z: Double
}

struct TaptionWatchLocationPoint: Codable, Hashable, Sendable {
    var id: UUID
    var capturedAt: Date
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var horizontalAccuracy: Double
    var verticalAccuracy: Double
    var speedMetersPerSecond: Double?
    var courseDegrees: Double?
}

/// A cumulative, battery-conscious summary of the sensors collected during an
/// explicit Apple Watch workout. The Watch samples motion locally and sends a
/// summary periodically instead of streaming every high-frequency event.
struct TaptionWatchSensorSummary: Identifiable, Codable, Hashable, Sendable {
    var id: UUID { sessionID }
    var sessionID: UUID
    var sequence: Int
    var workoutKind: TaptionWatchWorkoutKind
    var linkedPlanID: UUID?
    var linkedPlanTitle: String?
    var linkedCategoryID: String?
    var startedAt: Date
    var endedAt: Date
    var isFinal: Bool

    var accelerometerSampleCount: Int
    var accelerometerAverageG: TaptionWatchSensorVector3?
    var peakAccelerationG: Double?
    /// Window statistics used to distinguish rail vibration from footsteps.
    /// Optional so summaries written by older builds remain readable.
    var accelerometerStandardDeviationG: Double? = nil
    var accelerometerMeanJerkGPerSecond: Double? = nil
    var gyroscopeSampleCount: Int
    var gyroscopeAverageRadiansPerSecond: TaptionWatchSensorVector3?
    var peakRotationRateRadiansPerSecond: Double?
    var gravity: TaptionWatchSensorVector3?
    var userAccelerationG: TaptionWatchSensorVector3?
    var rotationRateRadiansPerSecond: TaptionWatchSensorVector3?
    var attitudeRadians: TaptionWatchSensorVector3?

    var relativeAltitudeMeters: Double?
    var pressureKilopascals: Double?
    var stepCount: Int?
    var distanceMeters: Double?
    var floorsAscended: Int?
    var floorsDescended: Int?

    var latestHeartRate: Double?
    var averageHeartRate: Double?
    var maximumHeartRate: Double?
    var activeEnergyKilocalories: Double?
    var routePoints: [TaptionWatchLocationPoint]?
    /// Rule/Core ML output for this 30-second sensor chunk. Optional for
    /// backwards compatibility with summaries already queued on either side.
    var behavior: WatchBehaviorKind? = nil
    var behaviorConfidenceScore: Double? = nil
    var behaviorEvidence: [String]? = nil
    var behaviorModelVersion: String? = nil
    var behaviorSegments: [WatchBehaviorSegment]? = nil
    /// Low-power accelerometer capture outside an explicit workout session.
    /// Optional so summaries queued by older Watch builds remain readable.
    var isAmbient: Bool? = nil
}

enum TaptionWatchEnvelope {
    static let payloadKey = "taption.watch.payload"
    static let commandKey = "taption.watch.command"
    static let sensorSummaryKey = "taption.watch.sensor-summary"
    static let workoutRequestKey = "taption.watch.workout-request"
    static let refreshRequestKey = "taption.watch.refresh-request"
    static let acceptedKey = "taption.watch.accepted"
}

enum TaptionWatchHealthMetadata {
    static let planID = "com.taption.plan.planID"
    static let planTitle = "com.taption.plan.planTitle"
    static let categoryID = "com.taption.plan.categoryID"
    static let sensorSessionID = "com.taption.plan.sensorSessionID"
}
