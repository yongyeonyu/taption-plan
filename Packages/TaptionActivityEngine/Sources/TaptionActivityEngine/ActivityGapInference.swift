import Foundation

public struct ActivityGapAnchor: Hashable, Sendable {
    public let majorCategoryID: String
    public let detailID: String
    public let behavior: String

    public init(majorCategoryID: String, detailID: String, behavior: String) {
        self.majorCategoryID = majorCategoryID
        self.detailID = detailID
        self.behavior = behavior
    }
}

public struct ActivityGapInferenceInput: Sendable {
    public let span: ActivityTimeSpan
    public let evidence: [ActivitySensorEvidence]
    public let precedingAnchor: ActivityGapAnchor?
    public let followingAnchor: ActivityGapAnchor?

    public init(
        span: ActivityTimeSpan,
        evidence: [ActivitySensorEvidence],
        precedingAnchor: ActivityGapAnchor? = nil,
        followingAnchor: ActivityGapAnchor? = nil
    ) {
        self.span = span
        self.evidence = evidence
        self.precedingAnchor = precedingAnchor
        self.followingAnchor = followingAnchor
    }
}

public struct ActivityGapInferenceSegment: Hashable, Sendable {
    public let id: UUID
    public let span: ActivityTimeSpan
    public let majorCategoryID: String
    public let detailID: String
    public let behavior: String
    public let confidence: Double
    public let provenance: [String]

    public init(
        id: UUID,
        span: ActivityTimeSpan,
        majorCategoryID: String,
        detailID: String,
        behavior: String,
        confidence: Double,
        provenance: [String]
    ) {
        self.id = id
        self.span = span
        self.majorCategoryID = majorCategoryID
        self.detailID = detailID
        self.behavior = behavior
        self.confidence = min(1, max(0, confidence))
        self.provenance = provenance
    }
}

public struct ActivityGapInferenceConfiguration: Hashable, Sendable {
    public var bucketDuration: TimeInterval
    public var maximumInferenceDuration: TimeInterval
    public var maximumAnchorBridgeDuration: TimeInterval
    public var transitionPenalty: Double

    public init(
        bucketDuration: TimeInterval = 60,
        maximumInferenceDuration: TimeInterval = 4 * 60 * 60,
        maximumAnchorBridgeDuration: TimeInterval = 15 * 60,
        transitionPenalty: Double = 1.5
    ) {
        self.bucketDuration = max(10, bucketDuration)
        self.maximumInferenceDuration = max(bucketDuration, maximumInferenceDuration)
        self.maximumAnchorBridgeDuration = max(0, maximumAnchorBridgeDuration)
        self.transitionPenalty = max(0, transitionPenalty)
    }
}

/// Infers only an explicitly supplied uncovered span. Ground-truth records are
/// anchors, never candidates for replacement.
public struct ActivityGapInferenceEngine: Sendable {
    public let configuration: ActivityGapInferenceConfiguration

    public init(configuration: ActivityGapInferenceConfiguration = .init()) {
        self.configuration = configuration
    }

    public func infer(_ input: ActivityGapInferenceInput) -> [ActivityGapInferenceSegment] {
        guard input.span.duration > 0,
              input.span.duration <= configuration.maximumInferenceDuration else {
            return []
        }
        let evidence = input.evidence
            .filter { input.span.start <= $0.timestamp && $0.timestamp < input.span.end }
            .sorted { $0.timestamp < $1.timestamp }
        if evidence.isEmpty {
            return bridgeMatchingAnchors(input)
        }

        let bucketCount = max(1, Int(ceil(input.span.duration / configuration.bucketDuration)))
        let states = InferenceState.allCases
        var scores = Array(
            repeating: Array(repeating: -Double.infinity, count: states.count),
            count: bucketCount
        )
        var previous = Array(
            repeating: Array(repeating: -1, count: states.count),
            count: bucketCount
        )
        let bucketEvidence = (0..<bucketCount).map { index in
            let start = input.span.start.addingTimeInterval(Double(index) * configuration.bucketDuration)
            let end = min(input.span.end, start.addingTimeInterval(configuration.bucketDuration))
            return evidence.filter { start <= $0.timestamp && $0.timestamp < end }
        }

        for stateIndex in states.indices {
            scores[0][stateIndex] = emission(states[stateIndex], evidence: bucketEvidence[0])
                + anchorScore(states[stateIndex], anchor: input.precedingAnchor)
        }
        if bucketCount > 1 {
            for bucket in 1..<bucketCount {
                for stateIndex in states.indices {
                    let emissionScore = emission(states[stateIndex], evidence: bucketEvidence[bucket])
                    for priorIndex in states.indices {
                        let transition = priorIndex == stateIndex ? 0 : -configuration.transitionPenalty
                        let candidate = scores[bucket - 1][priorIndex] + transition + emissionScore
                        if candidate > scores[bucket][stateIndex] {
                            scores[bucket][stateIndex] = candidate
                            previous[bucket][stateIndex] = priorIndex
                        }
                    }
                }
            }
        }
        for stateIndex in states.indices {
            scores[bucketCount - 1][stateIndex] += anchorScore(
                states[stateIndex],
                anchor: input.followingAnchor
            )
        }

        guard var stateIndex = scores[bucketCount - 1].indices.max(by: {
            scores[bucketCount - 1][$0] < scores[bucketCount - 1][$1]
        }) else { return [] }
        var path = Array(repeating: InferenceState.rest, count: bucketCount)
        for bucket in stride(from: bucketCount - 1, through: 0, by: -1) {
            path[bucket] = states[stateIndex]
            if bucket > 0 {
                stateIndex = max(0, previous[bucket][stateIndex])
            }
        }

        var result: [ActivityGapInferenceSegment] = []
        var startBucket = 0
        for index in 1...bucketCount {
            guard index == bucketCount || path[index] != path[startBucket] else { continue }
            let state = path[startBucket]
            let rangeEvidence = bucketEvidence[startBucket..<index].flatMap { $0 }
            if !rangeEvidence.isEmpty || stateMatchesEitherAnchor(state, input: input) {
                let start = input.span.start.addingTimeInterval(
                    Double(startBucket) * configuration.bucketDuration
                )
                let end = min(
                    input.span.end,
                    input.span.start.addingTimeInterval(Double(index) * configuration.bucketDuration)
                )
                let confidence = confidence(for: state, evidence: rangeEvidence)
                if confidence >= 0.55 {
                    result.append(segment(state: state, span: .init(start: start, end: end), confidence: confidence))
                }
            }
            startBucket = index
        }
        return result
    }

    private func bridgeMatchingAnchors(
        _ input: ActivityGapInferenceInput
    ) -> [ActivityGapInferenceSegment] {
        guard input.span.duration <= configuration.maximumAnchorBridgeDuration,
              let preceding = input.precedingAnchor,
              preceding == input.followingAnchor else { return [] }
        return [.init(
            id: ActivityStableID.uuid(seed: stableSeed(span: input.span, behavior: preceding.behavior)),
            span: input.span,
            majorCategoryID: preceding.majorCategoryID,
            detailID: preceding.detailID,
            behavior: preceding.behavior,
            confidence: 0.65,
            provenance: ["matching-ground-truth-anchors"]
        )]
    }

    private func emission(
        _ state: InferenceState,
        evidence: [ActivitySensorEvidence]
    ) -> Double {
        guard !evidence.isEmpty else { return -0.25 }
        return evidence.reduce(0) { score, sample in
            score + state.score(sample)
        } / Double(evidence.count)
    }

    private func anchorScore(
        _ state: InferenceState,
        anchor: ActivityGapAnchor?
    ) -> Double {
        guard let anchor else { return 0 }
        return state.behavior == anchor.behavior ? 1.5 : -0.5
    }

    private func stateMatchesEitherAnchor(
        _ state: InferenceState,
        input: ActivityGapInferenceInput
    ) -> Bool {
        state.behavior == input.precedingAnchor?.behavior
            || state.behavior == input.followingAnchor?.behavior
    }

    private func confidence(
        for state: InferenceState,
        evidence: [ActivitySensorEvidence]
    ) -> Double {
        guard !evidence.isEmpty else { return 0.55 }
        let explicit = evidence.filter { state.matchesHint($0) }.count
        let sensor = evidence.filter { state.matchesSensor($0) }.count
        return min(0.95, 0.55 + Double(explicit) * 0.1 + Double(sensor) * 0.05)
    }

    private func segment(
        state: InferenceState,
        span: ActivityTimeSpan,
        confidence: Double
    ) -> ActivityGapInferenceSegment {
        .init(
            id: ActivityStableID.uuid(seed: stableSeed(span: span, behavior: state.behavior)),
            span: span,
            majorCategoryID: state.majorCategoryID,
            detailID: state.detailID,
            behavior: state.behavior,
            confidence: confidence,
            provenance: ["activity-gap-viterbi-v1", state.evidenceLabel]
        )
    }

    private func stableSeed(span: ActivityTimeSpan, behavior: String) -> String {
        "activity-gap-viterbi-v1|\(span.start.timeIntervalSince1970)|\(span.end.timeIntervalSince1970)|\(behavior)"
    }
}

private enum InferenceState: CaseIterable {
    case rest
    case walking
    case running
    case cycling
    case automotive
    case subway

    var majorCategoryID: String { self == .rest ? "activity" : "movement" }
    var detailID: String {
        switch self {
        case .rest: "activity.rest"
        case .walking: "movement.walking"
        case .running: "movement.running"
        case .cycling: "movement.cycling"
        case .automotive: "movement.car"
        case .subway: "movement.subway"
        }
    }
    var behavior: String {
        switch self {
        case .rest: "stationary"
        case .walking: "walking"
        case .running: "running"
        case .cycling: "cycling"
        case .automotive: "automotive"
        case .subway: "subway"
        }
    }
    var evidenceLabel: String { "sensor-state-\(behavior)" }

    func score(_ sample: ActivitySensorEvidence) -> Double {
        var score = matchesHint(sample) ? 5.0 : 0
        if matchesSensor(sample) { score += 3 }
        if let speed = sample.speedMetersPerSecond, speed.isFinite, speed >= 0 {
            switch self {
            case .rest: score += speed < 0.5 ? 2 : -2
            case .walking: score += (0.5..<3.5).contains(speed) ? 2 : 0
            case .running: score += (2.5..<9).contains(speed) ? 2 : 0
            case .cycling: score += (3..<20).contains(speed) ? 1.5 : 0
            case .automotive, .subway: score += speed >= 8 ? 1.5 : 0
            }
        }
        return score
    }

    func matchesHint(_ sample: ActivitySensorEvidence) -> Bool {
        let text = [sample.categoryHint, sample.detailHint, sample.behaviorHint]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return text.contains(behavior)
            || (self == .automotive && text.contains("car"))
            || (self == .rest && text.contains("rest"))
    }

    func matchesSensor(_ sample: ActivitySensorEvidence) -> Bool {
        switch self {
        case .rest: sample.motion == .stationary
        case .walking: sample.motion == .walking
        case .running: sample.motion == .running
        case .cycling: sample.motion == .cycling
        case .automotive: sample.motion == .automotive
        case .subway: matchesHint(sample)
        }
    }
}
