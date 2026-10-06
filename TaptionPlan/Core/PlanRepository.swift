import CloudKit
import Compression
import CryptoKit
import Darwin
import Foundation
import OSLog
#if os(iOS) && !TAPTION_WIDGET
import UIKit
#endif
#if canImport(TaptionPlanCore)
import TaptionPlanCore
#endif

protocol PlanDataRepository: Sendable {
    func load() async throws -> TaptionDataSnapshot
    func loadStartupSnapshot() async throws -> TaptionDataSnapshot?
    func save(_ snapshot: TaptionDataSnapshot) async throws
    func save(_ snapshot: TaptionDataSnapshot, actualEdit: PlanActualEdit?) async throws
    func actuals(in span: TimeSpan, matching source: [ActualRecord]) async throws -> [ActualRecord]?
    func deleteAll() async throws
    func handleMemoryPressure() async
}

extension PlanDataRepository {
    func loadStartupSnapshot() async throws -> TaptionDataSnapshot? { nil }
    func save(_ snapshot: TaptionDataSnapshot, actualEdit: PlanActualEdit?) async throws {
        try await save(snapshot)
    }
    func actuals(in span: TimeSpan, matching source: [ActualRecord]) async throws -> [ActualRecord]? { nil }
}

enum TaptionRepositoryBackgroundExecution {
    @MainActor
    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        #if os(iOS) && !TAPTION_WIDGET
        let task = Task {
            try Task.checkCancellation()
            return try await operation()
        }
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: "TaptionPlan.repository"
        ) { task.cancel() }
        guard identifier != .invalid else {
            task.cancel()
            throw CancellationError()
        }
        defer { UIApplication.shared.endBackgroundTask(identifier) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        #else
        return try await operation()
        #endif
    }
}

final class TaptionDataFileLock: @unchecked Sendable {
    enum AcquireError: Error {
        case busy
    }

    private var descriptor: Int32

    private init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        descriptor = Darwin.open(
            url.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func acquireIfAvailable(url: URL) throws -> TaptionDataFileLock {
        let lock = try TaptionDataFileLock(url: url)
        guard flock(lock.descriptor, LOCK_EX | LOCK_NB) != 0 else {
            return lock
        }
        do {
            let code = errno
            lock.unlock()
            if code == EWOULDBLOCK || code == EAGAIN {
                throw AcquireError.busy
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    static func acquire(url: URL) async throws -> TaptionDataFileLock {
        while true {
            try Task.checkCancellation()
            do {
                return try acquireIfAvailable(url: url)
            } catch AcquireError.busy {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    static func withLock<Value>(
        url: URL,
        _ operation: () throws -> Value
    ) throws -> Value {
        let lock = try acquireIfAvailable(url: url)
        defer { lock.unlock() }
        return try operation()
    }

    func unlock() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        unlock()
    }
}

enum TaptionDataDeletionFence {
    private static let generationKey = "TaptionPlan.dataDeletionGeneration"
    private static let cutoffKey = "TaptionPlan.dataDeletionCutoff"
    private static let activeKey = "TaptionPlan.dataDeletionActive"

    private static var defaults: UserDefaults {
        UserDefaults(
            suiteName: TaptionPlanSharedContainer.appGroupIdentifier
        ) ?? .standard
    }

    static func currentGeneration() -> UInt64 {
        UInt64(defaults.string(forKey: generationKey) ?? "") ?? 0
    }

    private static let repositoryDeletionPendingKey =
        "TaptionPlan.repositoryDeletionPending"

    static func beginRepositoryDeletion() {
        defaults.set(true, forKey: repositoryDeletionPendingKey)
        defaults.synchronize()
    }

    static func finishRepositoryDeletion() {
        defaults.removeObject(forKey: repositoryDeletionPendingKey)
        defaults.synchronize()
    }

    static func repositoryDeletionIsPending() -> Bool {
        defaults.bool(forKey: repositoryDeletionPendingKey)
    }

    static func cutoff() -> Date? {
        defaults.object(forKey: cutoffKey) as? Date
    }

    static func advance(at date: Date = .now) -> UInt64 {
        let current = currentGeneration()
        let clock = UInt64(max(1, date.timeIntervalSince1970 * 1_000))
        let next = max(current == .max ? current : current + 1, clock)
        defaults.set(String(next), forKey: generationKey)
        defaults.set(date, forKey: cutoffKey)
        defaults.set(String(getpid()), forKey: activeKey)
        defaults.synchronize()
        return next
    }

    static func finish(generation: UInt64) {
        guard generation == currentGeneration() else { return }
        defaults.removeObject(forKey: activeKey)
        defaults.synchronize()
    }

    static func allows(generation: UInt64, capturedAt: Date? = nil) -> Bool {
        if defaults.object(forKey: activeKey) != nil {
            if let marker = defaults.string(forKey: activeKey),
               let pid = Int32(marker),
               pid > 0,
               Darwin.kill(pid, 0) == 0 || errno == EPERM {
                return false
            }
            defaults.removeObject(forKey: activeKey)
            defaults.synchronize()
        }
        guard generation == currentGeneration() else { return false }
        guard let capturedAt, let cutoff = cutoff() else { return true }
        return capturedAt > cutoff
    }
}

private enum TaptionRepositoryDeletionMarker {
    static func write(generation: UInt64, to url: URL) throws {
        try Data(String(generation).utf8).write(
            to: url,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
    }

    static func recoveredGeneration(at url: URL, current: UInt64) -> UInt64 {
        guard let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8),
              let generation = UInt64(value),
              generation >= current else {
            return current < UInt64.max ? current + 1 : current
        }
        return generation
    }
}

extension PlanDataRepository {
    func deleteAll() async throws {
        try await save(.empty)
    }

    func handleMemoryPressure() async {}
}

enum TaptionLocalDatabaseLocation {
    static let fileName = "taption-data-v2.sqlite"

    static func sharedOrApplicationSupport(
        fileManager: FileManager = .default
    ) throws -> URL {
        if let directory = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier:
                TaptionPlanSharedContainer.appGroupIdentifier
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
    private var writeTail: Task<Void, Error>?
    private var migrationTask: Task<Void, Error>?
    private var migrationTaskID: UUID?

    init(
        primary: any PlanDataRepository,
        legacy: any PlanDataRepository
    ) {
        self.primary = primary
        self.legacy = legacy
    }

    func loadStartupSnapshot() async throws -> TaptionDataSnapshot? {
        guard !TaptionDataDeletionFence.repositoryDeletionIsPending() else { return nil }
        return try await primary.loadStartupSnapshot()
    }

    func load() async throws -> TaptionDataSnapshot {
        if TaptionDataDeletionFence.repositoryDeletionIsPending() {
            try await deleteAll()
            return .empty
        }
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

    func actuals(in span: TimeSpan, matching source: [ActualRecord]) async throws -> [ActualRecord]? {
        try await primary.actuals(in: span, matching: source)
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        try await save(snapshot, actualEdit: nil)
    }

    func save(_ snapshot: TaptionDataSnapshot, actualEdit: PlanActualEdit?) async throws {
        migrationTask?.cancel()
        migrationTask = nil
        migrationTaskID = nil
        let previous = writeTail
        let primary = self.primary
        let task = Task<Void, Error> {
            if let previous { _ = try? await previous.value }
            try await primary.save(snapshot, actualEdit: actualEdit)
        }
        writeTail = task
        try await task.value
    }

    func handleMemoryPressure() async {
        await primary.handleMemoryPressure()
        await legacy.handleMemoryPressure()
    }

    func deleteAll() async throws {
        migrationTask?.cancel()
        migrationTask = nil
        migrationTaskID = nil
        TaptionDataDeletionFence.beginRepositoryDeletion()
        let previous = writeTail
        let primary = self.primary
        let legacy = self.legacy
        let task = Task<Void, Error> {
            if let previous { _ = try? await previous.value }
            var firstError: Error?
            do {
                try await primary.deleteAll()
            } catch {
                firstError = error
            }
            do {
                try await legacy.deleteAll()
            } catch {
                if firstError == nil { firstError = error }
            }
            if let firstError { throw firstError }
        }
        writeTail = task
        try await task.value
        TaptionDataDeletionFence.finishRepositoryDeletion()
    }

    private func schedulePrimaryMigration(_ snapshot: TaptionDataSnapshot) {
        guard migrationTask == nil else { return }
        let previous = writeTail
        let primary = self.primary
        let generation = TaptionDataDeletionFence.currentGeneration()
        let taskID = UUID()
        let task = Task.detached(priority: .utility) {
            if let previous { _ = try? await previous.value }
            // A caller may save a newer snapshot as soon as the legacy value
            // is returned. Never let this one-time import overwrite it, and
            // never replace a primary that failed to decode.
            guard !Task.isCancelled,
                  TaptionDataDeletionFence.allows(generation: generation),
                  let current = try? await primary.load(),
                  !Task.isCancelled,
                  TaptionDataDeletionFence.allows(generation: generation),
                  current.updatedAt == .distantPast else {
                await self.finishMigrationTask(id: taskID)
                return
            }
            do {
                guard !Task.isCancelled else {
                    await self.finishMigrationTask(id: taskID)
                    return
                }
                try await primary.save(snapshot)
            } catch {
                await self.finishMigrationTask(id: taskID)
                throw error
            }
            await self.finishMigrationTask(id: taskID)
        }
        writeTail = task
        migrationTask = task
        migrationTaskID = taskID
    }

    private func finishMigrationTask(id: UUID) {
        guard migrationTaskID == id else { return }
        migrationTask = nil
        migrationTaskID = nil
    }
}

enum PlanRepositoryAvailabilityError: LocalizedError, Equatable, Sendable {
    case unavailable

    var errorDescription: String? {
        "기기 저장소를 열 수 없어 변경 내용을 저장하지 않습니다."
    }
}

actor UnavailablePlanRepository: PlanDataRepository {
    func load() async throws -> TaptionDataSnapshot {
        throw PlanRepositoryAvailabilityError.unavailable
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        throw PlanRepositoryAvailabilityError.unavailable
    }

    func deleteAll() async throws {
        throw PlanRepositoryAvailabilityError.unavailable
    }
}

struct PlanRepositorySelection {
    let repository: any PlanDataRepository
    let source: String
}

enum PlanRepositoryResolver {
    static func resolve(
        appGroupSQLite: (any PlanDataRepository)?,
        appGroupFile: (any PlanDataRepository)?,
        applicationSupportSQLite: (any PlanDataRepository)?,
        applicationSupportFile: (any PlanDataRepository)?
    ) -> PlanRepositorySelection {
        let legacy = combinedLegacy(
            appGroupFile: appGroupFile,
            applicationSupportFile: applicationSupportFile
        )
        if let appGroupSQLite {
            return selection(
                primary: appGroupSQLite,
                legacy: legacy,
                source: "sqlite-app-group"
            )
        }
        if let applicationSupportSQLite {
            return selection(
                primary: applicationSupportSQLite,
                legacy: legacy,
                source: "sqlite-application-support"
            )
        }
        if let legacy {
            return PlanRepositorySelection(
                repository: legacy,
                source: appGroupFile == nil
                    ? "file-application-support"
                    : "file-app-group"
            )
        }
        return PlanRepositorySelection(
            repository: UnavailablePlanRepository(),
            source: "unavailable"
        )
    }

    private static func selection(
        primary: any PlanDataRepository,
        legacy: (any PlanDataRepository)?,
        source: String
    ) -> PlanRepositorySelection {
        guard let legacy else {
            return PlanRepositorySelection(
                repository: primary,
                source: source
            )
        }
        return PlanRepositorySelection(
            repository: MigratingPlanRepository(
                primary: primary,
                legacy: legacy
            ),
            source: source + "+one-time-import"
        )
    }

    private static func combinedLegacy(
        appGroupFile: (any PlanDataRepository)?,
        applicationSupportFile: (any PlanDataRepository)?
    ) -> (any PlanDataRepository)? {
        if let appGroupFile, let applicationSupportFile {
            return MigratingPlanRepository(
                primary: appGroupFile,
                legacy: applicationSupportFile
            )
        }
        return appGroupFile ?? applicationSupportFile
    }
}

enum RepositoryError: Error, Equatable {
    case invalidSnapshot
    case unsupportedSchema(Int)
    case cloudAccountUnavailable
    case cloudSchemaUnavailable
    case cloudPayloadMissing
    case cloudPayloadTooLarge
    case appGroupUnavailable
    case staleGeneration
}

enum TaptionSnapshotCompressionError: Error, Equatable {
    case invalidLimit
    case invalidHeader
    case uncompressedSizeExceedsLimit(actual: UInt64, maximum: Int)
    case decompressionFailed(expected: Int, actual: Int)
}

/// Keeps the shared snapshot small without changing its on-disk path.  The
/// decoder accepts the old plain JSON file so existing installs migrate on
/// their next save.
enum TaptionSnapshotCompression {
    private static let magic: [UInt8] = [0x54, 0x50, 0x5A, 0x31]
    private static let headerSize = magic.count + 8
    private static let minimumSize = 4 * 1024
    static let maximumUncompressedSize = 64 * 1_024 * 1_024
    // ponytail: one monthly raw JSON caps at 256 MiB; split by retention unit
    // when growth requires it.
    static let maximumRawSensorUncompressedSize = 256 * 1_024 * 1_024

    static func encode(
        _ json: Data,
        maximumSize: Int = Self.maximumUncompressedSize
    ) -> Data {
        guard maximumSize > 0,
              json.count >= minimumSize,
              json.count <= maximumSize else { return json }
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
        (try? decodeChecked(data)) ?? data
    }

    static func decodeChecked(
        _ data: Data,
        maximumSize: Int = Self.maximumUncompressedSize
    ) throws -> Data {
        guard maximumSize > 0 else {
            throw TaptionSnapshotCompressionError.invalidLimit
        }
        guard data.count >= magic.count,
              data.prefix(magic.count).elementsEqual(magic) else {
            return data
        }
        guard data.count >= headerSize else {
            throw TaptionSnapshotCompressionError.invalidHeader
        }

        let originalSize = readLittleEndian(
            data.dropFirst(magic.count).prefix(8)
        )
        guard originalSize > 0 else {
            throw TaptionSnapshotCompressionError.invalidHeader
        }
        guard originalSize <= UInt64(maximumSize) else {
            throw TaptionSnapshotCompressionError
                .uncompressedSizeExceedsLimit(
                    actual: originalSize,
                    maximum: maximumSize
                )
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
        guard decodedCount == expectedSize else {
            throw TaptionSnapshotCompressionError.decompressionFailed(
                expected: expectedSize,
                actual: decodedCount
            )
        }
        return decoded
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
    private let lockURL: URL
    private let generationURL: URL
    private let deletionPendingURL: URL
    private let storageLabel: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var fileGeneration: UInt64
    private var dataDeletionGeneration: UInt64

    private var backupURL: URL {
        fileURL.appendingPathExtension("backup")
    }

    init(fileURL: URL, storageLabel: String = "file") {
        self.fileURL = fileURL
        lockURL = fileURL.appendingPathExtension("lock")
        generationURL = fileURL.appendingPathExtension("generation")
        deletionPendingURL = fileURL.appendingPathExtension("deletion-pending")
        self.storageLabel = storageLabel
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        fileGeneration = Self.readGeneration(
            at: fileURL.appendingPathExtension("generation")
        )
        dataDeletionGeneration = TaptionDataDeletionFence.currentGeneration()
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
        identifier: String = TaptionPlanSharedContainer.appGroupIdentifier,
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
        try await withLockRetry { try loadLocked() }
    }

    private func loadLocked() throws -> TaptionDataSnapshot {
        if FileManager.default.fileExists(atPath: deletionPendingURL.path) {
            let recoveredGeneration = TaptionRepositoryDeletionMarker.recoveredGeneration(
                at: deletionPendingURL,
                current: readGeneration()
            )
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try Data(String(recoveredGeneration).utf8).write(
                to: generationURL,
                options: .atomic
            )
            try FileManager.default.removeItem(at: deletionPendingURL)
        }
        fileGeneration = readGeneration()
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
            try await withLockRetry {
                guard fileGeneration == readGeneration(),
                      TaptionDataDeletionFence.allows(
                        generation: dataDeletionGeneration
                      ) else {
                    throw RepositoryError.staleGeneration
                }
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // Keep the last valid generation. Never replace this backup from
                // a file that no longer decodes.
                if FileManager.default.fileExists(atPath: fileURL.path),
                   (try? loadSnapshot(at: fileURL)) != nil {
                    let previous = try Data(contentsOf: fileURL)
                    try previous.write(
                        to: backupURL,
                        options: [
                            .atomic,
                            .completeFileProtectionUntilFirstUserAuthentication,
                        ]
                    )
                }
                guard fileGeneration == readGeneration(),
                      TaptionDataDeletionFence.allows(
                        generation: dataDeletionGeneration
                      ) else {
                    throw RepositoryError.staleGeneration
                }
                try data.write(
                    to: fileURL,
                    options: [
                        .atomic,
                        .completeFileProtectionUntilFirstUserAuthentication,
                    ]
                )
            }
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
        try await withLockRetry {
            let current = readGeneration()
            guard current < UInt64.max else {
                throw RepositoryError.staleGeneration
            }
            fileGeneration = current + 1
            try TaptionRepositoryDeletionMarker.write(
                generation: fileGeneration,
                to: deletionPendingURL
            )
            try Data(String(fileGeneration).utf8).write(
                to: generationURL,
                options: .atomic
            )
            dataDeletionGeneration = TaptionDataDeletionFence.currentGeneration()
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.removeItem(at: deletionPendingURL)
        }
    }

    private func withLockRetry<Value>(
        _ operation: () throws -> Value
    ) async throws -> Value {
        while true {
            try Task.checkCancellation()
            do {
                return try TaptionDataFileLock.withLock(
                    url: lockURL,
                    operation
                )
            } catch TaptionDataFileLock.AcquireError.busy {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private func readGeneration() -> UInt64 {
        Self.readGeneration(at: generationURL)
    }

    private static func readGeneration(at url: URL) -> UInt64 {
        guard let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8),
              let generation = UInt64(value) else { return 0 }
        return generation
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

    private struct LoadedRows: Sendable {
        let generation: UInt64
        let rows: [TaptionPlanDayStore.Snapshot]
        let actualRows: [TaptionPlanDayStore.ActualRow]?
        let actualRevision: UInt64
        let readVersion: TaptionPlanDayStore.SnapshotReadVersion?
        let reusedRows: Bool
    }

    private struct SavedRows: Sendable {
        let generation: UInt64
        let nextRevision: UInt64
        let revisions: [String: UInt64]
        let encodedDomains: [String]
        let loadStamps: [LoadedRowStamp]?
        let readVersion: TaptionPlanDayStore.SnapshotReadVersion
        let readMS: Double
        let encodeMS: Double
        let writeMS: Double
        let verifyMS: Double
        let reusedRows: Bool
        let writtenDomains: Int
        let actualRevision: UInt64
        let actualKeys: [String]
        let comparedRecords: Int
        let writtenRecords: Int
    }

    private struct CommittedSnapshot: Sendable {
        let value: TaptionDataSnapshot
        let generation: UInt64
        let revisions: [String: UInt64]
        let loadStamps: [LoadedRowStamp]?
        let readVersion: TaptionPlanDayStore.SnapshotReadVersion?
        let actualRevision: UInt64
        let actualKeys: [String]
    }

    private struct LoadedRowStamp: Equatable, Sendable {
        let domain: Data
        let revision: UInt64
        let updatedAt: Date
        let payloadDigest: SHA256.Digest
        let payloadBytes: Int

        init(_ row: TaptionPlanDayStore.Snapshot) {
            domain = Data(row.domain.utf8)
            revision = row.revision
            updatedAt = row.updatedAt
            payloadDigest = SHA256.hash(data: row.payload)
            payloadBytes = row.payload.count
        }
    }

    private struct DeletedRows: Sendable {
        let generation: UInt64
        let deletionGeneration: UInt64
    }

    private let store: TaptionPlanDayStore
    private let lockURL: URL
    private let generationURL: URL
    private let deletionPendingURL: URL
    private var nextRevision: UInt64 = 0
    private var observedGeneration: UInt64?
    private var dataDeletionGeneration: UInt64
    private var committedSnapshot: CommittedSnapshot?
    private var cacheEpoch: UInt64 = 0
    private(set) var lastEncodedDomains: [String] = []
    private(set) var lastLoadReusedSnapshot = false
    private(set) var lastLoadSkippedPayloadRead = false
    private(set) var lastDecodedDomains: [String] = []
    private(set) var lastComparedActualRecords = 0
    private(set) var lastWrittenActualRecords = 0

    init(databaseURL: URL) throws {
        self.store = try TaptionPlanDayStore(url: databaseURL, allowsUndatedSnapshots: true)
        lockURL = databaseURL.appendingPathExtension("lock")
        generationURL = databaseURL.appendingPathExtension("generation")
        deletionPendingURL = databaseURL.appendingPathExtension("deletion-pending")
        observedGeneration = Self.readGeneration(at: generationURL)
        dataDeletionGeneration = TaptionDataDeletionFence.currentGeneration()
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
        identifier: String = TaptionPlanSharedContainer.appGroupIdentifier,
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
        let epoch = cacheEpoch
        let cached = committedSnapshot
        var succeeded = false
        lastLoadReusedSnapshot = false
        lastLoadSkippedPayloadRead = false
        lastDecodedDomains = []
        defer {
            if !succeeded { clearSerializationCache() }
        }
        let generationURL = self.generationURL
        let deletionPendingURL = self.deletionPendingURL
        let readStart = ProcessInfo.processInfo.systemUptime
        let loaded = try await withStoreLockRetry { store in
            if FileManager.default.fileExists(atPath: deletionPendingURL.path) {
                let recoveredGeneration =
                    TaptionRepositoryDeletionMarker.recoveredGeneration(
                        at: deletionPendingURL,
                        current: Self.readGeneration(at: generationURL)
                    )
                try store.deleteAllContent()
                try Data(String(recoveredGeneration).utf8).write(
                    to: generationURL,
                    options: .atomic
                )
                try FileManager.default.removeItem(at: deletionPendingURL)
            }
            let version = try store.snapshotReadVersion()
            if cached?.readVersion != version || cached?.generation != Self.readGeneration(at: generationURL) {
                try Self.importInlineActualsIfNeeded(store)
            }
            return try store.withSnapshotReadTransaction { store in
                let generation = Self.readGeneration(at: generationURL)
                // Capture before SELECT so a concurrent commit cannot tag old rows with a newer version.
                let version = try store.snapshotReadVersion()
                let reuse = cached?.generation == generation
                    && cached?.readVersion == version && cached?.loadStamps != nil
                let actualRevision = try store.actualRecordRevision()
                let rows = reuse ? [] : try store.snapshots(day: Self.day)
                let root = rows.first { $0.domain == PlanActualStorage.domain }
                let rootUnchanged = reuse || root.map { row in
                    cached?.loadStamps?.contains(LoadedRowStamp(row)) == true
                } == true
                let reuseActuals = cached?.generation == generation && rootUnchanged
                    && cached?.actualRevision == actualRevision
                return LoadedRows(generation: generation, rows: rows,
                    actualRows: reuseActuals ? nil : root == nil ? [] : try store.actualRecords(), actualRevision: actualRevision,
                    readVersion: version, reusedRows: reuse)
            }
        }
        try Task.checkCancellation()
        let readMS = (ProcessInfo.processInfo.systemUptime - readStart) * 1_000
        let verificationStart = ProcessInfo.processInfo.systemUptime
        let stamps = loaded.reusedRows ? (cached?.loadStamps ?? []) : loaded.rows.map(LoadedRowStamp.init)
        let verificationMS = (ProcessInfo.processInfo.systemUptime - verificationStart) * 1_000
        let decodeStart = ProcessInfo.processInfo.systemUptime
        let value: TaptionDataSnapshot
        if let cached,
           cached.generation == loaded.generation,
           cached.loadStamps == stamps, cached.actualRevision == loaded.actualRevision {
            value = cached.value
            lastLoadReusedSnapshot = true
        } else {
            let prior = cached?.generation == loaded.generation ? cached : nil
            let priorStamps = Dictionary(uniqueKeysWithValues: (prior?.loadStamps ?? []).map { ($0.domain, $0) })
            var reusableDomains = Set(stamps.filter { priorStamps[$0.domain] == $0 }.map(\.domain))
            if prior?.actualRevision != loaded.actualRevision { reusableDomains.remove(Data(PlanActualStorage.domain.utf8)) }
            value = try snapshot(from: loaded.rows, actualRows: loaded.actualRows,
                reusing: prior?.value, reusableDomains: reusableDomains)
        }
        lastLoadSkippedPayloadRead = loaded.reusedRows
        let decodeMS = (ProcessInfo.processInfo.systemUptime - decodeStart) * 1_000
        try Task.checkCancellation()
        remember(
            value,
            generation: loaded.generation,
            revisions: loaded.reusedRows ? (cached?.revisions ?? [:])
                : Dictionary(uniqueKeysWithValues: loaded.rows.map { ($0.domain, $0.revision) }),
            epoch: epoch,
            loadStamps: stamps, readVersion: loaded.readVersion,
            actualRevision: loaded.actualRevision,
            actualKeys: loaded.actualRows?.map(\.key) ?? cached?.actualKeys ?? []
        )
        TaptionPlanDiagnosticsLogger.shared.record(
            "repository_local_load",
            fields: [
                "read_ms": String(format: "%.2f", readMS),
                "verify_ms": String(format: "%.2f", verificationMS),
                "decode_ms": String(format: "%.2f", decodeMS),
                "domains": String(stamps.count),
                "stored_bytes": String(stamps.reduce(0) { $0 + $1.payloadBytes }),
                "payload_read_bytes": String(loaded.rows.reduce(0) { $0 + $1.payload.count }),
                "actual_rows_read": String(loaded.actualRows?.count ?? 0),
                "reused_rows": String(loaded.reusedRows),
                "decoded_domains": String(lastDecodedDomains.count),
                "reused_snapshot": String(lastLoadReusedSnapshot),
            ]
        )
        succeeded = true
        return value
    }

    func loadStartupSnapshot() async throws -> TaptionDataSnapshot? {
        let generationURL = self.generationURL
        let deletionPendingURL = self.deletionPendingURL
        let loaded = try await withStoreLockRetry { store in
            guard !FileManager.default.fileExists(atPath: deletionPendingURL.path),
                  !TaptionDataDeletionFence.repositoryDeletionIsPending() else {
                return LoadedRows(generation: Self.readGeneration(at: generationURL), rows: [], actualRows: nil, actualRevision: 0,
                    readVersion: nil, reusedRows: false)
            }
            let rows = try [Self.metadataDomain, "plan.settings", "plan.categories"].compactMap {
                try store.snapshot(domain: $0, day: Self.day)
            }
            return LoadedRows(generation: Self.readGeneration(at: generationURL), rows: rows, actualRows: nil, actualRevision: 0,
                readVersion: nil, reusedRows: false)
        }
        try Task.checkCancellation()
        guard loaded.rows.contains(where: { $0.domain == Self.metadataDomain }) else { return nil }
        let value = try snapshot(from: loaded.rows)
        guard value.updatedAt != .distantPast else { return nil }
        observedGeneration = max(observedGeneration ?? 0, loaded.generation)
        return value
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        try await save(snapshot, actualEdit: nil)
    }

    func save(_ snapshot: TaptionDataSnapshot, actualEdit: PlanActualEdit?) async throws {
        var value = snapshot
        value.updatedAt = .now
        let valueToSave = value
        try await TaptionRepositoryBackgroundExecution.run {
            try await self.saveProtected(valueToSave, actualEdit: actualEdit)
        }
    }

    private func saveProtected(_ value: TaptionDataSnapshot, actualEdit: PlanActualEdit?) async throws {
        let totalStart = ProcessInfo.processInfo.systemUptime
        let expectedGeneration = observedGeneration
        let currentNextRevision = nextRevision
        let deletionGeneration = dataDeletionGeneration
        let generationURL = self.generationURL
        let cached = committedSnapshot
        let epoch = cacheEpoch
        let saved = try await withStoreLockRetry { store in
            try store.withSnapshotWriteTransaction { store in
                let readStart = ProcessInfo.processInfo.systemUptime
                let generation = Self.readGeneration(at: generationURL)
                guard expectedGeneration == nil || expectedGeneration == generation,
                      TaptionDataDeletionFence.allows(generation: deletionGeneration) else {
                    throw RepositoryError.staleGeneration
                }
                let version = try store.snapshotReadVersion()
                let reuse = cached?.generation == generation
                    && cached?.readVersion == version && cached?.loadStamps != nil
                let storedRows = reuse ? [] : try store.snapshots(day: Self.day)
                let rowByDomain = Dictionary(uniqueKeysWithValues: storedRows.map { ($0.domain, $0) })
                let cachedStamps = Dictionary(uniqueKeysWithValues: (cached?.loadStamps ?? []).map { ($0.domain, $0) })
                var expectedStamps = reuse ? cachedStamps
                    : Dictionary(uniqueKeysWithValues: storedRows.map { (Data($0.domain.utf8), LoadedRowStamp($0)) })
                var revisions = reuse ? (cached?.revisions ?? [:])
                    : Dictionary(uniqueKeysWithValues: storedRows.map { ($0.domain, $0.revision) })
                let actualRevision = try store.actualRecordRevision()
                let actualKey = Data(PlanActualStorage.domain.utf8)
                let actualCacheMatches = cached?.generation == generation
                    && cachedStamps[actualKey] == expectedStamps[actualKey]
                    && cached?.actualRevision == actualRevision
                var actualDelta: PlanActualStorage.Delta?
                let readMS = (ProcessInfo.processInfo.systemUptime - readStart) * 1_000
                var revision = max(currentNextRevision, revisions.values.max() ?? 0)
                guard revision < UInt64(Int64.max) else {
                    throw TaptionPlanDayStoreError.revisionOverflow
                }
                revision += 1
                var writes: [TaptionPlanDayStore.Snapshot] = []
                var encodedDomains: [String] = []
                var encodeMS = 0.0
                func append<Value: Encodable>(
                    _ domain: String, _ field: Value, unchanged: Bool = false,
                    store: isolated TaptionPlanDayStore, force: Bool = false
                ) throws {
                    try Task.checkCancellation()
                    let key = Data(domain.utf8)
                    if !force, cached?.generation == generation, unchanged,
                       let expected = expectedStamps[key], cachedStamps[key] == expected {
                        return
                    }
                    encodedDomains.append(domain)
                    let encodeStart = ProcessInfo.processInfo.systemUptime
                    let payload = try Self.payload(field)
                    encodeMS += (ProcessInfo.processInfo.systemUptime - encodeStart) * 1_000
                    if !force {
                        let stored = reuse ? try store.snapshot(domain: domain, day: Self.day) : rowByDomain[domain]
                        if stored?.payload == payload { return }
                    }
                    guard revision > (revisions[domain] ?? 0) else {
                        throw TaptionPlanDayStoreError.revisionOverflow
                    }
                    writes.append(.init(domain: domain, day: Self.day, revision: revision,
                        updatedAt: .now, payload: payload))
                    revisions[domain] = revision
                }
                try append(
                    Self.metadataDomain,
                    Metadata(schemaVersion: value.schemaVersion, updatedAt: value.updatedAt),
                    store: store, force: true
                )
                try append("plan.plans", value.plans, unchanged: Self.sharesStorage(value.plans, previous: cached?.value.plans), store: store)
                let unchangedActuals = actualCacheMatches && expectedStamps[actualKey] != nil
                    && Self.sharesStorage(value.actuals, previous: cached?.value.actuals)
                if !unchangedActuals {
                    let encodeStart = ProcessInfo.processInfo.systemUptime
                    actualDelta = try PlanActualStorage.delta(value.actuals,
                        previous: actualCacheMatches ? cached?.value.actuals : nil,
                        previousKeys: actualCacheMatches ? cached?.actualKeys ?? [] : [], edit: actualEdit)
                    encodeMS += (ProcessInfo.processInfo.systemUptime - encodeStart) * 1_000
                    // The root contains only the storage version and count; records live in typed rows.
                    try append(PlanActualStorage.domain, PlanActualStorage.NativeHeader(count: value.actuals.count), store: store)
                }
                try append("plan.recordLinks", value.recordLinks, unchanged: Self.sharesStorage(value.recordLinks, previous: cached?.value.recordLinks), store: store)
                try append("plan.memos", value.memos, unchanged: Self.sharesStorage(value.memos, previous: cached?.value.memos), store: store)
                try append("plan.stickers", value.stickers, unchanged: Self.sharesStorage(value.stickers, previous: cached?.value.stickers), store: store)
                try append("plan.categories", value.categories, unchanged: Self.sharesStorage(value.categories, previous: cached?.value.categories), store: store)
                try append("plan.photos", value.photos, unchanged: Self.sharesStorage(value.photos, previous: cached?.value.photos), store: store)
                try append("plan.calendarEvents", value.calendarEvents, unchanged: Self.sharesStorage(value.calendarEvents, previous: cached?.value.calendarEvents), store: store)
                try append("plan.weather", value.weather, unchanged: Self.sharesStorage(value.weather, previous: cached?.value.weather), store: store)
                try append("plan.places", value.places, unchanged: Self.sharesStorage(value.places, previous: cached?.value.places), store: store)
                try append("plan.travel", value.travel, unchanged: Self.sharesStorage(value.travel, previous: cached?.value.travel), store: store)
                try append("plan.floorTransitions", value.floorTransitions, unchanged: Self.sharesStorage(value.floorTransitions, previous: cached?.value.floorTransitions), store: store)
                try append("plan.yearlyReports", value.yearlyReports, unchanged: Self.sharesStorage(value.yearlyReports, previous: cached?.value.yearlyReports), store: store)
                try append("plan.settings", value.settings, store: store)
                guard TaptionDataDeletionFence.allows(generation: deletionGeneration) else {
                    throw RepositoryError.staleGeneration
                }
                let writeStart = ProcessInfo.processInfo.systemUptime
                if let actualDelta {
                    try PlanActualStorage.write(actualDelta, records: value.actuals, to: store)
                }
                try store.saveSnapshots(writes)
                let writeMS = (ProcessInfo.processInfo.systemUptime - writeStart) * 1_000
                let verifyStart = ProcessInfo.processInfo.systemUptime
                let writtenByDomain = Dictionary(uniqueKeysWithValues: writes.map { ($0.domain, $0) })
                for row in writes { expectedStamps[Data(row.domain.utf8)] = LoadedRowStamp(row) }
                let committedRows = try store.snapshots(day: Self.day)
                let committedStamps = committedRows.map(LoadedRowStamp.init)
                let matches = committedRows.count == expectedStamps.count && zip(committedRows, committedStamps).allSatisfy { row, stamp in
                    if let written = writtenByDomain[row.domain] {
                        return row.revision == written.revision && row.payload == written.payload
                    }
                    return expectedStamps[stamp.domain] == stamp
                }
                guard matches else { throw TaptionPlanCanonicalStorageError.checksumMismatch }
                let verifyMS = (ProcessInfo.processInfo.systemUptime - verifyStart) * 1_000
                return SavedRows(generation: generation, nextRevision: revision,
                    revisions: revisions, encodedDomains: encodedDomains,
                    loadStamps: matches ? committedStamps : nil,
                    readVersion: try store.snapshotReadVersion(),
                    readMS: readMS, encodeMS: encodeMS, writeMS: writeMS, verifyMS: verifyMS,
                    reusedRows: reuse, writtenDomains: writes.count,
                    actualRevision: try store.actualRecordRevision(),
                    actualKeys: actualDelta?.keys ?? cached?.actualKeys ?? [],
                    comparedRecords: actualDelta?.comparedRecords ?? 0,
                    writtenRecords: actualDelta?.replaceAll == true ? value.actuals.count
                        : (actualDelta?.rows.count ?? 0) + (actualDelta?.deletedKeys.count ?? 0))
            }
        }
        if saved.generation >= (observedGeneration ?? 0), saved.nextRevision >= nextRevision {
            lastEncodedDomains = saved.encodedDomains
            lastComparedActualRecords = saved.comparedRecords
            lastWrittenActualRecords = saved.writtenRecords
        }
        try Task.checkCancellation()
        remember(value, generation: saved.generation, revisions: saved.revisions,
                 epoch: epoch, loadStamps: saved.loadStamps, readVersion: saved.readVersion,
                 actualRevision: saved.actualRevision, actualKeys: saved.actualKeys)
        TaptionPlanDiagnosticsLogger.shared.record("repository_local_save", fields: [
            "total_ms": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - totalStart) * 1_000),
            "read_ms": String(format: "%.2f", saved.readMS),
            "encode_ms": String(format: "%.2f", saved.encodeMS),
            "write_ms": String(format: "%.2f", saved.writeMS),
            "verify_ms": String(format: "%.2f", saved.verifyMS),
            "reused_rows": String(saved.reusedRows),
            "encoded_domains": String(saved.encodedDomains.count),
            "written_domains": String(saved.writtenDomains),
            "compared_actual_records": String(saved.comparedRecords),
            "written_actual_records": String(saved.writtenRecords),
        ])
    }

    private static func sharesStorage<Value>(_ value: [Value], previous: [Value]?) -> Bool {
        guard let previous, previous.count == value.count else { return false }
        if value.isEmpty { return true }
        // Buffer identity proves unchanged value contents without treating distinct
        // Unicode representations as equal or retaining temporary raw pointers.
        return previous.withUnsafeBufferPointer { old in
            value.withUnsafeBufferPointer { current in old.baseAddress == current.baseAddress }
        }
    }

    private func remember(
        _ value: TaptionDataSnapshot, generation: UInt64,
        revisions: [String: UInt64], epoch: UInt64,
        loadStamps: [LoadedRowStamp]? = nil,
        readVersion: TaptionPlanDayStore.SnapshotReadVersion? = nil,
        actualRevision: UInt64 = 0, actualKeys: [String] = []
    ) {
        guard generation >= (observedGeneration ?? 0) else { return }
        if generation != observedGeneration { nextRevision = 0 }
        observedGeneration = generation
        let revision = revisions.values.max() ?? 0
        guard revision >= nextRevision else { return }
        nextRevision = revision
        if epoch == cacheEpoch {
            committedSnapshot = .init(
                value: value, generation: generation, revisions: revisions,
                loadStamps: loadStamps, readVersion: readVersion,
                actualRevision: actualRevision, actualKeys: actualKeys
            )
        }
    }

    func handleMemoryPressure() async {
        clearSerializationCache()
    }

    private func clearSerializationCache() {
        cacheEpoch &+= 1
        committedSnapshot = nil
    }

    func deleteAll() async throws {
        try await TaptionRepositoryBackgroundExecution.run {
            try await self.deleteAllProtected()
        }
    }

    private func deleteAllProtected() async throws {
        let generationURL = self.generationURL
        let deletionPendingURL = self.deletionPendingURL
        let deleted = try await withStoreLockRetry { store in
            let current = Self.readGeneration(at: generationURL)
            guard current < UInt64.max else {
                throw TaptionPlanDayStoreError.revisionOverflow
            }
            let next = current + 1
            try TaptionRepositoryDeletionMarker.write(
                generation: next,
                to: deletionPendingURL
            )
            try Data(String(next).utf8).write(to: generationURL, options: .atomic)
            try store.deleteAllContent()
            try FileManager.default.removeItem(at: deletionPendingURL)
            return DeletedRows(
                generation: next,
                deletionGeneration: TaptionDataDeletionFence.currentGeneration()
            )
        }
        nextRevision = 0
        clearSerializationCache()
        lastEncodedDomains = []
        observedGeneration = deleted.generation
        dataDeletionGeneration = deleted.deletionGeneration
    }

    private func readGeneration() -> UInt64 {
        Self.readGeneration(at: generationURL)
    }

    private static func readGeneration(at url: URL) -> UInt64 {
        guard let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8),
              let generation = UInt64(value) else { return 0 }
        return generation
    }

    private func withStoreLockRetry<Value: Sendable>(
        _ operation: @Sendable (isolated TaptionPlanDayStore) throws -> Value
    ) async throws -> Value {
        while true {
            try Task.checkCancellation()
            do {
                return try await store.withExclusiveFileAccess(
                    at: lockURL,
                    operation
                )
            } catch TaptionPlanDayStoreError.exclusiveFileLockBusy {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private struct Metadata: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let updatedAt: Date
    }

    /// A one-time import replaces the deployed array payload atomically. No legacy copy is kept.
    private static func importInlineActualsIfNeeded(_ store: isolated TaptionPlanDayStore) throws {
        guard let row = try store.snapshot(domain: PlanActualStorage.domain, day: day),
              (try? PlanActualStorage.nativeHeader(row.payload)) == nil else { return }
        try store.withSnapshotWriteTransaction { store in
            guard let current = try store.snapshot(domain: PlanActualStorage.domain, day: day),
                  (try? PlanActualStorage.nativeHeader(current.payload)) == nil else { return }
            let records = try PlanActualStorage.decode([ActualRecord].self, from: current.payload)
            let delta = try PlanActualStorage.delta(records, previous: nil, previousKeys: [], edit: nil)
            try PlanActualStorage.write(delta, records: records, to: store)
            guard current.revision < UInt64(Int64.max) else { throw TaptionPlanDayStoreError.revisionOverflow }
            try store.saveSnapshots([.init(domain: PlanActualStorage.domain, day: day,
                revision: current.revision + 1, updatedAt: current.updatedAt,
                payload: payload(PlanActualStorage.NativeHeader(count: records.count)))])
        }
    }

    func actuals(in span: TimeSpan, matching source: [ActualRecord]) async throws -> [ActualRecord]? {
        guard let cached = committedSnapshot,
              PlanActualStorage.sharesStorage(source, cached.value.actuals) else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        let generationURL = self.generationURL
        let deletionPendingURL = self.deletionPendingURL
        let deletionGeneration = dataDeletionGeneration
        let rows = try await withStoreLockRetry { store -> [TaptionPlanDayStore.ActualRow]? in
            try store.withSnapshotReadTransaction { store in
                guard Self.readGeneration(at: generationURL) == cached.generation,
                      !FileManager.default.fileExists(atPath: deletionPendingURL.path),
                      TaptionDataDeletionFence.allows(generation: deletionGeneration),
                      try store.actualRecordRevision() == cached.actualRevision,
                      let root = try store.snapshot(domain: PlanActualStorage.domain, day: Self.day),
                      cached.loadStamps?.contains(LoadedRowStamp(root)) == true else { return nil }
                return try store.actualRecords(in: span.start...span.end)
            }
        }
        try Task.checkCancellation()
        guard let rows else { return nil }
        let records = try PlanActualStorage.records(from: rows)
        TaptionPlanDiagnosticsLogger.shared.record("repository_actual_range", fields: [
            "rows": String(records.count), "total_records": String(source.count),
            "elapsed_ms": String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - started) * 1_000),
        ])
        return records
    }

    private func snapshot(
        from rows: [TaptionPlanDayStore.Snapshot],
        actualRows: [TaptionPlanDayStore.ActualRow]? = nil,
        reusing previous: TaptionDataSnapshot? = nil,
        reusableDomains: Set<Data> = []
    ) throws -> TaptionDataSnapshot {
        var value = TaptionDataSnapshot.empty
        let rowByDomain = Dictionary(uniqueKeysWithValues: rows.map { ($0.domain, $0) })
        if let metadata = rowByDomain[Self.metadataDomain] {
            let decoded = try decode(Metadata.self, from: metadata.payload)
            lastDecodedDomains.append(Self.metadataDomain)
            value.schemaVersion = decoded.schemaVersion
            value.updatedAt = decoded.updatedAt
        }
        func assign<Value: Decodable>(_ domain: String, _ keyPath: WritableKeyPath<TaptionDataSnapshot, Value>) throws {
            guard let row = rowByDomain[domain] else { return }
            if let previous, reusableDomains.contains(Data(domain.utf8)) {
                value[keyPath: keyPath] = previous[keyPath: keyPath]
            } else {
                value[keyPath: keyPath] = try decode(Value.self, from: row.payload)
                lastDecodedDomains.append(domain)
            }
        }
        try assign("plan.plans", \.plans)
        if let row = rowByDomain[PlanActualStorage.domain] {
            if let previous, reusableDomains.contains(Data(PlanActualStorage.domain.utf8)) {
                value.actuals = previous.actuals
            } else {
                let header = try PlanActualStorage.nativeHeader(row.payload)
                guard let actualRows, actualRows.count == header.count,
                      actualRows.enumerated().allSatisfy({ $0.offset == $0.element.position }) else {
                    throw TaptionPlanCanonicalStorageError.invalidPayload
                }
                value.actuals = try PlanActualStorage.records(from: actualRows)
                lastDecodedDomains.append(PlanActualStorage.domain)
            }
        }
        try assign("plan.recordLinks", \.recordLinks)
        try assign("plan.memos", \.memos)
        try assign("plan.stickers", \.stickers)
        try assign("plan.categories", \.categories)
        try assign("plan.photos", \.photos)
        try assign("plan.calendarEvents", \.calendarEvents)
        try assign("plan.weather", \.weather)
        try assign("plan.places", \.places)
        try assign("plan.travel", \.travel)
        try assign("plan.floorTransitions", \.floorTransitions)
        try assign("plan.yearlyReports", \.yearlyReports)
        try assign("plan.settings", \.settings)
        guard value.schemaVersion <= TaptionDataSnapshot.empty.schemaVersion else {
            throw RepositoryError.unsupportedSchema(value.schemaVersion)
        }
        return value
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from payload: Data
    ) throws -> Value {
        let encoded = try TaptionPlanCanonicalStorage.encodedPayload(from: payload)
        return try TaptionPlanCanonicalStorage.decode(type, from: encoded)
    }

    private static func payload<Value: Encodable>(_ value: Value) throws -> Data {
        TaptionPlanCanonicalStorage.envelope(
            for: try TaptionPlanCanonicalStorage.encode(value)
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

    func deleteAll() async throws {
        snapshot = .empty
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
    static func sticker(_ id: UUID) -> String { "sticker:\(id.uuidString)" }
    static func link(_ id: UUID) -> String { "link:\(id.uuidString)" }
}

/// A snapshot is portable only when it does not claim device-derived results
/// without the raw evidence that can reproduce them. User edits remain the
/// authority; automatic records are rebuilt after raw sensor restore.
enum PlanCloudSnapshotRecoveryPolicy {
    static func sourceSafe(
        _ snapshot: TaptionDataSnapshot
    ) -> TaptionDataSnapshot {
        var value = snapshot
        value.actuals.removeAll {
            $0.source.usesAutomaticClassification && !$0.manuallyCorrected
        }
        value.travel.removeAll { !$0.isConfirmed }
        return value
    }

    static func iCloudSafe(
        _ snapshot: TaptionDataSnapshot
    ) -> TaptionDataSnapshot {
        let excludedActualIDs = Set(snapshot.actuals.compactMap {
            actual -> UUID? in
            if actual.categoryID == "sleep"
                || (actual.source.usesAutomaticClassification
                    && !actual.manuallyCorrected) {
                return actual.id
            }
            switch actual.source {
            case .healthKit, .appleWatch:
                return actual.id
            default:
                return nil
            }
        })
        var value = sourceSafe(snapshot)
        let excludedNodeIDs = Set(excludedActualIDs.map {
            "automatic.actual.\($0.uuidString)"
        })
        value.actuals.removeAll { excludedActualIDs.contains($0.id) }
        value.recordLinks.removeAll {
            excludedNodeIDs.contains($0.fromNodeID)
                || excludedNodeIDs.contains($0.toNodeID)
        }
        value.memos = value.memos.map { memo in
            guard let targetID = memo.targetID,
                  excludedNodeIDs.contains(targetID) else { return memo }
            var detached = memo
            detached.targetID = nil
            return detached
        }
        value.settings.activityCorrections = value.settings.activityCorrections
            .filter { !excludedActualIDs.contains($0.key) }
        value.settings.suppressedActualIDs.subtract(excludedActualIDs)
        value.settings.confirmedSleepSpans = []
        value.yearlyReports = []
        return value
    }
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
        let availablePlanIDs = Set(value.plans.map(\.id))
        value.memos = value.memos.map { memo in
            var value = memo
            if let planID = memo.planID,
               !availablePlanIDs.contains(planID) {
                value.planID = nil
            }
            if let targetID = memo.targetID,
               targetID.hasPrefix("plan."),
               let targetPlanID = UUID(
                   uuidString: String(targetID.dropFirst("plan.".count))
               ),
               !availablePlanIDs.contains(targetPlanID) {
                value.targetID = nil
            }
            return value
        }
        value.stickers = mergeStickers(primary.stickers, backup.stickers).filter {
            !deleted.contains(CloudBackupRecordKey.sticker($0.id))
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

    private static func mergeStickers(
        _ primary: [MapSticker],
        _ backup: [MapSticker]
    ) -> [MapSticker] {
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
    private static let inboundPayloadMaximum = TaptionSnapshotCompression.maximumUncompressedSize
    private static let temporaryAssetPrefix = "taption-cloud-"
    private static let temporaryAssetMaximumAge: TimeInterval = 60 * 60

    private let container: CKContainer
    private let database: CKDatabase
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var schemaUnavailable = false
    private var uploadInProgress = false

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
        Task.detached(priority: .utility) {
            let removed = Self.removeStaleTemporaryAssets(
                in: FileManager.default.temporaryDirectory,
                before: Date.now.addingTimeInterval(
                    -Self.temporaryAssetMaximumAge
                )
            )
            if removed > 0 {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "cloud_stale_temp_assets_removed",
                    fields: ["count": String(removed)]
                )
            }
        }
    }

    @discardableResult
    nonisolated static func removeStaleTemporaryAssets(
        in directory: URL,
        before cutoff: Date,
        fileManager: FileManager = .default
    ) -> Int {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var removed = 0
        for url in urls where
            url.lastPathComponent.hasPrefix(temporaryAssetPrefix)
                && url.pathExtension == "json" {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            ),
            values.isRegularFile == true,
            let modifiedAt = values.contentModificationDate,
            modifiedAt < cutoff
            else { continue }
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {}
        }
        return removed
    }

    nonisolated static func writeTemporaryAsset(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(Self.temporaryAssetPrefix)\(UUID().uuidString).json"
            )
        try data.write(
            to: url,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
        return url
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

        let safeLocal = PlanCloudSnapshotRecoveryPolicy.iCloudSafe(local)
        guard let remote = try await fetch() else {
            let uploaded = try await upload(safeLocal)
            return (uploaded, .uploaded)
        }
        let safeRemote = PlanCloudSnapshotRecoveryPolicy.iCloudSafe(remote)
        let merged = CloudSnapshotRecoveryEngine.merge(
            local: safeLocal,
            remote: safeRemote
        )
        if remote != safeRemote {
            return (try await upload(merged), .uploaded)
        }
        if merged == safeLocal, merged == safeRemote {
            return (merged, .unchanged)
        }
        if merged == safeRemote {
            return (merged, .downloaded)
        }
        let uploaded = try await upload(merged)
        return (uploaded, merged == safeLocal ? .uploaded : .downloaded)
    }

    func fetch() async throws -> TaptionDataSnapshot? {
        guard let record = try await fetchRecord() else { return nil }
        return try snapshot(from: record)
    }

    func deleteSnapshot() async throws {
        try await acquireUploadTurn()
        defer { releaseUploadTurn() }
        guard await accountState() == .authorized else {
            throw RepositoryError.cloudAccountUnavailable
        }
        do {
            _ = try await database.deleteRecord(
                withID: CKRecord.ID(recordName: Self.recordName)
            )
        } catch let error as CKError where error.code == .unknownItem {
            return
        }
    }

    @discardableResult
    func upload(_ snapshot: TaptionDataSnapshot) async throws -> TaptionDataSnapshot {
        try await acquireUploadTurn()
        defer { releaseUploadTurn() }
        try Task.checkCancellation()
        guard !schemaUnavailable else {
            throw RepositoryError.cloudSchemaUnavailable
        }
        do {
            let safeSnapshot = PlanCloudSnapshotRecoveryPolicy.iCloudSafe(
                snapshot
            )
            let record = try await fetchRecord()
            let value: TaptionDataSnapshot
            if let record {
                value = CloudSnapshotRecoveryEngine.merge(
                    local: safeSnapshot,
                    remote: PlanCloudSnapshotRecoveryPolicy.iCloudSafe(
                        try self.snapshot(from: record)
                    )
                )
            } else {
                value = safeSnapshot
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

    private func acquireUploadTurn() async throws {
        while uploadInProgress {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        uploadInProgress = true
    }

    private func releaseUploadTurn() {
        uploadInProgress = false
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
                assetURL = try Self.writeTemporaryAsset(data)
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
                        remote: PlanCloudSnapshotRecoveryPolicy.iCloudSafe(
                            remote
                        )
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
            guard inline.count <= Self.inboundPayloadMaximum else {
                throw RepositoryError.cloudPayloadTooLarge
            }
            data = inline
        } else if let asset = record["payloadAsset"] as? CKAsset,
                  let fileURL = asset.fileURL {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = values.fileSize,
                  fileSize >= 0,
                  fileSize <= Self.inboundPayloadMaximum else {
                throw RepositoryError.cloudPayloadTooLarge
            }
            data = try Data(contentsOf: fileURL)
            guard data?.count ?? 0 <= Self.inboundPayloadMaximum else {
                throw RepositoryError.cloudPayloadTooLarge
            }
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
