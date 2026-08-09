import Foundation
#if canImport(CoreML)
import CoreML
#endif

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
    case showering
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
        case .showering: "샤워"
        case .sleep: "수면"
        case .unknown: "활동"
        }
    }

    /// Watch에서 사용자가 고를 수 있는 확정 활동. 모델 내부의 `unknown`은
    /// 사용자 선택지로 노출하지 않는다.
    static let confirmationChoices: [WatchBehaviorKind] = [
        .sleep,
        .walking, .running, .cycling, .stairsUp, .stairsDown, .elevator,
        .automotive, .publicTransit, .subway,
        .exercise,
        .showering, .housework, .brushingTeeth, .eating, .typing,
        .standing, .sitting, .lying, .stationary,
    ]

    var isMovement: Bool {
        switch self {
        case .walking, .running, .cycling, .stairsUp, .stairsDown,
             .elevator, .automotive, .publicTransit, .subway:
            true
        default:
            false
        }
    }

    var systemImage: String {
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

    static func fromModelLabel(_ label: String) -> WatchBehaviorKind? {
        let normalized = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return allCases.first {
            $0.rawValue.lowercased() == normalized
                || $0.title.lowercased() == normalized
        }
    }
}

struct WatchBehaviorInference: Codable, Hashable, Sendable {
    var kind: WatchBehaviorKind
    var confidenceScore: Double
    var evidence: [String]
    var modelVersion: String
}

#if canImport(CoreML)
/// Optional Create ML/Core ML bridge. The app works without a bundled model;
/// when `WatchActivityClassifier.mlmodelc` is present, its prediction wins
/// over the conservative rule fallback for the same sensor window.
@MainActor
final class WatchBehaviorModel {
    private let model: MLModel
    let modelVersion: String

    private init(model: MLModel, modelVersion: String) {
        self.model = model
        self.modelVersion = modelVersion
    }

    static func load(
        bundle: Bundle = .main,
        resource: String = "WatchActivityClassifier"
    ) -> WatchBehaviorModel? {
        guard let url = bundle.url(
            forResource: resource,
            withExtension: "mlmodelc"
        ), let model = try? MLModel(contentsOf: url) else {
            return nil
        }
        return WatchBehaviorModel(
            model: model,
            modelVersion: "core-ml-\(resource)"
        )
    }

    func predict(
        features: WatchBehaviorWindowFeatures
    ) -> WatchBehaviorInference? {
        guard let input = model.modelDescription.inputDescriptionsByName
            .first(where: { $0.value.type == .multiArray }),
            let array = try? MLMultiArray(
                shape: [NSNumber(value: features.featureVector.count)],
                dataType: .double
            ) else {
            return nil
        }
        for (index, value) in features.featureVector.enumerated() {
            array[index] = NSNumber(value: value)
        }
        guard let provider = try? MLDictionaryFeatureProvider(
            dictionary: [
                input.key: MLFeatureValue(multiArray: array),
            ]
        ), let output = try? model.prediction(from: provider) else {
            return nil
        }

        let label = output.featureValue(for: "classLabel")?.stringValue
            ?? output.featureValue(for: "label")?.stringValue
        let probabilities = output.featureValue(
            for: "classLabelProbs"
        )?.dictionaryValue.reduce(into: [String: Double]()) { result, item in
            result[String(describing: item.key)] = item.value.doubleValue
        }
        let best = probabilities?.max { $0.value < $1.value }
        let rawLabel = label ?? best?.key
        guard let rawLabel,
              let kind = WatchBehaviorKind.fromModelLabel(rawLabel) else {
            return nil
        }
        return WatchBehaviorInference(
            kind: kind,
            confidenceScore: min(0.99, max(0, best?.value ?? 0.7)),
            evidence: [
                "Core ML 활동 모델",
                "IMU 창 \(WatchBehaviorWindowFeatures.featureSchemaVersion)",
            ],
            modelVersion: modelVersion
        )
    }
}
#endif

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

struct WatchBehaviorWindowFeatures: Codable, Hashable, Sendable {
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

    /// Stable numeric layout shared with a future Create ML/Core ML model.
    /// Missing device signals are encoded as zero for low-power windows.
    var featureVector: [Double] {
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

    static let featureSchemaVersion = "watch-har-window-v1"
}

/// A labelled window for personal calibration or Create ML training.
/// Classifier guesses are never written back as labels.
struct WatchBehaviorTrainingSample: Codable, Hashable, Sendable {
    var id: UUID
    var capturedAt: Date
    var features: WatchBehaviorWindowFeatures
    var label: WatchBehaviorKind
    var source: String
    var labelConfidence: Double

    init(
        id: UUID = UUID(),
        capturedAt: Date,
        features: WatchBehaviorWindowFeatures,
        label: WatchBehaviorKind,
        source: String,
        labelConfidence: Double = 1
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.features = features
        self.label = label
        self.source = source
        self.labelConfidence = min(1, max(0, labelConfidence))
    }
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

    static func aggregate(
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

/// 워치가 "지금 이걸 하고 있다"고 보여준 추정에 대한 사용자의 응답.
/// 콤플리케이션은 모든 것을 보여주기엔 너무 작으므로, 워치 앱은 이 확인과
/// 정정만 담당하고 실제 반영은 iPhone이 한다.
struct TaptionWatchActivityConfirmation: Codable, Hashable, Sendable {
    var id: UUID
    var respondedAt: Date
    /// 워치가 보여준 추정의 시간 범위.
    var observedStartedAt: Date
    var observedEndedAt: Date
    var isCorrect: Bool
    /// 계획 항목을 보여준 경우의 원본.
    var observedPlanID: UUID?
    var observedPlanTitle: String?
    /// 센서 추정을 보여준 경우의 원본.
    var observedBehavior: WatchBehaviorKind?
    /// 사용자가 고른 실제 행동. `isCorrect`가 true면 nil이다.
    var correctedBehavior: WatchBehaviorKind?
    /// iPhone이 만든 확인 요청과 센서 패턴. Watch가 독자적으로 후보를
    /// 만들지 않도록 요청 원본을 응답에 그대로 돌려보낸다.
    var suggestionID: UUID?
    var sensorSessionID: UUID?
    var pattern: WatchActivityPattern?

    init(
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
        self.pattern = pattern
    }
}

/// iPhone과 Watch의 문맥을 합친 개인화용 특징. 원시 센서 파일은 별도로
/// 보존하고 여기에는 비교에 필요한 요약값만 둔다.
struct WatchActivityPattern: Codable, Hashable, Sendable {
    var duration: TimeInterval
    var accelerationVariationG: Double?
    var jerkGPerSecond: Double?
    var peakRotationRate: Double?
    var stepsPerMinute: Double?
    var averageHeartRate: Double?
    var atHome: Bool
    var waterLockEnabled: Bool
    var observedBehavior: WatchBehaviorKind?
}

struct WatchActivityPatternSample: Codable, Hashable, Sendable {
    var id: UUID
    var capturedAt: Date
    var pattern: WatchActivityPattern
    var label: WatchBehaviorKind

    init(
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

struct TaptionWatchActivitySuggestion: Identifiable, Codable, Hashable,
    Sendable {
    var id: UUID
    var sensorSessionID: UUID
    var generatedAt: Date
    var startedAt: Date
    var endedAt: Date
    var proposedBehavior: WatchBehaviorKind
    var alternativeBehaviors: [WatchBehaviorKind]
    var confidenceScore: Double
    var evidence: [String]
    var pattern: WatchActivityPattern

    init(
        id: UUID = UUID(),
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

struct WatchActivityResolution: Sendable {
    var learnedBehavior: WatchBehaviorInference?
    var suggestion: TaptionWatchActivitySuggestion?
}

/// 애매한 생활 행동은 사용자에게 묻고, 같은 패턴이 세 번 이상 같은 답을
/// 얻은 뒤에만 자동 확정한다. 운동 세션처럼 Apple이 이미 확정한 기록은
/// 이 경로를 거치지 않는다.
enum WatchActivityPersonalizationEngine {
    static let modelVersion = "watch-personal-v1"
    private static let minimumLearningSamples = 3

    static func pattern(
        from summary: TaptionWatchSensorSummary,
        atHome: Bool
    ) -> WatchActivityPattern {
        let duration = max(1, summary.endedAt.timeIntervalSince(
            summary.startedAt
        ))
        return WatchActivityPattern(
            duration: duration,
            accelerationVariationG: summary.accelerometerStandardDeviationG,
            jerkGPerSecond: summary.accelerometerMeanJerkGPerSecond,
            peakRotationRate: summary.peakRotationRateRadiansPerSecond,
            stepsPerMinute: summary.stepCount.map {
                Double($0) / max(1, duration / 60)
            },
            averageHeartRate: summary.averageHeartRate,
            atHome: atHome,
            waterLockEnabled: summary.waterLockEnabled == true,
            observedBehavior: summary.behavior
        )
    }

    static func resolve(
        _ summary: TaptionWatchSensorSummary,
        atHome: Bool,
        learnedSamples: [WatchActivityPatternSample],
        now: Date = .now
    ) -> WatchActivityResolution {
        guard summary.isAmbient == true else {
            return WatchActivityResolution(
                learnedBehavior: nil,
                suggestion: nil
            )
        }
        let pattern = pattern(from: summary, atHome: atHome)
        if let learned = learnedBehavior(
            for: pattern,
            samples: learnedSamples
        ) {
            return WatchActivityResolution(
                learnedBehavior: learned,
                suggestion: nil
            )
        }
        guard isSustainedMotion(pattern) else {
            return WatchActivityResolution(
                learnedBehavior: nil,
                suggestion: nil
            )
        }

        let proposal: (
            behavior: WatchBehaviorKind,
            alternatives: [WatchBehaviorKind],
            score: Double,
            evidence: [String]
        )?
        if atHome && pattern.waterLockEnabled && pattern.duration >= 60 {
            proposal = (
                .showering,
                [.housework],
                0.72,
                ["집 위치", "Water Lock 켜짐", "지속적인 손목 움직임"]
            )
        } else if atHome && summary.behavior?.isMovement != true {
            proposal = (
                .housework,
                [.showering, .brushingTeeth],
                max(0.55, min(0.74, summary.behaviorConfidenceScore ?? 0.6)),
                ["집 위치", "지속적인 손목 움직임"]
            )
        } else if let behavior = summary.behavior,
                  [.brushingTeeth, .eating, .typing, .housework]
                    .contains(behavior),
                  (summary.behaviorConfidenceScore ?? 0) < 0.85 {
            proposal = (
                behavior,
                [],
                summary.behaviorConfidenceScore ?? 0.55,
                summary.behaviorEvidence ?? ["Apple Watch 센서 추정"]
            )
        } else {
            proposal = nil
        }
        guard let proposal else {
            return WatchActivityResolution(
                learnedBehavior: nil,
                suggestion: nil
            )
        }
        return WatchActivityResolution(
            learnedBehavior: nil,
            suggestion: TaptionWatchActivitySuggestion(
                sensorSessionID: summary.sessionID,
                generatedAt: now,
                startedAt: summary.startedAt,
                endedAt: summary.endedAt,
                proposedBehavior: proposal.behavior,
                alternativeBehaviors: proposal.alternatives,
                confidenceScore: proposal.score,
                evidence: proposal.evidence,
                pattern: pattern
            )
        )
    }

    static func learnedBehavior(
        for pattern: WatchActivityPattern,
        samples: [WatchActivityPatternSample]
    ) -> WatchBehaviorInference? {
        let nearby = samples.compactMap { sample -> (
            WatchActivityPatternSample, Double
        )? in
            guard sample.pattern.atHome == pattern.atHome,
                  sample.pattern.waterLockEnabled
                    == pattern.waterLockEnabled else { return nil }
            let value = distance(pattern, sample.pattern)
            return value <= 1.5 ? (sample, value) : nil
        }
        .sorted { $0.1 < $1.1 }
        .prefix(8)
        guard nearby.count >= minimumLearningSamples else { return nil }

        var votes: [WatchBehaviorKind: Double] = [:]
        for (sample, distance) in nearby {
            votes[sample.label, default: 0] += 1 / (0.15 + distance)
        }
        guard let winner = votes.max(by: { $0.value < $1.value }) else {
            return nil
        }
        let total = votes.values.reduce(0, +)
        let confidence = total > 0 ? winner.value / total : 0
        guard confidence >= 0.8 else { return nil }
        return WatchBehaviorInference(
            kind: winner.key,
            confidenceScore: min(0.95, confidence),
            evidence: ["사용자 확인 패턴 \(nearby.count)회"],
            modelVersion: modelVersion
        )
    }

    private static func isSustainedMotion(
        _ pattern: WatchActivityPattern
    ) -> Bool {
        guard pattern.duration >= 20 else { return false }
        return (pattern.accelerationVariationG ?? 0) >= 0.018
            || (pattern.jerkGPerSecond ?? 0) >= 0.018
            || (pattern.stepsPerMinute ?? 0) >= 8
    }

    private static func distance(
        _ lhs: WatchActivityPattern,
        _ rhs: WatchActivityPattern
    ) -> Double {
        var values: [Double] = []
        func add(_ a: Double?, _ b: Double?, scale: Double) {
            guard let a, let b else { return }
            values.append(min(2, abs(a - b) / scale))
        }
        add(lhs.accelerationVariationG, rhs.accelerationVariationG, scale: 0.04)
        add(lhs.jerkGPerSecond, rhs.jerkGPerSecond, scale: 0.25)
        add(lhs.peakRotationRate, rhs.peakRotationRate, scale: 2)
        add(lhs.stepsPerMinute, rhs.stepsPerMinute, scale: 40)
        add(lhs.averageHeartRate, rhs.averageHeartRate, scale: 35)
        if let left = lhs.observedBehavior, let right = rhs.observedBehavior,
           left != right {
            values.append(0.35)
        }
        return values.isEmpty
            ? (lhs.observedBehavior == rhs.observedBehavior ? 0 : 2)
            : values.reduce(0, +) / Double(values.count)
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

/// 지금 무엇이 워치를 재고 있는지.
enum TaptionWatchMeasurementSource: String, Codable, Hashable, Sendable {
    /// 명시적 운동 세션. 25Hz로 가속도·자이로·심박을 함께 받는다.
    case workout
    /// `CMSensorRecorder`가 앱과 무관하게 남기는 배경 가속도 기록.
    case ambient
    /// 자동 기록이 꺼져 있거나 아직 아무것도 재지 않는 상태.
    case idle

    var title: String {
        switch self {
        case .workout: "운동 측정 중"
        case .ambient: "배경 기록 중"
        case .idle: "측정 대기"
        }
    }
}

/// 워치 앱이 앱 그룹에 남기는 "지금 재고 있는 것" 스냅숏.
///
/// 워치 위젯은 별도 프로세스라 워치 앱의 관측 상태를 직접 볼 수 없다.
/// 위젯이 현재 측정을 보여주려면 이 스냅숏만 읽으면 된다.
struct TaptionWatchMeasurementSnapshot: Codable, Hashable, Sendable {
    var updatedAt: Date
    var source: TaptionWatchMeasurementSource
    var behavior: WatchBehaviorKind?
    var confidenceScore: Double
    /// 마지막으로 분류된 구간의 끝. 위젯의 "n분 전"이 쓰는 값이다.
    var measuredAt: Date?
    /// iPhone 설정이 자동 가속도 기록을 켜 두었는가.
    var isRecordingRequested: Bool
    /// 이 워치에서 `CMSensorRecorder`를 실제로 쓸 수 있는가.
    var isRecorderAvailable: Bool
    var isMotionAccessDenied: Bool
    /// 기록 읽기가 예외로 끊긴 횟수(`ambient-drain-exception`).
    var drainFailureCount: Int
    /// 운동·기록 실패 문구. 워치 화면과 위젯이 같은 문장을 쓴다.
    var failureMessage: String?

    init(
        updatedAt: Date = .now,
        source: TaptionWatchMeasurementSource = .idle,
        behavior: WatchBehaviorKind? = nil,
        confidenceScore: Double = 0,
        measuredAt: Date? = nil,
        isRecordingRequested: Bool = false,
        isRecorderAvailable: Bool = false,
        isMotionAccessDenied: Bool = false,
        drainFailureCount: Int = 0,
        failureMessage: String? = nil
    ) {
        self.updatedAt = updatedAt
        self.source = source
        self.behavior = behavior
        self.confidenceScore = min(1, max(0, confidenceScore))
        self.measuredAt = measuredAt
        self.isRecordingRequested = isRecordingRequested
        self.isRecorderAvailable = isRecorderAvailable
        self.isMotionAccessDenied = isMotionAccessDenied
        self.drainFailureCount = max(0, drainFailureCount)
        self.failureMessage = failureMessage
    }
}

enum TaptionWatchAlertKind: String, Codable, Hashable, Sendable, CaseIterable {
    case recordingFailed
    case motionAccessDenied
    case recorderUnavailable
    case recordingGap
    case measurementStalled

    var symbolName: String {
        switch self {
        case .recordingFailed: "exclamationmark.triangle.fill"
        case .motionAccessDenied: "hand.raised.fill"
        case .recorderUnavailable: "sensor.tag.radiowaves.forward.fill"
        case .recordingGap: "chart.line.downtrend.xyaxis"
        case .measurementStalled: "clock.badge.exclamationmark.fill"
        }
    }
}

struct TaptionWatchAlert: Identifiable, Codable, Hashable, Sendable {
    var kind: TaptionWatchAlertKind
    var title: String
    var detail: String

    var id: String { kind.rawValue }
    var symbolName: String { kind.symbolName }
}

/// 워치가 사용자를 불러야 하는 상황만 고른다.
///
/// 새 알림 종류를 만들지 않는다. 이미 워치가 알고 있는 사실(기록 실패,
/// 권한, 읽기 예외, 마지막 측정 시각)만 문장으로 옮긴다. 알림 권한을
/// 새로 요구하지 않도록 결과는 화면과 위젯 안에서만 쓴다.
enum TaptionWatchAlertPolicy {
    /// `CMSensorRecorder`는 앱이 꺼져 있어도 계속 기록하지만, 쌓인 표본은
    /// 워치 앱이 실행될 때만 비워진다. 이만큼 새 측정이 없으면 앱을 한 번
    /// 열어야 한다는 뜻이다.
    static let stalledMeasurementInterval: TimeInterval = 6 * 3_600

    static func alerts(
        for snapshot: TaptionWatchMeasurementSnapshot?,
        now: Date = .now
    ) -> [TaptionWatchAlert] {
        // 워치 앱이 한 번도 실행되지 않았으면 상태를 단정할 근거가 없다.
        guard let snapshot else { return [] }
        var alerts: [TaptionWatchAlert] = []
        if let message = snapshot.failureMessage, !message.isEmpty {
            alerts.append(
                TaptionWatchAlert(
                    kind: .recordingFailed,
                    title: "기록이 멈췄어요",
                    detail: message
                )
            )
        }
        if snapshot.isMotionAccessDenied {
            alerts.append(
                TaptionWatchAlert(
                    kind: .motionAccessDenied,
                    title: "동작 권한 없음",
                    detail: "워치 설정에서 동작 및 피트니스를 켜 주세요"
                )
            )
        } else if snapshot.isRecordingRequested, !snapshot.isRecorderAvailable {
            alerts.append(
                TaptionWatchAlert(
                    kind: .recorderUnavailable,
                    title: "배경 기록 불가",
                    detail: "이 워치에서 가속도 기록을 쓸 수 없어요"
                )
            )
        }
        if snapshot.drainFailureCount > 0 {
            alerts.append(
                TaptionWatchAlert(
                    kind: .recordingGap,
                    title: "기록 일부 유실",
                    detail: "읽지 못한 구간 \(snapshot.drainFailureCount)회"
                )
            )
        }
        if isMeasurementStalled(snapshot, now: now) {
            alerts.append(
                TaptionWatchAlert(
                    kind: .measurementStalled,
                    title: "새 측정 없음",
                    detail: "워치 앱을 한 번 열면 밀린 기록을 가져와요"
                )
            )
        }
        return alerts
    }

    static func primary(
        for snapshot: TaptionWatchMeasurementSnapshot?,
        now: Date = .now
    ) -> TaptionWatchAlert? {
        alerts(for: snapshot, now: now).first
    }

    private static func isMeasurementStalled(
        _ snapshot: TaptionWatchMeasurementSnapshot,
        now: Date
    ) -> Bool {
        guard snapshot.isRecordingRequested,
              snapshot.isRecorderAvailable,
              !snapshot.isMotionAccessDenied else {
            return false
        }
        // 운동 세션이 도는 동안에는 30초마다 새 요약이 나온다.
        guard snapshot.source != .workout else { return false }
        // 측정이 한 번도 없었던 기기는 "끊겼다"고 말할 근거가 없다.
        // 설치 직후를 경고로 만들지 않는다.
        guard let measuredAt = snapshot.measuredAt else { return false }
        return now.timeIntervalSince(measuredAt) >= stalledMeasurementInterval
    }
}

/// 워치 위젯 새로고침은 시스템 예산을 쓴다. 실제로 보이는 값이 바뀌었을
/// 때만 다시 그리고, 그렇지 않으면 최소 간격을 지킨다.
enum TaptionWatchWidgetRefreshPolicy {
    static let minimumInterval: TimeInterval = 5 * 60

    static func shouldReload(
        previous: TaptionWatchMeasurementSnapshot?,
        next: TaptionWatchMeasurementSnapshot,
        lastReloadedAt: Date?,
        now: Date = .now
    ) -> Bool {
        guard let previous, let lastReloadedAt else { return true }
        guard displayIdentity(previous) == displayIdentity(next) else {
            return true
        }
        return now.timeIntervalSince(lastReloadedAt) >= minimumInterval
    }

    /// 위젯이 실제로 그리는 값만 모은다. 신뢰도는 10% 단위로 뭉쳐,
    /// 30초마다 도착하는 같은 분류가 새로고침을 태우지 않게 한다.
    static func displayIdentity(
        _ snapshot: TaptionWatchMeasurementSnapshot
    ) -> String {
        let confidence = Int((snapshot.confidenceScore * 10).rounded())
        let alerts = TaptionWatchAlertPolicy
            .alerts(for: snapshot, now: snapshot.updatedAt)
            .map(\.kind.rawValue)
            .joined(separator: ",")
        return [
            snapshot.source.rawValue,
            snapshot.behavior?.rawValue ?? "none",
            String(confidence),
            alerts,
        ].joined(separator: "|")
    }
}

/// iPhone-owned policy for Watch motion sampling.  The Watch receives this
/// with the normal timeline payload so an offline payload remains safe and
/// backward compatible.
///
/// 주변 가속도 수집은 이제 `CMSensorRecorder`가 맡는다. 시스템이 앱과 무관하게
/// 계속 기록하므로 `interval`은 워치의 듀티 사이클을 더 이상 결정하지 않고,
/// 이 프로필은 사실상 켜기/끄기 스위치로 동작한다.
enum TaptionWatchAccelerationProfile: Int, Codable, CaseIterable, Hashable, Sendable {
    case off = 0
    case batterySaver = 1
    case balanced = 2
    case accuracy = 3

    var interval: TimeInterval {
        switch self {
        case .off: 0
        case .batterySaver: 15 * 60
        case .balanced: 5 * 60
        case .accuracy: 60
        }
    }

    var intervalMinutes: Int? {
        guard interval > 0 else { return nil }
        return Int(interval / 60)
    }

    var displayName: String {
        switch self {
        case .off: "끔"
        case .batterySaver: "배터리 최소화"
        case .balanced: "균형"
        case .accuracy: "정확도 최적화"
        }
    }

    var subtitle: String {
        guard interval > 0 else { return "자동 수집 안 함" }
        return "앱이 꺼져 있어도 배경에서 계속 기록"
    }
}

enum TaptionWatchDataSyncProfile: Int, Codable, CaseIterable, Hashable, Sendable {
    case off = 0
    case batterySaver = 1
    case balanced = 2
    case accuracy = 3

    var interval: TimeInterval {
        switch self {
        case .off: 0
        case .batterySaver: 15 * 60
        case .balanced: 5 * 60
        case .accuracy: 60
        }
    }

    var intervalMinutes: Int? {
        guard interval > 0 else { return nil }
        return Int(interval / 60)
    }

    var displayName: String {
        switch self {
        case .off: "끔"
        case .batterySaver: "배터리 최소화"
        case .balanced: "균형"
        case .accuracy: "최신 데이터 우선"
        }
    }

    var subtitle: String {
        guard let intervalMinutes else { return "자동 가져오기 안 함" }
        return intervalMinutes.description + "분마다 건강·활동 데이터 가져오기"
    }
}

struct TaptionWatchAccelerationSettings: Codable, Hashable, Sendable {
    var profile: TaptionWatchAccelerationProfile
    var samplingWindowSeconds: Int

    init(
        profile: TaptionWatchAccelerationProfile,
        samplingWindowSeconds: Int = 30
    ) {
        self.profile = profile
        self.samplingWindowSeconds = min(
            60,
            max(20, samplingWindowSeconds)
        )
    }

    var isEnabled: Bool { profile != .off }
}

struct TaptionWatchPayload: Codable, Hashable, Sendable {
    var generatedAt: Date
    var viewportStart: Date
    var viewportEnd: Date
    var items: [TaptionWatchPlanItem]
    var catStyle: String
    var reducesMotion: Bool
    var todaySummary: TaptionWatchDaySummary? = nil
    var accelerationSettings: TaptionWatchAccelerationSettings? = nil
    var dataSyncProfile: TaptionWatchDataSyncProfile? = nil
    var locationTrackingEnabled: Bool? = nil
    var locationPermissionState: String? = nil
    var activitySuggestion: TaptionWatchActivitySuggestion? = nil
}

struct TaptionWatchHealthSnapshot: Codable, Hashable, Sendable {
    var capturedAt: Date
    var dayStart: Date
    var activeEnergyKilocalories: Double?
    var exerciseMinutes: Double?
    var standHours: Double?
    var sleepMinutes: Double?
    var workoutCount: Int
    var source: String
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
    /// 직접적인 물방울 센서가 아니라 Watch의 Water Lock 상태다.
    /// 지원되는 수중 센서가 없는 기기에서도 샤워 후보의 보조 근거가 된다.
    var waterLockEnabled: Bool? = nil
}

enum TaptionWatchEnvelope {
    static let payloadKey = "taption.watch.payload"
    static let commandKey = "taption.watch.command"
    static let sensorSummaryKey = "taption.watch.sensor-summary"
    static let healthSnapshotKey = "taption.watch.health-snapshot"
    static let workoutRequestKey = "taption.watch.workout-request"
    static let activityConfirmationKey = "taption.watch.activity-confirmation"
    static let refreshRequestKey = "taption.watch.refresh-request"
    static let dataSyncRequestKey = "taption.watch.data-sync-request"
    static let locationTrackingKey = "taption.watch.location-tracking"
    static let locationTrackingGuidanceKey =
        "taption.watch.location-tracking-guidance"
    static let acceptedKey = "taption.watch.accepted"
    static let launchDiagnosticsKey = "taption.watch.launch-diagnostics"
    static let diagnosticsRequestKey = "taption.watch.diagnostics-request"
    static let diagnosticsLogKey = "taption.watch.diagnostics-log"
}

/// Apple Watch가 보내온 직전 실행 기록. 워치 앱이 실행 중 종료될 때 어느
/// 단계까지 갔는지 iPhone 설정 화면에서 확인하기 위한 저장소다.
/// 워치에서 받은 "맞아요 / 아니에요" 응답을 원본과 별개로 모아 둔다.
/// 자동 센서 기록은 원본을 보존해야 하므로 기록을 고치지 않고, 사용자가
/// 붙인 라벨로만 쌓아 나중에 학습·교정에 쓴다.
enum WatchActivityConfirmationStore {
    private static let key = "TaptionPlan.watchActivityConfirmations"
    private static let limit = 500

    static func append(_ value: TaptionWatchActivityConfirmation) {
        var all = read()
        guard !all.contains(where: { $0.id == value.id }) else { return }
        all.append(value)
        if all.count > limit {
            all.removeFirst(all.count - limit)
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func read() -> [TaptionWatchActivityConfirmation] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let values = try? JSONDecoder().decode(
                [TaptionWatchActivityConfirmation].self,
                from: data
              ) else {
            return []
        }
        return values
    }
}

enum WatchActivityLearningStore {
    private static let key = "TaptionPlan.watchActivityLearningSamples"
    private static let limit = 1_000

    static func append(_ value: WatchActivityPatternSample) {
        var all = read()
        guard !all.contains(where: { $0.id == value.id }) else { return }
        all.append(value)
        if all.count > limit { all.removeFirst(all.count - limit) }
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func read() -> [WatchActivityPatternSample] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let values = try? JSONDecoder().decode(
                [WatchActivityPatternSample].self,
                from: data
              ) else { return [] }
        return values
    }
}

enum WatchLaunchReportStore {
    private static let key = "TaptionPlan.watchLaunchReport"
    private static let dateKey = "TaptionPlan.watchLaunchReportDate"

    static func save(_ report: String) {
        UserDefaults.standard.set(report, forKey: key)
        UserDefaults.standard.set(Date.now, forKey: dateKey)
    }

    static func read() -> (report: String, receivedAt: Date)? {
        guard let report = UserDefaults.standard.string(forKey: key),
              !report.isEmpty else {
            return nil
        }
        let date = UserDefaults.standard.object(forKey: dateKey) as? Date
        return (report, date ?? .now)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: dateKey)
    }
}

enum TaptionWatchHealthMetadata {
    static let planID = "com.taption.plan.planID"
    static let planTitle = "com.taption.plan.planTitle"
    static let categoryID = "com.taption.plan.categoryID"
    static let sensorSessionID = "com.taption.plan.sensorSessionID"
}
