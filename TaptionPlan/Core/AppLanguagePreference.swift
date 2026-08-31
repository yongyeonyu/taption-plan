import Foundation
import TaptionPlanCore

enum AppLanguagePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case korean
    case english

    enum ResolvedLanguage: String, Codable, CaseIterable, Sendable {
        case korean
        case english

        var locale: Locale {
            switch self {
            case .korean: Locale(identifier: "ko_KR")
            case .english: Locale(identifier: "en_US")
            }
        }
    }

    static let appGroupIdentifier = TaptionPlanSharedContainer.appGroupIdentifier
    static let sharedDefaultsKey = "taption.app.language.preference"
    static let legacyDefaultsKey = "taption.mapHome.language"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "자동"
        case .korean: "한국어"
        case .english: "English"
        }
    }

    var resolvedLanguage: ResolvedLanguage {
        Self.resolve(rawValue: rawValue)
    }

    var watchPayloadValue: String? {
        self == .automatic ? nil : rawValue
    }

    static var current: Self {
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

    static func load(
        from defaults: UserDefaults,
        key: String = sharedDefaultsKey
    ) -> Self {
        storedPreference(in: defaults, key: key) ?? .automatic
    }

    static func save(
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

    static func resolve(
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

    static func text(
        korean: String,
        english: String,
        preference: Self = .current
    ) -> String {
        preference.resolvedLanguage == .korean ? korean : english
    }

    static func text(
        korean: String,
        english: String,
        rawPreference: String?,
        locale: Locale = .current
    ) -> String {
        resolve(rawValue: rawPreference, locale: locale) == .korean
            ? korean
            : english
    }

    static func localized(
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
