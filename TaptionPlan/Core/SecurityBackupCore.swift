import CryptoKit
import CloudKit
import CommonCrypto
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

    let version: Int
    let salt: Data
    let digest: Data

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
        guard Self.isValid(pin) else { throw PlanSecurityError.invalidPIN }
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
    }

    func matches(_ pin: String) -> Bool {
        guard Self.isValid(pin),
              let candidate = Self.derive(
                pin: pin,
                salt: salt,
                version: version
              ) else { return false }
        return Self.constantTimeEqual(digest, candidate)
    }

    /// PBKDF output is retained only as a verifier and key-encryption key; the
    /// four digit PIN itself never leaves the call stack.
    var keyMaterial: Data { digest }

    static func isValid(_ pin: String) -> Bool {
        pin.utf8.count == 4 && pin.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
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
                korean: "4자리 숫자 비밀번호를 다시 확인해 주세요.",
                english: "Check your 4-digit PIN and try again.",
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
                korean: "이 기능을 사용하려면 4자리 비밀번호를 먼저 등록해 주세요.",
                english: "Set a 4-digit PIN before using this feature.",
                preference: preference
            )
        case .invalidArchive:
            AppLanguagePreference.text(
                korean: "백업 파일의 암호화 또는 무결성을 확인하지 못했습니다.",
                english: "The backup encryption or integrity check failed.",
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

struct PlanBackupRoutePoint: Codable, Equatable, Sendable {
    let sensorReading: SensorReading

    init?(_ reading: SensorReading) {
        guard reading.point != nil else { return nil }
        sensorReading = reading
    }

    var id: UUID { sensorReading.id }
}

struct PlanCloudBackupPayload: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let snapshot: TaptionDataSnapshot
    let routePoints: [PlanBackupRoutePoint]
    let portableContent: TaptionPlanStorageEnvelopeV2?

    init(
        snapshot: TaptionDataSnapshot,
        routePoints: [PlanBackupRoutePoint] = []
    ) {
        version = Self.currentVersion
        self.snapshot = snapshot
        self.routePoints = routePoints
        portableContent = try? Self.makePortableContent(from: snapshot)
    }

    private static func makePortableContent(
        from snapshot: TaptionDataSnapshot
    ) throws -> TaptionPlanStorageEnvelopeV2 {
        var mediaByID: [String: TaptionPlanMediaReference] = [:]
        for photo in snapshot.photos {
            mediaByID[photo.id] = TaptionPlanMediaReference(
                id: photo.id,
                localIdentifier: photo.id,
                capturedAt: photo.capturedAt
            )
        }
        var links: [TaptionPlanContentLink] = []
        let memos = try snapshot.memos.map { memo in
            var linkedMediaIDs = Set<String>()
            let mediaIDs = memo.attachments.compactMap { attachment -> String? in
                guard attachment.kind == .photo else { return nil }
                let id = attachment.localIdentifier
                guard linkedMediaIDs.insert(id).inserted else { return nil }
                if mediaByID[id] == nil {
                    mediaByID[id] = TaptionPlanMediaReference(
                        id: id,
                        localIdentifier: id,
                        capturedAt: attachment.createdAt
                    )
                }
                links.append(
                    TaptionPlanContentLink(
                        from: .memo(memo.id),
                        to: .media(id)
                    )
                )
                return id
            }
            return try TaptionPlanMemoRecord(
                id: memo.id,
                occurredAt: memo.occurredAt,
                text: memo.text,
                mediaReferenceIDs: mediaIDs,
                createdAt: memo.createdAt,
                updatedAt: memo.updatedAt
            )
        }
        let account = TaptionPlanExternalCalendarAccountIdentity(
            provider: .apple,
            accountID: "eventkit.local"
        )
        let calendars = snapshot.settings.selectedCalendarIDs.map {
            TaptionPlanExternalCalendarIdentity(
                account: account,
                calendarID: $0
            )
        }
        return try TaptionPlanStorageEnvelopeV2(
            updatedAt: snapshot.updatedAt,
            userContent: TaptionPlanUserContent(memos: memos),
            externalCalendarPreferences: TaptionPlanExternalCalendarPreferences(
                preferredProvider: calendars.isEmpty ? nil : .apple,
                selectedCalendars: calendars
            ),
            mediaReferences: mediaByID.values.sorted { $0.id < $1.id },
            contentLinks: links
        )
    }
}

enum PlanBackupRoutePointReducer {
    static let minimumInterval: TimeInterval = 10
    static let maximumCount = 60_000

    static func backupSpan(
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> TimeSpan {
        let start = calendar.dateInterval(of: .month, for: date)?.start
            ?? date.addingTimeInterval(-31 * 86_400)
        return TimeSpan(
            start: start,
            end: date.addingTimeInterval(5 * 60)
        )
    }

    static func reduce(_ readings: [SensorReading]) -> [PlanBackupRoutePoint] {
        let candidates = readings
            .filter { $0.point != nil }
            .sorted { $0.timestamp < $1.timestamp }
        guard !candidates.isEmpty else { return [] }

        var retained: [SensorReading] = []
        retained.reserveCapacity(min(candidates.count, maximumCount))
        for reading in candidates {
            guard let previous = retained.last else {
                retained.append(reading)
                continue
            }
            guard let previousPoint = previous.point,
                  let point = reading.point else { continue }
            let elapsed = reading.timestamp.timeIntervalSince(previous.timestamp)
            let moved = distanceMeters(previousPoint, point) >= 25
            if elapsed >= minimumInterval || moved
                || reading.behavior != previous.behavior {
                retained.append(reading)
            }
        }
        if let last = candidates.last, retained.last?.id != last.id {
            retained.append(last)
        }
        if retained.count > maximumCount {
            let stride = Double(retained.count - 1) / Double(maximumCount - 1)
            retained = (0..<maximumCount).map {
                retained[Int((Double($0) * stride).rounded())]
            }
        }
        return retained.compactMap(PlanBackupRoutePoint.init)
    }

    static func merging(
        existing: [PlanBackupRoutePoint],
        incoming: [PlanBackupRoutePoint]
    ) -> [PlanBackupRoutePoint] {
        var readingsByID: [UUID: SensorReading] = [:]
        for point in existing {
            readingsByID[point.id] = point.sensorReading
        }
        for point in incoming {
            readingsByID[point.id] = point.sensorReading
        }
        return reduce(Array(readingsByID.values))
    }

    static func restoring(
        _ archives: [[PlanBackupRoutePoint]]
    ) -> [PlanBackupRoutePoint] {
        var pointsByID: [UUID: PlanBackupRoutePoint] = [:]
        for points in archives {
            for point in points {
                pointsByID[point.id] = point
            }
        }
        return pointsByID.values.sorted {
            $0.sensorReading.timestamp < $1.sensorReading.timestamp
        }
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

    func decodedPayload(
        pinKeyData: Data? = nil,
        accountKeyData: Data? = nil
    ) throws -> PlanCloudBackupPayload {
        guard version == Self.currentVersion,
              payloadDigest == Data(SHA256.hash(data: encryptedPayload)) else {
            throw PlanSecurityError.invalidArchive
        }
        var archiveKeys: [Data] = []
        if let pinKeyData,
           let key = try? Self.openKey(wrappedPayloadKey, with: pinKeyData) {
            archiveKeys.append(key)
        }
        if let accountKeyData,
           let key = try? Self.openKey(
               accountWrappedPayloadKey,
               with: accountKeyData
           ), !archiveKeys.contains(key) {
            archiveKeys.append(key)
        }
        for archiveKey in archiveKeys where archiveKey.count == 32 {
            guard let payload = try? decodePayload(archiveKey: archiveKey) else {
                continue
            }
            return payload
        }
        throw PlanSecurityError.invalidArchive
    }

    private func decodePayload(
        archiveKey: Data
    ) throws -> PlanCloudBackupPayload {
        let sealed = try AES.GCM.SealedBox(combined: encryptedPayload)
        let compressed = try AES.GCM.open(
            sealed,
            using: SymmetricKey(data: archiveKey)
        )
        let data = TaptionSnapshotCompression.decode(compressed)
        if let payload = try? JSONDecoder.taptionPlan.decode(
            PlanCloudBackupPayload.self,
            from: data
        ), payload.version == PlanCloudBackupPayload.currentVersion {
            return payload
        }
        return PlanCloudBackupPayload(
            snapshot: try JSONDecoder.taptionPlan.decode(
                TaptionDataSnapshot.self,
                from: data
            )
        )
    }

    func decodedSnapshot(
        pinKeyData: Data? = nil,
        accountKeyData: Data? = nil
    ) throws -> TaptionDataSnapshot {
        try decodedPayload(
            pinKeyData: pinKeyData,
            accountKeyData: accountKeyData
        ).snapshot
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

/// iCloud Drive carries the encrypted monthly archive. The recovery key lives
/// in the account's private CloudKit database, with an account-scoped hidden
/// iCloud Drive fallback for production-schema recovery.
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
        let fallbackKey = try? documentFallback.existingKey()
        let accountStatus: CKAccountStatus
        do {
            accountStatus = try await container.accountStatus()
        } catch {
            if let fallbackKey { return fallbackKey }
            throw error
        }
        guard accountStatus == .available else {
            throw PlanSecurityError.accountUnavailable
        }
        let recordID = CKRecord.ID(recordName: Self.recordName)
        do {
            let record = try await database.record(for: recordID)
            guard let existing = record[Self.valueKey] as? Data,
                  existing.count == 32 else {
                throw PlanSecurityError.accountUnavailable
            }
            try? documentFallback.save(existing)
            return existing
        } catch let error as CKError where error.code == .unknownItem {
            let generated = try fallbackKey ?? Self.randomKey()
            let record = CKRecord(recordType: Self.recordType, recordID: recordID)
            record[Self.valueKey] = generated as CKRecordValue
            do {
                _ = try await database.save(record)
                try? documentFallback.save(generated)
                return generated
            } catch let saveError as CKError
            where saveError.code == .serverRecordChanged {
                let existing = try await database.record(for: recordID)
                guard let value = existing[Self.valueKey] as? Data,
                      value.count == 32 else {
                    throw PlanSecurityError.accountUnavailable
                }
                try? documentFallback.save(value)
                return value
            } catch {
                if Self.isProductionSchemaRejection(error) {
                    try documentFallback.save(generated)
                    return generated
                }
                if let fallbackKey { return fallbackKey }
                throw error
            }
        } catch {
            if Self.isProductionSchemaRejection(error) {
                let generated = try fallbackKey ?? Self.randomKey()
                try documentFallback.save(generated)
                return generated
            }
            if let fallbackKey { return fallbackKey }
            throw error
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

    private static func randomKey() throws -> Data {
        var key = Data(repeating: 0, count: 32)
        guard key.withUnsafeMutableBytes({
            guard let baseAddress = $0.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
        }) == errSecSuccess else {
            throw PlanSecurityError.accountUnavailable
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

    func save(_ key: Data) throws {
        guard key.count == 32,
              let fileURL = try recoveryKeyURL(createDirectory: true) else {
            throw PlanSecurityError.accountUnavailable
        }
        try key.write(
            to: fileURL,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
    }

    func removeExistingKey() throws {
        guard let fileURL = try recoveryKeyURL(createDirectory: false),
              fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
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
        let status = key.withUnsafeMutableBytes { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
        }
        guard status == errSecSuccess else {
            throw PlanSecurityError.accountUnavailable
        }
        keys[accountIdentifier] = key
        return key
    }
}

protocol PlanCloudBackupStore: AnyObject {
    func save(_ archive: PlanMonthlyArchive, at path: PlanCloudBackupPath) throws
    func latest() throws -> PlanMonthlyArchive?
    func allArchives() throws -> [PlanMonthlyArchive]
}

extension PlanCloudBackupStore {
    func allArchives() throws -> [PlanMonthlyArchive] {
        try latest().map { [$0] } ?? []
    }
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
        try allArchives().max { $0.monthKey < $1.monthKey }
    }

    func allArchives() throws -> [PlanMonthlyArchive] {
        let root = root.appendingPathComponent("Taption Plan", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ) else { return [] }
        guard isDirectory.boolValue else {
            throw PlanSecurityError.invalidArchive
        }
        let months = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        return try months.compactMap { month in
            guard month.pathExtension == "taptionbackup" else { return nil }
            let data = try Data(contentsOf: month)
            return try JSONDecoder.taptionPlan.decode(PlanMonthlyArchive.self, from: data)
        }
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

    func allArchives() throws -> [PlanMonthlyArchive] {
        try fileStore().allArchives()
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

    func allArchives() throws -> [PlanMonthlyArchive] {
        Array(archives.values)
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
#if targetEnvironment(simulator)
        PlanSecurityBackupService(
            backupStore: UbiquitousPlanCloudBackupStore(fileManager: fileManager)
        )
#else
        PlanSecurityBackupService(
            backupStore: UbiquitousPlanCloudBackupStore(fileManager: fileManager),
            cloudRecoveryKeyProvider: CloudKitPlanCloudRecoveryKeyProvider()
        )
#endif
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
        let reason = AppLanguagePreference.text(
            korean: "Taption Plan 잠금 해제",
            english: "Unlock Taption Plan"
        )
        guard await biometricAuthenticator.authenticate(reason: reason) else {
            throw PlanSecurityError.biometricRejected
        }
        state = .unlocked
    }

    func saveMonthlyArchive(_ snapshot: TaptionDataSnapshot, accountIdentifier: String, date: Date = .now) throws -> PlanMonthlyArchive {
        try saveMonthlyArchive(
            PlanCloudBackupPayload(snapshot: snapshot),
            accountIdentifier: accountIdentifier,
            date: date
        )
    }

    func saveMonthlyArchive(
        _ payload: PlanCloudBackupPayload,
        accountIdentifier: String,
        date: Date = .now
    ) throws -> PlanMonthlyArchive {
        guard hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        guard !accountIdentifier.isEmpty else { throw PlanSecurityError.accountUnavailable }
        let accountKey = try accountKeyProvider.key(for: accountIdentifier)
        return try saveMonthlyArchive(
            payload,
            accountIdentifier: accountIdentifier,
            accountKey: accountKey,
            date: date
        )
    }

    func saveMonthlyArchive(
        _ snapshot: TaptionDataSnapshot,
        date: Date = .now
    ) async throws -> PlanMonthlyArchive {
        try await saveMonthlyArchive(
            PlanCloudBackupPayload(snapshot: snapshot),
            date: date
        )
    }

    func saveMonthlyArchive(
        _ payload: PlanCloudBackupPayload,
        date: Date = .now
    ) async throws -> PlanMonthlyArchive {
        guard hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        guard let cloudRecoveryKeyProvider else {
            throw PlanSecurityError.accountUnavailable
        }
        let accountKey = try await cloudRecoveryKeyProvider.key()
        return try saveMonthlyArchive(
            payload,
            accountIdentifier: CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope,
            accountKey: accountKey,
            date: date
        )
    }

    private func saveMonthlyArchive(
        _ payload: PlanCloudBackupPayload,
        accountIdentifier: String,
        accountKey: Data?,
        date: Date
    ) throws -> PlanMonthlyArchive {
        guard let verifier else {
            throw PlanSecurityError.pinRequiredForCloudBackup
        }
        let monthKey = PlanArchiveSchedule.monthKey(for: date)
        let payload = try payloadPreservingCurrentMonthRoutes(
            payload,
            monthKey: monthKey,
            accountIdentifier: accountIdentifier,
            pinKeyData: verifier.keyMaterial,
            accountKeyData: accountKey
        )
        let encoded = try JSONEncoder.taptionPlan.encode(payload)
        let compressed = TaptionSnapshotCompression.encode(encoded)
        let archiveKey = try Self.randomKey()
        let encryptedPayload = try AES.GCM.seal(
            compressed,
            using: SymmetricKey(data: archiveKey)
        ).combined ?? { throw PlanSecurityError.invalidArchive }()
        let pinKey = SymmetricKey(data: verifier.keyMaterial)
        let wrappedPayloadKey = try AES.GCM.seal(archiveKey, using: pinKey).combined ?? { throw PlanSecurityError.invalidArchive }()
        let accountWrappedPayloadKey: Data
        if let accountKey {
            guard accountKey.count == 32 else { throw PlanSecurityError.accountUnavailable }
            accountWrappedPayloadKey = try AES.GCM.seal(archiveKey, using: SymmetricKey(data: accountKey)).combined ?? { throw PlanSecurityError.invalidArchive }()
        } else {
            accountWrappedPayloadKey = Data()
        }
        let archive = PlanMonthlyArchive(monthKey: monthKey, accountIdentifier: accountIdentifier, encryptedPayload: encryptedPayload, wrappedPayloadKey: wrappedPayloadKey, accountWrappedPayloadKey: accountWrappedPayloadKey, createdAt: date)
        try backupStore.save(archive, at: PlanCloudBackupPath(monthKey: archive.monthKey))
        return archive
    }

    private func payloadPreservingCurrentMonthRoutes(
        _ incoming: PlanCloudBackupPayload,
        monthKey: String,
        accountIdentifier: String,
        pinKeyData: Data,
        accountKeyData: Data?
    ) throws -> PlanCloudBackupPayload {
        guard let existingArchive = try backupStore.allArchives().first(
            where: { $0.monthKey == monthKey }
        ) else {
            return incoming
        }
        guard existingArchive.accountIdentifier == accountIdentifier else {
            throw PlanSecurityError.accountMismatch
        }

        let existing: PlanCloudBackupPayload
        do {
            existing = try existingArchive.decodedPayload(
                pinKeyData: pinKeyData
            )
        } catch {
            guard let accountKeyData else { throw error }
            existing = try existingArchive.decodedPayload(
                accountKeyData: accountKeyData
            )
        }
        return PlanCloudBackupPayload(
            snapshot: incoming.snapshot,
            routePoints: PlanBackupRoutePointReducer.merging(
                existing: existing.routePoints,
                incoming: incoming.routePoints
            )
        )
    }

    func loadLatestArchive(accountIdentifier: String) throws -> TaptionDataSnapshot {
        try loadLatestBackup(accountIdentifier: accountIdentifier).snapshot
    }

    func loadLatestBackup(
        accountIdentifier: String
    ) throws -> PlanCloudBackupPayload {
        guard hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        guard let verifier else { throw PlanSecurityError.pinRequiredForCloudBackup }
        return try loadLatestBackup(
            accountIdentifier: accountIdentifier,
            pinKeyData: verifier.keyMaterial
        )
    }

    func loadLatestArchive() async throws -> TaptionDataSnapshot {
        try await loadLatestBackup().snapshot
    }

    func loadLatestBackup() async throws -> PlanCloudBackupPayload {
        guard hasPIN else { throw PlanSecurityError.pinRequiredForCloudBackup }
        let accountIdentifier =
            CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope
        do {
            return try loadLatestBackup(
                accountIdentifier: accountIdentifier,
                pinKeyData: verifier?.keyMaterial
            )
        } catch PlanSecurityError.invalidArchive {
            guard let cloudRecoveryKeyProvider else {
                throw PlanSecurityError.accountUnavailable
            }
            let accountKey = try await cloudRecoveryKeyProvider.key()
            let payload = try loadLatestBackup(
                accountIdentifier: accountIdentifier,
                accountKeyData: accountKey
            )
            let currentMonth = PlanBackupRoutePointReducer.backupSpan(
                containing: .now
            )
            _ = try? saveMonthlyArchive(
                PlanCloudBackupPayload(
                    snapshot: payload.snapshot,
                    routePoints: payload.routePoints.filter {
                        currentMonth.contains($0.sensorReading.timestamp)
                    }
                ),
                accountIdentifier: accountIdentifier,
                accountKey: accountKey,
                date: .now
            )
            return payload
        }
    }

    /// PIN loss and biometric changes are recoverable only when iCloud still
    /// identifies the same account. Recovery writes a replacement verifier;
    /// it never silently clears data or resets the account.
    func recoverLatestArchive(accountIdentifier: String, newPIN: String) throws -> TaptionDataSnapshot {
        guard !accountIdentifier.isEmpty else { throw PlanSecurityError.accountUnavailable }
        let snapshot = try loadLatestBackup(
            accountIdentifier: accountIdentifier,
            accountKeyData: try accountKeyProvider.key(for: accountIdentifier)
        ).snapshot
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
            snapshot = try loadLatestBackup(
                accountIdentifier: CloudKitPlanCloudRecoveryKeyProvider.privateAccountScope,
                accountKeyData: accountKey
            ).snapshot
        } catch PlanSecurityError.invalidArchive {
            throw PlanSecurityError.accountMismatch
        }
        try setPIN(newPIN)
        return snapshot
    }

    private func loadLatestBackup(
        accountIdentifier: String,
        pinKeyData: Data? = nil,
        accountKeyData: Data? = nil
    ) throws -> PlanCloudBackupPayload {
        guard !accountIdentifier.isEmpty else { throw PlanSecurityError.accountUnavailable }
        let archives = try backupStore.allArchives().sorted {
            if $0.monthKey == $1.monthKey {
                return $0.createdAt < $1.createdAt
            }
            return $0.monthKey < $1.monthKey
        }
        guard let latest = archives.last else {
            throw PlanSecurityError.archiveNotFound
        }
        guard latest.accountIdentifier == accountIdentifier else {
            throw PlanSecurityError.accountMismatch
        }
        let latestPayload = try latest.decodedPayload(
            pinKeyData: pinKeyData,
            accountKeyData: accountKeyData
        )
        let routeArchives = try archives.map { archive -> [PlanBackupRoutePoint] in
            guard archive.accountIdentifier == accountIdentifier else {
                throw PlanSecurityError.accountMismatch
            }
            if archive == latest {
                return latestPayload.routePoints
            }
            return try archive.decodedPayload(
                pinKeyData: pinKeyData,
                accountKeyData: accountKeyData
            ).routePoints
        }
        return PlanCloudBackupPayload(
            snapshot: latestPayload.snapshot,
            routePoints: PlanBackupRoutePointReducer.restoring(routeArchives)
        )
    }

    private static func randomKey() throws -> Data {
        var key = Data(repeating: 0, count: 32)
        let status = key.withUnsafeMutableBytes { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
        }
        guard status == errSecSuccess else {
            throw PlanSecurityError.invalidArchive
        }
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
