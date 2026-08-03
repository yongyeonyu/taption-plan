import CloudKit
import Compression
import Foundation
import OSLog

protocol PlanDataRepository: Sendable {
    func load() async throws -> TaptionDataSnapshot
    func save(_ snapshot: TaptionDataSnapshot) async throws
}

actor MigratingPlanRepository: PlanDataRepository {
    private let primary: any PlanDataRepository
    private let legacy: any PlanDataRepository

    init(
        primary: any PlanDataRepository,
        legacy: any PlanDataRepository
    ) {
        self.primary = primary
        self.legacy = legacy
    }

    func load() async throws -> TaptionDataSnapshot {
        let shared = try await primary.load()
        guard shared.updatedAt == .distantPast else {
            return shared
        }
        let existing = try await legacy.load()
        guard existing.updatedAt != .distantPast else {
            return shared
        }
        try await primary.save(existing)
        return existing
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        try await primary.save(snapshot)
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

    init(fileURL: URL, storageLabel: String = "file") {
        self.fileURL = fileURL
        self.storageLabel = storageLabel
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
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
            Self.logger.notice(
                "Repository load empty: storage=\(self.storageLabel, privacy: .public)"
            )
            return .empty
        }
        do {
            let storedData = try Data(contentsOf: fileURL)
            let data = TaptionSnapshotCompression.decode(storedData)
            let snapshot = try decoder.decode(
                TaptionDataSnapshot.self,
                from: data
            )
            guard snapshot.schemaVersion <= TaptionDataSnapshot.empty.schemaVersion else {
                throw RepositoryError.unsupportedSchema(snapshot.schemaVersion)
            }
            Self.logger.debug(
                "Repository load: storage=\(self.storageLabel, privacy: .public), bytes=\(storedData.count, privacy: .public), jsonBytes=\(data.count, privacy: .public), updated=\(snapshot.updatedAt.timeIntervalSince1970, privacy: .public), plans=\(snapshot.plans.count, privacy: .public), places=\(snapshot.places.count, privacy: .public), travel=\(snapshot.travel.count, privacy: .public)"
            )
            return snapshot
        } catch {
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
            try data.write(
                to: fileURL,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication,
                ]
            )
            Self.logger.notice(
                "Repository save: storage=\(self.storageLabel, privacy: .public), bytes=\(data.count, privacy: .public), jsonBytes=\(json.count, privacy: .public), updated=\(value.updatedAt.timeIntervalSince1970, privacy: .public), plans=\(value.plans.count, privacy: .public), places=\(value.places.count, privacy: .public), travel=\(value.travel.count, privacy: .public)"
            )
        } catch {
            Self.logger.error(
                "Repository save failed: storage=\(self.storageLabel, privacy: .public), error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    func deleteAll() async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

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

enum CloudKitErrorPolicy {
    static func isProductionSchemaUnavailable(_ error: Error) -> Bool {
        let nsError = error as NSError
        let values = [
            error.localizedDescription,
            nsError.localizedFailureReason ?? "",
            nsError.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String
                ?? "",
        ]
        let message = values.joined(separator: " ").lowercased()
        return message.contains("cannot create new type")
            || message.contains("production schema")
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
        do {
            switch try await container.accountStatus() {
            case .available:
                return .authorized
            case .couldNotDetermine:
                return .notDetermined
            case .noAccount, .restricted, .temporarilyUnavailable:
                return .unavailable
            @unknown default:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    func isSchemaUnavailable() -> Bool {
        schemaUnavailable
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

        if remote.updatedAt > local.updatedAt {
            return (remote, .downloaded)
        }
        if local.updatedAt > remote.updatedAt {
            let uploaded = try await upload(local)
            return (uploaded, .uploaded)
        }
        return (local, .unchanged)
    }

    func fetch() async throws -> TaptionDataSnapshot? {
        let recordID = CKRecord.ID(recordName: Self.recordName)
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }

        let data: Data?
        if let inline = record["payload"] as? Data {
            data = inline
        } else if let asset = record["payloadAsset"] as? CKAsset,
                  let fileURL = asset.fileURL {
            data = try Data(contentsOf: fileURL)
        } else {
            data = nil
        }

        guard let data else {
            throw RepositoryError.cloudPayloadMissing
        }
        return try decoder.decode(TaptionDataSnapshot.self, from: data)
    }

    @discardableResult
    func upload(_ snapshot: TaptionDataSnapshot) async throws -> TaptionDataSnapshot {
        guard !schemaUnavailable else {
            throw RepositoryError.cloudSchemaUnavailable
        }
        do {
            return try await uploadRecord(snapshot)
        } catch {
            if CloudKitErrorPolicy.isProductionSchemaUnavailable(error) {
                schemaUnavailable = true
            }
            throw error
        }
    }

    private func uploadRecord(
        _ snapshot: TaptionDataSnapshot
    ) async throws -> TaptionDataSnapshot {
        var value = snapshot
        value.updatedAt = .now
        let data = try encoder.encode(value)
        let recordID = CKRecord.ID(recordName: Self.recordName)
        let record = (try? await database.record(for: recordID))
            ?? CKRecord(recordType: Self.recordType, recordID: recordID)

        if data.count <= Self.inlineLimit {
            try await saveWithConflictRecovery(
                record,
                value: value,
                inlineData: data,
                assetURL: nil
            )
            return value
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-cloud-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .atomic)
        try await saveWithConflictRecovery(
            record,
            value: value,
            inlineData: nil,
            assetURL: temporaryURL
        )
        return value
    }

    /// A phone, Watch-triggered refresh, and another Apple device can update
    /// the single snapshot record at nearly the same time. CloudKit then
    /// rejects a stale record change tag as a client oplock conflict. Reapply
    /// the local snapshot to the server's newest record and retry a bounded
    /// number of times so edits remain atomic without presenting a false save
    /// failure to the user.
    private func saveWithConflictRecovery(
        _ initialRecord: CKRecord,
        value: TaptionDataSnapshot,
        inlineData: Data?,
        assetURL: URL?
    ) async throws {
        var record = initialRecord
        let maximumAttempts = 3

        for attempt in 1...maximumAttempts {
            applyPayload(
                to: record,
                value: value,
                inlineData: inlineData,
                assetURL: assetURL
            )

            do {
                _ = try await database.save(record)
                return
            } catch let error as CKError
                where error.code == .serverRecordChanged
                    && attempt < maximumAttempts {
                if let serverRecord = error.userInfo[
                    CKRecordChangedErrorServerRecordKey
                ] as? CKRecord {
                    record = serverRecord
                } else {
                    record = try await database.record(
                        for: initialRecord.recordID
                    )
                }
            }
        }
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
