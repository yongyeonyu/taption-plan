import Foundation
import TaptionPlanCore

public enum HealthKitImportStoreError: Error, Equatable, Sendable {
    case appGroupUnavailable
    case invalidDateRange
    case invalidTypeIdentifier
    case revisionOverflow
}

public struct HealthKitSampleRecord: Identifiable, Codable, Hashable, Sendable {
    public let uuid: UUID
    public let typeIdentifier: String
    public let startDate: Date
    public let endDate: Date
    public let numericValue: Double?
    public let unit: String?
    public let categoryValue: Int?
    public let textValue: String?
    public let binaryData: Data?
    public let childIDs: [UUID]
    public let sourceName: String?
    public let sourceBundleIdentifier: String?
    public let sourceVersion: String?
    public let sourceProductType: String?
    public let deviceName: String?
    public let deviceManufacturer: String?
    public let deviceModel: String?
    public let deviceHardwareVersion: String?
    public let deviceFirmwareVersion: String?
    public let deviceSoftwareVersion: String?
    public let deviceLocalIdentifier: String?
    public let deviceUDI: String?
    public let userEntered: Bool
    public let timeZoneIdentifier: String?
    public let metadata: [String: String]
    public let modelVersion: String

    public var id: UUID { uuid }

    public init(
        uuid: UUID,
        typeIdentifier: String,
        startDate: Date,
        endDate: Date,
        numericValue: Double? = nil,
        unit: String? = nil,
        categoryValue: Int? = nil,
        textValue: String? = nil,
        binaryData: Data? = nil,
        childIDs: [UUID] = [],
        sourceName: String? = nil,
        sourceBundleIdentifier: String? = nil,
        sourceVersion: String? = nil,
        sourceProductType: String? = nil,
        deviceName: String? = nil,
        deviceManufacturer: String? = nil,
        deviceModel: String? = nil,
        deviceHardwareVersion: String? = nil,
        deviceFirmwareVersion: String? = nil,
        deviceSoftwareVersion: String? = nil,
        deviceLocalIdentifier: String? = nil,
        deviceUDI: String? = nil,
        userEntered: Bool = false,
        timeZoneIdentifier: String? = nil,
        metadata: [String: String] = [:],
        modelVersion: String = "healthkit-sample-v1"
    ) {
        self.uuid = uuid
        self.typeIdentifier = typeIdentifier
        self.startDate = startDate
        self.endDate = endDate
        self.numericValue = numericValue
        self.unit = unit
        self.categoryValue = categoryValue
        self.textValue = textValue
        self.binaryData = binaryData
        self.childIDs = childIDs
        self.sourceName = sourceName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sourceVersion = sourceVersion
        self.sourceProductType = sourceProductType
        self.deviceName = deviceName
        self.deviceManufacturer = deviceManufacturer
        self.deviceModel = deviceModel
        self.deviceHardwareVersion = deviceHardwareVersion
        self.deviceFirmwareVersion = deviceFirmwareVersion
        self.deviceSoftwareVersion = deviceSoftwareVersion
        self.deviceLocalIdentifier = deviceLocalIdentifier
        self.deviceUDI = deviceUDI
        self.userEntered = userEntered
        self.timeZoneIdentifier = timeZoneIdentifier
        self.metadata = metadata
        self.modelVersion = modelVersion
    }

    public var eventID: String {
        Self.eventID(for: uuid)
    }

    public static func eventID(for uuid: UUID) -> String {
        "healthkit:\(uuid.uuidString)"
    }
}

public struct HealthKitTypeSyncState: Codable, Hashable, Sendable {
    public let typeIdentifier: String
    public let anchor: Data?
    public let historyCursor: Data?
    public let historyComplete: Bool
    public let sampleCount: Int
    public let addedCount: Int
    public let updatedCount: Int
    public let deletedCount: Int
    public let lastSampleDate: Date?
    public let lastDeletionDate: Date?
    public let lastSyncedAt: Date?
    public let lastError: String?
    public let modelVersion: String

    public init(
        typeIdentifier: String,
        anchor: Data? = nil,
        historyCursor: Data? = nil,
        historyComplete: Bool = false,
        sampleCount: Int = 0,
        addedCount: Int = 0,
        updatedCount: Int = 0,
        deletedCount: Int = 0,
        lastSampleDate: Date? = nil,
        lastDeletionDate: Date? = nil,
        lastSyncedAt: Date? = nil,
        lastError: String? = nil,
        modelVersion: String = "healthkit-sync-v1"
    ) {
        self.typeIdentifier = typeIdentifier
        self.anchor = anchor
        self.historyCursor = historyCursor
        self.historyComplete = historyComplete
        self.sampleCount = sampleCount
        self.addedCount = addedCount
        self.updatedCount = updatedCount
        self.deletedCount = deletedCount
        self.lastSampleDate = lastSampleDate
        self.lastDeletionDate = lastDeletionDate
        self.lastSyncedAt = lastSyncedAt
        self.lastError = lastError
        self.modelVersion = modelVersion
    }
}

public struct HealthKitSyncOverview: Codable, Hashable, Sendable {
    public let states: [HealthKitTypeSyncState]

    public init(states: [HealthKitTypeSyncState]) {
        self.states = states.sorted { $0.typeIdentifier < $1.typeIdentifier }
    }

    public var totalSampleCount: Int {
        states.reduce(0) { $0 + $1.sampleCount }
    }

    public var totalAddedCount: Int {
        states.reduce(0) { $0 + $1.addedCount }
    }

    public var totalUpdatedCount: Int {
        states.reduce(0) { $0 + $1.updatedCount }
    }

    public var totalDeletedCount: Int {
        states.reduce(0) { $0 + $1.deletedCount }
    }

    public var completedTypeCount: Int {
        states.filter(\.historyComplete).count
    }

    public var failedTypeCount: Int {
        states.filter { $0.lastError != nil }.count
    }

    public var lastSyncedAt: Date? {
        states.compactMap(\.lastSyncedAt).max()
    }

    public var lastError: String? {
        states
            .sorted { ($0.lastSyncedAt ?? .distantPast) > ($1.lastSyncedAt ?? .distantPast) }
            .compactMap(\.lastError)
            .first
    }
}

/// HealthKit에서 가져온 샘플과 종류별 동기화 위치를 새 저장소의 `records` 표에 둔다.
/// 샘플은 가져온 값(`imported`)이며, 본문 JSON에 출처 앱·기기 정보가 그대로 남는다.
public actor HealthKitImportStore {
    public static let eventDomain = "healthkit-sample"
    public static let applicationGroupIdentifier = TaptionPlanSharedContainer.appGroupIdentifier

    private static let stateKind = "healthkit-sync-state"
    private static let maximumRecordDurationMetadataKey =
        "healthkit.maximum-record-duration-v1"

    private let store: TaptionStoreV2
    private let writeLockURL: URL
    private var dataDeletionGeneration: UInt64

    public init(databaseURL: URL) throws {
        store = try TaptionStoreV2(url: databaseURL)
        writeLockURL = databaseURL.appendingPathExtension("lock")
        dataDeletionGeneration = TaptionDataDeletionFence.currentGeneration()
    }

    public init(fileManager: FileManager = .default) throws {
        let shared = try TaptionStoreV2.applicationSupport(fileManager: fileManager)
        store = shared
        writeLockURL = shared.url.appendingPathExtension("lock")
        dataDeletionGeneration = TaptionDataDeletionFence.currentGeneration()
    }

    @discardableResult
    public func upsert(_ records: [HealthKitSampleRecord]) async throws -> Int {
        let generation = dataDeletionGeneration
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration(generation)
        let uniqueRecords = Self.unique(records)
        let rows = try uniqueRecords.map(makeRow)
        try await updateMaximumRecordDuration(for: uniqueRecords)
        try checkDataGeneration(generation)
        try await store.upsertRecords(rows)
        return rows.count
    }

    public func delete(ids: [UUID]) async throws {
        let generation = dataDeletionGeneration
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration(generation)
        try await store.applyRecordChanges(
            upserts: [],
            deletes: ids.map { (Self.eventDomain, HealthKitSampleRecord.eventID(for: $0)) }
        )
    }

    public func existingRecordIDs(_ ids: [UUID]) async throws -> Set<UUID> {
        let byEventID = ids.reduce(into: [String: UUID]()) {
            $0[HealthKitSampleRecord.eventID(for: $1)] = $1
        }
        let existing = try await store.existingRecordIDs(
            kind: Self.eventDomain,
            ids: Array(byEventID.keys)
        )
        return Set(existing.compactMap { byEventID[$0] })
    }

    public func apply(
        records: [HealthKitSampleRecord],
        deletedIDs: [UUID],
        state: HealthKitTypeSyncState
    ) async throws {
        let generation = dataDeletionGeneration
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration(generation)
        try validate(typeIdentifier: state.typeIdentifier)
        let uniqueRecords = Self.unique(records)
        let rows = try uniqueRecords.map(makeRow) + [makeStateRow(state)]
        try await updateMaximumRecordDuration(for: uniqueRecords)
        try checkDataGeneration(generation)
        try await store.applyRecordChanges(
            upserts: rows,
            deletes: deletedIDs.map { (Self.eventDomain, HealthKitSampleRecord.eventID(for: $0)) }
        )
    }

    public func records(from start: Date, through end: Date) async throws -> [HealthKitSampleRecord] {
        guard start <= end else { throw HealthKitImportStoreError.invalidDateRange }
        let maximumDuration = try await maximumRecordDuration()
        let queryStart = start.addingTimeInterval(-maximumDuration)
        // 저장소의 범위 조회는 끝을 포함하지 않으므로 끝 바로 다음 시각까지 읽고 아래에서 걸러 낸다.
        let queryEnd = Date(timeIntervalSince1970: end.timeIntervalSince1970.nextUp)
        let rows = try await store.records(kind: Self.eventDomain, from: queryStart, to: queryEnd)
        return try rows.compactMap { row in
            let record = try Self.decode(HealthKitSampleRecord.self, from: row.body)
            return record.startDate <= end && record.endDate >= start ? record : nil
        }
    }

    public func allRecords() async throws -> [HealthKitSampleRecord] {
        try await records(
            from: Date(timeIntervalSince1970: 0),
            through: .now
        )
    }

    public func syncState(for typeIdentifier: String) async throws -> HealthKitTypeSyncState? {
        try validate(typeIdentifier: typeIdentifier)
        let id = Self.stateID(for: typeIdentifier)
        return try await store.records(kind: Self.stateKind)
            .first { $0.id == id }
            .map { try Self.decode(HealthKitTypeSyncState.self, from: $0.body) }
    }

    /// 동기화 위치만 저장한다. 샘플 변경과 함께 저장하려면 `apply`를 쓴다.
    public func saveSyncState(_ state: HealthKitTypeSyncState) async throws {
        let generation = dataDeletionGeneration
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration(generation)
        try validate(typeIdentifier: state.typeIdentifier)
        let row = try makeStateRow(state)
        try checkDataGeneration(generation)
        try await store.upsertRecords([row])
    }

    public func overview() async throws -> HealthKitSyncOverview {
        let states = try await store.records(kind: Self.stateKind).map {
            try Self.decode(HealthKitTypeSyncState.self, from: $0.body)
        }
        return HealthKitSyncOverview(states: states)
    }

    public func deleteAll(generation: UInt64? = nil) async throws {
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        dataDeletionGeneration = generation
            ?? TaptionDataDeletionFence.currentGeneration()
        try await store.deleteRecords(kinds: [Self.eventDomain, Self.stateKind])
        try await store.deleteMeta(Self.maximumRecordDurationMetadataKey)
    }

    private func checkDataGeneration(_ generation: UInt64) throws {
        guard generation == dataDeletionGeneration,
              TaptionDataDeletionFence.allows(generation: generation) else {
            throw CancellationError()
        }
    }

    private func updateMaximumRecordDuration(
        for records: some Collection<HealthKitSampleRecord>
    ) async throws {
        guard let candidate = records.lazy
            .compactMap(Self.recordDuration)
            .max() else { return }
        let current = try await maximumRecordDuration()
        guard candidate > current else { return }
        try await store.setMeta(Self.maximumRecordDurationMetadataKey, String(candidate))
    }

    /// 가장 긴 샘플의 길이. 조회 범위를 이만큼 앞으로 넓혀 범위에 걸치는 긴 샘플을 놓치지 않는다.
    private func maximumRecordDuration() async throws -> TimeInterval {
        if let value = try await store.meta(Self.maximumRecordDurationMetadataKey),
           let duration = TimeInterval(value), duration.isFinite, duration >= 0 {
            return duration
        }
        var maximum: TimeInterval = 0
        for row in try await store.records(kind: Self.eventDomain) {
            let record = try Self.decode(HealthKitSampleRecord.self, from: row.body)
            maximum = max(maximum, Self.recordDuration(record) ?? 0)
        }
        try await store.setMeta(Self.maximumRecordDurationMetadataKey, String(maximum))
        return maximum
    }

    private static func recordDuration(
        _ record: HealthKitSampleRecord
    ) -> TimeInterval? {
        let duration = record.endDate.timeIntervalSince(record.startDate)
        guard duration.isFinite, duration >= 0 else { return nil }
        return duration
    }

    private static func unique(_ records: [HealthKitSampleRecord]) -> [HealthKitSampleRecord] {
        Array(records.reduce(into: [UUID: HealthKitSampleRecord]()) { $0[$1.uuid] = $1 }.values)
    }

    private func makeRow(for record: HealthKitSampleRecord) throws -> TaptionStoreRecord {
        TaptionStoreRecord(
            id: record.eventID,
            kind: Self.eventDomain,
            start: record.startDate,
            end: record.endDate,
            updatedAt: .now,
            origin: .imported,
            body: try Self.encode(record)
        )
    }

    private func makeStateRow(_ state: HealthKitTypeSyncState) throws -> TaptionStoreRecord {
        TaptionStoreRecord(
            id: Self.stateID(for: state.typeIdentifier),
            kind: Self.stateKind,
            start: nil,
            end: nil,
            updatedAt: state.lastSyncedAt ?? .now,
            origin: .auto,
            body: try Self.encode(state)
        )
    }

    private static func stateID(for typeIdentifier: String) -> String {
        "healthkit-state:\(typeIdentifier)"
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan"
        )
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from body: String) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan"
        )
        return try decoder.decode(type, from: Data(body.utf8))
    }

    private func validate(typeIdentifier: String) throws {
        guard !typeIdentifier.isEmpty else {
            throw HealthKitImportStoreError.invalidTypeIdentifier
        }
    }
}
