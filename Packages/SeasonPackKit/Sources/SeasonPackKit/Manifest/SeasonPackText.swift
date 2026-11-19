import Foundation

/// 언어 코드별 문구 한 벌. 매니페스트의 `{ "ko": "…", "en": "…" }` 모양이다.
/// 고르는 순서: 코드 그대로 → 하이픈 앞 언어 → 영어 → 한국어 → 아무거나(정렬 첫째). 빈 문자열은 없는 것으로 본다.
public struct SeasonPackText: Codable, Sendable, Equatable, Hashable {
    public var values: [String: String]

    public init(_ values: [String: String]) { self.values = values }
    public init(ko: String, en: String) { self.values = ["ko": ko, "en": en] }

    public init(from decoder: Decoder) throws {
        let scalars = try decoder.singleValueContainer().decode([String: SeasonPackScalar].self)
        self.values = scalars.compactMapValues(\.text)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    public func resolve(language code: String) -> String {
        let base = code.split(separator: "-").first.map(String.init) ?? code
        for key in [code, base, "en", "ko"] {
            if let text = values[key], !text.isEmpty { return text }
        }
        return values.sorted { $0.key < $1.key }.first { !$0.value.isEmpty }?.value ?? ""
    }

    /// 패키지가 직접 그리는 화면 문구(앱의 `language.text` 자리). 한국어만 한국어고 나머지는 영어다.
    public static func ui(_ ko: String, _ en: String, language code: String) -> String {
        code == "ko" || code.hasPrefix("ko-") ? ko : en
    }
}

/// 문자열이든 숫자든 받아 두는 값. 큐처럼 `atMs`(숫자)와 언어 문구가 한 객체에 섞인 곳에서 쓴다.
struct SeasonPackScalar: Decodable, Sendable {
    let text: String?
    let number: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            text = string; number = nil
        } else if let value = try? container.decode(Double.self) {
            text = nil; number = value
        } else {
            text = nil; number = nil
        }
    }
}
