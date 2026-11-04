import Foundation

/// `text("한글", "English")`의 인자. 보간 값을 따로 받아, 번역문에 영어 쪽 값을 넣을 수 있게 한다.
public struct UIPhrase: ExpressibleByStringInterpolation, Sendable {
    public let text: String
    let template: String
    let arguments: [String]

    public init(stringLiteral value: String) {
        text = value
        template = value
        arguments = []
    }

    public init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.text
        template = stringInterpolation.template
        arguments = stringInterpolation.arguments
    }

    init(runtime value: String) {
        self.init(stringLiteral: value)
    }

    init(text: String, template: String, arguments: [String]) {
        self.text = text
        self.template = template
        self.arguments = arguments
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var text = ""
        var template = ""
        var arguments: [String] = []

        public init(literalCapacity: Int, interpolationCount: Int) {}

        public mutating func appendLiteral(_ literal: String) {
            text += literal
            if UITextPack.bundleLanguageCode != nil { template += literal }
        }

        public mutating func appendInterpolation<T>(_ value: T) {
            let rendered = "\(value)"
            text += rendered
            if UITextPack.bundleLanguageCode != nil {
                template += "{\(arguments.count)}"
                arguments.append(rendered)
            }
        }
    }
}

/// 한국어·영어 밖의 언어 문구. 표는 각 제품 번들의 `UIText.xcstrings`이고 `scripts/l10n`이 만든다.
public enum UITextPack {
    public static let tableName = "UIText"

    /// 번들이 고른 언어가 한국어·영어가 아니면 그 코드. 한국어·영어에서는 nil이라 조회 비용이 없다.
    public static let bundleLanguageCode: String? = translatedCode(
        preferred: Bundle.main.preferredLocalizations.first
    )

    /// 지금 번역을 써야 할 언어. 언어 메뉴에서 한국어·영어를 고정했다면 nil이다.
    public static var activeLanguageCode: String? {
        guard let bundleLanguageCode else { return nil }
        return AppLanguagePreference.current == .automatic ? bundleLanguageCode : nil
    }

    /// 번역 언어의 형식 지역. 기기 지역이 같은 언어를 쓰면 기기 지역을 그대로 쓴다.
    public static var activeLocale: Locale? {
        guard let code = activeLanguageCode else { return nil }
        let current = Locale.current
        let codeLanguage = Locale(identifier: code).language
        return current.language.languageCode == codeLanguage.languageCode
            ? current
            : Locale(identifier: code)
    }

    public static func translate(korean: UIPhrase, english: UIPhrase) -> String {
        guard activeLanguageCode != nil else { return english.text }
        return translate(korean: korean, english: english, lookup: bundleLookup)
    }

    /// 코드에 영어만 있는 표(이름 사전 등)의 번역. 없으면 영어를 그대로 돌려준다.
    public static func translate(english: String) -> String {
        guard activeLanguageCode != nil else { return english }
        return bundleLookup(enOnlyKey(english)) ?? english
    }

    static func translate(
        korean: UIPhrase,
        english: UIPhrase,
        lookup: (String) -> String?
    ) -> String {
        let key = korean.template + separator + english.template
        guard let translated = lookup(key)
            ?? lookup(enOnlyKey(english.template))
        else { return english.text }
        return fill(translated, with: english.arguments)
    }

    static func translatedCode(preferred: String?) -> String? {
        guard let preferred, preferred != "Base" else { return nil }
        let language = Locale(identifier: preferred).language.languageCode?.identifier ?? preferred
        return language == "ko" || language == "en" ? nil : preferred
    }

    static func enOnlyKey(_ english: String) -> String {
        separator + english
    }

    /// `{0}` 자리에 값을 넣는다. 번역문은 자리를 건너뛰거나 순서를 바꿀 수 있다.
    static func fill(_ template: String, with arguments: [String]) -> String {
        guard !arguments.isEmpty, template.contains("{") else { return template }
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let tail = rest[rest.index(after: open)...]
            if let close = tail.firstIndex(of: "}"),
               let index = Int(tail[..<close]),
               arguments.indices.contains(index) {
                result += arguments[index]
                rest = tail[tail.index(after: close)...]
            } else {
                result += "{"
                rest = tail
            }
        }
        return result + rest
    }

    private static let separator = "|"
    private static let missing = "\u{1}"

    private static func bundleLookup(_ key: String) -> String? {
        let value = Bundle.main.localizedString(forKey: key, value: missing, table: tableName)
        return value == missing ? nil : value
    }
}
