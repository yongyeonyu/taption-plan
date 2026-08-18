import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum BiometricDataProtectionStatus: Equatable, Sendable {
    case unavailable
    case notProtected
    case protected(createdAt: Date)

    var isProtected: Bool {
        if case .protected = self { return true }
        return false
    }
}

enum BiometricDataProtectionError: LocalizedError {
    case biometricUnavailable
    case authenticationCancelled
    case authenticationFailed
    case keychain(OSStatus)
    case invalidKey
    case invalidArchive
    case archiveMissing

    var errorDescription: String? {
        switch self {
        case .biometricUnavailable:
            "Face ID 또는 Touch ID를 사용할 수 없습니다. 기기 잠금과 생체 인증을 확인해 주세요."
        case .authenticationCancelled:
            "생체 인증이 취소되었습니다."
        case .authenticationFailed:
            "생체 인증을 완료하지 못했습니다."
        case .keychain:
            "보호 키를 키체인에 저장하거나 열지 못했습니다."
        case .invalidKey, .invalidArchive:
            "보호된 데이터의 무결성을 확인하지 못했습니다."
        case .archiveMissing:
            "보호된 데이터가 아직 없습니다."
        }
    }
}

struct BiometricProtectedSnapshotArchive: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let createdAt: Date
    let encryptedPayload: Data
    let compressedByteCount: Int
    let jsonByteCount: Int
}

enum BiometricProtectedSnapshotCodec {
    static func archive(
        snapshot: TaptionDataSnapshot,
        keyData: Data,
        now: Date = .now
    ) throws -> BiometricProtectedSnapshotArchive {
        let json = try encoder.encode(snapshot)
        let compressed = TaptionSnapshotCompression.encode(json)
        let key = try symmetricKey(from: keyData)
        let sealed = try AES.GCM.seal(compressed, using: key)
        guard let encryptedPayload = sealed.combined else {
            throw BiometricDataProtectionError.invalidArchive
        }
        return BiometricProtectedSnapshotArchive(
            version: BiometricProtectedSnapshotArchive.currentVersion,
            createdAt: now,
            encryptedPayload: encryptedPayload,
            compressedByteCount: compressed.count,
            jsonByteCount: json.count
        )
    }

    static func snapshot(
        from archive: BiometricProtectedSnapshotArchive,
        keyData: Data
    ) throws -> TaptionDataSnapshot {
        guard archive.version == BiometricProtectedSnapshotArchive.currentVersion else {
            throw BiometricDataProtectionError.invalidArchive
        }
        let key = try symmetricKey(from: keyData)
        let sealed = try AES.GCM.SealedBox(combined: archive.encryptedPayload)
        let compressed = try AES.GCM.open(sealed, using: key)
        let json = TaptionSnapshotCompression.decode(compressed)
        let snapshot = try decoder.decode(TaptionDataSnapshot.self, from: json)
        guard snapshot.schemaVersion <= TaptionDataSnapshot.empty.schemaVersion else {
            throw BiometricDataProtectionError.invalidArchive
        }
        return snapshot
    }

    private static let encoder: JSONEncoder = {
        let value = JSONEncoder()
        value.outputFormatting = [.sortedKeys]
        value.dateEncodingStrategy = .secondsSince1970
        return value
    }()

    private static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .secondsSince1970
        return value
    }()

    private static func symmetricKey(from keyData: Data) throws -> SymmetricKey {
        guard keyData.count == 32 else {
            throw BiometricDataProtectionError.invalidKey
        }
        return SymmetricKey(data: keyData)
    }
}

@MainActor
final class BiometricProtectedSnapshotStore {
    private let archiveURL: URL
    private let keychain: BiometricDataProtectionKeychain
    private let fileManager: FileManager

    init(
        archiveURL: URL,
        keychain: BiometricDataProtectionKeychain = .init(),
        fileManager: FileManager = .default
    ) {
        self.archiveURL = archiveURL
        self.keychain = keychain
        self.fileManager = fileManager
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> BiometricProtectedSnapshotStore {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent("TaptionPlan", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return BiometricProtectedSnapshotStore(
            archiveURL: directory.appendingPathComponent(
                "biometric-protected-snapshot-v1.json"
            ),
            fileManager: fileManager
        )
    }

    var status: BiometricDataProtectionStatus {
        guard let archive = try? loadArchive() else {
            return fileManager.fileExists(atPath: archiveURL.path)
                ? .unavailable
                : .notProtected
        }
        return .protected(createdAt: archive.createdAt)
    }

    func protect(_ snapshot: TaptionDataSnapshot) async throws -> BiometricDataProtectionStatus {
        let keyData = try await keychain.key(
            localizedReason: "Taption Plan의 보호된 기록을 잠금 해제합니다."
        )
        let archive = try BiometricProtectedSnapshotCodec.archive(
            snapshot: snapshot,
            keyData: keyData
        )
        let data = try archiveEncoder.encode(archive)
        try fileManager.createDirectory(
            at: archiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(
            to: archiveURL,
            options: [.atomic, .completeFileProtection]
        )
        return .protected(createdAt: archive.createdAt)
    }

    func validate() async throws -> BiometricDataProtectionStatus {
        let archive = try loadArchive()
        let keyData = try await keychain.key(
            localizedReason: "Taption Plan의 보호된 기록을 확인합니다."
        )
        _ = try BiometricProtectedSnapshotCodec.snapshot(
            from: archive,
            keyData: keyData
        )
        return .protected(createdAt: archive.createdAt)
    }

    private func loadArchive() throws -> BiometricProtectedSnapshotArchive {
        guard fileManager.fileExists(atPath: archiveURL.path) else {
            throw BiometricDataProtectionError.archiveMissing
        }
        let data = try Data(contentsOf: archiveURL)
        do {
            return try archiveDecoder.decode(
                BiometricProtectedSnapshotArchive.self,
                from: data
            )
        } catch {
            throw BiometricDataProtectionError.invalidArchive
        }
    }

    private let archiveEncoder: JSONEncoder = {
        let value = JSONEncoder()
        value.outputFormatting = [.sortedKeys]
        value.dateEncodingStrategy = .secondsSince1970
        return value
    }()

    private let archiveDecoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .secondsSince1970
        return value
    }()
}

@MainActor
final class BiometricDataProtectionKeychain {
    private let service = "com.taption.plan.biometric-data-protection"
    private let account = "snapshot-encryption-key-v1"

    func key(localizedReason: String) async throws -> Data {
        let context = try await authenticatedContext(localizedReason: localizedReason)
        if let existing = try existingKey(using: context) {
            return existing
        }

        let generated = try randomKey()
        try add(generated, using: context)
        return generated
    }

    private func authenticatedContext(localizedReason: String) async throws -> LAContext {
        let context = LAContext()
        context.localizedReason = localizedReason
        var availabilityError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &availabilityError
        ) else {
            throw BiometricDataProtectionError.biometricUnavailable
        }
        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: localizedReason
            )
            return context
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                throw BiometricDataProtectionError.authenticationCancelled
            default:
                throw BiometricDataProtectionError.authenticationFailed
            }
        } catch {
            throw BiometricDataProtectionError.authenticationFailed
        }
    }

    private func existingKey(using context: LAContext) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecUseAuthenticationContext: context,
        ] as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw BiometricDataProtectionError.invalidKey
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw BiometricDataProtectionError.keychain(status)
        }
    }

    private func add(_ key: Data, using context: LAContext) throws {
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            &accessError
        ) else {
            throw BiometricDataProtectionError.keychain(errSecAuthFailed)
        }
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: key,
            kSecAttrAccessControl: accessControl,
            kSecUseAuthenticationContext: context,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BiometricDataProtectionError.keychain(status)
        }
    }

    private func randomKey() throws -> Data {
        var value = Data(repeating: 0, count: 32)
        let count = value.count
        let status = value.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw BiometricDataProtectionError.keychain(status)
        }
        return value
    }
}
