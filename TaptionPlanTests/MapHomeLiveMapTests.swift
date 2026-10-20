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

    func testPlaybackSpeedUsesNeighbouringPointsWhenNoTravelSegmentExists() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func reading(_ offset: TimeInterval, longitude: Double, speed: Double? = nil) -> SensorReading {
            var value = SensorReading(timestamp: base.addingTimeInterval(offset))
            value.point = GeoPoint(latitude: 37.5, longitude: longitude, altitude: 0,
                                   horizontalAccuracy: 5, verticalAccuracy: 5)
            value.speedMetersPerSecond = speed
            return value
        }
        // 위도 37.5°에서 경도 0.001° ≈ 88m. 60초에 약 88m → 약 1.5m/s(걷기).
        let walking = [reading(0, longitude: 127.000), reading(60, longitude: 127.001)]
        let slow = MapHomePlaybackSpeed.speed(at: base.addingTimeInterval(30), travel: [], readings: walking)
        XCTAssertEqual(try XCTUnwrap(slow), 88.0 / 60.0, accuracy: 0.3)
        // 60초에 약 8.8km → 약 147m/s는 거리 비례 줌의 상한을 넘는 빠른 이동.
        let fast = [reading(0, longitude: 127.0), reading(60, longitude: 127.1)]
        XCTAssertGreaterThan(
            try XCTUnwrap(MapHomePlaybackSpeed.speed(at: base.addingTimeInterval(30), travel: [], readings: fast)), 30
        )
        // 제자리: 같은 좌표 두 점은 0, 한쪽 점만 있으면 가까운 센서 속도, 둘 다 멀면 nil.
        let still = [reading(0, longitude: 127.0), reading(600, longitude: 127.0)]
        XCTAssertEqual(MapHomePlaybackSpeed.speed(at: base.addingTimeInterval(300), travel: [], readings: still), 0)
        let single = [reading(0, longitude: 127.0, speed: 1.2)]
        XCTAssertEqual(MapHomePlaybackSpeed.speed(at: base.addingTimeInterval(60), travel: [], readings: single), 1.2)
        XCTAssertNil(MapHomePlaybackSpeed.speed(at: base.addingTimeInterval(600), travel: [], readings: single))
        XCTAssertNil(MapHomePlaybackSpeed.speed(at: base, travel: [], readings: []))
    }

    func testDayTravelSummaryGroupsByModeAndSortsByDistance() {
        func segment(_ mode: TravelMode, _ meters: Double) -> TravelSegment {
            TravelSegment(
                mode: mode,
                span: TimeSpan(start: .now, end: .now.addingTimeInterval(60)),
                distanceMeters: meters,
                confidence: .high,
                evidence: [],
                isConfirmed: true
            )
        }
        let entries = MapHomeDayTravelSummary.entries(from: [
            segment(.walking, 400), segment(.subway, 12_300), segment(.walking, 650),
            segment(.cycling, 5), segment(.car, .nan),
        ])
        XCTAssertEqual(entries.map(\.mode), [.subway, .walking])
        XCTAssertEqual(entries[1].meters, 1_050, accuracy: 0.001)
        XCTAssertEqual(MapHomeDayTravelSummary.distanceText(1_050), "1.1 km")
        XCTAssertEqual(MapHomeDayTravelSummary.distanceText(420), "420 m")
    }

    private func photo(_ id: String, minute: Double, lat: Double, lon: Double, hidden: Bool = false) -> PhotoMoment {
        let day = Calendar.autoupdatingCurrent.startOfDay(for: .now)
        return PhotoMoment(
            id: id,
            capturedAt: day.addingTimeInterval(minute * 60),
            pixelWidth: 10,
            pixelHeight: 10,
            isFavorite: false,
            isHiddenFromTimeline: hidden,
            location: GeoPoint(latitude: lat, longitude: lon, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5),
            linkedPlanID: nil,
            linkedPlaceID: nil
        )
    }

    func testPhotoClustersGroupNearbyAndIgnoreHiddenOrUnlocated() {
        var noLocation = photo("n", minute: 5, lat: 0, lon: 0)
        noLocation.location = nil
        let moments = [
            photo("a", minute: 60, lat: 37.5000, lon: 127.0000),
            photo("b", minute: 70, lat: 37.5002, lon: 127.0000),
            photo("c", minute: 80, lat: 37.6000, lon: 127.1000),
            photo("h", minute: 90, lat: 37.5000, lon: 127.0000, hidden: true),
            noLocation,
        ]
        let clusters = MapHomePhotoPolicy.clusters(from: moments, radiusMeters: 100)
        XCTAssertEqual(clusters.map(\.count), [2, 1])
        XCTAssertEqual(clusters[0].moments.map(\.id), ["a", "b"])
        XCTAssertGreaterThan(
            MapHomePhotoPolicy.clusterRadiusMeters(cameraDistance: 20_000),
            MapHomePhotoPolicy.clusterRadiusMeters(cameraDistance: 500)
        )
    }

    func testPhotoHighlightAndPlaybackWindow() throws {
        let cluster = try XCTUnwrap(MapHomePhotoPolicy.clusters(
            from: [photo("a", minute: 600, lat: 37.5, lon: 127.0)], radiusMeters: 50
        ).first)
        XCTAssertTrue(MapHomePhotoPolicy.isHighlighted(cluster, selectedMinute: 625))
        XCTAssertFalse(MapHomePhotoPolicy.isHighlighted(cluster, selectedMinute: 640))
        XCTAssertTrue(MapHomePhotoPolicy.playbackVisibleMoments(in: cluster, playbackMinute: 590).isEmpty)
        XCTAssertEqual(MapHomePhotoPolicy.playbackVisibleMoments(in: cluster, playbackMinute: 610).count, 1)
        XCTAssertTrue(MapHomePhotoPolicy.playbackVisibleMoments(in: cluster, playbackMinute: 640).isEmpty)
    }

    func testRecordingLayersDefaultsAndRoundTrip() {
        let defaults = MapHomeRecordingLayers(rawValue: "")
        XCTAssertFalse(defaults.cat)
        XCTAssertTrue(defaults.routes)
        XCTAssertFalse(defaults.mapMemos)
        var changed = defaults
        changed.cat = true
        changed.timeSidebar = false
        XCTAssertEqual(MapHomeRecordingLayers(rawValue: changed.rawValue), changed)
        XCTAssertEqual(MapHomeRecordingLayers(rawValue: "not json"), defaults)
    }

    func testPlaybackZoomModeRoundTripsAndDefaultsToAdaptive() {
        XCTAssertEqual(MapHomePlaybackZoomMode(rawValue: "fixed"), .fixed)
        XCTAssertNil(MapHomePlaybackZoomMode(rawValue: "unknown"))
        XCTAssertEqual(MapHomePlaybackZoomMode.allCases, [.adaptive, .fixed])
        XCTAssertEqual(MapHomePlaybackZoomMode.fixed.koreanTitle, "현재 배율로 고정")
        XCTAssertEqual(MapHomePlaybackZoomMode.adaptive.koreanTitle, "속도에 따라 가변")
    }

    func testPlaybackZoomSmootherLimitsRateAndFollowsTimeNotTicks() {
        let smoother = MapHomePlaybackZoomSmoother()
        var distance = 250.0
        var uptime = 100.0
        // 첫 호출은 기준 시각만 잡는다.
        XCTAssertEqual(smoother.next(current: distance, target: 40_000, uptime: uptime), distance)
        // 1초 동안 30틱: 초당 로그 변화 상한(0.9) 안에서만 멀어진다.
        for _ in 0..<30 {
            uptime += 1.0 / 30
            distance = smoother.next(current: distance, target: 40_000, uptime: uptime)
        }
        XCTAssertLessThanOrEqual(log(distance / 250), MapHomePlaybackZoomSmoother.maximumLogRate + 0.001)
        XCTAssertGreaterThan(distance, 250)
        // 틱 수가 달라도 같은 시간이면 비슷한 결과(시간 기준).
        let coarse = MapHomePlaybackZoomSmoother()
        var coarseDistance = 250.0
        var coarseUptime = 100.0
        _ = coarse.next(current: coarseDistance, target: 40_000, uptime: coarseUptime)
        for _ in 0..<5 {
            coarseUptime += 0.2
            coarseDistance = coarse.next(current: coarseDistance, target: 40_000, uptime: coarseUptime)
        }
        XCTAssertEqual(log(coarseDistance), log(distance), accuracy: 0.15)
        // 정지와 이동이 번갈아도 한 번에 크게 튀지 않는다.
        var flipping = 2_000.0
        var t = 200.0
        let flip = MapHomePlaybackZoomSmoother()
        _ = flip.next(current: flipping, target: 250, uptime: t)
        var largestStep = 0.0
        for index in 0..<60 {
            t += 1.0 / 30
            let before = flipping
            flipping = flip.next(current: flipping, target: index % 20 < 10 ? 250 : 40_000, uptime: t)
            largestStep = max(largestStep, abs(log(flipping / before)))
        }
        XCTAssertLessThan(largestStep, MapHomePlaybackZoomSmoother.maximumLogRate / 30 + 0.0001)
        // 목표에 가까워지면 넘지 않고 수렴한다.
        var near = 300.0
        let settle = MapHomePlaybackZoomSmoother()
        var u = 0.0
        _ = settle.next(current: near, target: 250, uptime: u)
        for _ in 0..<300 { u += 0.05; near = settle.next(current: near, target: 250, uptime: u) }
        XCTAssertEqual(near, 250, accuracy: 1)
        XCTAssertGreaterThanOrEqual(near, 250)
    }

    func testZoomScaleBaselineIsEightyFiveAndRangeIsWider() {
        typealias Policy = MapHomePlaybackZoomPolicy
        XCTAssertEqual(MapHomeCameraZoomMath.scale(distance: Policy.baselineDistance), 85)
        XCTAssertEqual(MapHomeCameraZoomMath.scale(distance: MapHomeCameraZoomMath.distance(forScale: 92)), 92)
        XCTAssertEqual(MapHomeCameraZoomMath.distance(forScale: 100), MapHomeCameraZoomMath.minimumDistance, accuracy: 0.001)
        XCTAssertEqual(MapHomeCameraZoomMath.distance(forScale: 0), MapHomeCameraZoomMath.maximumDistance, accuracy: 1)
        // 시작 화면도 85.
        XCTAssertEqual(MapHomeStartupCameraPolicy.distance, Policy.baselineDistance, accuracy: 0.001)
        // 탈것 곡선: 느리면 92, 빠르면 42, 그 사이는 단조 감소.
        XCTAssertEqual(Policy.scale(forVehicleSpeed: 0.2), 92, accuracy: 0.001)
        XCTAssertEqual(Policy.scale(forVehicleSpeed: 40), 42, accuracy: 0.001)
        XCTAssertEqual(Policy.scale(forVehicleSpeed: 200), 42, accuracy: 0.001)
        XCTAssertGreaterThan(Policy.scale(forVehicleSpeed: 3), Policy.scale(forVehicleSpeed: 12))
        XCTAssertGreaterThan(Policy.scale(forVehicleSpeed: 12), Policy.scale(forVehicleSpeed: 30))
        // 센서 속도만 아는 경우: 정지·걷기는 85, 그 위는 탈것 곡선, 모르면 nil.
        XCTAssertEqual(try XCTUnwrap(Policy.targetDistance(speedMetersPerSecond: 0)), Policy.baselineDistance, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(Policy.targetDistance(speedMetersPerSecond: 2.0)), Policy.baselineDistance, accuracy: 0.001)
        XCTAssertGreaterThan(try XCTUnwrap(Policy.targetDistance(speedMetersPerSecond: 20)), Policy.baselineDistance * 10)
        XCTAssertNil(Policy.targetDistance(speedMetersPerSecond: nil))
    }

    func testPlaybackZoomPlanFixesWalkingPlacesAndStaysAndOnlyVehiclesZoom() {
        typealias Plan = MapHomePlaybackZoomPlan
        let plan = Plan(inputs: [
            .init(startMinute: 100, endMinute: 115, mode: .walking, speedMetersPerSecond: 1.4, touchesRegisteredPlace: false),
            .init(startMinute: 200, endMinute: 240, mode: .subway, speedMetersPerSecond: 20, touchesRegisteredPlace: false),
            .init(startMinute: 300, endMinute: 330, mode: .car, speedMetersPerSecond: 15, touchesRegisteredPlace: true),
            .init(startMinute: 400, endMinute: 420, mode: nil, speedMetersPerSecond: 1.0, touchesRegisteredPlace: false),
            .init(startMinute: 500, endMinute: 520, mode: .bus, speedMetersPerSecond: nil, touchesRegisteredPlace: false),
        ])
        let base = MapHomePlaybackZoomPolicy.baselineScale
        XCTAssertEqual(plan.scale(atMinute: 50), base, "정지·구간 밖은 85")
        XCTAssertEqual(plan.scale(atMinute: 105), base, "걷기는 85 고정")
        XCTAssertLessThan(plan.scale(atMinute: 220), base - 20, "지하철은 크게 축소")
        XCTAssertEqual(plan.scale(atMinute: 310), base, "등록 장소에서 이어지는 이동은 85 고정")
        XCTAssertEqual(plan.scale(atMinute: 410), base, "모드를 모르는 느린 이동은 걷기로 보고 85")
        XCTAssertEqual(plan.scale(atMinute: 510), base, "속도를 모르면 85")
        XCTAssertEqual(plan.scale(atMinute: 240), base, "구간 끝은 85로 돌아온다")
    }

    func testPlaybackZoomPlanDampsShortSegmentsAndHoldsAcrossShortGaps() {
        typealias Plan = MapHomePlaybackZoomPlan
        let base = MapHomePlaybackZoomPolicy.baselineScale
        let full = Plan(inputs: [.init(startMinute: 0, endMinute: 30, mode: .train, speedMetersPerSecond: 30, touchesRegisteredPlace: false)])
        let short = Plan(inputs: [.init(startMinute: 0, endMinute: 1, mode: .train, speedMetersPerSecond: 30, touchesRegisteredPlace: false)])
        XCTAssertLessThan(full.scale(atMinute: 5), short.scale(atMinute: 0.5), "짧은 구간은 덜 축소")
        XCTAssertGreaterThan(short.scale(atMinute: 0.5), base - 15)
        // 탈것 구간 사이 2분 틈은 앞 구간 배율을 유지하고, 10분 틈은 85로 돌아온다.
        let near = Plan(inputs: [
            .init(startMinute: 0, endMinute: 20, mode: .bus, speedMetersPerSecond: 10, touchesRegisteredPlace: false),
            .init(startMinute: 22, endMinute: 40, mode: .bus, speedMetersPerSecond: 10, touchesRegisteredPlace: false),
        ])
        XCTAssertEqual(near.scale(atMinute: 21), near.scale(atMinute: 10), accuracy: 0.001)
        let far = Plan(inputs: [
            .init(startMinute: 0, endMinute: 20, mode: .bus, speedMetersPerSecond: 10, touchesRegisteredPlace: false),
            .init(startMinute: 30, endMinute: 50, mode: .bus, speedMetersPerSecond: 10, touchesRegisteredPlace: false),
        ])
        XCTAssertEqual(far.scale(atMinute: 25), base)
    }

    func testLongTripsFitTheWholeRouteAndShortVehicleTripsStayAtBaseline() {
        typealias Plan = MapHomePlaybackZoomPlan
        let base = MapHomePlaybackZoomPolicy.baselineScale
        // 인천→대구: 약 290km, 3시간, 범위 대각선 약 250km. 집(등록 장소)에서 출발해도 85 고정이 아니라 경로 전체 맞춤.
        let trip = Plan(inputs: [.init(
            startMinute: 600, endMinute: 780, mode: .car, speedMetersPerSecond: 27,
            touchesRegisteredPlace: true, distanceMeters: 290_000, extentMeters: 250_000
        )])
        let fit = MapHomePlaybackZoomPolicy.fitScale(forExtentMeters: 250_000)
        XCTAssertEqual(trip.scale(atMinute: 690), fit, accuracy: 0.001, "가운데는 경로 전체 맞춤으로 고정")
        XCTAssertGreaterThan(fit, 15)
        XCTAssertLessThan(fit, 45, "250km 범위는 매우 넓게 본다")
        XCTAssertEqual(trip.scale(atMinute: 601), base, "시작은 85로 확대")
        XCTAssertEqual(trip.scale(atMinute: 779), base, "도착도 85로 확대")
        // 가운데에서는 시간이 지나도 배율이 변하지 않는다(고정).
        XCTAssertEqual(trip.scale(atMinute: 650), trip.scale(atMinute: 720), accuracy: 0.0001)
        // 범위가 더 좁은 긴 이동은 더 가깝게 본다.
        XCTAssertGreaterThan(
            MapHomePlaybackZoomPolicy.fitScale(forExtentMeters: 60_000),
            MapHomePlaybackZoomPolicy.fitScale(forExtentMeters: 250_000)
        )
        XCTAssertEqual(MapHomePlaybackZoomPolicy.fitScale(forExtentMeters: 5_000_000), 15, "하한")
        XCTAssertLessThanOrEqual(MapHomePlaybackZoomPolicy.fitScale(forExtentMeters: 100), 60, "상한")
        // 5km 미만 탈것은 85 고정, 5~50km는 속도 비례.
        let hop = Plan(inputs: [.init(
            startMinute: 0, endMinute: 10, mode: .bus, speedMetersPerSecond: 6,
            touchesRegisteredPlace: false, distanceMeters: 3_600, extentMeters: 3_000)])
        XCTAssertEqual(hop.scale(atMinute: 5), base)
        let city = Plan(inputs: [.init(
            startMinute: 0, endMinute: 40, mode: .bus, speedMetersPerSecond: 12,
            touchesRegisteredPlace: false, distanceMeters: 28_800, extentMeters: 20_000)])
        XCTAssertLessThan(city.scale(atMinute: 20), base - 10)
        // 걷기는 거리가 길어도(예: 하루 종일 걷기) 85 고정이다.
        let hike = Plan(inputs: [.init(
            startMinute: 0, endMinute: 600, mode: .walking, speedMetersPerSecond: 1.4,
            touchesRegisteredPlace: false, distanceMeters: 60_000, extentMeters: 40_000)])
        XCTAssertEqual(hike.scale(atMinute: 300), base)
    }

    func testPlaybackZoomInputBuilderMeasuresSpeedAndRegisteredPlaceContact() throws {
        let dayStart = Date(timeIntervalSince1970: 1_800_000_000)
        func point(_ meters: Double) -> GeoPoint {
            GeoPoint(latitude: 37.5, longitude: 127.0 + meters / (111_320 * cos(37.5 * .pi / 180)),
                     altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5)
        }
        func reading(minute: Double, meters: Double) -> SensorReading {
            SensorReading(timestamp: dayStart.addingTimeInterval(minute * 60), point: point(meters))
        }
        // 10분 동안 12km: 20m/s. 출발점은 등록 장소(0m)에서 100m 이내.
        let readings = (0...10).map { reading(minute: 100 + Double($0), meters: Double($0) * 1_200) }
        let inputs = MapHomePlaybackZoomInputBuilder.inputs(
            ranges: [MapHomePlaybackMovementRange(startMinute: 100, endMinute: 110, mode: .car)],
            dayStart: dayStart, travel: [], readings: readings, places: [point(100)]
        )
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(try XCTUnwrap(inputs[0].speedMetersPerSecond), 20, accuracy: 0.5)
        XCTAssertTrue(inputs[0].touchesRegisteredPlace)
        let away = MapHomePlaybackZoomInputBuilder.inputs(
            ranges: [MapHomePlaybackMovementRange(startMinute: 100, endMinute: 110, mode: .car)],
            dayStart: dayStart, travel: [], readings: readings, places: [point(5_000_000)]
        )
        XCTAssertFalse(away[0].touchesRegisteredPlace)
        XCTAssertNil(MapHomePlaybackZoomInputBuilder.speed(from: dayStart, to: dayStart.addingTimeInterval(600), travel: [], readings: []))
        // 거리와 범위: 10분 동안 12km를 직선으로 가면 거리 12km, 범위 대각선 12km.
        XCTAssertEqual(try XCTUnwrap(inputs[0].distanceMeters), 12_000, accuracy: 100)
        XCTAssertEqual(try XCTUnwrap(inputs[0].extentMeters), 12_000, accuracy: 100)
    }

    func testLiveFollowSpeedTreatsStaleSlowReadingAsStationary() {
        typealias Speed = MapHomeLiveFollowSpeed
        XCTAssertEqual(Speed.speed(latestAge: 3, latestSpeed: 1.2), 1.2)
        XCTAssertNil(Speed.speed(latestAge: 3, latestSpeed: nil), "최근 값에 속도가 없으면 알 수 없음")
        XCTAssertEqual(Speed.speed(latestAge: 40, latestSpeed: 0.2), 0, "멈춰서 fix가 끊기면 정지")
        XCTAssertEqual(Speed.speed(latestAge: 120, latestSpeed: 1.5), 0, "걷기 이하로 끊기면 정지")
        XCTAssertEqual(Speed.speed(latestAge: 40, latestSpeed: nil), 0)
        XCTAssertNil(Speed.speed(latestAge: 40, latestSpeed: 20), "달리다 끊기면(터널) 정지로 단정하지 않는다")
        XCTAssertNil(Speed.speed(latestAge: 3, latestSpeed: -1))
    }

    func testStationaryGovernorZoomsInStepByStepToTheBaseDistance() {
        let governor = MapHomeLiveZoomGovernor()
        var distance = 15_000.0
        var uptime = 100.0
        var steps = 0
        while let next = governor.nextDistance(current: distance, speedMetersPerSecond: 0, uptime: uptime) {
            XCTAssertLessThan(next, distance)
            distance = next
            uptime += MapHomeLiveZoomGovernor.minimumInterval + 0.01
            steps += 1
            XCTAssertLessThan(steps, 40)
        }
        XCTAssertLessThan(abs(log(distance / MapHomePlaybackZoomPolicy.baselineDistance)), MapHomeLiveZoomGovernor.hysteresis)
        XCTAssertLessThan(Double(steps) * MapHomeLiveZoomGovernor.minimumInterval, 45, "약 45초 안에 기본 거리에 닿는다")
    }

    func testGradientColorsFollowThePawprintSpeedScale() {
        XCTAssertEqual(MapHomeRouteSpeedGradient.colorHex(forMetersPerSecond: 0), "#D11F1F")
        XCTAssertEqual(MapHomeRouteSpeedGradient.colorHex(forMetersPerSecond: 150 / 3.6), "#1F1FD1")
        XCTAssertEqual(
            MapHomeRouteSpeedGradient.colorHex(forMetersPerSecond: 500),
            "#1F1FD1",
            "시속 150km를 넘으면 파랑에 머문다"
        )
        XCTAssertEqual(
            MapHomeRouteSpeedGradient.colorHex(forMetersPerSecond: 75 / 3.6), "#1FD11F",
            "중간 속도는 초록: 빨강→초록→파랑을 반씩 나눈다"
        )
        let quarter = MapHomeRouteSpeedGradient.colorHex(forMetersPerSecond: 37.5 / 3.6)
        XCTAssertNotEqual(quarter, "#D11F1F")
        XCTAssertNotEqual(quarter, "#1FD11F")
    }

    func testGradientSplitsSlowThenFastRouteIntoRedThenBluePieces() throws {
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

    func testGradientPieceCountIsCappedAndShortRoutesUseOnePiece() throws {
        let long = makeRoute(stepsMeters: Array(repeating: 2.0, count: 5_000))
        let capped = try XCTUnwrap(MapHomeRouteSpeedGradient.pieces(
            coordinates: long.coordinates, timestamps: long.timestamps
        ))
        XCTAssertLessThanOrEqual(capped.count, MapHomeRouteSpeedGradient.maximumPieces)
        let custom = try XCTUnwrap(MapHomeRouteSpeedGradient.pieces(
            coordinates: long.coordinates, timestamps: long.timestamps, maximumPieces: 8
        ))
        XCTAssertLessThanOrEqual(custom.count, 8)
        let short = makeRoute(stepsMeters: [2, 2])
        XCTAssertEqual(
            MapHomeRouteSpeedGradient.pieces(
                coordinates: short.coordinates, timestamps: short.timestamps
            )?.count,
            1
        )
    }

    func testGradientColorsOfDrawnPiecesDoNotChangeAsRouteGrows() throws {
        let steps = (0..<400).map { Double(1 + ($0 / 40) * 3) }
        let full = makeRoute(stepsMeters: steps)
        let partial = makeRoute(stepsMeters: Array(steps.prefix(250)))
        let fullPieces = try XCTUnwrap(MapHomeRouteSpeedGradient.pieces(
            coordinates: full.coordinates, timestamps: full.timestamps
        ))
        let partialPieces = try XCTUnwrap(MapHomeRouteSpeedGradient.pieces(
            coordinates: partial.coordinates, timestamps: partial.timestamps
        ))
        // 마지막 몇 구간(성장 중인 머리)을 뺀 이미 그린 구간은 색이 같아야 한다.
        for index in 0..<(partialPieces.count - 3) {
            XCTAssertEqual(partialPieces[index].startIndex, fullPieces[index].startIndex)
            XCTAssertEqual(partialPieces[index].colorHex, fullPieces[index].colorHex)
        }
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
        let route = makeRoute(stepsMeters: Array(repeating: 2.0, count: 12))
        var timestamps = route.timestamps
        // 가운데 구간(간선 4~7)의 점들이 모두 같은 시각이라 그 구간 속도를 알 수 없다.
        for index in 5...8 { timestamps[index] = timestamps[4] }
        let pieces = try XCTUnwrap(MapHomeRouteSpeedGradient.pieces(
            coordinates: route.coordinates, timestamps: timestamps
        ))
        XCTAssertEqual(pieces.count, 3)
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
        XCTAssertLessThan(out, MapHomeCameraZoomMath.distance(forScale: MapHomePlaybackZoomPolicy.fastestScale))

        let slow = MapHomeLiveZoomGovernor()
        let into = try XCTUnwrap(slow.nextDistance(current: 8_000, speedMetersPerSecond: 0, uptime: 10))
        XCTAssertLessThan(into, 8_000)
        XCTAssertGreaterThan(into, MapHomePlaybackZoomPolicy.baselineDistance)
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
            distance, MapHomePlaybackZoomPolicy.baselineDistance,
            accuracy: MapHomePlaybackZoomPolicy.baselineDistance * 0.2
        )
    }

    func testLiveZoomIgnoresSmallDifferencesAndRespectsMinimumInterval() throws {
        let near = MapHomePlaybackZoomPolicy.baselineDistance
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
