import Foundation
import TaptionPlanCore

public enum AppLanguagePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case korean
    case english

    public enum ResolvedLanguage: String, Codable, CaseIterable, Sendable {
        case korean
        case english

        public var locale: Locale {
            switch self {
            case .korean: Locale(identifier: "ko_KR")
            case .english: Locale(identifier: "en_US")
            }
        }

        /// 이 언어에 맞는 쪽 문구. 화면이 이미 언어를 알고 있을 때 쓴다.
        public func text(_ korean: String, _ english: String) -> String {
            self == .korean ? korean : english
        }
    }

    public static let appGroupIdentifier = TaptionPlanSharedContainer.appGroupIdentifier
    public static let sharedDefaultsKey = "taption.app.language.preference"
    public static let legacyDefaultsKey = "taption.mapHome.language"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: "자동"
        case .korean: "한국어"
        case .english: "English"
        }
    }

    public var resolvedLanguage: ResolvedLanguage {
        Self.resolve(rawValue: rawValue)
    }

    public var watchPayloadValue: String? {
        self == .automatic ? nil : rawValue
    }

    public static var current: Self {
        if let groupDefaults = UserDefaults(suiteName: appGroupIdentifier),
           let rawValue = groupDefaults.string(forKey: sharedDefaultsKey) {
            return Self(rawValue: rawValue) ?? .automatic
        }
        if let rawValue = UserDefaults.standard.string(
            forKey: sharedDefaultsKey
        ) {
            return Self(rawValue: rawValue) ?? .automatic
        }
        if let rawValue = UserDefaults.standard.string(
            forKey: legacyDefaultsKey
        ) {
            return Self(rawValue: rawValue) ?? .automatic
        }
        return .automatic
    }

    public static func load(
        from defaults: UserDefaults,
        key: String = sharedDefaultsKey
    ) -> Self {
        storedPreference(in: defaults, key: key) ?? .automatic
    }

    public static func save(
        _ preference: Self,
        to defaults: UserDefaults? = nil
    ) {
        let target = defaults ?? sharedDefaults
        target.set(preference.rawValue, forKey: sharedDefaultsKey)

        if defaults == nil {
            UserDefaults.standard.set(
                preference.rawValue,
                forKey: legacyDefaultsKey
            )
            UserDefaults.standard.set(
                preference.rawValue,
                forKey: sharedDefaultsKey
            )
        }
    }

    public static func resolve(
        rawValue: String?,
        locale: Locale = .current
    ) -> ResolvedLanguage {
        switch Self(rawValue: rawValue ?? "") ?? .automatic {
        case .korean:
            return .korean
        case .english:
            return .english
        case .automatic:
            let languageCode = locale.language.languageCode?.identifier ?? ""
            return languageCode.lowercased().hasPrefix("ko")
                ? .korean
                : .english
        }
    }

    /// 지금 설정(`current`)에 맞는 쪽 문구.
    public static func text(_ korean: String, _ english: String) -> String {
        current.resolvedLanguage.text(korean, english)
    }

    public static func text(
        korean: String,
        english: String,
        preference: Self = .current
    ) -> String {
        preference.resolvedLanguage == .korean ? korean : english
    }

    public static func text(
        korean: String,
        english: String,
        rawPreference: String?,
        locale: Locale = .current
    ) -> String {
        resolve(rawValue: rawPreference, locale: locale) == .korean
            ? korean
            : english
    }

    public static func localized(
        _ key: String,
        rawPreference: String? = nil,
        locale: Locale = .current,
        bundle: Bundle = .main
    ) -> String {
        let resolved = resolve(
            rawValue: rawPreference ?? current.rawValue,
            locale: locale
        )
        let code = resolved == .korean ? "ko" : "en"
        guard let url = bundle.url(
            forResource: code,
            withExtension: "lproj"
        ), let localizedBundle = Bundle(url: url) else {
            return key
        }
        return localizedBundle.localizedString(
            forKey: key,
            value: key,
            table: nil
        )
    }

    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    private static func storedPreference(
        in defaults: UserDefaults,
        key: String
    ) -> Self? {
        guard let rawValue = defaults.string(forKey: key) else {
            return nil
        }
        return Self(rawValue: rawValue)
    }
}
