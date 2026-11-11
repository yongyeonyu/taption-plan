import CoreLocation
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
    /// PBD1111A01: 모든 도감 장소에 한·영 설명이 있고, 설명 없는 항목은 빈 글이다.
    func testPlaceBookDescriptionsCoverEveryPlace() {
        let places = MapHomeKoreaPlaceBookData.places
        XCTAssertEqual(MapHomePlaceBookDescriptions.items.count, places.count)
        XCTAssertEqual(Set(MapHomePlaceBookDescriptions.items.map(\.id)), Set(places.map(\.id)))
        let hangul = try! NSRegularExpression(pattern: "[가-힣]")
        func hasHangul(_ text: String) -> Bool {
            hangul.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        for item in MapHomePlaceBookDescriptions.items {
            XCTAssertTrue(hasHangul(item.ko) && item.ko.count >= 20, item.id)
            XCTAssertFalse(hasHangul(item.english) || item.english.count < 30, item.id)
        }
        XCTAssertEqual(Set(MapHomePlaceBookDescriptions.items.map(\.english)).count, places.count)
        XCTAssertEqual(MapHomePlaceBookDescriptions.text(for: "kr.unknown", language: .korean), "")
        let state = MapHomePlaceBookState.make(visits: [:], language: .korean, region: "seoul")
        XCTAssertFalse(state.entries.isEmpty)
        XCTAssertTrue(state.entries.allSatisfy { !$0.summary.isEmpty })
    }

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
        // 도착하며 걸은 기록. 공항·해외 도시는 걷기가 있어야 방문이다(VIS1110A03).
        let walk = readings.first.map {
            TravelSegment(mode: .walking, span: TimeSpan(start: $0.timestamp.addingTimeInterval(-300), end: $0.timestamp), distanceMeters: 300, confidence: .high, evidence: [], isConfirmed: true)
        }
        let state = MapHomePlaceBookState.make(stays: stays, language: .korean, region: selection, travel: walk.map { [$0] } ?? [])
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
        XCTAssertEqual(MapHomePassportStampStyle.style(forCountry: "fr").entryCode, "F")
        let number = MapHomePassportStampStyle.stampNumber(country: "fr", date: date, digits: 3, calendar: calendar)
        XCTAssertEqual(number.count, 3)
        XCTAssertEqual(number, MapHomePassportStampStyle.stampNumber(country: "fr", date: date, digits: 3, calendar: calendar), "같은 날 같은 나라는 같은 번호")
        XCTAssertEqual(MapHomePassportStampStyle.numberDigits(country: "gb"), 4)
        let unique = (["kr"] + MapHomePlaceBookMenu.countries).filter { !["gu", "mp"].contains($0) }
        let styles = unique.map(MapHomePassportStampStyle.style(forCountry:))
        for (index, style) in styles.enumerated() {
            XCTAssertNotEqual(style, .standard, "도안 없음: \(unique[index])")
            XCTAssertFalse(styles[..<index].contains(style), "디자인 중복: \(unique[index])")
        }
        XCTAssertEqual(MapHomePassportStampStyle.style(forCountry: "gu"), MapHomePassportStampStyle.style(forCountry: "us"), "같은 나라만 같은 도안")
        XCTAssertEqual(MapHomePassportStampStyle.style(forCountry: "kr").shape, .circle)
        XCTAssertEqual(MapHomePassportStampStyle.style(forCountry: "th").colorHex, "#B8404A")
        XCTAssertEqual(MapHomePassportStampStyle.style(forCountry: "zz"), .standard)
        XCTAssertEqual(MapHomePassportStampStyle.style(forCountry: "id").shape, .triangle)
        XCTAssertEqual(MapHomePassportStampStyle.countryLabel("kr"), "KOREA")
        XCTAssertEqual(MapHomePassportStampStyle.countryLabel("jp"), "JAPAN")
        XCTAssertEqual(MapHomePassportStampStyle.countryLabel("cn"), "CHINA")
        XCTAssertNotNil(MapHomePassportStampStyle.style(forCountry: "jp").paperHex, "일본은 입국 스티커")
        XCTAssertNil(MapHomePassportStampStyle.style(forCountry: "th").paperHex)
        XCTAssertNotNil(MapHomePassportHomepageQR.image, "스티커의 홈페이지 QR이 만들어진다")
    }

    func testPassportStampsCoverAirportsAndOverseasCitiesOnly() throws {
        XCTAssertTrue(try bookPlace("kr.airport_gmp").usesPassportStamp)
        XCTAssertTrue(try bookPlace("kr.airport").usesPassportStamp)
        XCTAssertTrue(try bookPlace("intl.jp.tokyo").usesPassportStamp)
        XCTAssertFalse(try bookPlace("kr.gyeongbokgung").usesPassportStamp)
        XCTAssertEqual(MapHomeKoreaPlaceBookData.places.filter { $0.theme == "airport" }.count, 6)
    }

    @MainActor
    func testPlaceBookTestVisitsStackAndStaySeparateFromRecords() {
        MapHomePlaceBookTestMode.visits = [:]
        MapHomePlaceBookTestMode.addVisit("kr.namsan", now: day)
        MapHomePlaceBookTestMode.addVisit("kr.namsan", now: day)
        let state = MapHomePlaceBookState.make(stays: [], language: .korean, testVisits: MapHomePlaceBookTestMode.visits)
        XCTAssertEqual(state.landmarks.first { $0.id == "kr.namsan" }?.visitDates.count, 2)
        MapHomePlaceBookTestMode.visits = [:]
    }

    /// 다른 날 또 가면 도장이 쌓이고, 같은 날 여러 번은 한 번이다.
    func testVisitDatesStackAcrossDaysOnly() throws {
        let tower = try bookPlace("kr.namsan")
        let here = point(tower.latitude, tower.longitude)
        let stays = [stay("a", start: 0, at: here), stay("b", start: 3_600, at: here), stay("c", start: 86_400 * 3, at: here)]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(tower.visitDays(in: stays, calendar: calendar).count, 2)
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

    func testPassportPlacementIsStableAndStaysInsideItsCell() {
        for page in 0..<4 {
            let spots = (0..<MapHomePassportLayout.stampsPerPage).map {
                MapHomePassportLayout.placement(visaID: "visa-\(page)-\($0)", order: $0, page: page)
            }
            XCTAssertEqual(spots, (0..<MapHomePassportLayout.stampsPerPage).map {
                MapHomePassportLayout.placement(visaID: "visa-\(page)-\($0)", order: $0, page: page)
            })
            let cells = Set(spots.map { "\(Int($0.x * 2))-\(Int($0.y * 3))" })
            XCTAssertEqual(cells.count, MapHomePassportLayout.stampsPerPage)
        }
    }

    func testPassportPagesKeepOrderAndLeaveBlankPages() {
        let pages = MapHomePassportLayout.pages(Array(0..<13))
        XCTAssertEqual(pages.flatMap { $0 }, Array(0..<13))
        XCTAssertEqual(pages[0].count, MapHomePassportLayout.stampsPerPage)
        XCTAssertGreaterThanOrEqual(pages.count, MapHomePassportLayout.minimumPages)
        XCTAssertEqual(pages.last, [])
    }

    func testEveryLanguageHasItsOwnPassportText() {
        let designs = MapHomePassportDesign.languageCodes.map(MapHomePassportDesign.design(languageCode:))
        XCTAssertEqual(Set(designs.map { $0.top + $0.bottom }).count, designs.count)
        XCTAssertEqual(MapHomePassportDesign.design(languageCode: "pt-BR").bottom, ["PASSAPORTE DE VIAGEM"])
    }

    func testPlaybackEndKeepsLastRecordedCoordinate() {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        func point(_ latitude: Double) -> GeoPoint {
            GeoPoint(latitude: latitude, longitude: 127, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5)
        }
        let readings = [
            SensorReading(timestamp: base, point: point(37.1)),
            SensorReading(timestamp: base.addingTimeInterval(60), point: point(37.2)),
            SensorReading(timestamp: base.addingTimeInterval(120)),
        ]
        XCTAssertEqual(MapHomePlaybackLocation.lastRecordedCoordinate(in: readings)?.latitude, 37.2)
        XCTAssertNil(MapHomePlaybackLocation.lastRecordedCoordinate(in: [SensorReading(timestamp: base)]))
    }

    func testKakaoSearchDecodesLiveOnlyResultsAndKeepsAppleOutsideKorea() {
        let json = #"{"documents":[{"place_name":"경복궁","road_address_name":"서울 종로구 사직로 161","address_name":"서울 종로구 세종로 1-91","x":"126.977","y":"37.579"},{"place_name":"깨진값","x":"x","y":"37"}]}"#
        let results = MapHomeKakaoSearch.decode(Data(json.utf8))
        XCTAssertEqual(results.map(\.title), ["경복궁"])
        XCTAssertEqual(results[0].subtitle, "서울 종로구 사직로 161")
        XCTAssertEqual(results[0].coordinate.latitude, 37.579)
        XCTAssertTrue(results[0].isLiveOnly)
        XCTAssertTrue(MapHomeKakaoSearch.decode(Data("oops".utf8)).isEmpty)
        XCTAssertTrue(MapHomeKakaoSearch.isInKorea(.init(latitude: 37.5, longitude: 127)))
        XCTAssertFalse(MapHomeKakaoSearch.isInKorea(.init(latitude: 35.6, longitude: 139.7)))
    }

    func testSearchMergeKeepsFirstGroupAndLimit() {
        func item(_ title: String) -> MapHomeSearchResult {
            MapHomeSearchResult(title: title, subtitle: "", coordinate: .init(latitude: 37, longitude: 127))
        }
        let merged = MapHomeSearchPolicy.merged([[item("가 나")], [item("가나"), item("다")], (0..<9).map { item("곳\($0)") }])
        XCTAssertEqual(merged.count, 8)
        XCTAssertEqual(Array(merged.map(\.title).prefix(2)), ["가 나", "다"])
    }

    func testSubwayPassThroughIsNotAPlaceBookVisit() {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        func at(_ minute: Double) -> Date { base.addingTimeInterval(minute * 60) }
        func stay(_ start: Double, _ end: Double) -> PlaceStay {
            PlaceStay(placeKey: "gimpo", displayName: "김포공항", span: TimeSpan(start: at(start), end: at(end)), confidence: .high)
        }
        func subway(_ start: Double, _ end: Double, mode: TravelMode = .subway) -> TravelSegment {
            TravelSegment(mode: mode, span: TimeSpan(start: at(start), end: at(end)), distanceMeters: 1_000, confidence: .high, evidence: [], isConfirmed: false)
        }
        let travel = [subway(0, 30), subway(38, 60), subway(100, 130), subway(400, 420), subway(600, 650, mode: .bus)]
        let transfer = stay(30, 38), onboard = stay(105, 125), shortAfterRide = stay(420, 426), realVisit = stay(200, 300), afterBus = stay(650, 655)
        let visits = MapHomePlaceBookVisitPolicy.actualVisits([transfer, onboard, shortAfterRide, realVisit, afterBus], travel: travel)
        XCTAssertEqual(visits.map(\.id), [realVisit.id, afterBus.id])
    }

    func testVisitLedgerMatchesFullScanWithinBudget() {
        let calendar = Calendar(identifier: .gregorian)
        let places = MapHomeKoreaPlaceBookData.places
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        // 실행마다 같은 자료로 비교한다(REV1110A03). 예전에는 매번 다른 난수라 가끔만 실패할 수 있었다.
        var generator = LedgerSeededGenerator(seed: 0x5EED_1110)
        let stays: [PlaceStay] = (0..<20_000).map { index in
            let anchor = places[index % places.count]
            let jitter = Double.random(in: -0.04...0.04, using: &generator)
            let start = base.addingTimeInterval(Double(index) * 3_600)
            return PlaceStay(
                placeKey: "s\(index)", displayName: "s",
                span: TimeSpan(start: start, end: start.addingTimeInterval(Double(index % 90 + 1) * 60)),
                confidence: .high,
                point: GeoPoint(latitude: anchor.latitude + jitter, longitude: anchor.longitude + jitter, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5)
            )
        }
        let travel: [TravelSegment] = (0..<5_000).map { index in
            let start = base.addingTimeInterval(Double(index) * 14_400 + 1_800)
            return TravelSegment(mode: .subway, span: TimeSpan(start: start, end: start.addingTimeInterval(1_200)), distanceMeters: 1_000, confidence: .high, evidence: [], isConfirmed: true)
        }
        let clock = ContinuousClock()
        var ledger: [String: [Date]] = [:]
        let new = clock.measure { ledger = MapHomeVisitLedger.build(stays: stays, travel: travel, calendar: calendar) }
        var kept: [PlaceStay] = []
        let filter = clock.measure { kept = MapHomePlaceBookVisitPolicy.actualVisits(stays, travel: travel) }
        var full: [String: [Date]] = [:]
        let old = clock.measure {
            for place in places {
                let days = place.visitDays(in: kept, calendar: calendar)
                if !days.isEmpty { full[place.id] = days }
            }
        }
        print("LDGBENCH ledger=\(new) railFilter=\(filter) oldFullScan=\(old) stays=\(stays.count) rails=\(travel.count)")
        // 공항·해외 도시는 걷기 조건이 더해져 전수 비교와 다르다. 나머지는 같아야 한다.
        let passport = Set(places.filter(\.usesPassportStamp).map(\.id))
        XCTAssertEqual(ledger.filter { !passport.contains($0.key) }, full.filter { !passport.contains($0.key) })
        XCTAssertLessThan(new, .seconds(10), "2만 곳 장부가 여권을 바로 열 만큼 빨라야 한다")
    }

    func testIslandUsesOutlineAndAirportStaysNearTerminals() throws {
        func point(_ latitude: Double, _ longitude: Double) -> GeoPoint {
            GeoPoint(latitude: latitude, longitude: longitude, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
        }
        func ids(_ latitude: Double, _ longitude: Double) -> Set<String> {
            Set(MapHomePlaceSiteIndex.shared.places(containing: point(latitude, longitude)).map(\.id))
        }
        XCTAssertTrue(ids(37.4900, 126.5300).contains("kr.yeongjongdo"), "영종도 안")
        XCTAssertFalse(ids(37.3920, 126.6450).contains("kr.yeongjongdo"), "송도는 반경 안이지만 섬 밖")
        XCTAssertFalse(ids(37.5350, 126.6600).contains("kr.yeongjongdo"), "청라는 섬 밖")
        XCTAssertTrue(ids(37.5587, 126.8027).contains("kr.airport_gmp"), "김포 국내선")
        XCTAssertTrue(ids(37.4491, 126.4510).contains("kr.airport"), "인천 1터미널")
        XCTAssertFalse(ids(37.5670, 126.8270).contains("kr.airport_gmp"), "마곡은 공항이 아니다")
    }

    func testAirportVisitNeedsLongStayAndWalking() {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        func at(_ minute: Double) -> Date { base.addingTimeInterval(minute * 60) }
        let terminal = GeoPoint(latitude: 37.5587, longitude: 126.8027, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
        func stay(_ start: Double, _ end: Double) -> PlaceStay {
            PlaceStay(placeKey: "gmp", displayName: "김포", span: TimeSpan(start: at(start), end: at(end)), confidence: .high, point: terminal)
        }
        func segment(_ mode: TravelMode, _ start: Double, _ end: Double, _ meters: Double) -> TravelSegment {
            TravelSegment(mode: mode, span: TimeSpan(start: at(start), end: at(end)), distanceMeters: meters, confidence: .high, evidence: [], isConfirmed: true)
        }
        let travel = [segment(.walking, 100, 108, 400), segment(.car, 290, 300, 9_000), segment(.walking, 500, 503, 20)]
        let ledger = MapHomeVisitLedger.build(stays: [stay(110, 160), stay(300, 360), stay(505, 560), stay(700, 710)], travel: travel)
        XCTAssertEqual(ledger["kr.airport_gmp"]?.count, 1, "걷고 50분 머문 것만 방문")
    }

    func testTripImportReadsAIJSONWithFencesAndOffsets() throws {
        let text = """
        좋아요, 최종 계획입니다.
        ```json
        {"format":"bokki-trip","version":1,"tripId":"trip-20261201-bkk","title":"방콕 3박 4일",
         "items":[
          {"id":"i1","type":"flight","title":"TG659 인천→방콕","start":"2026-12-01T09:05+09:00","end":"2026-12-01T13:05+07:00",
           "place":{"name":"수완나품 공항","lat":13.69,"lng":100.75,"mapsUrl":"https://maps.google.com/?q=BKK"}},
          {"id":"i2","type":"meal","title":"쩟페어 야시장","start":"2026-12-01T19:00+07:00",
           "place":{"name":"Jodd Fairs","lat":null,"lng":null},"travelFromPrevious":{"mode":"taxi","minutes":40}}
         ]}
        ```
        """
        let plan = try TripImportParser.parse(text).get()
        XCTAssertEqual(plan.tripID, "trip-20261201-bkk")
        XCTAssertEqual(plan.items.map(\.kind), [.flight, .meal])
        XCTAssertEqual(plan.items[0].end.timeIntervalSince(plan.items[0].start), 6 * 3_600, "시차를 붙인 현지 시각")
        XCTAssertNil(plan.items[1].coordinate, "AI가 비운 좌표는 앱이 찾는다")
        XCTAssertEqual(plan.items[1].end.timeIntervalSince(plan.items[1].start), TripImportItem.defaultDuration)
        XCTAssertEqual(plan.items[1].travelMinutes, 40)
        XCTAssertEqual(plan.items[1].timeZone.secondsFromGMT(), 7 * 3_600, "방콕 현지 시간대")
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = TimeZone(identifier: "Asia/Seoul")!
        XCTAssertEqual(seoul.component(.day, from: plan.items[1].localDay(calendar: seoul)), 1, "방콕 12월 1일 밤은 기기 시간대와 상관없이 1일")
        XCTAssertEqual(TripImportParser.parse("안녕하세요"), .failure(.noJSON))
        XCTAssertEqual(TripImportParser.parse(#"{"format":"bokki-trip","version":2,"tripId":"x","title":"t","items":[]}"#), .failure(.unsupportedVersion(2)))
    }

    /// 외부 AI 비서 연동 문서의 샘플을 앱이 그대로 읽는지(TRP1110A05).
    func testTripRelayDocSampleParses() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/trip-relay-sample.json")
        // 실기기에서는 Mac의 저장소 파일이 보이지 않는다. 시뮬레이터에서만 돈다.
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "저장소 파일을 읽을 수 없는 기기")
        let plan = try TripImportParser.parse(String(contentsOf: url, encoding: .utf8)).get()
        XCTAssertEqual(plan.tripID, "trip-20261201-bkk")
        XCTAssertEqual(plan.items.map(\.kind), [.flight, .lodging, .activity, .meal, .sleep, .sight])
        XCTAssertNil(plan.items[3].coordinate)
        XCTAssertEqual(plan.items[0].endTimeZone.secondsFromGMT(), 7 * 3_600, "항공편 도착은 도착지 시차")
    }

    func testTravelStopDecodesRecordsWithoutTripNumbers() throws {
        let old = #"{"id":"6E3B1A52-0C33-4C1D-9F11-2B0E7A9D4A10","title":"경복궁","latitude":37.5796,"longitude":126.977,"day":0,"order":0}"#
        let stop = try JSONDecoder().decode(TravelPlanStop.self, from: Data(old.utf8))
        XCTAssertNil(stop.tripID)
        XCTAssertNil(stop.itemID)
        XCTAssertNil(stop.planID)
    }

    func testTripImportPromptFillsLanguageAndAppsOpen() {
        let prompt = TripImportPrompt.text(languageCode: "ko", today: Date(timeIntervalSince1970: 1_796_000_000))
        XCTAssertTrue(prompt.contains("Talk to me in Korean"))
        XCTAssertFalse(prompt.contains("{TODAY}"))
        XCTAssertNotNil(TripImportAIApp.chatGPT.url(prompt: prompt))
        XCTAssertTrue(TripImportAIApp.allCases.allSatisfy { $0.url(prompt: prompt) != nil })
        XCTAssertEqual(TripImportAIApp.allCases.first, .pickle, "피클이 맨 위(TRP1110A08)")
        XCTAssertEqual(TripImportAIApp.pickle.fallbackURL?.absoluteString, "https://apps.apple.com/app/id6795790129")
        XCTAssertFalse(TripImportAIApp.pickle.prefillsPrompt)
        XCTAssertTrue(prompt.contains(#""status": "booked | planned | tentative""#))
    }

    func testTravelRailUsesLocalWallClockFromArrival() throws {
        let plan = try TripImportParser.parse(#"""
        {"format":"bokki-trip","version":1,"tripId":"t","title":"t","items":[
         {"id":"f","type":"flight","title":"TG659","start":"2026-12-01T09:05+09:00","end":"2026-12-01T13:05+07:00"},
         {"id":"s","type":"sleep","title":"잠","start":"2026-12-01T23:00+07:00","end":"2026-12-02T07:00+07:00"}]}
        """#).get()
        let items = plan.items.map {
            TravelTripItem(tripID: "t", itemID: $0.id, kind: $0.kind.rawValue, title: $0.title, start: $0.start, end: $0.end,
                           startOffsetSeconds: $0.timeZone.secondsFromGMT(), endOffsetSeconds: $0.endTimeZone.secondsFromGMT(), planID: nil)
        }
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let day1 = seoul.date(from: DateComponents(year: 2026, month: 12, day: 1))!
        let day2 = seoul.date(from: DateComponents(year: 2026, month: 12, day: 2))!
        let first = TravelTripRail.segments(items, day: day1, calendar: seoul)
        XCTAssertEqual(first.map(\.startMinute), [9 * 60 + 5, 23 * 60])
        XCTAssertEqual(first.map(\.endMinute), [13 * 60 + 5, 1_440], "도착 13:05는 방콕 시각, 잠은 자정까지")
        XCTAssertEqual(first.map(\.categoryID), ["movement", "sleep"])
        let second = TravelTripRail.segments(items, day: day2, calendar: seoul)
        XCTAssertEqual(second.map(\.startMinute), [0])
        XCTAssertEqual(second.map(\.endMinute), [7 * 60], "다음 날 아침 7시 현지 기상")
    }

    func testSettingsDecodeWithoutTripItems() throws {
        let data = try JSONEncoder().encode(AppFeatureSettings.defaults)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "travelTripItems")
        let decoded = try JSONDecoder().decode(AppFeatureSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.travelTripItems)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("travelTripItems"), "비어 있으면 저장하지 않는다")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("travelPlanStops"), "빈 여행 장소도 저장하지 않는다")
        var withStops = AppFeatureSettings.defaults
        withStops.travelPlanStops = [TravelPlanStop(id: UUID(), title: "왓 아룬", latitude: 13.74, longitude: 100.49, day: Date(timeIntervalSince1970: 0), order: 0, planID: nil, tripID: "t", itemID: "i4")]
        let roundTrip = try JSONDecoder().decode(AppFeatureSettings.self, from: JSONEncoder().encode(withStops))
        XCTAssertEqual(roundTrip.travelPlanStops, withStops.travelPlanStops)
    }

    func testLocationAlwaysPromptOnlyWhenNotAlwaysAndOncePerDay() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LocationAlwaysPromptTests"))
        defaults.removePersistentDomain(forName: "LocationAlwaysPromptTests")
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9))!
        XCTAssertFalse(LocationAlwaysPrompt.shouldPrompt(state: .notDetermined, isAlways: false, now: now, defaults: defaults), "아직 안 물었으면 묻지 않는다")
        XCTAssertFalse(LocationAlwaysPrompt.shouldPrompt(state: .authorized, isAlways: true, now: now, defaults: defaults))
        XCTAssertTrue(LocationAlwaysPrompt.shouldPrompt(state: .authorized, isAlways: false, now: now, defaults: defaults), "앱 사용 중에만")
        XCTAssertTrue(LocationAlwaysPrompt.shouldPrompt(state: .denied, isAlways: false, now: now, defaults: defaults))
        LocationAlwaysPrompt.markShown(now: now, defaults: defaults)
        XCTAssertFalse(LocationAlwaysPrompt.shouldPrompt(state: .denied, isAlways: false, now: now.addingTimeInterval(3_600), defaults: defaults), "하루 한 번")
        XCTAssertTrue(LocationAlwaysPrompt.shouldPrompt(state: .denied, isAlways: false, now: now.addingTimeInterval(86_400 * 2), defaults: defaults))
    }

    /// 베타 기록 재생(SLP1110A01). 개인 기록이라 저장소에 두지 않고 `TEST_RUNNER_TAPTION_SLEEP_SCORE_REPLAY=<json>`일 때만 돈다.
    /// json: {"timeZone", "motion": [[시작, 끝, "stationary"...]], "nights": [{"night": [시작, 끝], "expect": [시작, 끝]}]}(2001 기준 초).
    func testScoredSleepReplay() throws {
        guard let path = ProcessInfo.processInfo.environment["TAPTION_SLEEP_SCORE_REPLAY"], !path.isEmpty else {
            throw XCTSkip("TAPTION_SLEEP_SCORE_REPLAY 없음")
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: object["timeZone"] as? String ?? "Asia/Seoul") ?? .current
        let motion = try XCTUnwrap(object["motion"] as? [[Any]]).compactMap { row -> MotionActivityRecord? in
            guard let start = row[0] as? Double, let end = row[1] as? Double, let kind = (row[2] as? String).flatMap(MotionKind.init(rawValue:)) else { return nil }
            return MotionActivityRecord(span: TimeSpan(start: Date(timeIntervalSinceReferenceDate: start), end: Date(timeIntervalSinceReferenceDate: end)), motion: kind, confidence: .high)
        }
        for night in try XCTUnwrap(object["nights"] as? [[String: [Double]]]) {
            let span = try XCTUnwrap(night["night"]), expect = try XCTUnwrap(night["expect"])
            let records = PhoneSleepScoreAdapter.records(
                night: TimeSpan(start: Date(timeIntervalSinceReferenceDate: span[0]), end: Date(timeIntervalSinceReferenceDate: span[1])),
                readings: [], motionActivities: motion, actuals: [], homePoint: nil, homeRadiusMeters: 100,
                wearableSleepSpans: [], asOf: .distantFuture, calendar: calendar
            )
            let sleep = try XCTUnwrap(records.first, "수면 없음 \(span)")
            print("SLEEPSCORE", sleep.startedAt, sleep.endedAt ?? sleep.startedAt, sleep.evidence.joined(separator: " | "))
            XCTAssertEqual(sleep.startedAt.timeIntervalSinceReferenceDate, expect[0], accuracy: 600)
            XCTAssertEqual(try XCTUnwrap(sleep.endedAt).timeIntervalSinceReferenceDate, expect[1], accuracy: 600)
        }
    }

    func testScoredSleepSkipsNightsWithWatchSleep() {
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = TimeZone(identifier: "Asia/Seoul")!
        func at(_ day: Int, _ hour: Int) -> Date { seoul.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))! }
        let motion = [MotionActivityRecord(span: TimeSpan(start: at(9, 1), end: at(9, 8)), motion: .stationary, confidence: .high)]
        func run(_ wearable: [TimeSpan]) -> [ActualRecord] {
            PhoneSleepScoreAdapter.records(
                night: TimeSpan(start: at(8, 18), end: at(9, 12)), readings: [], motionActivities: motion + [
                    MotionActivityRecord(span: TimeSpan(start: at(8, 18), end: at(8, 23)), motion: .walking, confidence: .high),
                    MotionActivityRecord(span: TimeSpan(start: at(9, 8), end: at(9, 12)), motion: .walking, confidence: .high),
                ], actuals: [], homePoint: nil, homeRadiusMeters: 100, wearableSleepSpans: wearable, asOf: at(10, 0), calendar: seoul
            )
        }
        XCTAssertEqual(run([]).count, 1, "워치 없이 자면 휴대폰 점수로 수면")
        XCTAssertTrue(run([TimeSpan(start: at(9, 1), end: at(9, 7))]).isEmpty, "워치 수면이 있는 밤은 쓰지 않는다")
    }

    func testTripClipboardOfferOnlyAfterPromptAndChangedClipboard() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TripClipboardWatchTests"))
        defaults.removePersistentDomain(forName: "TripClipboardWatchTests")
        let now = Date(timeIntervalSinceReferenceDate: 815_900_000)
        XCTAssertFalse(TripClipboardWatch.shouldOffer(currentChangeCount: 9, hasStrings: true, now: now, defaults: defaults), "프롬프트를 안 썼으면 묻지 않는다")
        defaults.set(7, forKey: "tripImportPromptChangeCount")
        defaults.set(now.timeIntervalSinceReferenceDate, forKey: "tripImportPromptStartedAt")
        XCTAssertFalse(TripClipboardWatch.shouldOffer(currentChangeCount: 7, hasStrings: true, now: now, defaults: defaults), "프롬프트 그대로")
        XCTAssertTrue(TripClipboardWatch.shouldOffer(currentChangeCount: 8, hasStrings: true, now: now.addingTimeInterval(600), defaults: defaults))
        XCTAssertFalse(TripClipboardWatch.shouldOffer(currentChangeCount: 8, hasStrings: true, now: now.addingTimeInterval(7 * 3_600), defaults: defaults), "6시간 지나면 묻지 않는다")
        TripClipboardWatch.clear(defaults: defaults)
        XCTAssertFalse(TripClipboardWatch.shouldOffer(currentChangeCount: 8, hasStrings: true, now: now, defaults: defaults))
    }

    func testTripRelayKeyFormatAndDeliveryInstruction() throws {
        let key = TripRelay.base64URL(Data(repeating: 0xFB, count: 32))
        XCTAssertEqual(key.count, 43)
        XCTAssertTrue(TripRelay.isValidKey(key), key)
        XCTAssertFalse(key.contains("+") || key.contains("/") || key.contains("="))
        XCTAssertFalse(TripRelay.isValidKey("short"))
        let text = TripRelay.deliveryInstruction(endpoint: try XCTUnwrap(URL(string: "https://relay.example.com/plan")), key: key)
        XCTAssertTrue(text.contains("POST https://relay.example.com/plan"))
        XCTAssertTrue(text.contains("Bearer \(key)"))
    }

    /// REV1110A01: 시각 꼴 여러 가지, 잘못된 날짜 거절.
    func testTripTimeAcceptsCompactOffsetAndFraction() throws {
        let base = try XCTUnwrap(TripImportParser.date("2026-12-01T09:05+07:00"))
        XCTAssertEqual(TripImportParser.date("2026-12-01T09:05:00.000+0700"), base)
        XCTAssertEqual(TripImportParser.date("2026-12-01T02:05:00Z"), base)
        XCTAssertNil(TripImportParser.date("2026-13-01T09:05+07:00"))
        XCTAssertNil(TripImportParser.date("2026-12-01 09:05"))
    }

    /// REV1110A01: 핀 없는 수면·좌표 없는 일정도 다시 가져올 때 지우고, 바뀐 것에 센다.
    @MainActor
    func testTripReimportReplacesItemsWithoutPins() async throws {
        let model = AppModel(repository: InMemoryPlanRepository(), cloudSyncService: nil)
        await model.bootstrapLocalSnapshot()
        func plan(_ sleepTitle: String) throws -> TripImportPlan {
            try TripImportParser.parse(#"""
            {"format":"bokki-trip","version":1,"tripId":"t1","title":"t","items":[
             {"id":"a","type":"sight","title":"왓 아룬","start":"2026-12-02T09:00+07:00","place":{"lat":13.74,"lng":100.49}},
             {"id":"s","type":"sleep","title":"\#(sleepTitle)","start":"2026-12-01T23:00+07:00","end":"2026-12-02T07:00+07:00"},
             {"id":"m","type":"meal","title":"야시장","start":"2026-12-01T19:00+07:00","place":{"lat":null,"lng":null}}]}
            """#).get()
        }
        await model.applyTripImport(try plan("취침"))
        XCTAssertEqual(model.snapshot.plans.count, 3)
        let diff = try XCTUnwrap(model.tripImportDiff(for: try plan("늦잠")))
        XCTAssertEqual(diff, TripImportDiff(added: 0, changed: 1, removed: 0))
        await model.applyTripImport(try plan("늦잠"))
        XCTAssertEqual(model.snapshot.plans.count, 3, "같은 여행을 다시 넣어도 계획이 두 벌이 되지 않는다")
        XCTAssertEqual(model.settings.travelPlanStops.count, 1)
        XCTAssertEqual(model.settings.travelTripItems?.count, 3)
    }

    /// REV1110A01: 같은 계획은 한 번만 자동으로 띄운다.
    func testTripRelayShowsSamePlanOnce() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TripRelayTests"))
        defaults.removePersistentDomain(forName: "TripRelayTests")
        XCTAssertTrue(TripRelay.isNew("{\"a\":1}", defaults: defaults))
        XCTAssertFalse(TripRelay.isNew("{\"a\":1}", defaults: defaults), "지운 뒤 캐시가 돌려준 같은 계획")
        XCTAssertTrue(TripRelay.isNew("{\"a\":2}", defaults: defaults))
    }

    /// REV1110A01: 신뢰도가 바뀌어 끊긴 정지 기록은 깬 근거가 아니고, 기록 ID는 밤마다 하나다.
    func testScoredSleepJoinsSplitStillRecords() throws {
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = TimeZone(identifier: "Asia/Seoul")!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date { seoul.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))! }
        func run(wakeAt end: Date) -> [ActualRecord] {
            let still = [(at(9, 0, 30), at(9, 2, 30)), (at(9, 2, 30), at(9, 4, 30)), (at(9, 4, 31), at(9, 6, 30)), (at(9, 6, 30), end)].map {
                MotionActivityRecord(span: TimeSpan(start: $0.0, end: $0.1), motion: .stationary, confidence: .medium)
            }
            return PhoneSleepScoreAdapter.records(
                night: TimeSpan(start: at(8, 18), end: at(9, 12)), readings: [], motionActivities: still + [
                    MotionActivityRecord(span: TimeSpan(start: at(8, 23), end: at(9, 0, 30)), motion: .walking, confidence: .high),
                    MotionActivityRecord(span: TimeSpan(start: end, end: at(9, 12)), motion: .walking, confidence: .high),
                ], actuals: [], homePoint: nil, homeRadiusMeters: 100, wearableSleepSpans: [], asOf: at(10, 0), calendar: seoul
            )
        }
        let first = try XCTUnwrap(run(wakeAt: at(9, 7, 30)).first, "2시간마다 끊긴 정지 기록도 한 밤")
        XCTAssertEqual(first.startedAt, at(9, 0, 30))
        XCTAssertEqual(first.endedAt, at(9, 7, 30))
        XCTAssertEqual(try XCTUnwrap(run(wakeAt: at(9, 7, 40)).first).id, first.id, "구간이 조금 바뀌어도 같은 기록")
    }

    /// REV1110A02: 서울에서 만든 일정이 방콕 시간대에서도 같은 날에 보인다.
    func testTravelStopDayStaysAfterTimeZoneChange() throws {
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        var bangkok = Calendar(identifier: .gregorian)
        bangkok.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
        let stored = try XCTUnwrap(seoul.date(from: DateComponents(year: 2026, month: 12, day: 1)))
        let stop = TravelPlanStop(id: UUID(), title: "왓 아룬", latitude: 13.74, longitude: 100.49, day: stored, order: 0, planID: nil)
        let bangkokDay = try XCTUnwrap(bangkok.date(from: DateComponents(year: 2026, month: 12, day: 1)))
        XCTAssertEqual(TravelPlanSchedule.stops(on: bangkokDay, in: [stop], calendar: bangkok).count, 1)
        XCTAssertEqual(TravelPlanSchedule.days([stop], calendar: bangkok), [bangkokDay])
        XCTAssertTrue(TravelPlanSchedule.stops(on: bangkokDay.addingTimeInterval(86_400), in: [stop], calendar: bangkok).isEmpty)
    }

    /// REV1110A02: 국내 판정은 남한만. 후쿠오카·대마도·북한은 Apple 검색으로 간다.
    func testKakaoSearchAreaIsSouthKoreaOnly() {
        func inside(_ lat: Double, _ lng: Double) -> Bool { MapHomeKakaoSearch.isInKorea(CLLocationCoordinate2D(latitude: lat, longitude: lng)) }
        for (lat, lng) in [(37.566, 126.978), (35.18, 129.08), (33.50, 126.53), (37.48, 130.90), (37.75, 128.90), (34.81, 126.39), (37.46, 126.44), (38.21, 128.59), (37.97, 124.71)] {
            XCTAssertTrue(inside(lat, lng), "\(lat), \(lng)")
        }
        for (lat, lng) in [(33.59, 130.40), (34.40, 129.30), (39.03, 125.75), (37.97, 126.55), (34.69, 135.50), (40.0, 124.4)] {
            XCTAssertFalse(inside(lat, lng), "\(lat), \(lng)")
        }
    }

    /// REV1110A02: 외부 계획 링크는 구글 지도 https만, 같은 id는 차례 번호.
    func testTripImportKeepsOnlyGoogleMapsLinksAndUniqueIDs() throws {
        XCTAssertNotNil(TripImportParser.mapsURL("https://maps.google.com/?q=Wat+Arun"))
        XCTAssertNotNil(TripImportParser.mapsURL("https://www.google.co.kr/maps/place/x"))
        XCTAssertNotNil(TripImportParser.mapsURL("https://maps.app.goo.gl/abc"))
        XCTAssertNil(TripImportParser.mapsURL("http://maps.google.com/?q=x"))
        XCTAssertNil(TripImportParser.mapsURL("https://google.com.evil.example/"))
        XCTAssertNil(TripImportParser.mapsURL("shortcuts://run-shortcut?name=x"))
        let plan = try TripImportParser.parse(#"""
        {"format":"bokki-trip","version":1,"tripId":"t","title":"t","items":[
         {"id":"i1","type":"meal","title":"a","start":"2026-12-01T09:00+07:00","place":{"mapsUrl":"https://evil.example/"}},
         {"id":"i1","type":"meal","title":"b","start":"2026-12-02T09:00+07:00"}]}
        """#).get()
        XCTAssertEqual(plan.items.map(\.id), ["i1", "i1#2"])
        XCTAssertNil(plan.items[0].mapsURL)
    }

    /// REV1110A02: 중계에서 받은 그 글일 때만 서버에서 지운다. 키가 있으면 ChatGPT 주소에 프롬프트를 싣지 않는다.
    func testTripRelayClearsOnlyReceivedPlan() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TripRelayClearTests"))
        defaults.removePersistentDomain(forName: "TripRelayClearTests")
        _ = TripRelay.isNew("{\"a\":1}", defaults: defaults)
        XCTAssertTrue(TripRelay.isLastReceived("{\"a\":1}", defaults: defaults))
        XCTAssertFalse(TripRelay.isLastReceived("{\"a\":2}", defaults: defaults))
        XCTAssertNil(TripImportAIApp.chatGPT.url(prompt: nil)?.query)
    }

    /// REV1110A02: 이미 시작한 여행은 첫날부터 고를 수 있다.
    func testTravelModeOpensOngoingTripStart() throws {
        let now = Date(timeIntervalSinceReferenceDate: 816_000_000)
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        func item(_ trip: String, _ start: TimeInterval, _ end: TimeInterval) -> TravelTripItem {
            TravelTripItem(tripID: trip, itemID: "i", kind: "sight", title: "t", start: now.addingTimeInterval(start), end: now.addingTimeInterval(end),
                           startOffsetSeconds: calendar.timeZone.secondsFromGMT(for: now), endOffsetSeconds: calendar.timeZone.secondsFromGMT(for: now), planID: nil)
        }
        XCTAssertEqual(TravelTripSchedule.earliestSelectableDay(items: [], now: now), today)
        XCTAssertEqual(TravelTripSchedule.earliestSelectableDay(items: [item("old", -10 * 86_400, -9 * 86_400)], now: now), today, "끝난 여행은 열지 않는다")
        let ongoing = TravelTripSchedule.earliestSelectableDay(items: [item("now", -2 * 86_400, 86_400)], now: now)
        XCTAssertEqual(ongoing, calendar.startOfDay(for: now.addingTimeInterval(-2 * 86_400)))
    }
}

/// REV1110A03: 3차 리뷰 수정.
final class ReviewThirdPassTests: XCTestCase {
    private func point(_ latitude: Double, _ longitude: Double) -> GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5)
    }

    func testIslandOutlineReachesBeyondItsCircle() {
        // 거제도 남쪽 끝은 중심에서 18km를 넘는다. 예전 15km 원과 겹쳐 보면 빠졌다.
        XCTAssertTrue(MapHomePlaceSiteIndex.shared.places(containing: point(34.71, 128.59)).contains { $0.id == "kr.geojedo" })
        XCTAssertTrue(MapHomePlaceSiteIndex.shared.places(containing: point(35.03, 128.705)).contains { $0.id == "kr.geojedo" })
    }

    func testSearchMergeKeepsNearbyBranchesWithSameName() {
        func item(_ title: String, _ latitude: Double) -> MapHomeSearchResult {
            MapHomeSearchResult(title: title, subtitle: "", coordinate: .init(latitude: latitude, longitude: 127))
        }
        let merged = MapHomeSearchPolicy.merged([[item("스타벅스", 37.50)], [item("스타벅스", 37.5001), item("스타벅스", 37.51)]])
        XCTAssertEqual(merged.map(\.coordinate.latitude), [37.50, 37.51], "같은 자리는 하나, 1km 떨어진 지점은 따로")
    }

    func testPlaybackFallbackDoesNotJumpToLaterPlace() {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let readings = [
            SensorReading(timestamp: base.addingTimeInterval(7 * 3_600), point: point(37.1, 127)),
            SensorReading(timestamp: base.addingTimeInterval(20 * 3_600), point: point(37.2, 127)),
        ]
        XCTAssertNil(MapHomePlaybackLocation.lastRecordedCoordinate(in: readings, notAfter: base.addingTimeInterval(3 * 3_600)), "첫 기록 전에는 저녁 자리로 가지 않는다")
        XCTAssertEqual(MapHomePlaybackLocation.lastRecordedCoordinate(in: readings, notAfter: base.addingTimeInterval(12 * 3_600))?.latitude, 37.1)
        XCTAssertEqual(MapHomePlaybackLocation.lastRecordedCoordinate(in: readings)?.latitude, 37.2)
    }

    func testStampDateTextIsEnglishDayMonthYear() throws {
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let date = try XCTUnwrap(seoul.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 1)))
        XCTAssertEqual(MapHomePassportStampStyle.dateText(date, calendar: seoul), "09 NOV 2026")
    }

    func testPassportCoversUseNoGovernmentNames() {
        let words = MapHomePassportDesign.languageCodes.flatMap { MapHomePassportDesign.design(languageCode: $0).top + MapHomePassportDesign.design(languageCode: $0).bottom }
        for banned in ["REPUBLIC", "대한민국", "United States", "UNIÓN EUROPEA", "BUNDESREPUBLIK", "中华人民共和国"] {
            XCTAssertFalse(words.contains { $0.contains(banned) }, banned)
        }
    }
}

/// 시험용 고정 난수(SplitMix64).
private struct LedgerSeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
