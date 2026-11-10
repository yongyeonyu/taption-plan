import Compression
import Foundation

public enum RepositoryError: Error, Equatable {
    case invalidSnapshot
    case unsupportedSchema(Int)
    case cloudAccountUnavailable
    case cloudSchemaUnavailable
    case cloudPayloadMissing
    case cloudPayloadTooLarge
    case appGroupUnavailable
    case staleGeneration
}

public enum TaptionSnapshotCompressionError: Error, Equatable {
    case invalidLimit
    case invalidHeader
    case uncompressedSizeExceedsLimit(actual: UInt64, maximum: Int)
    case decompressionFailed(expected: Int, actual: Int)
}

/// Keeps the shared snapshot small without changing its on-disk path.  The
/// decoder accepts the old plain JSON file so existing installs migrate on
/// their next save.
public enum TaptionSnapshotCompression {
    private static let magic: [UInt8] = [0x54, 0x50, 0x5A, 0x31]
    private static let headerSize = magic.count + 8
    private static let minimumSize = 4 * 1024
    public static let maximumUncompressedSize = 64 * 1_024 * 1_024

    public static func encode(
        _ json: Data,
        maximumSize: Int = Self.maximumUncompressedSize
    ) -> Data {
        guard maximumSize > 0,
              json.count >= minimumSize,
              json.count <= maximumSize else { return json }
        var compressed = Data(repeating: 0, count: json.count + 64)
        let encodedCount: Int = json.withUnsafeBytes { source in
            compressed.withUnsafeMutableBytes { destination in
                guard let sourceBase = source.bindMemory(to: UInt8.self)
                    .baseAddress,
                    let destinationBase = destination.bindMemory(
                        to: UInt8.self
                    ).baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    destinationBase,
                    destination.count,
                    sourceBase,
                    json.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard encodedCount > 0,
              encodedCount + headerSize < json.count else {
            return json
        }

        var result = Data(magic)
        appendLittleEndian(UInt64(json.count), to: &result)
        result.append(compressed.prefix(encodedCount))
        return result
    }

    /// TPZ1이 아니면 옛 평문 JSON으로 보고 그대로 돌려준다. TPZ1인데 풀리지 않으면 바이트를 그대로 넘기지 않고
    /// 던진다. 손상된 압축본을 평문처럼 읽어 빈 값으로 오인하지 않게 한다(REV1110A04).
    public static func decode(_ data: Data) throws -> Data {
        try decodeChecked(data)
    }

    public static func decodeChecked(
        _ data: Data,
        maximumSize: Int = Self.maximumUncompressedSize
    ) throws -> Data {
        guard maximumSize > 0 else {
            throw TaptionSnapshotCompressionError.invalidLimit
        }
        guard data.count >= magic.count,
              data.prefix(magic.count).elementsEqual(magic) else {
            return data
        }
        guard data.count >= headerSize else {
            throw TaptionSnapshotCompressionError.invalidHeader
        }

        let originalSize = readLittleEndian(
            data.dropFirst(magic.count).prefix(8)
        )
        guard originalSize > 0 else {
            throw TaptionSnapshotCompressionError.invalidHeader
        }
        guard originalSize <= UInt64(maximumSize) else {
            throw TaptionSnapshotCompressionError
                .uncompressedSizeExceedsLimit(
                    actual: originalSize,
                    maximum: maximumSize
                )
        }
        let expectedSize = Int(originalSize)
        var decoded = Data(repeating: 0, count: expectedSize)
        let compressed = data.dropFirst(headerSize)
        let decodedCount: Int = compressed.withUnsafeBytes { source in
            decoded.withUnsafeMutableBytes { destination in
                guard let sourceBase = source.bindMemory(to: UInt8.self)
                    .baseAddress,
                    let destinationBase = destination.bindMemory(
                        to: UInt8.self
                    ).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase,
                    destination.count,
                    sourceBase,
                    compressed.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard decodedCount == expectedSize else {
            throw TaptionSnapshotCompressionError.decompressionFailed(
                expected: expectedSize,
                actual: decodedCount
            )
        }
        return decoded
    }

    private static func appendLittleEndian(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, to: 64, by: 8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    private static func readLittleEndian(_ data: Data.SubSequence) -> UInt64 {
        data.enumerated().reduce(into: UInt64(0)) { result, item in
            result |= UInt64(item.element) << UInt64(item.offset * 8)
        }
    }
}
