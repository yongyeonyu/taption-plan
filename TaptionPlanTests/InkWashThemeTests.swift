import SwiftUI
import XCTest
@testable import TaptionPlan

/// INK1108A01: 수묵 테마·도장·장소 도감.
final class InkWashThemeTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_762_560_000) // 2025-11-08 00:00 UTC 근처
    private var dayEnd: Date { day.addingTimeInterval(86_400) }

    private func point(_ lat: Double, _ lon: Double) -> GeoPoint {
        GeoPoint(latitude: lat, longitude: lon, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1)
    }

    private func stay(_ key: String, start: TimeInterval, minutes: Double = 30, at point: GeoPoint? = nil) -> PlaceStay {
        let begin = day.addingTimeInterval(start)
        return PlaceStay(
            placeKey: key, displayName: key,
            span: TimeSpan(start: begin, end: begin.addingTimeInterval(minutes * 60)),
            confidence: .high, point: point
        )
    }

    // MARK: - 도장 판정

    func testArrivalAtRegisteredPlaceStampsItForThatDay() {
        let company = FrequentPlace(kind: .company, name: "본사", point: point(37.5, 127.0))
        let stays = [stay(company.stablePlaceKey, start: 9 * 3_600)]
        let keys = MapHomePlaceStampPolicy.stampedKeys(stays: stays, dayStart: day, dayEnd: dayEnd)
        XCTAssertEqual(MapHomePlaceStampPolicy.mark(for: company, stampedKeys: keys), MapHomePlaceStampMark(glyph: "社", isStamped: true))
    }

    func testNoStayMeansNoStampAndOtherDaysDoNotCount() {
        let home = FrequentPlace(kind: .home, point: point(37.5, 127.0))
        let gym = FrequentPlace(kind: .exercise, name: "동네 체육관", point: point(37.51, 127.01))
        // 집은 전날에만, 체육관은 기록이 없다. 일반 장소 키는 등록 장소를 찍지 않는다.
        let stays = [
            stay(home.stablePlaceKey, start: -5 * 3_600),
            stay("place-37.500-127.000", start: 10 * 3_600),
        ]
        let keys = MapHomePlaceStampPolicy.stampedKeys(stays: stays, dayStart: day, dayEnd: dayEnd)
        XCTAssertFalse(MapHomePlaceStampPolicy.mark(for: home, stampedKeys: keys).isStamped)
        XCTAssertEqual(MapHomePlaceStampPolicy.mark(for: gym, stampedKeys: keys), MapHomePlaceStampMark(glyph: "동", isStamped: false))
    }

    func testOngoingStayCrossingMidnightStampsBothDays() {
        let home = FrequentPlace(kind: .home, point: point(37.5, 127.0))
        let stays = [stay(home.stablePlaceKey, start: -2 * 3_600, minutes: 10 * 60)]
        XCTAssertTrue(MapHomePlaceStampPolicy.stampedKeys(stays: stays, dayStart: day, dayEnd: dayEnd).contains(home.stablePlaceKey))
    }

    func testGlyphFollowsPlaceKind() {
        XCTAssertEqual(MapHomePlaceStampPolicy.glyph(kind: .home, name: "우리집"), "家")
        XCTAssertEqual(MapHomePlaceStampPolicy.glyph(kind: .company, name: "회사"), "社")
        XCTAssertEqual(MapHomePlaceStampPolicy.glyph(kind: .school, name: "학교"), "學")
        XCTAssertEqual(MapHomePlaceStampPolicy.glyph(kind: .restaurant, name: "김밥집"), "食")
        XCTAssertEqual(MapHomePlaceStampPolicy.glyph(kind: .custom, name: "  서점"), "서")
        XCTAssertEqual(MapHomePlaceStampPolicy.glyph(kind: .hobby, name: ""), "印")
    }

    func testFirstArrivalIsEarliestStay() {
        let key = "frequent-a"
        let stays = [stay(key, start: 5 * 3_600), stay(key, start: 3_600), stay("other", start: 0)]
        let first = MapHomePlaceStampPolicy.firstArrivals(stays: stays, keys: [key])
        XCTAssertEqual(first, [key: day.addingTimeInterval(3_600)])
    }

    // MARK: - 장소 도감

    /// 국내 도감 자료: 17개 시·도와 해외 직항 도시, id 중복 없음, 국내 좌표 범위, 기존 7곳 id 유지(PLB1109A01).
    func testKoreaPlaceBookData() {
        let places = MapHomeKoreaPlaceBookData.places
        let regions = Set(MapHomeKoreaPlaceBookData.regions.map(\.id))
        XCTAssertEqual(regions.count, 17)
        XCTAssertEqual(Set(places.map(\.id)).count, places.count)
        XCTAssertEqual(Set(places.compactMap { $0.countryCode == nil ? $0.region : nil }), regions, "모든 시·도에 명소가 있다")
        XCTAssertEqual(Set(places.compactMap(\.theme)), Set(MapHomeKoreaPlaceBookData.themes.map(\.id)), "모든 종류에 명소가 있다")
        for place in places {
            XCTAssertNotNil(UIImage(named: place.artworkName), "그림 없음: \(place.id)")
            if place.region == "abroad" {
                XCTAssertNotNil(place.countryCode, place.id)
                XCTAssertEqual(place.kind, .city, place.id)
                XCTAssertFalse(place.airports.isEmpty, "공항 좌표 없음: \(place.id)")
            } else {
                XCTAssertTrue(place.id.hasPrefix("kr."), place.id)
                XCTAssertTrue((33...39).contains(place.latitude) && (124...132).contains(place.longitude), place.id)
            }
        }
        let ids = Set(places.map(\.id))
        for kept in MapHomeLandmarkCatalog.candidates.map(\.id) where kept.hasPrefix("kr.") {
            XCTAssertTrue(ids.contains(kept), "도장이 이어지게 기존 id를 유지한다: \(kept)")
        }
    }

    /// 한 줄 메뉴: 1차 나라, 2차 지역별·종류별, 3차 목록과 위로가기(PLB1109A01).
    /// 기록 간격 메뉴를 없앴으니 옛 저장 값·백업의 값은 고정값으로 읽는다(VER1109A01).
    func testStoredCustomGPSIntervalLoadsAsFixedValue() throws {
        var stored = AppFeatureSettings.defaults
        stored.gpsLoggingPreferences = GPSLoggingPreferences(intervalSeconds: 60)
        stored.sensorCollectionProfile = .accuracy
        let restored = try JSONDecoder().decode(AppFeatureSettings.self, from: JSONEncoder().encode(stored))
        XCTAssertEqual(restored.gpsLoggingPreferences.intervalSeconds, 300)
        XCTAssertEqual(restored.sensorCollectionProfile, .balanced)
    }

    func testStationaryGPSHeldOnlyWhileStayingAndFixedEveryTenMinutes() {
        let now = day
        let recent = now.addingTimeInterval(-5 * 60), old = now.addingTimeInterval(-11 * 60)
        XCTAssertFalse(StationaryGPSPolicy.requestsFix(stayRegionArmed: true, keepsStreamsActive: false, lastFixAt: recent, now: now))
        XCTAssertTrue(StationaryGPSPolicy.requestsFix(stayRegionArmed: true, keepsStreamsActive: false, lastFixAt: old, now: now), "10분마다 실측")
        XCTAssertTrue(StationaryGPSPolicy.requestsFix(stayRegionArmed: false, keepsStreamsActive: false, lastFixAt: recent, now: now), "머문 근거가 없으면 잰다")
        XCTAssertTrue(StationaryGPSPolicy.requestsFix(stayRegionArmed: true, keepsStreamsActive: true, lastFixAt: recent, now: now), "이동 추적 중")
        XCTAssertTrue(StationaryGPSPolicy.requestsFix(stayRegionArmed: true, keepsStreamsActive: false, lastFixAt: nil, now: now))
        XCTAssertTrue(StationaryGPSPolicy.wakesGPS(for: .walking))
        XCTAssertTrue(StationaryGPSPolicy.wakesGPS(for: .automotive))
        XCTAssertFalse(StationaryGPSPolicy.wakesGPS(for: .stationary))
    }

    /// GPS를 드물게 재도 긴 머묾이 하나로 남는다.
    func testSparseStayFixesStillDetectOneStay() {
        let every30 = (0...6).map { step in
            SensorReading(timestamp: day.addingTimeInterval(Double(step) * 1_800), point: point(37.5, 127))
        }
        let stays = PlaceDetectionEngine().detectStays(readings: every30)
        XCTAssertEqual(stays.count, 1)
        XCTAssertEqual(stays.first?.span.duration ?? 0, 3 * 3_600, accuracy: 1)
    }

    // MARK: - 임의 GPS로 도장 판정(VER1109A01)

    private func dwell(_ lat: Double, _ lon: Double, minutes: Int, accuracy: Double = 8, from minute: Int = 0) -> [SensorReading] {
        (0...(minutes * 2)).map { step in
            let jitter = step.isMultiple(of: 2) ? 0.00005 : -0.00005
            return SensorReading(
                timestamp: day.addingTimeInterval(Double(minute * 60 + step * 30)),
                point: GeoPoint(latitude: lat + jitter, longitude: lon - jitter, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5)
            )
        }
    }

    private func isStamped(_ id: String, in selection: String, readings: [SensorReading]) throws -> Bool {
        let stays = PlaceDetectionEngine().detectStays(readings: readings)
        let state = MapHomePlaceBookState.make(stays: stays, language: .korean, region: selection)
        return try XCTUnwrap(state.landmarks.first { $0.id == id }, id).isVisited
    }

    private func bookPlace(_ id: String) throws -> MapHomeKoreaPlace {
        try XCTUnwrap(MapHomeKoreaPlaceBookData.places.first { $0.id == id }, id)
    }

    func testSyntheticGPSDwellStampsOnlyRealVisits() throws {
        let tree = try bookPlace("kr.bangyeri_ginkgo")
        XCTAssertTrue(try isStamped(tree.id, in: "gangwon", readings: dwell(tree.latitude, tree.longitude, minutes: 20)), "20분 머묾")
        XCTAssertFalse(try isStamped(tree.id, in: "gangwon", readings: dwell(tree.latitude, tree.longitude, minutes: 10)), "감지 기준 15분 미만")
        XCTAssertFalse(try isStamped(tree.id, in: "gangwon", readings: dwell(tree.latitude + 0.01, tree.longitude, minutes: 30)), "약 1.1km 밖")
        XCTAssertFalse(try isStamped(tree.id, in: "gangwon", readings: dwell(tree.latitude, tree.longitude, minutes: 30, accuracy: 500)), "셀룰러 위치는 머묾이 아니다")
    }

    func testSyntheticGPSStampsCityAtEveryDirectAirport() throws {
        let tokyo = try bookPlace("intl.jp.tokyo")
        XCTAssertEqual(tokyo.airports.count, 2)
        for airport in tokyo.airports {
            XCTAssertTrue(try isStamped(tokyo.id, in: "jp", readings: dwell(airport.latitude, airport.longitude, minutes: 40)), airport.name)
        }
        XCTAssertTrue(try isStamped(tokyo.id, in: "jp", readings: dwell(tokyo.latitude + 0.05, tokyo.longitude, minutes: 40)), "시내 숙소")
        XCTAssertFalse(try isStamped(tokyo.id, in: "jp", readings: dwell(37.5665, 126.9780, minutes: 40)), "서울에 있으면 도쿄가 아니다")
    }

    func testEveryPlaceBookPlaceStampsAtItsOwnCenter() {
        for place in MapHomeKoreaPlaceBookData.places {
            let visit = stay("gps", start: 0, at: point(place.latitude, place.longitude))
            XCTAssertNotNil(place.firstVisit(in: [visit]), place.id)
        }
    }

    /// 드라이브길은 멈추지 않고 달려도 찍히고, 머묾 판정이 필요한 다른 명소는 지나가기만 하면 찍히지 않는다.
    func testSyntheticGPSDriveThroughStampsDriveRoadsOnly() throws {
        let road = try bookPlace("kr.heonhwaro")
        let readings = (0...40).map { step in
            SensorReading(
                timestamp: day.addingTimeInterval(Double(step * 30)),
                point: GeoPoint(latitude: road.latitude + Double(step - 20) * 0.0045, longitude: road.longitude, altitude: 0, horizontalAccuracy: 8, verticalAccuracy: 5)
            )
        }
        XCTAssertFalse(try isStamped(road.id, in: "drive", readings: readings), "머묾은 없다")
        var passes: [String: Date] = [:]
        MapHomePlaceBookDrivePass.merge(readings: readings, into: &passes)
        XCTAssertNotNil(passes[road.id])
        XCTAssertNil(passes["kr.gyeongbokgung"], "드라이브길이 아니면 통과로 찍지 않는다")
        let state = MapHomePlaceBookState.make(stays: [], language: .korean, region: "drive", drivePasses: passes)
        XCTAssertEqual(state.landmarks.first { $0.id == road.id }?.isVisited, true)

        let cellular = readings.map { reading -> SensorReading in
            var copy = reading
            copy.point?.horizontalAccuracy = 800
            return copy
        }
        var none: [String: Date] = [:]
        MapHomePlaceBookDrivePass.merge(readings: cellular, into: &none)
        XCTAssertTrue(none.isEmpty, "셀룰러 위치로는 찍지 않는다")
    }

    /// 직항 공항이 둘 이상인 도시는 모두 담고, 어느 공항에 머물러도 도장이 찍힌다(PLB1109A01).
    func testPlaceBookCityIncludesEveryDirectAirport() throws {
        let tokyo = try XCTUnwrap(MapHomeKoreaPlaceBookData.places.first { $0.id == "intl.jp.tokyo" })
        XCTAssertEqual(tokyo.airports.count, 2)
        XCTAssertEqual(tokyo.pins(language: .korean).count, 2)
        let narita = try XCTUnwrap(tokyo.airports.first)
        let stay = MapHomeLandmarkSite(latitude: narita.latitude, longitude: narita.longitude, radiusMeters: 3_000)
        XCTAssertTrue(stay.contains(GeoPoint(latitude: narita.latitude + 0.005, longitude: narita.longitude, altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1)))
    }

    func testPassportStampDateIsEnglishDayMonthYearAndCountryStyled() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!
        XCTAssertEqual(MapHomePassportStampStyle.dateText(date, calendar: calendar), "09 NOV 2026")
        XCTAssertEqual(MapHomePassportStampStyle.style(forCountry: "CN").shape, .oval)
        XCTAssertEqual(MapHomePassportStampStyle.style(forCountry: "fr").shape, .roundedRectangle)
        XCTAssertEqual(MapHomePassportStampStyle.style(forCountry: "kr").shape, .circle)
        XCTAssertEqual(MapHomePassportStampStyle.style(forCountry: "th").colorHex, "#B8404A")
        XCTAssertEqual(MapHomePassportStampStyle.style(forCountry: "zz"), .standard)
    }

    func testPassportStampsCoverAirportsAndOverseasCitiesOnly() throws {
        XCTAssertTrue(try bookPlace("kr.airport_gmp").usesPassportStamp)
        XCTAssertTrue(try bookPlace("kr.airport").usesPassportStamp)
        XCTAssertTrue(try bookPlace("intl.jp.tokyo").usesPassportStamp)
        XCTAssertFalse(try bookPlace("kr.gyeongbokgung").usesPassportStamp)
        XCTAssertEqual(MapHomeKoreaPlaceBookData.places.filter { $0.theme == "airport" }.count, 6)
    }

    @MainActor
    func testPlaceBookTestVisitIsReversibleAndSeparateFromRecords() {
        MapHomePlaceBookTestMode.visits = [:]
        MapHomePlaceBookTestMode.toggleVisit("kr.namsan", now: day)
        let state = MapHomePlaceBookState.make(stays: [], language: .korean, drivePasses: MapHomePlaceBookTestMode.visits)
        XCTAssertEqual(state.landmarks.first { $0.id == "kr.namsan" }?.firstVisit, day)
        MapHomePlaceBookTestMode.toggleVisit("kr.namsan", now: day)
        XCTAssertTrue(MapHomePlaceBookTestMode.visits.isEmpty)
    }

    func testPlaceRequestWritesRequestedJSON() throws {
        let request = MapHomePlaceRequest(name: "새 명소", memo: "설명", latitude: 37.5, longitude: 127, requestedAt: day, appBuild: "305")
        let url = try request.writeJSON()
        defer { try? FileManager.default.removeItem(at: url) }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["name"] as? String, "새 명소")
        XCTAssertEqual(object["memo"] as? String, "설명")
        XCTAssertEqual(object["latitude"] as? Double, 37.5)
    }

    func testTravelPlanOrdersAndMovesStopsWithinADay() throws {
        let a = TravelPlanStop(id: UUID(), title: "A", latitude: 1, longitude: 1, day: day, order: 0, planID: nil)
        let b = TravelPlanStop(id: UUID(), title: "B", latitude: 2, longitude: 2, day: day, order: 1, planID: nil)
        let moved = TravelPlanSchedule.moved([a, b], id: b.id, by: -1)
        XCTAssertEqual(TravelPlanSchedule.stops(on: day, in: moved).map(\.title), ["B", "A"])
        XCTAssertEqual(TravelPlanSchedule.moved([a, b], id: a.id, by: -1), [a, b], "맨 앞에서 위로는 그대로")
        XCTAssertEqual(TravelPlanSchedule.renumbered([b]).first?.order, 0)
    }

    /// 옛 저장본에는 여행 일정이 없어도 읽히고, 저장한 일정은 그대로 돌아온다.
    func testTravelPlanStopsRoundTripAndOldSettingsDecode() throws {
        var settings = AppFeatureSettings.defaults
        let stop = TravelPlanStop(id: UUID(), title: "도쿄", latitude: 35, longitude: 139, day: day, order: 0, planID: nil)
        settings.travelPlanStops = [stop]
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppFeatureSettings.self, from: data).travelPlanStops, [stop])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["travelPlanStops"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try JSONDecoder().decode(AppFeatureSettings.self, from: old).travelPlanStops, [])
    }

    func testPlaceBookMenuHierarchy() {
        var menu = MapHomePlaceBookMenu()
        XCTAssertEqual(menu.selected, "seoul")
        XCTAssertTrue(menu.showsKoreaRows)
        XCTAssertEqual(menu.browseItems.map(\.id), ["by-region", "by-theme"])
        XCTAssertEqual(menu.listItems.count, 17)
        menu.selectBrowse("by-theme")
        XCTAssertEqual(menu.selected, "landmark")
        menu.selectList("temple")
        XCTAssertEqual(menu.selected, "temple")
        XCTAssertTrue(MapHomePlaceBookState.places(in: "temple").contains { $0.id == "kr.bulguksa" })
        menu.country = "jp"
        XCTAssertEqual(menu.selected, "jp", "다른 나라는 그 나라 직항 도시만")
        XCTAssertFalse(menu.showsKoreaRows)
        XCTAssertTrue(MapHomePlaceBookState.places(in: "jp").allSatisfy { $0.id.hasPrefix("intl.jp.") })
        menu.country = "kr"
        XCTAssertEqual(menu.selected, "temple", "한국으로 돌아오면 고르던 곳 그대로")
        menu.selectBrowse("by-region")
        XCTAssertEqual(menu.selected, "seoul")
        XCTAssertEqual(menu.countryItems.first?.id, "kr")
    }

    func testPlaceBookCountsVisitedAndRemaining() throws {
        let tower = try XCTUnwrap(MapHomeLandmarkSites.site(for: "kr.namsan"))
        let stays = [
            // 남산 서울타워 반경 안의 일반 머묾.
            stay("place-namsan", start: 4 * 3_600, at: point(tower.latitude + 0.001, tower.longitude)),
            // 경복궁에서 5 km 떨어진 곳은 세지 않는다.
            stay("place-far", start: 6 * 3_600, at: point(37.6250, 126.9770)),
        ]
        let state = MapHomePlaceBookState.make(stays: stays, language: .korean)
        let seoul = MapHomePlaceBookState.places(in: "seoul")
        XCTAssertEqual(state.landmarks.map(\.id), seoul.map(\.id), "처음은 서울, 등록한 곳은 없다")
        XCTAssertEqual(state.stampedCount + state.remainingCount, state.entries.count)
        XCTAssertGreaterThanOrEqual(seoul.count, 40)
        let jeju = MapHomePlaceBookState.make(stays: stays, language: .korean, region: "jeju")
        XCTAssertTrue(jeju.landmarks.contains { $0.id == "kr.hallasan" })
        XCTAssertEqual(jeju.stampedCount, 0, "서울 명소 도장은 제주 수에 넣지 않는다")
        let japan = MapHomePlaceBookState.make(stays: stays, language: .korean, region: "jp")
        XCTAssertTrue(japan.landmarks.allSatisfy { $0.id.hasPrefix("intl.jp.") })
        XCTAssertTrue(try XCTUnwrap(state.landmarks.first { $0.id == "kr.namsan" }).isVisited)
        XCTAssertFalse(try XCTUnwrap(state.landmarks.first { $0.id == "kr.gyeongbokgung" }).isVisited)
    }

    func testEveryLandmarkHasSiteAndArtwork() {
        for candidate in MapHomeLandmarkCatalog.candidates {
            let site = MapHomeLandmarkSites.site(for: candidate.id)
            XCTAssertNotNil(site, candidate.id)
            XCTAssertNotNil(UIImage(named: candidate.artworkName), candidate.artworkName)
            if let site {
                XCTAssertTrue((-90...90).contains(site.latitude) && (-180...180).contains(site.longitude), candidate.id)
                XCTAssertTrue([500, 2_000, 5_000].contains(site.radiusMeters), candidate.id)
            }
        }
        XCTAssertEqual(MapHomeLandmarkSites.table.count, MapHomeLandmarkCatalog.candidates.count)
    }

    // MARK: - 테마

    func testInkThemeFollowsInkMapAndStaysLight() {
        XCTAssertEqual(TaptionUITheme.forMap(.mapLibreInk), .ink)
        XCTAssertFalse(TaptionUITheme.ink.isDark)
        XCTAssertEqual(TaptionUITheme.ink.colorScheme, .light)
        XCTAssertEqual(MapDisplayStyle.mapLibreInk.provider, .openFreeMap)
        XCTAssertTrue(MapDisplayStyle.openFreeMapStyles.contains(.mapLibreInk))
    }

    func testInkPaletteContrast() {
        let hexes = MapHomeInkWash.uiHexes
        let (background, surface, accent, secondary, ink) = (hexes[0], hexes[1], hexes[3], hexes[4], hexes[5])
        XCTAssertGreaterThanOrEqual(Self.contrast(ink, background), 7, "먹 글자 / 한지")
        XCTAssertGreaterThanOrEqual(Self.contrast(secondary, background), 5.3, "보조 글자 / 한지")
        XCTAssertGreaterThanOrEqual(Self.contrast("#FFFFFF", accent), 4.5, "흰 글자 / 인주")
        XCTAssertGreaterThanOrEqual(Self.contrast(accent, surface), 3, "인주 / 면")
        XCTAssertEqual(MapHomeInkWash.sealHex, accent)
        XCTAssertGreaterThanOrEqual(Self.contrast(MapHomeInkWash.Map.labels.place, MapHomeInkWash.Map.labels.halo), 7)
    }

    func testDecodingUnknownFutureStyleStillFallsBack() throws {
        let encoded = try JSONEncoder().encode(MapDisplayStyle.mapLibreInk)
        XCTAssertEqual(try JSONDecoder().decode(MapDisplayStyle.self, from: encoded), .mapLibreInk)
        // 예전 빌드는 모르는 값을 애플맵으로 읽는다(같은 디코더 규칙).
        XCTAssertEqual(try JSONDecoder().decode(MapDisplayStyle.self, from: Data(#""mapLibreFuture""#.utf8)), .standard)
    }

    // MARK: - 지도 스타일

    func testInkStyleJSONLoadsWithPaperWaterAndMutedIcons() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(MapHomeVectorStyle.ink.json.utf8)) as? [String: Any])
        let layers = try XCTUnwrap(object["layers"] as? [[String: Any]])
        func paint(_ id: String) -> [String: Any]? { layers.first { $0["id"] as? String == id }?["paint"] as? [String: Any] }
        XCTAssertEqual(paint("background")?["background-color"] as? String, MapHomeInkWash.Map.paper)
        XCTAssertEqual(paint("water")?["fill-color"] as? String, MapHomeInkWash.Map.water)
        XCTAssertEqual(paint("ink-coastline")?["line-color"] as? String, MapHomeInkWash.Map.waterLine)
        XCTAssertEqual(paint("ink-road-major")?["line-color"] as? String, MapHomeInkWash.Map.ink)
        XCTAssertEqual(paint("label-poi")?["icon-opacity"] as? Double, MapHomeInkWash.Map.iconOpacity)
        // 다른 스타일의 아이콘은 그대로다.
        let rpg = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(MapHomeVectorStyle.rpg.json.utf8)) as? [String: Any])
        let rpgPOI = (rpg["layers"] as? [[String: Any]])?.first { $0["id"] as? String == "label-poi" }?["paint"] as? [String: Any]
        XCTAssertNil(rpgPOI?["icon-opacity"])
    }

    func testInkBarPaletteKeepsTravelMapMidTones() {
        let palette = TravelMapPalette.make(bar: TaptionBarPalette(MapHomeInkWash.barHexes), isDark: false)
        let water = TravelMapPalette.lightness(palette.water), land = TravelMapPalette.lightness(palette.land)
        XCTAssertTrue((25...85).contains(water), "water \(water)")
        XCTAssertTrue((25...85).contains(land), "land \(land)")
    }

    private static func luminance(_ hex: String) -> Double {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        func channel(_ shift: UInt64) -> Double {
            let c = Double(value >> shift & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private static func contrast(_ a: String, _ b: String) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
