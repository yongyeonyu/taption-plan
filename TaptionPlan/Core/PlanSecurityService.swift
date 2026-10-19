import Foundation

/// 비밀번호(6자리 숫자) 등록·검증, 앱 잠금, 생체 인증, 시도 횟수 제한, 마지막 백업 시각과 로컬 보관 달 수를 맡는다.
/// 백업 파일 자체는 `TaptionBackupEngine`이 다루며, 이 서비스는 백업 키를 저장하지 않는다.
@MainActor
final class PlanSecurityService {
    static let defaultLocalMonthsToKeep = 2
    static let localMonthsToKeepRange = 1...12
    /// 비밀번호를 5번 틀리면 잠시 막는다.
    static let attemptsBeforeDelay = 5
    static let delayAfterAttempts: TimeInterval = 30

    private let credentialStore: PlanCredentialStore
    private let biometricAuthenticator: PlanLocalBiometricAuthenticator
    private let settingsDefaults: UserDefaults
    private let settingsKey = "TaptionPlan.security.app-lock-settings-v1"
    private let latestBackupDateKey = "TaptionPlan.security.latest-successful-backup-date-v1"
    private let localMonthsKey = "TaptionPlan.backup.local-months-to-keep-v1"
    private var verifier: PlanPINVerifier?
    private var failedAttempts = 0
    private var blockedUntil: Date?
    private(set) var settings: PlanAppLockSettings
    private(set) var state: PlanAppLockState = .unlocked
    private(set) var latestSuccessfulBackupDate: Date?
    private(set) var localMonthsToKeep: Int

    init(
        credentialStore: PlanCredentialStore = KeychainPlanCredentialStore(),
        biometricAuthenticator: PlanLocalBiometricAuthenticator = SystemPlanLocalBiometricAuthenticator(),
        settingsDefaults: UserDefaults = .standard
    ) {
        self.credentialStore = credentialStore
        self.biometricAuthenticator = biometricAuthenticator
        self.settingsDefaults = settingsDefaults
        if let data = try? credentialStore.read() {
            if let record = try? JSONDecoder().decode(PlanCredentialRecord.self, from: data) {
                verifier = record.verifier
                failedAttempts = max(0, record.failedAttempts)
                blockedUntil = record.blockedUntil
            } else {
                verifier = try? JSONDecoder().decode(PlanPINVerifier.self, from: data)
            }
        }
        if let data = settingsDefaults.data(forKey: settingsKey),
           let value = try? JSONDecoder().decode(PlanAppLockSettings.self, from: data) {
            settings = value
        } else {
            settings = PlanAppLockSettings()
        }
        latestSuccessfulBackupDate = settingsDefaults.object(forKey: latestBackupDateKey) as? Date
        let stored = settingsDefaults.object(forKey: localMonthsKey) as? Int
        localMonthsToKeep = Self.clampedMonths(stored ?? Self.defaultLocalMonthsToKeep)
    }

    var hasPIN: Bool { verifier != nil }

    var status: PlanSecurityStatus {
        .init(
            settings: settings,
            state: state,
            hasPIN: hasPIN,
            pinDigits: verifier?.pinLength ?? PlanPINVerifier.currentDigits,
            failedAttempts: failedAttempts,
            retryAfter: blockedUntil,
            latestSuccessfulBackupDate: latestSuccessfulBackupDate,
            localMonthsToKeep: localMonthsToKeep
        )
    }

    func setPIN(_ pin: String) throws {
        let value = try PlanPINVerifier(pin: pin)
        let data = try JSONEncoder().encode(
            PlanCredentialRecord(verifier: value, failedAttempts: 0, blockedUntil: nil)
        )
        try credentialStore.write(data)
        verifier = value
        failedAttempts = 0
        blockedUntil = nil
    }

    /// 비밀번호를 확인한다. 틀리면 횟수를 세고 5번째부터 30초 동안 막는다. `unlocking`이면 앱 잠금도 푼다.
    func verifyPIN(_ pin: String, now: Date = .now, unlocking: Bool = true) throws {
        if let blockedUntil, blockedUntil > now {
            throw PlanSecurityError.tooManyAttempts(retryAfter: blockedUntil.timeIntervalSince(now))
        }
        guard let verifier, verifier.matches(pin) else {
            failedAttempts += 1
            if failedAttempts >= Self.attemptsBeforeDelay {
                blockedUntil = now.addingTimeInterval(Self.delayAfterAttempts)
            }
            try persistCredentialState()
            throw PlanSecurityError.invalidPIN
        }
        failedAttempts = 0
        blockedUntil = nil
        try persistCredentialState()
        if unlocking { state = .unlocked }
    }

    func setAppLockSettings(_ value: PlanAppLockSettings) throws {
        if (value.lockOnLaunch || value.lockOnForeground) && !hasPIN {
            throw PlanSecurityError.pinRequiredForCloudBackup
        }
        settings = value
        settingsDefaults.set(try? JSONEncoder().encode(value), forKey: settingsKey)
    }

    func handleLaunch() { if settings.lockOnLaunch { state = .locked(reason: .launch) } }
    func handleForeground() { if settings.lockOnForeground { state = .locked(reason: .foreground) } }

    func unlock(withPIN pin: String) throws { try verifyPIN(pin) }

    func unlockWithBiometrics() async throws {
        guard settings.biometricUnlockEnabled else { throw PlanSecurityError.biometricUnavailable }
        let reason = AppLanguagePreference.text(korean: "Taption Plan 잠금 해제", english: "Unlock Taption Plan")
        guard await biometricAuthenticator.authenticate(reason: reason) else {
            throw PlanSecurityError.biometricRejected
        }
        state = .unlocked
    }

    func recordSuccessfulBackup(at date: Date) {
        guard latestSuccessfulBackupDate.map({ date > $0 }) ?? true else { return }
        latestSuccessfulBackupDate = date
        settingsDefaults.set(date, forKey: latestBackupDateKey)
    }

    func clearLatestBackupDate() {
        latestSuccessfulBackupDate = nil
        settingsDefaults.removeObject(forKey: latestBackupDateKey)
    }

    func setLocalMonthsToKeep(_ months: Int) {
        localMonthsToKeep = Self.clampedMonths(months)
        settingsDefaults.set(localMonthsToKeep, forKey: localMonthsKey)
    }

    private static func clampedMonths(_ value: Int) -> Int {
        min(max(value, localMonthsToKeepRange.lowerBound), localMonthsToKeepRange.upperBound)
    }

    private func persistCredentialState() throws {
        guard let verifier else { return }
        try credentialStore.write(
            JSONEncoder().encode(
                PlanCredentialRecord(verifier: verifier, failedAttempts: failedAttempts, blockedUntil: blockedUntil)
            )
        )
    }
}
