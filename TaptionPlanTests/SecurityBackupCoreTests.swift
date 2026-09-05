import CryptoKit
import XCTest
@testable import TaptionPlan

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
        XCTAssertEqual(try rawStore.allArchives(), [raw])

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
        XCTAssertEqual(generation.rawSensors?.monthKey, "2026-08")
        XCTAssertEqual(generation.snapshot.generationID, generation.generationID)
        XCTAssertEqual(generation.rawSensors?.generationID, generation.generationID)
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

    func testMonthlyGenerationIgnoresRawWhenSnapshotCommitFails()
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
        XCTAssertNotEqual(
            rawStore.archives["2026-08"]?.generationID,
            first.generationID
        )
        XCTAssertEqual(service.status.latestSuccessfulBackupDate, firstDate)
        let restored = try await service.loadLatestBackupPackage()
        XCTAssertEqual(restored.rawSensorState, .unavailable)
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

    func testRawSensorArchiveKeepsOnlyLocationAndWeatherData() async throws {
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
        XCTAssertEqual(decoded.watchAccelerationChunks, [])
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

    func testBackupPackageCombinesRawSensorArchivesAcrossMonths() throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore
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
        _ = try service.saveRawSensorArchive(
            PlanCloudRawSensorPayload(
                monthKey: "2026-04",
                sensorReadings: [julyReading],
                envelopes: [envelope],
                createdAt: july
            ),
            accountIdentifier: "account-a",
            date: july
        )
        _ = try service.saveRawSensorArchive(
            PlanCloudRawSensorPayload(
                monthKey: "2026-05",
                sensorReadings: [julyReading, augustReading],
                createdAt: august
            ),
            accountIdentifier: "account-a",
            date: august
        )
        _ = try service.saveMonthlyArchive(
            .empty,
            accountIdentifier: "account-a",
            date: august
        )

        let restored = try service.loadLatestBackupPackage(
            accountIdentifier: "account-a"
        )
        guard case .available(let rawSensors) = restored.rawSensorState else {
            return XCTFail("Raw sensor archives must be restorable")
        }
        XCTAssertEqual(
            rawSensors.sensorReadings.map(\.id),
            [julyReading.id, augustReading.id]
        )
        XCTAssertTrue(rawSensors.envelopes.isEmpty)
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

    func testRawRestoreRejectsConflictingIDsAcrossMonths() throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore
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
        _ = try service.saveRawSensorArchive(
            PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [SensorReading(
                    id: id,
                    timestamp: july,
                    point: point
                )],
                createdAt: july
            ),
            accountIdentifier: "account-a",
            date: july
        )
        _ = try service.saveRawSensorArchive(
            PlanCloudRawSensorPayload(
                monthKey: "ignored",
                sensorReadings: [SensorReading(
                    id: id,
                    timestamp: august,
                    point: point
                )],
                createdAt: august
            ),
            accountIdentifier: "account-a",
            date: august
        )
        _ = try service.saveMonthlyArchive(
            .empty,
            accountIdentifier: "account-a",
            date: august
        )

        XCTAssertEqual(
            try service.loadLatestBackupPackage(
                accountIdentifier: "account-a"
            ).rawSensorState,
            .invalidArchive
        )
    }

    func testBackupPackageReportsCorruptedRawArchiveSeparately() throws {
        let backupStore = InMemoryPlanCloudBackupStore()
        let rawStore = InMemoryPlanCloudRawSensorBackupStore()
        let service = makeService(
            backupStore: backupStore,
            rawSensorBackupStore: rawStore
        )
        try service.setPIN("1234")
        let date = Date(timeIntervalSince1970: 1_787_538_400)
        _ = try service.saveMonthlyArchive(
            .empty,
            accountIdentifier: "account-a",
            date: date
        )
        let corrupted = PlanRawSensorMonthlyArchive(
            monthKey: "2026-08",
            accountIdentifier: "account-a",
            encryptedPayload: Data([0x01]),
            wrappedPayloadKey: Data([0x02]),
            accountWrappedPayloadKey: Data(),
            createdAt: date
        )
        try rawStore.save(
            corrupted,
            at: PlanCloudRawSensorBackupPath(monthKey: "2026-08")
        )

        let restored = try service.loadLatestBackupPackage(
            accountIdentifier: "account-a"
        )
        assertEmptySnapshot(restored.backup.snapshot)
        XCTAssertEqual(restored.rawSensorState, .invalidArchive)
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

    func testLegacySnapshotArchiveStillDecodes() throws {
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
        let encrypted = try AES.GCM.seal(
            compressed,
            using: SymmetricKey(data: archiveKey)
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
            createdAt: Date(timeIntervalSince1970: 1_787_538_400)
        )

        XCTAssertEqual(
            try archive.decodedPayload(pinKeyData: verifier.keyMaterial)
                .snapshot.settings.userTransitLocations,
            snapshot.settings.userTransitLocations
        )
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
