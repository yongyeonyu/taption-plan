import CSQLite
import CryptoKit
import Foundation

public enum TaptionPlanStoreDevice: String, Codable, Hashable, Sendable {
    case iPhone
    case appleWatch
}

public struct TaptionPlanRawEvent: Codable, Hashable, Sendable {
    public let device: TaptionPlanStoreDevice
    public let day: TaptionPlanDayKey
    public let timestamp: Date
    public let sequence: UInt64
    public let id: String
    public let domain: String
    public let provenance: [String]
    public let payload: Data

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.device == rhs.device
            && lhs.day == rhs.day
            && lhs.timestamp == rhs.timestamp
            && lhs.sequence == rhs.sequence
            && exactlyEqual(lhs.id, rhs.id)
            && exactlyEqual(lhs.domain, rhs.domain)
            && lhs.provenance == rhs.provenance
            && lhs.payload == rhs.payload
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(device)
        hasher.combine(day)
        hasher.combine(timestamp)
        hasher.combine(sequence)
        hashExactBytes(id, into: &hasher)
        hashExactBytes(domain, into: &hasher)
        hasher.combine(provenance)
        hasher.combine(payload)
    }

    public init(
        device: TaptionPlanStoreDevice,
        day: TaptionPlanDayKey,
        timestamp: Date,
        sequence: UInt64,
        id: String,
        domain: String,
        provenance: [String],
        payload: Data
    ) {
        self.device = device
        self.day = day
        self.timestamp = timestamp
        self.sequence = sequence
        self.id = id
        self.domain = domain
        self.provenance = provenance
        self.payload = payload
    }
}

public struct TaptionPlanRawEventIdentifier: Hashable, Sendable {
    public let domain: String
    public let id: String

    public init(domain: String, id: String) {
        self.domain = domain
        self.id = id
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        exactlyEqual(lhs.domain, rhs.domain)
            && exactlyEqual(lhs.id, rhs.id)
    }

    public func hash(into hasher: inout Hasher) {
        hashExactBytes(domain, into: &hasher)
        hashExactBytes(id, into: &hasher)
    }
}

struct RawEventPageScanState: Hashable, Sendable {
    let storeID: UUID
    let rawEventRevision: UInt64
    let dataVersion: Int64
}

public struct TaptionPlanRawEventCursor: Hashable, Sendable {
    public let day: TaptionPlanDayKey
    public let timestamp: Date
    public let sequence: UInt64
    public let id: String
    public let domain: String
    let scanState: RawEventPageScanState?

    public init(after event: TaptionPlanRawEvent) {
        day = event.day
        timestamp = event.timestamp
        sequence = event.sequence
        id = event.id
        domain = event.domain
        scanState = nil
    }

    init(
        after event: TaptionPlanRawEvent,
        scanState: RawEventPageScanState
    ) {
        day = event.day
        timestamp = event.timestamp
        sequence = event.sequence
        id = event.id
        domain = event.domain
        self.scanState = scanState
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.day == rhs.day
            && lhs.timestamp == rhs.timestamp
            && lhs.sequence == rhs.sequence
            && exactlyEqual(lhs.id, rhs.id)
            && exactlyEqual(lhs.domain, rhs.domain)
            && lhs.scanState == rhs.scanState
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(day)
        hasher.combine(timestamp)
        hasher.combine(sequence)
        hashExactBytes(id, into: &hasher)
        hashExactBytes(domain, into: &hasher)
        hasher.combine(scanState)
    }
}

public struct TaptionPlanRawEventPage: Sendable {
    public let events: [TaptionPlanRawEvent]
    public let nextCursor: TaptionPlanRawEventCursor?
    public let hasMore: Bool

    public init(
        events: [TaptionPlanRawEvent],
        nextCursor: TaptionPlanRawEventCursor?,
        hasMore: Bool
    ) {
        self.events = events
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

/// A durable device-to-device message that remains queued until the receiver
/// confirms that its copy has been persisted.
public struct TaptionPlanV3OutboxItem: Hashable, Sendable {
    public let id: String
    public let kind: String
    public let payload: Data

    public init(id: String, kind: String, payload: Data) {
        self.id = id
        self.kind = kind
        self.payload = payload
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        exactlyEqual(lhs.id, rhs.id)
            && exactlyEqual(lhs.kind, rhs.kind)
            && lhs.payload == rhs.payload
    }

    public func hash(into hasher: inout Hasher) {
        hashExactBytes(id, into: &hasher)
        hashExactBytes(kind, into: &hasher)
        hasher.combine(payload)
    }
}

public struct TaptionPlanMaterializedDay: Codable, Hashable, Sendable {
    public let device: TaptionPlanStoreDevice
    public let day: TaptionPlanDayKey
    public let sourceRevision: UInt64
    public let projectionVersion: UInt64
    public let generatedAt: Date
    public let rawDigest: String
    public let rawEventCount: Int
    public let firstTimestamp: Date?
    public let lastTimestamp: Date?
    public let payload: Data

    public init(
        device: TaptionPlanStoreDevice,
        day: TaptionPlanDayKey,
        sourceRevision: UInt64,
        projectionVersion: UInt64,
        generatedAt: Date = .now,
        rawDigest: String,
        rawEventCount: Int,
        firstTimestamp: Date?,
        lastTimestamp: Date?,
        payload: Data
    ) {
        self.device = device
        self.day = day
        self.sourceRevision = sourceRevision
        self.projectionVersion = projectionVersion
        self.generatedAt = generatedAt
        self.rawDigest = rawDigest
        self.rawEventCount = rawEventCount
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.payload = payload
    }
}

public struct TaptionPlanDayDigest: Codable, Hashable, Sendable {
    public let device: TaptionPlanStoreDevice
    public let day: TaptionPlanDayKey
    public let eventCount: Int
    public let firstTimestamp: Date?
    public let lastTimestamp: Date?
    public let sha256: String

    public init(
        device: TaptionPlanStoreDevice,
        day: TaptionPlanDayKey,
        eventCount: Int,
        firstTimestamp: Date?,
        lastTimestamp: Date?,
        sha256: String
    ) {
        self.device = device
        self.day = day
        self.eventCount = eventCount
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.sha256 = sha256
    }
}

public enum TaptionPlanV3StoreError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidDay
    case invalidDomain
    case invalidDevice
    case invalidIdentifier
    case integerOverflow
    case staleRawEventCursor
    case rawEventPageItemTooLarge(limit: Int)
    case payloadConflict(device: TaptionPlanStoreDevice, domain: String, id: String)
    case outboxConflict(id: String)
    case outboxLimitExceeded(limit: Int)
    case outboxPayloadTooLarge(limit: Int)
    case outboxByteLimitExceeded(limit: Int)
    case materializationMismatch
    case database(code: Int32, message: String)
    case databaseCorrupt(message: String)
}
