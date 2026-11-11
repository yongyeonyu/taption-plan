import XCTest
@testable import TaptionPlan
import CoreLocation
import SwiftUI
import TaptionPlanEngine

/// TRP1110A09: 여행 일정 상태 예약·계획·미정.
final class TripItemStatusTests: XCTestCase {
    private func plan(_ statuses: [String?]) throws -> TripImportPlan {
        let items = statuses.enumerated().map { index, status in
            let field = status.map { #","status":"\#($0)""# } ?? ""
            return #"{"id":"i\#(index)","type":"sight","title":"곳\#(index)","start":"2026-12-02T0\#(index):00+07:00"\#(field)}"#
        }
        return try TripImportParser.parse(#"{"format":"bokki-trip","version":1,"tripId":"t1","title":"t","items":[\#(items.joined(separator: ","))]}"#).get()
    }

    func testStatusParsesEachValueAndFallsBackToPlanned() throws {
        let parsed = try plan(["booked", "planned", "tentative", nil, "maybe", " BOOKED "])
        XCTAssertEqual(parsed.items.map(\.status), [.booked, .planned, .tentative, .planned, .planned, .booked])
        XCTAssertEqual(parsed.items.map(\.status.stored), ["booked", nil, "tentative", nil, nil, "booked"], "계획은 저장하지 않는다")
    }

    func testDiffCountsStatusChange() throws {
        let old = try plan(["booked", nil]).items.map {
            TravelTripItem(tripID: "t1", itemID: $0.id, kind: $0.kind.rawValue, title: $0.title, start: $0.start, end: $0.end,
                           startOffsetSeconds: 25_200, endOffsetSeconds: 25_200, planID: nil, status: $0.status.stored)
        }
        XCTAssertEqual(TripImportDiff.make(plan: try plan(["booked", "planned"]), existing: old), TripImportDiff(added: 0, changed: 0, removed: 0))
        XCTAssertEqual(TripImportDiff.make(plan: try plan(["tentative", nil]), existing: old), TripImportDiff(added: 0, changed: 1, removed: 0))
    }

    func testPlannedItemsEncodeWithoutStatusKey() throws {
        let stop = TravelPlanStop(id: UUID(), title: "왓 아룬", latitude: 13.74, longitude: 100.49, day: .now, order: 0, planID: nil,
                                  tripID: "t1", itemID: "i1", status: TripItemStatus.planned.stored)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(stop), as: UTF8.self).contains("status"))
        let old = #"{"id":"6E3B1A52-0C33-4C1D-9F11-2B0E7A9D4A10","title":"경복궁","latitude":37.5796,"longitude":126.977,"day":0,"order":0}"#
        XCTAssertNil(try JSONDecoder().decode(TravelPlanStop.self, from: Data(old.utf8)).status)
    }

    @MainActor
    func testImportCarriesStatusAndOneTapChangePersistsBoth() async throws {
        let model = AppModel(repository: InMemoryPlanRepository(), cloudSyncService: nil)
        await model.bootstrapLocalSnapshot()
        let text = #"{"format":"bokki-trip","version":1,"tripId":"t1","title":"t","items":[{"id":"a","type":"sight","title":"왓 아룬","start":"2026-12-02T09:00+07:00","status":"tentative","place":{"lat":13.74,"lng":100.49}}]}"#
        await model.applyTripImport(try TripImportParser.parse(text).get())
        let stop = try XCTUnwrap(model.settings.travelPlanStops.first)
        XCTAssertEqual(stop.status, "tentative")
        XCTAssertEqual(model.settings.travelTripItems?.first?.status, "tentative")
        model.setTravelStopStatus(.booked, stopID: stop.id)
        XCTAssertEqual(model.settings.travelPlanStops.first?.status, "booked")
        XCTAssertEqual(model.settings.travelTripItems?.first?.status, "booked")
        model.setTravelStopStatus(.planned, stopID: stop.id)
        XCTAssertNil(model.settings.travelTripItems?.first?.status)
        let segments = TravelTripRail.segments(model.settings.travelTripItems ?? [], day: stop.day)
        XCTAssertEqual(segments.first?.tripStatus, .planned)
    }

    // MARK: - REV1110A06

    private func stored(_ plan: TripImportPlan) -> [TravelTripItem] {
        plan.items.map {
            TravelTripItem(tripID: plan.tripID, itemID: $0.id, kind: $0.kind.rawValue, title: $0.title, start: $0.start, end: $0.end,
                           startOffsetSeconds: 25_200, endOffsetSeconds: 25_200, planID: nil, status: $0.status.stored)
        }
    }

    func testReimportWithoutStatusKeepsUserStatusAndExplicitStatusWins() throws {
        // 사용자가 i0은 예약, i1은 미정, i2는 예약으로 바꿔 둔 뒤 AI가 같은 여행을 다시 보낸다.
        let user = stored(try plan(["booked", "tentative", "booked", nil]))
        let incoming = try plan([nil, "maybe", "planned", "tentative"])
        XCTAssertEqual(incoming.items.map(\.hasExplicitStatus), [false, false, true, true])
        let kept = incoming.keepingUserStatus(from: user)
        XCTAssertEqual(kept.items.map(\.status), [.booked, .tentative, .planned, .tentative], "없거나 모르는 값은 지키고, 적어 보낸 값은 이긴다")
        XCTAssertEqual(TripImportDiff.make(plan: incoming, existing: user), TripImportDiff(added: 0, changed: 2, removed: 0))
    }

    func testKeepingUserStatusIgnoresOtherTripsAndNewItems() throws {
        var other = stored(try plan(["booked"]))
        other[0].tripID = "t2"
        XCTAssertEqual(try plan([nil, nil]).keepingUserStatus(from: other).items.map(\.status), [.planned, .planned])
        XCTAssertNil(TripItemStatus(explicit: nil))
        XCTAssertNil(TripItemStatus(explicit: "maybe"))
        XCTAssertEqual(TripItemStatus(explicit: " Tentative "), .tentative)
    }

    @MainActor
    func testReimportThroughModelKeepsBookedSetInApp() async throws {
        let model = AppModel(repository: InMemoryPlanRepository(), cloudSyncService: nil)
        await model.bootstrapLocalSnapshot()
        func json(_ status: String) -> String {
            #"{"format":"bokki-trip","version":1,"tripId":"t1","title":"t","items":[{"id":"a","type":"sight","title":"왓 아룬","start":"2026-12-02T09:00+07:00"\#(status),"place":{"lat":13.74,"lng":100.49}}]}"#
        }
        await model.applyTripImport(try TripImportParser.parse(json("")).get())
        model.setTravelStopStatus(.booked, stopID: try XCTUnwrap(model.settings.travelPlanStops.first).id)
        let again = try TripImportParser.parse(json("")).get().keepingUserStatus(from: model.settings.travelTripItems ?? [])
        XCTAssertEqual(model.tripImportDiff(for: again), TripImportDiff(added: 0, changed: 0, removed: 0))
        await model.applyTripImport(again)
        XCTAssertEqual(model.settings.travelTripItems?.first?.status, "booked")
        XCTAssertEqual(model.settings.travelPlanStops.first?.status, "booked")
        let explicit = try TripImportParser.parse(json(#","status":"planned""#)).get().keepingUserStatus(from: model.settings.travelTripItems ?? [])
        await model.applyTripImport(explicit)
        XCTAssertNil(model.settings.travelTripItems?.first?.status, "적어 보낸 계획은 예약을 덮는다")
    }

    @MainActor
    func testStatusChangesForItemsWithoutAPin() async throws {
        let model = AppModel(repository: InMemoryPlanRepository(), cloudSyncService: nil)
        await model.bootstrapLocalSnapshot()
        let text = #"{"format":"bokki-trip","version":1,"tripId":"t1","title":"t","items":[{"id":"a","type":"sight","title":"왓 아룬","start":"2026-12-02T09:00+07:00","place":{"lat":13.74,"lng":100.49}},{"id":"m1","type":"meal","title":"저녁","start":"2026-12-02T19:00+07:00","status":"tentative"},{"id":"s1","type":"sleep","title":"잠","start":"2026-12-02T23:00+07:00","place":{"lat":13.7,"lng":100.5}}]}"#
        await model.applyTripImport(try TripImportParser.parse(text).get())
        let items = try XCTUnwrap(model.settings.travelTripItems)
        let unpinned = TripUnpinnedItemStatusList.unpinned(items, stops: model.settings.travelPlanStops)
        XCTAssertEqual(unpinned.map(\.itemID), ["m1", "s1"], "좌표 없는 일정과 잠만 나온다")
        model.setTripItemStatus(.booked, tripID: "t1", itemID: "m1")
        model.setTripItemStatus(.tentative, tripID: "t1", itemID: "s1")
        let byID = Dictionary(uniqueKeysWithValues: (model.settings.travelTripItems ?? []).map { ($0.itemID, $0.status) })
        XCTAssertEqual(byID["m1"], "booked")
        XCTAssertEqual(byID["s1"], "tentative")
        XCTAssertEqual(byID["a"], .some(nil))
        XCTAssertNil(model.settings.travelPlanStops.first?.status, "다른 일정의 핀은 그대로다")
        // 일정 번호로 바꿔도 이어진 핀이 함께 바뀐다.
        model.setTripItemStatus(.booked, tripID: "t1", itemID: "a")
        XCTAssertEqual(model.settings.travelPlanStops.first?.status, "booked")
        let rail = TravelTripRail.segments(model.settings.travelTripItems ?? [], day: try XCTUnwrap(model.settings.travelPlanStops.first).day)
        XCTAssertTrue(rail.contains { $0.title == "저녁" && $0.tripStatus == .booked })
    }

    func testSpokenLabelAddsStatusOnlyWhenNotPlanned() {
        XCTAssertEqual(TripItemStatus.planned.spoken("왓 아룬", .korean), "왓 아룬")
        XCTAssertEqual(TripItemStatus.booked.spoken("왓 아룬", .korean), "왓 아룬, 예약됨")
        XCTAssertEqual(TripItemStatus.tentative.spoken("Wat Arun", .english), "Wat Arun, Tentative")
    }

    /// TAU1110A01: 빠듯한 이동과 항공편 도착 뒤 시간을 미리보기에서 알린다.
    func testTimingWarnings() throws {
        let json = #"""
        {"format":"bokki-trip","version":1,"tripId":"t2","title":"t","items":[
         {"id":"f","type":"flight","title":"ICN-BKK","start":"2026-12-02T08:00+09:00","end":"2026-12-02T12:00+07:00"},
         {"id":"a","type":"sight","title":"왕궁","start":"2026-12-02T12:30+07:00","end":"2026-12-02T14:00+07:00","place":{"lat":13.7500,"lng":100.4913}},
         {"id":"b","type":"meal","title":"짜뚜짝","start":"2026-12-02T14:10+07:00","end":"2026-12-02T15:00+07:00","place":{"lat":13.7999,"lng":100.5500}},
         {"id":"c","type":"cafe","title":"근처 카페","start":"2026-12-02T15:10+07:00","place":{"lat":13.8000,"lng":100.5510}}
        ]}
        """#
        let plan = try TripImportParser.parse(json).get()
        let warnings = TripImportTimingCheck.warnings(plan.items)
        XCTAssertEqual(warnings["a"], .afterFlight(needMinutes: 60))
        guard case let .tightMove(need) = warnings["b"] else { return XCTFail("\(warnings)") }
        XCTAssertGreaterThan(need, 10)
        XCTAssertNil(warnings["c"], "100m 남짓 걷기는 10분이면 된다")
        let stay = try TripImportParser.parse(#"""
        {"format":"bokki-trip","version":1,"tripId":"t3","title":"t","items":[
         {"id":"h","type":"lodging","title":"호텔","start":"2026-12-02T15:00+07:00","end":"2026-12-03T11:00+07:00","place":{"lat":13.75,"lng":100.49}},
         {"id":"d","type":"meal","title":"저녁","start":"2026-12-02T19:00+07:00","place":{"lat":13.80,"lng":100.55}}
        ]}
        """#).get()
        XCTAssertTrue(TripImportTimingCheck.warnings(stay.items).isEmpty, "a stay that spans dinner is not a tight move")
    }
}

/// TAU1111A01: 가져온 여행의 대중교통 구간 예상 요금, 항공편 위치를 비우면 도착 공항 좌표.
final class TravelFareAndAirportTests: XCTestCase {
    private let gangnam = CLLocationCoordinate2D(latitude: 37.498, longitude: 127.028)
    private let seoulStation = CLLocationCoordinate2D(latitude: 37.555, longitude: 126.972)

    func testCapitalAreaTransitUsesTableAndOtherCasesAreNil() throws {
        XCTAssertNotNil(FareCalculator.bundled, "요금표가 앱 번들에서 읽혀야 한다")
        XCTAssertEqual(TravelFareEstimate.won(from: gangnam, to: seoulStation, mode: "transit"), 1_550)
        XCTAssertEqual(TravelFareEstimate.won(from: gangnam, to: seoulStation, mode: "bus"), 1_500)
        let far = CLLocationCoordinate2D(latitude: 37.70, longitude: 127.20)
        XCTAssertGreaterThan(try XCTUnwrap(TravelFareEstimate.won(from: gangnam, to: far, mode: "subway")), 1_550)
        let daegu = (CLLocationCoordinate2D(latitude: 35.87, longitude: 128.60), CLLocationCoordinate2D(latitude: 35.88, longitude: 128.63))
        XCTAssertEqual(TravelFareEstimate.won(from: daegu.0, to: daegu.1, mode: "transit"), 1_500)
        XCTAssertNil(TravelFareEstimate.won(from: gangnam, to: seoulStation, mode: "walk"))
        XCTAssertNil(TravelFareEstimate.won(from: gangnam, to: daegu.0, mode: "transit"), "지역이 다르면 요금표 밖")
        let bangkok = CLLocationCoordinate2D(latitude: 13.74, longitude: 100.49)
        XCTAssertNil(TravelFareEstimate.won(from: bangkok, to: CLLocationCoordinate2D(latitude: 13.75, longitude: 100.53), mode: "transit"))
    }

    func testImportedPlanShowsFareOnTheTransitItemOnly() throws {
        let json = #"""
        {"format":"bokki-trip","version":1,"tripId":"t","title":"서울","items":[
        {"id":"a","type":"sight","title":"강남","start":"2026-12-02T09:00+09:00","end":"2026-12-02T10:00+09:00","place":{"name":"강남","lat":37.498,"lng":127.028}},
        {"id":"b","type":"sight","title":"서울역","start":"2026-12-02T11:00+09:00","place":{"name":"서울역","lat":37.555,"lng":126.972},"travelFromPrevious":{"mode":"transit","minutes":25}},
        {"id":"c","type":"meal","title":"점심","start":"2026-12-02T13:00+09:00","place":{"name":"남대문","lat":37.559,"lng":126.977},"travelFromPrevious":{"mode":"walk","minutes":10}}
        ]}
        """#
        let plan = try TripImportParser.parse(json).get()
        XCTAssertEqual(TravelFareEstimate.fares(plan.items), ["b": 1_550])
    }

    func testFlightWithoutCoordinateUsesArrivalAirport() throws {
        let json = #"""
        {"format":"bokki-trip","version":1,"tripId":"t","title":"도쿄","items":[
        {"id":"f","type":"flight","title":"인천 → 나리타","start":"2026-12-02T09:00+09:00","end":"2026-12-02T11:30+09:00","place":{"name":"나리타","lat":null,"lng":null},"flight":{"number":"KE701","fromAirport":"ICN","toAirport":"nrt"}},
        {"id":"s","type":"sight","title":"아사쿠사","start":"2026-12-02T14:00+09:00"}
        ]}
        """#
        let items = try TripImportParser.parse(json).get().items
        XCTAssertEqual(try XCTUnwrap(items.first { $0.id == "f" }?.coordinate?.latitude), 35.77, accuracy: 0.01)
        XCTAssertNil(items.first { $0.id == "s" }?.coordinate, "항공편이 아니면 공항표로 채우지 않는다")
        XCTAssertNil(TravelAirports.coordinate("XXX"))
    }

    /// TRP1110A01: AI 좌표가 지도 검색과 1km 넘게 다르면 알리고, 항공편·잠은 확인하지 않는다.
    func testCoordinateMismatchNeedsMoreThanOneKilometre() throws {
        let ai = CLLocationCoordinate2D(latitude: 37.5796, longitude: 126.9770)
        XCTAssertNil(TripImportCoordinateCheck.mismatch(ai: ai, searched: CLLocationCoordinate2D(latitude: 37.5830, longitude: 126.9770)))
        XCTAssertNil(TripImportCoordinateCheck.mismatch(ai: ai, searched: nil))
        let far = try XCTUnwrap(TripImportCoordinateCheck.mismatch(ai: ai, searched: CLLocationCoordinate2D(latitude: 37.5900, longitude: 126.9770)))
        XCTAssertEqual(Double(far.meters), 1_156, accuracy: 10)
        let json = #"""
        {"format":"bokki-trip","version":1,"tripId":"t","title":"t","items":[
        {"id":"a","type":"sight","title":"경복궁","start":"2026-12-02T09:00+09:00","place":{"name":"경복궁","lat":37.5796,"lng":126.977}},
        {"id":"b","type":"sleep","title":"잠","start":"2026-12-02T23:00+09:00","place":{"name":"호텔","lat":37.56,"lng":126.98}},
        {"id":"c","type":"meal","title":"점심","start":"2026-12-02T12:00+09:00"}
        ]}
        """#
        let items = try TripImportParser.parse(json).get().items
        XCTAssertEqual(items.filter(TripImportCoordinateCheck.shouldCheck).map(\.id), ["a"])
    }
}

/// TRP1110A01 재생: 기록 없는 여행 날은 화랑이가 일정 핀을 시간 순서대로 따라간다.
final class TripPlaybackPathTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_796_000_000)

    private func stop(_ itemID: String, _ lat: Double, _ lng: Double, order: Int) -> TravelPlanStop {
        TravelPlanStop(id: UUID(), title: itemID, latitude: lat, longitude: lng, day: base, order: order, planID: nil, tripID: "t", itemID: itemID)
    }

    private func item(_ itemID: String, from: Double, to: Double) -> TravelTripItem {
        TravelTripItem(tripID: "t", itemID: itemID, kind: "sight", title: itemID, start: base.addingTimeInterval(from * 60),
                       end: base.addingTimeInterval(to * 60), startOffsetSeconds: 32_400, endOffsetSeconds: 32_400, planID: nil, status: nil)
    }

    func testStaysOnPinsAndMovesStraightBetweenThem() throws {
        // 순서 번호와 달리 시각 순서로 따라간다.
        let path = try XCTUnwrap(MapHomeTripPlaybackPath(
            stops: [stop("b", 37.60, 127.00, order: 0), stop("a", 37.50, 127.00, order: 1), stop("x", 1, 1, order: 2)],
            items: [item("a", from: 60, to: 120), item("b", from: 180, to: 240)]
        ))
        XCTAssertEqual(path.stops.count, 2, "시각을 모르는 핀은 뺀다")
        XCTAssertEqual(path.coordinate(at: base).latitude, 37.50, accuracy: 1e-9)
        XCTAssertEqual(path.coordinate(at: base.addingTimeInterval(90 * 60)).latitude, 37.50, accuracy: 1e-9)
        XCTAssertEqual(path.coordinate(at: base.addingTimeInterval(150 * 60)).latitude, 37.55, accuracy: 1e-9)
        XCTAssertEqual(path.coordinate(at: base.addingTimeInterval(600 * 60)).latitude, 37.60, accuracy: 1e-9)
        XCTAssertEqual(path.moves.count, 1)
        XCTAssertEqual(path.moves.first?.start, base.addingTimeInterval(120 * 60))
    }

    func testNoTimedStopsMeansNoPath() {
        XCTAssertNil(MapHomeTripPlaybackPath(stops: [stop("a", 37.5, 127, order: 0)], items: []))
    }
}

/// TVA1111A01: 여행 단위(이름·기간 저장), 일정 시각 고치기와 일상 계획·핀 동기, 가계부 여행 고르기.
final class TravelTripUnitTests: XCTestCase {
    private func json(title: String) -> String {
        #"{"format":"bokki-trip","version":1,"tripId":"t1","title":"\#(title)","items":["#
            + #"{"id":"a","type":"sight","title":"왓 아룬","start":"2026-12-02T09:00+07:00","end":"2026-12-02T10:00+07:00","place":{"lat":13.74,"lng":100.49}},"#
            + #"{"id":"b","type":"meal","title":"저녁","start":"2026-12-04T18:00+07:00"}]}"#
    }

    @MainActor
    private func importedModel() async throws -> AppModel {
        let model = AppModel(repository: InMemoryPlanRepository(), cloudSyncService: nil)
        await model.bootstrapLocalSnapshot()
        let applied = await model.applyTripImport(try TripImportParser.parse(json(title: "방콕")).get())
        XCTAssertTrue(applied)
        return model
    }

    @MainActor
    func testImportStoresTitleAndDaysAndKeepsUserChosenCurrency() async throws {
        let model = try await importedModel()
        var trip = try XCTUnwrap(model.settings.travelTrips?.first)
        XCTAssertEqual(trip, TravelTrip(id: "t1", title: "방콕", startDay: "2026-12-02", endDay: "2026-12-04"))
        trip.currencyCode = "THB"
        trip.countryCode = "TH"
        let saved = await model.saveTravelTrip(trip)
        XCTAssertTrue(saved)
        await model.applyTripImport(try TripImportParser.parse(json(title: "방콕 가족 여행")).get())
        XCTAssertEqual(model.settings.travelTrips, [TravelTrip(id: "t1", title: "방콕 가족 여행", startDay: "2026-12-02", endDay: "2026-12-04", countryCode: "TH", currencyCode: "THB")])
    }

    @MainActor
    func testMovingAndResizingAnItemKeepsDailyPlanAndPinInStep() async throws {
        let model = try await importedModel()
        let before = try XCTUnwrap(model.settings.travelTripItems?.first { $0.itemID == "a" })
        let planID = try XCTUnwrap(before.planID)

        let moved = await model.moveTripItem(tripID: "t1", itemID: "a", by: 3_600)
        XCTAssertTrue(moved)
        var item = try XCTUnwrap(model.settings.travelTripItems?.first { $0.itemID == "a" })
        XCTAssertEqual(item.start, before.start.addingTimeInterval(3_600))
        XCTAssertEqual(item.end, before.end.addingTimeInterval(3_600))
        var plan = try XCTUnwrap(model.snapshot.plans.first { $0.id == planID })
        XCTAssertEqual(plan.span.start, item.start, "일상 계획 기록이 같은 시각으로 따라온다")
        XCTAssertEqual(plan.span.end, item.end)

        let resized = await model.resizeTripItem(tripID: "t1", itemID: "a", endDelta: 1_800)
        XCTAssertTrue(resized)
        item = try XCTUnwrap(model.settings.travelTripItems?.first { $0.itemID == "a" })
        plan = try XCTUnwrap(model.snapshot.plans.first { $0.id == planID })
        XCTAssertEqual(item.end.timeIntervalSince(item.start), 5_400)
        XCTAssertEqual(plan.span.end, item.end)

        let tooShort = await model.resizeTripItem(tripID: "t1", itemID: "a", startDelta: 5_300)
        XCTAssertFalse(tooShort, "5분보다 짧아지면 바꾸지 않는다")
        XCTAssertEqual(model.settings.travelTripItems?.first { $0.itemID == "a" }, item)
        let missing = await model.moveTripItem(tripID: "t1", itemID: "없음", by: 60)
        XCTAssertFalse(missing)

        // 사흘 뒤로 옮기면 지도 핀 날짜가 따라가고 여행 기간이 늘어난다.
        let later = await model.moveTripItem(tripID: "t1", itemID: "a", by: 3 * 86_400)
        XCTAssertTrue(later)
        let stop = try XCTUnwrap(model.settings.travelPlanStops.first { $0.itemID == "a" })
        XCTAssertEqual(TravelPlanSchedule.dayKey(stored: stop.day), DateComponents(year: 2026, month: 12, day: 5))
        XCTAssertEqual(stop.order, 0)
        XCTAssertEqual(model.settings.travelTrips?.first?.endDay, "2026-12-05")
        XCTAssertEqual(model.settings.travelTrips?.first?.startDay, "2026-12-02", "기간은 늘리기만 한다")
    }

    @MainActor
    func testDayTripAndPastDayCanBecomeTripsAndBadRangeIsRejected() async throws {
        let model = AppModel(repository: InMemoryPlanRepository(), cloudSyncService: nil)
        await model.bootstrapLocalSnapshot()
        let bad = await model.saveTravelTrip(TravelTrip(id: "x", title: "거꾸로", startDay: "2026-11-09", endDay: "2026-11-08"))
        XCTAssertFalse(bad)
        let empty = await model.saveTravelTrip(TravelTrip(id: "", title: "번호 없음", startDay: "2026-11-08", endDay: "2026-11-08"))
        XCTAssertFalse(empty)
        XCTAssertNil(model.settings.travelTrips)
        let dayTrip = await model.saveTravelTrip(TravelTrip(id: "gapyeong", title: "가평", startDay: "2026-11-08", endDay: "2026-11-08"))
        XCTAssertTrue(dayTrip)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let onTheDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 15)))
        let today = try XCTUnwrap(model.travelTripEntries(now: onTheDay, calendar: calendar).first)
        XCTAssertTrue(today.isDayTrip)
        XCTAssertEqual(today.state, .active)
        XCTAssertEqual(today.dayNumber, 1)
        let nextDay = try XCTUnwrap(model.travelTripEntries(now: onTheDay.addingTimeInterval(86_400), calendar: calendar).first)
        XCTAssertEqual(nextDay.state, .past, "지난 날짜의 여행도 목록에 남는다")
    }

    @MainActor
    func testLedgerTripChoicesUseStoredTripNameAndDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 2, hour: 2)))
        let item = TravelTripItem(tripID: "t1", itemID: "a", kind: "sight", title: "왓 아룬", start: start, end: start.addingTimeInterval(3_600),
                                  startOffsetSeconds: 25_200, endOffsetSeconds: 25_200, planID: nil)
        XCTAssertEqual(LedgerBook.plannedTrips(stops: [], items: [item]).map(\.name), ["왓 아룬"], "저장한 여행이 없으면 예전처럼 첫 일정 이름")
        let trips = [
            TravelTrip(id: "t1", title: "방콕", startDay: "2026-12-02", endDay: "2026-12-06"),
            TravelTrip(id: "gapyeong", title: "가평", startDay: "2026-11-08", endDay: "2026-11-08"),
        ]
        let choices = LedgerBook.plannedTrips(stops: [], items: [item], trips: trips, calendar: calendar)
        XCTAssertEqual(choices.map(\.id), ["t1", "gapyeong"])
        XCTAssertEqual(choices.map(\.name), ["방콕", "가평"])
        XCTAssertEqual(choices[0].end, calendar.date(from: DateComponents(year: 2026, month: 12, day: 6)))
        XCTAssertEqual(choices[1].start, choices[1].end, "일정이 없는 당일치기도 고를 수 있다")
    }
}

/// TVB1112A01: 여행 모드 지구본. 번들 경계 자료, 여행지 찾기, 그림이 실제로 그려지는지(캡처는 임시 폴더에 남긴다).
final class TravelModeGlobeTests: XCTestCase {
    func testBundledRegionsLoadAndCurrencyFollowsCountry() {
        XCTAssertEqual(TravelModeRegions.countries.count, 240)
        XCTAssertEqual(TravelModeRegions.provinces.count, 17)
        XCTAssertEqual(TravelModeRegions.currency(forCountry: "JP"), "JPY")
        XCTAssertEqual(TravelModeRegions.currency(forCountry: "TH"), "THB")
        XCTAssertEqual(TravelModeRegions.currency(forCountry: "FR"), "EUR")
    }

    func testDestinationComesFromTripFieldsOrItsPins() {
        let daegu = TravelModeDestination(trip: TravelTrip(id: "d", title: "대구", startDay: "2026-11-17", endDay: "2026-11-18", countryCode: "KR", regionName: "대구광역시"), stops: [])
        XCTAssertEqual(daegu.country?.code, "KR")
        XCTAssertEqual(daegu.province?.code, "KR-27")
        XCTAssertNotNil(daegu.point)
        // 예전에 가져온 여행은 나라가 없다. 핀이 있는 곳으로 알아낸다.
        let day = Date(timeIntervalSince1970: 1_795_046_400)
        let stops = [
            TravelPlanStop(id: UUID(), title: "오사카성", latitude: 34.687, longitude: 135.526, day: day, order: 1, planID: nil, tripID: "o"),
            TravelPlanStop(id: UUID(), title: "도톤보리", latitude: 34.669, longitude: 135.501, day: day, order: 0, planID: nil, tripID: "o"),
            TravelPlanStop(id: UUID(), title: "다른 여행", latitude: 13.7, longitude: 100.5, day: day, order: 0, planID: nil, tripID: "x"),
        ]
        let osaka = TravelModeDestination(trip: TravelTrip(id: "o", title: "오사카", startDay: "2026-11-19", endDay: "2026-11-22"), stops: stops)
        XCTAssertEqual(osaka.country?.code, "JP")
        XCTAssertNil(osaka.province)
        XCTAssertEqual(osaka.stops.map(\.title), ["도톤보리", "오사카성"])
        XCTAssertEqual(osaka.point?.x ?? 0, 135.5135, accuracy: 0.001)
        let unknown = TravelModeDestination(trip: TravelTrip(id: "u", title: "모름", startDay: "2026-11-19", endDay: "2026-11-19"), stops: [])
        XCTAssertNil(unknown.point, "어디인지 모르면 깃발을 꽂지 않는다")
    }

    /// 회전·확대 60장을 그리는 데 걸리는 시간. 한 장이 화면 한 번(60Hz 기준 16.7ms) 안에 그려지는지 본다.
    @MainActor
    func testFlightFramesRenderFastEnough() throws {
        let japan = try XCTUnwrap(TravelModeRegions.countries.first { $0.code == "JP" })
        let box = japan.mainBox
        let fitted = TravelGlobeCamera.fitting(west: box.west, south: box.south, east: box.east, north: box.north, width: 390, height: 760, padding: 56, minimumRadius: 148, maximumRadius: 60_000)
        let flight = TravelGlobeFlight(start: TravelGlobeCamera(longitude: 20, latitude: 10, radius: 148), targetLongitude: 135.5, targetLatitude: 34.7, stops: [fitted])
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 760), format: format)
        let frames = 60
        var slowest = 0.0
        let started = CFAbsoluteTimeGetCurrent()
        for index in 0..<frames {
            let camera = flight.camera(at: flight.duration * Double(index) / Double(frames - 1))
            let frameStart = CFAbsoluteTimeGetCurrent()
            _ = renderer.image { _ in
                let view = Canvas { context, size in
                    TravelGlobeRenderer.draw(&context, size: size, camera: camera, highlight: ["JP"], flag: .init(longitude: 135.5, latitude: 34.7, text: "D-24", progress: 1), pins: [])
                }.frame(width: 390, height: 760)
                let image = ImageRenderer(content: view)
                image.scale = 2
                image.uiImage?.draw(at: .zero)
            }
            slowest = max(slowest, CFAbsoluteTimeGetCurrent() - frameStart)
        }
        let average = (CFAbsoluteTimeGetCurrent() - started) / Double(frames)
        print(String(format: "TVB1112A01 globe frame average %.2f ms, slowest %.2f ms", average * 1_000, slowest * 1_000))
        // 그림 파일로 굽는 값이라 화면에 그릴 때보다 느리다. 넉넉한 상한만 둔다.
        XCTAssertLessThan(average, 0.05)
    }

    func testPrecomputedVectorsMatchTheCameraProjection() throws {
        let japan = try XCTUnwrap(TravelModeRegions.countries.first { $0.code == "JP" })
        let vectors = try XCTUnwrap(TravelModeRegions.vectors["JP"])
        XCTAssertEqual(vectors.map(\.count), japan.rings.map(\.count))
        let camera = TravelGlobeCamera(longitude: 100, latitude: 20, radius: 300)
        let lambda = camera.longitude * .pi / 180, phi = camera.latitude * .pi / 180
        let east = SIMD3(-sin(lambda), cos(lambda), 0), north = SIMD3(-sin(phi) * cos(lambda), -sin(phi) * sin(lambda), cos(phi))
        for (point, vector) in zip(japan.rings[0], vectors[0]) {
            let expected = camera.project(longitude: point.x, latitude: point.y)
            guard expected.isFront else { continue }
            XCTAssertEqual((vector * east).sum() * 300, expected.point.x, accuracy: 1e-6)
            XCTAssertEqual(-(vector * north).sum() * 300, expected.point.y, accuracy: 1e-6)
        }
    }

    @MainActor
    func testGlobeRendersLandFlagAndPins() throws {
        let size = CGSize(width: 390, height: 760)
        let japan = try XCTUnwrap(TravelModeRegions.countries.first { $0.code == "JP" })
        let daegu = try XCTUnwrap(TravelModeRegions.provinces.first { $0.code == "KR-27" })
        func fit(_ box: (west: Double, south: Double, east: Double, north: Double)) -> TravelGlobeCamera {
            TravelGlobeCamera.fitting(west: box.west, south: box.south, east: box.east, north: box.north, width: 390, height: 760, padding: 56, minimumRadius: 148, maximumRadius: 60_000)
        }
        let shots: [(String, TravelGlobeCamera, Set<String>, TravelGlobeRenderer.Flag?, [TravelGlobeRenderer.Pin])] = [
            ("1-globe", TravelGlobeCamera(longitude: 127, latitude: 28, radius: 148), [], nil, []),
            ("2-flag", TravelGlobeCamera(longitude: 135.5, latitude: 34.7, radius: 148), ["JP"], .init(longitude: 135.5, latitude: 34.7, text: "D-24", progress: 1), []),
            ("3-japan", fit(japan.mainBox), ["JP"], .init(longitude: 135.5, latitude: 34.7, text: "여행 중", progress: 1), []),
            ("4-daegu", fit(daegu.mainBox), ["KR-27"], nil, [.init(longitude: 128.60, latitude: 35.87, label: "1"), .init(longitude: 128.65, latitude: 35.83, label: "2")]),
        ]
        // 시뮬레이터에서는 저장소의 검증 폴더에 캡처를 남긴다(기기에서는 쓸 수 없어 건너뛴다).
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/validation/TVB1112A01/shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, camera, highlight, flag, pins) in shots {
            let renderer = ImageRenderer(content: Canvas { context, canvas in
                TravelGlobeRenderer.draw(&context, size: canvas, camera: camera, highlight: highlight, flag: flag, pins: pins)
            }.frame(width: size.width, height: size.height))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage, name)
            let data = try XCTUnwrap(image.pngData())
            try? data.write(to: folder.appendingPathComponent("\(name).png"))
            // 한 색으로만 칠해진 그림이 아닌지(땅과 바다가 함께 있는지) 가운데 줄의 색 수로 본다.
            let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data as Data?)
            let row = Int(image.size.height * image.scale / 2) * (image.cgImage?.bytesPerRow ?? 0)
            var colors = Set<UInt32>()
            for x in stride(from: 0, to: Int(image.size.width * image.scale), by: 4) {
                let offset = row + x * 4
                colors.insert(UInt32(pixels[offset]) << 16 | UInt32(pixels[offset + 1]) << 8 | UInt32(pixels[offset + 2]))
            }
            XCTAssertGreaterThanOrEqual(colors.count, 2, "\(name): 땅과 바다가 그려져야 한다")
        }
    }
}
