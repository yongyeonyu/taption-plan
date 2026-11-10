import Foundation
import TaptionPlanCore

// 워치 운동 수명·주변 센서 outbox·spool·지우기 순서 정책. (WatchSyncModels.swift에서 나눴다.)

public struct TaptionWatchWorkoutStartGate {
    public struct ResetToken: Hashable {
        fileprivate let id: UUID
        fileprivate let generation: UInt64
    }

    public private(set) var generation: UInt64 = 0
    private var activePurges: Set<UUID> = []
    private var activeReset: UUID?
    private var commerceLocked = false

    public var allowsAmbientRecording: Bool {
        activePurges.isEmpty && activeReset == nil
    }

    public var isPurging: Bool { !activePurges.isEmpty }

    public mutating func beginStart() -> UInt64? {
        guard !commerceLocked, activePurges.isEmpty, activeReset == nil else {
            return nil
        }
        return generation
    }

    public func beginHealthSync() -> UInt64? {
        guard activePurges.isEmpty else { return nil }
        return generation
    }

    public func accepts(_ generation: UInt64) -> Bool {
        self.generation == generation
            && !commerceLocked
            && activePurges.isEmpty
            && activeReset == nil
    }

    public mutating func setCommerceLocked(_ locked: Bool) {
        guard commerceLocked != locked else { return }
        commerceLocked = locked
        if activeReset == nil { generation &+= 1 }
    }

    public mutating func beginReset() -> ResetToken? {
        guard activePurges.isEmpty, activeReset == nil else { return nil }
        generation &+= 1
        let id = UUID()
        activeReset = id
        return ResetToken(id: id, generation: generation)
    }

    public func accepts(_ token: ResetToken) -> Bool {
        token.generation == generation
            && activeReset == token.id
            && activePurges.isEmpty
    }

    public mutating func finishReset(_ token: ResetToken) -> Bool {
        guard activeReset == token.id else { return false }
        activeReset = nil
        return activePurges.isEmpty && token.generation == generation
    }

    public mutating func beginPurge() -> UUID {
        generation &+= 1
        let id = UUID()
        activePurges.insert(id)
        return id
    }

    public mutating func endPurge(_ id: UUID) {
        activePurges.remove(id)
    }

    public init(
        generation: UInt64 = 0
    ) {
        self.generation = generation
    }
}

public enum TaptionWatchWorkoutFinishState: Equatable {
    case idle
    case finishing
    case savedWithSample
    case savedWithoutSample
    case failedMayHavePersisted
    case failed

    public var mayHavePersistedWorkout: Bool {
        switch self {
        case .finishing, .savedWithSample, .savedWithoutSample,
             .failedMayHavePersisted:
            true
        case .idle, .failed:
            false
        }
    }

    public static func successfulFinish(sampleAvailable: Bool) -> Self {
        sampleAvailable ? .savedWithSample : .savedWithoutSample
    }
}

public enum TaptionWatchWorkoutPurgeIntentStore {
    private static let key = "TaptionPlan.watchPendingWorkoutPurgeIDs.v1"

    public static func pendingIdentifiers(
        defaults: UserDefaults = .standard
    ) -> [UUID] {
        var seen = Set<UUID>()
        return (defaults.stringArray(forKey: key) ?? []).compactMap {
            UUID(uuidString: $0)
        }.filter { seen.insert($0).inserted }
    }

    public static func enqueue(
        _ identifier: UUID,
        defaults: UserDefaults = .standard
    ) {
        var identifiers = pendingIdentifiers(defaults: defaults)
        guard !identifiers.contains(identifier) else { return }
        identifiers.append(identifier)
        defaults.set(identifiers.map(\.uuidString), forKey: key)
    }

    public static func remove(
        _ identifier: UUID,
        defaults: UserDefaults = .standard
    ) {
        let identifiers = pendingIdentifiers(defaults: defaults).filter {
            $0 != identifier
        }
        if identifiers.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(identifiers.map(\.uuidString), forKey: key)
        }
    }
}

@MainActor
public enum TaptionWatchWorkoutPurgeReconciliation {
    public enum Failure: Error {
        case deletionUnconfirmed
    }

    public static func run(
        identifiers: [UUID],
        deleteMatchingWorkout: @MainActor (UUID) async throws -> Int,
        matchingWorkoutExists: @MainActor (UUID) async throws -> Bool,
        confirmDeletion: @MainActor (UUID) -> Void
    ) async throws {
        for identifier in identifiers {
            let deletedCount = try await deleteMatchingWorkout(identifier)
            guard deletedCount >= 0 else {
                throw Failure.deletionUnconfirmed
            }
            if deletedCount == 0 {
                let stillExists = try await matchingWorkoutExists(identifier)
                guard !stillExists else {
                    throw Failure.deletionUnconfirmed
                }
            }
            confirmDeletion(identifier)
        }
    }
}

@MainActor
public enum TaptionWatchPurgeSequence {
    public static func run(
        deleteDatabase: @MainActor () async throws -> Void,
        deleteManagerStores: @MainActor () async throws -> Void
    ) async throws {
        try await deleteDatabase()
        try await deleteManagerStores()
    }
}

public enum TaptionWatchAmbientQueueAdoption {
    public static func removePersistedSummaries(
        from pending: inout [TaptionWatchSensorSummary],
        snapshot: Set<TaptionWatchSensorSummary>
    ) {
        pending.removeAll {
            $0.isAmbient == true && snapshot.contains($0)
        }
    }

    public static func removePersistedChunks(
        from pending: inout [TaptionWatchAccelerationChunk],
        snapshot: Set<TaptionWatchAccelerationChunk>
    ) {
        pending.removeAll {
            $0.isAmbient && snapshot.contains($0)
        }
    }
}

public enum TaptionWatchAmbientOutboxRetryPolicy {
    public static func shouldRetry(
        transferFailed: Bool,
        hasDeliveryID: Bool,
        sessionIsActivated: Bool,
        isPurging: Bool
    ) -> Bool {
        transferFailed && hasDeliveryID && sessionIsActivated && !isPurging
    }
}

public enum TaptionWatchAmbientOutboxFlushPolicy {
    public static func shouldContinue(
        startGeneration: UInt64,
        currentGeneration: UInt64,
        isPurging: Bool,
        isCancelled: Bool
    ) -> Bool {
        !isPurging
            && !isCancelled
            && startGeneration == currentGeneration
    }
}

public struct TaptionWatchAmbientLiveDeliveryGate {
    public init() {}

    public static let maximumPending = 4
    public static let maximumPayloadBytes = 32 * 1_024
    public static let retryInterval: TimeInterval = 10

    private var pending: [String: TimeInterval] = [:]

    public mutating func reserve(
        id: String,
        payloadBytes: Int,
        isReachable: Bool,
        now: TimeInterval
    ) -> Bool {
        guard isReachable, now.isFinite, now >= 0,
              id.hasPrefix("summary:") || id.hasPrefix("chunk:"),
              payloadBytes > 0, payloadBytes <= Self.maximumPayloadBytes else {
            return false
        }
        pending = pending.filter {
            now >= $0.value && now - $0.value < Self.retryInterval
        }
        guard pending[id] == nil, pending.count < Self.maximumPending else {
            return false
        }
        pending[id] = now
        return true
    }

    public mutating func acknowledge(_ id: String) {
        pending[id] = nil
    }

    public mutating func reset() {
        pending.removeAll(keepingCapacity: false)
    }
}

public enum TaptionWatchAmbientAcknowledgementRetryPolicy {
    public static let outboxReadRetryID = "outbox-read"
    public static let initialDelay: TimeInterval = 5
    public static let maximumDelay: TimeInterval = 5 * 60

    public static func pendingDeliveryIDs(
        from items: [TaptionPlanV3OutboxItem]
    ) -> [String] {
        items.compactMap { item in
            guard item.kind == TaptionWatchEnvelope.sensorSummaryKey
                    || item.kind == TaptionWatchEnvelope.accelerationChunkKey
            else { return nil }
            return item.id
        }
    }

    @MainActor
    public static func deleteOutboxItem(
        id: String,
        delete: @MainActor () async throws -> Void,
        onFailure: @MainActor (String, any Error) -> Void
    ) async -> Bool {
        do {
            try await delete()
            return true
        } catch {
            onFailure(id, error)
            return false
        }
    }

    public static func shouldRetry(
        retryCount: Int,
        hasDeliveryID: Bool,
        sessionIsActivated: Bool,
        isPurging: Bool
    ) -> Bool {
        retryCount >= 0
            && hasDeliveryID
            && sessionIsActivated
            && !isPurging
    }

    public static func delay(retryCount: Int) -> TimeInterval {
        let exponent = min(max(retryCount, 0), 6)
        return min(maximumDelay, initialDelay * pow(2, Double(exponent)))
    }

    public static func nextRetryCount(after retryCount: Int) -> Int {
        retryCount < Int.max ? max(0, retryCount) + 1 : Int.max
    }

    public static func restoredAttempts(from data: Data?) -> [String: Int] {
        guard let data,
              let values = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return values.filter {
            ($0.key.hasPrefix("summary:")
                || $0.key.hasPrefix("chunk:")
                || $0.key == outboxReadRetryID)
                && $0.value >= 0
        }
    }

    public static func encodedAttempts(_ attempts: [String: Int]) -> Data? {
        try? JSONEncoder().encode(attempts)
    }
}

public enum TaptionWatchAmbientOutboxReadFailurePolicy {
    public static func retryIDs(
        requested: Set<String>?,
        alreadyTracked: Set<String>
    ) -> Set<String> {
        var ids = alreadyTracked.union(requested ?? [])
        if ids.isEmpty {
            ids.insert(
                TaptionWatchAmbientAcknowledgementRetryPolicy.outboxReadRetryID
            )
        }
        return ids
    }
}

public enum TaptionWatchAmbientSampleDeduplicationPolicy {
    public static func shouldProcess(
        _ id: UUID,
        committed: Set<UUID>,
        seen: inout Set<UUID>
    ) -> Bool {
        guard !committed.contains(id) else { return false }
        return seen.insert(id).inserted
    }

    public static func retainingSampleDates(
        _ sampleDates: [String: Date],
        from cutoff: Date
    ) -> [String: Date] {
        sampleDates.filter { $0.value >= cutoff }
    }

    public static func uniqueSamples(
        _ samples: [TaptionWatchAccelerationSample]
    ) -> [TaptionWatchAccelerationSample] {
        var seen = Set<UUID>()
        var unique: [TaptionWatchAccelerationSample] = []
        for sample in samples {
            let stableID = sample.isAmbient
                ? TaptionWatchStableID.ambientAccelerationSample(
                    capturedAt: sample.capturedAt
                ) ?? sample.id
                : sample.id
            guard seen.insert(stableID).inserted else { continue }
            var sample = sample
            if sample.isAmbient { sample.id = stableID }
            unique.append(sample)
        }
        return unique
    }
}

public enum TaptionWatchDurableSpoolPolicy {
    public static func enqueue(
        _ summary: TaptionWatchSensorSummary,
        into pending: inout [TaptionWatchSensorSummary]
    ) {
        if let index = pending.firstIndex(where: {
            $0.rawEventID == summary.rawEventID
        }) {
            pending[index] = summary
        } else {
            pending.append(summary)
        }
        pending.sort {
            if $0.startedAt == $1.startedAt {
                return $0.sequence < $1.sequence
            }
            return $0.startedAt < $1.startedAt
        }
    }

    public static func enqueue(
        _ chunk: TaptionWatchAccelerationChunk,
        into pending: inout [TaptionWatchAccelerationChunk]
    ) {
        if let index = pending.firstIndex(where: { $0.id == chunk.id }) {
            pending[index] = chunk
        } else {
            pending.append(chunk)
        }
        pending.sort { $0.endedAt < $1.endedAt }
    }

    public static func enqueue(
        _ snapshot: TaptionWatchHealthSnapshot,
        into pending: inout [TaptionWatchHealthSnapshot]
    ) {
        if let index = pending.firstIndex(where: {
            $0.capturedAt == snapshot.capturedAt
        }) {
            pending[index] = snapshot
        } else {
            pending.append(snapshot)
        }
        pending.sort { $0.capturedAt < $1.capturedAt }
        // 스냅샷에는 수면 구간 같은 원본이 들어 있다. 연결이 며칠 끊겨도 날마다 남도록
        // 개수(20개)가 아니라 기간으로 자른다(WCH1110A01).
        if let newest = pending.last?.capturedAt {
            let cutoff = newest.addingTimeInterval(-healthSnapshotRetention)
            pending.removeAll { $0.capturedAt < cutoff }
        }
        if pending.count > maximumHealthSnapshots {
            pending.removeFirst(pending.count - maximumHealthSnapshots)
        }
    }

    public static let healthSnapshotRetention: TimeInterval = 14 * 86_400
    public static let maximumHealthSnapshots = 200

    public static func removingCommitted(
        _ committed: [TaptionWatchSensorSummary],
        from pending: [TaptionWatchSensorSummary]
    ) -> [TaptionWatchSensorSummary] {
        pending.filter { value in
            !committed.contains {
                $0.rawEventID == value.rawEventID && $0 == value
            }
        }
    }

    public static func commitForTransfer(
        _ committed: [TaptionWatchSensorSummary],
        from pending: inout [TaptionWatchSensorSummary],
        isCancelled: Bool,
        isPurging: Bool
    ) -> Bool {
        guard !isCancelled, !isPurging else { return false }
        pending = removingCommitted(committed, from: pending)
        return true
    }

    public static func removingCommitted(
        _ committed: [TaptionWatchAccelerationChunk],
        from pending: [TaptionWatchAccelerationChunk]
    ) -> [TaptionWatchAccelerationChunk] {
        pending.filter { value in
            !committed.contains { $0.id == value.id && $0 == value }
        }
    }

    public static func commitForTransfer(
        _ committed: [TaptionWatchAccelerationChunk],
        from pending: inout [TaptionWatchAccelerationChunk],
        isCancelled: Bool,
        isPurging: Bool
    ) -> Bool {
        guard !isCancelled, !isPurging else { return false }
        pending = removingCommitted(committed, from: pending)
        return true
    }

    public static func removingCommitted(
        _ committed: [TaptionWatchHealthSnapshot],
        from pending: [TaptionWatchHealthSnapshot]
    ) -> [TaptionWatchHealthSnapshot] {
        pending.filter { value in
            !committed.contains {
                $0.capturedAt == value.capturedAt && $0 == value
            }
        }
    }

    public static func commitForTransfer(
        _ committed: [TaptionWatchHealthSnapshot],
        from pending: inout [TaptionWatchHealthSnapshot],
        isCancelled: Bool,
        isPurging: Bool
    ) -> Bool {
        guard !isCancelled, !isPurging else { return false }
        pending = removingCommitted(committed, from: pending)
        return true
    }
}

public enum TaptionWatchDurableSpoolCodec {
    public static func encode<Value: Encodable>(_ values: [Value]) -> Data? {
        try? JSONEncoder().encode(values)
    }

    public static func decode<Value: Decodable>(
        _ type: [Value].Type,
        from data: Data?
    ) -> [Value]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

@MainActor
public final class TaptionWatchWorkoutLifecycleBarrier {
    public init() {}

    private var activeOperations = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public func beginOperation() {
        activeOperations += 1
    }

    public func finishOperation() {
        precondition(activeOperations > 0)
        activeOperations -= 1
        guard activeOperations == 0 else { return }
        let readyWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        readyWaiters.forEach { $0.resume() }
    }

    public func waitUntilIdle() async {
        guard activeOperations > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

public struct TaptionWatchAccelerationArchiveAppendIndex: Sendable {
    public init() {}

    private var highestSequenceBySession: [UUID: Int] = [:]
    private var trackedAmbientSessions = Set<UUID>()
    private var ambientSequencesBySession: [UUID: Set<Int>] = [:]
    private var ambientSampleKeys = Set<Int64>()
    private var ambientSampleKeysBySession: [UUID: Set<Int64>] = [:]
    private var unscopedAmbientSampleKeys = Set<Int64>()
    private var unscopedSampleIDs = Set<UUID>()

    public mutating func trackAmbientSessions(_ sessionIDs: Set<UUID>) {
        guard !sessionIDs.isEmpty else { return }
        for sessionID in trackedAmbientSessions where !sessionIDs.contains(sessionID) {
            ambientSequencesBySession[sessionID] = nil
        }
        trackedAmbientSessions = sessionIDs
    }

    /// 다시 보내는 표본은 최근 것뿐이라 이보다 오래된 키는 버린다. 예전에는 20만 개에서 통째로
    /// 비워 중복이 다시 들어오고, 세션별 집합은 줄지 않았다(WCH1110A01).
    public static let ambientKeyRetentionMicros: Int64 = 6 * 3_600 * 1_000_000
    private static let pruneThreshold = 200_000

    private mutating func pruneAmbientKeys(newest: Int64) {
        let floor = newest - Self.ambientKeyRetentionMicros
        ambientSampleKeys = ambientSampleKeys.filter { $0 >= floor }
        unscopedAmbientSampleKeys = unscopedAmbientSampleKeys.filter { $0 >= floor }
        ambientSampleKeysBySession = ambientSampleKeysBySession
            .mapValues { $0.filter { $0 >= floor } }
            .filter { !$0.value.isEmpty }
    }

    public mutating func insert(_ sample: TaptionWatchAccelerationSample) -> Bool {
        if ambientSampleKeys.count + unscopedAmbientSampleKeys.count > Self.pruneThreshold,
           let newest = TaptionWatchStableID.ambientAccelerationTimestampKey(capturedAt: sample.capturedAt) {
            pruneAmbientKeys(newest: newest)
        }
        if sample.isAmbient,
           let stableKey = TaptionWatchStableID.ambientAccelerationTimestampKey(
               capturedAt: sample.capturedAt
            ) {
            if let sessionID = sample.sessionID {
                let isNewForSession = ambientSampleKeysBySession[sessionID, default: []]
                    .insert(stableKey).inserted
                let isNewAcrossSessions = ambientSampleKeys.insert(stableKey).inserted
                return isNewForSession
                    && (isNewAcrossSessions || !trackedAmbientSessions.contains(sessionID))
            }
            return unscopedAmbientSampleKeys.insert(stableKey).inserted
        }
        guard let sessionID = sample.sessionID else {
            return unscopedSampleIDs.insert(sample.id).inserted
        }
        if sample.isAmbient {
            guard trackedAmbientSessions.contains(sessionID) else { return true }
            return ambientSequencesBySession[sessionID, default: []]
                .insert(sample.sequence).inserted
        }
        if let highest = highestSequenceBySession[sessionID],
           sample.sequence <= highest {
            return false
        }
        highestSequenceBySession[sessionID] = sample.sequence
        return true
    }
}

public enum TaptionWatchAmbientRevisionError: Error {
    case exhausted
}

public enum TaptionWatchAmbientRevisionPolicy {
    public static func nextSummaryRevision(
        for summary: TaptionWatchSensorSummary,
        existing: [TaptionWatchSensorSummary]
    ) throws -> TaptionWatchSensorSummary? {
        guard summary.isAmbient == true else { return summary }
        var candidate = summary
        candidate.ambientWindowStart =
            candidate.ambientWindowStart ?? candidate.startedAt
        let matches = existing.filter {
            $0.sessionID == candidate.sessionID
                && $0.sequence == candidate.sequence
        }
        if matches.contains(where: {
            withoutRevision($0) == withoutRevision(candidate)
        }) {
            return nil
        }
        if existing.contains(where: {
            $0.isAmbient == true
                && $0.sessionID != candidate.sessionID
                && sameAmbientContent($0, candidate)
        }) {
            return nil
        }
        let latest = matches.compactMap(\.ambientRevision).max() ?? 0
        guard latest < Int.max else {
            throw TaptionWatchAmbientRevisionError.exhausted
        }
        candidate.ambientRevision = matches.isEmpty ? 0 : latest + 1
        return candidate
    }

    public static func nextChunkRevision(
        for chunk: TaptionWatchAccelerationChunk,
        existing: [TaptionWatchAccelerationChunk],
        windowStart: Date? = nil
    ) throws -> TaptionWatchAccelerationChunk? {
        guard chunk.isAmbient, let sessionID = chunk.sessionID else {
            return chunk
        }
        var candidate = chunk
        candidate.ambientWindowStart = candidate.ambientWindowStart
            ?? windowStart
            ?? candidate.startedAt
        let previousSampleIDs = Set(
            existing
                .filter { $0.isAmbient && $0.sessionID != sessionID }
                .flatMap(\.samples)
                .map {
                    TaptionWatchStableID.ambientAccelerationSample(
                        capturedAt: $0.capturedAt
                    ) ?? $0.id
                }
        )
        if !previousSampleIDs.isEmpty {
            candidate.samples.removeAll { sample in
                let stableID = TaptionWatchStableID.ambientAccelerationSample(
                    capturedAt: sample.capturedAt
                ) ?? sample.id
                return previousSampleIDs.contains(stableID)
            }
            guard let first = candidate.samples.first,
                  let last = candidate.samples.last else { return nil }
            candidate.startedAt = first.capturedAt
            candidate.endedAt = last.capturedAt
        }
        let matches = existing.filter {
            $0.isAmbient
                && $0.sessionID == sessionID
                && $0.sequence == candidate.sequence
        }
        let baseID = TaptionWatchStableID.ambientAccelerationChunkID(
            sessionID: sessionID,
            sequence: candidate.sequence,
            revision: 0
        )
        var normalized = candidate
        normalized.id = baseID
        normalized.ambientRevision = nil
        if matches.contains(where: { value in
            var value = value
            value.id = baseID
            value.ambientRevision = nil
            return value == normalized
        }) {
            return nil
        }
        let latest = matches.compactMap(\.ambientRevision).max() ?? 0
        guard latest < Int.max else {
            throw TaptionWatchAmbientRevisionError.exhausted
        }
        let revision = matches.isEmpty ? 0 : latest + 1
        candidate.ambientRevision = revision
        candidate.id = TaptionWatchStableID.ambientAccelerationChunkID(
            sessionID: sessionID,
            sequence: candidate.sequence,
            revision: revision
        )
        return candidate
    }

    private static func withoutRevision(
        _ summary: TaptionWatchSensorSummary
    ) -> TaptionWatchSensorSummary {
        var value = summary
        value.ambientRevision = nil
        return value
    }

    private static func sameAmbientContent(
        _ lhs: TaptionWatchSensorSummary,
        _ rhs: TaptionWatchSensorSummary
    ) -> Bool {
        var lhs = lhs
        var rhs = rhs
        rhs.sessionID = lhs.sessionID
        rhs.sequence = lhs.sequence
        lhs.ambientWindowStart = nil
        rhs.ambientWindowStart = nil
        lhs.ambientRevision = nil
        rhs.ambientRevision = nil
        return lhs == rhs
    }
}

public enum TaptionWatchPurgeGenerationPolicy {
    public static func shouldExecute(
        requested: UInt64,
        completed: UInt64
    ) -> Bool {
        requested > completed
    }
}
