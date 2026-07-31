import CloudKit
import Foundation

protocol PlanDataRepository: Sendable {
    func load() async throws -> TaptionDataSnapshot
    func save(_ snapshot: TaptionDataSnapshot) async throws
}

enum RepositoryError: Error, Equatable {
    case invalidSnapshot
    case unsupportedSchema(Int)
    case cloudAccountUnavailable
    case cloudPayloadMissing
    case appGroupUnavailable
}

actor FilePlanRepository: PlanDataRepository {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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
            fileURL: directory.appendingPathComponent("taption-data-v1.json")
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
            )
        )
    }

    func load() async throws -> TaptionDataSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty
        }
        let data = try Data(contentsOf: fileURL)
        let snapshot = try decoder.decode(TaptionDataSnapshot.self, from: data)
        guard snapshot.schemaVersion <= TaptionDataSnapshot.empty.schemaVersion else {
            throw RepositoryError.unsupportedSchema(snapshot.schemaVersion)
        }
        return snapshot
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        var value = snapshot
        value.updatedAt = .now
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
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

actor CloudKitSnapshotSyncService {
    private static let recordName = "taption-data-v1"
    private static let recordType = "TaptionSnapshot"
    private static let inlineLimit = 850_000

    private let container: CKContainer
    private let database: CKDatabase
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    nonisolated static func automatic() -> CloudKitSnapshotSyncService? {
#if targetEnvironment(simulator)
        return nil
#else
        return CloudKitSnapshotSyncService(
            container: CKContainer(identifier: "iCloud.com.taption.plan")
        )
#endif
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
        var value = snapshot
        value.updatedAt = .now
        let data = try encoder.encode(value)
        let recordID = CKRecord.ID(recordName: Self.recordName)
        let record = (try? await database.record(for: recordID))
            ?? CKRecord(recordType: Self.recordType, recordID: recordID)

        record["schemaVersion"] = value.schemaVersion as CKRecordValue
        record["updatedAt"] = value.updatedAt as CKRecordValue

        if data.count <= Self.inlineLimit {
            record["payload"] = data as CKRecordValue
            record["payloadAsset"] = nil
            _ = try await database.save(record)
            return value
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-cloud-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .atomic)
        record["payload"] = nil
        record["payloadAsset"] = CKAsset(fileURL: temporaryURL)
        _ = try await database.save(record)
        return value
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
            "kind,id,parent_id,title,category,start,end,status,source,duration_seconds"
        ]

        for plan in snapshot.plans {
            rows.append([
                "plan",
                plan.id.uuidString,
                plan.parentID?.uuidString ?? "",
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
