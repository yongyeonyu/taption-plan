import CommonCrypto
import CryptoKit
import Foundation

/// 규약 v1의 고정 값(3·4절).
public enum ShareProtocolV1 {
    public static let prefix = "taption-share-v1"
    public static let pbkdf2Iterations = 600_000
    public static let cipherVersion: UInt8 = 0x01
    public static let nonceBytes = 12
    public static let tagBytes = 16
    /// 평문 길이를 이 배수로 맞춘다(크기로 내용을 짐작하기 어렵게).
    public static let paddingBlock = 64
}

/// 비밀번호 규칙. 1차 기본값은 「6자 이상 아무 글자」이고, 바꿀 때는 이 함수만 고친다.
public enum SharePasswordPolicy {
    public enum Issue: Sendable, Equatable { case tooShort(minimum: Int) }

    public static let minimumLength = 6

    /// 키 유도에 들어가는 모양(NFC).
    public static func normalized(_ password: String) -> String { password.precomposedStringWithCanonicalMapping }

    public static func issue(in password: String) -> Issue? {
        normalized(password).count >= minimumLength ? nil : .tooShort(minimum: minimumLength)
    }
}

/// 링크 비밀 값 + 비밀번호에서 나오는 키들. 서버로 가는 것은 `proof`뿐이다.
public struct ShareKeys: Sendable, Equatable {
    public let roomID: String
    public let root: Data
    public let encKey: Data
    public let authKey: Data
    public let proof: String

    /// 키체인에 둔 뿌리 키에서 나머지를 다시 만든다(PBKDF2를 다시 하지 않는다).
    public init(roomID: String, root: Data) {
        self.roomID = roomID
        self.root = root
        encKey = Self.expand(root, info: "enc")
        authKey = Self.expand(root, info: "auth")
        let mac = HMAC<SHA256>.authenticationCode(for: Data(("join|" + roomID).utf8), using: SymmetricKey(data: authKey))
        proof = ShareBytes.base64URL(Data(mac))
    }

    /// PBKDF2 60만 회. 시간이 걸리므로 화면 밖(Task)에서 부른다.
    public static func derive(roomID: String, linkSecret: Data, password: String, iterations: Int = ShareProtocolV1.pbkdf2Iterations) throws -> ShareKeys {
        guard ShareIdentifiers.isRoomID(roomID), linkSecret.count == 32 else { throw ShareError.crypto }
        let root = try pbkdf2(
            password: Data(SharePasswordPolicy.normalized(password).utf8),
            salt: salt(roomID: roomID, linkSecret: linkSecret),
            iterations: iterations
        )
        return ShareKeys(roomID: roomID, root: root)
    }

    public static func salt(roomID: String, linkSecret: Data) -> Data {
        Data("\(ShareProtocolV1.prefix)|\(roomID)|".utf8) + linkSecret
    }

    /// 묶음(한 날의 항목들) 이름. 날짜가 서버에 보이지 않게 암호화 키로 HMAC한 앞 12바이트를 쓴다(8절).
    public func groupName(day: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(("group|" + day).utf8), using: SymmetricKey(data: encKey))
        return ShareBytes.base64URL(Data(mac).prefix(12))
    }

    private static func expand(_ root: Data, info: String) -> Data {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: root),
            salt: Data(ShareProtocolV1.prefix.utf8),
            info: Data(info.utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
    }

    private static func pbkdf2(password: Data, salt: Data, iterations: Int) throws -> Data {
        guard !password.isEmpty, iterations > 0 else { throw ShareError.crypto }
        var out = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: Int8.self).baseAddress, password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                    &out, out.count
                )
            }
        }
        guard status == kCCSuccess else { throw ShareError.crypto }
        return Data(out)
    }
}

/// 초대 링크의 `#` 뒤: `<roomId>.<linkSecret의 base64url>`. 비밀은 주소의 경로·쿼리에 넣지 않는다.
public struct ShareInvite: Sendable, Equatable {
    public let roomID: String
    public let linkSecret: Data

    public init?(roomID: String, linkSecret: Data) {
        guard ShareIdentifiers.isRoomID(roomID), linkSecret.count == 32 else { return nil }
        self.roomID = roomID
        self.linkSecret = linkSecret
    }

    /// 새 방의 초대(무작위 방 id와 링크 비밀 값).
    public static func make() -> ShareInvite {
        ShareInvite(roomID: ShareIdentifiers.roomID(), linkSecret: ShareIdentifiers.linkSecret())!
    }

    public var fragment: String { roomID + "." + ShareBytes.base64URL(linkSecret) }

    public init?(fragment: String) {
        let parts = fragment.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, ShareIdentifiers.isSecret(String(parts[1])), let secret = ShareBytes.data(base64URL: String(parts[1])) else { return nil }
        self.init(roomID: String(parts[0]), linkSecret: secret)
    }

    public init?(url: URL) {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment else { return nil }
        self.init(fragment: fragment)
    }

    /// 앱이 정한 주소 뒤에 `#…`를 붙인다. 주소에 이미 `#`이 있으면 바꾼다.
    public func url(opening base: URL) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        parts.fragment = fragment
        return parts.url
    }
}
