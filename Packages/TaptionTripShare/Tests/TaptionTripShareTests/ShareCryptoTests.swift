import Foundation
import XCTest
@testable import TaptionTripShare

/// 규약 3·4절: 키 유도·암호문·링크. 벡터는 서버 시험이 쓰는 파일(`share-vectors.json`)을 그대로 복사한 것이다.
final class ShareCryptoTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Vector: Decodable {
            struct Input: Decodable {
                var roomId: String
                var linkSecretHex: String
                var password: String
                var itemId: String
                var kind: String
                var epoch: Int
                var nonceHex: String
                var plaintext: String
            }

            struct Expected: Decodable {
                var passwordUtf8Hex: String
                var saltHex: String
                var rootHex: String
                var encKeyHex: String
                var authKeyHex: String
                var proof: String
                var aad: String
                var cipher: String
            }

            var input: Input
            var expected: Expected
        }

        var iterations: Int
        var vectors: [Vector]
    }

    private func vectors() throws -> Vectors {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "share-vectors", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testVectorsMatchTheProtocolDocument() throws {
        let file = try vectors()
        XCTAssertEqual(file.iterations, ShareProtocolV1.pbkdf2Iterations)
        XCTAssertEqual(file.vectors.count, 2)
        for vector in file.vectors {
            let input = vector.input, expected = vector.expected
            let secret = try XCTUnwrap(ShareBytes.data(hex: input.linkSecretHex))
            XCTAssertEqual(ShareBytes.hex(Data(SharePasswordPolicy.normalized(input.password).utf8)), expected.passwordUtf8Hex)
            XCTAssertEqual(ShareBytes.hex(ShareKeys.salt(roomID: input.roomId, linkSecret: secret)), expected.saltHex)

            let keys = try ShareKeys.derive(roomID: input.roomId, linkSecret: secret, password: input.password)
            XCTAssertEqual(ShareBytes.hex(keys.root), expected.rootHex)
            XCTAssertEqual(ShareBytes.hex(keys.encKey), expected.encKeyHex)
            XCTAssertEqual(ShareBytes.hex(keys.authKey), expected.authKeyHex)
            XCTAssertEqual(keys.proof, expected.proof)
            XCTAssertEqual(ShareKeys(roomID: input.roomId, root: keys.root), keys, "뿌리 키만으로 같은 키들이 나온다")

            let context = ShareItemContext(roomID: input.roomId, itemID: input.itemId, kind: input.kind, epoch: input.epoch)
            XCTAssertEqual(context.aad, expected.aad)
            let nonce = try XCTUnwrap(ShareBytes.data(hex: input.nonceHex))
            XCTAssertEqual(try ShareCipher.seal(Data(input.plaintext.utf8), key: keys.encKey, context: context, nonce: nonce), expected.cipher)
            XCTAssertEqual(ShareCipher.open(expected.cipher, key: keys.encKey, context: context), Data(input.plaintext.utf8))
        }
    }

    func testPasswordIsNormalizedToNFC() throws {
        let secret = Data(repeating: 7, count: 32)
        let room = "AAECAwQFBgcICQoLDA0ODw"
        let composed = try ShareKeys.derive(roomID: room, linkSecret: secret, password: "\u{AC00}\u{C744}길에서", iterations: 10)
        let decomposed = try ShareKeys.derive(roomID: room, linkSecret: secret, password: "\u{1100}\u{1161}\u{110B}\u{1173}\u{11AF}길에서", iterations: 10)
        XCTAssertEqual(composed, decomposed)
    }

    func testPasswordPolicyIsSixOrMoreOfAnything() {
        XCTAssertEqual(SharePasswordPolicy.issue(in: "12345"), .tooShort(minimum: 6))
        XCTAssertNil(SharePasswordPolicy.issue(in: "123456"))
        XCTAssertNil(SharePasswordPolicy.issue(in: "가나다라마바"))
        XCTAssertEqual(SharePasswordPolicy.issue(in: "가나다"), .tooShort(minimum: 6))
        XCTAssertNil(SharePasswordPolicy.issue(in: "a b-c!"))
    }

    func testSealedItemOpensOnlyWithTheSameRoomItemKindAndEpoch() throws {
        let key = ShareBytes.random(32)
        let context = ShareItemContext(roomID: ShareIdentifiers.roomID(), itemID: ShareIdentifiers.itemID(), kind: "plan", epoch: 1)
        let plain = Data(#"{"v":1}"#.utf8)
        let cipher = try ShareCipher.seal(plain, key: key, context: context)
        XCTAssertEqual(ShareCipher.open(cipher, key: key, context: context), plain)
        XCTAssertNotEqual(try ShareCipher.seal(plain, key: key, context: context), cipher, "nonce는 잠글 때마다 새로 뽑는다")
        XCTAssertTrue(cipher.hasPrefix("A"), "첫 바이트 0x01")

        var other = context
        other.epoch = 2
        XCTAssertNil(ShareCipher.open(cipher, key: key, context: other))
        other = context
        other.kind = "notice"
        XCTAssertNil(ShareCipher.open(cipher, key: key, context: other))
        other = context
        other.itemID = ShareIdentifiers.itemID()
        XCTAssertNil(ShareCipher.open(cipher, key: key, context: other))
        other = context
        other.roomID = ShareIdentifiers.roomID()
        XCTAssertNil(ShareCipher.open(cipher, key: key, context: other))
        XCTAssertNil(ShareCipher.open(cipher, key: ShareBytes.random(32), context: context))
        XCTAssertNil(ShareCipher.open("AQ", key: key, context: context))
        XCTAssertNil(ShareCipher.open("B" + cipher.dropFirst(), key: key, context: context), "모르는 형식 버전")
    }

    func testPaddingMakesLengthsMultiplesOf64AndStaysJSON() throws {
        for length in [1, 23, 63, 64, 65, 200] {
            let json = Data(("{\"v\":1,\"t\":\"" + String(repeating: "x", count: length) + "\"}").utf8)
            let padded = ShareCipher.padded(json)
            XCTAssertEqual(padded.count % 64, 0)
            XCTAssertLessThan(padded.count - json.count, 64)
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: padded))
        }
    }

    func testInviteLinkKeepsSecretsBehindTheHash() throws {
        let invite = ShareInvite.make()
        XCTAssertTrue(ShareIdentifiers.isRoomID(invite.roomID))
        XCTAssertEqual(invite.linkSecret.count, 32)
        let base = try XCTUnwrap(URL(string: "https://example.invalid/join?x=1"))
        let url = try XCTUnwrap(invite.url(opening: base))
        let secret = ShareBytes.base64URL(invite.linkSecret)
        XCTAssertEqual(url.absoluteString, "https://example.invalid/join?x=1#\(invite.roomID).\(secret)")
        XCTAssertFalse((url.path + (url.query ?? "")).contains(secret))
        XCTAssertEqual(ShareInvite(url: url), invite)
        XCTAssertEqual(ShareInvite(url: try XCTUnwrap(URL(string: "tripshare-example://open#\(invite.fragment)"))), invite)

        XCTAssertNil(ShareInvite(url: base))
        XCTAssertNil(ShareInvite(fragment: invite.roomID))
        XCTAssertNil(ShareInvite(fragment: "short." + secret))
        XCTAssertNil(ShareInvite(fragment: invite.roomID + "." + secret.dropLast()))
        XCTAssertNil(ShareInvite(fragment: invite.roomID + "." + secret + ".x"))
    }

    func testGroupNameHidesTheDayAndFitsTheServerShape() throws {
        let keys = ShareKeys(roomID: "AAECAwQFBgcICQoLDA0ODw", root: Data(repeating: 1, count: 32))
        let other = ShareKeys(roomID: "AAECAwQFBgcICQoLDA0ODw", root: Data(repeating: 2, count: 32))
        let name = keys.groupName(day: "2031-05-06")
        XCTAssertEqual(name.count, 16)
        XCTAssertTrue(ShareIdentifiers.isGroupName(name))
        XCTAssertEqual(name, keys.groupName(day: "2031-05-06"))
        XCTAssertNotEqual(name, keys.groupName(day: "2031-05-07"))
        XCTAssertNotEqual(name, other.groupName(day: "2031-05-06"), "키가 다르면 이름도 다르다")
        XCTAssertFalse(name.contains("2031"))
    }

    func testIdentifiersHaveTheProtocolShapes() throws {
        XCTAssertEqual(ShareIdentifiers.roomID().count, 22)
        XCTAssertEqual(ShareIdentifiers.ownerKey().count, 43)
        XCTAssertTrue(ShareIdentifiers.isItemID(ShareIdentifiers.itemID()))
        XCTAssertNotEqual(ShareIdentifiers.itemID(), ShareIdentifiers.itemID())
        XCTAssertEqual(ShareIdentifiers.memberCardID(3), "member-3")
        XCTAssertTrue(ShareIdentifiers.isItemID(ShareIdentifiers.metaID))
        XCTAssertFalse(ShareIdentifiers.isItemID("short"))
        XCTAssertFalse(ShareIdentifiers.isItemID("has space in it"))

        let uuid = try XCTUnwrap(UUID(uuidString: "00010203-0405-0607-0809-0A0B0C0D0E0F"))
        XCTAssertEqual(ShareIdentifiers.itemID(uuid: uuid), "AAECAwQFBgcICQoLDA0ODw")
        XCTAssertEqual(ShareIdentifiers.uuid(itemID: "AAECAwQFBgcICQoLDA0ODw"), uuid)
        XCTAssertNil(ShareIdentifiers.uuid(itemID: "member-3"))

        let derived = ShareIdentifiers.itemID(tripID: "trip-a", itemID: "item-1")
        XCTAssertEqual(derived.count, 22)
        XCTAssertEqual(derived, ShareIdentifiers.itemID(tripID: "trip-a", itemID: "item-1"))
        XCTAssertNotEqual(derived, ShareIdentifiers.itemID(tripID: "trip-a", itemID: "item-2"))
        XCTAssertNotEqual(derived, ShareIdentifiers.itemID(tripID: "trip-b", itemID: "item-1"))
        // SHA256("trip-a|item-1")의 앞 16바이트.
        XCTAssertEqual(ShareBytes.data(base64URL: derived)?.count, 16)
    }

    func testBase64URLAndHexRoundTrip() {
        let data = Data((0..<255).map { UInt8($0) })
        XCTAssertEqual(ShareBytes.data(base64URL: ShareBytes.base64URL(data)), data)
        XCTAssertEqual(ShareBytes.data(hex: ShareBytes.hex(data)), data)
        XCTAssertFalse(ShareBytes.base64URL(data).contains(where: { "+/=".contains($0) }))
        XCTAssertNil(ShareBytes.data(base64URL: "a+b/"))
        XCTAssertNil(ShareBytes.data(hex: "abc"))
    }
}
