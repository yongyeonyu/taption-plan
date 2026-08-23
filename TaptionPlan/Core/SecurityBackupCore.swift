import CryptoKit
import CloudKit
import Foundation
import LocalAuthentication
import Security

/// The local gate is deliberately separate from normal app use.  A PIN is a
/// cloud-backup credential; it is not an app-login credential unless the user
/// explicitly enables an app lock.
struct PlanPINVerifier: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let iterations = 120_000

    let version: Int
    let salt: Data
    let digest: Data

    init(pin: String, random: (Int) -> Data = { count in
        var data = Data(repeating: 0, count: count)
        _ = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        return data
    }) throws {
        guard Self.isValid(pin) else { throw PlanSecurityError.invalidPIN }
        let salt = random(16)
        guard salt.count == 16 else { throw PlanSecurityError.invalidCredential }
        self.version = Self.currentVersion
        self.salt = salt
        self.digest = Self.derive(pin: pin, salt: salt)
    }

    func matches(_ pin: String) -> Bool {
        guard Self.isValid(pin) else { return false }
        return Self.constantTimeEqual(digest, Self.derive(pin: pin, salt: salt))
    }

    /// PBKDF output is retained only as a verifier and key-encryption key; the
    /// four digit PIN itself never leaves the call stack.
    var keyMaterial: Data { digest }

    static func isValid(_ pin: String) -> Bool {
        pin.utf8.count == 4 && pin.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func derive(pin: String, salt: Data) -> Data {
        var value = Data(pin.utf8) + salt
        for _ in 0..<iterations {
            value = Data(SHA256.hash(data: value))
        }
        return value
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
}

extension PlanSecurityError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidPIN:
            "4자리 숫자 비밀번호를 다시 확인해 주세요."
        case .invalidCredential:
            "보안 자격 증명을 확인하지 못했습니다."
        case .pinRequiredForCloudBackup:
            "이 기능을 사용하려면 4자리 비밀번호를 먼저 등록해 주세요."
        case .invalidArchive:
            "백업 파일의 암호화 또는 무결성을 확인하지 못했습니다."
        case .archiveNotFound:
            "불러올 iCloud 백업이 없습니다."
        case .accountUnavailable:
            "iCloud 계정을 확인한 뒤 다시 시도해 주세요."
        case .accountMismatch:
            "이 백업을 만든 iCloud 계정과 다릅니다."
        case .biometricUnavailable:
            "Face ID 또는 Touch ID를 사용할 수 없습니다."
        case .biometricRejected:
            "생체 인증을 완료하지 못했습니다."
        case .tooManyAttempts:
            "입력 횟수가 많습니다. 잠시 뒤 다시 시도해 주세요."
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
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
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
    let failedAttempts: Int
    let retryAfter: Date?
}

struct PlanCloudBackupPath: Equatable, Sendable {
    let monthKey: String
    /// The user-visible location in Files. Each month is one encrypted file,
    /// rather than a folder containing an unprotected JSON payload.
    var components: [String] {
        ["iCloud Drive", "Taption Plan", "\(monthKey).taptionbackup"]
    }
    var relativePath: String { components.joined(separator: "/") }
    var storageComponents: [String] {
        ["Taption Plan", "\(monthKey).taptionbackup"]
    }
}

struct PlanMonthlyArchive: Codable, Equatable, Sendable {
    static let currentVersion = 1
    let version: Int
    let monthKey: String
    let accountIdentifier: String
    let createdAt: Date
    let encryptedPayload: Data
    let wrappedPayloadKey: Data
    let accountWrappedPayloadKey: Data
    let payloadDigest: Data

    init(monthKey: String, accountIdentifier: String, encryptedPayload: Data, wrappedPayloadKey: Data, accountWrappedPayloadKey: Data, createdAt: Date = .now) {
        self.version = Self.currentVersion
        self.monthKey = monthKey
        self.accountIdentifier = accountIdentifier
        self.createdAt = createdAt
        self.encryptedPayload = encryptedPayload
        self.wrappedPayloadKey = wrappedPayloadKey
        self.accountWrappedPayloadKey = accountWrappedPayloadKey
        self.payloadDigest = Data(SHA256.hash(data: encryptedPayload))
    }

    func decodedSnapshot(pinKeyData: Data? = nil, accountKeyData: Data? = nil) throws -> TaptionDataSnapshot {
        guard version == Self.currentVersion,
              payloadDigest == Data(SHA256.hash(data: encryptedPayload)) else {
            throw PlanSecurityError.invalidArchive
        }
        let archiveKey: Data
        if let pinKeyData {
            archiveKey = try Self.openKey(wrappedPayloadKey, with: pinKeyData)
        } else if let accountKeyData {
            archiveKey = try Self.openKey(accountWrappedPayloadKey, with: accountKeyData)
        } else {
            throw PlanSecurityError.invalidArchive
        }
        guard archiveKey.count == 32 else { throw PlanSecurityError.invalidArchive }
        do {
            let sealed = try AES.GCM.SealedBox(combined: encryptedPayload)
            let compressed = try AES.GCM.open(
                sealed,
                using: SymmetricKey(data: archiveKey)
            )
            let data = TaptionSnapshotCompression.decode(compressed)
            return try JSONDecoder.taptionPlan.decode(
                TaptionDataSnapshot.self,
                from: data
            )
        } catch { throw PlanSecurityError.invalidArchive }
    }

    private static func openKey(_ wrapped: Data, with keyData: Data) throws -> Data {
        guard keyData.count == 32 else { throw PlanSecurityError.invalidArchive }
        let sealed = try AES.GCM.SealedBox(combined: wrapped)
        return try AES.GCM.open(sealed, using: SymmetricKey(data: keyData))
    }
}

protocol PlanCloudAccountKeyProvider: AnyObject {
    /// Implementations must bind the key to the authenticated iCloud account.
    /// A different account must throw instead of generating a new key.
    func key(for accountIdentifier: String) throws -> Data
}

/// iCloud Drive carries the encrypted monthly archive. The recovery key is
/// stored separately in CloudKit's private database, so it is readable only
/// by the same signed-in iCloud account on a replacement device.
@MainActor
protocol PlanCloudRecoveryKeyProvider: AnyObject {
    func key() async throws -> Data
}

@MainActor
final class CloudKitPlanCloudRecoveryKeyProvider: PlanCloudRecoveryKeyProvider {
    static let privateAccountScope = "icloud-private-v1"
    private static let recordType = "TaptionBackupRecoveryKey"
    private static let recordName = "taption-backup-recovery-key-v1"
    private static let valueKey = "keyEnvelopeBytes"
    private let container: CKContainer
    private let database: CKDatabase
    private let documentFallback: UbiquitousPlanCloudRecoveryKeyStore

    init(
        container: CKContainer = CKContainer(identifier: "iCloud.com.taption.plan"),
        documentFallback: UbiquitousPlanCloudRecoveryKeyStore = .init()
    ) {
        self.container = container
        database = container.privateCloudDatabase
        self.documentFallback = documentFallback
    }

    func key() async throws -> Data {
        guard try await container.accountStatus() == .available else {
            throw PlanSecurityError.accountUnavailable
        }
        if let stored = try documentFallback.existingKey() {
            return stored
        }
        let recordID = CKRecord.ID(recordName: Self.recordName)
        do {
            let record = try await database.record(for: recordID)
            guard let existing = record[Self.valueKey] as? Data,
                  existing.count == 32 else {
                throw PlanSecurityError.accountUnavailable
            }
            return existing
        } catch let error as CKError where error.code == .unknownItem {
            let generated = Self.randomKey()
            let record = CKRecord(recordType: Self.recordType, recordID: recordID)
            record[Self.valueKey] = generated as CKRecordValue
            do {
                _ = try await database.save(record)
                return generated
            } catch let saveError as CKError
            where saveError.code == .serverRecordChanged {
                let existing = try await database.record(for: recordID)
                guard let value = existing[Self.valueKey] as? Data,
                      value.count == 32 else {
                    throw PlanSecurityError.accountUnavailable
                }
                return value
            } catch {
                guard Self.isProductionSchemaRejection(error) else { throw error }
                return try documentFallback.store(generated)
            }
        } catch {
            throw PlanSecurityError.accountUnavailable
        }
    }

    private static func isProductionSchemaRejection(_ error: Error) -> Bool {
        let value = diagnosticMessage(for: error).lowercased()
        return value.contains("production schema")
            && value.contains(valueKey.lowercased())
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
        return values.joined(separator: " ")
    }

    private static func randomKey() -> Data {
        var key = Data(repeating: 0, count: 32)
        guard key.withUnsafeMutableBytes({
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }) == errSecSuccess else {
            return Data()
        }
        return key
    }
}

final class UbiquitousPlanCloudRecoveryKeyStore {
    private let containerIdentifier: String
    private let fileManager: FileManager
    private let containerURL: URL?
    private let fileName = ".recovery-key-v1"

    init(
        containerIdentifier: String = "iCloud.com.taption.plan",
        fileManager: FileManager = .default,
        containerURL: URL? = nil
    ) {
        self.containerIdentifier = containerIdentifier
        self.fileManager = fileManager
        self.containerURL = containerURL
    }

    func existingKey() throws -> Data? {
        guard let fileURL = try recoveryKeyURL(createDirectory: false) else { return nil }
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let value = try Data(contentsOf: fileURL)
        guard value.count == 32 else { throw PlanSecurityError.invalidArchive }
        return value
    }

    func store(_ key: Data) throws -> Data {
        guard key.count == 32 else { throw PlanSecurityError.accountUnavailable }
        guard let fileURL = try recoveryKeyURL(createDirectory: true) else {
            throw PlanSecurityError.accountUnavailable
        }
        if let stored = try existingKey() { return stored }
        try key.write(to: fileURL, options: .atomic)
        return key
    }

    private func recoveryKeyURL(createDirectory: Bool) throws -> URL? {
        guard let container = containerURL ?? fileManager.url(
            forUbiquityContainerIdentifier: containerIdentifier
        ) else { return nil }
        let directory = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Taption Plan", isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }
}

@MainActor
final class InMemoryPlanCloudRecoveryKeyProvider: PlanCloudRecoveryKeyProvider {
    private var value: Data?

    func key() async throws -> Data {
        if let value { return value }
        let generated = Data(repeating: 9, count: 32)
        value = generated
        return generated
    }
}

final class InMemoryPlanCloudAccountKeyProvider: PlanCloudAccountKeyProvider {
    private var keys: [String: Data] = [:]
    func key(for accountIdentifier: String) throws -> Data {
        guard !accountIdentifier.isEmpty else { throw PlanSecurityError.accountUnavailable }
        if let key = keys[accountIdentifier] { return key }
        var key = Data(repeating: 0, count: 32)
        _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        keys[accountIdentifier] = key
        return key
    }
}

protocol PlanCloudBackupStore: AnyObject {
    func save(_ archive: PlanMonthlyArchive, at path: PlanCloudBackupPath) throws
    func latest() throws -> PlanMonthlyArchive?
}

final class FilePlanCloudBackupStore: PlanCloudBackupStore {
    private let root: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    func save(_ archive: PlanMonthlyArchive, at path: PlanCloudBackupPath) throws {
        let destination = path.storageComponents.reduce(root) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.taptionPlan.encode(archive)
        try data.write(
            to: destination,
            options: [.atomic, .completeFileProtection]
        )
    }

    func latest() throws -> PlanMonthlyArchive? {
        let root = root.appendingPathComponent("Taption Plan", isDirectory: true)
        guard let months = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        return try months.compactMap { month in
            guard month.pathExtension == "taptionbackup",
                  let data = try? Data(contentsOf: month) else { return nil }
            return try JSONDecoder.taptionPlan.decode(PlanMonthlyArchive.self, from: data)
        }.max { $0.monthKey < $1.monthKey }
    }
}

/// Cloud Documents is the authoritative monthly-backup location. There is no
/// local fallback: if the iCloud account is unavailable, backup and recovery
/// report that state instead of claiming a device-only file is cloud data.
final class UbiquitousPlanCloudBackupStore: PlanCloudBackupStore {
    private let containerIdentifier: String
    private let fileManager: FileManager

    init(
        containerIdentifier: String = "iCloud.com.taption.plan",
        fileManager: FileManager = .default
    ) {
        self.containerIdentifier = containerIdentifier
        self.fileManager = fileManager
    }

    func save(_ archive: PlanMonthlyArchive, at path: PlanCloudBackupPath) throws {
        try fileStore().save(archive, at: path)
    }

    func latest() throws -> PlanMonthlyArchive? {
        try fileStore().latest()
    }

    private func fileStore() throws -> FilePlanCloudBackupStore {
        guard let container = fileManager.url(
            forUbiquityContainerIdentifier: containerIdentifier
        ) else {
            throw PlanSecurityError.accountUnavailable
        }
        let documents = container.appendingPathComponent(
            "Documents",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: documents,
            withIntermediateDirectories: true
        )
        return FilePlanCloudBackupStore(root: documents, fileManager: fileManager)
    }
}

final class InMemoryPlanCloudBackupStore: PlanCloudBackupStore {
    private(set) var archives: [String: PlanMonthlyArchive] = [:]
    func save(_ archive: PlanMonthlyArchive, at path: PlanCloudBackupPath) throws { archives[path.monthKey] = archive }
    func latest() throws -> PlanMonthlyArchive? {
        archives.values.max { $0.monthKey < $1.monthKey }
    }
}

enum PlanArchiveSchedule {
    static func monthKey(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    static func monthsBetween(_ start: Date, _ end: Date, calendar: Calendar = .autoupdatingCurrent) -> [String] {
        let startMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: start)) ?? start
        let endMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: end)) ?? end
        guard startMonth <= endMonth else { return [] }
        var result: [String] = []
        var cursor = startMonth
        while cursor <= endMonth {
            result.append(monthKey(for: cursor, calendar: calendar))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }
}

@MainActor
final class PlanSecurityBackupService {
    private let credentialStore: PlanCredentialStore
    private let backupStore: PlanCloudBackupStore
    private let accountKeyProvider: PlanCloudAccountKeyProvider
    private let cloudRecoveryKeyProvider: PlanCloudRecoveryKeyProvider?
    private let biometricAuthenticator: PlanLocalBiometricAuthenticator
    private let settingsDefaults: UserDefaults
    private let settingsKey = "TaptionPlan.security.app-lock-settings-v1"
    private var verifier: PlanPINVerifier?
    private var failedAttempts = 0
    private var blockedUntil: Date?
    private(set) var settings: PlanAppLockSettings
    private(set) var state: PlanAppLockState = .unlocked

    init(
        credentialStore: PlanCredentialStore = KeychainPlanCredentialStore(),
        backupStore: PlanCloudBackupStore,
        accountKeyProvider: PlanCloudAccountKeyProvider = InMemoryPlanCloudAccountKeyProvider(),
        cloudRecoveryKeyProvider: PlanCloudRecoveryKeyProvider? = nil,
        biometricAuthenticator: PlanLocalBiometricAuthenticator = SystemPlanLocalBiometricAuthenticator(),
        settingsDefaults: UserDefaults = .standard
    ) {
        self.credentialStore = credentialStore
        self.backupStore = backupStore
        self.accountKeyProvider = accountKeyProvider
        self.cloudRecoveryKeyProvider = cloudRecoveryKeyProvider
        self.biometricAuthenticator = biometricAuthenticator
        self.settingsDefaults = settingsDefaults
        self.verifier = (try? credentialStore.read()).flatMap { try? JSONDecoder().decode(PlanPINVerifier.self, from: $0) }
        if let data = settingsDefaults.data(forKey: settingsKey),
           let value = try? JSONDecoder().decode(PlanAppLockSettings.self, from: data) {
            self.settings = value
        } else {
            self.settings = PlanAppLockSettings()
        }
    }

    static func applicationSupport(fileManager: FileManager = .default) throws -> PlanSecurityBackupService {
        PlanSecurityBackupService(
            backupStore: UbiquitousPlanCloudBackupStore(fileManager: fileManager),
            cloudRecoveryKeyProvider: CloudKitPlanCloudRecoveryKeyProvider()
        )
    }

    var hasPIN: Bool { verifier != nil }
    var status: PlanSecurityStatus { .init(settings: settings, state: state, hasPIN: hasPIN, failedAttempts: failedAttempts, retryAfter: blockedUntil) }

    func setPIN(_ pin: String) throws {
        let value = try PlanPINVerifier(pin: pin)
        let data = try JSONEncoder().encode(value)
        try credentialStore.write(data)
        verifier = value
        failedAttempts = 0
        blockedUntil = nil
    }

    func verifyPIN(_ pin: String, now: Date = .now) throws {
        if let blockedUntil, blockedUntil > now { throw PlanSecurityError.tooManyAttempts(retryAfter: blockedUntil.timeIntervalSince(now)) }
        guard let verifier, verifier.matches(pin) else {
            failedAttempts += 1
            if failedAttempts >= 5 { blockedUntil = now.addingTimeInterval(30) }
            throw PlanSecurityError.invalidPIN
        }
        failedAttempts = 0
        blockedUntil = nil
        state = .unlocked
    }

    func setAppLockSettings(_ value: PlanAppLockSettings) throws {
        if (value.lockOnLaunch || value.lockOnForeground || value.cloudBackupEnabled)
            && !hasPIN {
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
        guard await biometricAuthenticator.authenticate(reason: "Taption Plan 잠금 해제") else {
            throw PlanSecurityError.biometricRejected
        }
        state = .unlocked
    }

    func saveMonthlyArchive(_ snapshot: TaptionDataSnapshot, accountIdentifier: String, date: Date = .now) throws -> PlanMonthlyArchive {
        guard hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        guard !accountIdentifier.isEmpty else { throw PlanSecurityError.accountUnavailable }
        let accountKey = try accountKeyProvider.key(for: accountIdentifier)
        return try saveMonthlyArchive(
            snapshot,
            accountIdentifier: accountIdentifier,
            accountKey: accountKey,
            date: date
        )
    }

    func saveMonthlyArchive(
        _ snapshot: TaptionDataSnapshot,
        date: Date = .now
    ) async throws -> PlanMonthlyArchive {
        guard hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        return try saveMonthlyArchive(
            snapshot,
            accountIdentifier: CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope,
            accountKey: nil,
            date: date
        )
    }

    private func saveMonthlyArchive(
        _ snapshot: TaptionDataSnapshot,
        accountIdentifier: String,
        accountKey: Data?,
        date: Date
    ) throws -> PlanMonthlyArchive {
        let payload = try JSONEncoder.taptionPlan.encode(snapshot)
        let compressed = TaptionSnapshotCompression.encode(payload)
        let archiveKey = Self.randomKey()
        let encryptedPayload = try AES.GCM.seal(
            compressed,
            using: SymmetricKey(data: archiveKey)
        ).combined ?? { throw PlanSecurityError.invalidArchive }()
        let pinKey = SymmetricKey(data: verifier!.keyMaterial)
        let wrappedPayloadKey = try AES.GCM.seal(archiveKey, using: pinKey).combined ?? { throw PlanSecurityError.invalidArchive }()
        let accountWrappedPayloadKey: Data
        if let accountKey {
            guard accountKey.count == 32 else { throw PlanSecurityError.accountUnavailable }
            accountWrappedPayloadKey = try AES.GCM.seal(archiveKey, using: SymmetricKey(data: accountKey)).combined ?? { throw PlanSecurityError.invalidArchive }()
        } else {
            accountWrappedPayloadKey = Data()
        }
        let archive = PlanMonthlyArchive(monthKey: PlanArchiveSchedule.monthKey(for: date), accountIdentifier: accountIdentifier, encryptedPayload: encryptedPayload, wrappedPayloadKey: wrappedPayloadKey, accountWrappedPayloadKey: accountWrappedPayloadKey, createdAt: date)
        try backupStore.save(archive, at: PlanCloudBackupPath(monthKey: archive.monthKey))
        return archive
    }

    func loadLatestArchive(accountIdentifier: String) throws -> TaptionDataSnapshot {
        guard hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        guard let verifier else { throw PlanSecurityError.pinRequiredForCloudBackup }
        return try loadLatestArchiveWithoutPIN(accountIdentifier: accountIdentifier, pinKeyData: verifier.keyMaterial)
    }

    func loadLatestArchive() async throws -> TaptionDataSnapshot {
        guard hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        return try loadLatestArchiveWithoutPIN(
            accountIdentifier: CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope,
            pinKeyData: verifier?.keyMaterial
        )
    }

    /// PIN loss and biometric changes are recoverable only when iCloud still
    /// identifies the same account. Recovery writes a replacement verifier;
    /// it never silently clears data or resets the account.
    func recoverLatestArchive(accountIdentifier: String, newPIN: String) throws -> TaptionDataSnapshot {
        guard !accountIdentifier.isEmpty else { throw PlanSecurityError.accountUnavailable }
        let snapshot = try loadLatestArchiveWithoutPIN(accountIdentifier: accountIdentifier, accountKeyData: try accountKeyProvider.key(for: accountIdentifier))
        try setPIN(newPIN)
        return snapshot
    }

    func recoverLatestArchive(newPIN: String) async throws -> TaptionDataSnapshot {
        guard let cloudRecoveryKeyProvider else {
            throw PlanSecurityError.accountUnavailable
        }
        let accountKey = try await cloudRecoveryKeyProvider.key()
        let snapshot: TaptionDataSnapshot
        do {
            snapshot = try loadLatestArchiveWithoutPIN(
                accountIdentifier: CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope,
                accountKeyData: accountKey
            )
        } catch PlanSecurityError.invalidArchive {
            throw PlanSecurityError.accountMismatch
        }
        try setPIN(newPIN)
        return snapshot
    }

    private func loadLatestArchiveWithoutPIN(accountIdentifier: String, pinKeyData: Data? = nil, accountKeyData: Data? = nil) throws -> TaptionDataSnapshot {
        guard !accountIdentifier.isEmpty else { throw PlanSecurityError.accountUnavailable }
        guard let archive = try backupStore.latest() else { throw PlanSecurityError.archiveNotFound }
        guard archive.accountIdentifier == accountIdentifier else { throw PlanSecurityError.accountMismatch }
        return try archive.decodedSnapshot(pinKeyData: pinKeyData, accountKeyData: accountKeyData)
    }

    private static func randomKey() -> Data {
        var key = Data(repeating: 0, count: 32)
        _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return key
    }
}

private extension JSONEncoder {
    static var taptionPlan: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

private extension JSONDecoder {
    static var taptionPlan: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
