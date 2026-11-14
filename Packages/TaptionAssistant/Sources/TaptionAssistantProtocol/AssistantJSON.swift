import Foundation

/// 명령에 실려 온 값 하나.
public enum AssistantJSON: Decodable, Equatable, Sendable {
    case text(String), number(Double), flag(Bool), list([AssistantJSON]), object([String: AssistantJSON]), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let flag = try? value.decode(Bool.self) { self = .flag(flag) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let text = try? value.decode(String.self) { self = .text(text) }
        else if let list = try? value.decode([AssistantJSON].self) { self = .list(list) }
        else { self = .object(try value.decode([String: AssistantJSON].self)) }
    }
}

/// 명령의 칸을 이름으로 읽는다. 형이 틀리면 nil이고, `ok`로 「준 칸은 다 읽혔는가」를 본다.
public struct AssistantFields: Sendable {
    public var values: [String: AssistantJSON]
    public var now: Date = .now
    public var calendar: Calendar = .autoupdatingCurrent

    public init(values: [String: AssistantJSON], now: Date = .now, calendar: Calendar = .autoupdatingCurrent) {
        self.values = values
        self.now = now
        self.calendar = calendar
    }

    public var name: String? { raw("action") }

    /// 칸이 있는가. null은 없는 것으로 본다(서버와 같다).
    public func has(_ name: String) -> Bool { values[name].map { $0 != .null } ?? false }

    /// 주지 않았거나, 주었고 읽혔다.
    public func ok(_ name: String, _ value: (some Any)?) -> Bool { !has(name) || value != nil }

    public func raw(_ name: String) -> String? {
        if case let .text(text)? = values[name] { return text }
        return nil
    }

    /// 앞뒤 공백을 뗀 1~max자.
    public func string(_ name: String, max: Int) -> String? { AssistantCommandParser.clean(raw(name), max: max) }

    public func number(_ name: String) -> Double? {
        if case let .number(number)? = values[name], number.isFinite { return number }
        return nil
    }

    public func integer(_ name: String, in range: ClosedRange<Int>) -> Int? {
        guard let number = number(name), number == number.rounded(), abs(number) < 1e12, range.contains(Int(number)) else { return nil }
        return Int(number)
    }

    public func flag(_ name: String) -> Bool? {
        if case let .flag(flag)? = values[name] { return flag }
        return nil
    }

    /// 서로 다른 글 목록. 하나라도 비었거나 길면 nil.
    public func texts(_ name: String, max: Int, count: ClosedRange<Int>) -> [String]? {
        guard case let .list(items)? = values[name], count.contains(items.count) else { return nil }
        let cleaned = items.compactMap { item -> String? in
            if case let .text(text) = item { return AssistantCommandParser.clean(text, max: max) }
            return nil
        }
        return cleaned.count == items.count && Set(cleaned).count == cleaned.count ? cleaned : nil
    }

    public func uuid(_ name: String) -> UUID? { raw(name).flatMap(UUID.init(uuidString:)) }

    /// `YYYY-MM-DD` → 그날 0시.
    public func day(_ name: String) -> Date? { raw(name).flatMap { AssistantCommandParser.day($0, calendar: calendar) } }

    /// `HH:mm` → 자정부터의 분.
    public func minutes(_ name: String) -> Int? { raw(name).flatMap(AssistantCommandParser.minutes) }

    /// 오프셋이 붙은 ISO 시각.
    public func instant(_ name: String) -> Date? { raw(name).flatMap(AssistantCommandParser.instant) }

    public func choice<Value: RawRepresentable>(_ name: String, _ type: Value.Type = Value.self) -> Value? where Value.RawValue == String {
        raw(name).flatMap(Value.init(rawValue:))
    }
}

/// 명령의 `value`처럼 글자·숫자·참거짓이 다 올 수 있는 칸(ACB1112A01).
public enum AssistantLooseValue: Decodable, Equatable, Sendable {
    case flag(Bool)
    case number(Double)
    case text(String)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let flag = try? value.decode(Bool.self) { self = .flag(flag) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else { self = .text(try value.decode(String.self)) }
    }
}
