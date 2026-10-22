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

    func testPawprintWindowedSpeedIgnoresSingleSampleJitter() {
        // 1초 간격으로 10 m씩(10 m/s) 가다가 한 점만 튄 경로.
        let route = makeRoute(stepsMeters: Array(repeating: 10.0, count: 120))
        var coordinates = route.coordinates
        coordinates[60].latitude += 0.0005
        let jittered = MapHomePawprintSpeedColor.windowedSpeed(
            coordinates: coordinates, timestamps: route.timestamps, index: 60
        )
        let clean = MapHomePawprintSpeedColor.windowedSpeed(
            coordinates: route.coordinates, timestamps: route.timestamps, index: 60
        )
        let instant = MapHomePawprintSpeedColor.speed(
            from: coordinates[60], at: route.timestamps[60],
            to: coordinates[61], at: route.timestamps[61]
        )
        XCTAssertEqual(try XCTUnwrap(clean), 10, accuracy: 1)
        XCTAssertLessThan(abs(try XCTUnwrap(jittered) - 10), abs(try XCTUnwrap(instant) - 10))
        // 같은 점은 경로가 더 길어져도(재생 진행) 같은 속도를 낸다.
        let shorter = MapHomePawprintSpeedColor.windowedSpeed(
            coordinates: Array(route.coordinates.prefix(100)),
            timestamps: Array(route.timestamps.prefix(100)), index: 60
        )
        XCTAssertEqual(try XCTUnwrap(shorter), try XCTUnwrap(clean), accuracy: 0.001)
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
        XCTAssertEqual(Policy.scale(forVehicleSpeed: 40), 30, accuracy: 0.001)
        XCTAssertEqual(Policy.scale(forVehicleSpeed: 200), 30, accuracy: 0.001)
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
        XCTAssertEqual(plan.scale(atMinute: 300.5), base, "등록 장소에서 이어지는 이동은 출발 몇 분만 85")
        XCTAssertLessThan(plan.scale(atMinute: 310), base - 20, "가운데는 속도에 따라 크게 축소")
        XCTAssertEqual(plan.scale(atMinute: 329.5), base, "도착 몇 분도 85")
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
        // 1km 미만 탈것은 85 고정, 1~50km는 속도 비례.
        let hop = Plan(inputs: [.init(
            startMinute: 0, endMinute: 10, mode: .bus, speedMetersPerSecond: 6,
            touchesRegisteredPlace: false, distanceMeters: 800, extentMeters: 700)])
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

extension MapHomeLiveMapTests {
    func testPastWeatherIsDimmedOnlyWhenEndedBeforeOneHourAgo() {
        let now = Date()
        func context(end: Date, forecast: Bool = false) -> WeatherContext {
            WeatherContext(
                observedAt: end.addingTimeInterval(-3_600),
                validUntil: end,
                isForecast: forecast,
                condition: "c",
                symbolName: "sun.max",
                temperatureCelsius: 10
            )
        }
        XCTAssertEqual(MapHomeWeatherDisplayPolicy.pillOpacity(for: context(end: now.addingTimeInterval(-7_200)), now: now), MapHomeWeatherDisplayPolicy.fixedPastPillOpacity)
        XCTAssertEqual(MapHomeWeatherDisplayPolicy.pillOpacity(for: context(end: now.addingTimeInterval(-1_800)), now: now), 1)
        XCTAssertEqual(MapHomeWeatherDisplayPolicy.pillOpacity(for: context(end: now.addingTimeInterval(3_600)), now: now), 1)
        XCTAssertEqual(
            MapHomeWeatherDisplayPolicy.opacity(for: context(end: now.addingTimeInterval(-7_200), forecast: true)),
            MapHomeWeatherDisplayPolicy.forecastOpacity
        )
        XCTAssertEqual(
            MapHomeWeatherDisplayPolicy.pillOpacity(for: context(end: now.addingTimeInterval(-7_200), forecast: true), now: now),
            1
        )
    }

    func testHomeLayoutStyleDefaultsToClassicAndReservesBottomSpace() {
        XCTAssertEqual(MapHomeLayoutStyle(rawValue: "unknown") ?? .classic, .classic)
        XCTAssertFalse(MapHomeLayoutStyle.classic.movesActionsToBottom)
        XCTAssertEqual(MapHomeLayoutStyle.classic.bottomReservedHeight, 0)
        for style in [MapHomeLayoutStyle.tabBar] {
            XCTAssertTrue(style.movesActionsToBottom)
            XCTAssertGreaterThan(style.bottomReservedHeight, 44)
            XCTAssertEqual(MapHomeLayoutStyle(rawValue: style.rawValue), style)
        }
    }

    func testDaysUntilNextWeeklyRewardCountsInSevenDayCycles() {
        typealias Policy = MapHomeGrowthPolicy
        XCTAssertEqual(Policy.daysUntilNextWeeklyReward(streak: 0), 7)
        XCTAssertEqual(Policy.daysUntilNextWeeklyReward(streak: 1), 6)
        XCTAssertEqual(Policy.daysUntilNextWeeklyReward(streak: 6), 1)
        XCTAssertEqual(Policy.daysUntilNextWeeklyReward(streak: 7), 7, "7일째에 보상을 받은 직후에는 다음 7일")
        XCTAssertEqual(Policy.daysUntilNextWeeklyReward(streak: 8), 6, "8일째부터 0으로 떨어지지 않는다")
        XCTAssertEqual(Policy.daysUntilNextWeeklyReward(streak: 13), 1)
        XCTAssertEqual(Policy.daysUntilNextWeeklyReward(streak: 14), 7)
        XCTAssertEqual(Policy.daysUntilNextWeeklyReward(streak: -3), 7)
    }

    func testCalendarCountMetricsFormatCellsAndPanel() {
        typealias Policy = MapHomeCalendarTimeTotalsPolicy
        XCTAssertEqual(Policy.countCellText(count: 0), "")
        XCTAssertEqual(Policy.countCellText(count: 3), "3")
        XCTAssertEqual(Policy.countText(count: 4, kind: .places, language: .korean), "4곳")
        XCTAssertEqual(Policy.countText(count: 6, kind: .trips, language: .korean), "6회")
        XCTAssertTrue(MapHomeCalendarTimeKind.places.isCount)
        XCTAssertTrue(MapHomeCalendarTimeKind.trips.isCount)
        XCTAssertFalse(MapHomeCalendarTimeKind.distance.isCount)
        XCTAssertTrue(MapHomeCalendarTimeKind.distance.usesAccentTint)
        XCTAssertFalse(MapHomeCalendarTimeKind.sleep.usesAccentTint)
    }

    func testPlaybackZoomFollowsInstantSpeedInsideVehicleSegments() {
        typealias Plan = MapHomePlaybackZoomPlan
        let base = MapHomePlaybackZoomPolicy.baselineScale
        let plan = Plan(inputs: [.init(
            startMinute: 100, endMinute: 160, mode: .car, speedMetersPerSecond: 15,
            touchesRegisteredPlace: false, distanceMeters: 30_000, extentMeters: 20_000
        )])
        let fast = plan.scale(atMinute: 130, speedMetersPerSecond: 25)
        let slow = plan.scale(atMinute: 130, speedMetersPerSecond: 3.5)
        XCTAssertLessThan(fast, slow, "빠를수록 더 축소")
        XCTAssertLessThan(fast, base - 20)
        XCTAssertEqual(plan.scale(atMinute: 130, speedMetersPerSecond: 1.0), base, "걷기 이하로 느려지면 85까지 확대")
        XCTAssertEqual(plan.scale(atMinute: 130, speedMetersPerSecond: nil), plan.scale(atMinute: 130), "속도를 모르면 계획 그대로")
        XCTAssertEqual(plan.scale(atMinute: 50, speedMetersPerSecond: 25), base, "구간 밖은 85")
    }

    func testLongHaulFitStaysFixedRegardlessOfInstantSpeed() {
        typealias Plan = MapHomePlaybackZoomPlan
        let trip = Plan(inputs: [.init(
            startMinute: 600, endMinute: 780, mode: .car, speedMetersPerSecond: 27,
            touchesRegisteredPlace: false, distanceMeters: 290_000, extentMeters: 250_000
        )])
        XCTAssertEqual(
            trip.scale(atMinute: 690, speedMetersPerSecond: 0.5),
            trip.scale(atMinute: 690),
            "경로 전체 맞춤은 순간 속도로 흔들리지 않는다"
        )
    }

    func testZoomSmootherZoomsInMoreGentlyThanOut() {
        let outSmoother = MapHomePlaybackZoomSmoother()
        let inSmoother = MapHomePlaybackZoomSmoother()
        _ = outSmoother.next(current: 250, target: 800, uptime: 0)
        _ = inSmoother.next(current: 800, target: 250, uptime: 0)
        let out = outSmoother.next(current: 250, target: 800, uptime: 0.5)
        let into = inSmoother.next(current: 800, target: 250, uptime: 0.5)
        XCTAssertGreaterThan(abs(log(out / 250)), abs(log(into / 800)), "줌인이 더 천천히")
    }

    func testPlacingUnlocatedPhotosUsesNearestMovementReadingWithinGap() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func reading(_ seconds: TimeInterval, longitude: Double) -> SensorReading {
            var value = SensorReading(timestamp: base.addingTimeInterval(seconds))
            value.point = GeoPoint(latitude: 37.5, longitude: longitude, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5)
            return value
        }
        func moment(_ id: String, _ seconds: TimeInterval, located: Bool = false, screenshot: Bool = false) -> PhotoMoment {
            PhotoMoment(
                id: id, capturedAt: base.addingTimeInterval(seconds), pixelWidth: 10, pixelHeight: 10,
                isFavorite: false, isHiddenFromTimeline: false,
                location: located ? GeoPoint(latitude: 1, longitude: 2, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5) : nil,
                isScreenshot: screenshot ? true : nil
            )
        }
        let readings = [reading(0, longitude: 127.000), reading(600, longitude: 127.010)]
        let placed = MapHomePhotoPolicy.placingUnlocated(
            [moment("near-first", 100, screenshot: true), moment("near-second", 500), moment("own", 100, located: true), moment("far", 5_000)],
            readings: readings
        )
        XCTAssertEqual(placed[0].location?.longitude, 127.000, "가까운 첫 기록의 위치")
        XCTAssertEqual(placed[0].isLocationEstimated, true)
        XCTAssertEqual(placed[0].isScreenshot, true, "스크린샷 표시는 유지")
        XCTAssertEqual(placed[1].location?.longitude, 127.010)
        XCTAssertEqual(placed[2].location?.longitude, 2, "사진 자신의 위치가 있으면 그대로")
        XCTAssertNil(placed[2].isLocationEstimated)
        XCTAssertNil(placed[3].location, "기록이 20분 밖이면 위치를 만들지 않는다")
        XCTAssertEqual(MapHomePhotoPolicy.locatedMoments(placed).count, 3)
    }

    func testPhotoMomentDecodesOlderRecordWithoutScreenshotFields() throws {
        let json = #"{"id":"a","capturedAt":0,"pixelWidth":1,"pixelHeight":1,"isFavorite":false,"isHiddenFromTimeline":false}"#
        let decoded = try JSONDecoder().decode(PhotoMoment.self, from: Data(json.utf8))
        XCTAssertNil(decoded.isScreenshot)
        XCTAssertNil(decoded.isLocationEstimated)
    }

    func testActionMemoTimelessFlagRoundTripsAndOlderRecordsHaveTime() throws {
        let timeless = ActionMemo(occurredAt: Date(timeIntervalSince1970: 1_800_000_000), isTimeless: true, kind: .idea, text: "큐 메모")
        let decoded = try JSONDecoder().decode(ActionMemo.self, from: JSONEncoder().encode(timeless))
        XCTAssertEqual(decoded.isTimeless, true)
        XCTAssertEqual(decoded.text, "큐 메모")
        let older = #"{"id":"00000000-0000-0000-0000-000000000001","kind":"idea","text":"옛 메모","createdAt":0}"#
        let legacy = try JSONDecoder().decode(ActionMemo.self, from: Data(older.utf8))
        XCTAssertNil(legacy.isTimeless, "옛 기록은 시간이 있는 메모")
        XCTAssertNil(legacy.mapPoint)
    }

    func testMemoDisplayModeDefaultsAndTitles() {
        XCTAssertEqual(MapHomeMemoDisplayMode(rawValue: "unknown") ?? .all, .all)
        XCTAssertEqual(MapHomeMemoDisplayMode.allCases.map(\.rawValue), ["all", "located", "hidden"])
        XCTAssertFalse(MapHomeMemoDisplayMode.hidden.koreanTitle.isEmpty)
    }

    func testPlaybackZoomProfileSmoothsSpeedAndFixesRegisteredPlaces() throws {
        let dayStart = Date(timeIntervalSince1970: 1_800_000_000)
        // 위도 37.5°에서 경도 0.001° ≈ 88.3m. 30초마다 한 점.
        let metersPerDegree = 111_320 * cos(37.5 * .pi / 180)
        var longitude = 127.0
        var readings: [SensorReading] = []
        func addPoint(_ seconds: TimeInterval) {
            var value = SensorReading(timestamp: dayStart.addingTimeInterval(seconds))
            value.point = GeoPoint(latitude: 37.5, longitude: longitude, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5)
            readings.append(value)
        }
        // 0~10분 정지, 10~40분 20m/s(72km/h), 40~60분 정지.
        for step in 0...120 {
            let seconds = Double(step) * 30
            if seconds > 600, seconds <= 2_400 { longitude += 20 * 30 / metersPerDegree }
            addPoint(seconds)
        }
        let midPoint = readings[50].point!   // 25분 지점
        let profile = try XCTUnwrap(MapHomePlaybackZoomProfile.build(readings: readings, places: [], dayStart: dayStart, endMinute: 60))
        let base = MapHomePlaybackZoomPolicy.baselineScale
        XCTAssertEqual(try XCTUnwrap(profile.scale(atMinute: 3)), base, accuracy: 0.001, "정지는 85")
        XCTAssertLessThan(try XCTUnwrap(profile.scale(atMinute: 25)), base - 20, "빠를 때 크게 축소")
        // 평탄화: 30초 사이 변화는 상한 이하
        for index in 1..<profile.scales.count {
            XCTAssertLessThanOrEqual(abs(profile.scales[index] - profile.scales[index - 1]), MapHomePlaybackZoomProfile.maximumStepChange + 0.001)
        }
        // 등록 지점이 경로 한가운데에 있으면 그 근처는 85로 고정
        let fixed = try XCTUnwrap(MapHomePlaybackZoomProfile.build(readings: readings, places: [midPoint], dayStart: dayStart, endMinute: 60))
        XCTAssertEqual(try XCTUnwrap(fixed.scale(atMinute: 25)), base, accuracy: 0.001, "등록 지점은 확대 고정")
        XCTAssertLessThan(try XCTUnwrap(fixed.scale(atMinute: 33)), base - 5, "지점에서 멀어지면 다시 속도 비례")
        XCTAssertNil(profile.scale(atMinute: 61), "범위 밖은 nil")
        XCTAssertNil(MapHomePlaybackZoomProfile.build(readings: [], places: [], dayStart: dayStart))
    }

    func testPlaybackZoomPlanUsesProfileOutsideFittedLongHauls() throws {
        let profile = MapHomePlaybackZoomProfile(startMinute: 0, scales: Array(repeating: 50, count: 2_881))
        let plan = MapHomePlaybackZoomPlan(inputs: [
            .init(startMinute: 100, endMinute: 160, mode: .car, speedMetersPerSecond: 15, touchesRegisteredPlace: false, distanceMeters: 30_000, extentMeters: 20_000),
            .init(startMinute: 600, endMinute: 780, mode: .car, speedMetersPerSecond: 27, touchesRegisteredPlace: false, distanceMeters: 290_000, extentMeters: 250_000),
        ], profile: profile)
        XCTAssertEqual(plan.scale(atMinute: 130, speedMetersPerSecond: nil), 50, accuracy: 0.001, "프로파일 값을 쓴다")
        XCTAssertEqual(plan.scale(atMinute: 690, speedMetersPerSecond: nil), plan.scale(atMinute: 690), "경로 전체 맞춤은 계획 그대로")
        XCTAssertEqual(plan.scale(atMinute: 30, speedMetersPerSecond: nil), 50, accuracy: 0.001)
    }

    func testAccessorySymbolFollowsLandmarkPatternAndFallsBack() throws {
        let landmark = try XCTUnwrap(MapHomeLandmarkCatalog.candidates.first)
        XCTAssertEqual(MapHomeGrowthAccessoryCatalog.symbol(for: landmark.accessoryID), landmark.systemImage)
        XCTAssertEqual(MapHomeGrowthAccessoryCatalog.landmark(for: landmark.accessoryID)?.id, landmark.id)
        XCTAssertNil(MapHomeGrowthAccessoryCatalog.landmark(for: "cat.accessory.unknown"))
        XCTAssertNotNil(MapHomeGrowthAccessoryCatalog.symbol(for: "cat.accessory.unknown"), "옛 id는 기본 심볼")
        XCTAssertNil(MapHomeGrowthAccessoryCatalog.symbol(for: nil))
        XCTAssertNil(MapHomeGrowthAccessoryCatalog.symbol(for: ""))
    }

    func testLandPlacementCandidatesAndExplicitPlacement() {
        typealias Policy = MapHomeGrowthPolicy
        var season = MapHomeGrowthSeason(year: 2026)
        season.landPlots = ["a", "b", "c"]
        let first = Policy.placementCandidates(in: season)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].x, 0)
        XCTAssertEqual(first[0].y, 0)
        XCTAssertFalse(Policy.placeLandPlot("a", atX: 3, y: 3, in: &season), "첫 땅은 집 자리(0,0)에만")
        XCTAssertTrue(Policy.placeLandPlot("a", atX: 0, y: 0, in: &season))
        let around = Policy.placementCandidates(in: season)
        XCTAssertEqual(Set(around.map { "\($0.x),\($0.y)" }), ["1,0", "0,1", "-1,0", "0,-1"])
        XCTAssertFalse(Policy.placeLandPlot("b", atX: 1, y: 1, in: &season), "변을 맞대지 않은 칸은 불가")
        XCTAssertTrue(Policy.placeLandPlot("b", atX: 0, y: -1, in: &season))
        XCTAssertFalse(Policy.placeLandPlot("b", atX: 1, y: 0, in: &season), "이미 놓은 땅은 다시 못 놓는다")
        XCTAssertFalse(Policy.placeLandPlot("c", atX: 0, y: -1, in: &season), "이미 차지한 칸은 불가")
        XCTAssertTrue(Policy.placeLandPlot("c", atX: -1, y: -1, in: &season), "새 땅과 변을 맞댄 칸")
        XCTAssertEqual(season.landPlotPlacements?.count, 3)
    }

    func testWeeklyChoicesSkipAlreadyChosenLandmarks() {
        var season = MapHomeGrowthSeason(year: 2026)
        let all = MapHomeLandmarkCatalog.candidates
        XCTAssertEqual(all.count, 52)
        var seen = Set<String>()
        // 한 해 52번 고르면 매번 아직 안 고른 랜드마크만 나오고, 고른 것은 다시 나오지 않는다.
        for _ in 0..<52 {
            let choices = MapHomeLandmarkCatalog.weeklyChoices(for: season)
            XCTAssertFalse(choices.isEmpty)
            XCTAssertTrue(choices.allSatisfy { !seen.contains($0.id) }, "이미 고른 후보가 다시 나왔다")
            let picked = choices[0]
            seen.insert(picked.id)
            season.chosenEvolutions.append(picked.id)
        }
        XCTAssertEqual(seen.count, 52)
        XCTAssertEqual(MapHomeLandmarkCatalog.weeklyChoices(for: season).count, 3, "다 모으면 전체에서 다시 돈다")
    }

    func testMergedStepCountsKeepsTheLargerOfHealthAndSensor() {
        let day1 = Date(timeIntervalSince1970: 1_800_000_000)
        let day2 = day1.addingTimeInterval(86_400)
        let day3 = day2.addingTimeInterval(86_400)
        let merged = MapHomeCalendarTimeTotalsPolicy.mergedStepCounts(
            health: [day1: 8_000, day2: 3_000],
            sensor: [day2: 5_000, day3: 1_200]
        )
        XCTAssertEqual(merged[day1], 8_000, "건강 앱만 있으면 그 값")
        XCTAssertEqual(merged[day2], 5_000, "둘 다 있으면 큰 값(더하지 않는다)")
        XCTAssertEqual(merged[day3], 1_200, "센서만 있으면 그 값")
    }

    func testKoreanNetPayMatchesSalaryCalculatorFor50Million() {
        // 연봉 5,000만 원(부양 1인·식대 20만): 공개 계산기 월 실수령 약 357만 원.
        let b = MapHomeKoreanNetPay.monthly(gross: 50_000_000 / 12)
        XCTAssertEqual(b.pension, 188_417, accuracy: 1)
        XCTAssertEqual(b.employment, 35_700, accuracy: 1)
        XCTAssertEqual(b.net, 3_573_640, accuracy: 2_000)
        XCTAssertEqual(MapHomeKoreanNetPay.monthly(gross: 0).net, 0)
        XCTAssertLessThan(MapHomeKoreanNetPay.monthly(gross: 160_000_000 / 12).net, 160_000_000 / 12 * 0.75, "고연봉은 공제가 커진다")
    }

    func testHourlyInputTaxesHourlyRateAndAddsWeeklyHolidayOnlyFromFifteenHours() {
        typealias P = MapHomeSalaryPolicy
        var settings = P.Settings()
        settings.isHourly = true
        settings.hourly = 10_000
        XCTAssertEqual(P.hourlyRate(settings, monthWorkSeconds: 0, projectedMonthWorkSeconds: 0) ?? 0, 9_670, accuracy: 0.001)
        settings.hourlyTax = .none
        settings.includesWeeklyHoliday = true
        let forty = 40 * 30.4 / 7 * 3_600
        XCTAssertEqual(P.hourlyRate(settings, monthWorkSeconds: 0, projectedMonthWorkSeconds: forty) ?? 0, 12_000, accuracy: 0.5)
        let ten = 10 * 30.4 / 7 * 3_600
        XCTAssertEqual(P.hourlyRate(settings, monthWorkSeconds: 0, projectedMonthWorkSeconds: ten) ?? 0, 10_000, accuracy: 0.5)
        XCTAssertEqual(P.inputMonthly(settings), 0)
    }

    func testSalaryRateUsesMonthlyPayBasisAndEditedAccumulation() throws {
        typealias P = MapHomeSalaryPolicy
        var settings = P.Settings(annualPay: 25_080_000, isNetInput: true)
        // 세후 입력, 예측 근무 없음: 연봉 ÷ 12 ÷ 209.
        XCTAssertEqual(try XCTUnwrap(P.hourlyRate(settings, monthWorkSeconds: 0, projectedMonthWorkSeconds: 0)), 10_000, accuracy: 0.01)
        // 예상 근무 190시간이면 월급 ÷ 190: 덜 일하면 시급이 오른다.
        XCTAssertEqual(try XCTUnwrap(P.hourlyRate(settings, monthWorkSeconds: 100 * 3_600, projectedMonthWorkSeconds: 190 * 3_600)), 2_090_000 / 190, accuracy: 0.01)
        // 월급을 넣으면 연봉 대신 월급.
        settings.monthlyPay = 4_180_000
        XCTAssertEqual(try XCTUnwrap(P.baseHourlyRate(settings)), 20_000, accuracy: 0.01)
        // 누적을 고치면 누적 시급 = 누적 ÷ 근무 시간.
        settings.monthAccumOverride = 1_500_000
        XCTAssertEqual(try XCTUnwrap(P.hourlyRate(settings, monthWorkSeconds: 100 * 3_600, projectedMonthWorkSeconds: 200 * 3_600)), 15_000, accuracy: 0.01)
        XCTAssertEqual(P.accumulated(settings, monthWorkSeconds: 100 * 3_600), 1_500_000)
        // 세전 입력 + 세후 보기는 세후 월급 기준.
        let gross = P.Settings(annualPay: 50_000_000, isNetInput: false, showsNet: true)
        XCTAssertEqual(P.displayedMonthly(gross), MapHomeKoreanNetPay.monthly(gross: 50_000_000 / 12).net, accuracy: 0.01)
        XCTAssertNil(P.hourlyRate(P.Settings(), monthWorkSeconds: 0, projectedMonthWorkSeconds: 0))
    }

    func testSalaryProjectionUsesWeekdayTrendAndMatchesPayAtMonthEnd() throws {
        typealias P = MapHomeSalaryPolicy
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        func d(_ m: Int, _ day: Int, _ h: Int = 12) -> Date { calendar.date(from: DateComponents(year: 2026, month: m, day: day, hour: h))! }
        // 9월·10월 초 평일마다 8시간, 금요일만 6시간 근무.
        var daily: [Date: TimeInterval] = [:]
        var day = d(9, 1, 0)
        while day < d(10, 15, 0) {
            let weekday = calendar.component(.weekday, from: day)
            if (2...6).contains(weekday) { daily[day] = weekday == 6 ? 6 * 3_600 : 8 * 3_600 }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        // 10월 15일(목) 정오, 오늘 4시간 근무 중.
        daily[d(10, 15, 0)] = 4 * 3_600
        let projected = P.projectedMonthWorkSeconds(dailyWork: daily, now: d(10, 15), calendar: calendar)
        // 10월 평일 22일(금 5일): 17×8 + 5×6 = 166시간이 추세 예측.
        XCTAssertEqual(projected / 3_600, 166, accuracy: 0.01)
        // 월말(10월 31일 밤)에는 예측 = 실제 누적이라 월급과 맞아떨어진다.
        var full = daily
        day = d(10, 15, 0)
        while day < d(11, 1, 0) {
            let weekday = calendar.component(.weekday, from: day)
            full[day] = (2...6).contains(weekday) ? 8 * 3_600 : 0
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        let actualSeconds = full.filter { calendar.component(.month, from: $0.key) == 10 }.values.reduce(0, +)
        let endProjected = P.projectedMonthWorkSeconds(dailyWork: full, now: d(10, 31, 23), calendar: calendar)
        XCTAssertEqual(endProjected, actualSeconds, accuracy: 1)
        let settings = P.Settings(annualPay: 0, isNetInput: true, monthlyPay: 3_000_000)
        let rate = try XCTUnwrap(P.hourlyRate(settings, monthWorkSeconds: actualSeconds, projectedMonthWorkSeconds: endProjected))
        XCTAssertEqual(P.earnings(workSeconds: actualSeconds, hourlyRate: rate), 3_000_000, accuracy: 0.01)
    }

    func testSalaryLiveSecondsAddElapsedOnlyWhileWorkingInTickSteps() {
        typealias P = MapHomeSalaryPolicy
        let base = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(P.liveWorkSeconds(base: 3_600, baseDate: base, isWorking: true, now: base + 25, tick: 10), 3_620)
        XCTAssertEqual(P.liveWorkSeconds(base: 3_600, baseDate: base, isWorking: false, now: base + 25, tick: 10), 3_600)
        XCTAssertEqual(P.earnings(workSeconds: 36, hourlyRate: 10_000), 100, accuracy: 0.001)
        XCTAssertTrue(P.isWorking(workNow: 3_660, workMinuteAgo: 3_600))
        XCTAssertFalse(P.isWorking(workNow: 3_600, workMinuteAgo: 3_600))
    }

    func testSalaryMonthSummaryCountsCommuteOnlyOnWorkDays() throws {
        let day1 = Date(timeIntervalSince1970: 0), day2 = Date(timeIntervalSince1970: 86_400)
        let summary = MapHomeSalaryPolicy.monthSummary(
            totals: [
                day1: ["work": 8 * 3_600, "movement": 2 * 3_600],
                day2: ["movement": 3 * 3_600],
            ],
            hourlyRate: 10_000
        )
        XCTAssertEqual(summary.workSeconds, 8 * 3_600)
        XCTAssertEqual(summary.commuteSeconds, 2 * 3_600, "근무 없는 날 이동은 출퇴근으로 세지 않는다")
        XCTAssertEqual(summary.earnings, 80_000, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(summary.effectiveHourlyRate), 8_000, accuracy: 0.01)
    }

    func testSalaryPlaybackCountsOnlyWorkSpansUntilPlaybackTimeInTicks() {
        typealias P = MapHomeSalaryPolicy
        let day = Date(timeIntervalSince1970: 0)
        let spans = [
            TimeSpan(start: day + 9 * 3_600, end: day + 12 * 3_600),
            TimeSpan(start: day + 13 * 3_600, end: day + 18 * 3_600),
        ]
        XCTAssertEqual(P.workSeconds(in: spans, until: day + 8 * 3_600), 0, "출근 전에는 0")
        XCTAssertEqual(P.workSeconds(in: spans, until: day + 12.5 * 3_600), 3 * 3_600, "점심시간에는 늘지 않는다")
        XCTAssertEqual(P.workSeconds(in: spans, until: day + 14 * 3_600), 4 * 3_600)
        XCTAssertEqual(P.workSeconds(in: spans, until: .distantFuture), 8 * 3_600)
        XCTAssertEqual(P.quantized(125, tick: 60), 120)
        XCTAssertEqual(P.quantized(125, tick: 1), 125)
    }

    func testSalaryPayModelLearnsOvertimeFromReceivedPayAndStaysExactAtMonthEnd() throws {
        typealias P = MapHomeSalaryPolicy
        let base = 3_000_000.0
        // 기록 없음: 고정 = 기본 월급, 수당 = 통상시급 × 1.5.
        let none = P.fitPayModel(baseMonthly: base, samples: [])
        XCTAssertEqual(none.fixedMonthly, base)
        XCTAssertEqual(none.overtimeHourly, base / 209 * 1.5, accuracy: 0.01)
        XCTAssertEqual(none.sampleCount, 0)
        // 두 달 기록: 209h → 300만, 249h → 380만이면 수당 시급 2만, 고정 300만.
        let model = P.fitPayModel(baseMonthly: base, samples: [.init(hours: 209, pay: 3_000_000), .init(hours: 249, pay: 3_800_000)])
        XCTAssertEqual(model.overtimeHourly, 20_000, accuracy: 0.01)
        XCTAssertEqual(model.fixedMonthly, 3_000_000, accuracy: 1)
        XCTAssertEqual(model.sampleCount, 2)
        // 수당 모델로 본 월급: 229h → 300만 + 20h × 2만 = 340만, 209h 미만은 고정분.
        XCTAssertEqual(P.expectedMonthlyPay(model, workHours: 229), 3_400_000, accuracy: 0.01)
        XCTAssertEqual(P.expectedMonthlyPay(model, workHours: 180), 3_000_000, accuracy: 0.01)
        // 근무 시간이 모자란 달(20h 미만)은 무시, 이상값은 묶인다.
        let noisy = P.fitPayModel(baseMonthly: base, samples: [.init(hours: 5, pay: 9_000_000), .init(hours: 300, pay: 90_000_000)])
        XCTAssertEqual(noisy.sampleCount, 1)
        XCTAssertLessThanOrEqual(noisy.overtimeHourly, base / 209 * 3 + 0.01)
        // 세후 입력 기준, 예상 249h인 달: 시급 = 380만 ÷ 249h. 월말(실제 249h) 누적 = 380만.
        let settings = P.Settings(annualPay: 0, isNetInput: true, monthlyPay: base)
        let samples = [P.PaySample(hours: 209, pay: 3_000_000), P.PaySample(hours: 249, pay: 3_800_000)]
        let rate = try XCTUnwrap(P.hourlyRate(settings, monthWorkSeconds: 249 * 3_600, projectedMonthWorkSeconds: 249 * 3_600, samples: samples))
        XCTAssertEqual(rate, 3_800_000 / 249, accuracy: 0.01)
        XCTAssertEqual(P.earnings(workSeconds: 249 * 3_600, hourlyRate: rate), 3_800_000, accuracy: 0.01)
        // 월 중간: 지금까지 100h, 예상 249h면 시급은 같고 누적은 그 비율.
        let midRate = try XCTUnwrap(P.hourlyRate(settings, monthWorkSeconds: 100 * 3_600, projectedMonthWorkSeconds: 249 * 3_600, samples: samples))
        XCTAssertEqual(midRate, rate, accuracy: 0.01)
        // JSON 저장은 0원 달을 버린다.
        let decoded = P.decodePayHistory(P.encodePayHistory(["2026-09": 2_900_000, "2026-08": 0]))
        XCTAssertEqual(decoded, ["2026-09": 2_900_000])
    }

    func testSalaryProjectionWithoutHistoryUsesStandardMonthNotTheDaysSoFar() {
        typealias P = MapHomeSalaryPolicy
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        // 기록 없이 오늘(10월 21일 수요일)까지 9시간만 일한 경우: 예상은 월 소정근로 209시간이어야 한다.
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 21))!
        let today = calendar.startOfDay(for: now)
        let projected = P.projectedMonthWorkSeconds(dailyWork: [today: 9 * 3_600], now: now, calendar: calendar)
        XCTAssertEqual(projected / 3_600, 209, accuracy: 0.5)
    }

    func testPlaceZoneHysteresisKeepsPreviousStateInsideBand() {
        typealias Z = MapHomePlaceZone
        let radius = 100.0
        // 85m 안쪽은 안, 115m 바깥쪽은 밖, 사이(85~115m)는 이전 상태 유지.
        XCTAssertEqual(Z.next(distance: 80, radius: radius, previous: .outside), .inside)
        XCTAssertEqual(Z.next(distance: 120, radius: radius, previous: .inside), .outside)
        XCTAssertEqual(Z.next(distance: 100, radius: radius, previous: .inside), .inside, "경계 흔들림은 상태를 바꾸지 않는다")
        XCTAssertEqual(Z.next(distance: 100, radius: radius, previous: .outside), .outside)
    }

    func testPlaceZoneTransitionsIgnoreJitterAtBoundary() {
        typealias Z = MapHomePlaceZone
        let start = Date(timeIntervalSince1970: 0)
        // 안 → 경계에서 흔들림(95~105m) → 밖(130m) → 다시 안(70m).
        let samples: [(date: Date, distance: Double)] = [
            (start, 70), (start.addingTimeInterval(60), 98), (start.addingTimeInterval(120), 104),
            (start.addingTimeInterval(180), 96), (start.addingTimeInterval(240), 130),
            (start.addingTimeInterval(300), 110), (start.addingTimeInterval(360), 70),
        ]
        let changes = Z.transitions(samples: samples, radius: 100)
        XCTAssertEqual(changes.map(\.state), [.inside, .outside, .inside])
        XCTAssertEqual(changes.first?.date, start)
        XCTAssertEqual(changes[1].date, start.addingTimeInterval(240))
    }

    func testPlaceZoneArrivalNeedsDwellAndDepartureNeedsMovement() {
        typealias Z = MapHomePlaceZone
        let t0 = Date(timeIntervalSince1970: 0)
        func at(_ minutes: Double, _ distance: Double, moving: Bool = false) -> Z.Sample {
            Z.Sample(date: t0.addingTimeInterval(minutes * 60), distance: distance, isMoving: moving)
        }
        // 잠깐 들렀다 나간 경우(머무름 없음) → 도착 없음.
        let brief = [at(0, 500), at(1, 40), at(2, 40), at(3, 500, moving: true)]
        XCTAssertFalse(Z.events(samples: brief, radius: 100).contains { if case .arrived = $0 { return true } else { return false } })
        // 들어와서 6분 머무름 → 도착 확정.
        let stay = [at(0, 500), at(1, 40), at(4, 40), at(7, 40)]
        XCTAssertTrue(Z.events(samples: stay, radius: 100).contains { if case .arrived = $0 { return true } else { return false } })
        // 나갔지만 가만히 있음(걸어 나가지 않음) → 출발 없음.
        let stillOut = [at(0, 40), at(1, 40), at(2, 300), at(5, 300)]
        XCTAssertFalse(Z.events(samples: stillOut, radius: 100).contains { if case .departed = $0 { return true } else { return false } })
        // 나가서 움직임 → 출발 확정.
        let leaving = [at(0, 40), at(1, 40), at(2, 300, moving: true), at(5, 400, moving: true)]
        XCTAssertTrue(Z.events(samples: leaving, radius: 100).contains { if case .departed = $0 { return true } else { return false } })
    }
}
