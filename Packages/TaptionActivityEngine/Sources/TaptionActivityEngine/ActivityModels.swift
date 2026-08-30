import Foundation

public enum ActivityStableID {
    public static func uuid(seed: String) -> UUID {
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x9e3779b185ebca87
        for byte in seed.utf8 {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second = (second ^ UInt64(byte)) &* 0x9e3779b185ebca87
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8((first >> UInt64(index * 8)) & 0xff)
            bytes[index + 8] = UInt8((second >> UInt64(index * 8)) & 0xff)
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

public enum ActivityMotion: String, Codable, CaseIterable, Hashable, Sendable {
    case stationary
    case walking
    case running
    case cycling
    case automotive
    case unknown
}

public enum ActivitySensorSource: String, Codable, CaseIterable, Hashable, Sendable {
    case iPhone
    case appleWatch
    case combined
}

public struct ActivityTimeSpan: Codable, Hashable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = max(start, end)
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public func intersects(_ other: ActivityTimeSpan) -> Bool {
        start < other.end && other.start < end
    }

    public func intersection(_ other: ActivityTimeSpan) -> ActivityTimeSpan? {
        guard intersects(other) else { return nil }
        return ActivityTimeSpan(start: max(start, other.start), end: min(end, other.end))
    }
}

/// A framework-neutral sensor projection. Adapters may create this from
/// Core Location, Motion, HealthKit or Watch records without leaking those
/// frameworks into the classification package.
public struct ActivitySensorEvidence: Codable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let motion: ActivityMotion
    public let speedMetersPerSecond: Double?
    public let horizontalAccuracyMeters: Double?
    public let isPreciseLocation: Bool
    public let stepCount: Int?
    public let screenIsOn: Bool?
    public let screenBrightness: Double?
    public let categoryHint: String?
    public let detailHint: String?
    public let behaviorHint: String?
    public let confidence: Double?
    public let evidence: [String]
    public let sequence: Int?
    public let source: ActivitySensorSource

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, motion, speedMetersPerSecond
        case horizontalAccuracyMeters, isPreciseLocation, stepCount
        case screenIsOn, screenBrightness, categoryHint, detailHint
        case behaviorHint, confidence, evidence, sequence, source
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        motion: ActivityMotion = .unknown,
        speedMetersPerSecond: Double? = nil,
        horizontalAccuracyMeters: Double? = nil,
        isPreciseLocation: Bool = true,
        stepCount: Int? = nil,
        screenIsOn: Bool? = nil,
        screenBrightness: Double? = nil,
        categoryHint: String? = nil,
        detailHint: String? = nil,
        behaviorHint: String? = nil,
        confidence: Double? = nil,
        evidence: [String] = [],
        sequence: Int? = nil,
        source: ActivitySensorSource = .iPhone
    ) {
        self.id = id
        self.timestamp = timestamp
        self.motion = motion
        self.speedMetersPerSecond = speedMetersPerSecond
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.isPreciseLocation = isPreciseLocation
        self.stepCount = stepCount
        self.screenIsOn = screenIsOn
        self.screenBrightness = screenBrightness
        self.categoryHint = categoryHint
        self.detailHint = detailHint
        self.behaviorHint = behaviorHint
        self.confidence = confidence
        self.evidence = evidence
        self.sequence = sequence
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        motion = try values.decodeIfPresent(ActivityMotion.self, forKey: .motion) ?? .unknown
        speedMetersPerSecond = try values.decodeIfPresent(Double.self, forKey: .speedMetersPerSecond)
        horizontalAccuracyMeters = try values.decodeIfPresent(Double.self, forKey: .horizontalAccuracyMeters)
        isPreciseLocation = try values.decodeIfPresent(Bool.self, forKey: .isPreciseLocation) ?? true
        stepCount = try values.decodeIfPresent(Int.self, forKey: .stepCount)
        screenIsOn = try values.decodeIfPresent(Bool.self, forKey: .screenIsOn)
        screenBrightness = try values.decodeIfPresent(Double.self, forKey: .screenBrightness)
        categoryHint = try values.decodeIfPresent(String.self, forKey: .categoryHint)
        detailHint = try values.decodeIfPresent(String.self, forKey: .detailHint)
        behaviorHint = try values.decodeIfPresent(String.self, forKey: .behaviorHint)
        confidence = try values.decodeIfPresent(Double.self, forKey: .confidence)
        evidence = try values.decodeIfPresent([String].self, forKey: .evidence) ?? []
        sequence = try values.decodeIfPresent(Int.self, forKey: .sequence)
        source = try values.decodeIfPresent(ActivitySensorSource.self, forKey: .source) ?? .iPhone
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(timestamp, forKey: .timestamp)
        try values.encode(motion, forKey: .motion)
        try values.encodeIfPresent(speedMetersPerSecond, forKey: .speedMetersPerSecond)
        try values.encodeIfPresent(horizontalAccuracyMeters, forKey: .horizontalAccuracyMeters)
        try values.encode(isPreciseLocation, forKey: .isPreciseLocation)
        try values.encodeIfPresent(stepCount, forKey: .stepCount)
        try values.encodeIfPresent(screenIsOn, forKey: .screenIsOn)
        try values.encodeIfPresent(screenBrightness, forKey: .screenBrightness)
        try values.encodeIfPresent(categoryHint, forKey: .categoryHint)
        try values.encodeIfPresent(detailHint, forKey: .detailHint)
        try values.encodeIfPresent(behaviorHint, forKey: .behaviorHint)
        try values.encodeIfPresent(confidence, forKey: .confidence)
        try values.encode(evidence, forKey: .evidence)
        try values.encodeIfPresent(sequence, forKey: .sequence)
        try values.encode(source, forKey: .source)
    }
}

public struct ActivityClassificationOverride: Codable, Hashable, Sendable {
    public let id: UUID
    public let span: ActivityTimeSpan
    public let majorCategoryID: String
    public let detailID: String?
    public let title: String?
    public let behavior: String?
    public let updatedAt: Date
    public let isLocked: Bool

    private enum CodingKeys: String, CodingKey {
        case id, span, majorCategoryID, detailID, title, behavior, updatedAt, isLocked
    }

    public init(
        id: UUID = UUID(),
        span: ActivityTimeSpan,
        majorCategoryID: String,
        detailID: String? = nil,
        title: String? = nil,
        behavior: String? = nil,
        updatedAt: Date = .now,
        isLocked: Bool = false
    ) {
        self.id = id
        self.span = span
        self.majorCategoryID = majorCategoryID
        self.detailID = detailID
        self.title = title
        self.behavior = behavior
        self.updatedAt = updatedAt
        self.isLocked = isLocked
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        span = try values.decode(ActivityTimeSpan.self, forKey: .span)
        majorCategoryID = try values.decode(String.self, forKey: .majorCategoryID)
        detailID = try values.decodeIfPresent(String.self, forKey: .detailID)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        behavior = try values.decodeIfPresent(String.self, forKey: .behavior)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? span.start
        isLocked = try values.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(span, forKey: .span)
        try values.encode(majorCategoryID, forKey: .majorCategoryID)
        try values.encodeIfPresent(detailID, forKey: .detailID)
        try values.encodeIfPresent(title, forKey: .title)
        try values.encodeIfPresent(behavior, forKey: .behavior)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(isLocked, forKey: .isLocked)
    }

    public var isSleep: Bool {
        majorCategoryID == "sleep" || detailID?.hasPrefix("sleep.") == true
    }
}

public struct ActivitySegment: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let span: ActivityTimeSpan
    public let majorCategoryID: String
    public let detailID: String
    public let title: String
    public let behavior: String
    public let confidence: Double
    public let evidence: [String]
    public let sampleCount: Int
    public let isUserConfirmed: Bool

    public init(
        id: UUID,
        span: ActivityTimeSpan,
        majorCategoryID: String,
        detailID: String,
        title: String,
        behavior: String,
        confidence: Double,
        evidence: [String],
        sampleCount: Int,
        isUserConfirmed: Bool
    ) {
        self.id = id
        self.span = span
        self.majorCategoryID = majorCategoryID
        self.detailID = detailID
        self.title = title
        self.behavior = behavior
        self.confidence = min(1, max(0, confidence))
        self.evidence = evidence
        self.sampleCount = sampleCount
        self.isUserConfirmed = isUserConfirmed
    }
}

public struct ActivityClassificationState: Codable, Hashable, Sendable {
    public let evidence: [ActivitySensorEvidence]
    public let overrides: [ActivityClassificationOverride]
    public let segments: [ActivitySegment]

    public init(
        evidence: [ActivitySensorEvidence],
        overrides: [ActivityClassificationOverride],
        segments: [ActivitySegment]
    ) {
        self.evidence = evidence
        self.overrides = overrides
        self.segments = segments
    }
}
