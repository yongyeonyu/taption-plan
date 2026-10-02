import Foundation

public enum TaptionCanonicalUUIDOrder {
    /// UUID text order, compared without allocating formatted strings.
    @inlinable
    public static func precedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        var left = lhs.uuid
        var right = rhs.uuid
        return withUnsafeBytes(of: &left) { leftBytes in
            withUnsafeBytes(of: &right) { leftBytes.lexicographicallyPrecedes($0) }
        }
    }
}

/// Value cache with constant-time hits and a bounded scan only on eviction.
public struct TaptionBoundedCache<Key: Hashable, Value> {
    @usableFromInline
    struct Entry {
        @usableFromInline var value: Value
        @usableFromInline var access: UInt64
        @usableFromInline init(value: Value, access: UInt64) {
            self.value = value
            self.access = access
        }
    }

    public let capacity: Int
    @usableFromInline var entries: [Key: Entry] = [:]
    @usableFromInline var clock: UInt64 = 0

    @inlinable
    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    @inlinable public var count: Int { entries.count }
    @inlinable public var keys: [Key] { Array(entries.keys) }

    @inlinable
    public func mostRecentKey(where matches: (Key) -> Bool) -> Key? {
        var result: Key?
        var newest: UInt64 = 0
        for (key, entry) in entries where matches(key) && entry.access >= newest {
            result = key
            newest = entry.access
        }
        return result
    }

    @inlinable
    public func peek(_ key: Key) -> Value? { entries[key]?.value }

    @inlinable
    public mutating func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        entry.access = nextAccess()
        entries[key] = entry
        return entry.value
    }

    @inlinable
    public mutating func insert(_ value: Value, for key: Key) {
        if entries[key] == nil, entries.count == capacity,
           let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = Entry(value: value, access: nextAccess())
    }

    @discardableResult
    @inlinable
    public mutating func removeValue(for key: Key) -> Value? {
        entries.removeValue(forKey: key)?.value
    }

    @inlinable
    public mutating func removeAll(keepingCapacity: Bool = false) {
        entries.removeAll(keepingCapacity: keepingCapacity)
        clock = 0
    }

    @inlinable
    mutating func nextAccess() -> UInt64 {
        if clock == .max {
            let keys = entries.sorted { $0.value.access < $1.value.access }.map(\.key)
            for (index, key) in keys.enumerated() { entries[key]?.access = UInt64(index) }
            clock = UInt64(keys.count)
        }
        clock += 1
        return clock
    }
}

/// Retains every input, publishes changed values at the display budget, and
/// permits an immediate final flush without consuming a frame for duplicates.
public struct TaptionLatestValueProjection<Value: Equatable & Sendable>: Sendable {
    public private(set) var latestValue: Value?
    public private(set) var renderedValue: Value?
    private var budget: TaptionPlanNLEInputBudgetEngine

    public init(publishInterval: TimeInterval = TaptionPlanNLEInputBudgetEngine.defaultPublishInterval) {
        budget = TaptionPlanNLEInputBudgetEngine(publishInterval: publishInterval)
    }

    public mutating func begin(with value: Value) {
        reset()
        synchronize(with: value)
    }

    public mutating func synchronize(with value: Value) {
        latestValue = value
        renderedValue = value
    }

    public mutating func submit(_ value: Value, at timestamp: TimeInterval, isFinal: Bool = false) -> Value? {
        latestValue = value
        guard renderedValue != value, timestamp.isFinite,
              budget.submit(at: timestamp, isFinal: isFinal).shouldPublish else { return nil }
        renderedValue = value
        return value
    }

    public mutating func finish(at timestamp: TimeInterval) -> Value? {
        guard let latestValue else { return nil }
        return submit(latestValue, at: timestamp, isFinal: true)
    }

    public mutating func reset() {
        latestValue = nil
        renderedValue = nil
        _ = budget.beginGeneration()
    }
}

public enum TaptionInputFrameGate {
    public static let maximumInputRate: Double = 240
    public static let inputInterval = 1 / maximumInputRate
    public static let maximumRenderRate: Double = 60
    public static let minimumInterval = 1 / maximumRenderRate

    public static func shouldRender(
        lastUptime: inout TimeInterval,
        nowUptime: TimeInterval,
        force: Bool = false,
        minimumInterval: TimeInterval = Self.minimumInterval
    ) -> Bool {
        if lastUptime == 0 {
            lastUptime = nowUptime == 0
                ? .leastNonzeroMagnitude
                : nowUptime
            return true
        }
        guard force || nowUptime - lastUptime >= max(0, minimumInterval) else {
            return false
        }
        lastUptime = nowUptime
        return true
    }
}
