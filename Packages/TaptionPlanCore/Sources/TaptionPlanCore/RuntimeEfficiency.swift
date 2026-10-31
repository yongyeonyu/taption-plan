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

/// 입력은 240Hz까지 받고, SwiftUI 레이아웃 상태는 60Hz로 합친다.
/// 지도 카메라·화랑이·카운터처럼 UIKit/Core Animation이 직접 그리는 것은 `maximumDirectRenderRate`(120Hz)까지 쓴다.
public enum TaptionInputFrameGate {
    public static let maximumInputRate: Double = 240
    public static let inputInterval = 1 / maximumInputRate
    public static let maximumRenderRate: Double = 60
    public static let minimumInterval = 1 / maximumRenderRate
    public static let maximumDirectRenderRate: Double = 120

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

/// 창 안에서 걸러진 마지막 입력을 창 끝에 한 번 보낸다(PRF1101A01).
/// `TaptionInputFrameGate`만 쓰면 손가락이 멈춘 순간의 값이 다음 입력이나 손을 뗄 때까지 화면에 오르지 않았다.
public struct TaptionTrailingInputGate<Value> {
    public enum Decision {
        /// 지금 반영한다.
        case deliver(Value)
        /// 값을 붙잡아 두었다. 이 시각에 `flush`를 부른다(이미 예약했으면 `nil`).
        case deferred(flushAtUptime: TimeInterval?)
    }

    public let minimumInterval: TimeInterval
    private var lastUptime: TimeInterval = 0
    private var pending: Value?
    private var isFlushScheduled = false

    public init(minimumInterval: TimeInterval = TaptionInputFrameGate.minimumInterval) {
        self.minimumInterval = minimumInterval
    }

    public var hasPendingValue: Bool { pending != nil }

    public mutating func submit(_ value: Value, nowUptime: TimeInterval, force: Bool = false) -> Decision {
        if TaptionInputFrameGate.shouldRender(
            lastUptime: &lastUptime,
            nowUptime: nowUptime,
            force: force,
            minimumInterval: minimumInterval
        ) {
            pending = nil
            return .deliver(value)
        }
        pending = value
        guard !isFlushScheduled else { return .deferred(flushAtUptime: nil) }
        isFlushScheduled = true
        return .deferred(flushAtUptime: lastUptime + minimumInterval)
    }

    /// 예약한 시각에 부른다. 그사이 새 값이 반영됐으면 `nil`.
    public mutating func flush(nowUptime: TimeInterval) -> Value? {
        isFlushScheduled = false
        guard let value = pending else { return nil }
        pending = nil
        lastUptime = nowUptime
        return value
    }

    public mutating func reset() {
        lastUptime = 0
        pending = nil
        isFlushScheduled = false
    }
}

/// `TaptionTrailingInputGate`를 메인 액터에서 예약까지 맡는 상자. 화면 쪽은 `submit`만 부른다.
@MainActor
public final class TaptionTrailingInputScheduler<Value> {
    private var gate: TaptionTrailingInputGate<Value>
    private var flushTask: Task<Void, Never>?
    /// 화면 쪽이 제스처마다 최신 클로저로 바꿔 끼울 수 있다(SwiftUI 화면 값은 매번 새로 만들어진다).
    public var deliver: (Value) -> Void

    public init(
        minimumInterval: TimeInterval = TaptionInputFrameGate.minimumInterval,
        deliver: @escaping (Value) -> Void = { _ in }
    ) {
        gate = TaptionTrailingInputGate(minimumInterval: minimumInterval)
        self.deliver = deliver
    }

    public func submit(_ value: Value, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        switch gate.submit(value, nowUptime: now, force: force) {
        case .deliver(let value):
            deliver(value)
        case .deferred(let flushAt?):
            flushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0, flushAt - now)))
                guard let self, !Task.isCancelled else { return }
                if let value = self.gate.flush(nowUptime: ProcessInfo.processInfo.systemUptime) {
                    self.deliver(value)
                }
            }
        case .deferred(nil):
            break
        }
    }

    public func reset() {
        flushTask?.cancel()
        flushTask = nil
        gate.reset()
    }
}

