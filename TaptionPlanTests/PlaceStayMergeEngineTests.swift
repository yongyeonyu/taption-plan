import XCTest
@testable import TaptionPlan

/// 같은 자리 이어진 체류 합치기(RVW1030A01).
final class PlaceStayMergeEngineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func stay(
        north meters: Double = 0,
        from minute: Double,
        to endMinute: Double,
        key: String = "37.5000,127.0000",
        name: String = "자동 감지 장소",
        floor: Int? = nil,
        confirmed: Bool = false
    ) -> PlaceStay {
        PlaceStay(
            placeKey: key,
            displayName: name,
            floor: floor,
            span: TimeSpan(start: start.addingTimeInterval(minute * 60), end: start.addingTimeInterval(endMinute * 60)),
            confidence: .medium,
            point: GeoPoint(latitude: 37.5 + meters / 111_320, longitude: 127, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 5),
            isConfirmed: confirmed
        )
    }

    func testJitterSplitStayWithinFiftyMetersMerges() {
        let merged = PlaceStayMergeEngine.merging([
            stay(from: 0, to: 30, key: "a"),
            stay(north: 40, from: 35, to: 70, key: "b"),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.span, TimeSpan(start: start, end: start.addingTimeInterval(70 * 60)))
    }

    func testRegisteredPlaceWinsOverUnnamed() {
        let merged = PlaceStayMergeEngine.merging([
            stay(from: 0, to: 20, key: "37.5001,127.0000"),
            stay(north: 20, from: 22, to: 60, key: "frequent-home", name: "집"),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.placeKey, "frequent-home")
        XCTAssertEqual(merged.first?.displayName, "집")
        XCTAssertEqual(merged.first?.span.start, start)
    }

    func testNamedPlaceWinsOverUnnamedEvenWhenShorter() {
        let merged = PlaceStayMergeEngine.merging([
            stay(from: 0, to: 60, key: "x"),
            stay(north: 10, from: 62, to: 75, key: "y", name: "카페"),
        ])
        XCTAssertEqual(merged.map(\.displayName), ["카페"])
    }

    func testFarOrLateStaysStaySeparate() {
        XCTAssertEqual(PlaceStayMergeEngine.merging([
            stay(from: 0, to: 30), stay(north: 80, from: 32, to: 60),
        ]).count, 2)
        XCTAssertEqual(PlaceStayMergeEngine.merging([
            stay(from: 0, to: 30), stay(north: 10, from: 41, to: 60),
        ]).count, 2)
    }

    func testConfirmedPlaceIsNeverMergedAway() {
        let confirmed = stay(from: 0, to: 30, key: "c", name: "회의실", confirmed: true)
        let merged = PlaceStayMergeEngine.merging([confirmed, stay(north: 5, from: 31, to: 60, key: "d")])
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains(confirmed))
    }

    func testDifferentNamesRegisteredPlacesOrFloorsStaySeparate() {
        XCTAssertEqual(PlaceStayMergeEngine.merging([
            stay(from: 0, to: 30, key: "a", name: "카페"), stay(north: 10, from: 31, to: 60, key: "b", name: "서점"),
        ]).count, 2)
        XCTAssertEqual(PlaceStayMergeEngine.merging([
            stay(from: 0, to: 30, key: "frequent-a", name: "집"), stay(north: 10, from: 31, to: 60, key: "frequent-b", name: "작업실"),
        ]).count, 2)
        XCTAssertEqual(PlaceStayMergeEngine.merging([
            stay(from: 0, to: 30, floor: 2), stay(north: 5, from: 31, to: 60, floor: 5),
        ]).count, 2)
    }
}
