import Foundation

public struct ClassifierDayInput: Sendable {
    public var day: ClassifierInterval
    public var samples: [ClassifierSample]
    public var sleepSources: [SleepSource]
    /// 수면을 볼 밤(보통 전날 18시 ~ 당일 14시).
    public var night: ClassifierInterval?
    public var registeredPlaces: [String: (point: ClassifierPoint, kind: RegisteredPlaceKind)]

    public init(day: ClassifierInterval, samples: [ClassifierSample], sleepSources: [SleepSource] = [], night: ClassifierInterval? = nil, registeredPlaces: [String: (point: ClassifierPoint, kind: RegisteredPlaceKind)] = [:]) {
        self.day = day
        self.samples = samples
        self.sleepSources = sleepSources
        self.night = night
        self.registeredPlaces = registeredPlaces
    }
}

public struct ClassifiedStay: Hashable, Sendable {
    public var stay: StayPoint
    public var placeID: String
    public var registeredKind: RegisteredPlaceKind?
    public var context: StayContextResult
}

/// 출력 기록 하나. 원본은 바꾸지 않고 근거·점수·버전을 함께 담는다.
public struct ClassifierRecord: Hashable, Sendable {
    public var interval: ClassifierInterval
    public var categoryID: String
    public var behavior: String
    public var score: Double
    public var confidence: ClassifierConfidence
    public var modelVersion: String
    public var evidence: [String]
}

public struct ClassifierDayOutput: Sendable {
    public var segments: [ClassifiedSegment]
    public var stays: [ClassifiedStay]
    public var sleep: [SleepSession]
    public var records: [ClassifierRecord]
    /// 원본이 충분하지 않아 기존 결과를 유지해야 하는 날.
    public var hasEnoughRawData: Bool
}

public enum TaptionClassifier {
    public static let pipelineVersion = ClassifierPipeline.version
    /// 재계산에 필요한 최소 원본: 위치·모션 표본 이 정도는 있어야 하루를 다시 만든다.
    public static let minimumSamples = 30

    public static func hasEnoughRawData(_ samples: [ClassifierSample]) -> Bool {
        hasEnoughRawData(sampleCount: samples.count)
    }

    public static func hasEnoughRawData(sampleCount: Int) -> Bool {
        sampleCount >= minimumSamples
    }

    public static func classifyDay(_ input: ClassifierDayInput) -> ClassifierDayOutput {
        classifyDay(input, cancellation: {})
    }

    public static func classifyDay(_ input: ClassifierDayInput, cancellation: () throws -> Void) rethrows -> ClassifierDayOutput {
        let samples = input.samples.filter { $0.timestamp >= input.day.start && $0.timestamp < input.day.end }
        let enough = hasEnoughRawData(samples)
        let windows = try WindowFeatureExtractor.windows(samples, cancellation: cancellation)
        try cancellation()
        let steps = ModeHMM().decode(windows)
        try cancellation()
        let segments = TravelSegmenter.segments(steps: steps, samples: samples)

        let stayPoints = StayPointDetector().detect(samples)
        let anchors = input.registeredPlaces.mapValues(\.point)
        let (_, assignment) = PlaceClusterer().cluster(stayPoints, anchors: anchors)
        let stays = stayPoints.enumerated().map { index, stay in
            let placeID = assignment[index] ?? stay.legacyKey
            let kind = input.registeredPlaces[placeID]?.kind
            return ClassifiedStay(stay: stay, placeID: placeID, registeredKind: kind,
                                  context: StayContextClassifier.classify(StayContextInput(interval: stay.interval, registeredKind: kind)))
        }
        try cancellation()
        let sleep = input.night.map { SleepFusion.sessions(health: input.sleepSources, phone: input.samples, night: $0) } ?? []

        var records: [ClassifierRecord] = segments.filter { $0.mode != .stationary }.map { segment in
            ClassifierRecord(
                interval: segment.interval, categoryID: "movement", behavior: behavior(for: segment.mode),
                score: segment.score, confidence: ClassifierConfidence(score: segment.score),
                modelVersion: ClassifierPipeline.modelVersion("movement"), evidence: segment.evidence
            )
        }
        let sleepIntervals = sleep.map(\.interval)
        records += stays.flatMap { stay -> [ClassifierRecord] in
            ClassifierInterval.subtracting(sleepIntervals, from: [stay.stay.interval]).map { interval in
                ClassifierRecord(
                    interval: interval, categoryID: stay.context.context.categoryID, behavior: stay.context.context.detailBehavior,
                    score: stay.context.score, confidence: ClassifierConfidence(score: stay.context.score),
                    modelVersion: ClassifierPipeline.modelVersion("context"), evidence: stay.context.evidence
                )
            }
        }
        records += sleep.map { session in
            ClassifierRecord(
                interval: session.interval, categoryID: "sleep", behavior: "core", score: session.score,
                confidence: ClassifierConfidence(score: session.score), modelVersion: ClassifierPipeline.modelVersion("sleep"),
                evidence: session.evidence
            )
        }
        records.sort { $0.interval.start < $1.interval.start }
        return ClassifierDayOutput(segments: segments, stays: stays, sleep: sleep, records: records, hasEnoughRawData: enough)
    }

    /// 분류표 v3 `movement.*`의 behavior.
    public static func behavior(for mode: TransportMode) -> String {
        switch mode {
        case .stationary: "stationary"
        case .walking: "walking"
        case .running: "running"
        case .cycling: "cycling"
        case .car: "automotive"
        case .bus: "bus"
        case .subway: "subway"
        case .train: "train"
        case .ship: "ship"
        case .airplane: "airplane"
        }
    }
}
