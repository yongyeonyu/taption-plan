import CryptoKit
import XCTest
@testable import TaptionPlan

private func makePlanJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .secondsSince1970
    return encoder
}

private struct VersionOneArchiveEnvelope: Codable {
    let version: Int
    let monthKey: String
    let accountIdentifier: String
    let createdAt: Date
    let encryptedPayload: Data
    let wrappedPayloadKey: Data
    let accountWrappedPayloadKey: Data
    let payloadDigest: Data
    let generationID: UUID?
}

private final class RestoreCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellationCheckCount: Int
    private var currentCheckCount = 0

    init(cancellationCheckCount: Int) {
        self.cancellationCheckCount = cancellationCheckCount
    }

    var checkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentCheckCount
    }

    func check() throws {
        lock.lock()
        currentCheckCount += 1
        let shouldCancel = currentCheckCount == cancellationCheckCount
        lock.unlock()
        if shouldCancel { throw CancellationError() }
    }
}

@MainActor
final class SecurityBackupCoreTests: XCTestCase {
    func testBiometricAttemptGateRunsOncePerLockGeneration() {
        XCTAssertTrue(
            AppLockBiometricAttemptGate.shouldStart(
                generation: 1,
                attemptedGeneration: nil,
                isInFlight: false
            )
        )
        XCTAssertFalse(
            AppLockBiometricAttemptGate.shouldStart(
                generation: 1,
                attemptedGeneration: 1,
                isInFlight: false
            )
        )
        XCTAssertFalse(
            AppLockBiometricAttemptGate.shouldStart(
                generation: 1,
                attemptedGeneration: nil,
                isInFlight: true
            )
        )
        XCTAssertTrue(
            AppLockBiometricAttemptGate.shouldStart(
                generation: 2,
                attemptedGeneration: 1,
                isInFlight: false
            )
        )
    }

    func testPINVerifierStoresOnlySaltAndDigestAndUsesFourDigits() throws {
        let verifier = try PlanPINVerifier(pin: "1234") { _ in Data(repeating: 7, count: 16) }
        XCTAssertEqual(verifier.version, PlanPINVerifier.currentVersion)
        XCTAssertEqual(verifier.salt, Data(repeating: 7, count: 16))
        XCTAssertNotEqual(verifier.digest, Data("1234".utf8))
        XCTAssertTrue(verifier.matches("1234"))
        XCTAssertFalse(verifier.matches("1235"))
        XCTAssertThrowsError(try PlanPINVerifier(pin: "12345"))
        XCTAssertThrowsError(try PlanPINVerifier(pin: "12a4"))
    }

    func testPINVerifierRejectsRandomGenerationFailure() {
        XCTAssertThrowsError(
            try PlanPINVerifier(pin: "1234") { _ in
                throw PlanSecurityError.invalidCredential
            }
        ) { error in
            XCTAssertEqual(error as? PlanSecurityError, .invalidCredential)
        }
    }

    func testSecurityErrorsFollowTheSelectedLanguage() {
        XCTAssertEqual(
            PlanSecurityError.invalidPIN.localizedDescription(
                preference: .english
            ),
            "Check your 4-digit PIN and try again."
        )
        XCTAssertEqual(
            PlanSecurityError.biometricRejected.localizedDescription(
                preference: .korean
            ),
            "생체 인증을 완료하지 못했습니다."
        )
    }

    func testLegacyPINVerifierStillMatchesAfterPBKDF2Migration() throws {
        let salt = Data(repeating: 4, count: 16)
        var digest = Data("1234".utf8) + salt
        for _ in 0..<PlanPINVerifier.legacyIterations {
            digest = Data(SHA256.hash(data: digest))
        }
        let encoded = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "salt": salt.base64EncodedString(),
            "digest": digest.base64EncodedString(),
        ])
        let verifier = try JSONDecoder().decode(
            PlanPINVerifier.self,
            from: encoded
        )

        XCTAssertTrue(verifier.matches("1234"))
        XCTAssertFalse(verifier.matches("1235"))
    }

    func testCloudBackupAndAppLockRequirePIN() throws {
        let service = makeService()
        XCTAssertFalse(service.status.hasPIN)
        XCTAssertThrowsError(try service.saveMonthlyArchive(.empty, accountIdentifier: "account-a")) { error in
            XCTAssertEqual(error as? PlanSecurityError, .pinRequiredForCloudBackup)
        }
        XCTAssertThrowsError(
            try service.setAppLockSettings(
                .init(lockOnLaunch: false, lockOnForeground: true)
            )
        ) { error in
            XCTAssertEqual(error as? PlanSecurityError, .pinRequiredForCloudBackup)
        }
        try service.setPIN("1234")
        try service.setAppLockSettings(
            .init(lockOnLaunch: false, lockOnForeground: true)
        )
        service.handleForeground()
        XCTAssertTrue(service.status.state != .unlocked)
    }

    func testAppLockAttemptThrottlePersistsAcrossServiceRecreation() throws {
        let credentials = InMemoryPlanCredentialStore()
        let suiteName = "SecurityBackupCoreTests.pin-throttle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let backupStore = InMemoryPlanCloudBackupStore()
        let first = PlanSecurityBackupService(
            credentialStore: credentials,
            backupStore: backupStore,
            settingsDefaults: defaults
        )
        try first.setPIN("1234")
        let blockedAt = Date(timeIntervalSince1970: 10_000)
        for _ in 0..<5 {
            XCTAssertThrowsError(try first.verifyPIN("0000", now: blockedAt))
        }

        let replacement = PlanSecurityBackupService(
            credentialStore: credentials,
            backupStore: backupStore,
            settingsDefaults: defaults
        )
        XCTAssertThrowsError(
            try replacement.verifyPIN(
                "1234",
                now: blockedAt.addingTimeInterval(1)
            )
        ) { error in
            guard case .tooManyAttempts = error as? PlanSecurityError else {
                return XCTFail("Expected persisted PIN throttle, got \(error)")
            }
        }
        try replacement.verifyPIN("1234", now: blockedAt.addingTimeInterval(31))

        let reset = PlanSecurityBackupService(
            credentialStore: credentials,
            backupStore: backupStore,
            settingsDefaults: defaults
        )
        XCTAssertEqual(reset.status.failedAttempts, 0)
        XCTAssertNil(reset.status.retryAfter)
    }

    func testArchiveMetadataTamperingFailsAuthenticatedDecode() throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let service = makeService(backupStore: backupStore)
        try service.setPIN("1234")
        let createdAt = Date(timeIntervalSince1970: 10_000)
        let archive = try service.saveMonthlyArchive(
            .empty,
            accountIdentifier: "account-a",
            date: createdAt
        )
        let tampered = PlanMonthlyArchive(
            monthKey: archive.monthKey,
            accountIdentifier: archive.accountIdentifier,
            encryptedPayload: archive.encryptedPayload,
            wrappedPayloadKey: archive.wrappedPayloadKey,
            accountWrappedPayloadKey: archive.accountWrappedPayloadKey,
            createdAt: createdAt.addingTimeInterval(60),
            generationID: archive.generationID
        )
        try backupStore.save(
            tampered,
            at: PlanCloudBackupPath(monthKey: tampered.monthKey)
        )

        XCTAssertThrowsError(
            try service.loadLatestBackup(accountIdentifier: "account-a")
        ) { error in
            XCTAssertEqual(error as? PlanSecurityError, .invalidArchive)
        }
    }

    func testLatestSuccessfulBackupDatePersistsAndUsesArchiveCreatedAt() throws {
        let suiteName = "SecurityBackupCoreTests.latestBackup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let credentials = InMemoryPlanCredentialStore()
        let backupStore = InMemoryPlanCloudBackupStore()
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let writer = PlanSecurityBackupService(
            credentialStore: credentials,
            backupStore: backupStore,
            settingsDefaults: defaults
        )
        try writer.setPIN("1234")
        _ = try writer.saveMonthlyArchive(
            .empty,
            accountIdentifier: "account-a",
            date: date
        )

        XCTAssertEqual(writer.status.latestSuccessfulBackupDate, date)

        let replacement = PlanSecurityBackupService(
            credentialStore: credentials,
            backupStore: backupStore,
            settingsDefaults: defaults
        )
        XCTAssertEqual(replacement.status.latestSuccessfulBackupDate, date)
    }

    func testDeleteAllBackupsClearsSnapshotRawAndSuccessDate() throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore
        )
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_788_000_000)
        _ = try service.saveMonthlyArchive(
            .empty,
            accountIdentifier: "account-a",
            date: date
        )
        _ = try service.saveRawSensorArchive(
            .init(
                monthKey: "2026-09",
                sensorReadings: [SensorReading(timestamp: date)],
                envelopes: [],
                createdAt: date
            ),
            accountIdentifier: "account-a",
            date: date
        )

        try service.deleteAllBackups()

        XCTAssertTrue(backupStore.archives.isEmpty)
        XCTAssertTrue(rawStore.archives.isEmpty)
        XCTAssertNil(service.status.latestSuccessfulBackupDate)
    }

    func testDeleteAllBackupsKeepsSuccessDateWhenAStoreFails() throws {
        let date = Date(timeIntervalSince1970: 1_788_000_000)
        let service = makeService(
            rawSensorBackupStore: DeleteFailingRawSensorBackupStore()
        )
        try service.setPIN("1234")
        _ = try service.saveMonthlyArchive(
            .empty,
            accountIdentifier: "account-a",
            date: date
        )

        XCTAssertThrowsError(try service.deleteAllBackups())
        XCTAssertEqual(service.status.latestSuccessfulBackupDate, date)
    }

    func testFileBackupDeleteRemovesOnlyTaptionArchives() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-delete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let backupDirectory = root.appendingPathComponent("Taption Plan")
        let rawDirectory = backupDirectory.appendingPathComponent("Raw Sensors")
        try FileManager.default.createDirectory(
            at: rawDirectory,
            withIntermediateDirectories: true
        )
        let backup = backupDirectory.appendingPathComponent(
            "2026-09.taptionbackup"
        )
        let raw = rawDirectory.appendingPathComponent(
            "2026-09.rawsensorbackup"
        )
        let unrelated = backupDirectory.appendingPathComponent("keep.txt")
        try Data([1]).write(to: backup)
        try Data([2]).write(to: raw)
        try Data([3]).write(to: unrelated)

        try FilePlanCloudBackupStore(root: root).deleteAll()
        try FilePlanCloudRawSensorBackupStore(root: root).deleteAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testRawGenerationFilesKeepCommittedArchiveUntilSnapshotChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-generation-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FilePlanCloudRawSensorBackupStore(root: root)
        let committedID = UUID()
        let stagedID = UUID()
        let committed = PlanRawSensorMonthlyArchive(
            monthKey: "2026-08",
            accountIdentifier: "account-a",
            encryptedPayload: Data([1]),
            wrappedPayloadKey: Data([2]),
            accountWrappedPayloadKey: Data([3]),
            createdAt: Date(timeIntervalSince1970: 1),
            generationID: committedID
        )
        let staged = PlanRawSensorMonthlyArchive(
            monthKey: "2026-08",
            accountIdentifier: "account-a",
            encryptedPayload: Data([4]),
            wrappedPayloadKey: Data([5]),
            accountWrappedPayloadKey: Data([6]),
            createdAt: Date(timeIntervalSince1970: 2),
            generationID: stagedID
        )

        try store.save(
            committed,
            at: PlanCloudRawSensorBackupPath(
                monthKey: committed.monthKey,
                generationID: committedID
            )
        )
        try store.save(
            staged,
            at: PlanCloudRawSensorBackupPath(
                monthKey: staged.monthKey,
                generationID: stagedID
            )
        )

        XCTAssertEqual(try store.allArchives().count, 2)
        let corruptID = UUID()
        let corruptPath = PlanCloudRawSensorBackupPath(
            monthKey: "2026-08",
            generationID: corruptID
        )
        let corruptURL = corruptPath.storageComponents.reduce(root) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        try Data("incomplete sync".utf8).write(to: corruptURL)
        XCTAssertEqual(
            try store.load(monthKey: "2026-08", generationID: committedID),
            committed
        )
        try FileManager.default.removeItem(at: corruptURL)
        try store.delete(
            at: PlanCloudRawSensorBackupPath(
                monthKey: staged.monthKey,
                generationID: stagedID
            )
        )
        XCTAssertEqual(try store.allArchives(), [committed])
    }

    func testLegacyRawFileLoadsByItsCommittedGeneration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-legacy-generation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FilePlanCloudRawSensorBackupStore(root: root)
        let generationID = UUID()
        let archive = PlanRawSensorMonthlyArchive(
            monthKey: "2026-08",
            accountIdentifier: "account-a",
            encryptedPayload: Data([1]),
            wrappedPayloadKey: Data([2]),
            accountWrappedPayloadKey: Data([3]),
            createdAt: Date(timeIntervalSince1970: 1_787_538_400),
            generationID: generationID
        )
        try store.save(
            archive,
            at: PlanCloudRawSensorBackupPath(monthKey: archive.monthKey)
        )

        XCTAssertEqual(
            try store.load(monthKey: archive.monthKey, generationID: generationID),
            archive
        )
    }

    func testCommittedRawGenerationSurvivesRestartWithAnOrphanPresent()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-generation-restart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let credentialStore = InMemoryPlanCredentialStore()
        let recoveryKeys = InMemoryPlanCloudRecoveryKeyProvider()
        let defaults = UserDefaults(
            suiteName: "SecurityBackupCoreTests.\(UUID().uuidString)"
        )!
        let writer = PlanSecurityBackupService(
            credentialStore: credentialStore,
            backupStore: FilePlanCloudBackupStore(root: root),
            rawSensorBackupStore: FilePlanCloudRawSensorBackupStore(root: root),
            cloudRecoveryKeyProvider: recoveryKeys,
            settingsDefaults: defaults
        )
        try writer.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let reading = SensorReading(
            timestamp: date,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 20,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            )
        )
        let committed = try await writer.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [reading],
                createdAt: date
            ),
            date: date
        )
        let orphan = PlanRawSensorMonthlyArchive(
            monthKey: committed.snapshot.monthKey,
            accountIdentifier: committed.rawSensors!.accountIdentifier,
            encryptedPayload: Data([9]),
            wrappedPayloadKey: Data([8]),
            accountWrappedPayloadKey: Data([7]),
            createdAt: date.addingTimeInterval(60),
            generationID: UUID()
        )
        try FilePlanCloudRawSensorBackupStore(root: root).save(
            orphan,
            at: PlanCloudRawSensorBackupPath(
                monthKey: orphan.monthKey,
                generationID: orphan.generationID
            )
        )

        let restarted = PlanSecurityBackupService(
            credentialStore: credentialStore,
            backupStore: FilePlanCloudBackupStore(root: root),
            rawSensorBackupStore: FilePlanCloudRawSensorBackupStore(root: root),
            cloudRecoveryKeyProvider: recoveryKeys,
            settingsDefaults: defaults
        )
        let restored = try await restarted.loadLatestBackupPackage()
        guard case let .available(raw) = restored.rawSensorState else {
            return XCTFail("An uncommitted generation must not hide committed raw data")
        }
        XCTAssertEqual(raw.sensorReadings, [reading])
    }

    func testMissingCommittedMonthPreventsPartialRawRestore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-generation-partial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let backupStore = FilePlanCloudBackupStore(root: root)
        let rawStore = FilePlanCloudRawSensorBackupStore(root: root)
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        let firstDate = Date(timeIntervalSince1970: 1_787_538_400)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 20,
            horizontalAccuracy: 8,
            verticalAccuracy: 10
        )
        let secondDate = Calendar.autoupdatingCurrent.date(
            byAdding: .month,
            value: 1,
            to: firstDate
        )!
        let first = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [SensorReading(timestamp: firstDate, point: point)],
                createdAt: firstDate
            ),
            date: firstDate
        )
        _ = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [SensorReading(timestamp: secondDate, point: point)],
                createdAt: secondDate
            ),
            date: secondDate
        )
        try rawStore.delete(
            at: PlanCloudRawSensorBackupPath(
                monthKey: first.snapshot.monthKey,
                generationID: first.generationID
            )
        )

        do {
            _ = try await service.loadLatestBackupPackage()
            XCTFail("A missing committed month must not yield partial raw data")
        } catch {
            XCTAssertEqual(error as? PlanSecurityError, .accountUnavailable)
        }
    }

    func testFileBackupStoresSkipOneCorruptArchive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotStore = FilePlanCloudBackupStore(root: root)
        let createdAt = Date(timeIntervalSince1970: 1_788_000_000)
        let snapshot = PlanMonthlyArchive(
            monthKey: "2026-08",
            accountIdentifier: "account-a",
            encryptedPayload: Data([1]),
            wrappedPayloadKey: Data([2]),
            accountWrappedPayloadKey: Data([3]),
            createdAt: createdAt
        )
        try snapshotStore.save(
            snapshot,
            at: PlanCloudBackupPath(monthKey: snapshot.monthKey)
        )
        let snapshotDirectory = root.appendingPathComponent("Taption Plan")
        try Data("truncated".utf8).write(
            to: snapshotDirectory.appendingPathComponent(
                "2026-09.taptionbackup"
            )
        )

        let rawStore = FilePlanCloudRawSensorBackupStore(root: root)
        let raw = PlanRawSensorMonthlyArchive(
            monthKey: "2026-08",
            accountIdentifier: "account-a",
            encryptedPayload: Data([4]),
            wrappedPayloadKey: Data([5]),
            accountWrappedPayloadKey: Data([6]),
            createdAt: createdAt
        )
        try rawStore.save(
            raw,
            at: PlanCloudRawSensorBackupPath(monthKey: raw.monthKey)
        )
        let rawDirectory = snapshotDirectory.appendingPathComponent(
            "Raw Sensors"
        )
        try Data("truncated".utf8).write(
            to: rawDirectory.appendingPathComponent(
                "2026-09.rawsensorbackup"
            )
        )

        XCTAssertEqual(try snapshotStore.allArchives(), [snapshot])
        XCTAssertEqual(
            try rawStore.load(monthKey: raw.monthKey, generationID: nil),
            raw
        )
        XCTAssertThrowsError(try rawStore.allArchives()) { error in
            XCTAssertEqual(error as? PlanSecurityError, .invalidArchive)
        }

        try snapshotStore.delete(
            at: PlanCloudBackupPath(monthKey: snapshot.monthKey)
        )
        try rawStore.delete(
            at: PlanCloudRawSensorBackupPath(monthKey: raw.monthKey)
        )
        XCTAssertThrowsError(try snapshotStore.allArchives()) { error in
            XCTAssertEqual(error as? PlanSecurityError, .invalidArchive)
        }
        XCTAssertThrowsError(try rawStore.allArchives()) { error in
            XCTAssertEqual(error as? PlanSecurityError, .invalidArchive)
        }
    }

    func testRawSensorRestoreChecksCancellationBetweenFileChunks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-restore-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FilePlanCloudRawSensorBackupStore(root: root)
        let monthKey = "2026-08"
        let generationID = UUID()
        let archive = PlanRawSensorMonthlyArchive(
            monthKey: monthKey,
            accountIdentifier: "account-a",
            encryptedPayload: Data(repeating: 7, count: 4 * 1_024 * 1_024),
            wrappedPayloadKey: Data([1]),
            accountWrappedPayloadKey: Data([2]),
            createdAt: Date(timeIntervalSince1970: 1_789_530_000),
            generationID: generationID
        )
        try store.save(
            archive,
            at: PlanCloudRawSensorBackupPath(
                monthKey: monthKey,
                generationID: generationID
            )
        )
        let restored = try await store.loadForRestore(
            monthKey: monthKey,
            generationID: generationID
        )
        XCTAssertEqual(restored, archive)
        let probe = RestoreCancellationProbe(cancellationCheckCount: 3)

        do {
            _ = try await store.loadForRestore(
                monthKey: monthKey,
                generationID: generationID,
                cancellationCheck: { try probe.check() }
            )
            XCTFail("Restore should stop before reading the full archive")
        } catch is CancellationError {
        }

        XCTAssertEqual(probe.checkCount, 3)
    }

    func testRawSensorArchiveDecoderChecksCancellationInsidePayload() throws {
        let archive = PlanRawSensorMonthlyArchive(
            monthKey: "2026-08",
            accountIdentifier: "account-a",
            encryptedPayload: Data(repeating: 9, count: 2 * 1_024 * 1_024),
            wrappedPayloadKey: Data([1]),
            accountWrappedPayloadKey: Data([2]),
            generationID: UUID()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(archive)
        let probe = RestoreCancellationProbe(cancellationCheckCount: 15)

        XCTAssertThrowsError(
            try PlanRawSensorMonthlyArchive.decodeForRestore(
                data,
                cancellationCheck: { try probe.check() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.checkCount, 15)
    }

    func testRawSensorArchiveDecoderChecksCancellationInsideUnknownBooleanArray()
        throws {
        let archive = PlanRawSensorMonthlyArchive(
            monthKey: "2026-08",
            accountIdentifier: "account-a",
            encryptedPayload: Data([9]),
            wrappedPayloadKey: Data([1]),
            accountWrappedPayloadKey: Data([2]),
            generationID: UUID()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(archive))
                as? [String: Any]
        )
        object["zzFutureMetadata"] = [Bool](repeating: true, count: 250_000)
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        let probe = RestoreCancellationProbe(cancellationCheckCount: 40)

        XCTAssertThrowsError(
            try PlanRawSensorMonthlyArchive.decodeForRestore(
                data,
                cancellationCheck: { try probe.check() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.checkCount, 40)
    }

    func testRawSensorPayloadDecodePropagatesCancellationBetweenStages()
        async throws {
        let service = makeService(
            rawSensorBackupStore: InMemoryPlanCloudRawSensorBackupStore(),
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 20,
            horizontalAccuracy: 8,
            verticalAccuracy: 10
        )
        let archive = try await service.saveRawSensorArchive(
            PlanCloudRawSensorPayload(
                monthKey: "2026-08",
                sensorReadings: [SensorReading(
                    timestamp: date,
                    point: point,
                    sourceDevice: .iPhone
                )],
                createdAt: date
            ),
            date: date
        )

        for checkpoint in [5, 6, 7] {
            let probe = RestoreCancellationProbe(
                cancellationCheckCount: checkpoint
            )
            do {
                _ = try archive.decodedPayload(
                    accountKeyData: Data(repeating: 9, count: 32),
                    cancellationCheck: { try probe.check() }
                )
                XCTFail("Decode must stop at cancellation checkpoint \(checkpoint)")
            } catch is CancellationError {
            }
            XCTAssertEqual(probe.checkCount, checkpoint)
        }
    }

    func testRawSensorArchiveDecoderAcceptsEscapedBase64Slashes() throws {
        let archive = PlanRawSensorMonthlyArchive(
            monthKey: "2026-08",
            accountIdentifier: "account-a",
            encryptedPayload: Data([0xFF, 0xFF]),
            wrappedPayloadKey: Data([1]),
            accountWrappedPayloadKey: Data([2])
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(archive)

        let restored = try PlanRawSensorMonthlyArchive.decodeForRestore(
            data,
            cancellationCheck: {}
        )

        XCTAssertEqual(restored.encryptedPayload, Data([0xFF, 0xFF]))
    }

    func testFileBackupSkipsOversizedArchiveBeforeReadingIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-size-limit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FilePlanCloudBackupStore(root: root)
        let createdAt = Date(timeIntervalSince1970: 1_787_538_400)
        let valid = PlanMonthlyArchive(
            monthKey: "2026-08",
            accountIdentifier: "account-a",
            encryptedPayload: Data([1]),
            wrappedPayloadKey: Data([2]),
            accountWrappedPayloadKey: Data([3]),
            createdAt: createdAt
        )
        try store.save(valid, at: PlanCloudBackupPath(monthKey: valid.monthKey))

        let oversized = root
            .appendingPathComponent("Taption Plan", isDirectory: true)
            .appendingPathComponent("2026-09.taptionbackup")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        handle.seek(toFileOffset: UInt64(512 * 1_024 * 1_024 + 1))
        try handle.write(contentsOf: Data([0]))
        try handle.close()

        XCTAssertEqual(try store.allArchives(), [valid])
    }

    func testFileBackupSeparatesUnavailableFilesFromCorruption() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-unavailable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshotStore = FilePlanCloudBackupStore(root: root)
        let snapshot = PlanMonthlyArchive(
            monthKey: "2026-08",
            accountIdentifier: "account-a",
            encryptedPayload: Data([1]),
            wrappedPayloadKey: Data([2]),
            accountWrappedPayloadKey: Data([3]),
            createdAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        try snapshotStore.save(
            snapshot,
            at: PlanCloudBackupPath(monthKey: snapshot.monthKey)
        )
        let snapshotDirectory = root.appendingPathComponent("Taption Plan")
        try FileManager.default.createSymbolicLink(
            at: snapshotDirectory.appendingPathComponent(
                "2026-09.taptionbackup"
            ),
            withDestinationURL: snapshotDirectory.appendingPathComponent(
                "not-downloaded.taptionbackup"
            )
        )

        XCTAssertThrowsError(try snapshotStore.allArchives()) { error in
            XCTAssertEqual(error as? PlanSecurityError, .accountUnavailable)
        }

        let rawStore = FilePlanCloudRawSensorBackupStore(root: root)
        let raw = PlanRawSensorMonthlyArchive(
            monthKey: "2026-08",
            accountIdentifier: "account-a",
            encryptedPayload: Data([4]),
            wrappedPayloadKey: Data([5]),
            accountWrappedPayloadKey: Data([6]),
            createdAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        try rawStore.save(
            raw,
            at: PlanCloudRawSensorBackupPath(monthKey: raw.monthKey)
        )
        let rawDirectory = snapshotDirectory.appendingPathComponent(
            "Raw Sensors"
        )
        try FileManager.default.createSymbolicLink(
            at: rawDirectory.appendingPathComponent(
                "2026-09.rawsensorbackup"
            ),
            withDestinationURL: rawDirectory.appendingPathComponent(
                "not-downloaded.rawsensorbackup"
            )
        )

        XCTAssertThrowsError(try rawStore.allArchives()) { error in
            XCTAssertEqual(error as? PlanSecurityError, .accountUnavailable)
        }
    }

    func testMonthlyGenerationRecordsSuccessOnlyAfterRawArchiveCompletes() async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawStore = FailOncePlanCloudRawSensorBackupStore()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let reading = SensorReading(
            timestamp: date,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 20,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            ),
            sourceDevice: .iPhone
        )
        let rawPayload = PlanCloudRawSensorPayload(
            monthKey: "2026-08",
            sensorReadings: [reading],
            envelopes: [],
            createdAt: date
        )

        do {
            _ = try await service.saveMonthlyGeneration(
                PlanCloudBackupPayload(snapshot: .empty),
                rawSensorPayload: rawPayload,
                date: date
            )
            XCTFail("Injected raw archive failure must fail the generation")
        } catch {
            XCTAssertEqual(error as? BackupStoreTestError, .injected)
        }
        XCTAssertTrue(backupStore.archives.isEmpty)
        XCTAssertTrue(rawStore.archives.isEmpty)
        XCTAssertNil(service.status.latestSuccessfulBackupDate)

        let generation = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: rawPayload,
            date: date
        )

        XCTAssertEqual(generation.snapshot.monthKey, "2026-08")
        let rawGeneration = try XCTUnwrap(generation.rawSensors)
        XCTAssertEqual(rawGeneration.monthKey, "2026-08")
        XCTAssertEqual(
            try XCTUnwrap(generation.snapshot.generationID),
            generation.generationID
        )
        XCTAssertEqual(
            try XCTUnwrap(rawGeneration.generationID),
            generation.generationID
        )
        XCTAssertEqual(Array(rawStore.archives.keys), ["2026-08"])
        XCTAssertEqual(service.status.latestSuccessfulBackupDate, date)

        let lightweight = try await service.saveMonthlyArchive(
            PlanCloudBackupPayload(snapshot: .empty),
            date: date.addingTimeInterval(60)
        )
        XCTAssertEqual(lightweight.generationID, generation.generationID)
        guard case let .available(restored) = try await service
            .loadLatestBackupPackage().rawSensorState else {
            return XCTFail("Snapshot-only backup must preserve committed raw data")
        }
        XCTAssertEqual(restored.sensorReadings.map(\.id), [reading.id])
    }

    func testCancelledMonthlyGenerationRemovesStagedRawArchive() async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawStore = CancelsCurrentTaskAfterRawArchiveSave()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let reading = SensorReading(
            timestamp: date,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 20,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            ),
            sourceDevice: .iPhone
        )

        do {
            _ = try await service.saveMonthlyGeneration(
                PlanCloudBackupPayload(snapshot: .empty),
                rawSensorPayload: PlanCloudRawSensorPayload(
                    monthKey: "2026-08",
                    sensorReadings: [reading],
                    envelopes: [],
                    createdAt: date
                ),
                date: date
            )
            XCTFail("Cancellation before snapshot commit must abort the generation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertTrue(backupStore.archives.isEmpty)
        XCTAssertTrue(try rawStore.allArchives().isEmpty)
        XCTAssertNil(service.status.latestSuccessfulBackupDate)
    }

    func testCancelledLegacyRawArchiveSavePreservesMergedReadings() async throws {
        let rawStore = CancelsCurrentTaskAfterRawArchiveSave(
            cancelAfterSaveNumber: 2
        )
        let service = makeService(
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)

        func makeReading(_ offset: TimeInterval) -> SensorReading {
            SensorReading(
                timestamp: date.addingTimeInterval(offset),
                point: GeoPoint(
                    latitude: 37.5,
                    longitude: 126.9,
                    altitude: 20,
                    horizontalAccuracy: 8,
                    verticalAccuracy: 10
                ),
                sourceDevice: .iPhone
            )
        }

        let first = makeReading(0)
        let second = makeReading(60)
        _ = try await service.saveRawSensorArchive(
            PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [first],
                createdAt: date
            ),
            date: date
        )
        let cancelledSave = Task {
            try await service.saveRawSensorArchive(
                PlanCloudRawSensorPayload(
                    monthKey: "ignored",
                    sensorReadings: [second],
                    createdAt: date.addingTimeInterval(60)
                ),
                date: date
            )
        }

        do {
            _ = try await cancelledSave.value
            XCTFail("A cancelled legacy write must report cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let monthKey = PlanArchiveSchedule.monthKey(for: date)
        guard let archive = try rawStore.load(
            monthKey: monthKey,
            generationID: nil
        ) else {
            return XCTFail("Cancellation must not remove the legacy archive")
        }
        let restored = try archive.decodedPayload(
            accountKeyData: Data(repeating: 9, count: 32)
        )
        XCTAssertEqual(Set(restored.sensorReadings.map(\.id)), Set([first.id, second.id]))
    }

    func testCommittedSnapshotKeepsRawGenerationWhenRollbackSaveFails()
        async throws {
        let backupStore = CommitThenCancelAndFailRollbackBackupStore(
            cancelAfterSaveNumber: 2,
            failSaveNumber: 3
        )
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 20,
            horizontalAccuracy: 8,
            verticalAccuracy: 10
        )
        let first = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "2026-08",
                sensorReadings: [SensorReading(timestamp: date, point: point)],
                createdAt: date
            ),
            date: date
        )

        do {
            _ = try await service.saveMonthlyGeneration(
                PlanCloudBackupPayload(snapshot: .empty),
                rawSensorPayload: PlanCloudRawSensorPayload(
                    monthKey: "2026-08",
                    sensorReadings: [SensorReading(
                        timestamp: date.addingTimeInterval(60),
                        point: point
                    )],
                    createdAt: date.addingTimeInterval(60)
                ),
                date: date.addingTimeInterval(60)
            )
            XCTFail("Cancellation after commit must not report success")
        } catch is CancellationError {
            // The new snapshot is durable; failed rollback must retain its raw generation.
        }

        let snapshot = try XCTUnwrap(backupStore.latest())
        let generationID = try XCTUnwrap(snapshot.generationID)
        XCTAssertNotEqual(generationID, first.generationID)
        XCTAssertEqual(snapshot.hasRawSensorArchive, true)
        XCTAssertEqual(service.status.latestSuccessfulBackupDate, date)
        let raw = try XCTUnwrap(
            try rawStore.load(
                monthKey: snapshot.monthKey,
                generationID: generationID
            )
        )
        XCTAssertEqual(raw.generationID, generationID)
    }

    func testCommittedRawGenerationSurvivesSnapshotReadbackFailure()
        async throws {
        let backupStore = CommitThenCancelAndFailRollbackBackupStore(
            cancelAfterSaveNumber: 2,
            failReadbackAfterSaveNumber: 2
        )
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 20,
            horizontalAccuracy: 8,
            verticalAccuracy: 10
        )
        let first = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "2026-08",
                sensorReadings: [SensorReading(timestamp: date, point: point)],
                createdAt: date
            ),
            date: date
        )

        do {
            _ = try await service.saveMonthlyGeneration(
                PlanCloudBackupPayload(snapshot: .empty),
                rawSensorPayload: PlanCloudRawSensorPayload(
                    monthKey: "2026-08",
                    sensorReadings: [SensorReading(
                        timestamp: date.addingTimeInterval(60),
                        point: point
                    )],
                    createdAt: date.addingTimeInterval(60)
                ),
                date: date.addingTimeInterval(60)
            )
            XCTFail("Cancellation after commit must not report success")
        } catch is CancellationError {
            // Failed snapshot readback must not cause deletion of staged raw data.
        }

        let snapshot = try XCTUnwrap(backupStore.latest())
        let generationID = try XCTUnwrap(snapshot.generationID)
        XCTAssertNotEqual(generationID, first.generationID)
        let raw = try XCTUnwrap(
            try rawStore.load(
                monthKey: snapshot.monthKey,
                generationID: generationID
            )
        )
        XCTAssertEqual(raw.generationID, generationID)
    }

    func testMonthlyGenerationStopsBeforeRawWriteAfterDeletionFenceAdvances()
        async throws {
        let state = BackupDeletionFenceTestState()
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawStore = DeletionFenceTestRawSensorBackupStore(
            state: state,
            advanceOnLoad: true
        )
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        defer {
            if let generation = state.advancedGeneration {
                TaptionDataDeletionFence.finish(generation: generation)
            }
        }
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let reading = SensorReading(
            timestamp: date,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 20,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            )
        )

        do {
            _ = try await service.saveMonthlyGeneration(
                PlanCloudBackupPayload(snapshot: .empty),
                rawSensorPayload: PlanCloudRawSensorPayload(
                    monthKey: "ignored",
                    sensorReadings: [reading],
                    createdAt: date
                ),
                date: date
            )
            XCTFail("A stale deletion generation must not write raw data")
        } catch is CancellationError {
        }

        XCTAssertEqual(rawStore.saveCount, 0)
        XCTAssertTrue(try rawStore.allArchives().isEmpty)
        XCTAssertTrue(backupStore.archives.isEmpty)
        XCTAssertNil(service.status.latestSuccessfulBackupDate)
    }

    func testAsyncRawArchiveRemovesWriteWhenDeletionFenceAdvancesDuringSave()
        async throws {
        let state = BackupDeletionFenceTestState()
        let rawStore = DeletionFenceTestRawSensorBackupStore(
            state: state,
            advanceAfterSave: true
        )
        let service = makeService(
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        defer {
            if let generation = state.advancedGeneration {
                TaptionDataDeletionFence.finish(generation: generation)
            }
        }
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let reading = SensorReading(
            timestamp: date,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 20,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            )
        )

        do {
            _ = try await service.saveRawSensorArchive(
                PlanCloudRawSensorPayload(
                    monthKey: "ignored",
                    sensorReadings: [reading],
                    createdAt: date
                ),
                date: date
            )
            XCTFail("A raw write crossing deletion must be cancelled")
        } catch is CancellationError {
        }

        XCTAssertEqual(rawStore.saveCount, 1)
        XCTAssertTrue(try rawStore.allArchives().isEmpty)
    }

    func testMonthlyGenerationRejectsDeletionAtSnapshotCommitBoundary()
        async throws {
        let state = BackupDeletionFenceTestState()
        let backupStore = DeletionFenceTestBackupStore(
            state: state,
            advanceAfterRawWriteOnRead: 2
        )
        let rawStore = DeletionFenceTestRawSensorBackupStore(state: state)
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        defer {
            if let generation = state.advancedGeneration {
                TaptionDataDeletionFence.finish(generation: generation)
            }
        }
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let reading = SensorReading(
            timestamp: date,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 20,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            )
        )

        do {
            _ = try await service.saveMonthlyGeneration(
                PlanCloudBackupPayload(snapshot: .empty),
                rawSensorPayload: PlanCloudRawSensorPayload(
                    monthKey: "ignored",
                    sensorReadings: [reading],
                    createdAt: date
                ),
                date: date
            )
            XCTFail("A stale deletion generation must not commit a snapshot")
        } catch is CancellationError {
        }

        XCTAssertEqual(state.snapshotReadsAfterRawWrite, 2)
        XCTAssertEqual(backupStore.saveCount, 0)
        XCTAssertTrue(try rawStore.allArchives().isEmpty)
        XCTAssertNil(service.status.latestSuccessfulBackupDate)
    }

    func testSnapshotWriteIsRemovedWhenDeletionFenceAdvancesDuringSave()
        async throws {
        let state = BackupDeletionFenceTestState()
        let backupStore = DeletionFenceTestBackupStore(
            state: state,
            advanceAfterRawWriteOnRead: .max,
            advanceOnSave: true
        )
        let rawStore = DeletionFenceTestRawSensorBackupStore(state: state)
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        defer {
            if let generation = state.advancedGeneration {
                TaptionDataDeletionFence.finish(generation: generation)
            }
        }

        do {
            _ = try await service.saveMonthlyGeneration(
                PlanCloudBackupPayload(snapshot: .empty),
                rawSensorPayload: nil,
                date: Date(timeIntervalSince1970: 1_787_538_400)
            )
            XCTFail("A snapshot crossing deletion must not remain committed")
        } catch is CancellationError {
        }

        XCTAssertEqual(backupStore.saveCount, 1)
        XCTAssertTrue(backupStore.archives.isEmpty)
        XCTAssertTrue(try rawStore.allArchives().isEmpty)
        XCTAssertNil(service.status.latestSuccessfulBackupDate)
    }

    func testRollbackDoesNotRestoreSnapshotAfterDeletionFenceAdvances()
        async throws {
        let state = BackupDeletionFenceTestState()
        let backupStore = DeletionFenceTestBackupStore(
            state: state,
            advanceAfterRawWriteOnRead: .max,
            advanceDuringPostSaveRead: true
        )
        let rawStore = DeletionFenceTestRawSensorBackupStore(state: state)
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        defer {
            if let generation = state.advancedGeneration {
                TaptionDataDeletionFence.finish(generation: generation)
            }
        }

        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let accountIdentifier = CloudKitPlanCloudRecoveryKeyProvider
            .privateAccountScope
        _ = try service.saveMonthlyArchive(
            .empty,
            accountIdentifier: accountIdentifier,
            date: date
        )
        state.snapshotArchiveWasWritten = false
        backupStore.onSave = { _ = try? service.setPIN("5678") }

        do {
            _ = try await service.saveMonthlyGeneration(
                PlanCloudBackupPayload(snapshot: .empty),
                rawSensorPayload: nil,
                date: date.addingTimeInterval(60)
            )
            XCTFail("A rollback crossing deletion must not restore an archive")
        } catch is CancellationError {
        }

        XCTAssertNotNil(state.advancedGeneration)
        XCTAssertTrue(backupStore.archives.isEmpty)
        XCTAssertTrue(try rawStore.allArchives().isEmpty)
    }

    func testSnapshotOnlySavePreservesStandaloneRawArchiveWithoutPreviousSnapshot()
        async throws {
        let service = makeService()
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let reading = SensorReading(
            timestamp: date,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 20,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            ),
            sourceDevice: .iPhone
        )

        _ = try service.saveRawSensorArchive(
            PlanCloudRawSensorPayload(
                monthKey: "2026-08",
                sensorReadings: [reading],
                envelopes: [],
                createdAt: date
            ),
            accountIdentifier: "account-a",
            date: date
        )
        let snapshot = try service.saveMonthlyArchive(
            .empty,
            accountIdentifier: "account-a",
            date: date.addingTimeInterval(60)
        )

        XCTAssertEqual(snapshot.hasRawSensorArchive, true)
        guard case let .available(restored) = try await service
            .loadLatestBackupPackage(accountIdentifier: "account-a")
            .rawSensorState else {
            return XCTFail("Snapshot-only save must preserve standalone raw sensor data")
        }
        XCTAssertEqual(restored.sensorReadings.map(\.id), [reading.id])
    }

    func testConsecutiveFullRawBackupsAcceptEquivalentPersistedDates() async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")

        let date = Date(timeIntervalSinceReferenceDate: 811012345.000002)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 20,
            horizontalAccuracy: 8,
            verticalAccuracy: 10
        )
        let reading = SensorReading(timestamp: date, point: point)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let persistedData = try encoder.encode(reading)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let restoredReading = try decoder.decode(
            SensorReading.self,
            from: persistedData
        )

        XCTAssertNotEqual(reading, restoredReading)
        XCTAssertEqual(persistedData, try encoder.encode(restoredReading))

        _ = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [reading],
                createdAt: date
            ),
            date: date
        )
        let second = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [reading],
                createdAt: date.addingTimeInterval(60)
            ),
            date: date.addingTimeInterval(60)
        )

        XCTAssertEqual(rawStore.archives.count, 1)
        guard case let .available(rawSensors) = try await service
            .loadLatestBackupPackage().rawSensorState else {
            return XCTFail("Equivalent raw payload must remain restorable")
        }
        XCTAssertEqual(rawSensors.sensorReadings.map(\.id), [reading.id])
        XCTAssertEqual(second.rawSensors?.monthKey, second.snapshot.monthKey)
    }

    func testCancelledAsyncSnapshotDoesNotCommit() async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let service = makeService(
            backupStore: backupStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")

        let task = Task {
            try await service.saveMonthlyArchive(
                PlanCloudBackupPayload(snapshot: .empty),
                date: Date(timeIntervalSince1970: 1_787_538_400)
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled snapshot must not commit")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(backupStore.archives.isEmpty)
    }

    func testAsyncSnapshotDoesNotOverwriteArchiveChangedDuringPreparation()
        async throws {
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let replacement = PlanMonthlyArchive(
            monthKey: PlanArchiveSchedule.monthKey(for: date),
            accountIdentifier: CloudKitPlanCloudRecoveryKeyProvider
                .privateAccountScope,
            encryptedPayload: Data([1]),
            wrappedPayloadKey: Data([2]),
            accountWrappedPayloadKey: Data([3]),
            createdAt: date
        )
        let backupStore = ArchiveChangesBetweenReadsStore(
            replacement: replacement
        )
        let service = makeService(
            backupStore: backupStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")

        do {
            _ = try await service.saveMonthlyArchive(
                PlanCloudBackupPayload(snapshot: .empty),
                date: date
            )
            XCTFail("A changed prior archive must cancel the commit")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(backupStore.saveCount, 0)
    }

    func testAsyncSnapshotCancelsAfterPINChangesWhileKeyIsGated()
        async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let recoveryKeys = GatedPlanCloudRecoveryKeyProvider()
        let service = makeService(
            backupStore: backupStore,
            cloudRecoveryKeyProvider: recoveryKeys
        )
        try service.setPIN("1234")

        let task = Task {
            try await service.saveMonthlyArchive(
                PlanCloudBackupPayload(snapshot: .empty),
                date: Date(timeIntervalSince1970: 1_787_538_400)
            )
        }
        while !recoveryKeys.keyWasRequested {
            await Task.yield()
        }
        try service.setPIN("5678")
        recoveryKeys.release()

        do {
            _ = try await task.value
            XCTFail("A PIN change during preparation must cancel the commit")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(backupStore.archives.isEmpty)
    }

    func testAsyncSnapshotCannotRecreateDeletedBackups() async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let recoveryKeys = GatedPlanCloudRecoveryKeyProvider()
        let service = makeService(
            backupStore: backupStore,
            cloudRecoveryKeyProvider: recoveryKeys
        )
        try service.setPIN("1234")
        let task = Task {
            try await service.saveMonthlyArchive(
                PlanCloudBackupPayload(snapshot: .empty),
                date: Date(timeIntervalSince1970: 1_787_538_400)
            )
        }
        while !recoveryKeys.keyWasRequested { await Task.yield() }
        try service.deleteAllBackups()
        recoveryKeys.release()
        do {
            _ = try await task.value
            XCTFail("A pending backup must not recreate deleted archives")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(backupStore.archives.isEmpty)
    }

    func testAsyncMonthlyGenerationCannotRecreateDeletedBackups()
        async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let recoveryKeys = GatedPlanCloudRecoveryKeyProvider()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: recoveryKeys
        )
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let payload = PlanCloudRawSensorPayload(
            monthKey: "2026-08",
            sensorReadings: [SensorReading(
                timestamp: date,
                point: GeoPoint(
                    latitude: 37.5,
                    longitude: 126.9,
                    altitude: 20,
                    horizontalAccuracy: 8,
                    verticalAccuracy: 10
                )
            )],
            createdAt: date
        )
        let task = Task {
            try await service.saveMonthlyGeneration(
                PlanCloudBackupPayload(snapshot: .empty),
                rawSensorPayload: payload,
                date: date
            )
        }
        while !recoveryKeys.keyWasRequested { await Task.yield() }
        try service.deleteAllBackups()
        recoveryKeys.release()

        do {
            _ = try await task.value
            XCTFail("A pending generation must not recreate deleted backups")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(backupStore.archives.isEmpty)
        XCTAssertTrue(rawStore.archives.isEmpty)
        XCTAssertNil(service.status.latestSuccessfulBackupDate)
    }

    func testAsyncRawArchiveCannotRecreateDeletedBackups() async throws {
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let recoveryKeys = GatedPlanCloudRecoveryKeyProvider()
        let service = makeService(
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: recoveryKeys
        )
        try service.setPIN("1234")
        let task = Task {
            try await service.saveRawSensorArchive(
                PlanCloudRawSensorPayload(monthKey: "2026-08")
            )
        }
        while !recoveryKeys.keyWasRequested { await Task.yield() }
        try service.deleteAllBackups()
        recoveryKeys.release()

        do {
            _ = try await task.value
            XCTFail("A pending raw archive must not recreate deleted backups")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(rawStore.archives.isEmpty)
    }

    func testAsyncRawArchiveCancelsWhenPINChangesDuringKeyRequest()
        async throws {
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let recoveryKeys = GatedPlanCloudRecoveryKeyProvider()
        let service = makeService(
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: recoveryKeys
        )
        try service.setPIN("1234")
        let task = Task {
            try await service.saveRawSensorArchive(
                PlanCloudRawSensorPayload(monthKey: "2026-08")
            )
        }
        while !recoveryKeys.keyWasRequested { await Task.yield() }
        try service.setPIN("5678")
        recoveryKeys.release()

        do {
            _ = try await task.value
            XCTFail("A raw archive prepared for an old PIN must be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(rawStore.archives.isEmpty)
    }

    func testAsyncCloudLoadCannotResaveBackupAfterDeletion() async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let writer = makeService(
            backupStore: backupStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try writer.setPIN("1234")
        _ = try await writer.saveMonthlyArchive(
            PlanCloudBackupPayload(snapshot: .empty)
        )

        let recoveryKeys = GatedPlanCloudRecoveryKeyProvider()
        let reader = makeService(
            backupStore: backupStore,
            cloudRecoveryKeyProvider: recoveryKeys
        )
        try reader.setPIN("5678")
        let task = Task { try await reader.loadLatestBackup() }
        while !recoveryKeys.keyWasRequested { await Task.yield() }
        try reader.deleteAllBackups()
        recoveryKeys.release()

        do {
            _ = try await task.value
            XCTFail("A cloud load must not recreate a deleted snapshot")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(backupStore.archives.isEmpty)
    }

    func testMonthlyGenerationRestoresRawWhenSnapshotCommitFails()
        async throws {
        let backupStore = FailNextPlanCloudBackupStore()
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        let firstDate = Date(timeIntervalSince1970: 1_787_538_400)
        let first = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: .init(
                monthKey: "ignored",
                sensorReadings: [SensorReading(
                    timestamp: firstDate,
                    point: GeoPoint(
                        latitude: 37.5,
                        longitude: 126.9,
                        altitude: 20,
                        horizontalAccuracy: 8,
                        verticalAccuracy: 10
                    )
                )],
                createdAt: firstDate
            ),
            date: firstDate
        )

        backupStore.failNextSave = true
        let failedDate = firstDate.addingTimeInterval(60)
        do {
            _ = try await service.saveMonthlyGeneration(
                PlanCloudBackupPayload(snapshot: .empty),
                rawSensorPayload: .init(
                    monthKey: "ignored",
                    sensorReadings: [SensorReading(
                        timestamp: failedDate,
                        point: GeoPoint(
                            latitude: 37.6,
                            longitude: 127,
                            altitude: 20,
                            horizontalAccuracy: 8,
                            verticalAccuracy: 10
                        )
                    )],
                    createdAt: failedDate
                ),
                date: failedDate
            )
            XCTFail("Snapshot commit failure must fail the generation")
        } catch {
            XCTAssertEqual(error as? BackupStoreTestError, .injected)
        }

        XCTAssertEqual(
            backupStore.archives["2026-08"]?.generationID,
            first.generationID
        )
        XCTAssertEqual(
            rawStore.archives["2026-08"]?.generationID,
            first.generationID
        )
        XCTAssertEqual(service.status.latestSuccessfulBackupDate, firstDate)
        let restored = try await service.loadLatestBackupPackage()
        guard case let .available(raw) = restored.rawSensorState else {
            return XCTFail("Snapshot failure must restore the previous raw archive")
        }
        XCTAssertEqual(raw.sensorReadings.count, 1)
        XCTAssertEqual(raw.sensorReadings.first?.timestamp, firstDate)
    }

    func testBiometricGateUnlocksWithoutExposingRawBiometric() async throws {
        let biometric = MockPlanLocalBiometricAuthenticator(result: true)
        let service = makeService(biometric: biometric)
        try service.setPIN("1234")
        try service.setAppLockSettings(.init(lockOnLaunch: true, lockOnForeground: false, biometricUnlockEnabled: true))
        service.handleLaunch()
        XCTAssertTrue(service.status.state != .unlocked)
        try await service.unlockWithBiometrics()
        XCTAssertEqual(service.status.state, .unlocked)
    }

    func testDisabledBiometricFallsBackToPINWhileLocked() async throws {
        let service = makeService(
            biometric: MockPlanLocalBiometricAuthenticator(result: true)
        )
        try service.setPIN("1234")
        try service.setAppLockSettings(
            .init(lockOnLaunch: true, lockOnForeground: false, biometricUnlockEnabled: false)
        )
        service.handleLaunch()

        do {
            try await service.unlockWithBiometrics()
            XCTFail("Disabled biometrics must not unlock the app")
        } catch {
            XCTAssertEqual(error as? PlanSecurityError, .biometricUnavailable)
        }
        XCTAssertNotEqual(service.status.state, .unlocked)

        try service.unlock(withPIN: "1234")
        XCTAssertEqual(service.status.state, .unlocked)
    }

    func testSameAccountRecoversWithNewPINAndDifferentAccountIsRejected() throws {
        let service = makeService()
        try service.setPIN("1234")
        _ = try service.saveMonthlyArchive(.empty, accountIdentifier: "account-a")
        let recovered = try service.recoverLatestArchive(accountIdentifier: "account-a", newPIN: "9876")
        assertEmptySnapshot(recovered)
        XCTAssertTrue(service.hasPIN)
        XCTAssertThrowsError(try service.recoverLatestArchive(accountIdentifier: "account-b", newPIN: "1111")) { error in
            XCTAssertEqual(error as? PlanSecurityError, .accountMismatch)
        }
    }

    func testMonthlyArchivePathAndCatchUpMonths() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(
            year: 2025, month: 7, day: 1
        ))!
        let end = calendar.date(from: DateComponents(
            year: 2025, month: 10, day: 1
        ))!
        XCTAssertEqual(
            PlanCloudBackupPath(monthKey: "2025-08").relativePath,
            "iCloud Drive/Taption Plan/2025-08.taptionbackup"
        )
        XCTAssertEqual(
            PlanCloudRawSensorBackupPath(monthKey: "2025-08").relativePath,
            "iCloud Drive/Taption Plan/Raw Sensors/2025-08.rawsensorbackup"
        )
        XCTAssertEqual(PlanArchiveSchedule.monthsBetween(start, end, calendar: calendar), ["2025-07", "2025-08", "2025-09", "2025-10"])
    }

    func testRawSensorArchiveKeepsLocationWeatherAndWatchAcceleration()
        async throws {
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let recoveryKeys = InMemoryPlanCloudRecoveryKeyProvider()
        let service = makeService(
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: recoveryKeys
        )
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let reading = SensorReading(
            timestamp: date,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 20,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            ),
            stepCount: 8_000,
            sourceDevice: .iPhone
        )
        let watchReading = SensorReading(
            timestamp: date.addingTimeInterval(1),
            point: reading.point,
            sourceDevice: .appleWatch
        )
        let weatherContext = WeatherContext(
            observedAt: date,
            condition: "Clear",
            symbolName: "sun.max.fill",
            temperatureCelsius: 21,
            point: reading.point
        )
        let weather = try RawDeviceDataEnvelope(
            capturedAt: date,
            source: .gps,
            kind: "weather-context",
            payload: weatherContext
        )
        let mislabeled = try RawDeviceDataEnvelope(
            capturedAt: date,
            source: .gps,
            kind: "weather-context",
            payload: ["sleepMinutes": 420]
        )
        let motion = try RawDeviceDataEnvelope(
            capturedAt: date,
            source: .iPhoneMotion,
            kind: "motion-activities",
            payload: ["state": "walking"]
        )
        let health = try RawDeviceDataEnvelope(
            capturedAt: date,
            source: .healthKit,
            kind: "sleep-sessions",
            payload: ["state": "asleep"]
        )
        let watchHealth = try RawDeviceDataEnvelope(
            capturedAt: date,
            source: .appleWatch,
            kind: "watch-health-snapshot",
            payload: ["heartRate": "72"]
        )
        let sessionID = UUID()
        let sample = TaptionWatchAccelerationSample(
            capturedAt: date,
            acceleration: TaptionWatchSensorVector3(x: 0, y: 0, z: 1),
            sessionID: sessionID,
            sequence: 1,
            isAmbient: false
        )
        let chunk = TaptionWatchAccelerationChunk(
            sessionID: sessionID,
            sequence: 1,
            startedAt: date,
            endedAt: date,
            samples: [sample]
        )
        let archive = try await service.saveRawSensorArchive(
            PlanCloudRawSensorPayload(
                monthKey: "2026-08",
                sensorReadings: [reading, watchReading],
                envelopes: [weather, mislabeled, motion, health, watchHealth],
                watchAccelerationChunks: [chunk],
                createdAt: date
            ),
            date: date
        )

        XCTAssertEqual(
            Array(rawStore.archives.keys),
            ["2026-08"]
        )
        XCTAssertNil(
            archive.encryptedPayload.range(
                of: Data("motion-activities".utf8)
            )
        )
        let decoded = try archive.decodedPayload(
            accountKeyData: Data(repeating: 9, count: 32)
        )
        XCTAssertEqual(decoded.sensorReadings.map(\.id), [reading.id])
        XCTAssertNil(decoded.sensorReadings.first?.stepCount)
        XCTAssertEqual(decoded.envelopes.map(\.id), [weather.id])
        XCTAssertEqual(decoded.watchAccelerationChunks, [chunk])
    }

    func testRawCloudExportCompactsWeatherToDisplayedTransitions() throws {
        let start = Date(timeIntervalSince1970: 1_787_538_400)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5
        )
        let first = WeatherContext(
            observedAt: start,
            fetchedAt: start,
            isForecast: true,
            condition: "이전 예보",
            symbolName: "cloud.rain.fill",
            temperatureCelsius: 20.1,
            point: point
        )
        let repeated = WeatherContext(
            observedAt: start,
            fetchedAt: start.addingTimeInterval(60 * 60),
            isForecast: true,
            condition: "Clear",
            symbolName: "sun.max.fill",
            temperatureCelsius: 20.4,
            point: point
        )
        let changed = WeatherContext(
            observedAt: start.addingTimeInterval(2 * 60 * 60),
            isForecast: true,
            condition: "흐림",
            symbolName: "cloud.fill",
            temperatureCelsius: 20.4,
            point: point
        )
        let sameLater = WeatherContext(
            observedAt: start.addingTimeInterval(60 * 60),
            fetchedAt: start.addingTimeInterval(60 * 60),
            isForecast: true,
            condition: "Clear",
            symbolName: "sun.max.fill",
            temperatureCelsius: 20.4,
            point: GeoPoint(
                latitude: 37.6,
                longitude: 127.1,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let contexts = [first, repeated, sameLater, changed]
        let envelopes = try contexts.map {
            try RawDeviceDataEnvelope(
                capturedAt: $0.observedAt,
                source: .gps,
                kind: "weather-forecast-hourly",
                payload: $0
            )
        }

        let payload = PlanCloudRawSensorPayload(
            monthKey: "2026-08",
            envelopes: envelopes
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let exported = try payload.envelopes.map {
            try decoder.decode(
                WeatherContext.self,
                from: Data($0.payloadJSON.utf8)
            )
        }

        XCTAssertEqual(exported.map(\.id), [repeated.id, changed.id])
    }

    func testRawCompressionUsesBoundedSeparateLimitAndCheckedDiagnostics() throws {
        let knownArchiveSize = 146_067_067
        XCTAssertEqual(
            TaptionSnapshotCompression.maximumUncompressedSize,
            64 * 1_024 * 1_024
        )
        XCTAssertGreaterThan(
            TaptionSnapshotCompression.maximumRawSensorUncompressedSize,
            knownArchiveSize
        )
        XCTAssertGreaterThan(
            knownArchiveSize,
            TaptionSnapshotCompression.maximumUncompressedSize
        )

        var oversized = Data([0x54, 0x50, 0x5A, 0x31])
        let size = UInt64(
            TaptionSnapshotCompression.maximumRawSensorUncompressedSize + 1
        )
        for shift in stride(from: 0, to: 64, by: 8) {
            oversized.append(UInt8((size >> UInt64(shift)) & 0xFF))
        }
        oversized.append(0)

        XCTAssertThrowsError(
            try TaptionSnapshotCompression.decodeChecked(
                oversized,
                maximumSize: TaptionSnapshotCompression
                    .maximumRawSensorUncompressedSize
            )
        ) { error in
            XCTAssertEqual(
                error as? TaptionSnapshotCompressionError,
                .uncompressedSizeExceedsLimit(
                    actual: size,
                    maximum: TaptionSnapshotCompression
                        .maximumRawSensorUncompressedSize
                )
            )
        }
        XCTAssertEqual(TaptionSnapshotCompression.decode(oversized), oversized)
    }

    func testBackupPackageCombinesRawSensorArchivesAcrossMonths() async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        let july = Date(timeIntervalSince1970: 1_775_000_000)
        let august = Date(timeIntervalSince1970: 1_777_700_000)
        let julyReading = SensorReading(
            timestamp: july,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 20,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            )
        )
        let augustReading = SensorReading(
            timestamp: august,
            point: GeoPoint(
                latitude: 37.6,
                longitude: 127,
                altitude: 20,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            )
        )
        let envelope = try RawDeviceDataEnvelope(
            capturedAt: july,
            source: .iPhoneMotion,
            kind: "motion-activities",
            payload: ["state": "walking"]
        )
        _ = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "2026-04",
                sensorReadings: [julyReading],
                envelopes: [envelope],
                createdAt: july
            ),
            date: july
        )
        _ = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "2026-05",
                sensorReadings: [augustReading],
                createdAt: august
            ),
            date: august
        )

        let restored = try await service.loadLatestBackupPackage()
        guard case .available(let rawSensors) = restored.rawSensorState else {
            return XCTFail("Raw sensor archives must be restorable")
        }
        XCTAssertEqual(
            rawSensors.sensorReadings.map(\.id),
            [julyReading.id, augustReading.id]
        )
        XCTAssertTrue(rawSensors.envelopes.isEmpty)
    }

    func testLegacyRawRestoreIgnoresGenerationCountAndCapsLegacyFiles()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-raw-without-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let backupStore = FilePlanCloudBackupStore(root: root)
        let rawStore = FilePlanCloudRawSensorBackupStore(root: root)
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let july = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 15)
        )!
        let august = calendar.date(byAdding: .month, value: 1, to: july)!
        _ = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: nil,
            date: july
        )
        let reading = SensorReading(
            timestamp: august,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 20,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            )
        )
        let legacyArchive = try service.saveRawSensorArchive(
            PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [reading],
                createdAt: august
            ),
            accountIdentifier: CloudKitPlanCloudRecoveryKeyProvider
                .privateAccountScope,
            date: august
        )
        XCTAssertNil(legacyArchive.generationID)
        for _ in 0..<120 {
            let generationID = UUID()
            let orphan = PlanRawSensorMonthlyArchive(
                monthKey: "2026-01",
                accountIdentifier: CloudKitPlanCloudRecoveryKeyProvider
                    .privateAccountScope,
                encryptedPayload: Data([1]),
                wrappedPayloadKey: Data([2]),
                accountWrappedPayloadKey: Data([3]),
                generationID: generationID
            )
            try rawStore.save(
                orphan,
                at: PlanCloudRawSensorBackupPath(
                    monthKey: orphan.monthKey,
                    generationID: generationID
                )
            )
        }
        XCTAssertEqual(
            try rawStore.legacyArchiveMonthKeys(),
            ["2026-08"]
        )

        let restored = try await service.loadLatestBackupPackage()
        guard case let .available(rawSensors) = restored.rawSensorState else {
            return XCTFail("A legacy raw month without a snapshot must restore")
        }
        XCTAssertEqual(rawSensors.sensorReadings.map(\.id), [reading.id])

        for index in 0..<120 {
            let year = 2000 + index / 12
            let month = index % 12 + 1
            let monthKey = "\(year)-\(month < 10 ? "0" : "")\(month)"
            let legacy = PlanRawSensorMonthlyArchive(
                monthKey: monthKey,
                accountIdentifier: CloudKitPlanCloudRecoveryKeyProvider
                    .privateAccountScope,
                encryptedPayload: Data([1]),
                wrappedPayloadKey: Data([2]),
                accountWrappedPayloadKey: Data([3])
            )
            try rawStore.save(
                legacy,
                at: PlanCloudRawSensorBackupPath(monthKey: monthKey)
            )
        }
        XCTAssertThrowsError(try rawStore.legacyArchiveMonthKeys()) {
            XCTAssertEqual($0 as? PlanSecurityError, .invalidArchive)
        }
    }

    func testRestoreDoesNotAssociateStaleLegacyRawWithSnapshotOnlyGeneration()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-legacy-raw-snapshot-only-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let backupStore = FilePlanCloudBackupStore(root: root)
        let rawStore = FilePlanCloudRawSensorBackupStore(root: root)
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_782_000_000)
        let snapshot = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: nil,
            date: date
        )
        XCTAssertFalse(snapshot.snapshot.hasRawSensorArchive ?? true)
        let expectedSnapshot = try await service.loadLatestBackup().snapshot

        let staleReading = SensorReading(
            timestamp: date,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 20,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            )
        )
        let legacyArchive = try service.saveRawSensorArchive(
            PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [staleReading],
                createdAt: date
            ),
            accountIdentifier: CloudKitPlanCloudRecoveryKeyProvider
                .privateAccountScope,
            date: date
        )
        XCTAssertNil(legacyArchive.generationID)

        let restored = try await service.loadLatestBackupPackage()
        XCTAssertEqual(restored.backup.snapshot, expectedSnapshot)
        XCTAssertEqual(restored.rawSensorState, .unavailable)
    }

    func testRawBackupRejectsConflictingPayloadForTheSameID() throws {
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let service = makeService(rawSensorBackupStore: rawStore)
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_777_700_000)
        let id = UUID()
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 20,
            horizontalAccuracy: 8,
            verticalAccuracy: 10
        )
        let original = SensorReading(id: id, timestamp: date, point: point)
        let conflicting = SensorReading(
            id: id,
            timestamp: date.addingTimeInterval(1),
            point: point
        )
        _ = try service.saveRawSensorArchive(
            PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [original],
                createdAt: date
            ),
            accountIdentifier: "account-a",
            date: date
        )

        XCTAssertThrowsError(
            try service.saveRawSensorArchive(
                PlanCloudRawSensorPayload(
                    monthKey: "ignored",
                    sensorReadings: [conflicting],
                    createdAt: date
                ),
                accountIdentifier: "account-a",
                date: date
            )
        ) { error in
            XCTAssertEqual(error as? PlanSecurityError, .invalidArchive)
        }
    }

    func testRawRestoreRejectsConflictingIDsAcrossMonths() async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        let july = Date(timeIntervalSince1970: 1_775_000_000)
        let august = Date(timeIntervalSince1970: 1_777_700_000)
        let id = UUID()
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 20,
            horizontalAccuracy: 8,
            verticalAccuracy: 10
        )
        _ = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [SensorReading(
                    id: id,
                    timestamp: july,
                    point: point
                )],
                createdAt: july
            ),
            date: july
        )
        _ = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [SensorReading(
                    id: id,
                    timestamp: august,
                    point: point
                )],
                createdAt: august
            ),
            date: august
        )

        let restored = try await service.loadLatestBackupPackage()
        XCTAssertEqual(restored.rawSensorState, .invalidArchive)
    }

    func testBackupPackageReportsCorruptedRawArchiveSeparately() async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 20,
            horizontalAccuracy: 8,
            verticalAccuracy: 10
        )
        let generation = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [SensorReading(timestamp: date, point: point)],
                createdAt: date
            ),
            date: date
        )
        let committedRaw = try XCTUnwrap(generation.rawSensors)
        let corrupted = PlanRawSensorMonthlyArchive(
            monthKey: generation.snapshot.monthKey,
            accountIdentifier: committedRaw.accountIdentifier,
            encryptedPayload: Data([0x01]),
            wrappedPayloadKey: Data([0x02]),
            accountWrappedPayloadKey: Data(),
            createdAt: date,
            generationID: generation.generationID
        )
        try rawStore.save(
            corrupted,
            at: PlanCloudRawSensorBackupPath(
                monthKey: generation.snapshot.monthKey,
                generationID: generation.generationID
            )
        )

        let restored = try await service.loadLatestBackupPackage()
        assertEmptySnapshot(restored.backup.snapshot)
        XCTAssertEqual(restored.rawSensorState, .invalidArchive)
    }

    func testRawRestoreRejectsAValidArchiveSetWithCorruptMonth() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-corrupt-month-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let backupStore = FilePlanCloudBackupStore(root: root)
        let rawStore = FilePlanCloudRawSensorBackupStore(root: root)
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 20,
            horizontalAccuracy: 8,
            verticalAccuracy: 10
        )
        let generation = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "2026-08",
                sensorReadings: [SensorReading(timestamp: date, point: point)],
                createdAt: date
            ),
            date: date
        )
        let rawPath = PlanCloudRawSensorBackupPath(
            monthKey: generation.snapshot.monthKey,
            generationID: generation.generationID
        ).storageComponents.reduce(root) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        try FileManager.default.removeItem(at: rawPath)
        try Data("truncated".utf8).write(
            to: rawPath
        )

        let restored = try await service.loadLatestBackupPackage()

        XCTAssertEqual(restored.rawSensorState, .invalidArchive)
    }

    func testRawRestorePropagatesCancellationBetweenArchives() async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let baseRawStore = InMemoryPlanCloudRawSensorBackupStore()
        let recoveryKeys = InMemoryPlanCloudRecoveryKeyProvider()
        let writer = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: baseRawStore,
            cloudRecoveryKeyProvider: recoveryKeys
        )
        try writer.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let reading = SensorReading(
            timestamp: date,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 20,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            ),
            sourceDevice: .iPhone
        )
        _ = try await writer.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "2026-08",
                sensorReadings: [reading],
                createdAt: date
            ),
            date: date
        )

        let reader = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: CancelsCurrentTaskOnRawArchiveLoad(
                base: baseRawStore
            ),
            cloudRecoveryKeyProvider: recoveryKeys
        )
        try reader.setPIN("1234")
        let restore = Task {
            try await reader.loadLatestBackupPackage()
        }

        do {
            _ = try await restore.value
            XCTFail("Raw restore cancellation must not become invalidArchive")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testRawRestoreSharesByteBudgetAndDoesNotReadNextArchiveWhenExceeded()
        async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawStore = CountingRawSensorRestoreBackupStore()
        let recoveryKeys = InMemoryPlanCloudRecoveryKeyProvider()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: recoveryKeys
        )
        try service.setPIN("1234")
        let firstDate = Date(timeIntervalSince1970: 1_787_538_400)
        let secondDate = Calendar.autoupdatingCurrent.date(
            byAdding: .month,
            value: 1,
            to: firstDate
        )!
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 20,
            horizontalAccuracy: 8,
            verticalAccuracy: 10
        )
        let first = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [SensorReading(timestamp: firstDate, point: point)],
                createdAt: firstDate
            ),
            date: firstDate
        )
        _ = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [SensorReading(timestamp: secondDate, point: point)],
                createdAt: secondDate
            ),
            date: secondDate
        )
        let firstArchive = try XCTUnwrap(
            try rawStore.load(
                monthKey: first.snapshot.monthKey,
                generationID: first.generationID
            )
        )
        let firstArchiveSize = try makePlanJSONEncoder()
            .encode(firstArchive).count

        let restored = try await service.loadLatestBackupPackage(
            accountIdentifier:
                CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope,
            rawSensorRestoreMaximumBytes: firstArchiveSize
        )

        XCTAssertEqual(
            restored.rawSensorState,
            PlanCloudRawSensorRestoreState.invalidArchive
        )
        XCTAssertEqual(rawStore.restoreReadMonthKeys, [first.snapshot.monthKey])
    }

    func testRawRestoreAccountKeyFallbackReusesLoadedArchiveAndByteBudget()
        async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawStore = CountingRawSensorRestoreBackupStore()
        let recoveryKeys = InMemoryPlanCloudRecoveryKeyProvider()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: recoveryKeys
        )
        try service.setPIN("1234")
        let firstDate = Date(timeIntervalSince1970: 1_787_538_400)
        let secondDate = Calendar.autoupdatingCurrent.date(
            byAdding: .month,
            value: 1,
            to: firstDate
        )!
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 20,
            horizontalAccuracy: 8,
            verticalAccuracy: 10
        )
        let first = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [SensorReading(timestamp: firstDate, point: point)],
                createdAt: firstDate
            ),
            date: firstDate
        )
        let second = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [SensorReading(timestamp: secondDate, point: point)],
                createdAt: secondDate
            ),
            date: secondDate
        )
        let secondArchive = try XCTUnwrap(
            try rawStore.load(
                monthKey: second.snapshot.monthKey,
                generationID: second.generationID
            )
        )
        try rawStore.save(
            PlanRawSensorMonthlyArchive(
                decodedVersion: secondArchive.version,
                monthKey: secondArchive.monthKey,
                accountIdentifier: secondArchive.accountIdentifier,
                createdAt: secondArchive.createdAt,
                encryptedPayload: secondArchive.encryptedPayload,
                wrappedPayloadKey: Data([0]),
                accountWrappedPayloadKey: secondArchive.accountWrappedPayloadKey,
                payloadDigest: secondArchive.payloadDigest,
                generationID: secondArchive.generationID
            ),
            at: PlanCloudRawSensorBackupPath(
                monthKey: second.snapshot.monthKey,
                generationID: second.generationID
            )
        )

        let generations = [first, second].sorted {
            $0.snapshot.monthKey < $1.snapshot.monthKey
        }
        var byteLimit = 0
        for generation in generations {
            let archive = try XCTUnwrap(
                try rawStore.load(
                    monthKey: generation.snapshot.monthKey,
                    generationID: generation.generationID
                )
            )
            byteLimit += try makePlanJSONEncoder().encode(archive).count
        }

        let restored = try await service.loadLatestBackupPackage(
            accountIdentifier: CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope,
            rawSensorRestoreMaximumBytes: byteLimit
        )

        guard case let .available(payload) = restored.rawSensorState else {
            return XCTFail("Account-key fallback should restore both archives")
        }
        XCTAssertEqual(payload.sensorReadings.count, 2)
        XCTAssertEqual(
            rawStore.restoreReadMonthKeys,
            generations.map(\.snapshot.monthKey)
        )
    }

    func testBackupPackagePropagatesUnavailableRawArchiveStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-package-unavailable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let backupStore = FilePlanCloudBackupStore(root: root)
        let rawStore = FilePlanCloudRawSensorBackupStore(root: root)
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 20,
            horizontalAccuracy: 8,
            verticalAccuracy: 10
        )
        let generation = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [SensorReading(timestamp: date, point: point)],
                createdAt: date
            ),
            date: date
        )

        let rawDirectory = root.appendingPathComponent(
            "Taption Plan/Raw Sensors",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rawDirectory,
            withIntermediateDirectories: true
        )
        let rawPath = PlanCloudRawSensorBackupPath(
            monthKey: generation.snapshot.monthKey,
            generationID: generation.generationID
        ).storageComponents.reduce(root) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        try FileManager.default.removeItem(at: rawPath)
        try FileManager.default.createSymbolicLink(
            at: rawPath,
            withDestinationURL: rawDirectory.appendingPathComponent(
                "not-downloaded.rawsensorbackup"
            )
        )

        do {
            _ = try await service.loadLatestBackupPackage(
                accountIdentifier:
                    CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope
            )
            XCTFail("A missing committed raw generation must stay retryable")
        } catch {
            XCTAssertEqual(error as? PlanSecurityError, .accountUnavailable)
        }

        do {
            _ = try await service.loadLatestBackupPackage()
            XCTFail("Async restore must preserve temporary archive unavailability")
        } catch {
            XCTAssertEqual(error as? PlanSecurityError, .accountUnavailable)
        }
    }

    func testEmptyMonthlyGenerationPreservesCommittedRawArchive() async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let reading = SensorReading(
            timestamp: date,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 20,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            )
        )
        _ = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "2026-08",
                sensorReadings: [reading],
                createdAt: date
            ),
            date: date
        )

        let generation = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: nil,
            date: date.addingTimeInterval(60)
        )

        let rawGeneration = try XCTUnwrap(generation.rawSensors)
        XCTAssertEqual(
            try XCTUnwrap(generation.snapshot.generationID),
            generation.generationID
        )
        XCTAssertEqual(
            try XCTUnwrap(rawGeneration.generationID),
            generation.generationID
        )
        XCTAssertEqual(try rawStore.allArchives().count, 2)
        guard case .available(let restored) = try await service
            .loadLatestBackupPackage().rawSensorState else {
            return XCTFail("An empty generation must retain committed raw data")
        }
        XCTAssertEqual(restored.sensorReadings, [reading])
    }

    func testMissingCommittedRawArchiveRejectsNonemptyReplacement()
        async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 20,
            horizontalAccuracy: 8,
            verticalAccuracy: 10
        )
        let committed = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [SensorReading(timestamp: date, point: point)],
                createdAt: date
            ),
            date: date
        )
        try rawStore.delete(
            at: PlanCloudRawSensorBackupPath(
                monthKey: committed.snapshot.monthKey,
                generationID: committed.generationID
            )
        )

        do {
            _ = try await service.saveMonthlyGeneration(
                PlanCloudBackupPayload(snapshot: .empty),
                rawSensorPayload: PlanCloudRawSensorPayload(
                    monthKey: "ignored",
                    sensorReadings: [
                        SensorReading(
                            timestamp: date.addingTimeInterval(1),
                            point: point
                        ),
                    ],
                    createdAt: date.addingTimeInterval(1)
                ),
                date: date.addingTimeInterval(1)
            )
            XCTFail("A missing committed raw archive must not be replaced")
        } catch {
            XCTAssertEqual(error as? PlanSecurityError, .accountUnavailable)
        }

        XCTAssertEqual(
            try backupStore.latest()?.generationID,
            committed.snapshot.generationID
        )
        XCTAssertTrue(try rawStore.allArchives().isEmpty)
    }

    func testUncommittedRawGenerationDoesNotHidePreviousCommittedArchive()
        async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: InMemoryPlanCloudRecoveryKeyProvider()
        )
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let reading = SensorReading(
            timestamp: date,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 20,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            )
        )
        let committed = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [reading],
                createdAt: date
            ),
            date: date
        )
        let orphan = PlanRawSensorMonthlyArchive(
            monthKey: committed.snapshot.monthKey,
            accountIdentifier: committed.rawSensors!.accountIdentifier,
            encryptedPayload: Data([9]),
            wrappedPayloadKey: Data([8]),
            accountWrappedPayloadKey: Data([7]),
            createdAt: date.addingTimeInterval(60),
            generationID: UUID()
        )
        try rawStore.save(
            orphan,
            at: PlanCloudRawSensorBackupPath(
                monthKey: orphan.monthKey,
                generationID: orphan.generationID
            )
        )

        guard case let .available(restored) = try await service
            .loadLatestBackupPackage().rawSensorState else {
            return XCTFail("An uncommitted generation hid valid raw data")
        }
        XCTAssertEqual(restored.sensorReadings, [reading])
    }

    func testCloudPrivateRecoveryRestoresEncryptedArchiveOnAnotherDevice() async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let recoveryKeys = InMemoryPlanCloudRecoveryKeyProvider()
        let writer = makeService(
            backupStore: backupStore,
            cloudRecoveryKeyProvider: recoveryKeys
        )
        try writer.setPIN("1234")

        let archive = try await writer.saveMonthlyArchive(.empty)
        XCTAssertNil(
            archive.encryptedPayload.range(
                of: Data("\"schemaVersion\"".utf8)
            )
        )

        let replacementDevice = makeService(
            backupStore: backupStore,
            cloudRecoveryKeyProvider: recoveryKeys
        )
        let recovered = try await replacementDevice.recoverLatestArchive(
            newPIN: "9876"
        )
        assertEmptySnapshot(recovered)
        XCTAssertTrue(replacementDevice.hasPIN)
    }

    func testCloudLoadFallsBackToAccountKeyAfterPINIsRegisteredAgain() async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let recoveryKeys = InMemoryPlanCloudRecoveryKeyProvider()
        let writer = makeService(
            backupStore: backupStore,
            cloudRecoveryKeyProvider: recoveryKeys
        )
        try writer.setPIN("1234")
        var snapshot = TaptionDataSnapshot.empty
        snapshot.settings.frequentPlaces[0].point = GeoPoint(
            latitude: 37.5665,
            longitude: 126.978,
            altitude: 12,
            horizontalAccuracy: 8,
            verticalAccuracy: 10
        )
        snapshot.settings.userTransitLocations = [
            UserTransitLocation(
                name: "시청역",
                kind: .subwayStation,
                point: GeoPoint(
                    latitude: 37.5657,
                    longitude: 126.9769,
                    altitude: 0,
                    horizontalAccuracy: 10,
                    verticalAccuracy: -1
                )
            ),
        ]
        let reading = SensorReading(
            timestamp: Date(timeIntervalSince1970: 1_787_538_400),
            point: snapshot.settings.frequentPlaces[0].point,
            locationFixQuality: .precise,
            motion: .walking,
            motionConfidence: .high
        )
        _ = try await writer.saveMonthlyArchive(
            PlanCloudBackupPayload(
                snapshot: snapshot,
                routePoints: PlanBackupRoutePointReducer.reduce([reading])
            )
        )

        let reinstalled = makeService(
            backupStore: backupStore,
            cloudRecoveryKeyProvider: recoveryKeys
        )
        try reinstalled.setPIN("9876")
        let restored = try await reinstalled.loadLatestBackup()

        XCTAssertEqual(
            restored.snapshot.settings.frequentPlaces[0].point,
            snapshot.settings.frequentPlaces[0].point
        )
        let restoredTransit = try XCTUnwrap(restored.snapshot.settings.userTransitLocations.first)
        let originalTransit = try XCTUnwrap(snapshot.settings.userTransitLocations.first)
        XCTAssertEqual(restoredTransit.id, originalTransit.id)
        XCTAssertEqual(restoredTransit.name, originalTransit.name)
        XCTAssertEqual(restoredTransit.kind, originalTransit.kind)
        XCTAssertEqual(restoredTransit.point, originalTransit.point)
        XCTAssertEqual(restoredTransit.radiusMeters, originalTransit.radiusMeters)
        XCTAssertEqual(restoredTransit.createdAt.timeIntervalSince1970,
                       originalTransit.createdAt.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertEqual(restored.routePoints.map(\.id), [reading.id])
    }

    func testBAK905H002AccountKeyRewrapKeepsRawGeneration() async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let recoveryKeys = InMemoryPlanCloudRecoveryKeyProvider()
        let writer = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: recoveryKeys
        )
        try writer.setPIN("1234")
        let reading = SensorReading(
            timestamp: .now,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            ),
            sourceDevice: .iPhone
        )
        let generation = try await writer.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: .init(
                monthKey: PlanArchiveSchedule.monthKey(for: .now),
                sensorReadings: [reading],
                createdAt: .now
            )
        )
        XCTAssertEqual(
            backupStore.archives.values.first?.generationID,
            generation.generationID
        )
        XCTAssertEqual(
            rawStore.archives.values.first?.generationID,
            generation.generationID
        )
        let accountKey = try await recoveryKeys.key()
        _ = try rawStore.archives.values.first?.decodedPayload(
            accountKeyData: accountKey
        )

        let reinstalled = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore,
            cloudRecoveryKeyProvider: recoveryKeys
        )
        try reinstalled.setPIN("9876")
        let firstRestore = try await reinstalled.loadLatestBackupPackage()
        guard case .available = firstRestore.rawSensorState else {
            return XCTFail(
                "Account recovery must restore raw data: \(firstRestore.rawSensorState)"
            )
        }
        XCTAssertEqual(
            backupStore.archives.values.first?.generationID,
            rawStore.archives.values.first?.generationID
        )
        let restored = try await reinstalled.loadLatestBackupPackage()

        guard case let .available(payload) = restored.rawSensorState else {
            return XCTFail("Rewrapped snapshot must keep its raw generation")
        }
        XCTAssertEqual(payload.sensorReadings.map(\.id), [reading.id])
    }

    func testPortableBackupDeduplicatesPhotoAndMemoMediaReferences() throws {
        let photoID = "photos-asset-1"
        var snapshot = TaptionDataSnapshot.empty
        snapshot.photos = [
            PhotoMoment(
                id: photoID,
                capturedAt: Date(timeIntervalSince1970: 100),
                pixelWidth: 100,
                pixelHeight: 100,
                isFavorite: false,
                isHiddenFromTimeline: false
            ),
            PhotoMoment(
                id: photoID,
                capturedAt: Date(timeIntervalSince1970: 101),
                pixelWidth: 200,
                pixelHeight: 200,
                isFavorite: true,
                isHiddenFromTimeline: false
            ),
        ]
        snapshot.memos = [
            ActionMemo(
                kind: .idea,
                text: "사진 메모",
                attachments: [
                    MemoAttachment(
                        kind: .photo,
                        localIdentifier: photoID
                    ),
                    MemoAttachment(
                        kind: .photo,
                        localIdentifier: photoID
                    ),
                ]
            ),
        ]

        let portable = try XCTUnwrap(
            PlanCloudBackupPayload(snapshot: snapshot).portableContent
        )
        XCTAssertEqual(portable.mediaReferences.map(\.id), [photoID])
        XCTAssertEqual(portable.userContent.memos[0].mediaReferenceIDs, [photoID])
        XCTAssertEqual(portable.contentLinks.count, 1)
    }

    func testPortableCalendarPreferencesKeepEventKitProviderIdentity() throws {
        let start = Date(timeIntervalSince1970: 100)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.settings.selectedCalendarIDs = ["google-work", "naver-home"]
        snapshot.calendarEvents = [
            CalendarRecord(
                id: "google-event",
                calendarID: "google-work",
                title: "회의",
                span: TimeSpan(
                    start: start,
                    end: start.addingTimeInterval(3_600)
                ),
                isAllDay: false,
                calendarTitle: "Work",
                calendarColorHex: nil,
                sourceTitle: "Google",
                sourceIdentifier: "account@gmail.com"
            ),
            CalendarRecord(
                id: "naver-event",
                calendarID: "naver-home",
                title: "약속",
                span: TimeSpan(
                    start: start,
                    end: start.addingTimeInterval(3_600)
                ),
                isAllDay: false,
                calendarTitle: "Home",
                calendarColorHex: nil,
                sourceTitle: "네이버",
                sourceIdentifier: "account@naver.com"
            ),
        ]

        let preferences = try XCTUnwrap(
            PlanCloudBackupPayload(snapshot: snapshot).portableContent
        ).externalCalendarPreferences

        XCTAssertNil(preferences.preferredProvider)
        XCTAssertEqual(
            Set(preferences.selectedCalendars.map(\.account.provider)),
            [.google, .naver]
        )
    }

    func testSourceSafeSnapshotKeepsManualCorrectionsAndConfirmedTravel() {
        let start = Date(timeIntervalSince1970: 1_787_538_400)
        let manual = ActualRecord(
            planID: nil,
            title: "수동 기록",
            categoryID: "work",
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            source: .manual
        )
        let automatic = ActualRecord(
            planID: nil,
            title: "건강 자동 기록",
            categoryID: "health",
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            source: .healthKit
        )
        let corrected = ActualRecord(
            planID: nil,
            title: "교정한 위치 기록",
            categoryID: "work",
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            source: .location,
            manuallyCorrected: true
        )
        let inferredTravel = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(600)
            ),
            distanceMeters: 1_000,
            confidence: .medium,
            evidence: []
        )
        let confirmedTravel = TravelSegment(
            mode: .bus,
            span: TimeSpan(
                start: start.addingTimeInterval(900),
                end: start.addingTimeInterval(1_500)
            ),
            distanceMeters: 1_000,
            confidence: .high,
            evidence: ["사용자 확인"],
            isConfirmed: true
        )
        var snapshot = TaptionDataSnapshot.empty
        snapshot.actuals = [manual, automatic, corrected]
        snapshot.travel = [inferredTravel, confirmedTravel]

        let safe = PlanCloudSnapshotRecoveryPolicy.sourceSafe(snapshot)

        XCTAssertEqual(
            safe.actuals.map(\.id),
            [manual.id, corrected.id]
        )
        XCTAssertEqual(safe.travel.map(\.id), [confirmedTravel.id])
    }

    func testICloudSnapshotExcludesHealthAndWatchResults() {
        let start = Date(timeIntervalSince1970: 1_787_538_400)
        let manual = ActualRecord(
            planID: nil,
            title: "수동 기록",
            categoryID: "work",
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            source: .manual
        )
        let correctedLocation = ActualRecord(
            planID: nil,
            title: "교정한 위치",
            categoryID: "work",
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            source: .location,
            manuallyCorrected: true
        )
        let health = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            source: .healthKit,
            manuallyCorrected: true
        )
        let watch = ActualRecord(
            planID: nil,
            title: "운동",
            categoryID: "activity",
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            source: .appleWatch,
            manuallyCorrected: true
        )
        let correctedPhoneSleep = ActualRecord(
            planID: nil,
            title: "교정한 수면",
            categoryID: "sleep",
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            source: .motion,
            manuallyCorrected: true
        )
        var snapshot = TaptionDataSnapshot.empty
        snapshot.actuals = [
            manual, correctedLocation, health, watch, correctedPhoneSleep,
        ]
        let healthNodeID = "automatic.actual.\(health.id.uuidString)"
        snapshot.recordLinks = [
            RecordLink(fromNodeID: healthNodeID, toNodeID: "action.keep"),
        ]
        snapshot.memos = [
            ActionMemo(
                targetID: healthNodeID,
                categoryID: "sleep",
                kind: .idea,
                text: "기기 내부 메모"
            ),
        ]
        snapshot.settings.activityCorrections[health.id] = ActivityCorrection(
            title: "교정 수면",
            categoryID: "sleep"
        )
        snapshot.settings.suppressedActualIDs.insert(health.id)
        snapshot.settings.confirmedSleepSpans = [
            TimeSpan(start: start, end: start.addingTimeInterval(600)),
        ]

        let safe = PlanCloudSnapshotRecoveryPolicy.iCloudSafe(snapshot)

        XCTAssertEqual(safe.actuals.map(\.id), [manual.id, correctedLocation.id])
        XCTAssertTrue(safe.recordLinks.isEmpty)
        XCTAssertNil(safe.memos.first?.targetID)
        XCTAssertNil(safe.settings.activityCorrections[health.id])
        XCTAssertFalse(safe.settings.suppressedActualIDs.contains(health.id))
        XCTAssertTrue(safe.settings.confirmedSleepSpans.isEmpty)

        let payload = PlanCloudBackupPayload(snapshot: snapshot)
        XCTAssertEqual(payload.snapshot.actuals.map(\.id), [manual.id, correctedLocation.id])
        XCTAssertTrue(payload.snapshot.recordLinks.isEmpty)
        XCTAssertEqual(payload.snapshot.travel, [])
    }

    func testCloudBackupRouteStripsFitnessSignalsAndWatchPoints() throws {
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 20,
            horizontalAccuracy: 8,
            verticalAccuracy: 10
        )
        let phone = SensorReading(
            timestamp: date,
            point: point,
            motion: .walking,
            motionConfidence: .high,
            stepCount: 2_000,
            sourceDevice: .iPhone
        )
        let watch = SensorReading(
            timestamp: date.addingTimeInterval(1),
            point: point,
            motion: .walking,
            motionConfidence: .high,
            stepCount: 2_000,
            sourceDevice: .appleWatch
        )

        let payload = PlanCloudBackupPayload(
            snapshot: .empty,
            routePoints: [
                try XCTUnwrap(PlanBackupRoutePoint(phone)),
                try XCTUnwrap(PlanBackupRoutePoint(watch)),
            ]
        )

        XCTAssertEqual(payload.routePoints.map(\.id), [phone.id])
        XCTAssertEqual(payload.routePoints[0].sensorReading.motion, .unknown)
        XCTAssertNil(payload.routePoints[0].sensorReading.stepCount)
    }

    func testSameMonthBackupMergesGPSAndKeepsLatestFullSettings() throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let service = makeService(backupStore: backupStore)
        try service.setPIN("1234")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3_600)!
        let firstDate = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 3,
            hour: 9
        ))!
        let latestDate = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 24,
            hour: 19
        ))!
        let oldReading = SensorReading(
            timestamp: firstDate,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 10,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            )
        )
        _ = try service.saveMonthlyArchive(
            PlanCloudBackupPayload(
                snapshot: .empty,
                routePoints: PlanBackupRoutePointReducer.reduce([oldReading])
            ),
            accountIdentifier: "account-a",
            date: firstDate
        )

        var latestSnapshot = TaptionDataSnapshot.empty
        latestSnapshot.settings.locationEnabled = true
        latestSnapshot.settings.weatherEnabled = true
        latestSnapshot.settings.weatherSidebarVisible = false
        latestSnapshot.settings.frequentPlaces[0].point = GeoPoint(
            latitude: 37.5665,
            longitude: 126.978,
            altitude: 12,
            horizontalAccuracy: 8,
            verticalAccuracy: 10
        )
        latestSnapshot.settings.userTransitLocations = [
            UserTransitLocation(
                name: "시청역",
                kind: .subwayStation,
                point: GeoPoint(
                    latitude: 37.5657,
                    longitude: 126.9769,
                    altitude: 0,
                    horizontalAccuracy: 10,
                    verticalAccuracy: -1
                )
            ),
        ]
        let latestReading = SensorReading(
            timestamp: latestDate,
            point: latestSnapshot.settings.frequentPlaces[0].point
        )
        _ = try service.saveMonthlyArchive(
            PlanCloudBackupPayload(
                snapshot: latestSnapshot,
                routePoints: PlanBackupRoutePointReducer.reduce([
                    latestReading,
                ])
            ),
            accountIdentifier: "account-a",
            date: latestDate
        )

        let restored = try service.loadLatestBackup(
            accountIdentifier: "account-a"
        )
        XCTAssertEqual(
            Set(restored.routePoints.map(\.id)),
            Set([oldReading.id, latestReading.id])
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let encodedSettings = try encoder.encode(latestSnapshot.settings)
        XCTAssertEqual(
            restored.snapshot.settings,
            try decoder.decode(AppFeatureSettings.self, from: encodedSettings)
        )
    }

    func testStaleSameMonthBackupDoesNotEraseNewerRecords() throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let service = makeService(backupStore: backupStore)
        try service.setPIN("1234")
        let month = Date(timeIntervalSince1970: 1_785_600_000)

        var newer = TaptionDataSnapshot.empty
        newer.updatedAt = month.addingTimeInterval(3_600)
        newer.settings.locationEnabled = true
        newer.plans = [
            PlanRecord(
                title: "newer",
                span: TimeSpan(
                    start: month,
                    end: month.addingTimeInterval(1_800)
                ),
                categoryID: "work"
            )
        ]
        _ = try service.saveMonthlyArchive(
            PlanCloudBackupPayload(snapshot: newer),
            accountIdentifier: "account-a",
            date: month
        )

        var stale = TaptionDataSnapshot.empty
        stale.updatedAt = month
        stale.plans = [
            PlanRecord(
                title: "stale-writer-only",
                span: TimeSpan(
                    start: month.addingTimeInterval(7_200),
                    end: month.addingTimeInterval(9_000)
                ),
                categoryID: "work"
            )
        ]
        _ = try service.saveMonthlyArchive(
            PlanCloudBackupPayload(snapshot: stale),
            accountIdentifier: "account-a",
            date: month.addingTimeInterval(10_800)
        )

        let restored = try service.loadLatestBackup(
            accountIdentifier: "account-a"
        ).snapshot
        XCTAssertEqual(Set(restored.plans.map(\.title)), [
            "newer",
            "stale-writer-only",
        ])
        XCTAssertTrue(restored.settings.locationEnabled)
    }

    func testSameMonthBackupPreservesExistingAppLogWhenLatestPayloadIsEmpty() throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let service = makeService(backupStore: backupStore)
        try service.setPIN("1234")
        let firstDate = Date(timeIntervalSince1970: 1_787_538_400)
        let latestDate = firstDate.addingTimeInterval(3_600)

        _ = try service.saveMonthlyArchive(
            PlanCloudBackupPayload(
                snapshot: .empty,
                appLog: "first-operation\n"
            ),
            accountIdentifier: "account-a",
            date: firstDate
        )
        _ = try service.saveMonthlyArchive(
            PlanCloudBackupPayload(snapshot: .empty),
            accountIdentifier: "account-a",
            date: latestDate
        )

        let restored = try service.loadLatestBackup(
            accountIdentifier: "account-a"
        )
        XCTAssertEqual(restored.appLog, "first-operation")
    }

    func testBackupRestoreCombinesRoutesAcrossMonthlyArchives() throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let service = makeService(backupStore: backupStore)
        try service.setPIN("1234")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3_600)!
        let july = calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 31,
            hour: 23
        ))!
        let august = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 24,
            hour: 19
        ))!
        let julyReading = SensorReading(
            timestamp: july,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 10,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            )
        )
        let augustReading = SensorReading(
            timestamp: august,
            point: GeoPoint(
                latitude: 37.6,
                longitude: 127,
                altitude: 12,
                horizontalAccuracy: 7,
                verticalAccuracy: 10
            )
        )
        _ = try service.saveMonthlyArchive(
            PlanCloudBackupPayload(
                snapshot: .empty,
                routePoints: PlanBackupRoutePointReducer.reduce([
                    julyReading,
                ])
            ),
            accountIdentifier: "account-a",
            date: july
        )
        _ = try service.saveMonthlyArchive(
            PlanCloudBackupPayload(
                snapshot: .empty,
                routePoints: PlanBackupRoutePointReducer.reduce([
                    augustReading,
                ])
            ),
            accountIdentifier: "account-a",
            date: august
        )

        let restored = try service.loadLatestBackup(
            accountIdentifier: "account-a"
        )
        XCTAssertEqual(
            restored.routePoints.map(\.id),
            [julyReading.id, augustReading.id]
        )
    }

    func testBackupPayloadKeepsConfirmedTravel() throws {
        let service = makeService()
        try service.setPIN("1234")
        var snapshot = TaptionDataSnapshot.empty
        snapshot.travel = [
            TravelSegment(
                mode: .subway,
                span: TimeSpan(
                    start: Date(timeIntervalSince1970: 1_787_538_400),
                    end: Date(timeIntervalSince1970: 1_787_542_000)
                ),
                distanceMeters: 12_000,
                confidence: .high,
                evidence: ["사용자 확인"],
                isConfirmed: true
            ),
        ]

        _ = try service.saveMonthlyArchive(snapshot, accountIdentifier: "account-a")
        XCTAssertEqual(
            try service.loadLatestArchive(accountIdentifier: "account-a").travel,
            snapshot.travel
        )
    }

    func testVersionTwoSnapshotArchiveStillDecodes() throws {
        var snapshot = TaptionDataSnapshot.empty
        snapshot.settings.userTransitLocations = [
            UserTransitLocation(
                name: "가정역",
                kind: .subwayStation,
                point: GeoPoint(
                    latitude: 37.5248,
                    longitude: 126.6759,
                    altitude: 0,
                    horizontalAccuracy: 10,
                    verticalAccuracy: -1
                ),
                createdAt: Date(timeIntervalSince1970: 1_787_538_400)
            ),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let compressed = TaptionSnapshotCompression.encode(
            try encoder.encode(snapshot)
        )
        let archiveKey = Data(repeating: 9, count: 32)
        let verifier = try PlanPINVerifier(pin: "1234") { _ in
            Data(repeating: 4, count: 16)
        }
        let archiveDate = Date(timeIntervalSince1970: 1_787_538_400)
        let authenticatedData = try PlanArchiveMetadata.authenticatedData(
            version: 2,
            monthKey: "2026-08",
            accountIdentifier: "account-a",
            createdAt: archiveDate,
            generationID: nil
        )
        let encrypted = try AES.GCM.seal(
            compressed,
            using: SymmetricKey(data: archiveKey),
            authenticating: authenticatedData
        ).combined!
        let wrapped = try AES.GCM.seal(
            archiveKey,
            using: SymmetricKey(data: verifier.keyMaterial)
        ).combined!
        let archive = PlanMonthlyArchive(
            monthKey: "2026-08",
            accountIdentifier: "account-a",
            encryptedPayload: encrypted,
            wrappedPayloadKey: wrapped,
            accountWrappedPayloadKey: Data(),
            createdAt: archiveDate
        )
        let encoderForArchive = JSONEncoder()
        encoderForArchive.dateEncodingStrategy = .secondsSince1970
        encoderForArchive.outputFormatting = [.sortedKeys]
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encoderForArchive.encode(archive)
            ) as? [String: Any]
        )
        legacyObject["version"] = 2
        let legacyData = try JSONSerialization.data(
            withJSONObject: legacyObject,
            options: [.sortedKeys]
        )
        let decoderForArchive = JSONDecoder()
        decoderForArchive.dateDecodingStrategy = .secondsSince1970
        let legacyArchive = try decoderForArchive.decode(
            PlanMonthlyArchive.self,
            from: legacyData
        )

        XCTAssertEqual(legacyArchive.version, 2)
        XCTAssertNil(legacyArchive.hasRawSensorArchive)
        XCTAssertEqual(
            try legacyArchive.decodedPayload(pinKeyData: verifier.keyMaterial)
                .snapshot.settings.userTransitLocations,
            snapshot.settings.userTransitLocations
        )
    }

    func testVersionOneSnapshotArchiveStillDecodes() throws {
        let verifier = try PlanPINVerifier(pin: "1234") { _ in
            Data(repeating: 4, count: 16)
        }
        let archive = try JSONDecoder().decode(
            PlanMonthlyArchive.self,
            from: makeVersionOneArchiveData(
            payload: PlanCloudBackupPayload(snapshot: .empty),
            monthKey: "2026-09",
            accountIdentifier: "account-a",
            createdAt: Date(timeIntervalSince1970: 1_788_629_099)
            )
        )

        let decoded = try archive.decodedPayload(
            pinKeyData: verifier.keyMaterial
        )
        assertEmptySnapshot(decoded.snapshot)
    }

    func testVersionOneRawSensorArchiveStillDecodes() throws {
        let verifier = try PlanPINVerifier(pin: "1234") { _ in
            Data(repeating: 4, count: 16)
        }
        let archiveData = try makeVersionOneArchiveData(
            payload: PlanCloudRawSensorPayload(monthKey: "2026-09"),
            monthKey: "2026-09",
            accountIdentifier: "account-a",
            createdAt: Date(timeIntervalSince1970: 1_788_629_099)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let archive = try decoder.decode(
            PlanRawSensorMonthlyArchive.self,
            from: archiveData
        )
        let restoredArchive = try PlanRawSensorMonthlyArchive.decodeForRestore(
            archiveData,
            cancellationCheck: {}
        )
        XCTAssertEqual(restoredArchive, archive)

        let decoded = try archive.decodedPayload(
            pinKeyData: verifier.keyMaterial
        )
        XCTAssertEqual(decoded.monthKey, "2026-09")
        XCTAssertTrue(decoded.isEmpty)
    }

    func testBackupRouteReducerKeepsEndpointsAndBoundsDenseGPS() {
        let start = Date(timeIntervalSince1970: 1_787_538_400)
        let readings = (0..<70_000).map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(index)),
                point: GeoPoint(
                    latitude: 37.5 + Double(index) * 0.000_001,
                    longitude: 126.9,
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                ),
                locationFixQuality: .precise,
                motion: .walking,
                motionConfidence: .high
            )
        }
        let reduced = PlanBackupRoutePointReducer.reduce(readings)

        XCTAssertEqual(reduced.first?.id, readings.first?.id)
        XCTAssertEqual(reduced.last?.id, readings.last?.id)
        XCTAssertEqual(reduced.first?.sensorReading, readings.first)
        XCTAssertEqual(reduced.last?.sensorReading, readings.last)
        XCTAssertLessThanOrEqual(
            reduced.count,
            PlanBackupRoutePointReducer.maximumCount
        )
    }

    func testBackupRouteWindowCoversTheCurrentCalendarMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3_600)!
        let now = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 8,
                day: 24,
                hour: 12
            )
        )!
        let span = PlanBackupRoutePointReducer.backupSpan(
            containing: now,
            calendar: calendar
        )

        XCTAssertEqual(
            span.start,
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))
        )
        XCTAssertEqual(span.end, now.addingTimeInterval(5 * 60))
    }

    func testBackupRouteReducerDropsAnIsolatedImpossibleGPSJump() {
        let start = Date(timeIntervalSince1970: 1_787_538_400)
        func reading(_ offset: TimeInterval, _ latitude: Double) -> SensorReading {
            SensorReading(
                timestamp: start.addingTimeInterval(offset),
                point: GeoPoint(
                    latitude: latitude,
                    longitude: 126.9,
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                ),
                locationFixQuality: .precise,
                motion: .walking,
                motionConfidence: .high
            )
        }
        let first = reading(0, 37.5000)
        let spike = reading(10, 37.9000)
        let last = reading(20, 37.5005)

        let reduced = PlanBackupRoutePointReducer.reduce([first, spike, last])

        XCTAssertEqual(reduced.map(\.id), [first.id, last.id])
        XCTAssertEqual(spike.point?.latitude, 37.9)
    }

    func testRestoredRoutePointsAreReducedWithoutChangingRawReading() {
        let start = Date(timeIntervalSince1970: 1_787_538_400)
        let reading = SensorReading(
            timestamp: start,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            ),
            locationFixQuality: .precise
        )
        let restored = PlanBackupRoutePointReducer.restoring([
            [PlanBackupRoutePoint(reading)!],
        ])

        XCTAssertEqual(restored.map(\.sensorReading), [reading])
        XCTAssertEqual(reading.point?.latitude, 37.5)
    }

    func testSleepOvernightSpanStartsPreviousEveningAndEndsAtNoon() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3_600)!
        let date = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 26,
            hour: 14
        ))!

        let span = SleepAnalysisEngine.overnightSpan(
            containing: date,
            calendar: calendar
        )

        XCTAssertEqual(
            span.start,
            calendar.date(from: DateComponents(
                year: 2026,
                month: 8,
                day: 25,
                hour: 18
            ))
        )
        XCTAssertEqual(
            span.end,
            calendar.date(from: DateComponents(
                year: 2026,
                month: 8,
                day: 26,
                hour: 12
            ))
        )
    }

    func testLegacyBackupCanDrawApproximateRouteFromTravelAndPlaces() {
        let start = Date(timeIntervalSince1970: 1_787_538_400)
        let home = PlaceStay(
            placeKey: "home",
            displayName: "집",
            span: TimeSpan(
                start: start.addingTimeInterval(-3_600),
                end: start
            ),
            confidence: .high,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: 10
            )
        )
        let office = PlaceStay(
            placeKey: "office",
            displayName: "회사",
            span: TimeSpan(
                start: start.addingTimeInterval(1_800),
                end: start.addingTimeInterval(7_200)
            ),
            confidence: .high,
            point: GeoPoint(
                latitude: 37.6,
                longitude: 127.0,
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: 10
            )
        )
        let travel = TravelSegment(
            fromPlaceID: home.id,
            toPlaceID: office.id,
            mode: .bus,
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(1_800)
            ),
            distanceMeters: 15_000,
            confidence: .high,
            evidence: []
        )

        let readings = PlanBackupRouteFallbackEngine.readings(
            travel: [travel],
            places: [home, office],
            in: TimeSpan(
                start: start.addingTimeInterval(-60),
                end: start.addingTimeInterval(1_860)
            )
        )

        XCTAssertEqual(readings.first?.point, home.point)
        XCTAssertEqual(readings.last?.point, office.point)
        XCTAssertEqual(readings.map(\.behavior), Array(repeating: "bus", count: 4))
        XCTAssertTrue(zip(readings, readings.dropFirst()).allSatisfy {
            $1.timestamp.timeIntervalSince($0.timestamp)
                <= PlanBackupRouteFallbackEngine.maximumRouteGap
        })
    }

    func testLegacyBackupFallbackInterpolatesAcrossDateLine() {
        let start = Date(timeIntervalSince1970: 1_787_538_400)
        let travel = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(30 * 60)
            ),
            distanceMeters: 30_000,
            confidence: .high,
            evidence: [],
            subwayRoute: SubwayRoutePath(
                stops: [
                    SubwayRouteStop(
                        lineName: "test",
                        order: 0,
                        stationName: "출발",
                        latitude: 37.5,
                        longitude: 179.9
                    ),
                    SubwayRouteStop(
                        lineName: "test",
                        order: 1,
                        stationName: "도착",
                        latitude: 37.5,
                        longitude: -179.9
                    ),
                ],
                lineNames: ["test"],
                transferStationNames: []
            )
        )

        let readings = PlanBackupRouteFallbackEngine.readings(
            travel: [travel],
            places: [],
            in: travel.span
        )
        let longitudes = readings.compactMap(\.point).map(\.longitude)

        XCTAssertGreaterThan(readings.count, 2)
        XCTAssertTrue(longitudes.allSatisfy { abs($0) > 179.8 })
    }

    func testLegacyRouteFallbackClipsToTheRequestedDay() throws {
        let start = Date(timeIntervalSince1970: 1_787_538_400)
        let from = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let to = GeoPoint(
            latitude: 37.6,
            longitude: 127.0,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let travel = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(3_600)
            ),
            distanceMeters: 20_000,
            confidence: .high,
            evidence: [],
            subwayRoute: SubwayRoutePath(
                stops: [
                    SubwayRouteStop(
                        lineName: "테스트",
                        order: 0,
                        stationName: "출발",
                        latitude: from.latitude,
                        longitude: from.longitude
                    ),
                    SubwayRouteStop(
                        lineName: "테스트",
                        order: 1,
                        stationName: "도착",
                        latitude: to.latitude,
                        longitude: to.longitude
                    ),
                ],
                lineNames: ["테스트"],
                transferStationNames: []
            )
        )
        let requested = TimeSpan(
            start: start.addingTimeInterval(900),
            end: start.addingTimeInterval(1_800)
        )
        let readings = PlanBackupRouteFallbackEngine.readings(
            travel: [travel],
            places: [],
            in: requested
        )

        XCTAssertEqual(readings.first?.timestamp, requested.start)
        XCTAssertEqual(readings.last?.timestamp, requested.end)
        XCTAssertTrue(zip(readings, readings.dropFirst()).allSatisfy {
            $1.timestamp.timeIntervalSince($0.timestamp)
                <= PlanBackupRouteFallbackEngine.maximumRouteGap
        })
        let first = try XCTUnwrap(readings.first?.point)
        let last = try XCTUnwrap(readings.last?.point)
        XCTAssertEqual(first.latitude, 37.525, accuracy: 0.000_001)
        XCTAssertEqual(last.latitude, 37.55, accuracy: 0.000_001)
    }

    func testLegacyRouteFallbackDoesNotConnectDistantUnrelatedPlaces() {
        let start = Date(timeIntervalSince1970: 1_787_538_400)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let oldPlace = PlaceStay(
            placeKey: "old",
            displayName: "이전 장소",
            span: TimeSpan(
                start: start.addingTimeInterval(-12 * 3_600),
                end: start.addingTimeInterval(-10 * 3_600)
            ),
            confidence: .high,
            point: point
        )
        let futurePlace = PlaceStay(
            placeKey: "future",
            displayName: "다음 장소",
            span: TimeSpan(
                start: start.addingTimeInterval(10 * 3_600),
                end: start.addingTimeInterval(12 * 3_600)
            ),
            confidence: .high,
            point: point
        )
        let travel = TravelSegment(
            mode: .bus,
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(30 * 60)
            ),
            distanceMeters: 1_000,
            confidence: .low,
            evidence: []
        )

        XCTAssertTrue(PlanBackupRouteFallbackEngine.readings(
            travel: [travel],
            places: [oldPlace, futurePlace],
            in: travel.span
        ).isEmpty)
    }

    func testBackupRouteFallbackKeepsFirstEqualBoundaryPlace() throws {
        let start = Date(timeIntervalSince1970: 1_787_538_400)
        let firstOrigin = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let secondOrigin = GeoPoint(
            latitude: 37.51,
            longitude: 126.91,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let firstDestination = GeoPoint(
            latitude: 37.6,
            longitude: 127.0,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let secondDestination = GeoPoint(
            latitude: 37.61,
            longitude: 127.01,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let originSpan = TimeSpan(
            start: start.addingTimeInterval(-600),
            end: start
        )
        let destinationSpan = TimeSpan(
            start: start.addingTimeInterval(600),
            end: start.addingTimeInterval(1_200)
        )
        let places = [
            PlaceStay(
                placeKey: "origin-first",
                displayName: "첫 출발지",
                span: originSpan,
                confidence: .high,
                point: firstOrigin
            ),
            PlaceStay(
                placeKey: "origin-second",
                displayName: "두 번째 출발지",
                span: originSpan,
                confidence: .high,
                point: secondOrigin
            ),
            PlaceStay(
                placeKey: "destination-first",
                displayName: "첫 도착지",
                span: destinationSpan,
                confidence: .high,
                point: firstDestination
            ),
            PlaceStay(
                placeKey: "destination-second",
                displayName: "두 번째 도착지",
                span: destinationSpan,
                confidence: .high,
                point: secondDestination
            ),
        ]
        let travel = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(600)
            ),
            distanceMeters: 10_000,
            confidence: .high,
            evidence: []
        )

        let readings = PlanBackupRouteFallbackEngine.readings(
            travel: [travel],
            places: places,
            in: travel.span
        )

        XCTAssertEqual(try XCTUnwrap(readings.first?.point), firstOrigin)
        XCTAssertEqual(try XCTUnwrap(readings.last?.point), firstDestination)
    }

    func testBackupRouteFallbackBoundsLegacyEndpointLookup() {
        let start = Date(timeIntervalSince1970: 1_787_538_400)
        let count = 1_000
        let places = (0...count).map { index in
            let end = start.addingTimeInterval(Double(index) * 10 * 60)
            return PlaceStay(
                placeKey: "place-\(index)",
                displayName: "장소 \(index)",
                span: TimeSpan(
                    start: end.addingTimeInterval(-5 * 60),
                    end: end
                ),
                confidence: .high,
                point: GeoPoint(
                    latitude: 37.5 + Double(index) * 0.000_001,
                    longitude: 126.9,
                    altitude: 0,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 10
                )
            )
        }
        let travel = (0..<count).map { index in
            let segmentStart = start.addingTimeInterval(
                Double(index) * 10 * 60
            )
            return TravelSegment(
                mode: .car,
                span: TimeSpan(
                    start: segmentStart,
                    end: segmentStart.addingTimeInterval(5 * 60)
                ),
                distanceMeters: 100,
                confidence: .high,
                evidence: []
            )
        }
        var endpointInspectionCount = 0

        let readings = PlanBackupRouteFallbackEngine.readings(
            travel: travel,
            places: places,
            in: TimeSpan(
                start: start,
                end: start.addingTimeInterval(Double(count) * 10 * 60)
            ),
            endpointInspectionCount: &endpointInspectionCount
        )

        XCTAssertEqual(readings.count, count * 2)
        XCTAssertLessThan(endpointInspectionCount, count * count / 10)
    }

    func testBackupRouteFallbackSupplementsSparseArchivedEndpoints() {
        let start = Date(timeIntervalSince1970: 1_787_538_400)
        let home = PlaceStay(
            placeKey: "home",
            displayName: "집",
            span: TimeSpan(start: start.addingTimeInterval(-600), end: start),
            confidence: .high,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: 10
            )
        )
        let office = PlaceStay(
            placeKey: "office",
            displayName: "회사",
            span: TimeSpan(
                start: start.addingTimeInterval(3_600),
                end: start.addingTimeInterval(4_200)
            ),
            confidence: .high,
            point: GeoPoint(
                latitude: 37.6,
                longitude: 127.0,
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: 10
            )
        )
        let travel = TravelSegment(
            fromPlaceID: home.id,
            toPlaceID: office.id,
            mode: .car,
            span: TimeSpan(start: start, end: start.addingTimeInterval(3_600)),
            distanceMeters: 15_000,
            confidence: .high,
            evidence: []
        )
        let archived = [home.point, office.point].enumerated().map { index, point in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(index) * 3_600),
                point: point,
                locationFixQuality: .precise,
                motion: .automotive,
                motionConfidence: .high,
                gpsAvailable: true
            )
        }

        let readings = PlanBackupRouteFallbackEngine.readings(
            travel: [travel],
            places: [home, office],
            in: travel.span,
            supplementing: archived
        )

        XCTAssertGreaterThan(readings.count, 2)
        XCTAssertTrue(zip(readings, readings.dropFirst()).allSatisfy {
            $1.timestamp.timeIntervalSince($0.timestamp)
                <= PlanBackupRouteFallbackEngine.maximumRouteGap
        })
        XCTAssertFalse(RouteTimelineDataEngine.project(
            selectedDate: start,
            through: travel.span.end,
            actuals: [],
            readings: archived + readings
        ).segments.isEmpty)
    }

    func testBackupRouteFallbackSkipsContinuouslyArchivedTravel() {
        let start = Date(timeIntervalSince1970: 1_787_538_400)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5
        )
        let travel = TravelSegment(
            mode: .walking,
            span: TimeSpan(start: start, end: start.addingTimeInterval(20 * 60)),
            distanceMeters: 1_000,
            confidence: .high,
            evidence: []
        )
        let archived = [0, 10, 20].map { minute in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(minute * 60)),
                point: point,
                locationFixQuality: .precise,
                motion: .walking,
                motionConfidence: .high,
                gpsAvailable: true
            )
        }

        XCTAssertTrue(PlanBackupRouteFallbackEngine.readings(
            travel: [travel],
            places: [],
            in: travel.span,
            supplementing: archived
        ).isEmpty)
    }

    func testUbiquitousCloudRecoveryKeyCanBePersistedReadAndRemoved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UbiquitousPlanCloudRecoveryKeyStore(containerURL: directory)
        let key = Data(repeating: 7, count: 32)

        try store.save(key)
        XCTAssertEqual(try store.existingKey(), key)
        try store.removeExistingKey()
        XCTAssertNil(try store.existingKey())
    }

    func testUbiquitousCloudRecoveryKeyRejectsInvalidLength() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UbiquitousPlanCloudRecoveryKeyStore(containerURL: directory)

        XCTAssertThrowsError(
            try store.save(Data(repeating: 1, count: 31))
        ) { error in
            XCTAssertEqual(error as? PlanSecurityError, .accountUnavailable)
        }
    }

    func testUbiquitousCloudRecoveryKeyDoesNotCrossAccountScope() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UbiquitousPlanCloudRecoveryKeyStore(containerURL: directory)
        let accountAKey = Data(repeating: 1, count: 32)
        let accountBKey = Data(repeating: 2, count: 32)

        try store.save(accountAKey, accountIdentifier: "account-A")
        XCTAssertEqual(
            try store.existingScopedKey(for: "account-A"),
            accountAKey
        )
        XCTAssertNil(try store.existingScopedKey(for: "account-B"))

        try store.save(accountBKey, accountIdentifier: "account-B")
        XCTAssertEqual(
            try store.existingScopedKey(for: "account-B"),
            accountBKey
        )
        XCTAssertEqual(
            try store.existingScopedKey(for: "account-A"),
            accountAKey
        )
    }

    func testCloudRecoveryKeyPreservesLegacyFallbackWhenKeychainWriteFails()
        throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyStore = UbiquitousPlanCloudRecoveryKeyStore(
            containerURL: directory
        )
        let key = Data(repeating: 8, count: 32)
        try legacyStore.save(key)
        let provider = CloudKitPlanCloudRecoveryKeyProvider(
            documentFallback: legacyStore,
            localFallback: FailingPlanCredentialStore()
        )

        XCTAssertThrowsError(try provider.cacheResolvedKey(key))
        XCTAssertEqual(try legacyStore.existingKey(), key)
    }

    func testCloudRecoveryKeyRemovesLegacyFallbackAfterKeychainWriteSucceeds()
        throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyStore = UbiquitousPlanCloudRecoveryKeyStore(
            containerURL: directory
        )
        let key = Data(repeating: 9, count: 32)
        try legacyStore.save(key)
        let localStore = InMemoryPlanCredentialStore()
        let provider = CloudKitPlanCloudRecoveryKeyProvider(
            documentFallback: legacyStore,
            localFallback: localStore
        )

        XCTAssertEqual(try provider.cacheResolvedKey(key), key)
        XCTAssertEqual(try localStore.read(), key)
        XCTAssertNil(try legacyStore.existingKey())
    }

    func testAccountScopedBackupPackageCancelsWhenDeletedDuringRawRestore()
        async throws {
        try await assertBackupPackageCancelsDuringRawRestore { service in
            try await service.loadLatestBackupPackage(
                accountIdentifier:
                    CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope
            )
        }
    }

    func testBackupPackageCancelsWhenDeletedDuringRawRestore() async throws {
        try await assertBackupPackageCancelsDuringRawRestore { service in
            try await service.loadLatestBackupPackage()
        }
    }

    private func assertBackupPackageCancelsDuringRawRestore(
        load: @escaping @MainActor (PlanSecurityBackupService) async throws
            -> PlanCloudBackupRestorePackage
    ) async throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawSensorBackupStore = GatedPlanCloudRawSensorBackupStore()
        let recoveryKeyProvider = InMemoryPlanCloudRecoveryKeyProvider()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawSensorBackupStore,
            cloudRecoveryKeyProvider: recoveryKeyProvider
        )
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        let reading = SensorReading(
            timestamp: date,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.9,
                altitude: 20,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            )
        )
        _ = try await service.saveMonthlyGeneration(
            PlanCloudBackupPayload(snapshot: .empty),
            rawSensorPayload: PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [reading],
                createdAt: date
            ),
            date: date
        )

        let restore = Task { try await load(service) }
        await rawSensorBackupStore.waitUntilRestoreStarts()
        try service.deleteAllBackups()
        await rawSensorBackupStore.releaseRestore()

        do {
            _ = try await restore.value
            XCTFail("A restore crossing backup deletion must be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(try backupStore.allArchives().isEmpty)
        XCTAssertTrue(try rawSensorBackupStore.allArchives().isEmpty)
    }

    private func makeService(
        biometric: PlanLocalBiometricAuthenticator = MockPlanLocalBiometricAuthenticator(),
        backupStore: PlanCloudBackupStore = InMemoryPlanCloudBackupStore(),
        rawSensorBackupStore: PlanCloudRawSensorBackupStore =
            InMemoryPlanCloudRawSensorBackupStore(),
        cloudRecoveryKeyProvider: PlanCloudRecoveryKeyProvider? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> PlanSecurityBackupService {
        let defaults = UserDefaults(
            suiteName: "SecurityBackupCoreTests.\(UUID().uuidString)"
        )!
        return PlanSecurityBackupService(
            credentialStore: InMemoryPlanCredentialStore(),
            backupStore: backupStore,
            rawSensorBackupStore: rawSensorBackupStore,
            cloudRecoveryKeyProvider: cloudRecoveryKeyProvider,
            biometricAuthenticator: biometric,
            settingsDefaults: defaults
        )
    }

    private func makeVersionOneArchiveData<Payload: Encodable>(
        payload: Payload,
        monthKey: String,
        accountIdentifier: String,
        createdAt: Date
    ) throws -> Data {
        let key = Data(repeating: 9, count: 32)
        let verifier = try PlanPINVerifier(pin: "1234") { _ in
            Data(repeating: 4, count: 16)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let compressed = TaptionSnapshotCompression.encode(
            try encoder.encode(payload)
        )
        let encrypted = try AES.GCM.seal(
            compressed,
            using: SymmetricKey(data: key)
        ).combined!
        let wrapped = try AES.GCM.seal(
            key,
            using: SymmetricKey(data: verifier.keyMaterial)
        ).combined!
        let envelope = VersionOneArchiveEnvelope(
            version: 1,
            monthKey: monthKey,
            accountIdentifier: accountIdentifier,
            createdAt: createdAt,
            encryptedPayload: encrypted,
            wrappedPayloadKey: wrapped,
            accountWrappedPayloadKey: Data(),
            payloadDigest: Data(SHA256.hash(data: encrypted)),
            generationID: nil
        )
        let data = try encoder.encode(envelope)
        return data
    }

    private func assertEmptySnapshot(_ snapshot: TaptionDataSnapshot) {
        XCTAssertEqual(snapshot.schemaVersion, TaptionDataSnapshot.empty.schemaVersion)
        XCTAssertTrue(snapshot.plans.isEmpty)
        XCTAssertTrue(snapshot.actuals.isEmpty)
        XCTAssertTrue(snapshot.recordLinks.isEmpty)
        XCTAssertTrue(snapshot.memos.isEmpty)
        XCTAssertTrue(snapshot.travel.isEmpty)
        XCTAssertEqual(snapshot.settings.mapCategoryColors, [:])
    }
}

private enum BackupStoreTestError: Error, Equatable {
    case injected
}

private final class FailNextPlanCloudBackupStore: PlanCloudBackupStore {
    var failNextSave = false
    private(set) var archives: [String: PlanMonthlyArchive] = [:]

    func save(
        _ archive: PlanMonthlyArchive,
        at path: PlanCloudBackupPath
    ) throws {
        if failNextSave {
            failNextSave = false
            throw BackupStoreTestError.injected
        }
        archives[path.monthKey] = archive
    }

    func delete(at path: PlanCloudBackupPath) throws {
        archives[path.monthKey] = nil
    }

    func latest() throws -> PlanMonthlyArchive? {
        archives.values.max { $0.monthKey < $1.monthKey }
    }

    func allArchives() throws -> [PlanMonthlyArchive] {
        Array(archives.values)
    }

    func deleteAll() throws {
        archives.removeAll()
    }
}

private final class CommitThenCancelAndFailRollbackBackupStore:
    PlanCloudBackupStore {
    private let base = InMemoryPlanCloudBackupStore()
    private let cancelAfterSaveNumber: Int
    private let failSaveNumber: Int?
    private let failReadbackAfterSaveNumber: Int?
    private var saveCount = 0

    init(
        cancelAfterSaveNumber: Int,
        failSaveNumber: Int? = nil,
        failReadbackAfterSaveNumber: Int? = nil
    ) {
        self.cancelAfterSaveNumber = cancelAfterSaveNumber
        self.failSaveNumber = failSaveNumber
        self.failReadbackAfterSaveNumber = failReadbackAfterSaveNumber
    }

    func save(
        _ archive: PlanMonthlyArchive,
        at path: PlanCloudBackupPath
    ) throws {
        saveCount += 1
        if let failSaveNumber, saveCount == failSaveNumber {
            throw BackupStoreTestError.injected
        }
        try base.save(archive, at: path)
        if saveCount == cancelAfterSaveNumber {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    func delete(at path: PlanCloudBackupPath) throws {
        try base.delete(at: path)
    }

    func latest() throws -> PlanMonthlyArchive? {
        try base.latest()
    }

    func allArchives() throws -> [PlanMonthlyArchive] {
        if let failReadbackAfterSaveNumber,
           saveCount >= failReadbackAfterSaveNumber {
            throw BackupStoreTestError.injected
        }
        return try base.allArchives()
    }

    func deleteAll() throws {
        try base.deleteAll()
    }
}

private final class FailingPlanCredentialStore: PlanCredentialStore {
    func read() throws -> Data? { nil }

    func write(_ data: Data) throws {
        throw PlanSecurityError.invalidCredential
    }
}

private final class ArchiveChangesBetweenReadsStore: PlanCloudBackupStore {
    private let replacement: PlanMonthlyArchive
    private var readCount = 0
    private(set) var saveCount = 0

    init(replacement: PlanMonthlyArchive) {
        self.replacement = replacement
    }

    func save(
        _ archive: PlanMonthlyArchive,
        at path: PlanCloudBackupPath
    ) throws {
        saveCount += 1
    }

    func delete(at path: PlanCloudBackupPath) throws {}

    func latest() throws -> PlanMonthlyArchive? {
        try allArchives().first
    }

    func allArchives() throws -> [PlanMonthlyArchive] {
        readCount += 1
        return readCount == 1 ? [] : [replacement]
    }

    func deleteAll() throws {}
}

@MainActor
private final class GatedPlanCloudRecoveryKeyProvider:
    PlanCloudRecoveryKeyProvider {
    private var continuation: CheckedContinuation<Data, Never>?
    private(set) var keyWasRequested = false

    func key() async throws -> Data {
        keyWasRequested = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume(returning: Data(repeating: 9, count: 32))
        continuation = nil
    }
}

private actor RawSensorRestoreLoadGate {
    private var hasStarted = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startedWaiter = continuation
        }
    }

    func suspendLoad() async {
        hasStarted = true
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class GatedPlanCloudRawSensorBackupStore:
    PlanCloudRawSensorBackupStore, @unchecked Sendable {
    private let base = InMemoryPlanCloudRawSensorBackupStore()
    private let gate = RawSensorRestoreLoadGate()

    func save(
        _ archive: PlanRawSensorMonthlyArchive,
        at path: PlanCloudRawSensorBackupPath
    ) throws {
        try base.save(archive, at: path)
    }

    func delete(at path: PlanCloudRawSensorBackupPath) throws {
        try base.delete(at: path)
    }

    func latest() throws -> PlanRawSensorMonthlyArchive? {
        try base.latest()
    }

    func allArchives() throws -> [PlanRawSensorMonthlyArchive] {
        try base.allArchives()
    }

    func load(
        monthKey: String,
        generationID: UUID?
    ) throws -> PlanRawSensorMonthlyArchive? {
        try base.load(monthKey: monthKey, generationID: generationID)
    }

    @MainActor
    func loadForRestore(
        monthKey: String,
        generationID: UUID?,
        byteBudget: PlanCloudArchiveRestoreByteBudget
    ) async throws -> PlanRawSensorMonthlyArchive? {
        guard let archive = try base.load(
            monthKey: monthKey,
            generationID: generationID
        ) else {
            return nil
        }
        await gate.suspendLoad()
        let fileSize = try makePlanJSONEncoder().encode(archive).count
        return try byteBudget.read(fileSize: fileSize) {
            (archive, fileSize)
        }
    }

    func deleteAll() throws {
        try base.deleteAll()
    }

    func waitUntilRestoreStarts() async {
        await gate.waitUntilStarted()
    }

    func releaseRestore() async {
        await gate.release()
    }
}

private final class BackupDeletionFenceTestState {
    var rawArchiveWasWritten = false
    var snapshotArchiveWasWritten = false
    var snapshotReadsAfterRawWrite = 0
    var advancedGeneration: UInt64?
}

private final class DeletionFenceTestRawSensorBackupStore:
    PlanCloudRawSensorBackupStore {
    private let base = InMemoryPlanCloudRawSensorBackupStore()
    private let state: BackupDeletionFenceTestState
    private let advanceOnLoad: Bool
    private let advanceAfterSave: Bool
    private(set) var saveCount = 0

    init(
        state: BackupDeletionFenceTestState,
        advanceOnLoad: Bool = false,
        advanceAfterSave: Bool = false
    ) {
        self.state = state
        self.advanceOnLoad = advanceOnLoad
        self.advanceAfterSave = advanceAfterSave
    }

    func save(
        _ archive: PlanRawSensorMonthlyArchive,
        at path: PlanCloudRawSensorBackupPath
    ) throws {
        try base.save(archive, at: path)
        saveCount += 1
        state.rawArchiveWasWritten = true
        if advanceAfterSave, state.advancedGeneration == nil {
            state.advancedGeneration = TaptionDataDeletionFence.advance()
        }
    }

    func delete(at path: PlanCloudRawSensorBackupPath) throws {
        try base.delete(at: path)
    }

    func latest() throws -> PlanRawSensorMonthlyArchive? {
        try base.latest()
    }

    func allArchives() throws -> [PlanRawSensorMonthlyArchive] {
        try base.allArchives()
    }

    func load(
        monthKey: String,
        generationID: UUID?
    ) throws -> PlanRawSensorMonthlyArchive? {
        let archive = try base.load(
            monthKey: monthKey,
            generationID: generationID
        )
        if advanceOnLoad, state.advancedGeneration == nil {
            state.advancedGeneration = TaptionDataDeletionFence.advance()
        }
        return archive
    }

    func deleteAll() throws {
        try base.deleteAll()
    }
}

private final class DeletionFenceTestBackupStore: PlanCloudBackupStore {
    private let base = InMemoryPlanCloudBackupStore()
    private let state: BackupDeletionFenceTestState
    private let advanceAfterRawWriteOnRead: Int
    private let advanceOnSave: Bool
    private let advanceDuringPostSaveRead: Bool
    private(set) var saveCount = 0
    var onSave: (() -> Void)?

    var archives: [String: PlanMonthlyArchive] { base.archives }

    init(
        state: BackupDeletionFenceTestState,
        advanceAfterRawWriteOnRead: Int,
        advanceOnSave: Bool = false,
        advanceDuringPostSaveRead: Bool = false
    ) {
        self.state = state
        self.advanceAfterRawWriteOnRead = advanceAfterRawWriteOnRead
        self.advanceOnSave = advanceOnSave
        self.advanceDuringPostSaveRead = advanceDuringPostSaveRead
    }

    func save(_ archive: PlanMonthlyArchive, at path: PlanCloudBackupPath) throws {
        saveCount += 1
        try base.save(archive, at: path)
        state.snapshotArchiveWasWritten = true
        onSave?()
        if advanceOnSave, state.advancedGeneration == nil {
            state.advancedGeneration = TaptionDataDeletionFence.advance()
        }
    }

    func delete(at path: PlanCloudBackupPath) throws {
        try base.delete(at: path)
    }

    func latest() throws -> PlanMonthlyArchive? {
        try base.latest()
    }

    func allArchives() throws -> [PlanMonthlyArchive] {
        let archives = try base.allArchives()
        if advanceDuringPostSaveRead,
           state.snapshotArchiveWasWritten,
           state.advancedGeneration == nil {
            state.advancedGeneration = TaptionDataDeletionFence.advance()
        }
        if state.rawArchiveWasWritten {
            state.snapshotReadsAfterRawWrite += 1
            if state.snapshotReadsAfterRawWrite == advanceAfterRawWriteOnRead,
               state.advancedGeneration == nil {
                state.advancedGeneration = TaptionDataDeletionFence.advance()
            }
        }
        return archives
    }

    func deleteAll() throws {
        try base.deleteAll()
    }
}

private final class CancelsCurrentTaskOnRawArchiveLoad:
    PlanCloudRawSensorBackupStore {
    private let base: InMemoryPlanCloudRawSensorBackupStore
    private var didCancel = false

    init(base: InMemoryPlanCloudRawSensorBackupStore) {
        self.base = base
    }

    func save(
        _ archive: PlanRawSensorMonthlyArchive,
        at path: PlanCloudRawSensorBackupPath
    ) throws {
        try base.save(archive, at: path)
    }

    func delete(at path: PlanCloudRawSensorBackupPath) throws {
        try base.delete(at: path)
    }

    func latest() throws -> PlanRawSensorMonthlyArchive? {
        try base.latest()
    }

    func allArchives() throws -> [PlanRawSensorMonthlyArchive] {
        try base.allArchives()
    }

    func load(
        monthKey: String,
        generationID: UUID?
    ) throws -> PlanRawSensorMonthlyArchive? {
        let archive = try base.load(
            monthKey: monthKey,
            generationID: generationID
        )
        if !didCancel {
            didCancel = true
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return archive
    }

    func deleteAll() throws {
        try base.deleteAll()
    }
}

private final class CancelsCurrentTaskAfterRawArchiveSave:
    PlanCloudRawSensorBackupStore {
    private let base = InMemoryPlanCloudRawSensorBackupStore()
    private let cancelAfterSaveNumber: Int
    private var saveCount = 0

    init(cancelAfterSaveNumber: Int = 1) {
        self.cancelAfterSaveNumber = cancelAfterSaveNumber
    }

    func save(
        _ archive: PlanRawSensorMonthlyArchive,
        at path: PlanCloudRawSensorBackupPath
    ) throws {
        try base.save(archive, at: path)
        saveCount += 1
        guard saveCount == cancelAfterSaveNumber else { return }
        withUnsafeCurrentTask { $0?.cancel() }
    }

    func delete(at path: PlanCloudRawSensorBackupPath) throws {
        try base.delete(at: path)
    }

    func latest() throws -> PlanRawSensorMonthlyArchive? {
        try base.latest()
    }

    func allArchives() throws -> [PlanRawSensorMonthlyArchive] {
        try base.allArchives()
    }

    func load(
        monthKey: String,
        generationID: UUID?
    ) throws -> PlanRawSensorMonthlyArchive? {
        try base.load(monthKey: monthKey, generationID: generationID)
    }

    func deleteAll() throws {
        try base.deleteAll()
    }
}

private final class FailOncePlanCloudRawSensorBackupStore:
    PlanCloudRawSensorBackupStore {
    private var failsNextSave = true
    private(set) var archives: [String: PlanRawSensorMonthlyArchive] = [:]

    func save(
        _ archive: PlanRawSensorMonthlyArchive,
        at path: PlanCloudRawSensorBackupPath
    ) throws {
        if failsNextSave {
            failsNextSave = false
            throw BackupStoreTestError.injected
        }
        archives[path.monthKey] = archive
    }

    func delete(at path: PlanCloudRawSensorBackupPath) throws {
        archives[path.monthKey] = nil
    }

    func latest() throws -> PlanRawSensorMonthlyArchive? {
        archives.values.max { $0.monthKey < $1.monthKey }
    }

    func allArchives() throws -> [PlanRawSensorMonthlyArchive] {
        Array(archives.values)
    }

    func deleteAll() throws {
        archives.removeAll()
    }
}

private final class DeleteFailingRawSensorBackupStore:
    PlanCloudRawSensorBackupStore {
    func save(
        _ archive: PlanRawSensorMonthlyArchive,
        at path: PlanCloudRawSensorBackupPath
    ) throws {}

    func delete(at path: PlanCloudRawSensorBackupPath) throws {}
    func latest() throws -> PlanRawSensorMonthlyArchive? { nil }
    func allArchives() throws -> [PlanRawSensorMonthlyArchive] { [] }
    func deleteAll() throws { throw BackupStoreTestError.injected }
}

private final class CountingRawSensorRestoreBackupStore:
    PlanCloudRawSensorBackupStore, @unchecked Sendable {
    private let base = InMemoryPlanCloudRawSensorBackupStore()
    private var fileSizes: [String: Int] = [:]
    private(set) var restoreReadMonthKeys: [String] = []

    func save(
        _ archive: PlanRawSensorMonthlyArchive,
        at path: PlanCloudRawSensorBackupPath
    ) throws {
        let fileSize = try makePlanJSONEncoder().encode(archive).count
        fileSizes[path.relativePath] = fileSize
        try base.save(archive, at: path)
    }

    func delete(at path: PlanCloudRawSensorBackupPath) throws {
        try base.delete(at: path)
    }

    func latest() throws -> PlanRawSensorMonthlyArchive? {
        try base.latest()
    }

    func allArchives() throws -> [PlanRawSensorMonthlyArchive] {
        try base.allArchives()
    }

    func load(
        monthKey: String,
        generationID: UUID?
    ) throws -> PlanRawSensorMonthlyArchive? {
        try base.load(monthKey: monthKey, generationID: generationID)
    }

    @MainActor
    func loadForRestore(
        monthKey: String,
        generationID: UUID?,
        byteBudget: PlanCloudArchiveRestoreByteBudget
    ) async throws -> PlanRawSensorMonthlyArchive? {
        let path = PlanCloudRawSensorBackupPath(
            monthKey: monthKey,
            generationID: generationID
        )
        guard let fileSize = fileSizes[path.relativePath] else {
            return nil
        }
        return try byteBudget.read(fileSize: fileSize) {
            let archive = try base.load(
                monthKey: monthKey,
                generationID: generationID
            )
            if archive != nil { restoreReadMonthKeys.append(monthKey) }
            return (archive, archive == nil ? 0 : fileSize)
        }
    }

    func deleteAll() throws {
        try base.deleteAll()
    }
}
