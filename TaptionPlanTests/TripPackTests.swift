import XCTest
@testable import TaptionPlan
import TaptionPlanStore

/// ARCH1120A01 2단계: 도시 팩 읽기·거르기·확인일·일정 칸 변환. 도시·장소는 전부 시험용 가짜다.
final class TripPackTests: XCTestCase {
    private func json(items: String, schema: Int = 1, format: String = "bokki-trip-pack") -> Data {
        Data(#"{"format":"\#(format)","schema":\#(schema),"city":"fixture-city","version":2,"items":[\#(items)]}"#.utf8)
    }

    private func item(_ id: String, _ category: String, lat: Double = 10, lng: Double = 20, checkedAt: String = "2026-11-01", name: String = "예시") -> String {
        #"{"id":"\#(id)","category":"\#(category)","name":"Ex","nameKo":"\#(name)","area":"예시구","lat":\#(lat),"lng":\#(lng),"tags":["점심"],"note":"시험용","source":"seed","checkedAt":"\#(checkedAt)","checkedBy":"대표"}"#
    }

    func testReadsAPackAndDropsUnknownCategoriesBadCoordinatesAndDuplicates() throws {
        let data = json(items: [item("a", "restaurant"), item("b", "unknown_kind"), item("c", "sight", lat: 123), item("a", "cafe"), item("d", "stay")].joined(separator: ","))
        let pack = try XCTUnwrap(TripPackReader.decode(data))
        XCTAssertEqual(pack.items.map(\.id), ["a", "d"], "모르는 카테고리·범위 밖 좌표·겹친 id는 뺀다")
        XCTAssertEqual(pack.version, 2)
    }

    func testRefusesWrongFormatSchemaEmptyAndOversizedPacks() {
        XCTAssertNil(TripPackReader.decode(json(items: item("a", "stay"), schema: 2)))
        XCTAssertNil(TripPackReader.decode(json(items: item("a", "stay"), format: "other")))
        XCTAssertNil(TripPackReader.decode(json(items: "")), "빈 팩은 쓰지 않는다")
        XCTAssertNil(TripPackReader.decode(Data("not json".utf8)))
        XCTAssertNil(TripPackReader.decode(Data(count: TripPackReader.maximumBytes + 1)))
    }

    func testHospitalAndPharmacyAreSafetyInfoAndGoStaleAfterNinetyDays() throws {
        XCTAssertTrue(TripPackCategory.hospital.isSafetyInfo)
        XCTAssertTrue(TripPackCategory.pharmacy.isSafetyInfo)
        XCTAssertFalse(TripPackCategory.restaurant.isSafetyInfo)
        let pack = try XCTUnwrap(TripPackReader.decode(json(items: item("h", "hospital", checkedAt: "2026-08-01"))))
        let now = ISO8601DateFormatter().date(from: "2026-11-21T00:00:00Z")!
        XCTAssertTrue(TripPackReader.isStale(pack.items[0], now: now), "112일 전 확인은 오래된 정보")
        let fresh = try XCTUnwrap(TripPackReader.decode(json(items: item("h", "hospital", checkedAt: "2026-10-30"))))
        XCTAssertFalse(TripPackReader.isStale(fresh.items[0], now: now))
        var broken = fresh.items[0]; broken.checkedAt = "not-a-date"
        XCTAssertTrue(TripPackReader.isStale(broken, now: now), "날짜를 못 읽으면 오래된 것으로 본다")
    }

    func testFilterByCategoryAndText() throws {
        let pack = try XCTUnwrap(TripPackReader.decode(json(items: [item("a", "restaurant", name: "라멘집"), item("b", "sight", name: "공원"), item("c", "restaurant", name: "우동집")].joined(separator: ","))))
        XCTAssertEqual(TripPackReader.filter(pack.items, category: .restaurant).map(\.id), ["a", "c"])
        XCTAssertEqual(TripPackReader.filter(pack.items, query: "라멘").map(\.id), ["a"])
        XCTAssertEqual(TripPackReader.filter(pack.items, category: .sight, query: "라멘").count, 0)
        XCTAssertEqual(TripPackReader.filter(pack.items, query: "점심").count, 3, "태그도 찾는다")
    }

    func testPlacementKeepsNameCoordinatesAndPackReference() throws {
        let pack = try XCTUnwrap(TripPackReader.decode(json(items: item("a", "restaurant", lat: 10.5, lng: 20.5, name: "예시 식당"))))
        let placement = try XCTUnwrap(TripPackPlacement.make(pack.items[0], in: pack))
        XCTAssertEqual(placement.kind, "meal")
        XCTAssertEqual(placement.title, "예시 식당")
        XCTAssertEqual(placement.place.latitude, 10.5)
        XCTAssertEqual(placement.source, "pack")
        XCTAssertEqual(placement.packID, "fixture-city.v2")
        let ref = TravelPackRef(city: placement.city, packID: placement.packID, itemID: placement.itemID)
        XCTAssertEqual(ref, TravelPackRef(city: "fixture-city", packID: "fixture-city.v2", itemID: "a"))
    }

    func testEveryCategoryMapsToARealItemKind() {
        let kinds = Set(TripImportItem.Kind.allCases.map(\.rawValue))
        for category in TripPackCategory.allCases { XCTAssertTrue(kinds.contains(category.itemKind), category.rawValue) }
    }
}
