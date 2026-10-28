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
    /// 저장 직후 되읽기용: 이 기록 id들이 저장소에 남아 있는지만 확인한다.
    /// 전체 스냅샷을 다시 읽으면 수만 행을 해독하므로, 확인만 필요할 때는 이 좁은 조회를 쓴다.
    func existingActualIDs(_ ids: Set<UUID>) async throws -> Set<UUID>
    func deleteAll() async throws
    func handleMemoryPressure() async
}

extension PlanDataRepository {
    func loadStartupSnapshot() async throws -> TaptionDataSnapshot? { nil }
    func save(_ snapshot: TaptionDataSnapshot, actualEdit: PlanActualEdit?) async throws {
        try await save(snapshot)
    }
    func actuals(in span: TimeSpan, matching source: [ActualRecord]) async throws -> [ActualRecord]? { nil }
    /// 기본 구현은 전체를 읽는다. 저장소가 좁은 조회를 지원하면 그쪽이 이긴다.
    func existingActualIDs(_ ids: Set<UUID>) async throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        return Set(try await load().actuals.map(\.id)).intersection(ids)
    }
}

#if os(iOS) && !TAPTION_WIDGET
/// iOS terminates an app whose expiration handler returns without ending the
/// task, so the handler must end it itself instead of waiting for the work.
@MainActor
final class BackgroundTaskAssertion {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin(name: String, onExpiration: @escaping @Sendable () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            onExpiration()
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif

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
        let assertion = BackgroundTaskAssertion()
        assertion.begin(name: "TaptionPlan.repository") { task.cancel() }
        // An invalid assertion means iOS granted no extra time. Still run the
        // write: dropping it silently would lose data that is still in memory.
        defer { assertion.end() }
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
    private static let activeDateKey = "TaptionPlan.dataDeletionActiveDate"
    private static let activeTimeout: TimeInterval = 600

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
        defaults.set(date, forKey: activeDateKey)
        defaults.synchronize()
        return next
    }

    static func finish(generation: UInt64) {
        guard generation == currentGeneration() else { return }
        defaults.removeObject(forKey: activeKey)
        defaults.removeObject(forKey: activeDateKey)
        defaults.synchronize()
    }

    static func allows(generation: UInt64, capturedAt: Date? = nil) -> Bool {
        if defaults.object(forKey: activeKey) != nil {
            let startedAt = defaults.object(forKey: activeDateKey) as? Date
            let expired = startedAt.map { Date.now.timeIntervalSince($0) > activeTimeout } ?? false
            if !expired,
               let marker = defaults.string(forKey: activeKey),
               let pid = Int32(marker),
               pid > 0,
               Darwin.kill(pid, 0) == 0 || errno == EPERM {
                return false
            }
            defaults.removeObject(forKey: activeKey)
            defaults.removeObject(forKey: activeDateKey)
            defaults.synchronize()
        }
        guard generation == currentGeneration() else { return false }
        guard let capturedAt, let cutoff = cutoff() else { return true }
        return capturedAt > cutoff
    }
}

extension PlanDataRepository {
    func deleteAll() async throws {
        try await save(.empty)
    }

    func handleMemoryPressure() async {}
}

enum PlanRepositoryAvailabilityError: LocalizedError, Equatable, Sendable {
    case unavailable

    var errorDescription: String? {
        message()
    }

    func message(preference: AppLanguagePreference = .current) -> String {
        AppLanguagePreference.text(
            korean: "기기 저장소를 열 수 없어 변경 내용을 저장하지 않습니다.",
            english: "The device storage could not be opened, so changes will not be saved.",
            preference: preference
        )
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
        statusLabel(preference: .current)
    }

    var guidance: String {
        guidance(preference: .current)
    }

    func statusLabel(preference: AppLanguagePreference) -> String {
        switch self {
        case .unsupportedBuild:
            AppLanguagePreference.text(
                korean: "이 빌드 미지원",
                english: "Unsupported in this build",
                preference: preference
            )
        case .signedOut:
            AppLanguagePreference.text(
                korean: "iCloud 로그인 필요",
                english: "iCloud sign-in required",
                preference: preference
            )
        case .restricted:
            AppLanguagePreference.text(
                korean: "기기에서 제한됨",
                english: "Restricted on this device",
                preference: preference
            )
        case .temporarilyUnavailable:
            AppLanguagePreference.text(
                korean: "잠시 후 다시",
                english: "Try again shortly",
                preference: preference
            )
        case .accountCheckFailed:
            AppLanguagePreference.text(
                korean: "계정 확인 실패",
                english: "Account check failed",
                preference: preference
            )
        case .schemaMissing:
            AppLanguagePreference.text(
                korean: "서버 설정 필요",
                english: "Server setup required",
                preference: preference
            )
        }
    }

    func guidance(preference: AppLanguagePreference) -> String {
        switch self {
        case .unsupportedBuild:
            AppLanguagePreference.text(
                korean: "이 빌드에는 iCloud 컨테이너가 없습니다. 기록은 이 기기에만 저장됩니다.",
                english: "This build has no iCloud container. Records are saved on this device only.",
                preference: preference
            )
        case .signedOut:
            AppLanguagePreference.text(
                korean: "설정 앱 → 맨 위 이름 → iCloud에서 로그인하고 iCloud Drive를 켠 뒤 이 줄을 눌러주세요.",
                english: "Sign in under Settings → your name at the top → iCloud, turn on iCloud Drive, then tap this row.",
                preference: preference
            )
        case .restricted:
            AppLanguagePreference.text(
                korean: "스크린타임이나 기기 관리 정책이 iCloud를 막고 있습니다. 제한을 푼 뒤 다시 시도해주세요.",
                english: "Screen Time or a device management policy is blocking iCloud. Remove the restriction and try again.",
                preference: preference
            )
        case .temporarilyUnavailable:
            AppLanguagePreference.text(
                korean: "iCloud 계정을 확인하는 중입니다. 잠시 뒤 이 줄을 눌러 다시 시도해주세요.",
                english: "Checking your iCloud account. Tap this row again shortly to retry.",
                preference: preference
            )
        case .accountCheckFailed:
            AppLanguagePreference.text(
                korean: "iCloud 계정 상태를 확인하지 못했습니다. 네트워크를 확인한 뒤 이 줄을 눌러주세요.",
                english: "Could not check your iCloud account status. Check your network, then tap this row.",
                preference: preference
            )
        case .schemaMissing:
            AppLanguagePreference.text(
                korean: "iCloud 컨테이너의 TaptionSnapshot 스키마가 Production에 배포되지 않았습니다. 배포 전까지 기록은 이 기기에 안전하게 저장되며, 배포 후 이 줄을 눌러 다시 시도할 수 있습니다.",
                english: "The iCloud container's TaptionSnapshot schema has not been deployed to Production. Until it is deployed, records are stored safely on this device; after deployment, tap this row to try again.",
                preference: preference
            )
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
                    "reason": result.1?.statusLabel(preference: .korean) ?? "authorized",
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
