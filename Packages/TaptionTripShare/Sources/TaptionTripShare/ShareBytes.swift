import CryptoKit
import Foundation

/// 바이트 ⇄ 글자. base64url은 패딩 없이 쓴다.
public enum ShareBytes {
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func data(base64URL text: String) -> Data? {
        guard isURLSafe(text), text.count % 4 != 1 else { return nil }
        var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return Data(base64Encoded: padded)
    }

    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func data(hex text: String) -> Data? {
        let digits = Array(text.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var out = Data(capacity: digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }

    /// 암호용 무작위 바이트(CryptoKit의 키 생성기).
    public static func random(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    /// `A-Za-z0-9_-`만.
    public static func isURLSafe(_ text: String) -> Bool {
        text.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a) || byte == 0x2d || byte == 0x5f
        }
    }
}

/// 규약의 id 모양과 만들기.
public enum ShareIdentifiers {
    /// 여행 정보 항목은 방에 하나라서 id를 고정한다.
    public static let metaID = "trip-meta"
    static let memberPrefix = "member-"

    public static func roomID() -> String { ShareBytes.base64URL(ShareBytes.random(16)) }
    public static func linkSecret() -> Data { ShareBytes.random(32) }
    public static func ownerKey() -> String { ShareBytes.base64URL(ShareBytes.random(32)) }
    public static func itemID() -> String { ShareBytes.base64URL(ShareBytes.random(16)) }
    public static func memberCardID(_ member: Int) -> String { memberPrefix + String(member) }

    /// UUID 16바이트 ⇄ 항목 id(base64url 22자).
    public static func itemID(uuid: UUID) -> String {
        withUnsafeBytes(of: uuid.uuid) { ShareBytes.base64URL(Data($0)) }
    }

    public static func uuid(itemID: String) -> UUID? {
        guard itemID.utf8.count == 22, let data = ShareBytes.data(base64URL: itemID), data.count == 16 else { return nil }
        return data.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }

    /// 앱의 여행·항목 id에서 늘 같은 방 항목 id를 만든다: SHA256(`tripID|itemID`)의 앞 16바이트.
    public static func itemID(tripID: String, itemID: String) -> String {
        ShareBytes.base64URL(Data(SHA256.hash(data: Data("\(tripID)|\(itemID)".utf8)).prefix(16)))
    }

    public static func isRoomID(_ text: String) -> Bool { text.utf8.count == 22 && ShareBytes.isURLSafe(text) }
    public static func isSecret(_ text: String) -> Bool { text.utf8.count == 43 && ShareBytes.isURLSafe(text) }
    public static func isItemID(_ text: String) -> Bool { (8...64).contains(text.utf8.count) && ShareBytes.isURLSafe(text) }
    public static func isGroupName(_ text: String) -> Bool { (1...64).contains(text.utf8.count) && ShareBytes.isURLSafe(text) }
    public static func itemLock(_ itemID: String) -> String { "i:" + itemID }
    public static func groupLock(_ group: String) -> String { "g:" + group }
}

enum ShareJSON {
    static func data(_ value: some Encodable) throws -> Data {
        do { return try JSONEncoder().encode(value) } catch { throw ShareError.invalidResponse }
    }

    static func string(_ value: some Encodable) throws -> String {
        String(decoding: try data(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw ShareError.invalidResponse }
    }
}
