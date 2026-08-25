import Foundation

public struct TaptionPlanDayKey: Codable, Comparable, Hashable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(date: Date, calendar: Calendar = .autoupdatingCurrent) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(
            year: components.year ?? 0,
            month: components.month ?? 0,
            day: components.day ?? 0
        )
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

public struct TaptionPlanTimestampIndex: Hashable, Sendable {
    public let timestamps: [Date]

    public init<S: Sequence>(timestamps: S) where S.Element == Date {
        self.timestamps = timestamps.sorted()
    }

    public var count: Int { timestamps.count }

    public func lowerBound(_ date: Date) -> Int {
        var lower = 0
        var upper = timestamps.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if timestamps[middle] < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    public func upperBound(_ date: Date) -> Int {
        var lower = 0
        var upper = timestamps.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if timestamps[middle] <= date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    public func prefixCount(through date: Date) -> Int {
        upperBound(date)
    }

    public func range(from start: Date, through end: Date) -> Range<Int> {
        let lower = lowerBound(start)
        let upper = upperBound(end)
        return lower..<max(lower, upper)
    }
}

public struct TaptionPlanDayDataSnapshot: Hashable, Sendable {
    public let day: TaptionPlanDayKey
    public let revision: UInt64
    public let generation: UInt64
    public let createdAt: Date
    public let timestampIndex: TaptionPlanTimestampIndex

    public init(
        day: TaptionPlanDayKey,
        revision: UInt64,
        generation: UInt64,
        createdAt: Date = .now,
        timestamps: [Date] = []
    ) {
        self.day = day
        self.revision = revision
        self.generation = generation
        self.createdAt = createdAt
        self.timestampIndex = TaptionPlanTimestampIndex(timestamps: timestamps)
    }

    public func isNewer(than other: Self) -> Bool {
        revision > other.revision || (revision == other.revision && generation > other.generation)
    }
}

public struct TaptionPlanNLEInputDecision: Hashable, Sendable {
    public let generation: UInt64
    public let sequence: UInt64
    public let shouldPublish: Bool
    public let isFinal: Bool

    public init(generation: UInt64, sequence: UInt64, shouldPublish: Bool, isFinal: Bool) {
        self.generation = generation
        self.sequence = sequence
        self.shouldPublish = shouldPublish
        self.isFinal = isFinal
    }
}

public struct TaptionPlanNLEInputBudgetEngine: Sendable {
    public static let defaultPublishInterval: TimeInterval = 1.0 / 60.0

    public let publishInterval: TimeInterval
    public private(set) var activeGeneration: UInt64

    private var lastPublishedAt: TimeInterval?
    private var nextSequence: UInt64

    public init(
        publishInterval: TimeInterval = Self.defaultPublishInterval,
        generation: UInt64 = 1
    ) {
        precondition(publishInterval > 0)
        self.publishInterval = publishInterval
        self.activeGeneration = generation
        self.lastPublishedAt = nil
        self.nextSequence = 0
    }

    public mutating func beginGeneration() -> UInt64 {
        activeGeneration &+= 1
        lastPublishedAt = nil
        nextSequence = 0
        return activeGeneration
    }

    public mutating func cancelGeneration(_ generation: UInt64) {
        guard generation == activeGeneration else { return }
        activeGeneration &+= 1
        lastPublishedAt = nil
        nextSequence = 0
    }

    public mutating func submit(
        at timestamp: TimeInterval,
        generation: UInt64 = 0,
        isFinal: Bool = false
    ) -> TaptionPlanNLEInputDecision {
        nextSequence &+= 1
        let eventGeneration = generation == 0 ? activeGeneration : generation
        guard eventGeneration == activeGeneration else {
            return .init(
                generation: eventGeneration,
                sequence: nextSequence,
                shouldPublish: false,
                isFinal: isFinal
            )
        }

        let due = lastPublishedAt == nil
            || timestamp >= (lastPublishedAt ?? timestamp)
                + publishInterval
                - 1e-9
        let shouldPublish = isFinal || due
        if shouldPublish {
            lastPublishedAt = timestamp
        }
        return .init(
            generation: eventGeneration,
            sequence: nextSequence,
            shouldPublish: shouldPublish,
            isFinal: isFinal
        )
    }
}
