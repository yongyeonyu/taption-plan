import Foundation
import TaptionPlanCore

// 워치 행동 규칙 분류·가속도 창 특징·활동 확인. CoreML 모델은 `TaptionWatchBehaviorML`에 있다.

/// Fine-grained behavior labels shared by the Watch and iPhone.  The Watch
/// emits a conservative label from the current sensor window; the iPhone can
/// later replace it with a trained Core ML result without changing the archive
/// format.
public enum WatchBehaviorKind: String, Codable, CaseIterable, Sendable {
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
    case showering
    case sleep
    case unknown

    public var title: String {
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
        case .showering: "샤워"
        case .sleep: "수면"
        case .unknown: "활동"
        }
    }

    public func localizedTitle(
        _ language: AppLanguagePreference.ResolvedLanguage =
            AppLanguagePreference.current.resolvedLanguage
    ) -> String {
        switch language {
        case .korean:
            return title
        case .english:
            return switch self {
            case .stationary: "Resting"
            case .standing: "Standing"
            case .sitting: "Sitting"
            case .lying: "Lying down"
            case .walking: "Walking"
            case .running: "Running"
            case .cycling: "Cycling"
            case .stairsUp: "Going upstairs"
            case .stairsDown: "Going downstairs"
            case .elevator: "Elevator"
            case .automotive: "In a car"
            case .publicTransit: "Public transit"
            case .subway: "Subway"
            case .exercise: "Exercise"
            case .brushingTeeth: "Brushing teeth"
            case .eating: "Eating"
            case .typing: "Typing"
            case .housework: "Housework"
            case .showering: "Showering"
            case .sleep: "Sleeping"
            case .unknown: "Activity"
            }
        }
    }

    /// Watch에서 사용자가 고를 수 있는 확정 활동. 모델 내부의 `unknown`은
    /// 사용자 선택지로 노출하지 않는다.
    public static let confirmationChoices: [WatchBehaviorKind] = [
        .sleep,
        .walking, .running, .cycling, .stairsUp, .stairsDown, .elevator,
        .automotive, .publicTransit, .subway,
        .exercise,
        .showering, .housework, .brushingTeeth, .eating, .typing,
        .standing, .sitting, .lying, .stationary,
    ]

    public var isMovement: Bool {
        switch self {
        case .walking, .running, .cycling, .stairsUp, .stairsDown,
             .elevator, .automotive, .publicTransit, .subway:
            true
        default:
            false
        }
    }

    public var systemImage: String {
        switch self {
        case .stationary: "pause.circle.fill"
        case .standing: "figure.stand"
        case .sitting: "figure.seated.side"
        case .lying: "bed.double.fill"
        case .walking: "figure.walk"
        case .running: "figure.run"
        case .cycling: "bicycle"
        case .stairsUp, .stairsDown: "figure.stairs"
        case .elevator: "arrow.up.arrow.down"
        case .automotive: "car.fill"
        case .publicTransit: "bus.fill"
        case .subway: "tram.fill"
        case .exercise: "figure.strengthtraining.traditional"
        case .brushingTeeth: "toothbrush.fill"
        case .eating: "fork.knife"
        case .typing: "keyboard"
        case .housework: "washer.fill"
        case .showering: "shower.fill"
        case .sleep: "bed.double.fill"
        case .unknown: "sparkles"
        }
    }

    public static func fromModelLabel(_ label: String) -> WatchBehaviorKind? {
        let normalized = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return allCases.first {
            $0.rawValue.lowercased() == normalized
                || $0.title.lowercased() == normalized
        }
    }
}

public struct WatchBehaviorInference: Codable, Hashable, Sendable {
    public var kind: WatchBehaviorKind
    public var confidenceScore: Double
    public var evidence: [String]
    public var modelVersion: String

    public init(
        kind: WatchBehaviorKind,
        confidenceScore: Double,
        evidence: [String],
        modelVersion: String
    ) {
        self.kind = kind
        self.confidenceScore = confidenceScore
        self.evidence = evidence
        self.modelVersion = modelVersion
    }
}

public struct WatchBehaviorInput: Hashable, Sendable {
    public var workoutKind: TaptionWatchWorkoutKind?
    public var duration: TimeInterval
    public var accelerometerSampleCount: Int
    public var accelerometerStandardDeviationG: Double?
    public var accelerometerMeanJerkGPerSecond: Double?
    public var peakAccelerationG: Double?
    public var peakRotationRateRadiansPerSecond: Double?
    public var steps: Int?
    public var distanceMeters: Double?
    public var floorsAscended: Int?
    public var floorsDescended: Int?
    public var averageHeartRate: Double?
    public var gpsAverageSpeedMetersPerSecond: Double?
    public var gpsAvailable: Bool
    public var gpsLossRatio: Double
    public var altitudeDeltaMeters: Double?
    public var nearRailContext: Bool
    public var repeatedStops: Bool
    public var accelerationBodyRMSG: Double?
    public var accelerationZeroCrossingRateHz: Double?
    public var dominantMotionFrequencyHz: Double?
    public var gyroscopeRMSG: Double?
    public var posturePitchRadians: Double?
    public var postureRollRadians: Double?

    public init(
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

public struct WatchMotionSample: Hashable, Sendable {
    public var capturedAt: Date
    public var acceleration: TaptionWatchSensorVector3
    public var rotationRate: TaptionWatchSensorVector3?
    public var gravity: TaptionWatchSensorVector3?

    public var accelerationMagnitude: Double {
        sqrt(acceleration.x * acceleration.x
            + acceleration.y * acceleration.y
            + acceleration.z * acceleration.z)
    }
    public var rotationMagnitude: Double {
        guard let rotationRate else { return 0 }
        return sqrt(rotationRate.x * rotationRate.x
            + rotationRate.y * rotationRate.y
            + rotationRate.z * rotationRate.z)
    }

    public init(
        capturedAt: Date,
        acceleration: TaptionWatchSensorVector3,
        rotationRate: TaptionWatchSensorVector3? = nil,
        gravity: TaptionWatchSensorVector3? = nil
    ) {
        self.capturedAt = capturedAt
        self.acceleration = acceleration
        self.rotationRate = rotationRate
        self.gravity = gravity
    }
}

/// Watch가 보관·전송하는 저전력 가속도 원본 표본. 요약의 파생값과
/// 분리해 두어, 날짜를 다시 열 때 현재 규칙으로 행동을 재생성할 수 있다.
public struct TaptionWatchAccelerationSample: Codable, Hashable, Sendable {
    public var id: UUID
    public var capturedAt: Date
    public var acceleration: TaptionWatchSensorVector3
    public var sessionID: UUID?
    public var sequence: Int
    public var isAmbient: Bool

    public init(
        id: UUID = UUID(),
        capturedAt: Date,
        acceleration: TaptionWatchSensorVector3,
        sessionID: UUID? = nil,
        sequence: Int,
        isAmbient: Bool
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.acceleration = acceleration
        self.sessionID = sessionID
        self.sequence = sequence
        self.isAmbient = isAmbient
    }
}

public struct WatchBehaviorWindowFeatures: Codable, Hashable, Sendable {
    public var startedAt: Date
    public var endedAt: Date
    public var sampleCount: Int
    public var sampleRateHz: Double
    public var accelerationMeanG: Double
    public var accelerationStandardDeviationG: Double
    public var bodyAccelerationRMSG: Double
    public var jerkRMSGPerSecond: Double
    public var zeroCrossingRateHz: Double
    public var dominantFrequencyHz: Double?
    public var gyroscopeRMSGPerSecond: Double
    public var posturePitchRadians: Double?
    public var postureRollRadians: Double?

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    /// Stable numeric layout shared with a future Create ML/Core ML model.
    /// Missing device signals are encoded as zero for low-power windows.
    public var featureVector: [Double] {
        [
            duration,
            sampleRateHz,
            Double(sampleCount),
            accelerationMeanG,
            accelerationStandardDeviationG,
            bodyAccelerationRMSG,
            jerkRMSGPerSecond,
            zeroCrossingRateHz,
            dominantFrequencyHz ?? 0,
            gyroscopeRMSGPerSecond,
            posturePitchRadians ?? 0,
            postureRollRadians ?? 0,
        ]
    }

    public static let featureSchemaVersion = "watch-har-window-v1"

    public init(
        startedAt: Date,
        endedAt: Date,
        sampleCount: Int,
        sampleRateHz: Double,
        accelerationMeanG: Double,
        accelerationStandardDeviationG: Double,
        bodyAccelerationRMSG: Double,
        jerkRMSGPerSecond: Double,
        zeroCrossingRateHz: Double,
        dominantFrequencyHz: Double? = nil,
        gyroscopeRMSGPerSecond: Double,
        posturePitchRadians: Double? = nil,
        postureRollRadians: Double? = nil
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sampleCount = sampleCount
        self.sampleRateHz = sampleRateHz
        self.accelerationMeanG = accelerationMeanG
        self.accelerationStandardDeviationG = accelerationStandardDeviationG
        self.bodyAccelerationRMSG = bodyAccelerationRMSG
        self.jerkRMSGPerSecond = jerkRMSGPerSecond
        self.zeroCrossingRateHz = zeroCrossingRateHz
        self.dominantFrequencyHz = dominantFrequencyHz
        self.gyroscopeRMSGPerSecond = gyroscopeRMSGPerSecond
        self.posturePitchRadians = posturePitchRadians
        self.postureRollRadians = postureRollRadians
    }
}

public struct WatchBehaviorSegment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var behavior: WatchBehaviorKind
    public var confidenceScore: Double
    public var evidence: [String]
    public var modelVersion: String

    public init(
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

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

public enum WatchBehaviorWindowAnalyzer {
    public static let windowDuration: TimeInterval = 2.56
    public static let strideDuration: TimeInterval = 1.28

    public static func features(
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
public enum WatchBehaviorClassifier {
    public static let rulesVersion = "watch-har-v2"

    public static func classifyWindow(
        _ features: WatchBehaviorWindowFeatures,
        context: WatchBehaviorInput,
        modelPrediction: WatchBehaviorInference? = nil
    ) -> WatchBehaviorInference {
        if let modelPrediction,
           modelPrediction.confidenceScore >= 0.55 {
            return modelPrediction
        }
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

    public static func aggregate(
        _ segments: [WatchBehaviorSegment],
        fallback: WatchBehaviorInference
    ) -> WatchBehaviorInference {
        guard !segments.isEmpty else { return fallback }
        let ordered = segments.sorted { $0.startedAt < $1.startedAt }
        var weightedDurations: [WatchBehaviorKind: Double] = [:]
        for segment in ordered {
            let duration = max(0.25, segment.duration)
            weightedDurations[segment.behavior, default: 0] +=
                duration * (0.5 + segment.confidenceScore)
        }
        guard let winningKind = weightedDurations.max(by: {
            if $0.value != $1.value { return $0.value < $1.value }
            return $0.key.rawValue < $1.key.rawValue
        })?.key else {
            return fallback
        }
        let winningSegments = ordered.filter { $0.behavior == winningKind }
        let totalWeight = winningSegments.reduce(0.0) { total, segment in
            total + max(0.25, segment.duration)
                * (0.5 + segment.confidenceScore)
        }
        let confidence = winningSegments.reduce(0.0) { total, segment in
            total + segment.confidenceScore
                * max(0.25, segment.duration)
                * (0.5 + segment.confidenceScore)
        } / max(0.25, totalWeight)
        let evidence = winningSegments.reduce(into: Set<String>()) {
            $0.formUnion($1.evidence)
        }
        return WatchBehaviorInference(
            kind: winningKind,
            confidenceScore: min(0.99, max(0, confidence)),
            evidence: Array(evidence + ["2.56초 IMU 창", "시간 가중 집계"]).sorted(),
            modelVersion: ordered.last?.modelVersion ?? fallback.modelVersion
        )
    }

    public static func classify(_ input: WatchBehaviorInput) -> WatchBehaviorInference {
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

/// 워치가 "지금 이걸 하고 있다"고 보여준 추정에 대한 사용자의 응답.
/// 콤플리케이션은 모든 것을 보여주기엔 너무 작으므로, 워치 앱은 이 확인과
/// 정정만 담당하고 실제 반영은 iPhone이 한다.
public struct TaptionWatchActivityConfirmation: Codable, Hashable, Sendable {
    public var id: UUID
    public var respondedAt: Date
    /// 워치가 보여준 추정의 시간 범위.
    public var observedStartedAt: Date
    public var observedEndedAt: Date
    public var isCorrect: Bool
    /// 계획 항목을 보여준 경우의 원본.
    public var observedPlanID: UUID?
    public var observedPlanTitle: String?
    /// 센서 추정을 보여준 경우의 원본.
    public var observedBehavior: WatchBehaviorKind?
    /// 사용자가 고른 실제 행동. `isCorrect`가 true면 nil이다.
    public var correctedBehavior: WatchBehaviorKind?
    /// iPhone이 만든 확인 요청과 센서 패턴. Watch가 독자적으로 후보를
    /// 만들지 않도록 요청 원본을 응답에 그대로 돌려보낸다.
    public var suggestionID: UUID?
    public var sensorSessionID: UUID?
    /// One-time capability issued with the iPhone suggestion. Old queued
    /// confirmations without it are rejected by the iPhone.
    public var confirmationToken: UUID?
    public var pattern: WatchActivityPattern?

    public init(
        id: UUID = UUID(),
        respondedAt: Date = .now,
        observedStartedAt: Date,
        observedEndedAt: Date,
        isCorrect: Bool,
        observedPlanID: UUID? = nil,
        observedPlanTitle: String? = nil,
        observedBehavior: WatchBehaviorKind? = nil,
        correctedBehavior: WatchBehaviorKind? = nil,
        suggestionID: UUID? = nil,
        sensorSessionID: UUID? = nil,
        confirmationToken: UUID? = nil,
        pattern: WatchActivityPattern? = nil
    ) {
        self.id = id
        self.respondedAt = respondedAt
        self.observedStartedAt = observedStartedAt
        self.observedEndedAt = max(observedStartedAt, observedEndedAt)
        self.isCorrect = isCorrect
        self.observedPlanID = observedPlanID
        self.observedPlanTitle = observedPlanTitle
        self.observedBehavior = observedBehavior
        self.correctedBehavior = isCorrect ? nil : correctedBehavior
        self.suggestionID = suggestionID
        self.sensorSessionID = sensorSessionID
        self.confirmationToken = confirmationToken
        self.pattern = pattern
    }
}

/// iPhone과 Watch의 문맥을 합친 개인화용 특징. 원시 센서 파일은 별도로
/// 보존하고 여기에는 비교에 필요한 요약값만 둔다.
public struct WatchActivityPattern: Codable, Hashable, Sendable {
    public var duration: TimeInterval
    public var accelerationVariationG: Double?
    public var jerkGPerSecond: Double?
    public var peakRotationRate: Double?
    public var stepsPerMinute: Double?
    public var averageHeartRate: Double?
    public var atHome: Bool
    public var waterLockEnabled: Bool
    public var observedBehavior: WatchBehaviorKind?

    public init(
        duration: TimeInterval,
        accelerationVariationG: Double? = nil,
        jerkGPerSecond: Double? = nil,
        peakRotationRate: Double? = nil,
        stepsPerMinute: Double? = nil,
        averageHeartRate: Double? = nil,
        atHome: Bool,
        waterLockEnabled: Bool,
        observedBehavior: WatchBehaviorKind? = nil
    ) {
        self.duration = duration
        self.accelerationVariationG = accelerationVariationG
        self.jerkGPerSecond = jerkGPerSecond
        self.peakRotationRate = peakRotationRate
        self.stepsPerMinute = stepsPerMinute
        self.averageHeartRate = averageHeartRate
        self.atHome = atHome
        self.waterLockEnabled = waterLockEnabled
        self.observedBehavior = observedBehavior
    }
}

public struct WatchActivityPatternSample: Codable, Hashable, Sendable {
    public var id: UUID
    public var capturedAt: Date
    public var pattern: WatchActivityPattern
    public var label: WatchBehaviorKind

    public init(
        id: UUID = UUID(),
        capturedAt: Date = .now,
        pattern: WatchActivityPattern,
        label: WatchBehaviorKind
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.pattern = pattern
        self.label = label
    }
}

public struct TaptionWatchActivitySuggestion: Identifiable, Codable, Hashable,
    Sendable {
    public var id: UUID
    public var confirmationToken: UUID?
    public var sensorSessionID: UUID
    public var generatedAt: Date
    public var startedAt: Date
    public var endedAt: Date
    public var proposedBehavior: WatchBehaviorKind
    public var alternativeBehaviors: [WatchBehaviorKind]
    public var confidenceScore: Double
    public var evidence: [String]
    public var pattern: WatchActivityPattern

    public init(
        id: UUID = UUID(),
        confirmationToken: UUID? = UUID(),
        sensorSessionID: UUID,
        generatedAt: Date = .now,
        startedAt: Date,
        endedAt: Date,
        proposedBehavior: WatchBehaviorKind,
        alternativeBehaviors: [WatchBehaviorKind],
        confidenceScore: Double,
        evidence: [String],
        pattern: WatchActivityPattern
    ) {
        self.id = id
        self.confirmationToken = confirmationToken
        self.sensorSessionID = sensorSessionID
        self.generatedAt = generatedAt
        self.startedAt = startedAt
        self.endedAt = max(startedAt, endedAt)
        self.proposedBehavior = proposedBehavior
        self.alternativeBehaviors = alternativeBehaviors.filter {
            $0 != proposedBehavior && $0 != .unknown
        }
        self.confidenceScore = min(1, max(0, confidenceScore))
        self.evidence = Array(Set(evidence)).sorted()
        self.pattern = pattern
    }
}
