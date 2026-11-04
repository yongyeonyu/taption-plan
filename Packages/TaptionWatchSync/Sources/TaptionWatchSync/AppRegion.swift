import Foundation
import os

/// 언어를 따라 정해지는 통화·거리·온도 표시. 저장하지 않고, 저장값과 숫자는 바꾸지 않는다.
public struct AppRegion: Equatable, Sendable {
    public let currencyCode: String
    public let currencyUnit: String
    public let usesDecimalCurrency: Bool
    public let locale: Locale
    public let usesMiles: Bool
    public let usesFahrenheit: Bool

    /// 기기 지역의 주 언어가 앱 언어와 같으면 그 지역을, 아니면 언어의 기본 지역을 쓴다.
    public init(languageCode: String, deviceRegion: String?) {
        let language = Locale.Language(identifier: languageCode)
        let defaultRegion = Self.defaultRegion(of: language)
        let region = deviceRegion.flatMap { candidate in
            Self.primaryLanguage(ofRegion: candidate).map { Self.sameLanguage($0, language) } == true ? candidate : nil
        } ?? defaultRegion
        let locale = Locale(identifier: "\(languageCode.replacingOccurrences(of: "-\(defaultRegion)", with: ""))_\(region)")
        self.locale = locale
        currencyCode = locale.currency?.identifier ?? "USD"
        let system = locale.measurementSystem
        usesMiles = system == .us || system == .uk
        usesFahrenheit = system == .us
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = currencyCode
        currencyUnit = currencyCode == "KRW" ? "원" : formatter.currencySymbol
        usesDecimalCurrency = currencyCode != "KRW" && formatter.maximumFractionDigits > 0
    }

    /// 지금 앱 언어의 표시 지역.
    public static var current: AppRegion {
        let code = currentLanguageCode
        return cache.withLock { cached in
            if let region = cached[code] { return region }
            let value = AppRegion(languageCode: code, deviceRegion: Locale.current.region?.identifier)
            cached[code] = value
            return value
        }
    }

    /// 통화가 원이 아니면 해외로 본다. 달러 기호로 한국 세금을 계산하는 일을 막는다.
    public var isOverseas: Bool { currencyCode != "KRW" }

    public func moneyText(_ value: Double) -> String {
        if isOverseas {
            return value.formatted(.currency(code: currencyCode).locale(locale))
        }
        return "\(Self.wonGrouped(value))원"
    }

    /// 입력칸 글자를 금액으로 읽는다. 소수 구분자는 기기 형식과 점을 모두 받는다.
    public func amount(from text: String) -> Double {
        let separator = locale.decimalSeparator ?? "."
        let normalized = text.replacingOccurrences(of: separator, with: ".")
            .filter { $0.isNumber || $0 == "." }
        return Double(normalized) ?? 0
    }

    public func distanceText(meters: Double, compact: Bool = false) -> String {
        let space = compact ? "" : " "
        if usesMiles {
            let miles = meters / 1_609.344
            if miles < 0.1 { return "\(Int((meters * 3.28084).rounded()))\(space)ft" }
            return String(format: "%.1f\(space)mi", miles)
        }
        if meters < 1_000 { return "\(Int(meters.rounded()))\(space)m" }
        return String(format: "%.1f\(space)km", meters / 1_000)
    }

    /// 긴 거리의 정수 표기(영상 요약 등).
    public func longDistanceText(meters: Double) -> String {
        usesMiles
            ? "\(Int((meters / 1_609.344).rounded()).formatted()) mi"
            : "\(Int((meters / 1_000).rounded()).formatted()) km"
    }

    public func speedText(metersPerSecond: Double) -> String {
        usesMiles
            ? String(format: "%.1f mph", metersPerSecond * 2.23694)
            : String(format: "%.1f km/h", metersPerSecond * 3.6)
    }

    public var paceUnit: String { usesMiles ? "mi" : "km" }

    public func secondsPerPaceUnit(secondsPerKilometer: Double) -> Double {
        usesMiles ? secondsPerKilometer * 1.609344 : secondsPerKilometer
    }

    /// 화면에 쓸 온도(반올림). 저장값은 섭씨다.
    public func temperature(celsius: Double) -> Int {
        Int((usesFahrenheit ? celsius * 9 / 5 + 32 : celsius).rounded())
    }

    private static var currentLanguageCode: String {
        switch AppLanguagePreference.current.resolvedLanguage {
        case .korean: "ko"
        case .english: UITextPack.activeLanguageCode ?? "en"
        }
    }

    private static func defaultRegion(of language: Locale.Language) -> String {
        Locale(identifier: language.maximalIdentifier).region?.identifier ?? "US"
    }

    private static func primaryLanguage(ofRegion region: String) -> Locale.Language? {
        let language = Locale.Language(identifier: "und-\(region)")
        let maximal = Locale.Language(identifier: language.maximalIdentifier)
        return maximal.languageCode?.identifier == "und" ? nil : maximal
    }

    private static func sameLanguage(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        let left = Locale.Language(identifier: a.maximalIdentifier)
        let right = Locale.Language(identifier: b.maximalIdentifier)
        return left.languageCode == right.languageCode && left.script == right.script
    }

    private static func wonGrouped(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.locale(Locale(identifier: "en_US")).grouping(.automatic))
    }

    private static let cache = OSAllocatedUnfairLock<[String: AppRegion]>(initialState: [:])
}
