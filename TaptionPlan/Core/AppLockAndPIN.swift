import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import TaptionPlanCore

/// The local gate is deliberately separate from normal app use.  A PIN is a
/// cloud-backup credential; it is not an app-login credential unless the user
/// explicitly enables an app lock.
struct PlanPINVerifier: Codable, Equatable, Sendable {
    static let currentVersion = 2
    static let legacyIterations = 120_000
    static let pbkdf2Iterations = 600_000
    /// 새로 등록하는 비밀번호 자릿수. 값이 없는 이전 저장본은 4자리로 본다.
    static let currentDigits = 6
    static let legacyDigits = 4

    let version: Int
    let salt: Data
    let digest: Data
    let digits: Int?

    /// 이 검증 정보로 풀리는 비밀번호의 자릿수.
    var pinLength: Int { digits ?? Self.legacyDigits }

    init(pin: String, random: (Int) throws -> Data = { count in
        var data = Data(repeating: 0, count: count)
        let status = data.withUnsafeMutableBytes { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw PlanSecurityError.invalidCredential
        }
        return data
    }) throws {
        guard Self.isValid(pin, digits: Self.currentDigits) else { throw PlanSecurityError.invalidPIN }
        let salt = try random(16)
        guard salt.count == 16 else { throw PlanSecurityError.invalidCredential }
        guard let digest = Self.derive(
            pin: pin,
            salt: salt,
            version: Self.currentVersion
        ) else {
            throw PlanSecurityError.invalidCredential
        }
        self.version = Self.currentVersion
        self.salt = salt
        self.digest = digest
        self.digits = Self.currentDigits
    }

    func matches(_ pin: String) -> Bool {
        guard Self.isValid(pin, digits: pinLength),
              let candidate = Self.derive(
                pin: pin,
                salt: salt,
                version: version
              ) else { return false }
        return Self.constantTimeEqual(digest, candidate)
    }

    /// PBKDF output is retained only as a verifier and key-encryption key; the
    /// PIN itself never leaves the call stack.
    var keyMaterial: Data { digest }

    static func isValid(_ pin: String, digits: Int = currentDigits) -> Bool {
        pin.utf8.count == digits && pin.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func derive(
        pin: String,
        salt: Data,
        version: Int
    ) -> Data? {
        switch version {
        case 1:
            legacyDigest(pin: pin, salt: salt)
        case currentVersion:
            pbkdf2Digest(pin: pin, salt: salt)
        default:
            nil
        }
    }

    private static func legacyDigest(pin: String, salt: Data) -> Data {
        var value = Data(pin.utf8) + salt
        for _ in 0..<legacyIterations {
            value = Data(SHA256.hash(data: value))
        }
        return value
    }

    private static func pbkdf2Digest(pin: String, salt: Data) -> Data? {
        let outputCount = 32
        var output = Data(repeating: 0, count: outputCount)
        let passwordLength = pin.lengthOfBytes(using: .utf8)
        let status = output.withUnsafeMutableBytes { outputBytes in
            salt.withUnsafeBytes { saltBytes in
                pin.withCString { password in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password,
                        passwordLength,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(pbkdf2Iterations),
                        outputBytes.bindMemory(to: UInt8.self).baseAddress,
                        outputCount
                    )
                }
            }
        }
        return status == kCCSuccess ? output : nil
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }
}

enum PlanSecurityError: Error, Equatable {
    case invalidPIN
    case invalidCredential
    case pinRequiredForCloudBackup
    case invalidArchive
    case archiveNotFound
    case accountUnavailable
    case accountMismatch
    case biometricUnavailable
    case biometricRejected
    case tooManyAttempts(retryAfter: TimeInterval)
    case localSensorArchiveIncomplete
    case backupInProgress
}

extension PlanSecurityError: LocalizedError {
    var errorDescription: String? {
        localizedDescription()
    }

    func localizedDescription(
        preference: AppLanguagePreference = .current
    ) -> String {
        switch self {
        case .invalidPIN:
            AppLanguagePreference.text(
                korean: "6자리 숫자 비밀번호를 다시 확인해 주세요.",
                english: "Check your 6-digit PIN and try again.",
                preference: preference
            )
        case .invalidCredential:
            AppLanguagePreference.text(
                korean: "보안 자격 증명을 확인하지 못했습니다.",
                english: "The security credential could not be verified.",
                preference: preference
            )
        case .pinRequiredForCloudBackup:
            AppLanguagePreference.text(
                korean: "이 기능을 사용하려면 6자리 비밀번호를 먼저 등록해 주세요.",
                english: "Set a 6-digit PIN before using this feature.",
                preference: preference
            )
        case .invalidArchive:
            AppLanguagePreference.text(
                korean: "백업 파일의 암호화 또는 무결성을 확인하지 못했습니다.",
                english: "The backup encryption or integrity check failed.",
                preference: preference
            )
        case .backupInProgress:
            AppLanguagePreference.text(korean: "백업이 이미 진행 중입니다. 완료된 뒤 다시 시도해 주세요.",
                english: "A backup is already in progress. Try again when it finishes.", preference: preference)
        case .localSensorArchiveIncomplete:
            AppLanguagePreference.text(
                korean: "기기의 일부 센서 기록을 읽지 못해 백업을 완료하지 못했습니다. 기존 기록과 백업은 보존되어 있습니다.",
                english: "Some sensor records on this device could not be read. Existing records and backups are preserved.",
                preference: preference
            )
        case .archiveNotFound:
            AppLanguagePreference.text(
                korean: "불러올 iCloud 백업이 없습니다.",
                english: "No iCloud backup is available to restore.",
                preference: preference
            )
        case .accountUnavailable:
            AppLanguagePreference.text(
                korean: "iCloud 계정을 확인한 뒤 다시 시도해 주세요.",
                english: "Check your iCloud account and try again.",
                preference: preference
            )
        case .accountMismatch:
            AppLanguagePreference.text(
                korean: "이 백업을 만든 iCloud 계정과 다릅니다.",
                english: "This is not the iCloud account that created the backup.",
                preference: preference
            )
        case .biometricUnavailable:
            AppLanguagePreference.text(
                korean: "Face ID 또는 Touch ID를 사용할 수 없습니다.",
                english: "Face ID or Touch ID is unavailable.",
                preference: preference
            )
        case .biometricRejected:
            AppLanguagePreference.text(
                korean: "생체 인증을 완료하지 못했습니다.",
                english: "Biometric authentication was not completed.",
                preference: preference
            )
        case .tooManyAttempts:
            AppLanguagePreference.text(
                korean: "입력 횟수가 많습니다. 잠시 뒤 다시 시도해 주세요.",
                english: "Too many attempts. Try again shortly.",
                preference: preference
            )
        }
    }
}

protocol PlanCredentialStore: AnyObject {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

final class KeychainPlanCredentialStore: PlanCredentialStore {
    private let service: String
    private let account: String

    init(service: String = "com.taption.plan.security", account: String = "pin-verifier-v1") {
        self.service = service
        self.account = account
    }

    func read() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PlanSecurityError.invalidCredential }
        return result as? Data
    }

    func write(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
                throw PlanSecurityError.invalidCredential
            }
        } else if status != errSecSuccess {
            throw PlanSecurityError.invalidCredential
        }
    }
}

final class InMemoryPlanCredentialStore: PlanCredentialStore {
    private var value: Data?
    init(value: Data? = nil) { self.value = value }
    func read() throws -> Data? { value }
    func write(_ data: Data) throws { value = data }
}

struct PlanCredentialRecord: Codable {
    let verifier: PlanPINVerifier
    var failedAttempts: Int
    var blockedUntil: Date?
}

protocol PlanLocalBiometricAuthenticator: AnyObject, Sendable {
    func authenticate(reason: String) async -> Bool
}

final class SystemPlanLocalBiometricAuthenticator: PlanLocalBiometricAuthenticator, @unchecked Sendable {
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        return (try? await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        )) ?? false
    }
}

final class MockPlanLocalBiometricAuthenticator: PlanLocalBiometricAuthenticator, @unchecked Sendable {
    var result: Bool
    init(result: Bool = true) { self.result = result }
    func authenticate(reason: String) async -> Bool { result }
}

struct PlanAppLockSettings: Codable, Equatable, Sendable {
    var lockOnLaunch: Bool
    var lockOnForeground: Bool
    var biometricUnlockEnabled: Bool
    /// A backup is opt-in. Turning it on requires the four-digit recovery
    /// code, but does not force an app lock for ordinary use.
    var cloudBackupEnabled: Bool
    var midnightBackupEnabled: Bool

    init(
        lockOnLaunch: Bool = false,
        lockOnForeground: Bool = false,
        biometricUnlockEnabled: Bool = false,
        cloudBackupEnabled: Bool = false,
        midnightBackupEnabled: Bool = false
    ) {
        self.lockOnLaunch = lockOnLaunch
        self.lockOnForeground = lockOnForeground
        self.biometricUnlockEnabled = biometricUnlockEnabled
        self.cloudBackupEnabled = cloudBackupEnabled
        self.midnightBackupEnabled = midnightBackupEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case lockOnLaunch
        case lockOnForeground
        case biometricUnlockEnabled
        case cloudBackupEnabled
        case midnightBackupEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lockOnLaunch: try values.decodeIfPresent(
                Bool.self,
                forKey: .lockOnLaunch
            ) ?? false,
            lockOnForeground: try values.decodeIfPresent(
                Bool.self,
                forKey: .lockOnForeground
            ) ?? false,
            biometricUnlockEnabled: try values.decodeIfPresent(
                Bool.self,
                forKey: .biometricUnlockEnabled
            ) ?? false,
            cloudBackupEnabled: try values.decodeIfPresent(
                Bool.self,
                forKey: .cloudBackupEnabled
            ) ?? false,
            midnightBackupEnabled: try values.decodeIfPresent(
                Bool.self,
                forKey: .midnightBackupEnabled
            ) ?? false
        )
    }
}

enum PlanAppLockState: Equatable, Sendable {
    case unlocked
    case locked(reason: PlanAppLockReason)
}

enum PlanAppLockReason: String, Codable, Sendable {
    case launch
    case foreground
}

struct PlanSecurityStatus: Equatable, Sendable {
    let settings: PlanAppLockSettings
    let state: PlanAppLockState
    let hasPIN: Bool
    /// 등록된 비밀번호의 자릿수(없으면 새로 등록할 자릿수).
    let pinDigits: Int
    let failedAttempts: Int
    let retryAfter: Date?
    let latestSuccessfulBackupDate: Date?
    let preservedUnmergedRawBackup: Bool
    /// 백업 뒤 로컬에 남길 최근 달 수(이번 달 포함).
    let localMonthsToKeep: Int

    init(
        settings: PlanAppLockSettings,
        state: PlanAppLockState,
        hasPIN: Bool,
        pinDigits: Int = PlanPINVerifier.currentDigits,
        failedAttempts: Int,
        retryAfter: Date?,
        latestSuccessfulBackupDate: Date? = nil,
        preservedUnmergedRawBackup: Bool = false,
        localMonthsToKeep: Int = 2
    ) {
        self.settings = settings
        self.state = state
        self.hasPIN = hasPIN
        self.pinDigits = pinDigits
        self.failedAttempts = failedAttempts
        self.retryAfter = retryAfter
        self.latestSuccessfulBackupDate = latestSuccessfulBackupDate
        self.preservedUnmergedRawBackup = preservedUnmergedRawBackup
        self.localMonthsToKeep = localMonthsToKeep
    }
}
