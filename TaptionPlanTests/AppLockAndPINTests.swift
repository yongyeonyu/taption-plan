import CommonCrypto
import CryptoKit
import XCTest
@testable import TaptionPlan

/// 비밀번호(6자리, 이전 4자리 호환)·앱 잠금·생체 인증·시도 횟수 제한. 이전 백업 엔진과 무관하게 유지해야 하는 동작이다.
@MainActor
final class AppLockAndPINTests: XCTestCase {
    private func makeService(
        credentials: PlanCredentialStore = InMemoryPlanCredentialStore(),
        biometric: PlanLocalBiometricAuthenticator = MockPlanLocalBiometricAuthenticator(),
        defaults: UserDefaults? = nil
    ) -> (PlanSecurityService, UserDefaults) {
        let suite = "AppLockAndPINTests.\(UUID().uuidString)"
        let store = defaults ?? UserDefaults(suiteName: suite)!
        addTeardownBlock { store.removePersistentDomain(forName: suite) }
        return (
            PlanSecurityService(credentialStore: credentials, biometricAuthenticator: biometric, settingsDefaults: store),
            store
        )
    }

    func testPasswordIsRememberedOnThisDeviceAfterRegistrationAndVerification() throws {
        let remembered = InMemoryPlanCredentialStore()
        let suite = "AppLockAndPINTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let credentials = InMemoryPlanCredentialStore()
        let service = PlanSecurityService(
            credentialStore: credentials, passwordStore: remembered, settingsDefaults: defaults
        )
        XCTAssertNil(service.rememberedPassword)
        try service.setPIN("123456")
        XCTAssertEqual(service.rememberedPassword, "123456")
        try service.setPIN("654321")
        XCTAssertEqual(service.rememberedPassword, "654321", "비밀번호를 바꾸면 보관값도 바뀐다")
        XCTAssertThrowsError(try service.verifyPIN("111111", unlocking: false))
        XCTAssertEqual(service.rememberedPassword, "654321", "틀린 값은 보관하지 않는다")

        // 보관 항목이 비어 있는 기존 사용자: 올바른 비밀번호를 한 번 확인하면 보관된다.
        let migrated = PlanSecurityService(
            credentialStore: credentials, passwordStore: InMemoryPlanCredentialStore(), settingsDefaults: defaults
        )
        XCTAssertTrue(migrated.hasPIN)
        XCTAssertNil(migrated.rememberedPassword)
        try migrated.verifyPIN("654321", unlocking: false)
        XCTAssertEqual(migrated.rememberedPassword, "654321")
    }

    func testBiometricAttemptGateRunsOncePerLockGeneration() {
        XCTAssertTrue(AppLockBiometricAttemptGate.shouldStart(generation: 1, attemptedGeneration: nil, isInFlight: false))
        XCTAssertFalse(AppLockBiometricAttemptGate.shouldStart(generation: 1, attemptedGeneration: 1, isInFlight: false))
        XCTAssertFalse(AppLockBiometricAttemptGate.shouldStart(generation: 1, attemptedGeneration: nil, isInFlight: true))
        XCTAssertTrue(AppLockBiometricAttemptGate.shouldStart(generation: 2, attemptedGeneration: 1, isInFlight: false))
    }

    func testPINVerifierStoresOnlySaltAndDigestAndUsesSixDigits() throws {
        let verifier = try PlanPINVerifier(pin: "123456") { _ in Data(repeating: 7, count: 16) }
        XCTAssertEqual(verifier.version, PlanPINVerifier.currentVersion)
        XCTAssertEqual(verifier.salt, Data(repeating: 7, count: 16))
        XCTAssertEqual(verifier.digits, 6)
        XCTAssertEqual(verifier.pinLength, 6)
        XCTAssertNotEqual(verifier.digest, Data("123456".utf8))
        XCTAssertTrue(verifier.matches("123456"))
        XCTAssertFalse(verifier.matches("123457"))
        XCTAssertFalse(verifier.matches("1234"), "6자리 검증 정보는 4자리를 받지 않는다")
        XCTAssertThrowsError(try PlanPINVerifier(pin: "1234"), "새로 등록하는 4자리는 거부한다")
        XCTAssertThrowsError(try PlanPINVerifier(pin: "12345"))
        XCTAssertThrowsError(try PlanPINVerifier(pin: "1234567"))
        XCTAssertThrowsError(try PlanPINVerifier(pin: "12a456"))
        let reloaded = try JSONDecoder().decode(PlanPINVerifier.self, from: JSONEncoder().encode(verifier))
        XCTAssertEqual(reloaded, verifier)
        XCTAssertEqual(reloaded.pinLength, 6)
    }

    func testStoredFourDigitVerifierKeepsUnlockingWithoutADigitsField() throws {
        // 자릿수 필드가 없던 이전 저장본(PBKDF2 v2, 4자리)도 그대로 풀려야 한다.
        let salt = Data(repeating: 9, count: 16)
        let probe = try PlanPINVerifier(pin: "123456") { _ in salt }
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(probe)) as? [String: Any]
        )
        object["digits"] = nil
        var digest = Data(count: 32)
        let status = digest.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                "1234".withCString { password in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2), password, 4,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(PlanPINVerifier.pbkdf2Iterations),
                        out.bindMemory(to: UInt8.self).baseAddress, 32
                    )
                }
            }
        }
        XCTAssertEqual(status, Int32(kCCSuccess))
        object["digest"] = digest.base64EncodedString()
        let legacy = try JSONDecoder().decode(
            PlanPINVerifier.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacy.digits)
        XCTAssertEqual(legacy.pinLength, 4)
        XCTAssertTrue(legacy.matches("1234"))
        XCTAssertFalse(legacy.matches("123456"))

        // 서비스도 4자리 저장본으로 잠금을 풀고 자릿수를 4로 보고한다.
        let credentials = InMemoryPlanCredentialStore(
            value: try JSONEncoder().encode(PlanCredentialRecord(verifier: legacy, failedAttempts: 0, blockedUntil: nil))
        )
        let (service, _) = makeService(credentials: credentials)
        XCTAssertEqual(service.status.pinDigits, 4)
        try service.verifyPIN("1234")
    }

    func testPINVerifierRejectsRandomGenerationFailure() {
        XCTAssertThrowsError(
            try PlanPINVerifier(pin: "123490") { _ in throw PlanSecurityError.invalidCredential }
        ) { error in
            XCTAssertEqual(error as? PlanSecurityError, .invalidCredential)
        }
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
        let verifier = try JSONDecoder().decode(PlanPINVerifier.self, from: encoded)
        XCTAssertTrue(verifier.matches("1234"))
        XCTAssertFalse(verifier.matches("1235"))
    }

    func testSecurityErrorsFollowTheSelectedLanguage() {
        XCTAssertEqual(
            PlanSecurityError.invalidPIN.localizedDescription(preference: .english),
            "Check your 6-digit PIN and try again."
        )
        XCTAssertEqual(
            PlanSecurityError.biometricRejected.localizedDescription(preference: .korean),
            "생체 인증을 완료하지 못했습니다."
        )
    }

    func testAppLockRequiresPINAndLocksOnForeground() throws {
        let (service, _) = makeService()
        XCTAssertFalse(service.status.hasPIN)
        XCTAssertThrowsError(
            try service.setAppLockSettings(.init(lockOnLaunch: false, lockOnForeground: true))
        ) { error in
            XCTAssertEqual(error as? PlanSecurityError, .pinRequiredForCloudBackup)
        }
        try service.setPIN("123490")
        try service.setAppLockSettings(.init(lockOnLaunch: false, lockOnForeground: true))
        service.handleForeground()
        XCTAssertNotEqual(service.status.state, .unlocked)
        try service.unlock(withPIN: "123490")
        XCTAssertEqual(service.status.state, .unlocked)
    }

    func testAppLockAttemptThrottlePersistsAcrossServiceRecreation() throws {
        let credentials = InMemoryPlanCredentialStore()
        let (first, defaults) = makeService(credentials: credentials)
        try first.setPIN("123490")
        let blockedAt = Date(timeIntervalSince1970: 10_000)
        for _ in 0..<5 {
            XCTAssertThrowsError(try first.verifyPIN("000090", now: blockedAt))
        }

        let (replacement, _) = makeService(credentials: credentials, defaults: defaults)
        XCTAssertThrowsError(try replacement.verifyPIN("123490", now: blockedAt.addingTimeInterval(1))) { error in
            guard case .tooManyAttempts = error as? PlanSecurityError else {
                return XCTFail("Expected persisted PIN throttle, got \(error)")
            }
        }
        try replacement.verifyPIN("123490", now: blockedAt.addingTimeInterval(31))

        let (reset, _) = makeService(credentials: credentials, defaults: defaults)
        XCTAssertEqual(reset.status.failedAttempts, 0)
        XCTAssertNil(reset.status.retryAfter)
    }

    func testVerifyWithoutUnlockingKeepsTheLock() throws {
        let (service, _) = makeService()
        try service.setPIN("123490")
        try service.setAppLockSettings(.init(lockOnLaunch: true, lockOnForeground: false))
        service.handleLaunch()
        try service.verifyPIN("123490", unlocking: false)
        XCTAssertNotEqual(service.status.state, .unlocked)
    }

    func testBiometricGateUnlocksWithoutExposingRawBiometric() async throws {
        let (service, _) = makeService(biometric: MockPlanLocalBiometricAuthenticator(result: true))
        try service.setPIN("123490")
        try service.setAppLockSettings(.init(lockOnLaunch: true, lockOnForeground: false, biometricUnlockEnabled: true))
        service.handleLaunch()
        XCTAssertNotEqual(service.status.state, .unlocked)
        try await service.unlockWithBiometrics()
        XCTAssertEqual(service.status.state, .unlocked)
    }

    func testDisabledBiometricFallsBackToPINWhileLocked() async throws {
        let (service, _) = makeService(biometric: MockPlanLocalBiometricAuthenticator(result: true))
        try service.setPIN("123490")
        try service.setAppLockSettings(.init(lockOnLaunch: true, lockOnForeground: false, biometricUnlockEnabled: false))
        service.handleLaunch()
        do {
            try await service.unlockWithBiometrics()
            XCTFail("Disabled biometrics must not unlock the app")
        } catch {
            XCTAssertEqual(error as? PlanSecurityError, .biometricUnavailable)
        }
        XCTAssertNotEqual(service.status.state, .unlocked)
        try service.unlock(withPIN: "123490")
        XCTAssertEqual(service.status.state, .unlocked)
    }

    func testRejectedBiometricKeepsTheLock() async throws {
        let (service, _) = makeService(biometric: MockPlanLocalBiometricAuthenticator(result: false))
        try service.setPIN("123490")
        try service.setAppLockSettings(.init(lockOnLaunch: true, lockOnForeground: false, biometricUnlockEnabled: true))
        service.handleLaunch()
        do {
            try await service.unlockWithBiometrics()
            XCTFail("A rejected biometric must not unlock")
        } catch {
            XCTAssertEqual(error as? PlanSecurityError, .biometricRejected)
        }
        XCTAssertNotEqual(service.status.state, .unlocked)
    }

    func testLocalMonthsToKeepDefaultsToTwoAndPersistsClamped() {
        let (service, defaults) = makeService()
        XCTAssertEqual(service.status.localMonthsToKeep, 2)
        service.setLocalMonthsToKeep(5)
        XCTAssertEqual(service.localMonthsToKeep, 5)
        service.setLocalMonthsToKeep(0)
        XCTAssertEqual(service.localMonthsToKeep, 1)
        service.setLocalMonthsToKeep(99)
        XCTAssertEqual(service.localMonthsToKeep, 12)
        let (reloaded, _) = makeService(defaults: defaults)
        XCTAssertEqual(reloaded.localMonthsToKeep, 12)
    }

    func testOldAppLockSettingsWithRemovedAutomaticBackupKeysStillDecode() throws {
        let data = Data(#"{"lockOnLaunch":true,"lockOnForeground":false,"biometricUnlockEnabled":true,"cloudBackupEnabled":true,"midnightBackupEnabled":true}"#.utf8)
        let settings = try JSONDecoder().decode(PlanAppLockSettings.self, from: data)
        XCTAssertEqual(settings, PlanAppLockSettings(lockOnLaunch: true, lockOnForeground: false, biometricUnlockEnabled: true))
    }
}
