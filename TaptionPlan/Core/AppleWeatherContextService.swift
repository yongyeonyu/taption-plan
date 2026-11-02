import CoreLocation
import Foundation
import WeatherKit
import TaptionPlanCore

// MARK: - Weather

actor AppleWeatherContextService {
    private static let maximumForecastDays = 10
    /// WeatherKit 인증 실패 뒤 다시 시도하기까지 기다리는 시간.
    static let authenticationRetryInterval: TimeInterval = 15 * 60
    private let service = WeatherKit.WeatherService.shared
    private var cachedContext: CachedWeatherContext?
    private var appleAuthenticationRetryAfter: Date?

    func context(
        latitude: Double,
        longitude: Double,
        at date: Date = .now
    ) async throws -> WeatherContext {
        let point = CLLocation(latitude: latitude, longitude: longitude)
        if let cachedContext,
           cachedContext.isReusable(for: point, at: date) {
            // Keep the cached observation usable while the app is receiving
            // frequent workout locations.  Refreshing the observation time
            // prevents the UI from dropping an otherwise valid context just
            // because the provider was not queried again yet.
            var context = cachedContext.context
            context.observedAt = date
            context.isStale = false
            self.cachedContext = CachedWeatherContext(
                location: cachedContext.location,
                context: context
            )
            return context
        }

        if appleAuthenticationRetryAfter.map({ date >= $0 }) ?? true {
            do {
                let context = try await appleContext(
                    at: point,
                    observedAt: date
                )
                cachedContext = CachedWeatherContext(
                    location: point,
                    context: context
                )
                appleAuthenticationRetryAfter = nil
                return context
            } catch {
                if Self.isWeatherKitAuthenticationFailure(error) {
                    appleAuthenticationRetryAfter = date.addingTimeInterval(
                        Self.authenticationRetryInterval
                    )
                }
            }
        }

        // A short network interruption should not erase the last usable
        // weather during an active workout. Keep the cached observation
        // as a graceful stale fallback and let the next refresh retry.
        if let cachedContext {
            var context = cachedContext.context
            context.observedAt = date
            context.isStale = true
            self.cachedContext = CachedWeatherContext(
                location: cachedContext.location,
                context: context
            )
            return context
        }
        if appleAuthenticationRetryAfter != nil {
            throw WeatherContextServiceError.authenticationFailed
        }
        throw WeatherContextServiceError.temporarilyUnavailable
    }

    func hourlyContexts(
        latitude: Double,
        longitude: Double,
        from start: Date,
        through end: Date
    ) async throws -> [WeatherContext] {
        let point = CLLocation(latitude: latitude, longitude: longitude)
        let now = Date.now
        let forecastStart = max(start, now)
        let maximumEnd = Calendar.autoupdatingCurrent.date(
            byAdding: .day,
            value: Self.maximumForecastDays,
            to: forecastStart
        ) ?? forecastStart.addingTimeInterval(
            TimeInterval(Self.maximumForecastDays) * 24 * 60 * 60
        )
        let forecastEnd = min(end, maximumEnd)
        guard forecastStart < forecastEnd else { return [] }

        do {
            let forecast = try await service.weather(
                for: point,
                including: .hourly(
                    startDate: forecastStart,
                    endDate: forecastEnd
                )
            )
            let values = forecast.map {
                Self.weatherContext(
                    $0,
                    isForecast: $0.date >= forecastStart
                )
            }
            if !values.isEmpty { return values }
        } catch {
            // Fall through to the unbounded hourly request below.
        }

        do {
            let hourly = try await service.weather(
                for: point,
                including: .hourly
            )
            let values = hourly.forecast.filter {
                $0.date >= forecastStart && $0.date < forecastEnd
            }
            guard !values.isEmpty else {
                throw WeatherContextServiceError.temporarilyUnavailable
            }
            return values.map {
                Self.weatherContext($0, isForecast: $0.date >= Date.now)
            }
        } catch {
            if Self.isWeatherKitAuthenticationFailure(error) {
                throw WeatherContextServiceError.authenticationFailed
            }
            throw WeatherContextServiceError.temporarilyUnavailable
        }
    }

    /// 지난 시간(현재 이전)의 시간별 날씨. 과거 구간만 묻는다. 일부 시간이 비어 오면 온 시간만 돌려주고, 전부 비면 빈 배열이다.
    /// WeatherKit의 과거 데이터는 일부 시간이 빠질 수 있어 호출한 쪽이 온 시간만 고정한다.
    func historicalHourlyContexts(
        latitude: Double,
        longitude: Double,
        from start: Date,
        through end: Date
    ) async throws -> [WeatherContext] {
        let clippedEnd = min(end, Date.now)
        guard start < clippedEnd else { return [] }
        do {
            let hours = try await service.weather(
                for: CLLocation(latitude: latitude, longitude: longitude),
                including: .hourly(startDate: start, endDate: clippedEnd)
            )
            return hours
                .filter { $0.date >= start && $0.date < clippedEnd }
                .map { Self.weatherContext($0, isForecast: false) }
        } catch {
            if Self.isWeatherKitAuthenticationFailure(error) {
                throw WeatherContextServiceError.authenticationFailed
            }
            throw WeatherContextServiceError.temporarilyUnavailable
        }
    }

    private static func weatherContext(
        _ value: WeatherKit.HourWeather,
        isForecast: Bool? = nil
    ) -> WeatherContext {
        WeatherContext(
            observedAt: value.date,
            fetchedAt: .now,
            isStale: false,
            isForecast: isForecast,
            providerName: "WeatherKit",
            condition: String(describing: value.condition),
            symbolName: value.symbolName,
            temperatureCelsius: value.temperature.converted(to: .celsius).value,
            precipitationChance: value.precipitationChance,
            isContextOnly: true,
            windSpeedMetersPerSecond: value.wind.speed.converted(to: .metersPerSecond).value
        )
    }

    private func appleContext(
        at location: CLLocation,
        observedAt date: Date
    ) async throws -> WeatherContext {
        let (current, hourly) = try await service.weather(
            for: location,
            including: .current,
            .hourly
        )
        let closestHour = hourly.forecast.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
        return WeatherContext(
            observedAt: date,
            fetchedAt: date,
            isStale: false,
            providerName: "WeatherKit",
            condition: String(describing: current.condition),
            symbolName: current.symbolName,
            temperatureCelsius: current.temperature.converted(to: .celsius).value,
            precipitationChance: closestHour?.precipitationChance,
            windSpeedMetersPerSecond: current.wind.speed.converted(to: .metersPerSecond).value
        )
    }

    static func isWeatherKitAuthenticationFailure(
        _ error: Error
    ) -> Bool {
        let nsError = error as NSError
        if nsError.domain.contains(
            "WDSJWTAuthenticatorServiceListener.Errors"
        ), nsError.code == 2 {
            return true
        }
        if let underlying = nsError.userInfo[
            NSUnderlyingErrorKey
        ] as? Error {
            return isWeatherKitAuthenticationFailure(underlying)
        }
        return false
    }
}

private struct CachedWeatherContext {
    let location: CLLocation
    let context: WeatherContext

    func isReusable(
        for newLocation: CLLocation,
        at date: Date
    ) -> Bool {
        context.isStale != true
            && abs(
                date.timeIntervalSince(
                    context.fetchedAt ?? context.observedAt
                )
            ) < 10 * 60
            && newLocation.distance(from: location) < 1_000
    }
}

enum WeatherContextServiceError: LocalizedError, Equatable {
    case temporarilyUnavailable
    case authenticationFailed

    var errorDescription: String? {
        message()
    }

    func message(preference: AppLanguagePreference = .current) -> String {
        if self == .authenticationFailed {
            return AppLanguagePreference.text(
                korean: "Apple 날씨(WeatherKit) 인증에 실패했습니다.",
                english: "Apple Weather (WeatherKit) authentication failed.",
                preference: preference
            )
        }
        return AppLanguagePreference.text(
            korean: "날씨 서비스에 잠시 연결할 수 없습니다. 잠시 후 다시 시도해 주세요.",
            english: "The weather service is temporarily unavailable. Please try again shortly.",
            preference: preference
        )
    }
}

/// Apple WeatherKit이 날씨를 보여 주는 화면마다 요구하는 출처 표기.
struct WeatherAttributionInfo: Equatable, Sendable {
    var serviceName: String
    var combinedMarkLightURL: URL?
    var combinedMarkDarkURL: URL?
    var legalPageURL: URL

    /// 출처 정보를 아직 받지 못했을 때도 법적 고지 링크는 항상 보여 준다.
    static let fallback = WeatherAttributionInfo(
        serviceName: "Apple 날씨",
        combinedMarkLightURL: nil,
        combinedMarkDarkURL: nil,
        legalPageURL: URL(string: "https://weatherkit.apple.com/legal-attribution.html") ?? URL(fileURLWithPath: "/")
    )

    func markURL(isDark: Bool) -> URL? {
        isDark ? combinedMarkDarkURL : combinedMarkLightURL
    }
}

protocol WeatherAttributionProviding: Sendable {
    func attribution() async throws -> WeatherAttributionInfo
}

struct AppleWeatherAttributionProvider: WeatherAttributionProviding {
    func attribution() async throws -> WeatherAttributionInfo {
        let value = try await WeatherKit.WeatherService.shared.attribution
        return WeatherAttributionInfo(
            serviceName: value.serviceName,
            combinedMarkLightURL: value.combinedMarkLightURL,
            combinedMarkDarkURL: value.combinedMarkDarkURL,
            legalPageURL: value.legalPageURL
        )
    }
}

actor WeatherAttributionStore {
    static let shared = WeatherAttributionStore()

    private let provider: any WeatherAttributionProviding
    private var cached: WeatherAttributionInfo?

    init(provider: any WeatherAttributionProviding = AppleWeatherAttributionProvider()) {
        self.provider = provider
    }

    /// 조회에 실패하면 기본 문구와 법적 고지 링크를 돌려주고 캐시하지 않는다.
    func current() async -> WeatherAttributionInfo {
        if let cached { return cached }
        guard let value = try? await provider.attribution() else {
            return .fallback
        }
        cached = value
        return value
    }
}
