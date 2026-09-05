import Foundation
import Compression
import CryptoKit

public struct TaptionPlanEncodedPayload: Sendable, Hashable {
    public let data: Data
    public let checksum: String
    public let uncompressedSize: Int
    public let isCompressed: Bool

    public init(data: Data, checksum: String, uncompressedSize: Int, isCompressed: Bool) {
        self.data = data
        self.checksum = checksum
        self.uncompressedSize = uncompressedSize
        self.isCompressed = isCompressed
    }
}

public enum TaptionPlanCanonicalStorageError: Error, Equatable, Sendable {
    case checksumMismatch
    case invalidPayload
    case decompressionFailed
}

/// The sole persistence codec: binary Codable, optionally LZFSE compressed, with SHA-256 integrity.
public enum TaptionPlanCanonicalStorage {
    public static let maximumUncompressedSize = 64 * 1_024 * 1_024
    private static let envelopeMagic = Data("TP-CANON".utf8)
    private static let minimumCompressionSize = 4 * 1_024

    public static func encode<Value: Encodable>(_ value: Value, compress: Bool = true) throws -> TaptionPlanEncodedPayload {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let raw = try encoder.encode(value)
        guard raw.count <= maximumUncompressedSize else {
            throw TaptionPlanCanonicalStorageError.invalidPayload
        }
        let payload: (Data, Bool)
        if compress,
           raw.count >= minimumCompressionSize,
           let compressed = lzfse(raw),
           compressed.count < raw.count {
            payload = (compressed, true)
        } else {
            payload = (raw, false)
        }
        return .init(data: payload.0, checksum: checksum(raw), uncompressedSize: raw.count, isCompressed: payload.1)
    }

    public static func envelope(for encoded: TaptionPlanEncodedPayload) -> Data {
        var envelope = envelopeMagic
        envelope.reserveCapacity(
            envelopeMagic.count + 1 + 8 + 64 + encoded.data.count
        )
        envelope.append(encoded.isCompressed ? 1 : 0)
        var size = UInt64(encoded.uncompressedSize).bigEndian
        withUnsafeBytes(of: &size) { envelope.append(contentsOf: $0) }
        envelope.append(Data(encoded.checksum.utf8))
        envelope.append(encoded.data)
        return envelope
    }

    public static func encodedPayload(from envelope: Data) throws -> TaptionPlanEncodedPayload {
        guard envelope.count >= envelopeMagic.count + 1 + 8 + 64,
              envelope.prefix(envelopeMagic.count) == envelopeMagic else {
            throw TaptionPlanCanonicalStorageError.invalidPayload
        }
        let magicLength = envelopeMagic.count
        let compressionFlag = envelope[magicLength]
        guard compressionFlag == 0 || compressionFlag == 1 else {
            throw TaptionPlanCanonicalStorageError.invalidPayload
        }
        let sizeStart = magicLength + 1
        let sizeEnd = sizeStart + 8
        let size = envelope[sizeStart..<sizeEnd]
            .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard size <= UInt64(maximumUncompressedSize) else {
            throw TaptionPlanCanonicalStorageError.invalidPayload
        }
        let checksumStart = sizeEnd
        let checksumEnd = checksumStart + 64
        let checksum = String(
            decoding: envelope[checksumStart..<checksumEnd],
            as: UTF8.self
        )
        guard checksum.count == 64,
              checksum.allSatisfy({ $0.isHexDigit }) else {
            throw TaptionPlanCanonicalStorageError.invalidPayload
        }
        let data = Data(envelope.dropFirst(checksumEnd))
        guard compressionFlag == 1 || data.count == Int(size) else {
            throw TaptionPlanCanonicalStorageError.invalidPayload
        }
        return TaptionPlanEncodedPayload(
            data: data,
            checksum: checksum,
            uncompressedSize: Int(size),
            isCompressed: compressionFlag == 1
        )
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from encoded: TaptionPlanEncodedPayload) throws -> Value {
        guard (0...maximumUncompressedSize).contains(encoded.uncompressedSize),
              encoded.isCompressed || encoded.data.count == encoded.uncompressedSize else {
            throw TaptionPlanCanonicalStorageError.invalidPayload
        }
        let raw = encoded.isCompressed ? try unlzfse(encoded.data, size: encoded.uncompressedSize) : encoded.data
        guard checksum(raw) == encoded.checksum else { throw TaptionPlanCanonicalStorageError.checksumMismatch }
        do { return try PropertyListDecoder().decode(type, from: raw) }
        catch { throw TaptionPlanCanonicalStorageError.invalidPayload }
    }

    public static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func lzfse(_ data: Data) -> Data? {
        guard data.count > 1 else { return nil }
        let capacity = data.count - 1
        var output = Data(count: capacity)
        let count = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_encode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!,
                    capacity,
                    input.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard count > 0 else { return nil }
        output.count = count
        return output
    }

    private static func unlzfse(_ data: Data, size: Int) throws -> Data {
        guard size >= 0 else { throw TaptionPlanCanonicalStorageError.decompressionFailed }
        if size == 0 { return Data() }
        guard !data.isEmpty else {
            throw TaptionPlanCanonicalStorageError.decompressionFailed
        }
        var output = Data(count: size)
        let count = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, size,
                                           input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard count == size else { throw TaptionPlanCanonicalStorageError.decompressionFailed }
        return output
    }
}

/// Bounded in-memory day cache. Values are loaded only on demand and evicted least-recently-used first.
public actor TaptionPlanDayLRUCache<Key: Hashable & Sendable, Value: Sendable> {
    public let capacity: Int
    private var values: [Key: Value] = [:]
    private var recency: [Key] = []
    private var loader: (@Sendable (Key) async throws -> Value?)?

    public init(capacity: Int, loader: (@Sendable (Key) async throws -> Value?)? = nil) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.loader = loader
    }

    public func value(for key: Key) async throws -> Value? {
        if let value = values[key] { touch(key); return value }
        guard let loaded = try await loader?(key) else { return nil }
        insert(loaded, for: key)
        return loaded
    }

    public func insert(_ value: Value, for key: Key) {
        values[key] = value; touch(key)
        while recency.count > capacity, let oldest = recency.first {
            recency.removeFirst(); values.removeValue(forKey: oldest)
        }
    }

    public func remove(_ key: Key) { values.removeValue(forKey: key); recency.removeAll { $0 == key } }
    public func removeAll() { values.removeAll(); recency.removeAll() }
    public func handleMemoryPressure() { removeAll() }
    public var count: Int { values.count }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }; recency.append(key)
    }
}
