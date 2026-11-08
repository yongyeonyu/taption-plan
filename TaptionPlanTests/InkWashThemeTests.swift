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

    func testPlaceBookCountsVisitedAndRemaining() throws {
        let home = FrequentPlace(kind: .home, point: point(37.5, 127.0))
        let school = FrequentPlace(kind: .school, point: point(37.52, 127.02))
        let unset = FrequentPlace(kind: .academy) // 위치 없는 기본 장소는 도감에 넣지 않는다.
        let tower = try XCTUnwrap(MapHomeLandmarkSites.site(for: "kr.namsan"))
        let stays = [
            stay(home.stablePlaceKey, start: 0),
            // 남산 서울타워 반경 안의 일반 머묾.
            stay("place-namsan", start: 4 * 3_600, at: point(tower.latitude + 0.001, tower.longitude)),
            // 경복궁에서 5 km 떨어진 곳은 세지 않는다.
            stay("place-far", start: 6 * 3_600, at: point(37.6250, 126.9770)),
        ]
        let state = MapHomePlaceBookState.make(frequentPlaces: [home, school, unset], stays: stays, language: .korean)
        XCTAssertEqual(state.registered.map(\.id), [home.stablePlaceKey, school.stablePlaceKey])
        XCTAssertEqual(state.landmarks.count, MapHomeLandmarkCatalog.candidates.count)
        XCTAssertEqual(state.stampedCount, 2)
        XCTAssertEqual(state.remainingCount, 1 + MapHomeLandmarkCatalog.candidates.count - 1)
        XCTAssertTrue(state.registered[0].isVisited)
        XCTAssertFalse(state.registered[1].isVisited)
        XCTAssertEqual(state.registered[0].stamp.glyph, "家")
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
