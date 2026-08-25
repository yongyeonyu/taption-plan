import CloudKit
import Compression
import Foundation
import OSLog
#if canImport(TaptionPlanCore)
import TaptionPlanCore
#endif

protocol PlanDataRepository: Sendable {
    func load() async throws -> TaptionDataSnapshot
    func save(_ snapshot: TaptionDataSnapshot) async throws
}

enum TaptionLocalDatabaseLocation {
    static let fileName = "taption-data-v2.sqlite"

    static func sharedOrApplicationSupport(
        fileManager: FileManager = .default
    ) throws -> URL {
        if let directory = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier:
                TaptionWidgetSharedStore.appGroupIdentifier
        ) {
            return directory.appendingPathComponent(fileName)
        }
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent(
            "TaptionPlan",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent(fileName)
    }
}

actor MigratingPlanRepository: PlanDataRepository {
    private let primary: any PlanDataRepository
    private let legacy: any PlanDataRepository
    private var migrationTask: Task<Void, Never>?

    init(
        primary: any PlanDataRepository,
        legacy: any PlanDataRepository
    ) {
        self.primary = primary
        self.legacy = legacy
    }

    func load() async throws -> TaptionDataSnapshot {
        let shared: TaptionDataSnapshot
        do {
            shared = try await primary.load()
        } catch {
            // A damaged shared file must never make the app fall back to an
            // empty snapshot and overwrite the last good device copy.
            if let existing = try? await legacy.load(),
               existing.updatedAt != .distantPast {
                schedulePrimaryMigration(existing)
                return existing
            }
            throw error
        }
        guard shared.updatedAt == .distantPast else {
            return shared
        }
        let existing = try await legacy.load()
        guard existing.updatedAt != .distantPast else {
            return shared
        }
        schedulePrimaryMigration(existing)
        return existing
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        migrationTask?.cancel()
        migrationTask = nil
        try await primary.save(snapshot)
    }

    private func schedulePrimaryMigration(_ snapshot: TaptionDataSnapshot) {
        guard migrationTask == nil else { return }
        let primary = self.primary
        migrationTask = Task.detached(priority: .utility) {
            // A caller may save a newer snapshot as soon as the legacy value
            // is returned. Never let this one-time import overwrite it, and
            // never replace a primary that failed to decode.
            guard !Task.isCancelled,
                  let current = try? await primary.load(),
                  !Task.isCancelled,
                  current.updatedAt == .distantPast else {
                return
            }
            guard !Task.isCancelled else { return }
            try? await primary.save(snapshot)
        }
    }
}

enum RepositoryError: Error, Equatable {
    case invalidSnapshot
    case unsupportedSchema(Int)
    case cloudAccountUnavailable
    case cloudSchemaUnavailable
    case cloudPayloadMissing
    case appGroupUnavailable
}

/// Keeps the shared snapshot small without changing its on-disk path.  The
/// decoder accepts the old plain JSON file so existing installs migrate on
/// their next save.
enum TaptionSnapshotCompression {
    private static let magic: [UInt8] = [0x54, 0x50, 0x5A, 0x31]
    private static let headerSize = magic.count + 8
    private static let minimumSize = 4 * 1024

    static func encode(_ json: Data) -> Data {
        guard json.count >= minimumSize else { return json }
        var compressed = Data(repeating: 0, count: json.count + 64)
        let encodedCount: Int = json.withUnsafeBytes { source in
            compressed.withUnsafeMutableBytes { destination in
                guard let sourceBase = source.bindMemory(to: UInt8.self)
                    .baseAddress,
                    let destinationBase = destination.bindMemory(
                        to: UInt8.self
                    ).baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    destinationBase,
                    destination.count,
                    sourceBase,
                    json.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard encodedCount > 0,
              encodedCount + headerSize < json.count else {
            return json
        }

        var result = Data(magic)
        appendLittleEndian(UInt64(json.count), to: &result)
        result.append(compressed.prefix(encodedCount))
        return result
    }

    static func decode(_ data: Data) -> Data {
        guard data.count > headerSize,
              data.prefix(magic.count).elementsEqual(magic) else {
            return data
        }

        let originalSize = readLittleEndian(
            data.dropFirst(magic.count).prefix(8)
        )
        guard originalSize > 0,
              originalSize <= UInt64(Int.max) else {
            return data
        }
        let expectedSize = Int(originalSize)
        var decoded = Data(repeating: 0, count: expectedSize)
        let compressed = data.dropFirst(headerSize)
        let decodedCount: Int = compressed.withUnsafeBytes { source in
            decoded.withUnsafeMutableBytes { destination in
                guard let sourceBase = source.bindMemory(to: UInt8.self)
                    .baseAddress,
                    let destinationBase = destination.bindMemory(
                        to: UInt8.self
                    ).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase,
                    destination.count,
                    sourceBase,
                    compressed.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        return decodedCount == expectedSize ? decoded : data
    }

    private static func appendLittleEndian(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, to: 64, by: 8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    private static func readLittleEndian(_ data: Data.SubSequence) -> UInt64 {
        data.enumerated().reduce(into: UInt64(0)) { result, item in
            result |= UInt64(item.element) << UInt64(item.offset * 8)
        }
    }
}

actor FilePlanRepository: PlanDataRepository {
    private static let logger = Logger(
        subsystem: "com.taption.plan",
        category: "WidgetSyncRepository"
    )

    private let fileURL: URL
    private let storageLabel: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var backupURL: URL {
        fileURL.appendingPathExtension("backup")
    }

    init(fileURL: URL, storageLabel: String = "file") {
        self.fileURL = fileURL
        self.storageLabel = storageLabel
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate.bitPattern)
        }
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            // Older files used the bit pattern of a reference-date Double;
            // exported and newer legacy files use seconds since 1970. Decode
            // the integer form first so a UInt64 bit pattern is lossless, and
            // use Double for fractional or negative Unix timestamps.
            if let raw = try? container.decode(UInt64.self) {
                if raw <= 1_000_000_000_000 {
                    return Date(timeIntervalSince1970: Double(raw))
                }
                return Date(
                    timeIntervalSinceReferenceDate: Double(bitPattern: raw)
                )
            }
            let seconds = try container.decode(Double.self)
            guard seconds.isFinite,
                  abs(seconds) <= 1_000_000_000_000 else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported date encoding"
                )
            }
            return Date(timeIntervalSince1970: seconds)
        }
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> FilePlanRepository {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent("TaptionPlan", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return FilePlanRepository(
            fileURL: directory.appendingPathComponent("taption-data-v1.json"),
            storageLabel: "application-support"
        )
    }

    static func appGroup(
        identifier: String = TaptionWidgetSharedStore.appGroupIdentifier,
        fileManager: FileManager = .default
    ) throws -> FilePlanRepository {
        guard let directory = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) else {
            throw RepositoryError.appGroupUnavailable
        }
        return FilePlanRepository(
            fileURL: directory.appendingPathComponent(
                "taption-data-v1.json"
            ),
            storageLabel: "app-group"
        )
    }

    func load() async throws -> TaptionDataSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            if let recovered = try? loadSnapshot(at: backupURL) {
                Self.logger.error(
                    "Repository primary missing; recovered backup: storage=\(self.storageLabel, privacy: .public)"
                )
                return recovered
            }
            Self.logger.notice(
                "Repository load empty: storage=\(self.storageLabel, privacy: .public)"
            )
            return .empty
        }
        do {
            let (snapshot, storedBytes, jsonBytes) = try loadSnapshotWithSizes(
                at: fileURL
            )
            Self.logger.debug(
                "Repository load: storage=\(self.storageLabel, privacy: .public), bytes=\(storedBytes, privacy: .public), jsonBytes=\(jsonBytes, privacy: .public), updated=\(snapshot.updatedAt.timeIntervalSince1970, privacy: .public), plans=\(snapshot.plans.count, privacy: .public), actuals=\(snapshot.actuals.count, privacy: .public), places=\(snapshot.places.count, privacy: .public), travel=\(snapshot.travel.count, privacy: .public)"
            )
            return snapshot
        } catch {
            if let recovered = try? loadSnapshot(at: backupURL) {
                Self.logger.error(
                    "Repository load recovered backup: storage=\(self.storageLabel, privacy: .public), error=\(error.localizedDescription, privacy: .public), plans=\(recovered.plans.count, privacy: .public), actuals=\(recovered.actuals.count, privacy: .public)"
                )
                return recovered
            }
            Self.logger.error(
                "Repository load failed: storage=\(self.storageLabel, privacy: .public), error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        var value = snapshot
        value.updatedAt = .now
        do {
            let json = try encoder.encode(value)
            let data = TaptionSnapshotCompression.encode(json)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Keep the last valid generation. Never replace this backup from
            // a file that no longer decodes.
            if FileManager.default.fileExists(atPath: fileURL.path),
               (try? loadSnapshot(at: fileURL)) != nil {
                let previous = try Data(contentsOf: fileURL)
                try previous.write(to: backupURL, options: [.atomic])
            }
            try data.write(
                to: fileURL,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication,
                ]
            )
            Self.logger.notice(
                "Repository save: storage=\(self.storageLabel, privacy: .public), bytes=\(data.count, privacy: .public), jsonBytes=\(json.count, privacy: .public), updated=\(value.updatedAt.timeIntervalSince1970, privacy: .public), plans=\(value.plans.count, privacy: .public), actuals=\(value.actuals.count, privacy: .public), places=\(value.places.count, privacy: .public), travel=\(value.travel.count, privacy: .public)"
            )
        } catch {
            Self.logger.error(
                "Repository save failed: storage=\(self.storageLabel, privacy: .public), error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    func deleteAll() async throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }
    }

    private func loadSnapshot(at url: URL) throws -> TaptionDataSnapshot {
        try loadSnapshotWithSizes(at: url).snapshot
    }

    private func loadSnapshotWithSizes(
        at url: URL
    ) throws -> (snapshot: TaptionDataSnapshot, storedBytes: Int, jsonBytes: Int) {
        let storedData = try Data(contentsOf: url)
        let data = TaptionSnapshotCompression.decode(storedData)
        let snapshot = try decoder.decode(TaptionDataSnapshot.self, from: data)
        guard snapshot.schemaVersion <= TaptionDataSnapshot.empty.schemaVersion else {
            throw RepositoryError.unsupportedSchema(snapshot.schemaVersion)
        }
        return (snapshot, storedData.count, data.count)
    }
}

#if canImport(TaptionPlanCore)
actor SQLitePlanRepository: PlanDataRepository {
    private static let metadataDomain = "plan.metadata"
    private static let day = TaptionPlanDayKey(year: 0, month: 0, day: 0)

    private let store: TaptionPlanDayStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var nextRevision: UInt64 = 0

    init(databaseURL: URL) throws {
        self.store = try TaptionPlanDayStore(url: databaseURL)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> SQLitePlanRepository {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent("TaptionPlan", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SQLitePlanRepository(
            databaseURL: directory.appendingPathComponent(
                TaptionLocalDatabaseLocation.fileName
            )
        )
    }

    static func appGroup(
        identifier: String = TaptionWidgetSharedStore.appGroupIdentifier,
        fileManager: FileManager = .default
    ) throws -> SQLitePlanRepository {
        guard let directory = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) else {
            throw RepositoryError.appGroupUnavailable
        }
        return try SQLitePlanRepository(
            databaseURL: directory.appendingPathComponent(
                TaptionLocalDatabaseLocation.fileName
            )
        )
    }

    func load() async throws -> TaptionDataSnapshot {
        try await loadFromStore()
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        var value = snapshot
        value.updatedAt = .now
        let existingRows = try await store.snapshots(day: Self.day)
        let rowsByDomain = Dictionary(
            uniqueKeysWithValues: existingRows.map { ($0.domain, $0) }
        )
        let revisions = Dictionary(
            uniqueKeysWithValues: existingRows.map { ($0.domain, $0.revision) }
        )
        var writes: [TaptionPlanDayStore.Snapshot] = []

        try append(
            domain: Self.metadataDomain,
            value: Metadata(schemaVersion: value.schemaVersion, updatedAt: value.updatedAt),
            existingPayload: rowsByDomain[Self.metadataDomain]?.payload,
            force: true,
            revisions: revisions,
            to: &writes
        )
        try append(domain: "plan.plans", value: value.plans, existingPayload: rowsByDomain["plan.plans"]?.payload, revisions: revisions, to: &writes)
        try append(domain: "plan.actuals", value: value.actuals, existingPayload: rowsByDomain["plan.actuals"]?.payload, revisions: revisions, to: &writes)
        try append(domain: "plan.recordLinks", value: value.recordLinks, existingPayload: rowsByDomain["plan.recordLinks"]?.payload, revisions: revisions, to: &writes)
        try append(domain: "plan.memos", value: value.memos, existingPayload: rowsByDomain["plan.memos"]?.payload, revisions: revisions, to: &writes)
        try append(domain: "plan.categories", value: value.categories, existingPayload: rowsByDomain["plan.categories"]?.payload, revisions: revisions, to: &writes)
        try append(domain: "plan.photos", value: value.photos, existingPayload: rowsByDomain["plan.photos"]?.payload, revisions: revisions, to: &writes)
        try append(domain: "plan.calendarEvents", value: value.calendarEvents, existingPayload: rowsByDomain["plan.calendarEvents"]?.payload, revisions: revisions, to: &writes)
        try append(domain: "plan.weather", value: value.weather, existingPayload: rowsByDomain["plan.weather"]?.payload, revisions: revisions, to: &writes)
        try append(domain: "plan.places", value: value.places, existingPayload: rowsByDomain["plan.places"]?.payload, revisions: revisions, to: &writes)
        try append(domain: "plan.travel", value: value.travel, existingPayload: rowsByDomain["plan.travel"]?.payload, revisions: revisions, to: &writes)
        try append(domain: "plan.floorTransitions", value: value.floorTransitions, existingPayload: rowsByDomain["plan.floorTransitions"]?.payload, revisions: revisions, to: &writes)
        try append(domain: "plan.yearlyReports", value: value.yearlyReports, existingPayload: rowsByDomain["plan.yearlyReports"]?.payload, revisions: revisions, to: &writes)
        try append(domain: "plan.settings", value: value.settings, existingPayload: rowsByDomain["plan.settings"]?.payload, revisions: revisions, to: &writes)
        guard !writes.isEmpty else { return }
        try await store.saveSnapshots(writes)
        nextRevision = max(nextRevision, writes.map(\.revision).max() ?? 0)
    }

    private struct Metadata: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let updatedAt: Date
    }

    private func loadFromStore() async throws -> TaptionDataSnapshot {
        let rows = try await store.snapshots(day: Self.day)
        guard !rows.isEmpty else { return .empty }
        let value = try snapshot(from: rows)
        nextRevision = max(nextRevision, rows.map(\.revision).max() ?? 0)
        return value
    }

    private func snapshot(
        from rows: [TaptionPlanDayStore.Snapshot]
    ) throws -> TaptionDataSnapshot {
        var value = TaptionDataSnapshot.empty
        let rowByDomain = Dictionary(uniqueKeysWithValues: rows.map { ($0.domain, $0) })
        if let metadata = rowByDomain[Self.metadataDomain] {
            let decoded = try decoder.decode(Metadata.self, from: metadata.payload)
            value.schemaVersion = decoded.schemaVersion
            value.updatedAt = decoded.updatedAt
        }
        try decode("plan.plans", from: rowByDomain, into: &value.plans)
        try decode("plan.actuals", from: rowByDomain, into: &value.actuals)
        try decode("plan.recordLinks", from: rowByDomain, into: &value.recordLinks)
        try decode("plan.memos", from: rowByDomain, into: &value.memos)
        try decode("plan.categories", from: rowByDomain, into: &value.categories)
        try decode("plan.photos", from: rowByDomain, into: &value.photos)
        try decode("plan.calendarEvents", from: rowByDomain, into: &value.calendarEvents)
        try decode("plan.weather", from: rowByDomain, into: &value.weather)
        try decode("plan.places", from: rowByDomain, into: &value.places)
        try decode("plan.travel", from: rowByDomain, into: &value.travel)
        try decode("plan.floorTransitions", from: rowByDomain, into: &value.floorTransitions)
        try decode("plan.yearlyReports", from: rowByDomain, into: &value.yearlyReports)
        try decode("plan.settings", from: rowByDomain, into: &value.settings)
        guard value.schemaVersion <= TaptionDataSnapshot.empty.schemaVersion else {
            throw RepositoryError.unsupportedSchema(value.schemaVersion)
        }
        return value
    }

    private func decode<Value: Decodable>(
        _ domain: String,
        from rows: [String: TaptionPlanDayStore.Snapshot],
        into value: inout Value
    ) throws {
        guard let row = rows[domain] else { return }
        value = try decoder.decode(Value.self, from: row.payload)
    }

    private func append<Value: Encodable>(
        domain: String,
        value: Value,
        existingPayload: Data?,
        force: Bool = false,
        revisions: [String: UInt64],
        to writes: inout [TaptionPlanDayStore.Snapshot]
    ) throws {
        let payload = try encoder.encode(value)
        guard force || payload != existingPayload else { return }
        let currentRevision = revisions[domain] ?? 0
        guard currentRevision < UInt64.max else {
            throw TaptionPlanDayStoreError.revisionOverflow
        }
        writes.append(
            .init(
                domain: domain,
                day: Self.day,
                revision: currentRevision + 1,
                updatedAt: .now,
                payload: payload
            )
        )
    }
}
#endif

actor InMemoryPlanRepository: PlanDataRepository {
    private var snapshot: TaptionDataSnapshot

    init(snapshot: TaptionDataSnapshot = .empty) {
        self.snapshot = snapshot
    }

    func load() async throws -> TaptionDataSnapshot {
        snapshot
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        var value = snapshot
        value.updatedAt = .now
        self.snapshot = value
    }
}

enum CloudSyncDecision: Equatable, Sendable {
    case uploaded
    case downloaded
    case unchanged
}

enum CloudBackupRecordKey {
    static func plan(_ id: UUID) -> String { "plan:\(id.uuidString)" }
    static func memo(_ id: UUID) -> String { "memo:\(id.uuidString)" }
    static func link(_ id: UUID) -> String { "link:\(id.uuidString)" }
}

enum CloudSnapshotRecoveryEngine {
    static func merge(
        local: TaptionDataSnapshot,
        remote: TaptionDataSnapshot
    ) -> TaptionDataSnapshot {
        if local.settings.cloudResetAt != remote.settings.cloudResetAt {
            return resetWinner(local: local, remote: remote)
        }

        let localIsPrimary = local.updatedAt >= remote.updatedAt
        let primary = localIsPrimary ? local : remote
        let backup = localIsPrimary ? remote : local
        var value = primary
        let deleted = local.settings.cloudDeletedRecordKeys.union(
            remote.settings.cloudDeletedRecordKeys
        )
        let suppressedActuals = local.settings.suppressedActualIDs.union(
            remote.settings.suppressedActualIDs
        )

        value.plans = mergePlans(primary.plans, backup.plans).filter {
            !deleted.contains(CloudBackupRecordKey.plan($0.id))
        }
        value.memos = mergeMemos(primary.memos, backup.memos).filter {
            !deleted.contains(CloudBackupRecordKey.memo($0.id))
        }
        value.actuals = merged(primary.actuals, backup.actuals, id: \.id)
            .filter { !suppressedActuals.contains($0.id) }
        value.recordLinks = merged(
            primary.recordLinks,
            backup.recordLinks,
            id: \.id
        ).filter {
            !deleted.contains(CloudBackupRecordKey.link($0.id))
                && referencesAvailableRecords(
                    $0,
                    plans: value.plans,
                    suppressedActuals: suppressedActuals
                )
        }
        value.categories = merged(
            primary.categories,
            backup.categories,
            id: \.id
        )
        value.calendarEvents = merged(
            primary.calendarEvents,
            backup.calendarEvents,
            id: \.id
        )
        value.places = merged(primary.places, backup.places, id: \.id)
        value.travel = merged(primary.travel, backup.travel, id: \.id)
        value.floorTransitions = merged(
            primary.floorTransitions,
            backup.floorTransitions,
            id: \.id
        )
        value.yearlyReports = merged(
            primary.yearlyReports,
            backup.yearlyReports,
            id: \.id,
            resolve: { ReviewArchiveHierarchy.merging($0, $1) }
        ).sorted { $0.span.start < $1.span.start }
        value.settings.cloudDeletedRecordKeys = deleted
        value.settings.suppressedActualIDs = suppressedActuals
        value.schemaVersion = max(local.schemaVersion, remote.schemaVersion)
        value.updatedAt = max(local.updatedAt, remote.updatedAt)
        return value
    }

    private static func resetWinner(
        local: TaptionDataSnapshot,
        remote: TaptionDataSnapshot
    ) -> TaptionDataSnapshot {
        let localReset = local.settings.cloudResetAt ?? .distantPast
        let remoteReset = remote.settings.cloudResetAt ?? .distantPast
        return localReset >= remoteReset ? local : remote
    }

    private static func mergePlans(
        _ primary: [PlanRecord],
        _ backup: [PlanRecord]
    ) -> [PlanRecord] {
        merged(primary, backup, id: \.id) { current, candidate in
            candidate.updatedAt > current.updatedAt ? candidate : current
        }
    }

    private static func mergeMemos(
        _ primary: [ActionMemo],
        _ backup: [ActionMemo]
    ) -> [ActionMemo] {
        merged(primary, backup, id: \.id) { current, candidate in
            candidate.updatedAt > current.updatedAt ? candidate : current
        }
    }

    private static func merged<Element, ID: Hashable>(
        _ primary: [Element],
        _ backup: [Element],
        id: KeyPath<Element, ID>,
        resolve: (Element, Element) -> Element = { current, _ in current }
    ) -> [Element] {
        var result: [Element] = []
        var indexes: [ID: Int] = [:]
        for item in primary + backup {
            let itemID = item[keyPath: id]
            if let index = indexes[itemID] {
                result[index] = resolve(result[index], item)
            } else {
                indexes[itemID] = result.count
                result.append(item)
            }
        }
        return result
    }

    private static func referencesAvailableRecords(
        _ link: RecordLink,
        plans: [PlanRecord],
        suppressedActuals: Set<UUID>
    ) -> Bool {
        let planIDs = Set(plans.map(\.id))
        for nodeID in [link.fromNodeID, link.toNodeID] {
            for prefix in ["routine.", "action."] where nodeID.hasPrefix(prefix) {
                guard let id = UUID(
                    uuidString: String(nodeID.dropFirst(prefix.count))
                ), planIDs.contains(id) else { return false }
            }
            let actualPrefix = "automatic.actual."
            if nodeID.hasPrefix(actualPrefix),
               let id = UUID(
                   uuidString: String(nodeID.dropFirst(actualPrefix.count))
               ), suppressedActuals.contains(id) {
                return false
            }
        }
        return true
    }
}

enum CloudUnavailableReason: Sendable {
    case unsupportedBuild
    case signedOut
    case restricted
    case temporarilyUnavailable
    case accountCheckFailed
    case schemaMissing

    var statusLabel: String {
        switch self {
        case .unsupportedBuild: "이 빌드 미지원"
        case .signedOut: "iCloud 로그인 필요"
        case .restricted: "기기에서 제한됨"
        case .temporarilyUnavailable: "잠시 후 다시"
        case .accountCheckFailed: "계정 확인 실패"
        case .schemaMissing: "서버 설정 필요"
        }
    }

    var guidance: String {
        switch self {
        case .unsupportedBuild:
            "이 빌드에는 iCloud 컨테이너가 없습니다. 기록은 이 기기에만 저장됩니다."
        case .signedOut:
            "설정 앱 → 맨 위 이름 → iCloud에서 로그인하고 iCloud Drive를 켠 뒤 이 줄을 눌러주세요."
        case .restricted:
            "스크린타임이나 기기 관리 정책이 iCloud를 막고 있습니다. 제한을 푼 뒤 다시 시도해주세요."
        case .temporarilyUnavailable:
            "iCloud 계정을 확인하는 중입니다. 잠시 뒤 이 줄을 눌러 다시 시도해주세요."
        case .accountCheckFailed:
            "iCloud 계정 상태를 확인하지 못했습니다. 네트워크를 확인한 뒤 이 줄을 눌러주세요."
        case .schemaMissing:
            "iCloud 컨테이너의 TaptionSnapshot 스키마가 Production에 배포되지 않았습니다. 배포 전까지 기록은 이 기기에 안전하게 저장되며, 배포 후 이 줄을 눌러 다시 시도할 수 있습니다."
        }
    }
}

enum CloudKitErrorPolicy {
    static func isProductionSchemaUnavailable(_ error: Error) -> Bool {
        let message = diagnosticMessage(for: error)
        return message.contains("cannot create new type")
            || message.contains("production schema")
    }

    static func diagnosticFields(for error: Error) -> [String: String] {
        let nsError = error as NSError
        var fields = [
            "error_type": String(reflecting: type(of: error)),
            "error_domain": nsError.domain,
            "error_code": String(nsError.code),
        ]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            let underlyingError = underlying as NSError
            fields["underlying_domain"] = underlyingError.domain
            fields["underlying_code"] = String(underlyingError.code)
        }
        fields["failure_kind"] = isProductionSchemaUnavailable(error)
            ? "production_schema"
            : "cloudkit"
        return fields
    }

    static func isRecordConflict(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == CKError.errorDomain,
           nsError.code == CKError.Code.serverRecordChanged.rawValue {
            return true
        }
        if partialErrors(in: nsError).contains(where: isRecordConflict) {
            return true
        }
        return conflictMessage(in: nsError).contains("client oplock")
    }

    static func serverRecord(in error: Error) -> CKRecord? {
        let nsError = error as NSError
        if let record = nsError.userInfo[
            CKRecordChangedErrorServerRecordKey
        ] as? CKRecord {
            return record
        }
        return partialErrors(in: nsError).lazy.compactMap(serverRecord).first
    }

    private static func partialErrors(in error: NSError) -> [Error] {
        guard let values = error.userInfo[
            CKPartialErrorsByItemIDKey
        ] as? [AnyHashable: Any] else {
            return []
        }
        return values.values.compactMap { $0 as? Error }
    }

    private static func conflictMessage(in error: NSError) -> String {
        [
            error.localizedDescription,
            error.localizedFailureReason ?? "",
            error.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String
                ?? "",
        ]
        .joined(separator: " ")
        .lowercased()
    }

    private static func diagnosticMessage(for error: Error) -> String {
        let nsError = error as NSError
        var values = [
            error.localizedDescription,
            nsError.localizedFailureReason ?? "",
            nsError.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String
                ?? "",
        ]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            values.append(diagnosticMessage(for: underlying))
        }
        if let partial = nsError.userInfo[CKPartialErrorsByItemIDKey]
            as? [AnyHashable: Any] {
            values.append(contentsOf: partial.values.compactMap { value in
                guard let error = value as? Error else { return nil }
                return diagnosticMessage(for: error)
            })
        }
        return values.joined(separator: " ").lowercased()
    }
}

actor CloudKitSnapshotSyncService {
    private static let containerIdentifier = "iCloud.com.taption.plan"
    private static let recordName = "taption-data-v1"
    private static let recordType = "TaptionSnapshot"
    private static let inlineLimit = 850_000

    private let container: CKContainer
    private let database: CKDatabase
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var schemaUnavailable = false
    private var uploadInProgress = false
    private var uploadWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated static func automatic() -> CloudKitSnapshotSyncService? {
#if targetEnvironment(simulator)
        return nil
#else
#if DEBUG
        guard CloudKitEntitlementPolicy.canInitialize(
            containerIdentifier: containerIdentifier,
            embeddedProfileData: embeddedProvisioningProfileData()
        ) else {
            return nil
        }
#endif
        return CloudKitSnapshotSyncService(
            container: CKContainer(identifier: containerIdentifier)
        )
#endif
    }

    private nonisolated static func embeddedProvisioningProfileData() -> Data? {
        guard let profileURL = Bundle.main.url(
            forResource: "embedded",
            withExtension: "mobileprovision"
        ) else {
            return nil
        }
        return try? Data(contentsOf: profileURL, options: .mappedIfSafe)
    }

    init(container: CKContainer) {
        self.container = container
        self.database = container.privateCloudDatabase
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    func accountState() async -> PermissionState {
        await accountAvailability().0
    }

    /// 계정 로그인, 기기 제한, 서버 스키마는 사용자가 할 수 있는 조치가 서로
    /// 다르다. 이유를 그대로 돌려주어 설정 화면이 안내할 수 있게 한다.
    func accountAvailability() async -> (PermissionState, CloudUnavailableReason?) {
        do {
            let status = try await container.accountStatus()
            let result: (PermissionState, CloudUnavailableReason?)
            switch status {
            case .available:
                result = (.authorized, nil)
            case .couldNotDetermine:
                result = (.notDetermined, nil)
            case .noAccount:
                result = (.unavailable, .signedOut)
            case .restricted:
                result = (.unavailable, .restricted)
            case .temporarilyUnavailable:
                result = (.unavailable, .temporarilyUnavailable)
            @unknown default:
                result = (.unavailable, .accountCheckFailed)
            }
            TaptionPlanDiagnosticsLogger.shared.record(
                "cloud_account_status",
                fields: [
                    "status": String(describing: status),
                    "permission": result.0.rawValue,
                    "reason": result.1?.statusLabel ?? "authorized",
                ]
            )
            return result
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record(
                "cloud_account_check_failed",
                level: .error,
                fields: CloudKitErrorPolicy.diagnosticFields(for: error)
            )
            return (.unavailable, .accountCheckFailed)
        }
    }

    func isSchemaUnavailable() -> Bool {
        schemaUnavailable
    }

    func resetSchemaAvailability() {
        schemaUnavailable = false
        TaptionPlanDiagnosticsLogger.shared.record(
            "cloud_schema_retry_requested"
        )
    }

    func synchronize(
        local: TaptionDataSnapshot
    ) async throws -> (TaptionDataSnapshot, CloudSyncDecision) {
        guard await accountState() == .authorized else {
            throw RepositoryError.cloudAccountUnavailable
        }

        guard let remote = try await fetch() else {
            let uploaded = try await upload(local)
            return (uploaded, .uploaded)
        }
        let merged = CloudSnapshotRecoveryEngine.merge(
            local: local,
            remote: remote
        )
        if merged == local, merged == remote {
            return (merged, .unchanged)
        }
        if merged == remote {
            return (merged, .downloaded)
        }
        let uploaded = try await upload(merged)
        return (uploaded, merged == local ? .uploaded : .downloaded)
    }

    func fetch() async throws -> TaptionDataSnapshot? {
        guard let record = try await fetchRecord() else { return nil }
        return try snapshot(from: record)
    }

    @discardableResult
    func upload(_ snapshot: TaptionDataSnapshot) async throws -> TaptionDataSnapshot {
        await acquireUploadTurn()
        defer { releaseUploadTurn() }
        try Task.checkCancellation()
        guard !schemaUnavailable else {
            throw RepositoryError.cloudSchemaUnavailable
        }
        do {
            let record = try await fetchRecord()
            let value: TaptionDataSnapshot
            if let record {
                value = CloudSnapshotRecoveryEngine.merge(
                    local: snapshot,
                    remote: try self.snapshot(from: record)
                )
            } else {
                value = snapshot
            }
            var stamped = value
            stamped.updatedAt = .now
            let target = record ?? CKRecord(
                recordType: Self.recordType,
                recordID: CKRecord.ID(recordName: Self.recordName)
            )
            return try await saveWithConflictRecovery(
                target,
                value: stamped
            )
        } catch {
            if CloudKitErrorPolicy.isProductionSchemaUnavailable(error) {
                schemaUnavailable = true
                TaptionPlanDiagnosticsLogger.shared.record(
                    "cloud_production_schema_unavailable",
                    level: .error,
                    fields: CloudKitErrorPolicy.diagnosticFields(for: error)
                )
            } else {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "cloud_upload_failed",
                    level: .error,
                    fields: CloudKitErrorPolicy.diagnosticFields(for: error)
                )
            }
            throw error
        }
    }

    private func acquireUploadTurn() async {
        guard uploadInProgress else {
            uploadInProgress = true
            return
        }
        await withCheckedContinuation { uploadWaiters.append($0) }
    }

    private func releaseUploadTurn() {
        guard !uploadWaiters.isEmpty else {
            uploadInProgress = false
            return
        }
        uploadWaiters.removeFirst().resume()
    }

    private func fetchRecord() async throws -> CKRecord? {
        let recordID = CKRecord.ID(recordName: Self.recordName)
        do {
            return try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch {
            if CloudKitErrorPolicy.isProductionSchemaUnavailable(error) {
                schemaUnavailable = true
                TaptionPlanDiagnosticsLogger.shared.record(
                    "cloud_production_schema_unavailable",
                    level: .error,
                    fields: CloudKitErrorPolicy.diagnosticFields(for: error)
                        .merging(["operation": "fetch"]) { current, _ in
                            current
                        }
                )
            }
            throw error
        }
    }

    /// A phone, Watch-triggered refresh, and another Apple device can update
    /// the single snapshot record at nearly the same time. CloudKit then
    /// rejects a stale record change tag as a client oplock conflict. Reapply
    /// the local snapshot to the server's newest record and retry a bounded
    /// number of times so edits remain atomic without presenting a false save
    /// failure to the user.
    private func saveWithConflictRecovery(
        _ initialRecord: CKRecord,
        value initialValue: TaptionDataSnapshot
    ) async throws -> TaptionDataSnapshot {
        var record = initialRecord
        var value = initialValue
        let maximumAttempts = 6

        for attempt in 1...maximumAttempts {
            let data = try encoder.encode(value)
            let assetURL: URL?
            if data.count > Self.inlineLimit {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "taption-cloud-\(UUID().uuidString).json"
                    )
                try data.write(to: url, options: .atomic)
                assetURL = url
            } else {
                assetURL = nil
            }
            defer {
                if let assetURL {
                    try? FileManager.default.removeItem(at: assetURL)
                }
            }
            applyPayload(
                to: record,
                value: value,
                inlineData: assetURL == nil ? data : nil,
                assetURL: assetURL
            )

            do {
                _ = try await database.save(record)
                if attempt > 1 {
                    TaptionPlanDiagnosticsLogger.shared.record(
                        "cloud_conflict_recovered",
                        fields: ["attempt": String(attempt)]
                    )
                }
                return value
            } catch {
                guard CloudKitErrorPolicy.isRecordConflict(error),
                      attempt < maximumAttempts else {
                    throw error
                }
                TaptionPlanDiagnosticsLogger.shared.record(
                    "cloud_conflict_retry",
                    level: .notice,
                    fields: ["attempt": String(attempt)]
                )
                let serverRecord = CloudKitErrorPolicy.serverRecord(in: error)
                let delay = min(800_000_000, 50_000_000 << (attempt - 1))
                try await Task.sleep(nanoseconds: UInt64(delay))
                record = (try? await database.record(
                    for: initialRecord.recordID
                )) ?? serverRecord ?? record
                if let remote = try? snapshot(from: record) {
                    value = CloudSnapshotRecoveryEngine.merge(
                        local: value,
                        remote: remote
                    )
                    value.updatedAt = .now
                }
            }
        }
        return value
    }

    private func snapshot(from record: CKRecord) throws -> TaptionDataSnapshot {
        let data: Data?
        if let inline = record["payload"] as? Data {
            data = inline
        } else if let asset = record["payloadAsset"] as? CKAsset,
                  let fileURL = asset.fileURL {
            data = try Data(contentsOf: fileURL)
        } else {
            data = nil
        }
        guard let data else { throw RepositoryError.cloudPayloadMissing }
        return try decoder.decode(TaptionDataSnapshot.self, from: data)
    }

    private func applyPayload(
        to record: CKRecord,
        value: TaptionDataSnapshot,
        inlineData: Data?,
        assetURL: URL?
    ) {
        record["schemaVersion"] = value.schemaVersion as CKRecordValue
        record["updatedAt"] = value.updatedAt as CKRecordValue
        if let inlineData {
            record["payload"] = inlineData as CKRecordValue
            record["payloadAsset"] = nil
        } else if let assetURL {
            record["payload"] = nil
            record["payloadAsset"] = CKAsset(fileURL: assetURL)
        }
    }
}

enum CloudKitEntitlementPolicy {
    static func canInitialize(
        containerIdentifier: String,
        embeddedProfileData: Data?
    ) -> Bool {
        guard let embeddedProfileData else { return false }
        return embeddedProfileData.range(
            of: Data(containerIdentifier.utf8)
        ) != nil
    }
}

enum SnapshotExporter {
    static func jsonData(
        _ snapshot: TaptionDataSnapshot,
        prettyPrinted: Bool = true
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    static func decodeJSON(_ data: Data) throws -> TaptionDataSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(TaptionDataSnapshot.self, from: data)
        guard snapshot.schemaVersion <= TaptionDataSnapshot.empty.schemaVersion else {
            throw RepositoryError.unsupportedSchema(snapshot.schemaVersion)
        }
        return snapshot
    }

    static func plansCSV(_ snapshot: TaptionDataSnapshot) -> Data {
        var rows = [
            "kind,id,parent_id,routine_id,title,category,start,end,status,source,duration_seconds"
        ]

        for plan in snapshot.plans {
            rows.append([
                "plan",
                plan.id.uuidString,
                plan.parentID?.uuidString ?? "",
                "",
                plan.title,
                plan.categoryID,
                plan.span.start.ISO8601Format(),
                plan.span.end.ISO8601Format(),
                plan.status.rawValue,
                plan.origin.rawValue,
                String(Int(plan.span.duration))
            ].map(csvEscape).joined(separator: ","))
        }

        for actual in snapshot.actuals {
            let span = actual.span(asOf: actual.endedAt ?? actual.startedAt)
            rows.append([
                "actual",
                actual.id.uuidString,
                actual.planID?.uuidString ?? "",
                actual.routineID?.uuidString ?? "",
                actual.title,
                actual.categoryID,
                span.start.ISO8601Format(),
                span.end.ISO8601Format(),
                actual.endedAt == nil ? "running" : "completed",
                actual.source.rawValue,
                String(Int(span.duration))
            ].map(csvEscape).joined(separator: ","))
        }

        return Data(rows.joined(separator: "\n").utf8)
    }

    private static func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
