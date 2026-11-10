import CryptoKit
import Foundation

/// AI 연결 승인 PIN은 앱 비밀번호 6자리로 정한다(대표 결정 2026-11-10, PIN1110A01).
/// 서버에는 앱 비밀번호를 보내지 않고, iCloud 키체인으로 동기화되는 무작위 값과 섞어 만든 다른 6자리를 보낸다.
/// 서버 저장소와 pepper가 함께 새도 이 무작위 값 없이는 앱 비밀번호(= 백업 비밀번호)를 되찾을 수 없다.
@MainActor
enum AssistantPINDerivation {
    static let saltAccount = "assistant-pin-salt-v1"
    nonisolated private static let label = Data("bokki-ai-pin-v1".utf8)

    /// 서버에 보낼 6자리. 같은 앱 비밀번호·같은 무작위 값이면 늘 같다.
    nonisolated static func pin(appPassword: String, salt: Data) -> String {
        var message = label
        message.append(0)
        message.append(Data(appPassword.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: salt))
        let value = Data(mac).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return String(format: "%06u", value % 1_000_000)
    }

    /// 보관된 무작위 값. 없으면 만들어 담는다. 담지 못하면 nil(이번에는 진행하지 않는다).
    static func salt(store: BackupPasswordStore = KeychainBackupPasswordStore(account: saltAccount)) -> Data? {
        if let text = try? store.read(), let data = Data(base64Encoded: text), data.count == 32 { return data }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let data = Data(bytes)
        guard (try? store.write(data.base64EncodedString())) != nil else { return nil }
        return data
    }

    static func pin(appPassword: String, store: BackupPasswordStore = KeychainBackupPasswordStore(account: saltAccount)) -> String? {
        salt(store: store).map { pin(appPassword: appPassword, salt: $0) }
    }
}

/// AI 화면에서 앱 비밀번호를 확인하는 길. `AppModel`이 켜질 때 채운다.
@MainActor
enum AssistantAppPassword {
    enum Check: Equatable {
        case matched
        case wrong
        case blocked(retryAfter: TimeInterval)
        case notSet
    }

    static var verify: (String) -> Check = { _ in .notSet }
    static var isSet: () -> Bool = { false }
}
