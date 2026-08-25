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
        sequence: Int? = nil
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

    public init(
        id: UUID = UUID(),
        span: ActivityTimeSpan,
        majorCategoryID: String,
        detailID: String? = nil,
        title: String? = nil,
        behavior: String? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.span = span
        self.majorCategoryID = majorCategoryID
        self.detailID = detailID
        self.title = title
        self.behavior = behavior
        self.updatedAt = updatedAt
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
