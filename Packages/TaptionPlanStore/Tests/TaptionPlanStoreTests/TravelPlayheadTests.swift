import XCTest
@testable import TaptionPlanStore

final class TravelPlayheadTests: XCTestCase {
    private let stops = [
        TravelPlayhead.Stop(id: "a", startMinute: 540, endMinute: 600, longitude: 130.0, latitude: 33.0),
        TravelPlayhead.Stop(id: "b", startMinute: 660, endMinute: 720, longitude: 131.0, latitude: 34.0),
        TravelPlayhead.Stop(id: "c", startMinute: 780, endMinute: 840, longitude: 130.5, latitude: 34.0),
    ]

    func testStaysInsideItemsAndMovesBetweenThem() throws {
        XCTAssertEqual(TravelPlayhead.position(at: 300, stops: stops)?.stopID, "a", "첫 일정 전에는 첫 곳")
        XCTAssertEqual(TravelPlayhead.position(at: 570, stops: stops)?.stopID, "a")
        let moving = try XCTUnwrap(TravelPlayhead.position(at: 630, stops: stops))
        XCTAssertNil(moving.stopID)
        XCTAssertEqual(moving.longitude, 130.5, accuracy: 1e-9)
        XCTAssertEqual(moving.latitude, 33.5, accuracy: 1e-9)
        XCTAssertTrue(moving.facesEast)
        let back = try XCTUnwrap(TravelPlayhead.position(at: 765, stops: stops))
        XCTAssertEqual(back.longitude, 130.625, accuracy: 1e-9)
        XCTAssertFalse(back.facesEast, "서쪽으로 갈 때는 왼쪽을 본다")
        XCTAssertEqual(TravelPlayhead.position(at: 1_200, stops: stops)?.stopID, "c", "마지막 일정 뒤에는 마지막 곳")
        XCTAssertNil(TravelPlayhead.position(at: 600, stops: []))
    }

    func testBackToBackAndOverlappingItems() {
        let tight = [
            TravelPlayhead.Stop(id: "a", startMinute: 540, endMinute: 720, longitude: 1, latitude: 1),
            TravelPlayhead.Stop(id: "b", startMinute: 600, endMinute: 630, longitude: 2, latitude: 2),
            TravelPlayhead.Stop(id: "c", startMinute: 720, endMinute: 780, longitude: 3, latitude: 3),
        ]
        XCTAssertEqual(TravelPlayhead.position(at: 610, stops: tight)?.stopID, "a", "겹치면 먼저 시작한 일정")
        XCTAssertEqual(TravelPlayhead.position(at: 720, stops: tight)?.stopID, "a")
        XCTAssertEqual(TravelPlayhead.position(at: 750, stops: tight)?.stopID, "c")
        XCTAssertEqual(TravelPlayhead.startMinute(nowMinute: 615, firstStartMinute: 540), 615)
        XCTAssertEqual(TravelPlayhead.startMinute(nowMinute: nil, firstStartMinute: 530), 530)
        XCTAssertEqual(TravelPlayhead.startMinute(nowMinute: nil, firstStartMinute: nil), 540)
    }

    func testFollowsTheRouteByDistanceWhenThereIsOne() throws {
        // a(130,33) → 모퉁이(130,34) → b(131,34): 곧은 선이 아니라 꺾인 길을 따라간다.
        let path = [SIMD2(130.0, 33.0), SIMD2(130.0, 34.0), SIMD2(131.0, 34.0)]
        let paths = [TravelPlayhead.legKey("a", "b"): path]
        let early = try XCTUnwrap(TravelPlayhead.position(at: 610, stops: stops, paths: paths))
        XCTAssertEqual(early.longitude, 130.0, accuracy: 1e-9, "처음에는 북쪽으로만 간다")
        XCTAssertGreaterThan(early.latitude, 33.0)
        let late = try XCTUnwrap(TravelPlayhead.position(at: 655, stops: stops, paths: paths))
        XCTAssertEqual(late.latitude, 34.0, accuracy: 1e-9, "모퉁이를 지나면 동쪽으로 간다")
        XCTAssertGreaterThan(late.longitude, 130.0)
        XCTAssertNil(TravelPlayhead.along([SIMD2(1.0, 1.0)], t: 0.5))
        let end = try XCTUnwrap(TravelPlayhead.along(path, t: 1))
        XCTAssertEqual(end.point, SIMD2(131.0, 34.0))
    }

    /// TVW1112A01: 일정 종류와 이동 수단에 맞는 동작.
    func testPosesFollowItemKindAndTransport() throws {
        XCTAssertEqual(TravelPlayhead.pose(kind: "meal", title: "라멘"), .eat)
        XCTAssertEqual(TravelPlayhead.pose(kind: "cafe", title: "카페"), .coffee)
        XCTAssertEqual(TravelPlayhead.pose(kind: "lodging", title: "체크인"), .sleep)
        XCTAssertEqual(TravelPlayhead.pose(kind: "sight", title: "성"), .sight)
        XCTAssertEqual(TravelPlayhead.pose(kind: "photo", title: "전망대"), .sight)
        XCTAssertEqual(TravelPlayhead.pose(kind: "shopping", title: "시장"), .shop)
        XCTAssertEqual(TravelPlayhead.pose(kind: "transfer", title: "니시테츠 전철 텐진→다자이후"), .subway)
        XCTAssertEqual(TravelPlayhead.pose(kind: "transfer", title: "노코노시마 페리"), .boat)
        XCTAssertEqual(TravelPlayhead.pose(kind: "transfer", title: "이동"), .car)
        XCTAssertEqual(TravelPlayhead.pose(kind: "flight", title: "KE657"), .airplane)
        XCTAssertEqual(TravelPlayhead.movingPose(fromKind: "sight", fromTitle: "신사", toKind: "meal", toTitle: "점심", meters: 600), .walk)
        XCTAssertEqual(TravelPlayhead.movingPose(fromKind: "sight", fromTitle: "신사", toKind: "meal", toTitle: "점심", meters: 9_000), .car)
        XCTAssertEqual(TravelPlayhead.movingPose(fromKind: "sight", fromTitle: "공원", toKind: "transfer", toTitle: "하카타역 버스", meters: 9_000), .bus)
        XCTAssertEqual(TravelPlayhead.movingPose(fromKind: "flight", fromTitle: "KE657", toKind: "lodging", toTitle: "호텔", meters: 30_000), .airplane)
        let moving = try XCTUnwrap(TravelPlayhead.position(at: 630, stops: stops))
        XCTAssertEqual(moving.fromID, "a")
        XCTAssertEqual(moving.toID, "b")
    }

    /// TVY1112A01: 가는 데 걸리는 시간보다 사이가 짧으면 빠듯한 일정.
    func testTightStopsNeedMoreTravelTimeThanTheGap() {
        // a 10:00 끝 → b 11:00 시작(사이 60분), b 12:00 끝 → c 13:00 시작(사이 60분).
        let minutes = [TravelPlayhead.legKey("a", "b"): 75, TravelPlayhead.legKey("b", "c"): 20]
        XCTAssertEqual(TravelPlayhead.tightStops(stops, travelMinutes: minutes), ["b"])
        XCTAssertEqual(TravelPlayhead.tightStops(stops, travelMinutes: [:]), [])
        XCTAssertEqual(TravelPlayhead.tightStops(stops, travelMinutes: [TravelPlayhead.legKey("a", "b"): 60]), [], "꼭 맞으면 빠듯하지 않다")
    }
}
