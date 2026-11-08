import CoreLocation
import XCTest
@testable import TaptionPlan

/// TRV1108A01: 도시 여행 지도 — 도시 뽑기·구간 수단·직접 입력·바탕 지도 투영·시간표.
final class TravelMapTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let catalog = TravelMapCityCatalog.bundled

    private let seoul = (37.5665, 126.9780), daejeon = (36.3504, 127.3845), jeonju = (35.8242, 127.1480)
    private let gyeongju = (35.8562, 129.2247), busan = (35.1796, 129.0756), jeju = (33.4996, 126.5312)

    private func time(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    private func samples(_ city: (Double, Double), from: Double, to: Double, every: Double = 10) -> [MapHomeRangeTripPlan.Sample] {
        stride(from: from, through: to, by: every).map {
            MapHomeRangeTripPlan.Sample(time: time($0).timeIntervalSinceReferenceDate, latitude: city.0 + 0.002, longitude: city.1 - 0.002)
        }
    }

    private func move(_ mode: TravelMode, _ from: Double, _ to: Double, km: Double) -> TravelMapTripExtractor.Move {
        TravelMapTripExtractor.Move(span: TimeSpan(start: time(from), end: time(to)), mode: mode, meters: km * 1_000)
    }

    /// 서울 → (대전 통과) → 전주 → 경주 → 부산 → 제주.
    private func sTrip() -> TravelMapTrip {
        var points = samples(seoul, from: 0, to: 180)
        points += samples(daejeon, from: 200, to: 210)
        points += samples(jeonju, from: 240, to: 600)
        points += samples(gyeongju, from: 720, to: 1_000)
        points += samples(busan, from: 1_100, to: 1_500)
        points += samples(jeju, from: 1_640, to: 2_000)
        let moves = [
            move(.walking, 170, 185, km: 1),
            move(.train, 185, 238, km: 210),
            move(.walking, 236, 240, km: 0.5),
            move(.car, 600, 718, km: 230),
            move(.bus, 1_000, 1_098, km: 70),
            move(.subway, 1_500, 1_530, km: 20),
            move(.airplane, 1_540, 1_630, km: 300),
        ]
        return TravelMapTripExtractor.extract(samples: points, stays: [], moves: moves, catalog: catalog, language: .korean)
    }

    // MARK: - 바탕 지도

    func testBundledBaseMapHasWorldAndEastAsiaLayers() throws {
        let map = try XCTUnwrap(TravelMapBaseMap.bundled)
        XCTAssertEqual(map.region, TravelMapGeoBox(west: 100, south: 18, east: 150, north: 52))
        XCTAssertGreaterThan(map.parts(.land, scope: .world).count, 50)
        XCTAssertGreaterThan(map.parts(.border, scope: .world).count, 100)
        XCTAssertGreaterThan(map.parts(.land, scope: .region).count, 100)
        XCTAssertFalse(map.parts(.lake, scope: .region).isEmpty)
        // 제주도가 자세한 육지에 들어 있다.
        XCTAssertTrue(map.parts(.land, scope: .region).contains { $0.box.west < 126.5 && $0.box.east > 126.5 && $0.box.south < 33.4 && $0.box.north > 33.4 && $0.box.north < 34 })
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ne-basemap", withExtension: "bin"))
        let bytes = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
        XCTAssertLessThan(bytes, 1_000_000)
    }

    func testBaseMapRejectsTruncatedData() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ne-basemap", withExtension: "bin"))
        let data = try Data(contentsOf: url)
        XCTAssertThrowsError(try TravelMapBaseMap.decode(data.prefix(data.count - 3)))
        XCTAssertThrowsError(try TravelMapBaseMap.decode(Data("NOPE".utf8)))
    }

    func testMercatorRoundTripAndFitKeepsStopsInsideContent() {
        let point = TravelMapViewport.mercator(longitude: 129.0756, latitude: 35.1796)
        let back = TravelMapViewport.coordinate(mercator: point)
        XCTAssertEqual(back.latitude, 35.1796, accuracy: 1e-9)
        XCTAssertEqual(back.longitude, 129.0756, accuracy: 1e-9)

        let size = CGSize(width: 360, height: 640)
        let content = TravelMapVideoScene.content(in: size)
        let coordinates = [seoul, jeonju, gyeongju, busan, jeju].map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }
        let viewport = TravelMapViewport.fit(coordinates, content: content, size: size)
        for coordinate in coordinates {
            XCTAssertTrue(content.contains(viewport.point(coordinate)), "\(coordinate)")
        }
        // 가장 긴 쪽이 영역을 거의 채운다(여백 18%만 남긴다).
        let ys = coordinates.map { viewport.point($0).y }
        XCTAssertGreaterThan((ys.max()! - ys.min()!) / content.height, 0.6)
        // 한국 여행은 자세한 동아시아 지도로, 서울→런던은 세계 지도로 그린다.
        let map = TravelMapBaseMap.bundled
        XCTAssertEqual(map?.scope(for: viewport.geoBox), .region)
        let world = TravelMapViewport.fit(
            [coordinates[0], CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12)], content: content, size: size
        )
        XCTAssertEqual(map?.scope(for: world.geoBox), .world)
    }

    func testOneCityTripDoesNotZoomPastCoastlineDetail() {
        let size = CGSize(width: 360, height: 640)
        let content = TravelMapVideoScene.content(in: size)
        let viewport = TravelMapViewport.fit([CLLocationCoordinate2D(latitude: seoul.0, longitude: seoul.1)], content: content, size: size)
        let box = viewport.geoBox
        let widthMeters = MapHomeRangeTripPlan.meters(
            MapHomeRangeTripPlan.Point(latitude: seoul.0, longitude: box.west),
            MapHomeRangeTripPlan.Point(latitude: seoul.0, longitude: box.east)
        )
        XCTAssertGreaterThan(widthMeters, TravelMapViewport.minimumSpanMeters)
    }

    func testPaletteStaysInMidTones() {
        let classic = TaptionBarPalette(["#3E3320", "#EE8A5E", "#F3C766", "#D9694F", "#62B7A6", "#E7708F", "#9CC6E8", "#FBF6EA", "#8A5A3C", "#B9A98F"])
        let night = TaptionBarPalette(["#FFFFFF", "#FF9E80", "#FFD97A", "#F2836B", "#6FDCC8", "#FF8FB0", "#8CCBFF", "#F5F9FF", "#4A6FA8", "#93B6DA"])
        for (bar, isDark) in [(classic, false), (night, true), (classic, true), (night, false)] {
            let palette = TravelMapPalette.make(bar: bar, isDark: isDark)
            let water = TravelMapPalette.lightness(palette.water), land = TravelMapPalette.lightness(palette.land)
            XCTAssertTrue((25...85).contains(water), "water \(water) dark=\(isDark)")
            XCTAssertTrue((25...85).contains(land), "land \(land) dark=\(isDark)")
            XCTAssertGreaterThan(abs(land - water), 6, "land and water must differ")
        }
    }

    // MARK: - 도시 목록

    func testCatalogGroupsCoordinatesIntoCities() {
        XCTAssertEqual(catalog.nearest(latitude: 37.4979, longitude: 127.0276)?.koreanName, "서울") // 강남역
        XCTAssertEqual(catalog.nearest(latitude: jeonju.0, longitude: jeonju.1)?.koreanName, "전주")
        XCTAssertEqual(catalog.nearest(latitude: gyeongju.0, longitude: gyeongju.1)?.koreanName, "경주")
        XCTAssertEqual(catalog.nearest(latitude: jeju.0, longitude: jeju.1)?.englishName, "Jeju")
        XCTAssertNil(catalog.nearest(latitude: 36.0, longitude: 131.0)) // 동해 한가운데
        XCTAssertEqual(catalog.search("부산").first?.englishName, "Busan")
        XCTAssertTrue(catalog.search("gyeong").contains { $0.koreanName == "경주" })
    }

    // MARK: - 기록에서 뽑기

    func testExtractionOrdersCitiesByTimeAndSkipsPassThrough() {
        let trip = sTrip()
        XCTAssertEqual(trip.stops.map(\.name), ["서울", "전주", "경주", "부산", "제주"])
        XCTAssertEqual(trip.stops.dropFirst().map(\.arrivalMode), [.train, .car, .bus, .flight])
        XCTAssertEqual(trip.stops.map(\.date), trip.stops.map(\.date).sorted())
        XCTAssertEqual(trip.stops[1].date, time(240))
        // 도시 점은 표본 평균이 아니라 도시 목록 좌표다.
        XCTAssertEqual(trip.stops[0].latitude, 37.5683, accuracy: 0.001)
        // 기록 거리가 직선보다 길면 기록 거리를 쓴다(서울→전주 직선 약 195 km, 기록 211.5 km).
        XCTAssertEqual(trip.legMeters(arrivingAt: 1), 211_500, accuracy: 1)
    }

    func testRevisitedCityStaysASeparateStop() {
        var points = samples(seoul, from: 0, to: 120)
        points += samples(busan, from: 300, to: 600)
        points += samples(seoul, from: 800, to: 900)
        let trip = TravelMapTripExtractor.extract(samples: points, stays: [], moves: [], catalog: catalog, language: .english)
        XCTAssertEqual(trip.stops.map(\.name), ["Seoul", "Busan", "Seoul"])
    }

    func testPlaceStayWithoutSamplesCountsAsVisitAndNamesUnknownArea() {
        let stay = TravelMapTripExtractor.Stay(
            span: TimeSpan(start: time(300), end: time(500)), latitude: 30.0, longitude: 140.0, name: "바닷가 캠핑장"
        )
        let trip = TravelMapTripExtractor.extract(
            samples: samples(seoul, from: 0, to: 120), stays: [stay], moves: [], catalog: catalog, language: .korean
        )
        XCTAssertEqual(trip.stops.map(\.name), ["서울", "바닷가 캠핑장"])
    }

    func testLegModeWithoutRecordsGuessesFromDistanceAndSpeed() {
        let window = TimeSpan(start: time(0), end: time(90))
        XCTAssertEqual(TravelMapTripExtractor.legMode(moves: [], window: window, straightMeters: 450_000).mode, .flight)
        XCTAssertEqual(TravelMapTripExtractor.legMode(moves: [], window: TimeSpan(start: time(0), end: time(400)), straightMeters: 320_000).mode, .car)
        XCTAssertEqual(TravelMapTripExtractor.legMode(moves: [], window: TimeSpan(start: time(0), end: time(2_000)), straightMeters: 800_000).mode, .flight)
    }

    func testTravelModeMapping() {
        XCTAssertEqual(TravelMapMode(.taxi), .car)
        XCTAssertEqual(TravelMapMode(.cycling), .walk)
        XCTAssertEqual(TravelMapMode(.running), .walk)
        XCTAssertEqual(TravelMapMode(.subway), .subway)
        XCTAssertEqual(TravelMapMode(.train), .train)
        XCTAssertEqual(TravelMapMode(.airplane), .flight)
        XCTAssertEqual(TravelMapMode(.ship), .ship)
        XCTAssertEqual(Set(TravelMapMode.allCases.map(\.symbolName)).count, TravelMapMode.allCases.count)
        for mode in TravelMapMode.allCases {
            XCTAssertNotNil(UIImage(systemName: mode.symbolName), mode.rawValue)
        }
    }

    // MARK: - 직접 입력

    func testManualTripAppendsNextDayAndGuessesMode() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        var trip = TravelMapTrip()
        trip.append(name: "서울", coordinate: CLLocationCoordinate2D(latitude: seoul.0, longitude: seoul.1), calendar: calendar, now: start)
        trip.append(name: "수원", coordinate: CLLocationCoordinate2D(latitude: 37.2636, longitude: 127.0286), calendar: calendar, now: start)
        trip.append(name: "부산", coordinate: CLLocationCoordinate2D(latitude: busan.0, longitude: busan.1), calendar: calendar, now: start)
        trip.append(name: "제주", coordinate: CLLocationCoordinate2D(latitude: jeju.0, longitude: jeju.1), calendar: calendar, now: start)
        // 거리만 보므로 부산→제주(약 290 km)도 기차로 시작한다. 사용자가 고친다.
        XCTAssertEqual(trip.stops.dropFirst().map(\.arrivalMode), [.car, .train, .train])
        XCTAssertEqual(trip.stops[0].date, calendar.startOfDay(for: start))
        XCTAssertEqual(calendar.dateComponents([.day], from: trip.stops[0].date, to: trip.stops[3].date).day, 3)
        XCTAssertTrue(trip.isRenderable)
        // 서울→수원→부산→제주 직선 합 ≈ 31 + 300 + 290 km.
        XCTAssertEqual(trip.totalMeters / 1_000, 620, accuracy: 25)
        XCTAssertEqual(TravelMapMode.guess(meters: 450_000), .flight)
    }

    func testDraftStoreRoundTripsLocally() throws {
        let suite = "TravelMapTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertEqual(TravelMapTripDraftStore.load(defaults), TravelMapTrip())
        let trip = sTrip()
        TravelMapTripDraftStore.save(trip, defaults)
        XCTAssertEqual(TravelMapTripDraftStore.load(defaults), trip)
    }

    // MARK: - 시간표·배치

    func testPlanDrawsLegByLegThenHoldsOverview() {
        let plan = TravelMapVideoPlan(legCount: 4)
        XCTAssertEqual(plan.totalSeconds, 1 + 4 * 2.3 + 2.5, accuracy: 1e-9)
        XCTAssertEqual(plan.frameCount(fps: 30), Int((plan.totalSeconds * 30).rounded(.up)))
        XCTAssertEqual(plan.state(atSecond: 0.5), .init(drawnLegs: 0, activeProgress: nil, currentStop: 0, isOverview: false))
        let drawing = plan.state(atSecond: 1 + 2.3 + 0.8)
        XCTAssertEqual(drawing.drawnLegs, 1)
        XCTAssertEqual(drawing.currentStop, 1)
        XCTAssertEqual(drawing.activeProgress ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(plan.state(atSecond: 1 + 2.3 + 1.9), .init(drawnLegs: 2, activeProgress: nil, currentStop: 2, isOverview: false))
        XCTAssertEqual(plan.state(atSecond: plan.totalSeconds - 0.1), .init(drawnLegs: 4, activeProgress: nil, currentStop: 4, isOverview: true))
    }

    func testLongTripIsCappedAtMaximumLength() {
        let plan = TravelMapVideoPlan(legCount: 60)
        XCTAssertEqual(plan.totalSeconds, TravelMapVideoPlan.maximumSeconds, accuracy: 1e-9)
        XCTAssertLessThan(plan.legSeconds, TravelMapVideoPlan.legSeconds)
    }

    func testSceneCurvesAlternateSidesAndPartialEndsOnCurve() {
        let trip = sTrip()
        let scene = TravelMapVideoScene(trip: trip, size: CGSize(width: 360, height: 640))
        XCTAssertEqual(scene.legCurves.count, 4)
        func side(_ leg: Int) -> Double {
            let curve = scene.legCurves[leg], a = curve.first!, b = curve.last!, m = curve[curve.count / 2]
            return Double((b.x - a.x) * (m.y - a.y) - (b.y - a.y) * (m.x - a.x))
        }
        XCTAssertLessThan(side(0) * side(1), 0)
        XCTAssertLessThan(side(1) * side(2), 0)
        XCTAssertEqual(scene.partial(leg: 0, progress: 1).last, scene.stopPoints[1])
        XCTAssertEqual(scene.partial(leg: 0, progress: 0).first, scene.stopPoints[0])
        XCTAssertEqual(scene.legCurves[0].first, scene.stopPoints[0])
    }
}
