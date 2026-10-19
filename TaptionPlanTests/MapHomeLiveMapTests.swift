import CoreLocation
import XCTest
@testable import TaptionPlan

/// MAP1019C01: 날씨 상태·집 날씨 아이콘·경로 속도 그라데이션·실시간 자동 줌·GPS 로그.
final class MapHomeLiveMapTests: XCTestCase {
    // MARK: - Weather status

    func testWeatherStatusRecordsFailureKindAndClearsOnSuccess() {
        var status = WeatherServiceStatus()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(status.latestFailure)

        XCTAssertTrue(status.recordFailure(.authentication, at: t0))
        XCTAssertEqual(status.latestFailure, .authentication)
        // 같은 종류의 실패가 이어져도 값은 바뀌지 않는다.
        XCTAssertFalse(status.recordFailure(.authentication, at: t0.addingTimeInterval(30)))
        XCTAssertEqual(status.failureAt, t0)
        // 종류가 바뀌면 갱신한다.
        XCTAssertTrue(status.recordFailure(.general, at: t0.addingTimeInterval(60)))
        XCTAssertEqual(status.latestFailure, .general)

        XCTAssertTrue(status.recordSuccess(at: t0.addingTimeInterval(120)))
        XCTAssertNil(status.latestFailure)
        XCTAssertEqual(status.lastSuccessAt, t0.addingTimeInterval(120))
    }

    func testWeatherStatusSuccessIsNotRepublishedWithinInterval() {
        var status = WeatherServiceStatus()
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertTrue(status.recordSuccess(at: t0))
        XCTAssertFalse(status.recordSuccess(at: t0.addingTimeInterval(10)))
        XCTAssertTrue(status.recordSuccess(at: t0.addingTimeInterval(
            WeatherServiceStatus.successRefreshInterval + 1
        )))
        // 실패가 있었다면 곧바로 성공으로 되돌린다.
        _ = status.recordFailure(.general, at: t0.addingTimeInterval(100))
        XCTAssertTrue(status.recordSuccess(at: t0.addingTimeInterval(101)))
        XCTAssertNil(status.failure)
    }

    func testWeatherFailureKindClassifiesAuthenticationError() {
        XCTAssertEqual(
            WeatherFailureKind.kind(for: WeatherContextServiceError.authenticationFailed),
            .authentication
        )
        XCTAssertEqual(
            WeatherFailureKind.kind(for: WeatherContextServiceError.temporarilyUnavailable),
            .general
        )
        XCTAssertEqual(WeatherFailureKind.kind(for: URLError(.notConnectedToInternet)), .general)
    }

    func testWeatherKitJWTFailureIsDetectedEvenWhenWrapped() {
        let inner = NSError(
            domain: "WeatherDaemon.WDSJWTAuthenticatorServiceListener.Errors",
            code: 2
        )
        let wrapped = NSError(
            domain: "WeatherKit.WeatherError",
            code: 2,
            userInfo: [NSUnderlyingErrorKey: inner]
        )
        XCTAssertTrue(AppleWeatherContextService.isWeatherKitAuthenticationFailure(inner))
        XCTAssertTrue(AppleWeatherContextService.isWeatherKitAuthenticationFailure(wrapped))
        XCTAssertFalse(AppleWeatherContextService.isWeatherKitAuthenticationFailure(
            NSError(domain: NSURLErrorDomain, code: -1009)
        ))
    }

    func testWeatherAuthenticationRetryIsFifteenMinutes() {
        XCTAssertEqual(AppleWeatherContextService.authenticationRetryInterval, 15 * 60)
        XCTAssertEqual(
            WeatherContextServiceError.authenticationFailed.message(preference: .korean),
            "Apple 날씨(WeatherKit) 인증에 실패했습니다."
        )
        XCTAssertEqual(
            WeatherContextServiceError.authenticationFailed.message(preference: .english),
            "Apple Weather (WeatherKit) authentication failed."
        )
    }

    func testWeatherNoticeAppearsOnlyWhenNoWeatherAndLatestAttemptFailed() {
        var status = WeatherServiceStatus()
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        XCTAssertNil(MapHomeWeatherNoticePolicy.notice(status: status, hasDisplayableWeather: false))

        _ = status.recordFailure(.authentication, at: t0)
        XCTAssertEqual(
            MapHomeWeatherNoticePolicy.notice(status: status, hasDisplayableWeather: false),
            .authenticationFailed
        )
        XCTAssertNil(MapHomeWeatherNoticePolicy.notice(status: status, hasDisplayableWeather: true))

        var general = WeatherServiceStatus()
        _ = general.recordFailure(.general, at: t0)
        XCTAssertEqual(
            MapHomeWeatherNoticePolicy.notice(status: general, hasDisplayableWeather: false),
            .unreachable
        )

        _ = status.recordSuccess(at: t0.addingTimeInterval(5))
        XCTAssertNil(MapHomeWeatherNoticePolicy.notice(status: status, hasDisplayableWeather: false))
    }

    // MARK: - Weather rail with data

    func testWeatherRailShowsCompleteContextsForTheSelectedDay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let current = weather(at: day.addingTimeInterval(9 * 3_600), symbol: "sun.max", celsius: 20)
        var forecast = weather(at: day.addingTimeInterval(12 * 3_600), symbol: "cloud", celsius: 15)
        forecast.isForecast = true
        var stale = weather(at: day.addingTimeInterval(15 * 3_600), symbol: "cloud.rain", celsius: 10)
        stale.isStale = true

        let complete = [current, forecast, stale].filter(MapHomeWeatherDisplayPolicy.isComplete)
        XCTAssertEqual(complete.count, 2, "오래된 값은 레일에 올리지 않는다")
        let spans = MapHomeWeatherTimelineMath.persistentSpans(
            for: day,
            contexts: complete,
            calendar: calendar,
            minimumTemperatureChangeCelsius: MapHomeWeatherTimelineMath.fullDayTemperatureChangeCelsius
        )
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].span.start, day.addingTimeInterval(9 * 3_600))
        XCTAssertEqual(spans[0].span.end, day.addingTimeInterval(12 * 3_600))
        XCTAssertEqual(spans[1].span.end, day.addingTimeInterval(24 * 3_600))
    }

    // MARK: - Home weather badge

    func testHomeWeatherBadgePicksClosestCompleteContextAndRoundsTemperature() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let far = weather(at: now.addingTimeInterval(-3_600), symbol: "cloud", celsius: 10)
        let near = weather(at: now.addingTimeInterval(-300), symbol: "sun.max", celsius: 21.6)
        let badge = try XCTUnwrap(MapHomeHomeWeatherBadgePolicy.badge(from: [far, near], now: now))
        XCTAssertEqual(badge.symbolName, "sun.max")
        XCTAssertEqual(badge.temperatureText, "22°")
        let cold = weather(at: now, symbol: "snowflake", celsius: -2.6)
        XCTAssertEqual(
            try XCTUnwrap(MapHomeHomeWeatherBadgePolicy.badge(from: [cold], now: now)).temperatureText,
            "-3°"
        )
    }

    func testHomeWeatherBadgeIsHiddenWithoutFreshCompleteData() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(MapHomeHomeWeatherBadgePolicy.badge(from: [], now: now))
        var stale = weather(at: now, symbol: "sun.max", celsius: 20)
        stale.isStale = true
        XCTAssertNil(MapHomeHomeWeatherBadgePolicy.badge(from: [stale], now: now))
        let old = weather(
            at: now.addingTimeInterval(-MapHomeHomeWeatherBadgePolicy.maximumAge - 60),
            symbol: "sun.max",
            celsius: 20
        )
        XCTAssertNil(MapHomeHomeWeatherBadgePolicy.badge(from: [old], now: now))
        var noFetch = weather(at: now, symbol: "sun.max", celsius: 20)
        noFetch.fetchedAt = nil
        XCTAssertNil(MapHomeHomeWeatherBadgePolicy.badge(from: [noFetch], now: now))
    }

    func testHomeWeatherBadgePrefersObservationOverForecastAtSameTime() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var forecast = weather(at: now, symbol: "cloud", celsius: 10)
        forecast.isForecast = true
        let observed = weather(at: now, symbol: "sun.max", celsius: 12)
        let badge = try XCTUnwrap(MapHomeHomeWeatherBadgePolicy.badge(from: [forecast, observed], now: now))
        XCTAssertEqual(badge.symbolName, "sun.max")
    }

    func testWeatherSymbolFallsBackToConditionWhenProviderSymbolIsEmpty() {
        func symbol(_ condition: String, _ provided: String = "") -> String {
            MapHomeHomeWeatherBadgePolicy.symbolName(for: WeatherContext(
                observedAt: .now, condition: condition, symbolName: provided, temperatureCelsius: 1
            ))
        }
        XCTAssertEqual(symbol("rain", "cloud.heavyrain.fill"), "cloud.heavyrain.fill")
        XCTAssertEqual(symbol("clear"), "sun.max")
        XCTAssertEqual(symbol("partlyCloudy"), "cloud.sun")
        XCTAssertEqual(symbol("mostlyCloudy"), "cloud")
        XCTAssertEqual(symbol("heavyRain"), "cloud.rain")
        XCTAssertEqual(symbol("thunderstorms"), "cloud.bolt.rain")
        XCTAssertEqual(symbol("flurries"), "cloud.snow")
        XCTAssertEqual(symbol("foggy"), "cloud.fog")
        XCTAssertEqual(symbol("???"), "cloud")
    }

    // MARK: - Route speed gradient

    func testGradientColorsFollowThePawprintSpeedScale() {
        XCTAssertEqual(MapHomeRouteSpeedGradient.colorHex(forMetersPerSecond: 0), "#1FD11F")
        XCTAssertEqual(MapHomeRouteSpeedGradient.colorHex(forMetersPerSecond: 150 / 3.6), "#D11F1F")
        XCTAssertEqual(
            MapHomeRouteSpeedGradient.colorHex(forMetersPerSecond: 500),
            "#D11F1F",
            "시속 150km를 넘으면 빨강에 머문다"
        )
        let middle = MapHomeRouteSpeedGradient.colorHex(forMetersPerSecond: 75 / 3.6)
        XCTAssertNotEqual(middle, "#1FD11F")
        XCTAssertNotEqual(middle, "#D11F1F")
    }

    func testGradientSplitsSlowThenFastRouteIntoGreenThenRedPieces() throws {
        let route = makeRoute(stepsMeters: Array(repeating: 1.0, count: 50) + Array(repeating: 30.0, count: 50))
        let pieces = try XCTUnwrap(MapHomeRouteSpeedGradient.pieces(
            coordinates: route.coordinates,
            timestamps: route.timestamps
        ))
        XCTAssertLessThanOrEqual(pieces.count, MapHomeRouteSpeedGradient.maximumPieces)
        XCTAssertEqual(pieces.first?.startIndex, 0)
        XCTAssertEqual(pieces.last?.endIndex, route.coordinates.count - 1)
        for (earlier, later) in zip(pieces, pieces.dropFirst()) {
            XCTAssertEqual(earlier.endIndex, later.startIndex, "인접 구간은 끝점을 공유해 끊기지 않는다")
            XCTAssertLessThan(earlier.startIndex, earlier.endIndex)
        }
        let first = try XCTUnwrap(pieces.first)
        let last = try XCTUnwrap(pieces.last)
        XCTAssertLessThan(first.speedMetersPerSecond, 3)
        XCTAssertGreaterThan(last.speedMetersPerSecond, 20)
        XCTAssertNotEqual(first.colorHex, last.colorHex)
    }

    func testGradientPieceCountIsCappedAndShortRoutesUseOnePiecePerEdge() throws {
        let long = makeRoute(stepsMeters: Array(repeating: 2.0, count: 5_000))
        let capped = try XCTUnwrap(MapHomeRouteSpeedGradient.pieces(
            coordinates: long.coordinates, timestamps: long.timestamps
        ))
        XCTAssertEqual(capped.count, MapHomeRouteSpeedGradient.maximumPieces)
        let custom = try XCTUnwrap(MapHomeRouteSpeedGradient.pieces(
            coordinates: long.coordinates, timestamps: long.timestamps, maximumPieces: 8
        ))
        XCTAssertEqual(custom.count, 8)
        let short = makeRoute(stepsMeters: [2, 2])
        XCTAssertEqual(
            MapHomeRouteSpeedGradient.pieces(
                coordinates: short.coordinates, timestamps: short.timestamps
            )?.count,
            2
        )
    }

    func testGradientFallsBackToSingleColorWhenSpeedIsUnknown() {
        let route = makeRoute(stepsMeters: [3, 3, 3])
        let sameTime = Array(repeating: route.timestamps[0], count: route.timestamps.count)
        XCTAssertNil(MapHomeRouteSpeedGradient.pieces(
            coordinates: route.coordinates, timestamps: sameTime
        ))
        XCTAssertNil(MapHomeRouteSpeedGradient.pieces(
            coordinates: route.coordinates, timestamps: Array(route.timestamps.dropLast())
        ))
        XCTAssertNil(MapHomeRouteSpeedGradient.pieces(
            coordinates: [route.coordinates[0]], timestamps: [route.timestamps[0]]
        ))
        XCTAssertNil(MapHomeRouteGradientSlicer.slices(
            overlayID: "x", coordinates: route.coordinates, timestamps: sameTime
        ))
    }

    func testGradientFillsPiecesWithoutTimeFromNeighbors() throws {
        let route = makeRoute(stepsMeters: [2, 2, 2, 2])
        var timestamps = route.timestamps
        // 가운데 두 점이 같은 시각이라 그 사이 구간 속도를 알 수 없다.
        timestamps[3] = timestamps[2]
        let pieces = try XCTUnwrap(MapHomeRouteSpeedGradient.pieces(
            coordinates: route.coordinates, timestamps: timestamps
        ))
        XCTAssertEqual(pieces.count, 4)
        XCTAssertTrue(pieces.allSatisfy { $0.speedMetersPerSecond.isFinite && $0.speedMetersPerSecond >= 0 })
        XCTAssertEqual(MapHomeRouteSpeedGradient.fillGaps([nil, 4, nil, nil, 6, nil]) ?? [], [4, 4, 4, 4, 6, 6])
        XCTAssertNil(MapHomeRouteSpeedGradient.fillGaps([nil, nil]))
    }

    func testMovingAverageSoftensSuddenColorChange() {
        let smoothed = MapHomeRouteSpeedGradient.movingAverage([0, 0, 30, 0, 0])
        XCTAssertEqual(smoothed.count, 5)
        XCTAssertEqual(smoothed[2], 10, accuracy: 0.0001)
        XCTAssertEqual(smoothed[1], 10, accuracy: 0.0001)
        XCTAssertEqual(smoothed[0], 0, accuracy: 0.0001)
    }

    func testGradientSlicesShareGeometryAndCarryColors() throws {
        let route = makeRoute(stepsMeters: Array(repeating: 1.0, count: 20) + Array(repeating: 25.0, count: 20))
        let slices = try XCTUnwrap(MapHomeRouteGradientSlicer.slices(
            overlayID: "route-1", coordinates: route.coordinates, timestamps: route.timestamps
        ))
        XCTAssertEqual(slices.first?.id, "route-1#g0")
        XCTAssertEqual(Set(slices.map(\.id)).count, slices.count)
        XCTAssertTrue(slices.allSatisfy { $0.coordinates.count >= 2 })
        XCTAssertEqual(slices.first?.coordinates.first?.longitude, route.coordinates.first?.longitude)
        XCTAssertEqual(slices.last?.coordinates.last?.longitude, route.coordinates.last?.longitude)
        XCTAssertNotEqual(slices.first?.colorHex, slices.last?.colorHex)
    }

    // MARK: - Live zoom

    func testLiveZoomZoomsOutWhenFastAndInWhenSlow() throws {
        let fast = MapHomeLiveZoomGovernor()
        let out = try XCTUnwrap(fast.nextDistance(current: 1_000, speedMetersPerSecond: 25, uptime: 10))
        XCTAssertGreaterThan(out, 1_000)
        XCTAssertLessThan(out, MapHomePlaybackZoomPolicy.farDistance)

        let slow = MapHomeLiveZoomGovernor()
        let into = try XCTUnwrap(slow.nextDistance(current: 8_000, speedMetersPerSecond: 0, uptime: 10))
        XCTAssertLessThan(into, 8_000)
        XCTAssertGreaterThan(into, MapHomePlaybackZoomPolicy.nearDistance)
    }

    func testLiveZoomReturnsToDefaultDistanceWhenStopped() throws {
        let governor = MapHomeLiveZoomGovernor()
        var distance = 12_000.0
        var uptime = 100.0
        for _ in 0..<30 {
            if let next = governor.nextDistance(
                current: distance, speedMetersPerSecond: 0, uptime: uptime
            ) { distance = next }
            uptime += MapHomeLiveZoomGovernor.minimumInterval + 0.1
        }
        XCTAssertEqual(
            distance, MapHomePlaybackZoomPolicy.nearDistance,
            accuracy: MapHomePlaybackZoomPolicy.nearDistance * 0.2
        )
    }

    func testLiveZoomIgnoresSmallDifferencesAndRespectsMinimumInterval() throws {
        let near = MapHomePlaybackZoomPolicy.nearDistance
        let governor = MapHomeLiveZoomGovernor()
        // 목표(기본 줌)와 15% 안쪽 차이는 무시한다.
        XCTAssertNil(governor.nextDistance(current: near * 1.1, speedMetersPerSecond: 0, uptime: 0))
        XCTAssertNil(governor.nextDistance(current: near * 0.9, speedMetersPerSecond: 0, uptime: 5))
        // 경계 밖이면 움직인다.
        XCTAssertNotNil(governor.nextDistance(current: near * 1.2, speedMetersPerSecond: 0, uptime: 10))
        // 변경 직후 최소 간격 동안은 다시 바꾸지 않는다.
        XCTAssertNil(governor.nextDistance(current: near * 3, speedMetersPerSecond: 0, uptime: 11))
        XCTAssertNotNil(governor.nextDistance(
            current: near * 3, speedMetersPerSecond: 0,
            uptime: 10 + MapHomeLiveZoomGovernor.minimumInterval + 0.01
        ))
    }

    func testLiveZoomKeepsDistanceWhenSpeedIsUnknown() {
        let governor = MapHomeLiveZoomGovernor()
        XCTAssertNil(governor.nextDistance(current: 3_000, speedMetersPerSecond: nil, uptime: 0))
        XCTAssertNil(governor.nextDistance(current: 3_000, speedMetersPerSecond: -1, uptime: 5))
        XCTAssertNil(governor.nextDistance(current: 3_000, speedMetersPerSecond: .nan, uptime: 10))
        XCTAssertNil(governor.nextDistance(current: .nan, speedMetersPerSecond: 0, uptime: 15))
        XCTAssertNil(governor.nextDistance(current: 0, speedMetersPerSecond: 0, uptime: 20))
    }

    func testLiveZoomPausesAfterUserAdjustmentAndResumes() {
        let governor = MapHomeLiveZoomGovernor()
        governor.pauseForUserAdjustment(uptime: 100)
        XCTAssertTrue(governor.isPaused(uptime: 110))
        XCTAssertNil(governor.nextDistance(current: 8_000, speedMetersPerSecond: 0, uptime: 110))
        let resume = 100 + MapHomeLiveZoomGovernor.userPauseDuration + 0.1
        XCTAssertFalse(governor.isPaused(uptime: resume))
        XCTAssertNotNil(governor.nextDistance(current: 8_000, speedMetersPerSecond: 0, uptime: resume))

        governor.pauseForUserAdjustment(uptime: 200)
        governor.reset()
        XCTAssertFalse(governor.isPaused(uptime: 201))
    }

    func testLiveZoomSmoothsSpeedSpikes() throws {
        let spike = MapHomeLiveZoomGovernor()
        _ = spike.nextDistance(current: 500, speedMetersPerSecond: 0, uptime: 0)
        let smoothed = spike.nextDistance(current: 500, speedMetersPerSecond: 30, uptime: 10)
        let direct = MapHomeLiveZoomGovernor()
        let jumped = direct.nextDistance(current: 500, speedMetersPerSecond: 30, uptime: 10)
        XCTAssertLessThan(try XCTUnwrap(smoothed), try XCTUnwrap(jumped))
    }

    // MARK: - GPS fix log

    func testGPSFixFieldsAndMetricsContainNoCoordinates() {
        let fields = GPSFixDiagnostics.fields(
            accepted: true, reason: "moving", source: "device", hasAltitude: true
        )
        let metrics = GPSFixDiagnostics.metrics(
            horizontalAccuracy: 4.6, speed: 1.26, course: 87.4, batchCount: 2
        )
        XCTAssertEqual(fields, [
            "gate": "accepted", "reason": "moving", "source": "device", "has_altitude": "true",
        ])
        XCTAssertEqual(metrics["accuracy_m"], 5)
        XCTAssertEqual(metrics["speed_mps"] ?? -1, 1.3, accuracy: 0.0001)
        XCTAssertEqual(metrics["course_deg"], 87)
        XCTAssertEqual(metrics["batch_count"], 2)
        for key in Set(fields.keys).union(metrics.keys) {
            XCTAssertFalse(key.contains("lat") || key.contains("lon") || key.contains("coord"), key)
        }
    }

    func testGPSFixMetricsOmitUnknownValues() {
        let metrics = GPSFixDiagnostics.metrics(
            horizontalAccuracy: -1, speed: -1, course: -1, batchCount: 1
        )
        XCTAssertEqual(Set(metrics.keys), ["batch_count"])
        XCTAssertEqual(
            GPSFixDiagnostics.fields(accepted: false, reason: "still", source: "device", hasAltitude: false)["gate"],
            "ignored"
        )
    }

    func testGPSFixGateReasons() {
        XCTAssertEqual(GPSFixDiagnostics.reason(
            accepted: false, hasPreviousLocation: true, isTrulyStill: true, motionIsStationary: true
        ), "still")
        XCTAssertEqual(GPSFixDiagnostics.reason(
            accepted: true, hasPreviousLocation: false, isTrulyStill: false, motionIsStationary: false
        ), "first_fix")
        XCTAssertEqual(GPSFixDiagnostics.reason(
            accepted: true, hasPreviousLocation: true, isTrulyStill: true, motionIsStationary: true
        ), "still_heartbeat")
        XCTAssertEqual(GPSFixDiagnostics.reason(
            accepted: true, hasPreviousLocation: true, isTrulyStill: false, motionIsStationary: false
        ), "moving")
        XCTAssertEqual(GPSFixDiagnostics.source(isSimulated: true, isFromAccessory: true), "simulated")
        XCTAssertEqual(GPSFixDiagnostics.source(isSimulated: false, isFromAccessory: true), "accessory")
        XCTAssertEqual(GPSFixDiagnostics.source(isSimulated: false, isFromAccessory: false), "device")
    }

    func testGPSFixIsCoalescedToOnePerSecondByNoiseGate() {
        var gate = TaptionDiagnosticsNoiseGate()
        let t0 = Date(timeIntervalSince1970: 5_000_000)
        XCTAssertEqual(gate.admit(GPSFixDiagnostics.eventName, at: t0), 0)
        XCTAssertNil(gate.admit(GPSFixDiagnostics.eventName, at: t0.addingTimeInterval(0.2)))
        XCTAssertNil(gate.admit(GPSFixDiagnostics.eventName, at: t0.addingTimeInterval(0.9)))
        XCTAssertEqual(gate.admit(GPSFixDiagnostics.eventName, at: t0.addingTimeInterval(1.1)), 2)
    }

    func testGPSFixIsWrittenToLogImmediatelyAndCoalesced() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPSFixLogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = TaptionPlanDiagnosticsLogger(
            directoryURL: directory,
            fallbackDirectoryURL: directory
        )
        let fields = GPSFixDiagnostics.fields(
            accepted: true, reason: "moving", source: "device", hasAltitude: false
        )
        let metrics = GPSFixDiagnostics.metrics(
            horizontalAccuracy: 5, speed: 1.4, course: 90, batchCount: 1
        )
        logger.record(GPSFixDiagnostics.eventName, fields: fields, metrics: metrics)
        logger.record(GPSFixDiagnostics.eventName, fields: fields, metrics: metrics)
        // 기록은 큐에서 바로 파일에 쓰이므로 플러시를 기다릴 필요 없이 읽힌다.
        var lines = logger.combinedLog().split(separator: "\n")
            .filter { $0.contains("\"event\":\"gps_fix\"") }
        XCTAssertEqual(lines.count, 1, "1초 안의 두 번째 fix는 합쳐진다")
        Thread.sleep(forTimeInterval: 1.1)
        logger.record(GPSFixDiagnostics.eventName, fields: fields, metrics: metrics)
        lines = logger.combinedLog().split(separator: "\n")
            .filter { $0.contains("\"event\":\"gps_fix\"") }
        XCTAssertEqual(lines.count, 2)
        let last = try XCTUnwrap(lines.last)
        XCTAssertTrue(last.contains("\"suppressed_since_last\":\"1\""), String(last))
        XCTAssertTrue(last.contains("\"accuracy_m\":5"), String(last))
        XCTAssertFalse(last.contains("latitude"))
        XCTAssertFalse(last.contains("longitude"))
    }

    // MARK: - Helpers

    private func weather(at date: Date, symbol: String, celsius: Double) -> WeatherContext {
        WeatherContext(
            observedAt: date,
            fetchedAt: date,
            isStale: false,
            isForecast: false,
            providerName: "WeatherKit",
            condition: "clear",
            symbolName: symbol,
            temperatureCelsius: celsius
        )
    }

    /// 경도 방향으로 구간마다 `stepsMeters`만큼 가는 1초 간격 경로.
    private func makeRoute(stepsMeters: [Double]) -> (coordinates: [CLLocationCoordinate2D], timestamps: [Date]) {
        let latitude = 37.5
        let metersPerDegreeLongitude = 111_320 * cos(latitude * .pi / 180)
        var longitude = 127.0
        var coordinates = [CLLocationCoordinate2D(latitude: latitude, longitude: longitude)]
        var timestamps = [Date(timeIntervalSince1970: 1_800_000_000)]
        for step in stepsMeters {
            longitude += step / metersPerDegreeLongitude
            coordinates.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            timestamps.append(timestamps[timestamps.count - 1].addingTimeInterval(1))
        }
        return (coordinates, timestamps)
    }
}
