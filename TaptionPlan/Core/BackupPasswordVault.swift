import Foundation
import Security

/// 백업 비밀번호 6자리를 보관하는 곳. 백업 키·파일 형식과는 무관하다(BKP1110A02).
protocol BackupPasswordStore: AnyObject {
    func read() throws -> String?
    func write(_ password: String) throws
    func delete() throws
}

struct BackupPasswordStoreError: Error, Equatable {
    let status: OSStatus
}

/// iCloud 키체인으로 동기화되는 일반 암호 항목. 동기화되려면 ThisDeviceOnly·생체 접근 제어를 쓰지 않아야 한다.
final class KeychainBackupPasswordStore: BackupPasswordStore {
    private let service: String
    private let account: String

    init(service: String = "com.taption.plan.security", account: String = "backup-password-sync-v1") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
        ]
    }

    func read() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw BackupPasswordStoreError(status: status) }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    func write(_ password: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw BackupPasswordStoreError(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BackupPasswordStoreError(status: status)
        }
    }
}

enum BackupPasswordReveal: Equatable, Sendable {
    case revealed(String)
    case nothingStored
    case passcodeNotSet
    case denied
}

@MainActor
final class BackupPasswordVault {
    private let store: BackupPasswordStore
    private let authenticator: AssistantOwnerAuthenticating

    init(
        store: BackupPasswordStore = KeychainBackupPasswordStore(),
        authenticator: AssistantOwnerAuthenticating = AssistantDeviceOwnerAuthenticator()
    ) {
        self.store = store
        self.authenticator = authenticator
    }

    /// 지금의 6자리와, 예전에 등록해 아직 남아 있는 4자리만 담는다.
    static func isStorable(_ password: String) -> Bool {
        PlanPINVerifier.isValid(password) || PlanPINVerifier.isValid(password, digits: PlanPINVerifier.legacyDigits)
    }

    /// 본인 확인 없이 읽는 값. 화면에 보여 주지 않고 같은 값인지 비교할 때만 쓴다.
    var stored: String? {
        guard let value = try? store.read(), Self.isStorable(value) else { return nil }
        return value
    }

    @discardableResult
    func save(_ password: String) -> Bool {
        guard Self.isStorable(password) else { return false }
        return (try? store.write(password)) != nil
    }

    func clear() {
        try? store.delete()
    }

    /// 본인 확인(Face ID·Touch ID, 안 되면 기기 암호)을 통과한 뒤에만 값을 돌려준다. 기기 암호가 없으면 보여 주지 않는다. 보관값이 없으면 `fallback`(이 기기에만 있던 값)을 옮겨 담는다.
    func reveal(reason: String, fallback: () -> String? = { nil }) async -> BackupPasswordReveal {
        switch await authenticator.authenticate(reason: reason) {
        case .failed: return .denied
        case .noPasscode: return .passcodeNotSet
        case .passed: break
        }
        if let stored { return .revealed(stored) }
        guard let value = fallback(), Self.isStorable(value) else { return .nothingStored }
        save(value)
        return .revealed(value)
    }
}
