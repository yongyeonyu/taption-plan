import XCTest
@testable import TaptionPlan
import TaptionPlanCore

/// TGT1118A01: 지난 톨게이트로 통행료 알아내기. 영업소·좌표는 모두 가짜다(위도 10·경도 20 언저리).
@MainActor
final class LedgerTollGateTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_794_355_200) // 2026-11-11(수) 00:00 UTC
    private func at(_ hour: Double) -> Date { base.addingTimeInterval(hour * 3_600) }
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let north = TollUnit(code: "901", name: "가짜북", route: "가짜선", lat: 10.0003, lng: 20.0)
    private let south = TollUnit(code: "902", name: "가짜남", route: "가짜선", lat: 10.1, lng: 20.0002)
    /// 길에서 약 110m 옆(지나긴 했지만 가깝지는 않음). 두 위치 사이에 있어 선으로 이어야 찾는다.
    private let side = TollUnit(code: "903", name: "가짜옆", route: "가짜선", lat: 10.045, lng: 20.001)
    private let far = TollUnit(code: "904", name: "가짜먼", route: "가짜선", lat: 10.05, lng: 20.01)
    private let away = TollUnit(code: "905", name: "가짜밖", route: "가짜선", lat: 30, lng: 40)

    /// 경도 20 위를 위도 10.00 → 10.10으로 1분마다 약 1.1km씩 달린다(8:00 출발).
    private func fixes(accuracy: Double = 10, start: Double = 8) -> [LedgerTollGate.Fix] {
        (0...10).map { LedgerTollGate.Fix(at: at(start + Double($0) / 60), latitude: 10 + Double($0) * 0.01, longitude: 20, accuracy: accuracy) }
    }

    private func pass(_ unit: TollUnit, _ hour: Double, meters: Double = 20, accuracy: Double = 10) -> LedgerTollGate.Pass {
        .init(code: unit.code, name: unit.name, at: at(hour), meters: meters, accuracy: accuracy)
    }

    // MARK: 판정

    func testFindsPassedPlazasInOrderIncludingBetweenSparseFixes() {
        let passes = LedgerTollGate.passes(units: [south, far, side, away, north], fixes: fixes().reversed())
        XCTAssertEqual(passes.map(\.code), ["901", "903", "902"], "먼 곳·범위 밖은 빼고 시각순")
        XCTAssertTrue(passes[0].isPrecise)
        XCTAssertFalse(passes[1].isPrecise, "110m 옆은 지났지만 확실하지 않다")
        XCTAssertEqual(passes[1].meters, 110, accuracy: 5)
        XCTAssertEqual(passes[1].at.timeIntervalSince(at(8)), 4.5 * 60, accuracy: 5, "두 위치 사이 가장 가까운 때")
        XCTAssertTrue(passes[2].isPrecise)

        let trip = LedgerTollGate.trip(passes)
        XCTAssertEqual(trip?.kind, .closed(entry: passes[0], exit: passes[2]))
        XCTAssertEqual(trip?.codes.from, "901")
        XCTAssertEqual(trip?.codes.to, "902")
        XCTAssertEqual(trip?.middlePrecise, false)
        XCTAssertEqual(trip?.isPrecise, true)
    }

    func testSparseFixesFarApartAreNotJoined() {
        let gappy = [LedgerTollGate.Fix(at: at(8), latitude: 10.04, longitude: 20, accuracy: 10),
                     LedgerTollGate.Fix(at: at(8.1), latitude: 10.05, longitude: 20, accuracy: 10)]
        XCTAssertTrue(LedgerTollGate.passes(units: [side], fixes: gappy).isEmpty, "6분 넘게 끊긴 위치는 잇지 않는다")
    }

    func testSingleMainlinePlazaAndUncertainShapes() {
        let single = LedgerTollGate.trip([pass(north, 8)])
        XCTAssertEqual(single?.kind, .single(pass(north, 8)))
        XCTAssertEqual(single?.codes.from, "901")
        XCTAssertEqual(single?.codes.to, "901", "본선 영업소는 같은 코드로 묻는다")
        XCTAssertNil(LedgerTollGate.trip([]))

        let middle = LedgerTollGate.trip([pass(north, 8), pass(side, 8.1), pass(south, 8.2)])
        XCTAssertEqual(middle?.middlePrecise, true)
        XCTAssertEqual(middle?.isPrecise, false, "사이에 또 가까이 지난 영업소가 있으면 확인을 받는다")
        XCTAssertEqual(LedgerTollGate.trip([pass(north, 8, meters: 120), pass(south, 8.2)])?.isPrecise, false)
        XCTAssertEqual(LedgerTollGate.trip([pass(north, 8, accuracy: 70), pass(south, 8.2)])?.isPrecise, false)
        let rough = LedgerTollGate.passes(units: [north, south], fixes: fixes(accuracy: 70))
        XCTAssertEqual(rough.count, 2)
        XCTAssertFalse(rough.contains(where: \.isPrecise), "위치 오차가 크면 확실하지 않다")
    }

    // MARK: 요금

    func testReadsFareReplies() {
        func reply(_ rows: String) -> Data { Data("{\"from\":\"901\",\"to\":\"902\",\"car\":1,\"fares\":[\(rows)]}".utf8) }
        let row = { (normal: Int, to: String) in "{\"from\":\"901\",\"to\":\"\(to)\",\"normal\":\(normal),\"distanceKm\":13.5}" }
        XCTAssertEqual(LedgerTollGate.fare(reply(row(900, "902")), from: "901", to: "902"), .known(normal: 900, distanceKm: 13.5))
        XCTAssertEqual(LedgerTollGate.fare(reply(row(900, "902") + "," + row(900, "902")), from: "901", to: "902"), .known(normal: 900, distanceKm: 13.5))
        XCTAssertEqual(LedgerTollGate.fare(reply(row(900, "902") + "," + row(1_100, "902")), from: "901", to: "902"), .ambiguous(normal: 1_100, distanceKm: 13.5))
        XCTAssertEqual(LedgerTollGate.fare(reply(row(900, "999") + "," + row(0, "902")), from: "901", to: "902"), .missing, "다른 영업소·0원은 없는 것")
        XCTAssertNil(LedgerTollGate.fare(Data("oops".utf8), from: "901", to: "902"))
    }

    func testCommuteDiscountNeedsUnderTwentyKilometres() {
        XCTAssertEqual(LedgerTollGate.applied(at: at(8.5), distanceKm: 13, vehicle: .standard, isOffDay: false, calendar: utc), .init(rate: 0.2, reason: .commuteFifth))
        XCTAssertEqual(LedgerTollGate.applied(at: at(8.5), distanceKm: 25, vehicle: .standard, isOffDay: false, calendar: utc), .init(rate: 0, reason: .none))
        XCTAssertEqual(LedgerTollGate.applied(at: at(6), distanceKm: 25, vehicle: .compact, isOffDay: false, calendar: utc), .init(rate: 0.5, reason: .compact))
        XCTAssertEqual(LedgerTollGate.applied(at: at(8.5), distanceKm: nil, vehicle: .standard, isOffDay: false, calendar: utc), .init(rate: 0.2, reason: .commuteFifth), "거리를 모르면 시각만 본다")
    }

    // MARK: 표시와 넣기

    private func addition(_ trip: LedgerTollGate.Trip, _ fare: LedgerTollGate.Fare, vehicle: LedgerTollDiscount.Vehicle = .standard) -> LedgerTollGate.Addition? {
        LedgerTollGate.addition(trip: trip, fare: fare, vehicle: vehicle, isOffDay: { _ in false }, calendar: utc, language: .korean)
    }

    func testCertainClosedTripIsWrittenWithPlazasFareAndDiscount() throws {
        let trip = try XCTUnwrap(LedgerTollGate.trip([pass(north, 8.1), pass(south, 8.5)]))
        let made = try XCTUnwrap(addition(trip, .known(normal: 900, distanceKm: 13)))
        XCTAssertTrue(made.certain)
        XCTAssertEqual(made.entry.title, "가짜북 영업소 → 가짜남 영업소 통행료")
        XCTAssertEqual(made.entry.note, "지난 톨게이트로 자동 추가 · 가짜북 영업소 → 가짜남 영업소 · 정상요금 900원 · 출퇴근 할인 20%")
        XCTAssertEqual(made.entry.amount, 720)
        XCTAssertEqual(made.entry.occurredAt, at(8.5), "출구를 지난 때")
        XCTAssertEqual(made.entry.category, .transport)
        XCTAssertTrue(LedgerTollRepeat.isToll(made.entry))
        XCTAssertTrue(LedgerTollRepeat.isAuto(made.entry), "할인 든 금액이라 같은 길 규칙이 배우지 않는다")
        XCTAssertTrue(LedgerTollRepeat.learn(drives: [.init(from: "집", to: "회사", start: at(8), end: at(8.6))], entries: [made.entry], into: [:]).isEmpty)
        XCTAssertEqual(addition(trip, .known(normal: 900, distanceKm: 13), vehicle: .compact)?.entry.amount, 450)
    }

    func testUncertainCasesGoToReviewAndMissingFareFallsBack() throws {
        let closed = try XCTUnwrap(LedgerTollGate.trip([pass(north, 6.9), pass(south, 7.2)]))
        let edge = try XCTUnwrap(addition(closed, .known(normal: 900, distanceKm: 13)))
        XCTAssertFalse(edge.certain, "입구(50%)와 출구(20%) 시각의 할인이 다르다")
        XCTAssertEqual(edge.entry.amount, 720)
        XCTAssertEqual(addition(try XCTUnwrap(LedgerTollGate.trip([pass(north, 10), pass(south, 10.3, meters: 120)])), .known(normal: 900, distanceKm: 13))?.certain, false)
        XCTAssertEqual(addition(try XCTUnwrap(LedgerTollGate.trip([pass(north, 10), pass(south, 10.3)])), .ambiguous(normal: 1_100, distanceKm: 13))?.certain, false)
        XCTAssertNil(addition(closed, .missing), "요금이 없으면 같은 길 방식에 맡긴다")

        let single = try XCTUnwrap(addition(try XCTUnwrap(LedgerTollGate.trip([pass(north, 10)])), .known(normal: 900, distanceKm: 17.6)))
        XCTAssertTrue(single.certain)
        XCTAssertEqual(single.entry.title, "가짜북 영업소 통행료")
        XCTAssertEqual(single.entry.note, "지난 톨게이트로 자동 추가 · 가짜북 영업소 · 정상요금 900원")
        XCTAssertEqual(LedgerTollGate.plaza("가짜영업소", language: .korean), "가짜영업소")
        XCTAssertEqual(LedgerTollGate.plaza("가짜", language: .english), "가짜 toll plaza")
    }

    func testCandidatesKeepHandledPaidUnsettledAndUnmatchedDrivesOut() {
        var drive = LedgerTollRepeat.Drive(from: "집", to: "회사", start: at(8), end: at(8.6))
        drive.passes = [pass(north, 8.1), pass(south, 8.5)]
        XCTAssertEqual(LedgerTollGate.candidates(drives: [drive], existing: [], handled: [], now: at(10)).map(\.drive.key), [drive.key])
        XCTAssertTrue(LedgerTollGate.candidates(drives: [drive], existing: [], handled: [drive.key], now: at(10)).isEmpty, "지운 것도 다시 넣지 않는다")
        XCTAssertTrue(LedgerTollGate.candidates(drives: [drive], existing: [], handled: [], now: at(8.65)).isEmpty, "도착 10분 전")
        var paid = LedgerEntry(occurredAt: at(8.6), amount: 900, title: "통행료")
        paid.category = .transport
        XCTAssertTrue(LedgerTollGate.candidates(drives: [drive], existing: [paid], handled: [], now: at(10)).isEmpty, "그 무렵 통행료가 이미 있다")
        let plain = LedgerTollRepeat.Drive(from: "집", to: "마트", start: at(8), end: at(8.6))
        XCTAssertTrue(LedgerTollGate.candidates(drives: [plain], existing: [], handled: [], now: at(10)).isEmpty, "영업소를 못 찾으면 같은 길 방식")
    }

    func testFragmentsMergeTheirPassesOnce() {
        var first = LedgerTollRepeat.Drive(from: "회사", to: "집", start: at(19), end: at(19.3))
        first.passes = [pass(north, 19.1, meters: 60)]
        var second = LedgerTollRepeat.Drive(from: "회사", to: "집", start: at(19.35), end: at(19.8))
        second.passes = [pass(north, 19.36, meters: 20), pass(south, 19.7)]
        let merged = LedgerTollRepeat.merged([second, first])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].passes.map(\.code), ["901", "902"])
        XCTAssertEqual(merged[0].passes[0].meters, 20, "같은 영업소는 더 가까웠던 것")
    }

    func testRouteUsesOnlyPreciseReadingsForPasses() {
        func readings(noisyEnds: Bool) -> [SensorReading] {
            fixes().enumerated().map { index, fix in
                let rough = noisyEnds && index == 10
                var reading = SensorReading(timestamp: fix.at, point: GeoPoint(latitude: fix.latitude, longitude: fix.longitude, altitude: 0,
                                                                             horizontalAccuracy: rough ? 300 : 10, verticalAccuracy: 10))
                if noisyEnds, index == 0 { reading.locationFixQuality = .approximate }
                return reading
            }
        }
        let drive = LedgerTollRepeat.Drive(from: "집", to: "회사", start: at(7.9), end: at(8.5))
        XCTAssertEqual(LedgerTollRepeatRunner.withRoute(drive, readings: readings(noisyEnds: false), units: [north, south]).passes.map(\.code), ["901", "902"])
        XCTAssertTrue(LedgerTollRepeatRunner.withRoute(drive, readings: readings(noisyEnds: true), units: [north, south]).passes.isEmpty,
                      "대략 위치·오차 300m 위치로는 지났다고 보지 않는다")
        XCTAssertTrue(LedgerTollRepeatRunner.withRoute(drive, readings: readings(noisyEnds: false)).passes.isEmpty, "목록이 없으면 찾지 않는다")
    }

    func testUnitListDecodingIsBounded() {
        let one = "{\"code\":\"901\",\"name\":\"가짜북\",\"route\":\"가짜선\",\"routeNo\":\"999\",\"lat\":10.1,\"lng\":20.1}"
        XCTAssertEqual(TollUnitStore.decode(Data("{\"units\":[\(one)],\"count\":1}".utf8)), [TollUnit(code: "901", name: "가짜북", route: "가짜선", lat: 10.1, lng: 20.1)])
        XCTAssertNil(TollUnitStore.decode(Data("{\"units\":[]}".utf8)))
        XCTAssertNil(TollUnitStore.decode(Data("{\"error\":\"ex_key_missing\"}".utf8)))
        let many = Array(repeating: one, count: TollUnitStore.maximumUnits + 5).joined(separator: ",")
        XCTAssertEqual(TollUnitStore.decode(Data("{\"units\":[\(many)]}".utf8))?.count, TollUnitStore.maximumUnits)
    }
}

/// KDR1118A01: 도로공사로 모를 때만 카카오 길찾기. 좌표는 모두 가짜다.
@MainActor
final class LedgerTollKakaoTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_794_355_200)
    private func at(_ hour: Double) -> Date { base.addingTimeInterval(hour * 3_600) }
    private func points(_ count: Int, start: Double = 18) -> [LedgerTollKakao.Point] {
        (0..<count).map { .init(at: at(start + Double($0) / 60), latitude: 10 + Double($0) * 0.01, longitude: 20) }
    }
    private func drive(cells: Int = 20, points count: Int = 30, from: String = "회사", to: String = "집") -> LedgerTollRepeat.Drive {
        var drive = LedgerTollRepeat.Drive(from: from, to: to, start: at(18), end: at(18.5))
        drive.cells = Set((0..<cells).map { "1000_\($0)" })
        drive.points = LedgerTollKakao.sampled(points(count))
        return drive
    }

    func testSamplesStartEndAndFiveBetween() throws {
        let all = points(40)
        let picked = LedgerTollKakao.sampled(all.shuffled())
        XCTAssertEqual(picked.count, 7)
        XCTAssertEqual(picked.first, all.first)
        XCTAssertEqual(picked.last, all.last)
        XCTAssertEqual(LedgerTollKakao.sampled(Array(all.prefix(4))).count, 4, "적으면 그대로")
        let body = try XCTUnwrap(LedgerTollKakao.body(all))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((object["waypoints"] as? [Any])?.count, 5, "경유지는 최대 5개")
        XCTAssertEqual(Set(object.keys), ["origin", "destination", "waypoints"], "점 말고는 보내지 않는다")
        XCTAssertNil(LedgerTollKakao.body(Array(all.prefix(1))))
    }

    func testOnlyUnhandledLongDrivesWithoutTollAreAsked() {
        let long = drive()
        let now = at(20)
        XCTAssertEqual(LedgerTollKakao.candidates(drives: [long], existing: [], handled: [], asked: [], now: now).count, 1)
        XCTAssertTrue(LedgerTollKakao.candidates(drives: [long], existing: [], handled: [long.key], asked: [], now: now).isEmpty, "다른 방식으로 넣었다")
        XCTAssertTrue(LedgerTollKakao.candidates(drives: [long], existing: [], handled: [], asked: [long.key], now: now).isEmpty, "이미 물었다")
        XCTAssertTrue(LedgerTollKakao.candidates(drives: [drive(cells: 3)], existing: [], handled: [], asked: [], now: now).isEmpty, "동네 길")
        XCTAssertTrue(LedgerTollKakao.candidates(drives: [drive(points: 1)], existing: [], handled: [], asked: [], now: now).isEmpty, "위치가 모자람")
        XCTAssertTrue(LedgerTollKakao.candidates(drives: [long], existing: [], handled: [], asked: [], now: at(18.55)).isEmpty, "도착 10분 전")
        var paid = LedgerEntry(occurredAt: at(18.4), amount: 3_000, title: "통행료")
        paid.category = .transport
        XCTAssertTrue(LedgerTollKakao.candidates(drives: [long], existing: [paid], handled: [], asked: [], now: now).isEmpty, "그 무렵 통행료가 있다")
    }

    func testEntryNamesHighwayAndIsAutoButNotLearned() throws {
        let route = try XCTUnwrap(LedgerTollKakao.decode(Data(#"{"found":true,"toll":6600,"distance":40000,"duration":2400,"roads":["가짜대로","가짜공항고속도로","가짜로"]}"#.utf8)))
        let entry = try XCTUnwrap(LedgerTollKakao.entry(drive: drive(), route: route, language: .korean))
        XCTAssertEqual(entry.title, "가짜공항고속도로 통행료")
        XCTAssertEqual(entry.amount, 6_600)
        XCTAssertEqual(entry.note, "카카오 길찾기로 자동 추가 · 회사 → 집 · 카카오 예상 통행료")
        XCTAssertTrue(LedgerTollRepeat.isToll(entry))
        XCTAssertTrue(LedgerTollRepeat.isAuto(entry), "할인 든 예상 금액이라 같은 길 규칙이 배우지 않는다")
        XCTAssertNil(LedgerTollKakao.entry(drive: drive(), route: .init(found: true, toll: 0, roads: []), language: .korean), "통행료 없는 길")
        XCTAssertNil(LedgerTollKakao.entry(drive: drive(), route: .init(found: false, toll: 0, roads: []), language: .korean))
        XCTAssertEqual(LedgerTollKakao.entry(drive: drive(), route: .init(found: true, toll: 900, roads: ["가짜로"]), language: .korean)?.title, "고속도로 통행료")
        XCTAssertNil(LedgerTollKakao.decode(Data(#"{"error":"unavailable"}"#.utf8)))

        // 확인해 남긴 카카오 통행료로 같은 길 규칙의 길 모양을 배우지 않는다(다른 길일 수 있다).
        let rules = ["회사→집": LedgerTollRepeat.Rule(amount: 900, currency: "KRW", title: "통행료 (퇴근)", learnedAt: at(0), base: 900)]
        var accepted = entry
        accepted.occurredAt = at(18.5)
        XCTAssertNil(LedgerTollRepeat.learn(drives: [drive()], entries: [accepted], into: rules)["회사→집"]?.route)
    }

    func testMergedFragmentsKeepSampledPoints() {
        var first = LedgerTollRepeat.Drive(from: "회사", to: "집", start: at(18), end: at(18.2))
        first.points = LedgerTollKakao.sampled(points(10))
        var second = LedgerTollRepeat.Drive(from: "회사", to: "집", start: at(18.25), end: at(18.5))
        second.points = LedgerTollKakao.sampled(points(10, start: 18.25))
        let merged = LedgerTollRepeat.merged([first, second])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].points.count, 7)
        XCTAssertEqual(merged[0].points.first?.at, at(18))
        XCTAssertEqual(merged[0].points.last, second.points.last)
    }
}
