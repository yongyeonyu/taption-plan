import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

extension FeatureEngineTests {
    func testWeatherDayFixPicksNearestGPSPerHourFallsBackToHomeAndGroupsNearbyHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20))!
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        func point(_ latitude: Double) -> GeoPoint {
            GeoPoint(latitude: latitude, longitude: 127, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
        }
        func reading(_ hour: Double, _ latitude: Double, accuracy: Double = 10) -> SensorReading {
            var p = point(latitude); p.horizontalAccuracy = accuracy
            return SensorReading(timestamp: dayStart.addingTimeInterval(hour * 3_600), point: p)
        }
        let home = point(37.0)   // 회사 자리는 위도 0.3° ≈ 33km 떨어져 있다
        let readings = [reading(0.2, 37.0), reading(9.4, 37.3), reading(12, 37.9, accuracy: 5_000)]
        let hours = WeatherDayFixEngine.hourLocations(
            dayStart: dayStart, dayEnd: dayEnd, readings: readings, home: nil, calendar: calendar
        )
        XCTAssertEqual(hours.count, 24)
        XCTAssertEqual(hours[0].point.latitude, 37.0)
        XCTAssertEqual(hours[9].point.latitude, 37.3)
        XCTAssertEqual(hours[23].point.latitude, 37.3, "마지막 GPS가 가장 가깝다")
        XCTAssertTrue(hours.allSatisfy { $0.point.latitude != 37.9 }, "부정확한 점은 쓰지 않는다")
        // 가까운 연속한 시는 한 묶음: 0~6시(집)와 7~23시(회사) 쪽으로 나뉜다.
        let groups = WeatherDayFixEngine.groups(hours)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.start, dayStart)
        XCTAssertEqual(groups.last?.end, dayEnd)
        XCTAssertEqual(groups.map(\.hours.count).reduce(0, +), 24)
        // GPS가 없으면 집, 집도 없으면 비어 있다.
        let homeOnly = WeatherDayFixEngine.hourLocations(
            dayStart: dayStart, dayEnd: dayEnd, readings: [], home: home, calendar: calendar)
        XCTAssertEqual(homeOnly.count, 24)
        XCTAssertEqual(WeatherDayFixEngine.groups(homeOnly).count, 1)
        XCTAssertTrue(WeatherDayFixEngine.hourLocations(
            dayStart: dayStart, dayEnd: dayEnd, readings: [], home: nil, calendar: calendar).isEmpty)
    }

    func testWeatherDayFixReplacesOnlyTheFixedHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let dayStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20))!
        func context(_ hour: Int, _ condition: String, forecast: Bool) -> WeatherContext {
            WeatherContext(
                observedAt: dayStart.addingTimeInterval(TimeInterval(hour) * 3_600),
                isForecast: forecast, condition: condition, symbolName: "cloud", temperatureCelsius: 15
            )
        }
        let existing = [context(10, "예보", forecast: true), context(11, "관측", forecast: false)]
        let result = WeatherDayFixEngine.replacing(existing, withFixed: [context(10, "고정", forecast: false)], calendar: calendar)
        XCTAssertEqual(result.map(\.condition), ["고정", "관측"])
        XCTAssertEqual(result.first?.isForecast, false)
        XCTAssertEqual(WeatherDayFixEngine.replacing(existing, withFixed: [], calendar: calendar).count, 2,
                       "받은 시간이 없으면 기존 값을 그대로 둔다")
    }

    func testWidgetPrivacyPayloadRemovesTimelineAndWeatherDetails() {
        let now = makeDate(2026, 8, 1, 18, 0)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.actuals = [
            ActualRecord(
                planID: nil,
                title: "민감한 활동",
                categoryID: "activity",
                startedAt: now.addingTimeInterval(-10 * 60),
                endedAt: now,
                source: .manual
            ),
        ]
        snapshot.weather = [
            WeatherContext(
                observedAt: now,
                condition: "맑음",
                symbolName: "sun.max.fill",
                temperatureCelsius: 27
            ),
        ]

        let payload = TaptionWidgetPayloadFactory.make(
            from: snapshot,
            now: now,
            hidesSensitiveContent: true
        )

        XCTAssertTrue(payload.hidesSensitiveContent)
        XCTAssertTrue(payload.items.isEmpty)
        XCTAssertNil(payload.weatherSymbolName)
        XCTAssertNil(payload.temperatureCelsius)
        XCTAssertEqual(
            payload.sourceFingerprint,
            TaptionWidgetSyncFingerprint.make(items: [])
        )
    }

    func testWeatherSymbolKindClassifiesSharedSymbols() {
        XCTAssertEqual(WeatherSymbolKind(symbolName: "sun.max.fill"), .sun)
        XCTAssertEqual(WeatherSymbolKind(symbolName: "cloud.moon.fill"), .moon)
        XCTAssertEqual(WeatherSymbolKind(symbolName: "cloud.fill"), .cloud)
        XCTAssertEqual(WeatherSymbolKind(symbolName: "cloud.rain.fill"), .rain)
        XCTAssertEqual(WeatherSymbolKind(symbolName: "cloud.snow.fill"), .snow)
        XCTAssertEqual(WeatherSymbolKind(symbolName: "cloud.bolt.rain.fill"), .lightning)
        XCTAssertEqual(WeatherSymbolKind(symbolName: "questionmark"), .fallback)
    }

    func testWeatherSymbolPalettesUseNoWhiteAndExpectedFamilies() {
        for kind in WeatherSymbolKind.allCases {
            let palette = kind.palette
            for color in [palette.primary, palette.secondary] {
                XCTAssertFalse(
                    color.red == 1 && color.green == 1 && color.blue == 1,
                    "\(kind.rawValue) must not use white"
                )
            }
        }

        XCTAssertGreaterThan(
            WeatherSymbolKind.sun.palette.primary.red,
            WeatherSymbolKind.sun.palette.primary.blue
        )
        XCTAssertGreaterThan(
            WeatherSymbolKind.moon.palette.secondary.green,
            WeatherSymbolKind.moon.palette.secondary.blue
        )
        XCTAssertGreaterThan(
            WeatherSymbolKind.rain.palette.primary.blue,
            WeatherSymbolKind.rain.palette.primary.red
        )
    }

    func testWeatherFreshnessMetadataSurvivesRoundTrip() throws {
        let fetchedAt = makeDate(2026, 8, 1, 18)
        let context = WeatherContext(
            observedAt: fetchedAt,
            fetchedAt: fetchedAt,
            isStale: true,
            isForecast: true,
            providerName: "WeatherKit",
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 28
        )
        let decoded = try JSONDecoder().decode(
            WeatherContext.self,
            from: JSONEncoder().encode(context)
        )
        XCTAssertEqual(decoded.fetchedAt, fetchedAt)
        XCTAssertEqual(decoded.isStale, true)
        XCTAssertEqual(decoded.isForecast, true)
        XCTAssertEqual(decoded.providerName, "WeatherKit")
    }

    func testWeatherProjectionReplacesCurrentHourOnlyAtSameLocation() {
        let start = makeDate(2026, 8, 1, 10)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127.0,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5
        )
        let otherPoint = GeoPoint(
            latitude: 37.6,
            longitude: 127.1,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5
        )
        let oldCurrent = WeatherContext(
            observedAt: start.addingTimeInterval(5 * 60),
            fetchedAt: start,
            condition: "예보",
            symbolName: "cloud.fill",
            temperatureCelsius: 18,
            point: point
        )
        let oldForecast = WeatherContext(
            observedAt: start.addingTimeInterval(60 * 60),
            fetchedAt: start,
            condition: "이전 예보",
            symbolName: "cloud.fill",
            temperatureCelsius: 19,
            point: point
        )
        let otherLocation = WeatherContext(
            observedAt: start.addingTimeInterval(5 * 60),
            fetchedAt: start,
            condition: "다른 위치",
            symbolName: "cloud.fill",
            temperatureCelsius: 18,
            point: otherPoint
        )
        let current = WeatherContext(
            observedAt: start.addingTimeInterval(20 * 60),
            fetchedAt: start.addingTimeInterval(30 * 60),
            condition: "현재",
            symbolName: "sun.max.fill",
            temperatureCelsius: 21,
            point: point
        )
        let forecastForCurrentHour = WeatherContext(
            observedAt: start.addingTimeInterval(30 * 60),
            fetchedAt: start.addingTimeInterval(30 * 60),
            condition: "잘못된 현재 예보",
            symbolName: "cloud.fill",
            temperatureCelsius: 99,
            point: point
        )
        let forecast = WeatherContext(
            observedAt: start.addingTimeInterval(60 * 60),
            fetchedAt: start.addingTimeInterval(30 * 60),
            condition: "새 예보",
            symbolName: "cloud.sun.fill",
            temperatureCelsius: 22,
            point: point
        )

        let result = WeatherTimelineEngine.replacing(
            [oldCurrent, oldForecast, otherLocation],
            current: current,
            forecast: [forecastForCurrentHour, forecast],
            forecastRange: TimeSpan(
                start: start,
                end: start.addingTimeInterval(2 * 60 * 60)
            ),
            calendar: utcCalendar
        )

        XCTAssertTrue(result.contains { $0.id == current.id })
        XCTAssertTrue(result.contains { $0.id == otherLocation.id })
        XCTAssertTrue(result.contains { $0.id == forecast.id })
        XCTAssertFalse(result.contains { $0.id == oldCurrent.id })
        XCTAssertFalse(result.contains { $0.id == oldForecast.id })
        XCTAssertFalse(result.contains { $0.id == forecastForCurrentHour.id })
        XCTAssertFalse(result.contains { $0.temperatureCelsius == 99 })
    }

    func testWeatherTimelineDoesNotMergeDifferentLocations() {
        let start = makeDate(2026, 8, 1, 10)
        let first = WeatherContext(
            observedAt: start,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 26,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 127.0,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        let second = WeatherContext(
            observedAt: start.addingTimeInterval(60 * 60),
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 26,
            point: GeoPoint(
                latitude: 37.6,
                longitude: 127.1,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )

        let merged = WeatherTimelineEngine.coalesced([first, second])

        XCTAssertEqual(merged.count, 2)
    }

    func testWeatherTimelineMergesEqualValuesAndSplitsOnChange() {
        let start = makeDate(2026, 8, 1, 10)
        let first = WeatherContext(
            observedAt: start,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 26.1
        )
        let repeated = WeatherContext(
            observedAt: start.addingTimeInterval(60 * 60),
            condition: "맑음",
            symbolName: "cloud.sun.fill",
            temperatureCelsius: 26.4
        )
        let changed = WeatherContext(
            observedAt: start.addingTimeInterval(2 * 60 * 60),
            condition: "흐림",
            symbolName: "cloud.fill",
            temperatureCelsius: 26.4
        )

        let merged = WeatherTimelineEngine.coalesced([
            first,
            repeated,
            changed,
        ])

        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].observedAt, start)
        XCTAssertEqual(
            merged[0].validUntil,
            repeated.observedAt
        )
        XCTAssertEqual(
            merged[1].validUntil,
            changed.observedAt
        )
        XCTAssertEqual(
            merged[2].validUntil,
            changed.observedAt.addingTimeInterval(15 * 60)
        )
    }

    func testWeatherTimelineSplitsWhenWeatherSymbolChanges() {
        let start = makeDate(2026, 8, 1, 10)
        let first = WeatherContext(
            observedAt: start,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 26
        )
        let symbolChanged = WeatherContext(
            observedAt: start.addingTimeInterval(60 * 60),
            condition: "맑음",
            symbolName: "cloud.sun.fill",
            temperatureCelsius: 26
        )

        let merged = WeatherTimelineEngine.coalesced([first, symbolChanged])

        XCTAssertEqual(merged.map(\.observedAt), [start, symbolChanged.observedAt])
    }

    func testWeatherTimelineKeepsSameDisplayedWeatherContinuous() {
        let start = makeDate(2026, 8, 1, 10)
        let first = WeatherContext(
            observedAt: start,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 28,
            airQuality: AirQualityContext(
                pm10MicrogramsPerCubicMeter: 41,
                pm25MicrogramsPerCubicMeter: 21,
                observedAt: start,
                providerName: "에어코리아",
                isFallback: false
            )
        )
        let repeated = WeatherContext(
            observedAt: start.addingTimeInterval(60 * 60),
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 28.4,
            airQuality: AirQualityContext(
                pm10MicrogramsPerCubicMeter: 63,
                pm25MicrogramsPerCubicMeter: 30,
                observedAt: start.addingTimeInterval(60 * 60),
                providerName: "에어코리아",
                isFallback: true
            )
        )

        let merged = WeatherTimelineEngine.coalesced([first, repeated])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].validUntil, repeated.observedAt.addingTimeInterval(15 * 60))
        XCTAssertEqual(merged[0].airQuality?.pm10MicrogramsPerCubicMeter, 63)
    }

    func testDomesticAirQualityGradeBoundaries() {
        XCTAssertEqual(AirQualityGrade.pm10(30), .good)
        XCTAssertEqual(AirQualityGrade.pm10(31), .moderate)
        XCTAssertEqual(AirQualityGrade.pm10(80), .moderate)
        XCTAssertEqual(AirQualityGrade.pm10(81), .bad)
        XCTAssertEqual(AirQualityGrade.pm10(151), .veryBad)
        XCTAssertEqual(AirQualityGrade.pm25(15), .good)
        XCTAssertEqual(AirQualityGrade.pm25(16), .moderate)
        XCTAssertEqual(AirQualityGrade.pm25(36), .bad)
        XCTAssertEqual(AirQualityGrade.pm25(76), .veryBad)

        let context = AirQualityContext(
            pm10MicrogramsPerCubicMeter: 45,
            pm25MicrogramsPerCubicMeter: 80,
            observedAt: .now,
            providerName: "test",
            isFallback: false
        )
        XCTAssertEqual(context.overallGrade, .veryBad)
    }

    func testAirQualityProxyHostIsValidatedAndNeverContainsASecret() {
        XCTAssertEqual(AirQualityContextService.proxyBaseURL(host: "air.example.com")?.absoluteString, "https://air.example.com")
        XCTAssertNil(AirQualityContextService.proxyBaseURL(host: nil))
        XCTAssertNil(AirQualityContextService.proxyBaseURL(host: ""))
        XCTAssertNil(AirQualityContextService.proxyBaseURL(host: "$(AIR_QUALITY_PROXY_HOST)"))
        XCTAssertNil(AirQualityContextService.proxyBaseURL(host: "https://air.example.com"))
        XCTAssertNil(AirQualityContextService.proxyBaseURL(host: "air.example.com/path"))
        XCTAssertNil(AirQualityContextService.proxyBaseURL(host: "air example.com"))
    }

    func testAirQualityHasNoOverseasFallbackWithoutKey() async throws {
        AirQualityURLProtocolStub.requestCount = 0
        AirQualityURLProtocolStub.handler = { _ in
            XCTFail("air quality must not call any provider without a key")
            return (500, Data())
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AirQualityURLProtocolStub.self]
        let service = AirQualityContextService(
            session: URLSession(configuration: configuration),
            proxyBaseURL: nil
        )
        do {
            _ = try await service.context(latitude: 37.5, longitude: 127)
            XCTFail("expected no provider")
        } catch {}
        do {
            _ = try await service.context(latitude: 48.85, longitude: 2.35)
            XCTFail("expected no provider")
        } catch {}
        XCTAssertEqual(AirQualityURLProtocolStub.requestCount, 0)
    }

    func testWeatherAttributionUsesProviderAndCachesIt() async {
        let expected = WeatherAttributionInfo(
            serviceName: "Apple Weather",
            combinedMarkLightURL: URL(string: "https://example.com/light.png"),
            combinedMarkDarkURL: URL(string: "https://example.com/dark.png"),
            legalPageURL: URL(string: "https://example.com/legal")!
        )
        let provider = StubWeatherAttributionProvider(result: .success(expected))
        let store = WeatherAttributionStore(provider: provider)

        let first = await store.current()
        let second = await store.current()

        XCTAssertEqual(first, expected)
        XCTAssertEqual(second, expected)
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(first.markURL(isDark: false)?.lastPathComponent, "light.png")
        XCTAssertEqual(first.markURL(isDark: true)?.lastPathComponent, "dark.png")
    }

    func testWeatherAttributionFallsBackToLegalLinkWithoutCaching() async {
        let provider = StubWeatherAttributionProvider(
            result: .failure(WeatherContextServiceError.temporarilyUnavailable)
        )
        let store = WeatherAttributionStore(provider: provider)

        let first = await store.current()
        _ = await store.current()

        XCTAssertEqual(first, .fallback)
        XCTAssertEqual(
            first.legalPageURL.absoluteString,
            "https://weatherkit.apple.com/legal-attribution.html"
        )
        XCTAssertNil(first.markURL(isDark: false))
        XCTAssertEqual(provider.callCount, 2)
    }

    func testWeatherRingShowsChangedMeasurementsWithAirQuality() throws {
        let dayStart = makeDate(2026, 8, 4)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        func weather(
            _ minute: Double,
            _ condition: String,
            _ temperature: Double,
            _ pm10: Double
        ) -> WeatherContext {
            WeatherContext(
                observedAt: dayStart.addingTimeInterval(minute * 60),
                condition: condition,
                symbolName: condition == "비" ? "cloud.rain.fill" : "sun.max.fill",
                temperatureCelsius: temperature,
                airQuality: AirQualityContext(
                    pm10MicrogramsPerCubicMeter: pm10,
                    pm25MicrogramsPerCubicMeter: 8,
                    observedAt: dayStart.addingTimeInterval(minute * 60),
                    providerName: "테스트",
                    isFallback: false
                )
            )
        }
        let ring = try XCTUnwrap(
            RecordClockDetailEngine.weatherRing(
                contexts: [
                    weather(8 * 60, "맑음", 25, 12),
                    weather(8 * 60 + 15, "맑음", 25, 12),
                    weather(9 * 60, "비", 21, 92),
                ],
                in: day,
                asOf: day.end
            )
        )
        XCTAssertEqual(ring.kind, .weather)
        XCTAssertEqual(ring.arcs.count, 2)
        XCTAssertEqual(WeatherClockToken.displayName(ring.arcs[0].token), "☀️ 25° · 🟢")
        XCTAssertEqual(WeatherClockToken.displayName(ring.arcs[1].token), "🌧️ 21° · 🟠")
        assertRingHasNoSlivers(ring)
    }

}
