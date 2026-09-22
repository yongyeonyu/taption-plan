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

public actor HealthKitImportStore {
    public static let eventDomain = "healthkit-sample"
    public static let applicationGroupIdentifier = TaptionPlanSharedContainer.appGroupIdentifier
    public static let databaseFileName = "healthkit-local-v1.sqlite"

    private static let stateDomainPrefix = "healthkit.sync-state."
    private static let stateDay = TaptionPlanDayKey(year: 0, month: 0, day: 0)
    private static let maximumRecordDurationMetadataKey =
        "healthkit.maximum-record-duration-v1"

    private let dayStore: TaptionPlanDayStore
    private let writeLockURL: URL
    private var dataDeletionGeneration: UInt64

    public init(databaseURL: URL) throws {
        dayStore = try TaptionPlanDayStore(url: databaseURL, allowsUndatedSnapshots: true)
        writeLockURL = databaseURL.appendingPathExtension("lock")
        dataDeletionGeneration = TaptionDataDeletionFence.currentGeneration()
    }

    public init(fileManager: FileManager = .default) throws {
        let root = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: Self.applicationGroupIdentifier
        ) ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directory = root.appendingPathComponent(
            "TaptionPlan/HealthKit",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var protectedDirectory = directory
        try protectedDirectory.setResourceValues(resourceValues)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        try self.init(
            databaseURL: directory.appendingPathComponent(Self.databaseFileName)
        )
    }

    @discardableResult
    public func upsert(_ records: [HealthKitSampleRecord]) async throws -> Int {
        let generation = dataDeletionGeneration
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration(generation)
        let uniqueRecords = records.reduce(into: [UUID: HealthKitSampleRecord]()) {
            $0[$1.uuid] = $1
        }.values
        let events = try uniqueRecords.map { record in
            try makeEvent(for: record)
        }
        try await updateMaximumRecordDuration(for: uniqueRecords)
        try checkDataGeneration(generation)
        try await dayStore.upsertEvents(events)
        return events.count
    }

    public func delete(ids: [UUID]) async throws {
        let generation = dataDeletionGeneration
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration(generation)
        try await dayStore.deleteEvents(
            ids: ids.map(HealthKitSampleRecord.eventID(for:)),
            domain: Self.eventDomain
        )
    }

    public func existingRecordIDs(_ ids: [UUID]) async throws -> Set<UUID> {
        let byEventID = ids.reduce(into: [String: UUID]()) {
            $0[HealthKitSampleRecord.eventID(for: $1)] = $1
        }
        let existing = try await dayStore.existingEventIdentifiers(
            Array(byEventID.keys),
            domain: Self.eventDomain
        )
        return Set(existing.compactMap { byEventID[$0.rawValue] })
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
        let uniqueRecords = records.reduce(into: [UUID: HealthKitSampleRecord]()) {
            $0[$1.uuid] = $1
        }.values
        let events = try uniqueRecords.map(makeEvent)
        try await updateMaximumRecordDuration(for: uniqueRecords)
        let domain = Self.stateDomain(for: state.typeIdentifier)
        let currentRevision = try await dayStore.snapshot(
            domain: domain,
            day: Self.stateDay
        )?.revision ?? 0
        guard currentRevision < UInt64.max else {
            throw HealthKitImportStoreError.revisionOverflow
        }
        let encodedState = try TaptionPlanCanonicalStorage.encode(state)
        let stateSnapshot = TaptionPlanDayStore.Snapshot(
            domain: domain,
            day: Self.stateDay,
            revision: currentRevision + 1,
            updatedAt: state.lastSyncedAt ?? .now,
            payload: TaptionPlanCanonicalStorage.envelope(for: encodedState)
        )
        try checkDataGeneration(generation)
        try await dayStore.applyEventDelta(
            upserting: events,
            deletingIDs: deletedIDs.map(HealthKitSampleRecord.eventID(for:)),
            domain: Self.eventDomain,
            snapshots: [stateSnapshot]
        )
    }

    public func records(from start: Date, through end: Date) async throws -> [HealthKitSampleRecord] {
        guard start <= end else { throw HealthKitImportStoreError.invalidDateRange }
        let maximumDuration = try await maximumRecordDuration()
        let queryStart = start.addingTimeInterval(-maximumDuration)
        let events = try await dayStore.events(
            from: TaptionPlanDayKey(date: queryStart),
            through: TaptionPlanDayKey(date: end),
            domain: Self.eventDomain
        )
        return try events.compactMap { event in
            let record = try decodeRecord(from: event.payload)
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
        return try await dayStore.codableSnapshot(
            HealthKitTypeSyncState.self,
            domain: Self.stateDomain(for: typeIdentifier),
            day: Self.stateDay
        )
    }

    /// Stores only the sync checkpoint. Main can combine it with event changes using DayStore's atomic delta API.
    public func saveSyncState(_ state: HealthKitTypeSyncState) async throws {
        let generation = dataDeletionGeneration
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration(generation)
        try validate(typeIdentifier: state.typeIdentifier)
        let domain = Self.stateDomain(for: state.typeIdentifier)
        let currentRevision = try await dayStore.snapshot(domain: domain, day: Self.stateDay)?.revision ?? 0
        guard currentRevision < UInt64.max else { throw HealthKitImportStoreError.revisionOverflow }
        try checkDataGeneration(generation)
        try await dayStore.saveCodableSnapshot(
            state,
            domain: domain,
            day: Self.stateDay,
            revision: currentRevision + 1,
            updatedAt: state.lastSyncedAt ?? .now
        )
    }

    public func overview() async throws -> HealthKitSyncOverview {
        let snapshots = try await dayStore.snapshots(day: Self.stateDay)
        let states = try snapshots
            .filter { $0.domain.hasPrefix(Self.stateDomainPrefix) }
            .map { snapshot in
                let encoded = try TaptionPlanCanonicalStorage.encodedPayload(from: snapshot.payload)
                return try TaptionPlanCanonicalStorage.decode(
                    HealthKitTypeSyncState.self,
                    from: encoded
                )
            }
        return HealthKitSyncOverview(states: states)
    }

    public func deleteAll(generation: UInt64? = nil) async throws {
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        dataDeletionGeneration = generation
            ?? TaptionDataDeletionFence.currentGeneration()
        try await dayStore.deleteAllContent()
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
        let current = try await maximumRecordDurationHoldingLock()
        guard candidate > current else { return }
        try await dayStore.setMetadata(
            String(candidate),
            forKey: Self.maximumRecordDurationMetadataKey
        )
    }

    private func maximumRecordDuration() async throws -> TimeInterval {
        if let stored = try await storedMaximumRecordDuration() {
            return stored
        }
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        return try await maximumRecordDurationHoldingLock()
    }

    private func maximumRecordDurationHoldingLock() async throws -> TimeInterval {
        if let stored = try await storedMaximumRecordDuration() {
            return stored
        }
        let events = try await dayStore.allEvents(domain: Self.eventDomain)
        var maximum: TimeInterval = 0
        for event in events {
            let record = try decodeRecord(from: event.payload)
            maximum = max(maximum, Self.recordDuration(record) ?? 0)
        }
        try await dayStore.setMetadata(
            String(maximum),
            forKey: Self.maximumRecordDurationMetadataKey
        )
        return maximum
    }

    private func storedMaximumRecordDuration() async throws -> TimeInterval? {
        guard let value = try await dayStore.metadata(
            forKey: Self.maximumRecordDurationMetadataKey
        ), let duration = TimeInterval(value), duration.isFinite,
              duration >= 0 else { return nil }
        return duration
    }

    private static func recordDuration(
        _ record: HealthKitSampleRecord
    ) -> TimeInterval? {
        let duration = record.endDate.timeIntervalSince(record.startDate)
        guard duration.isFinite, duration >= 0 else { return nil }
        return duration
    }

    private func makeEvent(for record: HealthKitSampleRecord) throws -> TaptionPlanDayStore.Event {
        let encoded = try TaptionPlanCanonicalStorage.encode(record)
        return TaptionPlanDayStore.Event(
            day: TaptionPlanDayKey(date: record.startDate),
            timestamp: record.startDate,
            sequence: 0,
            id: record.eventID,
            domain: Self.eventDomain,
            payload: TaptionPlanCanonicalStorage.envelope(for: encoded)
        )
    }

    private func decodeRecord(from envelope: Data) throws -> HealthKitSampleRecord {
        let encoded = try TaptionPlanCanonicalStorage.encodedPayload(from: envelope)
        return try TaptionPlanCanonicalStorage.decode(HealthKitSampleRecord.self, from: encoded)
    }

    private static func stateDomain(for typeIdentifier: String) -> String {
        "\(stateDomainPrefix)\(typeIdentifier)"
    }

    private func validate(typeIdentifier: String) throws {
        guard !typeIdentifier.isEmpty else {
            throw HealthKitImportStoreError.invalidTypeIdentifier
        }
    }
}
