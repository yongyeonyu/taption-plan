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
        XCTAssertEqual(PlanArchiveSchedule.monthsBetween(start, end, calendar: calendar), ["2025-07", "2025-08", "2025-09", "2025-10"])
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

    func testLegacyCloudRecoveryKeyCanOnlyBeReadAndRemoved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UbiquitousPlanCloudRecoveryKeyStore(containerURL: directory)
        let key = Data(repeating: 7, count: 32)
        let legacyDirectory = directory
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Taption Plan", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        try key.write(
            to: legacyDirectory.appendingPathComponent(".recovery-key-v1")
        )

        XCTAssertEqual(try store.existingKey(), key)
        try store.removeExistingKey()
        XCTAssertNil(try store.existingKey())
    }

    private func makeService(
        biometric: PlanLocalBiometricAuthenticator = MockPlanLocalBiometricAuthenticator(),
        backupStore: PlanCloudBackupStore = InMemoryPlanCloudBackupStore(),
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
