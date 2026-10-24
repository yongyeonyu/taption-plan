import Foundation

/// `SensorReading` ↔ 열 사이를 **JSON을 거치지 않고** 잇는다.
///
/// 기존 경로는 행 하나에 JSON을 네 번 통과시켰다.
/// 쓰기: `JSONEncoder.encode` → `JSONSerialization.jsonObject`
/// 읽기: `JSONSerialization.data` → `JSONDecoder.decode`
/// `JSONSerialization` 두 번은 오직 "열로 펼치기"와 "열에서 되살리기"를 위해서만 있었고,
/// 대리 측정에서 그 둘이 전체 왕복의 87%를 차지했다(`scripts/codec-proxy-bench.swift`).
///
/// 여기서는 `Codable`이 부르는 컨테이너를 직접 구현해 **같은 모양의 사전**을 바로 만든다.
/// 사전의 모양이 예전과 같으므로 `take`/`put`/`extra` 규칙은 하나도 바뀌지 않는다.
///
/// 지켜야 하는 기존 동작:
/// - `Date`는 `secondsSince1970`(1970년 기준 초)로 저장한다. JSONEncoder의 전략을 우리가 대신 적용한다.
/// - 무한대·NaN은 저장하지 않고 던진다(JSONEncoder 기본 전략과 같다).
/// - 없는 키는 사전에 넣지 않는다(옵셔널 nil).
///
/// 읽기는 이 사전을 만들지 않는다(`TaptionRowDecoder`가 행에서 바로 모델로 간다).
/// 여기 `object(from:)`은 쓰기 경로 전용이다.
enum TaptionColumnObjectCoder {
    static func object(from reading: SensorReading) throws -> [String: Any] {
        let encoder = TaptionObjectEncoder()
        try reading.encode(to: encoder)
        return encoder.box.value as? [String: Any] ?? [:]
    }
}

// MARK: - 쓰기

private final class TaptionObjectBox {
    enum Kind {
        case unset, dictionary, array, single
    }

    var kind: Kind = .unset
    var dictionary: [String: Any] = [:]
    var array: [Any] = []
    var single: Any?

    var value: Any {
        switch kind {
        case .dictionary: dictionary
        case .array: array
        case .single: single ?? NSNull()
        case .unset: [String: Any]()
        }
    }

    func child() -> TaptionObjectBox { TaptionObjectBox() }
}

private final class TaptionObjectEncoder: Encoder {
    let box: TaptionObjectBox
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    init(box: TaptionObjectBox = TaptionObjectBox(), codingPath: [CodingKey] = []) {
        self.box = box
        self.codingPath = codingPath
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        box.kind = .dictionary
        return KeyedEncodingContainer(TaptionObjectKeyedEncoding<Key>(box: box, codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        box.kind = .array
        return TaptionObjectUnkeyedEncoding(box: box, codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        TaptionObjectSingleValueEncoding(box: box, codingPath: codingPath)
    }

    /// 중첩 값(구조체·배열·Date·UUID·enum)을 자식 상자에 담아 돌려준다.
    func encodeNested<T: Encodable>(_ value: T, key: CodingKey?, at index: Int?) throws -> Any {
        if let date = value as? Date {
            return try Self.finite(date.timeIntervalSince1970, path: codingPath)
        }
        let child = box.child()
        try value.encode(to: TaptionObjectEncoder(box: child, codingPath: codingPath + [key ?? TaptionAnyKey(index: index ?? 0)]))
        return child.value
    }

    static func finite(_ value: Double, path: [CodingKey]) throws -> Double {
        guard value.isFinite else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: path,
                    debugDescription: "무한대·NaN은 저장할 수 없다"
                )
            )
        }
        return value
    }
}

private struct TaptionAnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) { self.stringValue = stringValue }
    init(intValue: Int) { self.intValue = intValue; self.stringValue = "\(intValue)" }
    init(index: Int) { self.init(intValue: index) }
}

private struct TaptionObjectKeyedEncoding<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let box: TaptionObjectBox
    let codingPath: [CodingKey]

    private func encoder() -> TaptionObjectEncoder {
        TaptionObjectEncoder(box: box, codingPath: codingPath)
    }

    mutating func encodeNil(forKey key: Key) throws { box.dictionary[key.stringValue] = NSNull() }
    mutating func encode(_ value: Bool, forKey key: Key) throws { box.dictionary[key.stringValue] = value }
    mutating func encode(_ value: String, forKey key: Key) throws { box.dictionary[key.stringValue] = value }
    mutating func encode(_ value: Double, forKey key: Key) throws {
        box.dictionary[key.stringValue] = try TaptionObjectEncoder.finite(value, path: codingPath + [key])
    }
    mutating func encode(_ value: Float, forKey key: Key) throws {
        box.dictionary[key.stringValue] = try TaptionObjectEncoder.finite(Double(value), path: codingPath + [key])
    }
    mutating func encode(_ value: Int, forKey key: Key) throws { box.dictionary[key.stringValue] = value }
    mutating func encode(_ value: Int8, forKey key: Key) throws { box.dictionary[key.stringValue] = Int(value) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { box.dictionary[key.stringValue] = Int(value) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { box.dictionary[key.stringValue] = Int(value) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { box.dictionary[key.stringValue] = Int(value) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { box.dictionary[key.stringValue] = Int(value) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { box.dictionary[key.stringValue] = Int(value) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { box.dictionary[key.stringValue] = Int(value) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { box.dictionary[key.stringValue] = Int(value) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { box.dictionary[key.stringValue] = Int(value) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        box.dictionary[key.stringValue] = try encoder().encodeNested(value, key: key, at: nil)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let child = box.child()
        child.kind = .dictionary
        box.dictionary[key.stringValue] = child.value
        return KeyedEncodingContainer(TaptionObjectKeyedEncoding<NestedKey>(box: child, codingPath: codingPath + [key]))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let child = box.child()
        child.kind = .array
        box.dictionary[key.stringValue] = child.value
        return TaptionObjectUnkeyedEncoding(box: child, codingPath: codingPath + [key])
    }

    mutating func superEncoder() -> Encoder { encoder() }
    mutating func superEncoder(forKey key: Key) -> Encoder { encoder() }
}

private struct TaptionObjectUnkeyedEncoding: UnkeyedEncodingContainer {
    let box: TaptionObjectBox
    let codingPath: [CodingKey]

    var count: Int { box.array.count }

    private func encoder() -> TaptionObjectEncoder {
        TaptionObjectEncoder(box: box, codingPath: codingPath)
    }

    mutating func encodeNil() throws { box.array.append(NSNull()) }
    mutating func encode(_ value: Bool) throws { box.array.append(value) }
    mutating func encode(_ value: String) throws { box.array.append(value) }
    mutating func encode(_ value: Double) throws {
        box.array.append(try TaptionObjectEncoder.finite(value, path: codingPath))
    }
    mutating func encode(_ value: Float) throws {
        box.array.append(try TaptionObjectEncoder.finite(Double(value), path: codingPath))
    }
    mutating func encode(_ value: Int) throws { box.array.append(value) }
    mutating func encode(_ value: Int8) throws { box.array.append(Int(value)) }
    mutating func encode(_ value: Int16) throws { box.array.append(Int(value)) }
    mutating func encode(_ value: Int32) throws { box.array.append(Int(value)) }
    mutating func encode(_ value: Int64) throws { box.array.append(Int(value)) }
    mutating func encode(_ value: UInt) throws { box.array.append(Int(value)) }
    mutating func encode(_ value: UInt8) throws { box.array.append(Int(value)) }
    mutating func encode(_ value: UInt16) throws { box.array.append(Int(value)) }
    mutating func encode(_ value: UInt32) throws { box.array.append(Int(value)) }
    mutating func encode(_ value: UInt64) throws { box.array.append(Int(value)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        box.array.append(try encoder().encodeNested(value, key: nil, at: box.array.count))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let child = box.child()
        child.kind = .dictionary
        box.array.append(child.value)
        return KeyedEncodingContainer(TaptionObjectKeyedEncoding<NestedKey>(box: child, codingPath: codingPath))
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let child = box.child()
        child.kind = .array
        box.array.append(child.value)
        return TaptionObjectUnkeyedEncoding(box: child, codingPath: codingPath)
    }

    mutating func superEncoder() -> Encoder { encoder() }
}

private struct TaptionObjectSingleValueEncoding: SingleValueEncodingContainer {
    let box: TaptionObjectBox
    let codingPath: [CodingKey]

    private func put(_ value: Any) {
        box.kind = .single
        box.single = value
    }

    mutating func encodeNil() throws { put(NSNull()) }
    mutating func encode(_ value: Bool) throws { put(value) }
    mutating func encode(_ value: String) throws { put(value) }
    mutating func encode(_ value: Double) throws { put(try TaptionObjectEncoder.finite(value, path: codingPath)) }
    mutating func encode(_ value: Float) throws { put(try TaptionObjectEncoder.finite(Double(value), path: codingPath)) }
    mutating func encode(_ value: Int) throws { put(value) }
    mutating func encode(_ value: Int8) throws { put(Int(value)) }
    mutating func encode(_ value: Int16) throws { put(Int(value)) }
    mutating func encode(_ value: Int32) throws { put(Int(value)) }
    mutating func encode(_ value: Int64) throws { put(Int(value)) }
    mutating func encode(_ value: UInt) throws { put(Int(value)) }
    mutating func encode(_ value: UInt8) throws { put(Int(value)) }
    mutating func encode(_ value: UInt16) throws { put(Int(value)) }
    mutating func encode(_ value: UInt32) throws { put(Int(value)) }
    mutating func encode(_ value: UInt64) throws { put(Int(value)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        if let date = value as? Date {
            put(try TaptionObjectEncoder.finite(date.timeIntervalSince1970, path: codingPath))
            return
        }
        let child = box.child()
        try value.encode(to: TaptionObjectEncoder(box: child, codingPath: codingPath))
        box.kind = .single
        box.single = child.value
    }
}

// MARK: - 읽기

private struct TaptionObjectDecoder: Decoder {
    let value: Any
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    init(value: Any, codingPath: [CodingKey] = []) {
        self.value = value
        self.codingPath = codingPath
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard let dictionary = value as? [String: Any] else {
            throw DecodingError.typeMismatch(
                [String: Any].self,
                .init(codingPath: codingPath, debugDescription: "사전이 아니다")
            )
        }
        return KeyedDecodingContainer(
            TaptionObjectKeyedDecoding<Key>(dictionary: dictionary, codingPath: codingPath)
        )
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard let array = value as? [Any] else {
            throw DecodingError.typeMismatch([Any].self, .init(codingPath: codingPath, debugDescription: "배열이 아니다"))
        }
        return TaptionObjectUnkeyedDecoding(array: array, codingPath: codingPath)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        TaptionObjectSingleValueDecoding(value: value, codingPath: codingPath)
    }
}

/// 열에서 온 Swift 값과 `extra`에서 온 `NSNumber`를 같은 규칙으로 읽는다.
private enum TaptionObjectPrimitive {
    /// 없는 키(`nil`)도 함께 받는다. `object["timestamp"]`가 `Any?`라서 그대로 넘긴다.
    static func double(_ any: Any?) -> Double? {
        guard let any else { return nil }
        switch any {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as Int64: return Double(value)
        case let value as Int32: return Double(value)
        case let value as NSNumber:
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.doubleValue
        default: return nil
        }
    }

    static func int(_ any: Any) -> Int? {
        switch any {
        case let value as Int: return value
        case let value as Int64: return Int(exactly: value)
        case let value as Int32: return Int(value)
        case let value as Double: return value == value.rounded() ? Int(exactly: value) : nil
        case let value as NSNumber:
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.intValue
        default: return nil
        }
    }

    static func bool(_ any: Any) -> Bool? {
        switch any {
        case let value as Bool: return value
        case let value as NSNumber:
            guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return value.boolValue
        default: return nil
        }
    }

    static func string(_ any: Any) -> String? { any as? String }

    static func isNull(_ any: Any) -> Bool { any is NSNull }
}

private struct TaptionObjectKeyedDecoding<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let dictionary: [String: Any]
    let codingPath: [CodingKey]

    var allKeys: [Key] { dictionary.keys.compactMap(Key.init(stringValue:)) }

    func contains(_ key: Key) -> Bool { dictionary[key.stringValue] != nil }

    func decodeNil(forKey key: Key) throws -> Bool {
        guard let value = dictionary[key.stringValue] else { return true }
        return TaptionObjectPrimitive.isNull(value)
    }

    private func raw(_ key: Key) throws -> Any {
        guard let value = dictionary[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "없는 키"))
        }
        return value
    }

    private func fail<T>(_ key: Key, _ type: T.Type) -> DecodingError {
        DecodingError.typeMismatch(type, .init(codingPath: codingPath + [key], debugDescription: "형태가 다르다"))
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        guard let value = TaptionObjectPrimitive.bool(try raw(key)) else { throw fail(key, type) }
        return value
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        guard let value = TaptionObjectPrimitive.string(try raw(key)) else { throw fail(key, type) }
        return value
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        guard let value = TaptionObjectPrimitive.double(try raw(key)) else { throw fail(key, type) }
        return value
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        guard let value = TaptionObjectPrimitive.double(try raw(key)) else { throw fail(key, type) }
        return Float(value)
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        guard let value = TaptionObjectPrimitive.int(try raw(key)) else { throw fail(key, type) }
        return value
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try narrow(key, type) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try narrow(key, type) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try narrow(key, type) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try narrow(key, type) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try narrow(key, type) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try narrow(key, type) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try narrow(key, type) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try narrow(key, type) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try narrow(key, type) }

    private func narrow<T: FixedWidthInteger>(_ key: Key, _ type: T.Type) throws -> T {
        guard let value = TaptionObjectPrimitive.int(try raw(key)), let narrowed = T(exactly: value) else {
            throw fail(key, type)
        }
        return narrowed
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let value = try raw(key)
        if type == Date.self {
            guard let seconds = TaptionObjectPrimitive.double(value) else { throw fail(key, type) }
            return try TaptionDateCast.cast(seconds, to: type, path: codingPath + [key])
        }
        return try T(from: TaptionObjectDecoder(value: value, codingPath: codingPath + [key]))
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try TaptionObjectDecoder(value: try raw(key), codingPath: codingPath + [key]).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        try TaptionObjectDecoder(value: try raw(key), codingPath: codingPath + [key]).unkeyedContainer()
    }

    func superDecoder() throws -> Decoder { TaptionObjectDecoder(value: dictionary, codingPath: codingPath) }
    func superDecoder(forKey key: Key) throws -> Decoder {
        TaptionObjectDecoder(value: try raw(key), codingPath: codingPath + [key])
    }
}

private struct TaptionObjectUnkeyedDecoding: UnkeyedDecodingContainer {
    let array: [Any]
    let codingPath: [CodingKey]
    var currentIndex = 0

    var count: Int? { array.count }
    var isAtEnd: Bool { currentIndex >= array.count }

    private mutating func next<T>(_ type: T.Type) throws -> Any {
        guard currentIndex < array.count else {
            throw DecodingError.valueNotFound(type, .init(codingPath: codingPath, debugDescription: "배열 끝"))
        }
        defer { currentIndex += 1 }
        return array[currentIndex]
    }

    mutating func decodeNil() throws -> Bool {
        guard currentIndex < array.count else { return true }
        if TaptionObjectPrimitive.isNull(array[currentIndex]) {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        guard let value = TaptionObjectPrimitive.bool(try next(type)) else { throw fail(type) }
        return value
    }

    mutating func decode(_ type: String.Type) throws -> String {
        guard let value = TaptionObjectPrimitive.string(try next(type)) else { throw fail(type) }
        return value
    }

    mutating func decode(_ type: Double.Type) throws -> Double {
        guard let value = TaptionObjectPrimitive.double(try next(type)) else { throw fail(type) }
        return value
    }

    mutating func decode(_ type: Float.Type) throws -> Float {
        guard let value = TaptionObjectPrimitive.double(try next(type)) else { throw fail(type) }
        return Float(value)
    }

    mutating func decode(_ type: Int.Type) throws -> Int {
        guard let value = TaptionObjectPrimitive.int(try next(type)) else { throw fail(type) }
        return value
    }

    mutating func decode(_ type: Int8.Type) throws -> Int8 { try narrow(type) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try narrow(type) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try narrow(type) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try narrow(type) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try narrow(type) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try narrow(type) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try narrow(type) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try narrow(type) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try narrow(type) }

    private mutating func narrow<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard let value = TaptionObjectPrimitive.int(try next(type)), let narrowed = T(exactly: value) else {
            throw fail(type)
        }
        return narrowed
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let value = try next(type)
        if type == Date.self {
            guard let seconds = TaptionObjectPrimitive.double(value) else { throw fail(type) }
            return try TaptionDateCast.cast(seconds, to: type, path: codingPath)
        }
        return try T(from: TaptionObjectDecoder(value: value, codingPath: codingPath))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try TaptionObjectDecoder(value: try next(type), codingPath: codingPath).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        try TaptionObjectDecoder(value: try next([Any].self), codingPath: codingPath).unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder {
        TaptionObjectDecoder(value: try next(Any.self), codingPath: codingPath)
    }

    private func fail<T>(_ type: T.Type) -> DecodingError {
        DecodingError.typeMismatch(type, .init(codingPath: codingPath, debugDescription: "형태가 다르다"))
    }
}

private struct TaptionObjectSingleValueDecoding: SingleValueDecodingContainer {
    let value: Any
    let codingPath: [CodingKey]

    private func fail<T>(_ type: T.Type) -> DecodingError {
        DecodingError.typeMismatch(type, .init(codingPath: codingPath, debugDescription: "형태가 다르다"))
    }

    func decodeNil() -> Bool { TaptionObjectPrimitive.isNull(value) }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard let value = TaptionObjectPrimitive.bool(value) else { throw fail(type) }
        return value
    }

    func decode(_ type: String.Type) throws -> String {
        guard let value = TaptionObjectPrimitive.string(value) else { throw fail(type) }
        return value
    }

    func decode(_ type: Double.Type) throws -> Double {
        guard let value = TaptionObjectPrimitive.double(value) else { throw fail(type) }
        return value
    }

    func decode(_ type: Float.Type) throws -> Float {
        guard let value = TaptionObjectPrimitive.double(value) else { throw fail(type) }
        return Float(value)
    }

    func decode(_ type: Int.Type) throws -> Int {
        guard let value = TaptionObjectPrimitive.int(value) else { throw fail(type) }
        return value
    }

    func decode(_ type: Int8.Type) throws -> Int8 { try narrow(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try narrow(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try narrow(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try narrow(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try narrow(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try narrow(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try narrow(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try narrow(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try narrow(type) }

    private func narrow<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard let number = TaptionObjectPrimitive.int(value), let narrowed = T(exactly: number) else {
            throw fail(type)
        }
        return narrowed
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if type == Date.self {
            guard let seconds = TaptionObjectPrimitive.double(value) else { throw fail(type) }
            return try TaptionDateCast.cast(seconds, to: type, path: codingPath)
        }
        return try T(from: TaptionObjectDecoder(value: value, codingPath: codingPath))
    }
}

private enum TaptionDateCast {
    static func cast<T>(_ seconds: Double, to type: T.Type, path: [CodingKey]) throws -> T {
        guard let date = Date(timeIntervalSince1970: seconds) as? T else {
            throw DecodingError.typeMismatch(
                type,
                .init(codingPath: path, debugDescription: "Date로 읽을 수 없다")
            )
        }
        return date
    }
}

// MARK: - 행 ↔ 모델 (동결 파일에서 옮겨 왔다)

extension TaptionReadingRowCodec {
    /// 열 경로를 **한 번만** 쪼개 둔다. 경로 문자열은 고정인데, 예전에는 `take`/`put`이
    /// 행마다 56번 `path.split(separator: ".")`을 했다. 1,000행 기준 그 비용만 53.2ms로
    /// 읽기 경로(134.3ms)의 40%였다(`testReadPathBreakdown`).
    static let columnParts: [[String]] = columns.map { $0.path.split(separator: ".").map(String.init) }

    private static let columnPartsByName: [String: [String]] = Dictionary(
        uniqueKeysWithValues: zip(columns.map(\.name), columnParts)
    )

    /// 열 하나의 경로 조각. `columns`에 없는 열(테스트가 직접 만든 열)은 그때 쪼갠다.
    static func parts(of column: Column) -> [String] {
        columnPartsByName[column.name] ?? column.path.split(separator: ".").map(String.init)
    }

    /// `SensorReading` → 저장할 행. JSON을 거치지 않고 같은 모양의 사전을 만든 뒤 열로 펼친다.
    static func row(for reading: SensorReading, calendar: Calendar) throws -> Row {
        var object = try TaptionColumnObjectCoder.object(from: reading)
        guard let id = object["id"] as? String, uuidData(id) != nil,
              let timestamp = TaptionObjectPrimitive.double(object["timestamp"]) else {
            throw TaptionStoreV2Error.corruptRow("reading without a UUID id or timestamp")
        }
        object["id"] = nil
        object["timestamp"] = nil
        var values: [Value] = []
        values.reserveCapacity(columns.count)
        for (index, column) in columns.enumerated() {
            values.append(take(column, parts: columnParts[index], from: &object))
        }
        // 열이 덮지 않은 필드만 `extra`로 남는다(지금 모델에서는 deviceMotion·behaviorEvidence 등).
        let extra: String? = object.isEmpty ? nil : String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            as: UTF8.self
        )
        return Row(
            id: id,
            timestamp: timestamp,
            day: dayNumber(for: Date(timeIntervalSince1970: timestamp), calendar: calendar),
            values: values,
            extra: extra
        )
    }

    /// 저장된 행 → `SensorReading`. 사전을 만들지 않고 행의 열 값에서 바로 모델을 채운다.
    static func reading(from row: Row) throws -> SensorReading {
        var extra: [String: Any] = [:]
        if let text = row.extra {
            guard let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw TaptionStoreV2Error.corruptRow("extra is not an object")
            }
            extra = parsed
        }
        do {
            return try SensorReading(
                from: TaptionRowDecoder(row: row, extra: extra, scope: .root, codingPath: [])
            )
        } catch {
            throw TaptionStoreV2Error.corruptRow("reading \(row.id): \(error)")
        }
    }
}

// MARK: - 행 → 모델 (사전 없이)

/// 행 하나를 디코딩할 때 보는 범위. `point` 같은 중첩 구조체는 그 안의 열만 본다.
private enum TaptionRowScope: Equatable {
    case root
    case nested(String)
}

/// 디코더가 꺼낸 값. 열에서 온 값은 `Value` enum 그대로라 동적 캐스팅이 없고,
/// `extra`에서 온 값만 `Any`로 다룬다.
private enum TaptionRowValue {
    case column(TaptionReadingRowCodec.Value)
    case nested([String: Int])
    case extra(Any)
}

extension TaptionReadingRowCodec {
    /// 단일 조각 경로 → 열 위치. 디코딩할 때마다 경로 문자열을 훑지 않으려고 한 번만 만든다.
    static let columnIndexByPath: [String: Int] = {
        var map: [String: Int] = [:]
        map.reserveCapacity(columns.count)
        for (index, column) in columns.enumerated() where !column.path.contains(".") {
            map[column.path] = index
        }
        return map
    }()

    /// 중첩 경로(`point.latitude`)를 바깥 키별로 모은다.
    static let nestedColumnIndex: [String: [String: Int]] = {
        var map: [String: [String: Int]] = [:]
        for (index, column) in columns.enumerated() where column.path.contains(".") {
            let parts = columnParts[index]
            guard parts.count == 2 else { continue }
            map[parts[0], default: [:]][parts[1]] = index
        }
        return map
    }()
}

private struct TaptionRowDecoder: Decoder {
    let row: TaptionReadingRowCodec.Row
    let extra: [String: Any]
    let scope: TaptionRowScope
    let codingPath: [CodingKey]

    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(
            TaptionRowKeyedDecoding<Key>(row: row, extra: extra, scope: scope, codingPath: codingPath)
        )
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch(
            [Any].self,
            .init(codingPath: codingPath, debugDescription: "행은 배열이 아니다")
        )
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        throw DecodingError.typeMismatch(
            Any.self,
            .init(codingPath: codingPath, debugDescription: "행은 단일 값이 아니다")
        )
    }
}

private struct TaptionRowKeyedDecoding<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let row: TaptionReadingRowCodec.Row
    let extra: [String: Any]
    let scope: TaptionRowScope
    let codingPath: [CodingKey]

    var allKeys: [Key] {
        switch scope {
        case .root:
            var names = Set(TaptionReadingRowCodec.columnIndexByPath.keys)
            names.formUnion(extra.keys)
            names.insert("id")
            names.insert("timestamp")
            return names.compactMap(Key.init(stringValue:))
        case .nested(let outer):
            guard let inner = TaptionReadingRowCodec.nestedColumnIndex[outer] else { return [] }
            return inner.keys.compactMap(Key.init(stringValue:))
        }
    }

    /// 행에 값이 모자란 손상된 행도 크래시 없이 `.null`로 읽는다.
    private func column(_ index: Int) -> TaptionReadingRowCodec.Value {
        row.values.indices.contains(index) ? row.values[index] : .null
    }

    private func value(for key: Key) -> TaptionRowValue? {
        switch scope {
        case .root:
            if key.stringValue == "id" { return .column(.text(row.id)) }
            if key.stringValue == "timestamp" { return .column(.real(row.timestamp)) }
            if let index = TaptionReadingRowCodec.columnIndexByPath[key.stringValue] {
                return .column(column(index))
            }
            if let inner = TaptionReadingRowCodec.nestedColumnIndex[key.stringValue] {
                return .nested(inner)
            }
            if let any = extra[key.stringValue] { return .extra(any) }
            return nil
        case .nested(let outer):
            if let index = TaptionReadingRowCodec.nestedColumnIndex[outer]?[key.stringValue] {
                return .column(column(index))
            }
            return nil
        }
    }

    /// `put`이 `.null`을 사전에 넣지 않던 동작과 같다. 중첩 구조체는 안의 값이 하나도 없을 때만 비었다고 본다.
    func contains(_ key: Key) -> Bool {
        switch value(for: key) {
        case .none:
            return false
        case .column(.null):
            return false
        case .nested(let inner):
            return inner.values.contains { column($0) != .null }
        case .column:
            return true
        case .extra(let any):
            return !TaptionObjectPrimitive.isNull(any)
        }
    }

    func decodeNil(forKey key: Key) throws -> Bool { !contains(key) }

    private func fail<T>(_ key: Key, _ type: T.Type) -> DecodingError {
        DecodingError.typeMismatch(type, .init(codingPath: codingPath + [key], debugDescription: "형태가 다르다"))
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        switch value(for: key) {
        case .column(.int(let number)):
            return number != 0
        case .extra(let any):
            guard let value = TaptionObjectPrimitive.bool(any) else { throw fail(key, type) }
            return value
        default:
            throw fail(key, type)
        }
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        switch value(for: key) {
        case .column(.text(let text)):
            return text
        case .extra(let any):
            guard let value = TaptionObjectPrimitive.string(any) else { throw fail(key, type) }
            return value
        default:
            throw fail(key, type)
        }
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        switch value(for: key) {
        case .column(.real(let number)):
            return number
        case .column(.int(let number)):
            return Double(number)
        case .extra(let any):
            guard let value = TaptionObjectPrimitive.double(any) else { throw fail(key, type) }
            return value
        default:
            throw fail(key, type)
        }
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        Float(try decode(Double.self, forKey: key))
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        switch value(for: key) {
        case .column(.int(let number)):
            return Int(number)
        case .column(.real(let number)):
            guard number == number.rounded(), let value = Int(exactly: number) else { throw fail(key, type) }
            return value
        case .extra(let any):
            guard let value = TaptionObjectPrimitive.int(any) else { throw fail(key, type) }
            return value
        default:
            throw fail(key, type)
        }
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try narrow(key, type) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try narrow(key, type) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try narrow(key, type) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try narrow(key, type) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try narrow(key, type) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try narrow(key, type) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try narrow(key, type) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try narrow(key, type) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try narrow(key, type) }

    private func narrow<T: FixedWidthInteger>(_ key: Key, _ type: T.Type) throws -> T {
        guard let number = try? decode(Int.self, forKey: key), let narrowed = T(exactly: number) else {
            throw fail(key, type)
        }
        return narrowed
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        switch value(for: key) {
        case .nested:
            return try T(
                from: TaptionRowDecoder(
                    row: row, extra: extra, scope: .nested(key.stringValue), codingPath: codingPath + [key]
                )
            )
        case .extra(let any):
            if type == Date.self {
                guard let seconds = TaptionObjectPrimitive.double(any) else { throw fail(key, type) }
                return try TaptionDateCast.cast(seconds, to: type, path: codingPath + [key])
            }
            return try T(from: TaptionObjectDecoder(value: any, codingPath: codingPath + [key]))
        case .column(let value):
            if type == Date.self, case .real(let seconds) = value {
                return try TaptionDateCast.cast(seconds, to: type, path: codingPath + [key])
            }
            // UUID·enum처럼 문자열에서 만드는 타입은 기존 단일값 디코더에 그대로 넘긴다.
            if case .text(let text) = value {
                return try T(from: TaptionObjectDecoder(value: text, codingPath: codingPath + [key]))
            }
            throw fail(key, type)
        case .none:
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "없는 키"))
        }
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        KeyedDecodingContainer(
            TaptionRowKeyedDecoding<NestedKey>(
                row: row, extra: extra, scope: .nested(key.stringValue), codingPath: codingPath + [key]
            )
        )
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch(
            [Any].self,
            .init(codingPath: codingPath + [key], debugDescription: "행은 배열이 아니다")
        )
    }

    func superDecoder() throws -> Decoder {
        TaptionRowDecoder(row: row, extra: extra, scope: scope, codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        TaptionRowDecoder(row: row, extra: extra, scope: scope, codingPath: codingPath + [key])
    }
}

// MARK: - 같은 내용인지

extension TaptionReadingRowCodec {
    /// 실수 비교에 두는 상대오차. 1 ULP는 약 2.2e-16이고 예전 파서의 실측 오차는 최대 5 ULP였다.
    /// 이 값은 그 1,000배쯤이라 비트 수준 차이는 모두 덮고, 센서 값의 의미 있는 변화는 잡는다.
    static let storedRealTolerance = 1e-12

    /// 두 기록이 저장소에 **같은 내용**으로 저장되는지. `Date`가 1970년 기준 초로 반올림되는
    /// 표현 차이는 무시하려고 저장 형태로 비교한다.
    ///
    /// P1부터 실수의 마지막 비트가 예전과 다를 수 있다. 예전 경로는 모델을 JSON 텍스트로 쓴 뒤
    /// `JSONSerialization`으로 다시 읽었는데, 그 **파서가 double을 몇 ULP 잘라냈다**:
    /// `0.019532305288943785` → `0.01953230528894378`. 표본 1,000행에서 잰 최대 차이는 5 ULP였다.
    /// 같은 텍스트를 `Double(_:)`로 읽으면 정확히 복원되므로 손실은 파서 한 곳에서만 생겼다.
    /// 지금은 그 단계가 없어 값이 정확하다.
    /// 그래서 실수는 상대오차 `storedRealTolerance`까지 같은 값으로 본다. 그보다 크면 예전처럼 충돌이다.
    static func sameStoredContent(_ lhs: SensorReading, _ rhs: SensorReading) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let left = try? row(for: lhs, calendar: calendar),
              let right = try? row(for: rhs, calendar: calendar) else { return false }
        return matchesStoredContent(left, right)
    }

    static func matchesStoredContent(_ left: Row, _ right: Row) -> Bool {
        guard left.id == right.id,
              left.timestamp == right.timestamp,
              left.day == right.day,
              left.values.count == right.values.count,
              sameExtra(left.extra, right.extra) else { return false }
        for (lhs, rhs) in zip(left.values, right.values) where !sameValue(lhs, rhs) {
            return false
        }
        return true
    }

    static func sameReal(_ lhs: Double, _ rhs: Double) -> Bool {
        if lhs == rhs { return true }
        guard lhs.isFinite, rhs.isFinite else { return false }
        return abs(lhs - rhs) <= max(abs(lhs), abs(rhs)) * storedRealTolerance
    }

    private static func sameValue(_ lhs: Value, _ rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.int(let lhs), .int(let rhs)):
            return lhs == rhs
        case (.real(let lhs), .real(let rhs)):
            return sameReal(lhs, rhs)
        case (.text(let lhs), .text(let rhs)):
            return lhs == rhs
        case (.blob(let lhs), .blob(let rhs)):
            return lhs == rhs
        default:
            return false
        }
    }

    private static func sameExtra(_ lhs: String?, _ rhs: String?) -> Bool {
        if lhs == rhs { return true }
        guard let lhs, let rhs,
              let left = try? JSONSerialization.jsonObject(with: Data(lhs.utf8)) as? [String: Any],
              let right = try? JSONSerialization.jsonObject(with: Data(rhs.utf8)) as? [String: Any] else {
            return false
        }
        return sameAny(left, right)
    }

    private static func sameAny(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (_ as NSNull, _ as NSNull):
            return true
        case (let left as NSNumber, let right as NSNumber):
            let leftIsBool = CFGetTypeID(left) == CFBooleanGetTypeID()
            let rightIsBool = CFGetTypeID(right) == CFBooleanGetTypeID()
            guard leftIsBool == rightIsBool else { return false }
            return leftIsBool ? left.boolValue == right.boolValue : sameReal(left.doubleValue, right.doubleValue)
        case (let left as String, let right as String):
            return left == right
        case (let left as [Any], let right as [Any]):
            return left.count == right.count && zip(left, right).allSatisfy { sameAny($0, $1) }
        case (let left as [String: Any], let right as [String: Any]):
            return left.keys.sorted() == right.keys.sorted() && left.allSatisfy { sameAny($0.value, right[$0.key]) }
        default:
            return false
        }
    }
}
