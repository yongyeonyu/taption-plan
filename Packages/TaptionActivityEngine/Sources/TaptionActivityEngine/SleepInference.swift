import Foundation

public struct SleepRuleSample: Codable, Hashable, Sendable {
    public let timestamp: Date
    public let screenIsOn: Bool?
    public let inactivityDuration: TimeInterval
    public let phoneMoved: Bool
    public let distanceFromHomeMeters: Double?
    public let ambientIsDark: Bool?
    public let isCharging: Bool
    public let userWakeActivity: Bool

    public init(timestamp: Date, screenIsOn: Bool? = nil, inactivityDuration: TimeInterval = 0, phoneMoved: Bool = false, distanceFromHomeMeters: Double? = nil, ambientIsDark: Bool? = nil, isCharging: Bool = false, userWakeActivity: Bool = false) {
        self.timestamp = timestamp
        self.screenIsOn = screenIsOn
        self.inactivityDuration = max(0, inactivityDuration)
        self.phoneMoved = phoneMoved
        self.distanceFromHomeMeters = distanceFromHomeMeters
        self.ambientIsDark = ambientIsDark
        self.isCharging = isCharging
        self.userWakeActivity = userWakeActivity
    }

    public func sleepConditionsMet(configuration: SleepInferenceConfiguration) -> Bool {
        let support = [
            distanceFromHomeMeters.map { $0 <= configuration.homeRadiusMeters },
            ambientIsDark,
            isCharging
        ].compactMap { $0 }.filter { $0 }.count
        return screenIsOn == false
            && inactivityDuration >= configuration.inactivityDuration
            && !phoneMoved
            && support >= configuration.minimumSupportingConditions
    }

    public func wakeConditionsMet(configuration: SleepInferenceConfiguration) -> Bool {
        screenIsOn == true && (phoneMoved || userWakeActivity)
            && (distanceFromHomeMeters.map { $0 > configuration.homeRadiusMeters } == true || ambientIsDark == false || !isCharging)
    }
}

public struct SleepInferenceConfiguration: Codable, Hashable, Sendable {
    public var inactivityDuration: TimeInterval
    public var homeRadiusMeters: Double
    public var minimumSupportingConditions: Int
    public var persistenceDuration: TimeInterval

    public init(inactivityDuration: TimeInterval = 30 * 60, homeRadiusMeters: Double = 100, minimumSupportingConditions: Int = 3, persistenceDuration: TimeInterval = 5 * 60) {
        self.inactivityDuration = max(0, inactivityDuration)
        self.homeRadiusMeters = max(0, homeRadiusMeters)
        self.minimumSupportingConditions = min(3, max(0, minimumSupportingConditions))
        self.persistenceDuration = max(0, persistenceDuration)
    }
}

public enum SleepInferenceState: String, Codable, CaseIterable, Hashable, Sendable {
    case insufficientEvidence
    case sleepCandidate
    case asleep
    case wakeCandidate
}

public struct SleepInferenceResult: Codable, Hashable, Sendable {
    public let state: SleepInferenceState
    public let confidence: Double
    public let provenance: ActivityDataProvenance?

    public init(state: SleepInferenceState, confidence: Double, provenance: ActivityDataProvenance? = nil) {
        self.state = state
        self.confidence = min(1, max(0, confidence))
        self.provenance = provenance
    }
}

public struct SleepInferenceEngine: Sendable {
    public let configuration: SleepInferenceConfiguration

    public init(configuration: SleepInferenceConfiguration = .init()) {
        self.configuration = configuration
    }

    public func infer(_ samples: [SleepRuleSample]) -> SleepInferenceResult {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        guard let last = ordered.last else { return .init(state: .insufficientEvidence, confidence: 0) }
        if last.wakeConditionsMet(configuration: configuration) {
            return makeResult(state: .wakeCandidate, samples: ordered, confidence: 0.9, evidence: ["화면 사용", "이동 또는 사용자 활동", "수면 보조 조건 해제"])
        }
        guard last.sleepConditionsMet(configuration: configuration) else { return .init(state: .insufficientEvidence, confidence: 0) }
        let continuous = ordered.reversed().prefix { $0.sleepConditionsMet(configuration: configuration) }
        guard let first = continuous.last else { return .init(state: .sleepCandidate, confidence: 0.7) }
        let state: SleepInferenceState = last.timestamp.timeIntervalSince(first.timestamp) >= configuration.persistenceDuration ? .asleep : .sleepCandidate
        let confidence = state == .asleep ? 0.85 : 0.7
        return makeResult(state: state, samples: Array(continuous.reversed()), confidence: confidence, evidence: ["화면 꺼짐", "30분 무사용", "휴대폰 이동 없음", "보조 조건 모두 충족"])
    }

    private func makeResult(state: SleepInferenceState, samples: [SleepRuleSample], confidence: Double, evidence: [String]) -> SleepInferenceResult {
        guard let first = samples.first, let last = samples.last else { return .init(state: state, confidence: confidence) }
        let span = ActivityTimeSpan(start: first.timestamp, end: last.timestamp)
        return .init(state: state, confidence: confidence, provenance: .init(tier: .expected, status: ActivityAutomaticConfirmation.status(for: confidence), source: "sleep-rule-v1", evidence: evidence, confidence: confidence, span: span))
    }
}
