import Foundation

/// 저장된 기록의 ID를 만드는 해시들. 결과가 바뀌면 기존 기록과 이어지지 않으므로
/// `StableRecordIDTests`의 고정값을 고치지 않는다. 방식이 여럿인 것은 기록마다 처음 쓴 값을 지키기 때문이다.
enum StableRecordID {
    /// HealthKit 가져오기·행동 투영.
    static func dualFNV(_ seed: String) -> UUID {
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x9e3779b185ebca87
        for byte in seed.utf8 {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second = (second ^ UInt64(byte)) &* 0x9e3779b185ebca87
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8((first >> UInt64(index * 8)) & 0xff)
            bytes[index + 8] = UInt8((second >> UInt64(index * 8)) & 0xff)
        }
        return version5UUID(bytes)
    }

    /// 앱 사용 기록과 움직임 활동.
    static func goldenMixedFNV(_ key: String) -> UUID {
        var hash = fnvOffset
        var bytes = [UInt8](repeating: 0, count: 16)
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* fnvPrime
        }
        for index in bytes.indices {
            hash ^= UInt64(index + 1) * 0x9E37_79B9
            hash = hash &* fnvPrime
            bytes[index] = UInt8(truncatingIfNeeded: hash >> ((index % 8) * 8))
        }
        return version5UUID(bytes)
    }

    /// 추정 수면.
    static func indexMixedFNV(_ key: String) -> UUID {
        var hash = fnvOffset
        var bytes = [UInt8](repeating: 0, count: 16)
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* fnvPrime
        }
        for index in bytes.indices {
            hash = (hash ^ UInt64(index + 1)) &* fnvPrime
            bytes[index] = UInt8(truncatingIfNeeded: hash >> ((index % 8) * 8))
        }
        return version5UUID(bytes)
    }

    /// 기록 요약과 시간표의 활동 조각.
    static func foldedFNV(_ seed: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var hash = fnvOffset
        for (index, byte) in seed.utf8.enumerated() {
            hash ^= UInt64(byte)
            hash = hash &* fnvPrime
            bytes[index % bytes.count] ^= UInt8(truncatingIfNeeded: hash >> 24)
        }
        return version5UUID(bytes)
    }

    /// 나뉜 실적의 뒷조각.
    static func remainder(of id: UUID, offset: Int) -> UUID {
        var bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        var hash = fnvOffset &+ UInt64(offset)
        for index in bytes.indices {
            hash ^= UInt64(bytes[index])
            hash = hash &* fnvPrime
            bytes[index] = UInt8(truncatingIfNeeded: hash >> 24)
        }
        return version5UUID(bytes)
    }

    private static let fnvOffset: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211

    private static func version5UUID(_ source: [UInt8]) -> UUID {
        var bytes = source
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
