import Foundation
import TaptionPlanCore

public enum AirQualityGrade: Int, Codable, CaseIterable, Comparable, Hashable, Sendable {
    case good = 0
    case moderate
    case bad
    case veryBad

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .good: "좋음"
        case .moderate: "보통"
        case .bad: "나쁨"
        case .veryBad: "매우 나쁨"
        }
    }

    public static func pm10(_ value: Double) -> Self {
        switch value {
        case ...30: .good
        case ...80: .moderate
        case ...150: .bad
        default: .veryBad
        }
    }

    public static func pm25(_ value: Double) -> Self {
        switch value {
        case ...15: .good
        case ...35: .moderate
        case ...75: .bad
        default: .veryBad
        }
    }
}

public struct AirQualityContext: Codable, Hashable, Sendable {
    public var pm10MicrogramsPerCubicMeter: Double
    public var pm25MicrogramsPerCubicMeter: Double
    public var pm10Grade: AirQualityGrade
    public var pm25Grade: AirQualityGrade
    public var overallGrade: AirQualityGrade
    public var observedAt: Date
    public var stationName: String?
    public var providerName: String
    public var isFallback: Bool

    public init(
        pm10MicrogramsPerCubicMeter: Double,
        pm25MicrogramsPerCubicMeter: Double,
        observedAt: Date,
        stationName: String? = nil,
        providerName: String,
        isFallback: Bool
    ) {
        self.pm10MicrogramsPerCubicMeter = pm10MicrogramsPerCubicMeter
        self.pm25MicrogramsPerCubicMeter = pm25MicrogramsPerCubicMeter
        pm10Grade = .pm10(pm10MicrogramsPerCubicMeter)
        pm25Grade = .pm25(pm25MicrogramsPerCubicMeter)
        overallGrade = max(pm10Grade, pm25Grade)
        self.observedAt = observedAt
        self.stationName = stationName
        self.providerName = providerName
        self.isFallback = isFallback
    }
}

public struct WeatherSymbolRGB: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum WeatherSymbolPaletteComponent: Equatable, Sendable {
    case primary
    case secondary
}

public struct WeatherSymbolPalette: Equatable, Sendable {
    public let primary: WeatherSymbolRGB
    public let secondary: WeatherSymbolRGB
}

public enum WeatherSymbolKind: String, CaseIterable, Equatable, Sendable {
    case sun
    case moon
    case cloud
    case rain
    case snow
    case lightning
    case fallback

    public init(symbolName: String) {
        let symbol = symbolName.lowercased()
        if symbol.contains("bolt") || symbol.contains("thunder") {
            self = .lightning
        } else if symbol.contains("snow") || symbol.contains("sleet") {
            self = .snow
        } else if symbol.contains("rain") || symbol.contains("drizzle") {
            self = .rain
        } else if symbol.contains("sun") {
            self = .sun
        } else if symbol.contains("moon") {
            self = .moon
        } else if symbol.contains("cloud") || symbol.contains("fog") {
            self = .cloud
        } else {
            self = .fallback
        }
    }

    public var palette: WeatherSymbolPalette {
        switch self {
        case .sun:
            return WeatherSymbolPalette(
                primary: WeatherSymbolRGB(red: 0.95, green: 0.42, blue: 0.06),
                secondary: WeatherSymbolRGB(red: 0.98, green: 0.68, blue: 0.12)
            )
        case .moon:
            return WeatherSymbolPalette(
                primary: WeatherSymbolRGB(red: 0.88, green: 0.58, blue: 0.06),
                secondary: WeatherSymbolRGB(red: 0.98, green: 0.80, blue: 0.18)
            )
        case .cloud:
            return WeatherSymbolPalette(
                primary: WeatherSymbolRGB(red: 0.31, green: 0.39, blue: 0.50),
                secondary: WeatherSymbolRGB(red: 0.50, green: 0.59, blue: 0.68)
            )
        case .rain:
            return WeatherSymbolPalette(
                primary: WeatherSymbolRGB(red: 0.08, green: 0.39, blue: 0.86),
                secondary: WeatherSymbolRGB(red: 0.24, green: 0.62, blue: 0.92)
            )
        case .snow:
            return WeatherSymbolPalette(
                primary: WeatherSymbolRGB(red: 0.10, green: 0.58, blue: 0.82),
                secondary: WeatherSymbolRGB(red: 0.35, green: 0.76, blue: 0.94)
            )
        case .lightning:
            return WeatherSymbolPalette(
                primary: WeatherSymbolRGB(red: 0.88, green: 0.52, blue: 0.04),
                secondary: WeatherSymbolRGB(red: 0.99, green: 0.73, blue: 0.10)
            )
        case .fallback:
            return WeatherSymbolPalette(
                primary: WeatherSymbolRGB(red: 0.35, green: 0.43, blue: 0.52),
                secondary: WeatherSymbolRGB(red: 0.54, green: 0.60, blue: 0.67)
            )
        }
    }
}

private let retiredWeatherProviderPrefix = "Open-Meteo"

extension WeatherContext {
    public var isFromRetiredProvider: Bool {
        providerName?.hasPrefix(retiredWeatherProviderPrefix) == true
    }
}

extension AirQualityContext {
    public var isFromRetiredProvider: Bool {
        providerName.hasPrefix(retiredWeatherProviderPrefix)
    }
}

public struct WeatherContext: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var observedAt: Date
    /// End of the displayed weather run. Raw samples remain in the device
    /// archive while equal consecutive values share one timeline segment.
    public var validUntil: Date?
    /// Time at which the provider actually supplied this observation.
    public var fetchedAt: Date?
    /// True when this is the last known value after a failed refresh.
    public var isStale: Bool?
    /// True when the provider supplied a forecast rather than an observed
    /// current value. Legacy snapshots omit this field and remain readable.
    public var isForecast: Bool?
    /// Provider provenance for raw weather replay. Legacy snapshots omit this
    /// field and remain readable.
    public var providerName: String?
    public var condition: String
    public var symbolName: String
    public var temperatureCelsius: Double
    public var precipitationChance: Double?
    public var placeID: UUID?
    public var placeName: String?
    public var point: GeoPoint?
    public var isContextOnly: Bool
    public var airQuality: AirQualityContext?
    /// 옛 기록에는 없다.
    public var windSpeedMetersPerSecond: Double?

    public init(
        id: UUID = UUID(),
        observedAt: Date,
        validUntil: Date? = nil,
        fetchedAt: Date? = nil,
        isStale: Bool? = false,
        isForecast: Bool? = false,
        providerName: String? = nil,
        condition: String,
        symbolName: String,
        temperatureCelsius: Double,
        precipitationChance: Double? = nil,
        placeID: UUID? = nil,
        placeName: String? = nil,
        point: GeoPoint? = nil,
        isContextOnly: Bool = true,
        airQuality: AirQualityContext? = nil,
        windSpeedMetersPerSecond: Double? = nil
    ) {
        self.windSpeedMetersPerSecond = windSpeedMetersPerSecond
        self.id = id
        self.observedAt = observedAt
        self.validUntil = validUntil
        self.fetchedAt = fetchedAt
        self.isStale = isStale
        self.isForecast = isForecast
        self.providerName = providerName
        self.condition = condition
        self.symbolName = symbolName
        self.temperatureCelsius = temperatureCelsius
        self.precipitationChance = precipitationChance
        self.placeID = placeID
        self.placeName = placeName
        self.point = point
        self.isContextOnly = isContextOnly
        self.airQuality = airQuality
    }

    public var freshnessLabel: String {
        guard let fetchedAt else {
            return isStale == true ? "이전" : "확인됨"
        }
        let minutes = max(0, Int(Date.now.timeIntervalSince(fetchedAt) / 60))
        if minutes < 1 { return "방금" }
        if minutes < 60 { return "\(minutes)분 전" }
        let hours = minutes / 60
        return "\(hours)시간 전"
    }
}
