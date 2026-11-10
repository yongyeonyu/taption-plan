import Foundation

/// 패키지에 든 여행 자료(요금표·계획 규칙). 파일만 바꾸면 값이 바뀐다.
enum TravelBundledData {
    static func data(_ name: String, _ fileExtension: String) -> Data? {
        Bundle.module.url(forResource: name, withExtension: fileExtension).flatMap { try? Data(contentsOf: $0) }
    }
}

/// 한 항목이 틀려도 나머지는 읽는다(없는 키가 있는 지역·수단만 빠진다).
public struct TravelLossyMap<Value: Decodable & Sendable>: Decodable, Sendable {
    public let values: [String: Value]

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        values = container.allKeys.reduce(into: [:]) { result, key in
            result[key.stringValue] = try? container.decode(Value.self, forKey: key)
        }
    }

    public subscript(key: String) -> Value? { values[key] }
}
