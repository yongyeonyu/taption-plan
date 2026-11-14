import CryptoKit
import Foundation

/// 암호문을 방·항목·종류·세대에 묶는 값(AAD의 재료).
public struct ShareItemContext: Sendable, Equatable {
    public var roomID: String
    public var itemID: String
    public var kind: String
    public var epoch: Int

    public init(roomID: String, itemID: String, kind: String, epoch: Int) {
        self.roomID = roomID
        self.itemID = itemID
        self.kind = kind
        self.epoch = epoch
    }

    public var aad: String { "\(ShareProtocolV1.prefix)|\(roomID)|\(itemID)|\(kind)|\(epoch)" }
}

/// `cipher = base64url(0x01 || nonce 12 || AES-256-GCM 암호문 || tag 16)`.
public enum ShareCipher {
    public static let overheadBytes = 1 + ShareProtocolV1.nonceBytes + ShareProtocolV1.tagBytes

    /// `nonce`는 시험 벡터를 맞출 때만 넣는다. 평소에는 비워 무작위를 쓴다.
    public static func seal(_ plaintext: Data, key: Data, context: ShareItemContext, nonce: Data? = nil) throws -> String {
        do {
            let box = try AES.GCM.seal(
                plaintext,
                using: SymmetricKey(data: key),
                nonce: try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce(),
                authenticating: Data(context.aad.utf8)
            )
            return ShareBytes.base64URL(Data([ShareProtocolV1.cipherVersion]) + Data(box.nonce) + box.ciphertext + box.tag)
        } catch {
            throw ShareError.crypto
        }
    }

    /// 풀리지 않으면(키·방·항목·종류·세대가 다르거나 형식이 다르면) nil. 그런 항목은 버린다.
    public static func open(_ cipher: String, key: Data, context: ShareItemContext) -> Data? {
        guard let raw = ShareBytes.data(base64URL: cipher), raw.count >= overheadBytes, raw.first == ShareProtocolV1.cipherVersion else { return nil }
        let body = Data(raw.dropFirst())
        let nonceEnd = ShareProtocolV1.nonceBytes
        let tagStart = body.count - ShareProtocolV1.tagBytes
        guard let nonce = try? AES.GCM.Nonce(data: body[0..<nonceEnd]),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: body[nonceEnd..<tagStart], tag: body[tagStart...]) else { return nil }
        return try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(context.aad.utf8))
    }

    /// JSON 뒤에 공백을 붙여 길이를 64바이트 배수로 맞춘다(JSON으로 읽을 때 무시된다).
    public static func padded(_ json: Data) -> Data {
        let block = ShareProtocolV1.paddingBlock
        return json + Data(repeating: 0x20, count: (block - json.count % block) % block)
    }

    /// 잠근 뒤의 바이트 수(서버 한도 `itemBytes`와 견준다).
    public static func sealedBytes(plaintextBytes: Int) -> Int { overheadBytes + plaintextBytes }
}
