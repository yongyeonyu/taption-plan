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

    /// TVQ1112A01: 손으로 넣기·고치기·지우기가 여행 일정과 일상 계획·핀을 함께 바꾼다.
    @MainActor
    func testAddingEditingAndDeletingAnItemByHand() async throws {
        let model = try await importedModel()
        let trip = try XCTUnwrap(model.settings.travelTrips?.first)
        let target = TravelQuickEntrySheet.Target.new(trip: trip, dayKey: "2026-12-03", dayLabel: "2일차", startMinute: 720, kind: .meal)
        let start = TravelQuickEntrySheet.date(dayKey: target.dayKey, minute: target.startMinute, offsetSeconds: 7 * 3_600)
        XCTAssertEqual(start, try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-03T12:00:00+07:00")))

        let added = await model.addTripItem(tripID: "t1", kind: .meal, title: " ", start: start, end: start.addingTimeInterval(3_600), offsetSeconds: 7 * 3_600)
        let itemID = try XCTUnwrap(added)
        var item = try XCTUnwrap(model.settings.travelTripItems?.first { $0.itemID == itemID })
        XCTAssertEqual(item.title, TripImportItem.Kind.meal.planName, "이름을 비우면 분류 이름으로 들어간다")
        let planID = try XCTUnwrap(item.planID)
        var plan = try XCTUnwrap(model.snapshot.plans.first { $0.id == planID })
        XCTAssertEqual(plan.span.start, start)
        XCTAssertEqual(plan.categoryID, "travel")
        XCTAssertEqual(model.settings.travelTripItems?.count, 3)

        let edit = TravelQuickEntrySheet.Target.edit(item, dayLabel: "2일차")
        XCTAssertEqual(edit.dayKey, "2026-12-03")
        XCTAssertEqual(edit.startMinute, 720)
        XCTAssertEqual(edit.kind, .meal)

        let late = start.addingTimeInterval(2 * 86_400 + 9 * 3_600)
        let updated = await model.updateTripItem(tripID: "t1", itemID: itemID, kind: .transfer, title: "공항 가기", start: late, end: late.addingTimeInterval(1_800))
        XCTAssertTrue(updated)
        item = try XCTUnwrap(model.settings.travelTripItems?.first { $0.itemID == itemID })
        XCTAssertEqual(item.title, "공항 가기")
        XCTAssertEqual(item.kind, "transfer")
        plan = try XCTUnwrap(model.snapshot.plans.first { $0.id == planID })
        XCTAssertEqual(plan.title, "공항 가기")
        XCTAssertEqual(plan.categoryID, "movement")

        // TVU1113A01: 색·예상 지출은 넘겨준 때만 바뀌고, 다듬어 저장한다. 넘기지 않으면 그대로, nil을 넘기면 지운다.
        let styled = await model.updateTripItem(tripID: "t1", itemID: itemID, kind: .transfer, title: "공항 가기", start: late, end: late.addingTimeInterval(1_800), style: (" #c8442e", 12_000.4))
        XCTAssertTrue(styled)
        item = try XCTUnwrap(model.settings.travelTripItems?.first { $0.itemID == itemID })
        XCTAssertEqual(item.colorHex, "#C8442E")
        XCTAssertEqual(item.plannedSpendKRW, 12_000)
        _ = await model.updateTripItem(tripID: "t1", itemID: itemID, kind: .transfer, title: "공항", start: late, end: late.addingTimeInterval(1_800))
        item = try XCTUnwrap(model.settings.travelTripItems?.first { $0.itemID == itemID })
        XCTAssertEqual(item.colorHex, "#C8442E", "넘기지 않으면 그대로")
        _ = await model.updateTripItem(tripID: "t1", itemID: itemID, kind: .transfer, title: "공항 가기", start: late, end: late.addingTimeInterval(1_800), style: (nil, 0))
        item = try XCTUnwrap(model.settings.travelTripItems?.first { $0.itemID == itemID })
        XCTAssertNil(item.colorHex)
        XCTAssertNil(item.plannedSpendKRW)
        XCTAssertEqual(plan.span.end, late.addingTimeInterval(1_800))
        XCTAssertEqual(model.settings.travelTrips?.first?.endDay, "2026-12-05", "여행 기간 밖으로 나가면 기간이 늘어난다")

        let renamed = await model.updateTripItem(tripID: "t1", itemID: "a", kind: .sight, title: "새벽 사원", start: item.start, end: item.end)
        XCTAssertTrue(renamed)
        XCTAssertEqual(model.settings.travelPlanStops.first { $0.itemID == "a" }?.title, "새벽 사원", "지도 핀 이름도 바뀐다")

        let deleted = await model.deleteTripItem(tripID: "t1", itemID: itemID)
        XCTAssertTrue(deleted)
        XCTAssertNil(model.snapshot.plans.first { $0.id == planID })
        XCTAssertEqual(model.settings.travelTripItems?.count, 2)
        let gone = await model.deleteTripItem(tripID: "t1", itemID: "a")
        XCTAssertTrue(gone)
        XCTAssertNil(model.settings.travelPlanStops.first { $0.itemID == "a" })
        let missing = await model.deleteTripItem(tripID: "t1", itemID: "none")
        XCTAssertFalse(missing)
    }

    /// TVR1112A01: 끌어 옮기기·길이 바꾸기의 5분 단위 계산과 하루 경계, 이름 후보.
    func testDragDeltasSnapAndStayInsideTheDay() {
        let h = TravelPlanTable.minuteHeight
        XCTAssertEqual(TravelPlanTable.moveDelta(translation: 32 * h, start: 600, end: 660), 30)
        XCTAssertEqual(TravelPlanTable.moveDelta(translation: -34 * h, start: 600, end: 660), -35)
        XCTAssertEqual(TravelPlanTable.moveDelta(translation: -900 * h, start: 600, end: 660), -600, "0시 앞으로 나가지 않는다")
        XCTAssertEqual(TravelPlanTable.moveDelta(translation: 2_000 * h, start: 600, end: 660), 780, "24시 뒤로 나가지 않는다")
        XCTAssertEqual(TravelPlanTable.resizeDelta(translation: 28 * h, start: 600, end: 660), 30)
        XCTAssertEqual(TravelPlanTable.resizeDelta(translation: -200 * h, start: 600, end: 660), -45, "15분보다 짧아지지 않는다")
        XCTAssertEqual(TravelPlanTable.resizeDelta(translation: 2_000 * h, start: 600, end: 660), 780)
    }

    /// 듀오·패드와 가로 모드: 넓으면 오른쪽 판, 계획표 높이는 화면 안에 든다.
    func testWideAndLandscapeLayouts() {
        let phone = CGSize(width: 402, height: 874), phoneLandscape = CGSize(width: 874, height: 402)
        let pad = CGSize(width: 820, height: 1_180), padLandscape = CGSize(width: 1_180, height: 820), duo = CGSize(width: 720, height: 800)
        XCTAssertFalse(TravelModeView.isWide(phone))
        for size in [phoneLandscape, pad, padLandscape, duo] { XCTAssertTrue(TravelModeView.isWide(size), "\(size)") }
        XCTAssertEqual(TravelModeView.planTableHeight(phone), 437)
        XCTAssertEqual(TravelModeView.planTableHeight(phoneLandscape), 122)
        XCTAssertEqual(TravelModeView.planTableHeight(pad), 826)
        XCTAssertEqual(TravelModeView.planTableHeight(padLandscape), 540)
        // TVU1113A01: 계획표 판 높이 — 기억한 값이 없으면 반반, 손잡이로 220pt부터 머리말·하단 막대를 남긴 끝까지, 넓은 화면은 그대로.
        XCTAssertEqual(TravelPlanSheetHeight.height(phone, stored: 0), 437)
        XCTAssertEqual(TravelPlanSheetHeight.range(phone), 220...544)
        XCTAssertEqual(TravelPlanSheetHeight.height(phone, stored: 900), 544)
        XCTAssertEqual(TravelPlanSheetHeight.height(phone, stored: 100), 220)
        XCTAssertEqual(TravelPlanSheetHeight.height(pad, stored: 300), 826, "넓은 화면은 높이를 바꾸지 않는다")
        XCTAssertEqual(TravelPlanSheetHeight.dragged(from: 437, translation: -50, size: phone), 488, "위로 끌면 커지고 4pt 단위")
        XCTAssertEqual(TravelPlanSheetHeight.dragged(from: 437, translation: 900, size: phone), 220)
        XCTAssertFalse(TravelPlanSheetHeight.isMapFolded(437, size: phone))
        XCTAssertTrue(TravelPlanSheetHeight.isMapFolded(544, size: phone))
        XCTAssertEqual(TravelPlanSheetHeight.toggled(437, size: phone), 544, "지도 접기")
        XCTAssertEqual(TravelPlanSheetHeight.toggled(544, size: phone), 437, "지도 펼치기")
        XCTAssertEqual(TravelModeView.mapArea(phone, isPlanUp: true, tableHeight: 544).height, 80, "지도 접기에서도 지도 자리는 80pt 남는다")
        // TVU1113A01: 핀치 배율은 단추와 같은 범위(0.6~2.2) 안에서 0.05 단위.
        XCTAssertEqual(TravelPlanTable.pinched(from: 1, magnification: 1.52), 1.5, accuracy: 0.001)
        XCTAssertEqual(TravelPlanTable.pinched(from: 1, magnification: 9), 2.2, accuracy: 0.001)
        XCTAssertEqual(TravelPlanTable.pinched(from: 1, magnification: 0.1), 0.6, accuracy: 0.001)
        XCTAssertEqual(TravelPlanTable.pinched(from: 1.5, magnification: .nan), 1.5)
        XCTAssertEqual(TravelPlanDays.shortDate("2026-11-20"), "11/20")
        XCTAssertEqual(TravelPlanDays.shortDate("2026-01-05"), "1/5")
        XCTAssertEqual(TravelPlanDays.shortDate("잘못"), "")
        // TVU1113A01: 편집기의 시작·종료 슬라이더(5분 단위).
        let moved = TravelQuickEntrySheet.movingStart(to: 607, duration: 90)
        XCTAssertEqual([moved.start, moved.duration], [605, 90], "시작을 옮기면 길이는 그대로")
        let late = TravelQuickEntrySheet.movingStart(to: 1_400, duration: 90)
        XCTAssertEqual([late.start, late.duration], [1_400, 40], "끝이 24시를 넘지 않게 길이를 줄인다")
        XCTAssertEqual(TravelQuickEntrySheet.movingStart(to: 2_000, duration: 30).start, 1_435)
        XCTAssertEqual(TravelQuickEntrySheet.duration(endingAt: 722, start: 600), 120)
        XCTAssertEqual(TravelQuickEntrySheet.duration(endingAt: 500, start: 600), 5, "종료는 시작보다 5분 이상 뒤")
        XCTAssertEqual(TravelQuickEntrySheet.duration(endingAt: 1_440, start: 1_380), 60)
    }

    /// 일상 → 여행 바로 전환: 보던 날을 품은 여행, 여행 중, 마지막으로 연 여행 순.
    func testSwitchingFromDailyOpensTheRightTrip() {
        func entry(_ id: String, _ start: String, _ end: String) -> TravelTripDirectory.Entry {
            TravelTripDirectory.entry(TravelTrip(id: id, title: id, startDay: start, endDay: end), isStored: true, today: "2026-11-12")
        }
        let entries = [entry("now", "2026-11-12", "2026-11-12"), entry("bkk", "2026-12-01", "2026-12-05"), entry("fuk", "2026-11-20", "2026-11-22")]
        XCTAssertEqual(TravelModeView.entryToOpen(entries, selectedDay: "2026-12-03", lastTripID: "fuk")?.id, "bkk", "일상에서 보던 날의 여행")
        XCTAssertEqual(TravelModeView.entryToOpen(entries, selectedDay: "2026-11-15", lastTripID: "fuk")?.id, "now", "여행 중인 것")
        let later = [entry("bkk", "2026-12-01", "2026-12-05"), entry("fuk", "2026-11-20", "2026-11-22")]
        XCTAssertEqual(TravelModeView.entryToOpen(later, selectedDay: "2026-11-12", lastTripID: "fuk")?.id, "fuk", "마지막으로 열어 둔 것")
        XCTAssertNil(TravelModeView.entryToOpen(later, selectedDay: "2026-11-12", lastTripID: ""), "없으면 지구본")
    }

    /// TVS1112A01: 오픈맵을 맞출 상자는 핀을 모두 품고, 한 점이어도 넓이가 있다.
    func testStreetMapBoundsCoverEveryPin() throws {
        XCTAssertNil(TravelStreetMap.bounds([]))
        let one = try XCTUnwrap(TravelStreetMap.bounds([.init(longitude: 130.4, latitude: 33.59, label: "1")]))
        XCTAssertLessThan(one.west, 130.4)
        XCTAssertGreaterThan(one.north, 33.59)
        let pins: [TravelStreetMap.Pin] = [.init(longitude: 130.37, latitude: 33.58, label: "1"), .init(longitude: 130.53, latitude: 33.52, label: "2")]
        let box = try XCTUnwrap(TravelStreetMap.bounds(pins))
        for pin in pins {
            XCTAssertTrue(box.west < pin.longitude && pin.longitude < box.east && box.south < pin.latitude && pin.latitude < box.north)
        }
    }

    func testTitleSuggestionsAreRecentTitlesOfTheSameKind() {
        func item(_ id: String, _ kind: String, _ title: String, trip: String = "t1") -> TravelTripItem {
            TravelTripItem(tripID: trip, itemID: id, kind: kind, title: title, start: .now, end: .now.addingTimeInterval(60), startOffsetSeconds: 0, endOffsetSeconds: 0, planID: nil)
        }
        let items = [item("1", "meal", "라멘"), item("2", "sight", "성"), item("3", "meal", TripImportItem.Kind.meal.planName), item("4", "meal", "야타이"),
                     item("5", "meal", "라멘"), item("6", "meal", "스시", trip: "t2")]
        XCTAssertEqual(TravelQuickEntrySheet.suggestions(items: items, tripID: "t1", kind: .meal, typed: ""), ["라멘", "야타이"])
        XCTAssertEqual(TravelQuickEntrySheet.suggestions(items: items, tripID: "t1", kind: .meal, typed: "라멘 "), ["야타이"])
        XCTAssertEqual(TravelQuickEntrySheet.suggestions(items: items, tripID: "t1", kind: .cafe, typed: ""), [])
    }

    func testTappedSpotBecomesColumnAndQuarterHour() throws {
        // 너비 350: 왼쪽 50은 시간축, 열 하나는 75.
        let slot = try XCTUnwrap(TravelPlanTable.slot(x: 130, y: 12 * 60 * TravelPlanTable.minuteHeight + 9, width: 350))
        XCTAssertEqual(slot.column, 1)
        XCTAssertEqual(slot.minute, 720)
        XCTAssertEqual(TravelPlanTable.slot(x: 349, y: 0, width: 350)?.column, 3)
        XCTAssertNil(TravelPlanTable.slot(x: 20, y: 100, width: 350), "시간축을 누르면 넣지 않는다")
        XCTAssertEqual(TravelQuickEntrySheet.clock(1_470), "00:30")
        XCTAssertEqual(TravelQuickEntrySheet.durationText(90, language: .korean), "1시간 30분")
    }

    /// TVU1113A01: 빈 셀을 누르면 선택만 되고, 「+」를 눌러야 그 시각으로 입력 시트가 열린다.
    func testEmptyCellIsSelectedFirstAndPlusOpensEntry() throws {
        let slot = try XCTUnwrap(TravelPlanTable.slot(x: 130, y: 12 * 60 * TravelPlanTable.minuteHeight + 9, width: 350))
        let noon = TravelPlanCell(column: slot.column, minute: slot.minute)
        // 1. 빈 셀 누르기: 선택만, 시트는 열리지 않는다.
        let first = TravelPlanCell.after(.empty(noon), selected: nil)
        XCTAssertEqual(first.selected, noon)
        XCTAssertNil(first.opens)
        XCTAssertEqual(noon.endMinute, 780)
        // 2. 다른 셀 누르기: 선택이 옮겨 간다.
        let evening = TravelPlanCell(column: 3, minute: 23 * 60 + 30)
        let moved = TravelPlanCell.after(.empty(evening), selected: first.selected)
        XCTAssertEqual(moved.selected, evening)
        XCTAssertNil(moved.opens)
        XCTAssertEqual(evening.endMinute, 1_440, "선택 표시는 하루를 넘지 않는다")
        // 3. 「+」: 선택한 셀로 열고 선택은 풀린다.
        let opened = TravelPlanCell.after(.plus, selected: moved.selected)
        XCTAssertEqual(opened.opens, evening)
        XCTAssertNil(opened.selected)
        // 4. 셀 밖(시간축·있는 일정): 선택만 풀리고 열리지 않는다.
        let cleared = TravelPlanCell.after(.elsewhere, selected: noon)
        XCTAssertNil(cleared.selected)
        XCTAssertNil(cleared.opens)
        // 선택 없이 「+」가 올 수는 없지만, 와도 열지 않는다.
        XCTAssertNil(TravelPlanCell.after(.plus, selected: nil).opens)
        // 손잡이: 아래는 끝을, 위는 시작을 옮긴다. 안 바꿨으면 분류의 기본 길이를 쓰도록 길이를 넘기지 않는다.
        XCTAssertNil(noon.chosenDuration)
        let longer = noon.movingEnd(by: 45)
        XCTAssertEqual([longer.minute, longer.endMinute, longer.chosenDuration ?? 0], [720, 825, 105])
        XCTAssertEqual(noon.movingEnd(by: -200).endMinute, 735, "15분보다 짧아지지 않는다")
        XCTAssertEqual(noon.movingEnd(by: 2_000).endMinute, 1_440, "24시를 넘지 않는다")
        let earlier = noon.movingStart(by: -30)
        XCTAssertEqual([earlier.minute, earlier.endMinute, earlier.chosenDuration ?? 0], [690, 780, 90])
        XCTAssertEqual(noon.movingStart(by: 300).minute, 765, "끝 15분 전까지만")
        XCTAssertEqual(noon.movingStart(by: -2_000).minute, 0)
        XCTAssertEqual(TravelPlanCell.after(.plus, selected: longer).opens?.chosenDuration, 105)
    }

    /// TVU1113A01: 일정을 한 번 누르면 선택만 되고, 선택된 일정을 다시 눌러야 편집기가 열린다(Trip 원본).
    func testPlanBlockIsSelectedFirstAndSecondTapOpensEditor() {
        let first = TravelPlanSelection.after(tapped: "a", selected: nil)
        XCTAssertEqual(first.selected, "a")
        XCTAssertFalse(first.opensEditor)
        let other = TravelPlanSelection.after(tapped: "b", selected: first.selected)
        XCTAssertEqual(other.selected, "b")
        XCTAssertFalse(other.opensEditor, "다른 일정을 누르면 선택만 옮겨 간다")
        let again = TravelPlanSelection.after(tapped: "b", selected: other.selected)
        XCTAssertEqual(again.selected, "b")
        XCTAssertTrue(again.opensEditor)
        // 선택 막대의 −5분·+5분은 하루를 벗어나지 않는다.
        XCTAssertFalse(TravelPlanSelection.canNudge(-5, start: 0, end: 60))
        XCTAssertTrue(TravelPlanSelection.canNudge(5, start: 0, end: 60))
        XCTAssertFalse(TravelPlanSelection.canNudge(5, start: 1_380, end: 1_440))
        XCTAssertTrue(TravelPlanSelection.canNudge(-5, start: 1_380, end: 1_440))
    }

    /// TVU1113A01: 일정 색·예상 지출이 계획표 칸까지 가고, 쓴 돈이 있으면 예상보다 먼저 보인다.
    func testItemColorAndPlannedSpendReachThePlanTable() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-03T10:00:00+09:00"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let item = TravelTripItem(tripID: "t1", itemID: "a", kind: "sight", title: "성", start: start, end: start.addingTimeInterval(7_200),
                                  startOffsetSeconds: 32_400, endOffsetSeconds: 32_400, planID: nil, colorHex: "#C8442E", plannedSpendKRW: 12_000)
        let plain = TravelTripItem(tripID: "t1", itemID: "b", kind: "meal", title: "라멘", start: start, end: start.addingTimeInterval(3_600),
                                   startOffsetSeconds: 32_400, endOffsetSeconds: 32_400, planID: nil)
        let table = TravelPlanTableModel.make(items: [item, plain], tripID: "t1", day: start, actual: [], now: start.addingTimeInterval(-86_400), calendar: calendar)
        let colored = try XCTUnwrap(table.blocks.first { $0.id == "a" })
        XCTAssertEqual(colored.colorHex, "#C8442E")
        XCTAssertEqual(colored.planned, 12_000)
        let other = try XCTUnwrap(table.blocks.first { $0.id == "b" })
        XCTAssertNil(other.colorHex)
        XCTAssertEqual(other.planned, 0)
        let planned = try XCTUnwrap(TravelPlanTable.money(spent: 0, planned: 12_000))
        XCTAssertTrue(planned.isPlanned)
        XCTAssertEqual(planned.amount, 12_000)
        let spent = try XCTUnwrap(TravelPlanTable.money(spent: 9_000, planned: 12_000))
        XCTAssertFalse(spent.isPlanned, "쓴 돈이 있으면 그것을 보인다")
        XCTAssertEqual(spent.amount, 9_000)
        XCTAssertNil(TravelPlanTable.money(spent: 0, planned: 0))
        XCTAssertEqual(TravelQuickEntrySheet.spendDigits("12,000원"), "12000")
        XCTAssertEqual(TravelPlanSpend.plannedTotal(items: [item, plain, item], tripID: "t1"), 24_000)
        XCTAssertEqual(TravelPlanSpend.plannedTotal(items: [item], tripID: "다른 여행"), 0)
        // 대표 결정: 예산을 정했으면 남은 돈, 안 정했으면 쓴 돈을 앞에 보인다.
        func sheet(budget: Double, cost: Double) -> LedgerTripSheet {
            LedgerTripSheet(budget: budget, otherIncome: 0, myPaid: cost, myCost: cost, sharedTotal: 0, balances: [:], transfers: [])
        }
        let noBudget = TravelPlanSpend.headline(sheet(budget: 0, cost: 1_200))
        XCTAssertFalse(noBudget.isLeftover)
        XCTAssertEqual(noBudget.amount, 1_200)
        let withBudget = TravelPlanSpend.headline(sheet(budget: 50_000, cost: 1_200))
        XCTAssertTrue(withBudget.isLeftover)
        XCTAssertEqual(withBudget.amount, 48_800)
        XCTAssertEqual(TravelQuickEntrySheet.spendDigits(""), "")
    }

    /// TVU1113A01: 계획표가 여행의 열 구성을 따른다 — 열 수, 칸 자리, 누른 자리의 열, 제목.
    func testPlanTableFollowsTripColumns() throws {
        XCTAssertEqual(Set(TravelPlanColumns.allKinds), Set(TravelQuickEntrySheet.kinds.map(\.rawValue)), "종류 12가지가 같다")
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-03T10:00:00+09:00"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        func item(_ id: String, _ kind: String) -> TravelTripItem {
            TravelTripItem(tripID: "t1", itemID: id, kind: kind, title: id, start: start, end: start.addingTimeInterval(3_600),
                           startOffsetSeconds: 32_400, endOffsetSeconds: 32_400, planID: nil)
        }
        let items = [item("a", "cafe"), item("b", "meal"), item("c", "flight"), item("d", "photo")]
        let base = TravelPlanTableModel.make(items: items, tripID: "t1", day: start, actual: [], now: start.addingTimeInterval(-86_400), calendar: calendar)
        XCTAssertEqual(base.columns.count, 4)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: base.blocks.map { ($0.id, $0.column) }), ["a": 1, "b": 1, "c": 0, "d": 2], "기본은 전과 같은 자리")

        let columns = TravelPlanColumns.resolved([
            TravelTripColumn(name: "", kinds: ["meal"]), TravelTripColumn(name: "카페", kinds: ["cafe"]),
            TravelTripColumn(name: "", kinds: ["transfer", "flight"]), TravelTripColumn(name: "", kinds: ["sight", "other"]),
            TravelTripColumn(name: "", kinds: ["lodging"]),
        ])
        let custom = TravelPlanTableModel.make(items: items, tripID: "t1", day: start, actual: [], now: start.addingTimeInterval(-86_400), columns: columns, calendar: calendar)
        XCTAssertEqual(custom.columns.count, 5)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: custom.blocks.map { ($0.id, $0.column) }), ["a": 1, "b": 0, "c": 2, "d": 3])
        // 너비 350에 다섯 열이면 한 열은 60: x 175는 세 번째 열.
        XCTAssertEqual(TravelPlanTable.slot(x: 175, y: 0, width: 350, columns: 5)?.column, 2)
        XCTAssertEqual(TravelPlanTable.slot(x: 349, y: 0, width: 350, columns: 5)?.column, 4)
        XCTAssertEqual(TravelPlanColumns.kind(forColumn: 1, in: columns), "cafe", "그 열의 빈 곳을 누르면 그 열의 첫 종류")
        XCTAssertEqual(TravelPlanTable.title(columns[1], index: 1, language: .korean), "카페")
        XCTAssertEqual(TravelPlanTable.title(columns[0], index: 0, language: .korean), "식사")
        XCTAssertEqual(TravelPlanTable.title(TravelTripColumn(name: "", kinds: []), index: 5, language: .korean), "열 6")
    }

    /// TVV1113A01: 코스 보기 — 시간 순서, 재생 헤드 기준 지금 일정, 진행률, 이전·다음.
    func testCourseOrderCurrentAndProgress() {
        func block(_ id: String, _ start: Int, _ end: Int) -> TravelPlanTableModel.Block {
            .init(id: id, column: 0, startMinute: start, endMinute: end, title: id, tripStatus: nil, status: .pending)
        }
        let blocks = TravelCourse.ordered([block("c", 720, 780), block("a", 540, 600), block("b", 570, 660)])
        XCTAssertEqual(blocks.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(TravelCourse.currentIndex(blocks, minute: 545), 0)
        XCTAssertEqual(TravelCourse.currentIndex(blocks, minute: 580), 1, "겹치면 늦게 시작한 일정")
        XCTAssertEqual(TravelCourse.currentIndex(blocks, minute: 700), 2, "사이 시간이면 다음에 올 일정")
        XCTAssertEqual(TravelCourse.currentIndex(blocks, minute: 60), 0)
        XCTAssertEqual(TravelCourse.currentIndex(blocks, minute: 1_400), 2, "다 지났으면 마지막 일정")
        XCTAssertNil(TravelCourse.currentIndex([], minute: 600))
        XCTAssertEqual(TravelCourse.progress(blocks[0], minute: 555), 0.25, accuracy: 0.001)
        XCTAssertEqual(TravelCourse.progress(blocks[0], minute: 100), 0)
        XCTAssertEqual(TravelCourse.progress(blocks[0], minute: 900), 1)
        XCTAssertEqual(TravelCourse.neighborStart(blocks, current: 1, step: 1), 720)
        XCTAssertEqual(TravelCourse.neighborStart(blocks, current: 1, step: -1), 540)
        XCTAssertNil(TravelCourse.neighborStart(blocks, current: 2, step: 1))
        XCTAssertNil(TravelCourse.neighborStart(blocks, current: 0, step: -1))
    }

    /// TVV1113A01 C1·C2: 코스가 먼저 열리고, 코스 끝에 붙는 새 곳의 시각과 찾은 장소의 종류 짐작.
    func testCourseIsDefaultAndNewStopsGoToTheEnd() {
        XCTAssertTrue(TravelCoursePlanner.showsCourse("", tripID: "t1"), "고르지 않은 여행은 코스가 먼저")
        var stored = TravelCoursePlanner.tableTrips("", tripID: "t1", showsCourse: false)
        XCTAssertEqual(stored, "t1")
        XCTAssertFalse(TravelCoursePlanner.showsCourse(stored, tripID: "t1"))
        XCTAssertTrue(TravelCoursePlanner.showsCourse(stored, tripID: "t10"), "번호가 앞부분만 같은 여행과 헷갈리지 않는다")
        stored = TravelCoursePlanner.tableTrips(stored, tripID: "t2", showsCourse: false)
        stored = TravelCoursePlanner.tableTrips(stored, tripID: "t1", showsCourse: true)
        XCTAssertEqual(stored, "t2")

        func block(_ start: Int, _ end: Int, kind: String = "sight") -> TravelPlanTableModel.Block {
            .init(id: "\(start)", column: 0, startMinute: start, endMinute: end, title: "", tripStatus: nil, status: .pending, kind: kind)
        }
        var slot = TravelCoursePlanner.nextSlot(blocks: [block(1_200, 1_230), block(1_380, 1_439, kind: "sleep")], kind: "cafe", nowMinute: nil)
        XCTAssertEqual([slot.start, slot.duration], [1_230, 45], "밤의 잠은 건너뛰고 그 앞 일정 뒤에 잇는다")
        slot = TravelCoursePlanner.nextSlot(blocks: [], kind: "sight", nowMinute: nil)
        XCTAssertEqual([slot.start, slot.duration], [540, 90], "빈 날은 09:00부터 종류 기본 길이")
        slot = TravelCoursePlanner.nextSlot(blocks: [], kind: "meal", nowMinute: 611)
        XCTAssertEqual([slot.start, slot.duration], [615, 60], "오늘이면 지금(15분 올림)")
        slot = TravelCoursePlanner.nextSlot(blocks: [block(540, 630), block(600, 700)], kind: "cafe", nowMinute: nil)
        XCTAssertEqual([slot.start, slot.duration], [700, 45], "그날 마지막 일정 끝에서 잇는다")
        slot = TravelCoursePlanner.nextSlot(blocks: [block(1_200, 1_400)], kind: "lodging", nowMinute: nil)
        XCTAssertEqual([slot.start, slot.duration], [1_400, 40], "하루를 넘지 않게 줄인다")

        XCTAssertEqual(TravelCoursePlanner.kind(forCategory: "MKPOICategoryRestaurant"), "meal")
        XCTAssertEqual(TravelCoursePlanner.kind(forCategory: "MKPOICategoryCafe"), "cafe")
        XCTAssertEqual(TravelCoursePlanner.kind(forCategory: "MKPOICategoryHotel"), "lodging")
        XCTAssertEqual(TravelCoursePlanner.kind(forCategory: "MKPOICategoryAirport"), "flight")
        XCTAssertEqual(TravelCoursePlanner.kind(forCategory: "MKPOICategoryPublicTransport"), "transfer")
        XCTAssertEqual(TravelCoursePlanner.kind(forCategory: "MKPOICategoryMuseum"), "sight")
        XCTAssertEqual(TravelCoursePlanner.kind(forCategory: nil), "sight")
    }

    /// TVV1113A01 C3: 코스 순서를 바꾸면 바뀐 구간 안에서만 시각이 다시 잡힌다 — 구간의 첫 시작과 틈은 자리에, 길이는 일정에.
    func testCourseReorderRetimesOnlyTheChangedRange() throws {
        func block(_ id: String, _ start: Int, _ end: Int, kind: String = "sight", booked: Bool = false) -> TravelPlanTableModel.Block {
            .init(id: id, column: 0, startMinute: start, endMinute: end, title: id, tripStatus: booked ? .booked : nil, status: .pending, kind: kind)
        }
        // a 09:00–10:00, (틈 30) b 10:30–11:00, (틈 0) c 11:00–13:00, (틈 60) d 14:00–15:00
        let blocks = [block("a", 540, 600), block("b", 630, 660), block("c", 660, 780), block("d", 840, 900)]
        // c를 맨 앞으로: 구간은 a·b·c. 새 순서 c, a, b — 첫 시작 09:00, 틈 30·0은 자리에 남는다.
        let moves = try XCTUnwrap(TravelCoursePlanner.reorder(blocks, from: 2, to: 0))
        XCTAssertEqual(moves, ["c": -120, "a": 150, "b": 120], "c 09:00–11:00, a 11:30–12:30, b 12:30–13:00")
        XCTAssertNil(moves["d"], "구간 밖은 건드리지 않는다")
        // 구간 끝(b의 새 끝 13:00)은 원래 c의 끝과 같아 뒤 일정 d와의 틈이 그대로다.
        XCTAssertEqual(blocks[1].endMinute + (moves["b"] ?? 0), blocks[2].endMinute)
        // 제자리로 놓으면 바뀌는 것이 없다.
        XCTAssertEqual(TravelCoursePlanner.reorder(blocks, from: 1, to: 1), [:])
        XCTAssertEqual(TravelCoursePlanner.reorder(blocks, from: 1, to: 2), [:])
        // 예약된 일정이나 잠이 구간에 끼면 옮기지 않는다.
        let booked = [block("a", 540, 600), block("b", 630, 660, booked: true), block("c", 660, 780)]
        XCTAssertNil(TravelCoursePlanner.reorder(booked, from: 2, to: 0))
        let night = [block("a", 540, 600), block("z", 1_380, 1_439, kind: "sleep")]
        XCTAssertNil(TravelCoursePlanner.reorder(night, from: 0, to: 2))

        // 묶음 걸음: 되돌리면 거꾸로, 반대 방향으로.
        let step = try XCTUnwrap(TravelPlanHistory.Step.reorder(tripID: "t1", moves: moves, title: "c"))
        XCTAssertEqual(step.group.map(\.itemID), ["a", "b", "c"])
        XCTAssertEqual(step.inverse.group.map(\.move), [120, -120, -150])
        XCTAssertNil(TravelPlanHistory.Step.reorder(tripID: "t1", moves: ["a": 0], title: "a"))
    }

    /// TVV1113A01 C5: 코스일 때 지도 핀은 코스 목록의 번호·종류 아이콘·일정 색을 따르고 지금 일정을 표시한다. 계획표일 때는 전과 같다.
    func testMapPinsFollowTheCourse() {
        func block(_ id: String, _ start: Int, _ end: Int, kind: String, color: String? = nil) -> TravelPlanTableModel.Block {
            .init(id: id, column: 0, startMinute: start, endMinute: end, title: "이름 " + id, tripStatus: nil, status: .pending, colorHex: color, kind: kind)
        }
        let pins = [TravelGlobeRenderer.Pin(longitude: 130.4, latitude: 33.6, label: "1", id: "b", title: ""), TravelGlobeRenderer.Pin(longitude: 130.5, latitude: 33.5, label: "2", id: "c", title: "")]
        let blocks = [block("c", 720, 780, kind: "meal", color: "#C8442E"), block("a", 540, 600, kind: "transfer"), block("b", 600, 700, kind: "sight")]
        let plain = TravelCoursePlanner.mapPins(pins, blocks: [], minute: 610)
        XCTAssertEqual(plain.map(\.label), ["1", "2"])
        XCTAssertEqual(plain.map(\.symbol), ["", ""])
        let course = TravelCoursePlanner.mapPins(pins, blocks: blocks, minute: 610)
        XCTAssertEqual(course.map(\.label), ["2", "3"], "장소 없는 일정(a)도 번호를 차지한다")
        XCTAssertEqual(course.map(\.title), ["이름 b", ""], "이름표는 골라 둔 핀과 지금 일정에만")
        XCTAssertEqual(course.map(\.isCurrent), [true, false])
        XCTAssertEqual(course[1].colorHex, "#C8442E")
        XCTAssertEqual(course.map(\.symbol), [TripImportItem.Kind.sight.symbol, TripImportItem.Kind.meal.symbol])
        XCTAssertEqual(TravelStreetMap.courseLabelWidth("아주 아주 아주 아주 아주 긴 장소 이름입니다 정말로"), 120, "이름표는 120pt까지")
    }

    /// TVV1113A01 C6: 위키백과 사진 — 연락처가 없으면 묻지 않고, 이름의 글자로 언어를 고르고, 좌표가 가깝고 이름이 맞는 항목의 사진만 쓴다.
    func testWikiPhotoPickingAndCredit() throws {
        XCTAssertNil(TravelWikiPhoto.userAgent(contact: nil, version: "1.0"))
        XCTAssertNil(TravelWikiPhoto.userAgent(contact: "  ", version: "1.0"))
        XCTAssertNil(TravelWikiPhoto.userAgent(contact: "$(WIKIMEDIA_CONTACT)", version: "1.0"), "설정이 풀리지 않은 값")
        XCTAssertEqual(TravelWikiPhoto.userAgent(contact: "example.org/support", version: "1.2"), "BOKKIPlan/1.2 (example.org/support)")
        XCTAssertEqual(TravelWikiPhoto.language(for: "다자이후 텐만구"), "ko")
        XCTAssertEqual(TravelWikiPhoto.language(for: "太宰府天満宮"), "ja")
        XCTAssertEqual(TravelWikiPhoto.language(for: "Canal City Hakata"), "en")
        XCTAssertEqual(TravelWikiPhoto.normalized("다자이후 텐만구!"), "다자이후텐만구")
        XCTAssertEqual(TravelWikiPhoto.searchURL(name: "경복궁", language: "ko")?.host, "ko.wikipedia.org")

        let found = Data(#"""
        {"query":{"pages":[
          {"title":"먼 곳의 같은 이름","index":1,"pageimage":"Far.jpg","thumbnail":{"source":"https://upload.wikimedia.org/far.jpg"},"coordinates":[{"lat":35.0,"lon":129.0}]},
          {"title":"근처 다른 곳","index":2,"pageimage":"Near.jpg","thumbnail":{"source":"https://upload.wikimedia.org/near.jpg"},"coordinates":[{"lat":33.5216,"lon":130.5350}]},
          {"title":"다자이후텐만구","index":3,"pageimage":"Shrine.jpg","thumbnail":{"source":"https://upload.wikimedia.org/shrine.jpg"},"coordinates":[{"lat":33.5215,"lon":130.5349}]},
          {"title":"그림 파일","index":0,"pageimage":"Logo.svg","thumbnail":{"source":"https://upload.wikimedia.org/logo.png"},"coordinates":[{"lat":33.5215,"lon":130.5349}]},
          {"title":"좌표 없는 항목","index":0,"pageimage":"NoSpot.jpg","thumbnail":{"source":"https://upload.wikimedia.org/nospot.jpg"}}
        ]}}
        """#.utf8)
        let pick = try XCTUnwrap(TravelWikiPhoto.pick(found, name: "다자이후 텐만구", latitude: 33.5215, longitude: 130.5349))
        XCTAssertEqual(pick.file, "Shrine.jpg", "가깝고 이름이 맞는 항목이 먼저")
        XCTAssertEqual(TravelWikiPhoto.pick(found, name: "이름이 안 맞는 곳", latitude: 33.5215, longitude: 130.5349)?.file, "Near.jpg", "이름이 안 맞으면 가까운 것 가운데 찾은 순서")
        XCTAssertNil(TravelWikiPhoto.pick(found, name: "다자이후 텐만구", latitude: 37.5, longitude: 127.0), "3km 밖이면 쓰지 않는다")
        XCTAssertNil(TravelWikiPhoto.pick(Data("깨진 응답".utf8), name: "x", latitude: 0, longitude: 0))

        let meta = Data(#"{"query":{"pages":[{"imageinfo":[{"extmetadata":{"Artist":{"value":"<a href=\"//commons.wikimedia.org/wiki/User:X\">Hong &amp; Kim</a>"},"LicenseShortName":{"value":"CC BY-SA 4.0"}}}]}]}}"#.utf8)
        XCTAssertEqual(TravelWikiPhoto.credit(meta), "Hong & Kim · CC BY-SA 4.0 · Wikimedia Commons")
        let noLicense = Data(#"{"query":{"pages":[{"imageinfo":[{"extmetadata":{"Artist":{"value":"누군가"}}}]}]}}"#.utf8)
        XCTAssertNil(TravelWikiPhoto.credit(noLicense), "라이선스가 없으면 그 사진을 쓰지 않는다")

        XCTAssertEqual(TravelWikiPhoto.cacheKey(name: "다자이후 텐만구", latitude: 33.52151, longitude: 130.53492), TravelWikiPhoto.cacheKey(name: "다자이후텐만구", latitude: 33.52149, longitude: 130.53488))
        XCTAssertNotEqual(TravelWikiPhoto.cacheKey(name: "다자이후 텐만구", latitude: 33.5215, longitude: 130.5349), TravelWikiPhoto.cacheKey(name: "다자이후 텐만구", latitude: 33.6, longitude: 130.5349))
        let old = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(TravelWikiPhoto.evictions([("a", 60, old.addingTimeInterval(30)), ("b", 50, old), ("c", 40, old.addingTimeInterval(10))], limitBytes: 100), ["b"], "오래 안 쓴 것부터 상한 아래까지")
        XCTAssertEqual(TravelWikiPhoto.evictions([("a", 60, old)], limitBytes: 100), [])

        let stops = [TravelPlanStop(id: UUID(), title: "성", latitude: 1, longitude: 2, day: old, order: 0, planID: nil, tripID: "t1", itemID: "a"),
                     TravelPlanStop(id: UUID(), title: "다른 여행", latitude: 1, longitude: 2, day: old, order: 0, planID: nil, tripID: "t2", itemID: "b")]
        XCTAssertEqual(TravelPlacePhotoStore.Place.places(tripID: "t1", stops: stops), [.init(itemID: "a", name: "성", latitude: 1, longitude: 2)])
    }

    /// TVV1113A01 C4: 세부 계획은 코스 번호에서 빠지고 그 곳 아래에 딸린다. 새 세부의 시각은 그 곳 안에서 잡힌다.
    func testCourseDetailsHangUnderTheirStop() {
        func block(_ id: String, _ start: Int, _ end: Int, parent: String? = nil) -> TravelPlanTableModel.Block {
            .init(id: id, column: 0, startMinute: start, endMinute: end, title: id, tripStatus: nil, status: .pending, parentID: parent)
        }
        let stop = block("a", 540, 720), blocks = [block("d2", 600, 630, parent: "a"), stop, block("b", 780, 840), block("d1", 540, 570, parent: "a"), block("x", 900, 930, parent: "다른 날의 곳")]
        XCTAssertEqual(TravelCourse.ordered(blocks).map(\.id), ["a", "b", "x"], "세부는 빠지고, 딸린 곳이 그날에 없으면 굵은 곳")
        XCTAssertEqual(TravelCourse.details(of: stop, in: blocks).map(\.id), ["d1", "d2"])
        var slot = TravelCourse.detailSlot(parent: stop, details: TravelCourse.details(of: stop, in: blocks))
        XCTAssertEqual([slot.start, slot.duration], [630, 30], "마지막 세부 끝에서 30분")
        slot = TravelCourse.detailSlot(parent: stop, details: [])
        XCTAssertEqual([slot.start, slot.duration], [540, 30], "세부가 없으면 그 곳 시작부터")
        slot = TravelCourse.detailSlot(parent: stop, details: [block("d", 600, 715, parent: "a")])
        XCTAssertEqual([slot.start, slot.duration], [705, 15], "자리가 모자라면 끝 15분")
        slot = TravelCourse.detailSlot(parent: block("s", 600, 610), details: [])
        XCTAssertEqual([slot.start, slot.duration], [600, 10], "짧은 곳은 그 길이만큼")
    }

    /// TVV1113A01 C4: 코스 곳을 옮기면 세부도 같은 만큼 옮겨지고, 지우면 함께 지워지며 한 번에 되돌아온다.
    @MainActor
    func testDetailsFollowTheirStopWhenMovedAndDeleted() async throws {
        let model = try await importedModel()
        let stop = try XCTUnwrap(model.settings.travelTripItems?.first { $0.tripID == "t1" })
        let detailStart = stop.start.addingTimeInterval(600)
        let addedID = await model.addTripItem(
            tripID: "t1", kind: .other, title: "표 사기", start: detailStart, end: detailStart.addingTimeInterval(900),
            offsetSeconds: stop.startOffsetSeconds, parentItemID: stop.itemID
        )
        let detailID = try XCTUnwrap(addedID)
        var detail = try XCTUnwrap(model.settings.travelTripItems?.first { $0.itemID == detailID })
        XCTAssertEqual(detail.parentItemID, stop.itemID)
        let count = try XCTUnwrap(model.settings.travelTripItems?.count)

        let moved = await model.moveTripItem(tripID: "t1", itemID: stop.itemID, by: 1_800)
        XCTAssertTrue(moved)
        detail = try XCTUnwrap(model.settings.travelTripItems?.first { $0.itemID == detailID })
        XCTAssertEqual(detail.start, detailStart.addingTimeInterval(1_800), "세부도 같은 만큼")
        let unmoved = await model.moveTripItem(tripID: "t1", itemID: detailID, by: 300)
        XCTAssertTrue(unmoved)
        XCTAssertEqual(model.settings.travelTripItems?.first { $0.itemID == stop.itemID }?.start, stop.start.addingTimeInterval(1_800), "세부만 옮기면 곳은 그대로")

        var history = TravelPlanHistory()
        let deletion = await model.deleteTripItemWithDetails(tripID: "t1", itemID: stop.itemID)
        let step = try XCTUnwrap(deletion)
        XCTAssertEqual(step.group.map(\.itemID), [detailID, stop.itemID], "세부 먼저, 곳은 마지막")
        XCTAssertEqual(model.settings.travelTripItems?.count, count - 2)
        history.record(step)
        await model.applyTravelHistory(try XCTUnwrap(history.undo()))
        XCTAssertEqual(model.settings.travelTripItems?.count, count)
        XCTAssertEqual(model.settings.travelTripItems?.first { $0.itemID == detailID }?.parentItemID, stop.itemID, "되돌리면 곳과 세부가 다시 이어진다")
    }

    /// TVU1113A01: 시각 고치기를 여러 번 되돌리고 다시 한다. 새로 고치면 다시 하기는 비고, 다른 여행이면 앞의 것을 버린다.
    func testPlanHistoryUndoesAndRedoesTimeEdits() {
        func step(_ item: String, move: Int = 0, resize: Int = 0, trip: String = "t1") -> TravelPlanHistory.Step {
            .init(tripID: trip, itemID: item, move: move, resize: resize, summary: item)
        }
        var history = TravelPlanHistory()
        XCTAssertNil(history.undo())
        history.record(step("a", move: 5))
        history.record(step("a", move: 5))
        history.record(step("b", resize: -15))
        XCTAssertEqual(history.summary, "b")
        XCTAssertEqual(history.undo(), step("b", resize: 15), "되돌릴 때는 반대 방향")
        XCTAssertEqual(history.undo(), step("a", move: -5))
        XCTAssertTrue(history.canUndo && history.canRedo)
        XCTAssertEqual(history.redo(), step("a", move: 5))
        history.record(step("c", move: 30))
        XCTAssertFalse(history.canRedo, "새로 고치면 다시 하기는 빈다")
        XCTAssertEqual(history.done.map(\.itemID), ["a", "a", "c"])
        history.record(step("z", move: 10, trip: "t2"))
        XCTAssertEqual(history.done.map(\.itemID), ["z"], "다른 여행이면 앞의 것을 버린다")
        XCTAssertEqual(history.tripID, "t2")
        for index in 0..<60 { history.record(step("n\(index)", move: 5, trip: "t2")) }
        XCTAssertEqual(history.done.count, TravelPlanHistory.limit)
    }

    /// TVU1113A01: 지운 일정을 되돌리면 같은 번호·시각·메모·색·예상 지출·상태로 돌아오고, 다시 하면 또 지워진다. 넣은 일정도 같다.
    @MainActor
    func testDeletingAndAddingItemsCanBeUndone() async throws {
        let model = try await importedModel()
        let before = try XCTUnwrap(model.settings.travelTripItems)
        var victim = try XCTUnwrap(before.first { $0.tripID == "t1" })
        _ = await model.updateTripItem(tripID: "t1", itemID: victim.itemID, kind: TripImportItem.Kind(rawValue: victim.kind) ?? .other, title: victim.title,
                                       start: victim.start, end: victim.end, note: "창가 자리", style: ("#2E7D6B", 9_000))
        victim = try XCTUnwrap(model.settings.travelTripItems?.first { $0.itemID == victim.itemID })
        let place = TravelPlanHistory.place(of: victim, stops: model.settings.travelPlanStops)

        var history = TravelPlanHistory()
        let deleted = await model.deleteTripItem(tripID: "t1", itemID: victim.itemID)
        XCTAssertTrue(deleted)
        history.record(.existence(victim, place: place, exists: false))
        XCTAssertEqual(history.summary, "－ " + victim.title)
        XCTAssertNil(model.settings.travelTripItems?.first { $0.itemID == victim.itemID })

        await model.applyTravelHistory(try XCTUnwrap(history.undo()))
        var back = try XCTUnwrap(model.settings.travelTripItems?.first { $0.itemID == victim.itemID }, "같은 번호로 돌아온다")
        XCTAssertEqual([back.kind, back.title, back.note ?? "", back.colorHex ?? "", back.status ?? ""], [victim.kind, victim.title, "창가 자리", "#2E7D6B", victim.status ?? ""])
        XCTAssertEqual(back.start, victim.start)
        XCTAssertEqual(back.end, victim.end)
        XCTAssertEqual(back.plannedSpendKRW, 9_000)
        XCTAssertEqual(TravelPlanHistory.place(of: back, stops: model.settings.travelPlanStops), place, "장소가 있었으면 핀도 돌아온다")
        XCTAssertNotNil(back.planID.flatMap { id in model.snapshot.plans.first { $0.id == id } }, "일상 쪽 계획 기록도 다시 생긴다")
        XCTAssertEqual(model.settings.travelTripItems?.count, before.count)

        await model.applyTravelHistory(try XCTUnwrap(history.redo()))
        XCTAssertNil(model.settings.travelTripItems?.first { $0.itemID == victim.itemID }, "다시 하면 또 지워진다")

        // 넣은 일정: 되돌리면 지워지고, 다시 하면 같은 번호로 돌아온다.
        let start = victim.end
        let addedID = await model.addTripItem(tripID: "t1", kind: .cafe, title: "카페", start: start, end: start.addingTimeInterval(1_800), offsetSeconds: victim.startOffsetSeconds)
        let added = try XCTUnwrap(model.settings.travelTripItems?.first { $0.itemID == addedID })
        history.record(.existence(added, place: nil, exists: true))
        await model.applyTravelHistory(try XCTUnwrap(history.undo()))
        XCTAssertNil(model.settings.travelTripItems?.first { $0.itemID == added.itemID })
        await model.applyTravelHistory(try XCTUnwrap(history.redo()))
        back = try XCTUnwrap(model.settings.travelTripItems?.first { $0.itemID == added.itemID })
        XCTAssertEqual(back.title, "카페")
    }

    /// TVU1113A01: 지도 핀을 누르면 그 일정의 날·시작 시각으로 가고, 길게 누른 자리는 주소가 없으면 좌표가 이름이 된다.
    func testPinFocusAndMapSpotName() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-21T00:30:00+09:00"))
        let item = TravelTripItem(tripID: "t1", itemID: "a", kind: "meal", title: "야타이", start: start, end: start.addingTimeInterval(3_600),
                                  startOffsetSeconds: 32_400, endOffsetSeconds: 32_400, planID: nil)
        let focus = TravelMapSpot.focus(item)
        XCTAssertEqual(focus.dayKey, "2026-11-21", "그곳 날짜")
        XCTAssertEqual(focus.minute, 30)
        XCTAssertEqual(TravelMapSpot.fallbackName(latitude: 33.59012, longitude: 130.40171), "33.5901, 130.4017")
    }

    /// TVZ1112A01: 지출은 그 시각의 일정 칸에 모이고(겹치면 늦게 시작한 일정), 이동 일정은 탈것을 먼저 권한다.
    func testSpendByItemAndVehicleSuggestions() throws {
        let base = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-03T10:00:00+09:00"))
        func item(_ id: String, _ kind: String, _ title: String, _ from: Double, _ to: Double, trip: String = "t1") -> TravelTripItem {
            TravelTripItem(tripID: trip, itemID: id, kind: kind, title: title, start: base.addingTimeInterval(from * 3_600), end: base.addingTimeInterval(to * 3_600),
                           startOffsetSeconds: 32_400, endOffsetSeconds: 32_400, planID: nil)
        }
        func spend(_ hours: Double, _ won: Double, trip: String? = "t1", kind: LedgerEntry.Kind = .expense) -> LedgerEntry {
            LedgerEntry(occurredAt: base.addingTimeInterval(hours * 3_600), amount: won, amountKRW: won, kind: kind, title: "x", tripID: trip)
        }
        let items = [item("a", "sight", "성", 0, 2), item("b", "meal", "라멘", 1, 2), item("c", "transfer", "지하철", 2, 3), item("z", "meal", "다른 여행", 0, 5, trip: "t2")]
        var canceled = spend(0.5, 9_000)
        canceled.canceledAt = base
        let spent = TravelPlanSpend.byItem(items: items, tripID: "t1", entries: [
            spend(0.5, 1_000), spend(1.5, 2_000), spend(1.75, 500), spend(2, 300), spend(3, 700), spend(0.5, 4_000, trip: nil),
            spend(0.5, 8_000, kind: .income), canceled,
        ])
        XCTAssertEqual(spent, ["a": 1_000, "b": 2_500, "c": 300], "끝 시각과 다른 여행·수입·취소는 세지 않는다")
        XCTAssertEqual(TravelPlanSpend.draft(tripID: "t1", at: base).occurredAt, base)

        let vehicles = ["도보", "지하철", "버스"]
        XCTAssertEqual(TravelQuickEntrySheet.suggestions(items: items, tripID: "t1", kind: .transfer, typed: "버스", vehicles: vehicles), ["도보", "지하철"])
        XCTAssertEqual(TravelQuickEntrySheet.suggestions(items: items, tripID: "t1", kind: .meal, typed: "", vehicles: vehicles), ["라멘"])
    }

    /// TVY1112A01: 일정 메모는 넘겨준 때만 바뀌고, 빈 글이면 지워진다. 계획표 확대 배율에 맞춰 누른 자리를 읽는다.
    @MainActor
    func testItemNoteAndZoomedTable() async throws {
        let model = try await importedModel()
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-03T12:00:00+07:00"))
        let added = await model.addTripItem(
            tripID: "t1", kind: .meal, title: "점심", start: start, end: start.addingTimeInterval(3_600), offsetSeconds: 7 * 3_600, note: "  창가 자리 예약  "
        )
        let itemID = try XCTUnwrap(added)
        XCTAssertEqual(model.settings.travelTripItems?.first { $0.itemID == itemID }?.note, "창가 자리 예약")
        var done = await model.updateTripItem(tripID: "t1", itemID: itemID, kind: .meal, title: "점심", start: start, end: start.addingTimeInterval(3_600))
        XCTAssertTrue(done)
        XCTAssertEqual(model.settings.travelTripItems?.first { $0.itemID == itemID }?.note, "창가 자리 예약", "메모를 안 넘기면 그대로")
        done = await model.updateTripItem(tripID: "t1", itemID: itemID, kind: .meal, title: "점심", start: start, end: start.addingTimeInterval(3_600), note: " ")
        XCTAssertTrue(done)
        XCTAssertNil(model.settings.travelTripItems?.first { $0.itemID == itemID }?.note, "빈 글이면 지운다")

        let h = TravelPlanTable.minuteHeight
        XCTAssertEqual(TravelPlanTable.slot(x: 130, y: 720 * h * 2.2 + 4, width: 350, scale: 2.2)?.minute, 720)
        XCTAssertEqual(TravelPlanTable.scrubMinute(start: 0, translation: 600 * h * 0.6, scale: 0.6), 600)
        XCTAssertEqual(TravelPlanTable.moveDelta(translation: 30 * h * 1.5, start: 600, end: 660, scale: 1.5), 30)
    }

    /// TVX1112A01: 여행 날짜를 옮기면 일정 전체가 한 덩어리로 옮겨진다(대표 결정).
    @MainActor
    func testShiftingATripMovesEveryItemPlanAndPinTogether() async throws {
        let model = try await importedModel()
        let before = try XCTUnwrap(model.settings.travelTripItems)
        let pinDay = try XCTUnwrap(model.settings.travelPlanStops.first { $0.itemID == "a" }).day
        let plansBefore = Dictionary(uniqueKeysWithValues: before.compactMap { item in
            item.planID.flatMap { id in model.snapshot.plans.first { $0.id == id }.map { (item.itemID, $0.span) } }
        })
        var trip = try XCTUnwrap(model.settings.travelTrips?.first)
        trip.startDay = "2026-12-09"
        trip.endDay = "2026-12-11"
        let saved = await model.saveTravelTrip(trip)
        XCTAssertTrue(saved)
        let shifted = await model.shiftTravelTrip("t1", byDays: 7)
        XCTAssertTrue(shifted)

        let after = try XCTUnwrap(model.settings.travelTripItems)
        for old in before {
            let new = try XCTUnwrap(after.first { $0.itemID == old.itemID })
            XCTAssertEqual(new.start, old.start.addingTimeInterval(7 * 86_400))
            XCTAssertEqual(new.end, old.end.addingTimeInterval(7 * 86_400))
            XCTAssertEqual(new.startOffsetSeconds, old.startOffsetSeconds, "그곳 시각은 그대로")
            if let planID = new.planID, let span = plansBefore[old.itemID] {
                let plan = try XCTUnwrap(model.snapshot.plans.first { $0.id == planID })
                XCTAssertEqual(plan.span.start, span.start.addingTimeInterval(7 * 86_400), "일상 계획 기록도 함께")
            }
        }
        let pin = try XCTUnwrap(model.settings.travelPlanStops.first { $0.itemID == "a" })
        XCTAssertEqual(pin.day, Calendar.autoupdatingCurrent.date(byAdding: .day, value: 7, to: pinDay), "지도 핀 날짜도 함께")
        XCTAssertEqual(model.settings.travelTrips?.first?.startDay, "2026-12-09")
        XCTAssertEqual(model.settings.travelTrips?.first?.endDay, "2026-12-11")
        let nothing = await model.shiftTravelTrip("t1", byDays: 0)
        XCTAssertTrue(nothing)
    }

    /// TVX1112A01: 손으로 넣은 일정에 장소를 붙이면 지도 핀이 생기고, 옮기고 뗄 수 있다.
    @MainActor
    func testManualItemPlaceBecomesAMapPin() async throws {
        let model = try await importedModel()
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-03T12:00:00+07:00"))
        let place = TravelItemPlace(name: "짜뚜짝 시장", latitude: 13.7999, longitude: 100.5503)
        let added = await model.addTripItem(
            tripID: "t1", kind: .shopping, title: "시장", start: start, end: start.addingTimeInterval(3_600), offsetSeconds: 7 * 3_600, place: place
        )
        let itemID = try XCTUnwrap(added)
        var pin = try XCTUnwrap(model.settings.travelPlanStops.first { $0.itemID == itemID })
        XCTAssertEqual(pin.latitude, 13.7999)
        XCTAssertEqual(pin.title, "시장")
        XCTAssertEqual(pin.tripID, "t1")

        let moved = TravelItemPlace(name: "아이콘시암", latitude: 13.7266, longitude: 100.5108)
        var done = await model.updateTripItem(
            tripID: "t1", itemID: itemID, kind: .shopping, title: "쇼핑", start: start, end: start.addingTimeInterval(3_600), place: moved, replacesPlace: true
        )
        XCTAssertTrue(done)
        pin = try XCTUnwrap(model.settings.travelPlanStops.first { $0.itemID == itemID })
        XCTAssertEqual(pin.longitude, 100.5108)
        XCTAssertEqual(pin.title, "쇼핑")

        done = await model.updateTripItem(tripID: "t1", itemID: itemID, kind: .shopping, title: "쇼핑", start: start, end: start.addingTimeInterval(3_600))
        XCTAssertTrue(done)
        XCTAssertNotNil(model.settings.travelPlanStops.first { $0.itemID == itemID }, "장소를 건드리지 않으면 핀은 그대로")
        done = await model.updateTripItem(
            tripID: "t1", itemID: itemID, kind: .shopping, title: "쇼핑", start: start, end: start.addingTimeInterval(3_600), place: nil, replacesPlace: true
        )
        XCTAssertTrue(done)
        XCTAssertNil(model.settings.travelPlanStops.first { $0.itemID == itemID }, "장소를 떼면 핀이 없어진다")
    }

    /// TVX1112A01: 여행 지우기는 일정·일상 계획·핀을 함께 지우고, 날짜 없는 여행도 저장된다.
    @MainActor
    func testDeletingATripRemovesItsItemsPlansAndPins() async throws {
        let model = try await importedModel()
        let planIDs = try XCTUnwrap(model.settings.travelTripItems).compactMap(\.planID)
        XCTAssertFalse(planIDs.isEmpty)
        let wish = TravelTrip(id: "wish", title: "도쿄", startDay: "", endDay: "", wishDays: 5)
        let saved = await model.saveTravelTrip(wish)
        XCTAssertTrue(saved, "날짜 없는 여행도 저장된다")
        let deleted = await model.deleteTravelTrip("t1")
        XCTAssertTrue(deleted)
        XCTAssertEqual(model.settings.travelTrips, [wish])
        XCTAssertNil(model.settings.travelTripItems)
        XCTAssertTrue(model.settings.travelPlanStops.isEmpty)
        for id in planIDs { XCTAssertNil(model.snapshot.plans.first { $0.id == id }) }
        let missing = await model.deleteTravelTrip("")
        XCTAssertFalse(missing)
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

    /// 나라만 정한 여행은 대표 공항에, 공항표에 없는 나라는 땅 위에 꽂는다(TFP1113A01: 일본이 동해에 꽂힘).
    func testCountryOnlyTripFlagsTheMainAirportNotTheSea() throws {
        let japan = TravelModeDestination(trip: TravelTrip(id: "j", title: "스시", startDay: "2026-12-01", endDay: "2026-12-04", countryCode: "JP"), stops: [])
        let point = try XCTUnwrap(japan.point)
        XCTAssertEqual(point.x, 140.39, accuracy: 0.01)
        XCTAssertEqual(point.y, 35.77, accuracy: 0.01)
        let region = try XCTUnwrap(japan.country)
        XCTAssertFalse(region.contains(longitude: region.anchor.x, latitude: region.anchor.y), "네모 가운데는 바다였다")
        // 공항표에 없는 나라도 깃발이 그 땅 고리 위에 있다.
        let land = TravelModeRegions.landAnchor(region)
        let ring = try XCTUnwrap(region.rings.max { $0.count < $1.count })
        XCTAssertTrue(ring.contains(land) || region.contains(longitude: land.x, latitude: land.y))
        // 예전에 만든 여행은 네모 가운데를 좌표로 저장했다. 그 값이면 공항으로 꽂는다(TFP1114A01).
        let old = TravelModeDestination(trip: TravelTrip(id: "o", title: "스시", startDay: "", endDay: "", countryCode: "JP",
                                                         latitude: region.anchor.y, longitude: region.anchor.x, wishDays: 4), stops: [])
        XCTAssertEqual(try XCTUnwrap(old.point).x, 140.39, accuracy: 0.01)
        let chosen = TravelModeDestination(trip: TravelTrip(id: "c", title: "도쿄", startDay: "", endDay: "", countryCode: "JP",
                                                            latitude: 35.68, longitude: 139.77, wishDays: 2), stops: [])
        XCTAssertEqual(try XCTUnwrap(chosen.point).x, 139.77, accuracy: 0.001, "직접 정한 좌표는 그대로")
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
                    TravelGlobeRenderer.draw(&context, size: size, camera: camera, highlight: ["JP"], flags: [.init(longitude: 135.5, latitude: 34.7, text: "D-24", progress: 1)], pins: [])
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
                TravelGlobeRenderer.draw(&context, size: canvas, camera: camera, highlight: highlight, flags: flag.map { [$0] } ?? [], pins: pins)
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

/// TVC1112A01: 시간 막대의 계획 띠. 그날의 계획을 실제 기록과 견줘 상태를 붙인다.
final class TravelPlanBandTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .gmt
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 20) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private func segment(_ start: Int, _ end: Int, _ category: String, status: TripItemStatus? = nil) -> MapHomeTimeRailSegment {
        var segment = MapHomeTimeRailSegment(startMinute: start, endMinute: end, categoryID: category, title: category)
        segment.tripStatus = status
        return segment
    }

    func testBandMarksDoneLateSkippedAndPendingForToday() {
        let plan = [
            segment(600, 630, "movement", status: .booked),
            segment(720, 780, "eating"),
            segment(840, 960, "hobby", status: .tentative),
            segment(1_080, 1_140, "eating"),
        ]
        let actual = [
            segment(605, 628, "movement"),
            segment(745, 800, "eating"),
            segment(850, 950, "unconfirmed"),
        ]
        let band = TravelPlanBand.spans(plan: plan, actual: actual, day: at(0), now: at(16, 40), calendar: calendar)
        XCTAssertEqual(band.map(\.status), [.done, .late, .skipped, .pending], "미확인 구간은 한 것으로 치지 않는다")
        XCTAssertEqual(band.map(\.opacity), [1, 0.75, 0.4, 0.75])
        XCTAssertEqual(band.map(\.startMinute), [600, 720, 840, 1_080])
    }

    /// 시간 막대에 계획 띠와 실제 띠가 나란히 그려지는지 그림으로 남긴다(시뮬레이터에서만 파일을 쓴다).
    @MainActor
    func testSidebarDrawsPlanBesideActual() throws {
        let plan = [segment(600, 630, "movement", status: .booked), segment(720, 780, "eating"), segment(840, 960, "hobby", status: .tentative), segment(1_080, 1_140, "eating")]
        let actual = [segment(605, 628, "movement"), segment(745, 800, "eating"), segment(820, 1_000, "activity")]
        let band = TravelPlanBand.spans(plan: plan, actual: actual, day: at(0), now: at(16, 40), calendar: calendar)
        let view = MapHomeTimeSidebar(
            date: at(0), selectedMinute: .constant(1_000), visibleStartMinute: .constant(480), visibleDurationMinutes: .constant(720),
            segments: actual, planBand: band
        )
        .frame(width: 90, height: 620)
        .background(Color(hex: "#F6F1E4"))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage)
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/validation/TVC1112A01/shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: folder.appendingPathComponent("sidebar-plan-and-actual.png"))
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testFutureDayIsAllPendingAndPastDayWithoutRecordsIsSkipped() {
        let plan = [segment(600, 660, "hobby")]
        XCTAssertEqual(TravelPlanBand.spans(plan: plan, actual: [], day: at(0, day: 21), now: at(12), calendar: calendar).map(\.status), [.pending])
        XCTAssertEqual(TravelPlanBand.spans(plan: plan, actual: [], day: at(0, day: 19), now: at(12), calendar: calendar).map(\.status), [.skipped])
        XCTAssertTrue(TravelPlanBand.spans(plan: [], actual: [], day: at(0), now: at(12), calendar: calendar).isEmpty)
    }
}

/// TVD1112A01: 계획표 하루치 자료와 여행 날짜 목록.
final class TravelPlanTableTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .gmt
        return calendar
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private func item(_ id: String, _ kind: String, day: Int = 20, from: Int, to: Int, trip: String = "t", status: String? = nil) -> TravelTripItem {
        TravelTripItem(tripID: trip, itemID: id, kind: kind, title: id, start: at(day, from / 60, from % 60), end: at(day, to / 60, to % 60),
                       startOffsetSeconds: 32_400, endOffsetSeconds: 32_400, planID: nil, status: status)
    }

    private func record(_ start: Int, _ end: Int, _ category: String, _ title: String = "") -> MapHomeTimeRailSegment {
        MapHomeTimeRailSegment(startMinute: start, endMinute: end, categoryID: category, title: title)
    }

    func testBlocksGoToTheirColumnsWithStatusesAndUnplannedStops() {
        let items = [
            item("metro", "transfer", from: 600, to: 630), item("lunch", "meal", from: 720, to: 780, status: "booked"),
            item("castle", "sight", from: 840, to: 960), item("hotel", "lodging", from: 1_200, to: 1_260),
            item("other-day", "sight", day: 21, from: 600, to: 660), item("other-trip", "sight", from: 600, to: 660, trip: "x"),
        ]
        let actual = [record(605, 628, "movement"), record(745, 800, "eating", "라멘"), record(1_000, 1_040, "hobby", "기념품 가게"), record(300, 360, "unconfirmed")]
        let table = TravelPlanTableModel.make(items: items, tripID: "t", day: at(20, 0), actual: actual, now: at(20, 17), calendar: calendar)
        XCTAssertEqual(table.blocks.map(\.id), ["metro", "lunch", "castle", "hotel"])
        XCTAssertEqual(table.blocks.map(\.column), [0, 1, 2, 3])
        XCTAssertEqual(table.blocks.map(\.status), [.done, .late, .skipped, .pending])
        XCTAssertEqual(table.blocks[1].tripStatus, .booked)
        XCTAssertEqual(table.actuals.count, 3, "미확인 구간은 실제 띠에 넣지 않는다")
        XCTAssertEqual(table.actuals.filter(\.isUnplanned).map(\.title), ["기념품 가게"])
        XCTAssertEqual(table.nowMinute, 1_020)
        XCTAssertEqual(table.focusMinute, 960, "오늘은 지금 한 시간 전부터 보인다")
    }

    func testOtherDaysHaveNoNowLineAndStartNearTheFirstItem() {
        let items = [item("castle", "sight", day: 21, from: 840, to: 960)]
        let future = TravelPlanTableModel.make(items: items, tripID: "t", day: at(21, 0), actual: [], now: at(20, 17), calendar: calendar)
        XCTAssertNil(future.nowMinute)
        XCTAssertEqual(future.blocks.map(\.status), [.pending])
        XCTAssertEqual(future.focusMinute, 810)
        let empty = TravelPlanTableModel.make(items: [], tripID: "t", day: at(21, 0), actual: [], now: at(20, 17), calendar: calendar)
        XCTAssertEqual(empty.focusMinute, 510, "일정이 없으면 아침 8시 반")
        XCTAssertEqual(TravelPlanTableModel.column(forKind: "cafe"), 1)
        XCTAssertEqual(TravelPlanTableModel.column(forKind: "sleep"), 3)
        XCTAssertEqual(TravelPlanTableModel.column(forKind: "모르는 값"), 2)
    }

    func testTripDaysListEveryDayInOrder() {
        let trip = TravelTrip(id: "t", title: "오사카", startDay: "2026-11-19", endDay: "2026-11-22")
        let days = TravelPlanDays.days(of: trip, calendar: calendar)
        XCTAssertEqual(days.map(\.key), ["2026-11-19", "2026-11-20", "2026-11-21", "2026-11-22"])
        XCTAssertEqual(days.first?.date, at(19, 0))
        XCTAssertEqual(TravelPlanDays.days(of: TravelTrip(id: "d", title: "가평", startDay: "2026-11-08", endDay: "2026-11-08"), calendar: calendar).count, 1)
        XCTAssertTrue(TravelPlanDays.days(of: TravelTrip(id: "b", title: "거꾸로", startDay: "2026-11-09", endDay: "2026-11-08"), calendar: calendar).isEmpty)
    }

    /// 계획표와 작은 시간 막대를 그림으로 남긴다(시뮬레이터에서만 파일을 쓴다).
    @MainActor
    func testPlanTableAndMiniRailRender() throws {
        let items = [
            item("지하철", "transfer", from: 600, to: 630), item("점심 라멘", "meal", from: 720, to: 780, status: "booked"),
            item("오사카성", "sight", from: 840, to: 960, status: "tentative"), item("저녁", "meal", from: 1_080, to: 1_140), item("호텔 체크인", "lodging", from: 1_200, to: 1_260),
        ]
        let actual = [record(605, 628, "movement"), record(745, 800, "eating", "라멘"), record(1_000, 1_040, "hobby", "기념품 가게")]
        let table = TravelPlanTableModel.make(items: items, tripID: "t", day: at(20, 0), actual: actual, now: at(20, 17), calendar: calendar)
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/validation/TVD1112A01/shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tableImage = ImageRenderer(content: TravelPlanTable(table: table, language: .korean) { _ in }.dayBody
            .frame(width: 370).background(Color.white))
        tableImage.scale = 2
        try? XCTUnwrap(tableImage.uiImage).pngData()?.write(to: folder.appendingPathComponent("plan-table.png"))
        let rail = ImageRenderer(content: TravelMiniRail(table: table).frame(height: 520).padding(8).background(Color(hex: "#F6F1E4")))
        rail.scale = 3
        try? XCTUnwrap(rail.uiImage).pngData()?.write(to: folder.appendingPathComponent("mini-rail.png"))
        XCTAssertNotNil(tableImage.uiImage)
    }
}


/// TVE1112A01: 지구본 손가락 조작과 깃발.
final class TravelGlobeTouchTests: XCTestCase {
    func testDragRotatesWithTheFingerAndStopsBeforeThePoles() {
        let camera = TravelGlobeCamera(longitude: 127, latitude: 28, radius: 180 / Double.pi) // 1pt = 1도
        let moved = TravelGlobeTouch.rotated(camera, by: CGSize(width: 30, height: 10))
        XCTAssertEqual(moved.longitude, 97, accuracy: 1e-9, "오른쪽으로 끌면 서쪽 땅이 따라온다")
        XCTAssertEqual(moved.latitude, 38, accuracy: 1e-9)
        XCTAssertEqual(moved.radius, camera.radius)
        XCTAssertEqual(TravelGlobeTouch.rotated(camera, by: CGSize(width: 0, height: 500)).latitude, 80)
        XCTAssertEqual(TravelGlobeTouch.rotated(camera, by: CGSize(width: 0, height: -500)).latitude, -80)
        XCTAssertEqual(TravelGlobeTouch.rotated(camera, by: CGSize(width: -100, height: 0)).longitude, -133, accuracy: 1e-9, "날짜 변경선을 넘으면 −180~180으로 돌아온다")
        let zoomedIn = TravelGlobeCamera(longitude: 0, latitude: 0, radius: 1_800 / Double.pi)
        XCTAssertEqual(TravelGlobeTouch.rotated(zoomedIn, by: CGSize(width: 30, height: 0)).longitude, -3, accuracy: 1e-9, "확대하면 같은 거리에 덜 돈다")
    }

    func testPinchZoomIsClamped() {
        XCTAssertEqual(TravelGlobeTouch.zoomed(150, by: 2, rest: 150), 300)
        XCTAssertEqual(TravelGlobeTouch.zoomed(150, by: 0.1, rest: 150), 90, "기본 크기의 0.6배에서 멈춘다")
        XCTAssertEqual(TravelGlobeTouch.zoomed(50_000, by: 3, rest: 150), 60_000)
    }

    func testTappingNearAFlagPicksItAndHiddenFlagsAreIgnored() throws {
        let size = CGSize(width: 390, height: 760)
        let camera = TravelGlobeCamera(longitude: 127, latitude: 28, radius: 148)
        let osaka = TravelGlobeRenderer.Flag(id: "osaka", longitude: 135.5, latitude: 34.7, text: "", progress: 1)
        let bangkok = TravelGlobeRenderer.Flag(id: "bangkok", longitude: 100.5, latitude: 13.75, text: "", progress: 1)
        let paris = TravelGlobeRenderer.Flag(id: "paris", longitude: -60, latitude: -20, text: "", progress: 1)
        let foot = try XCTUnwrap(TravelGlobeRenderer.foot(of: osaka, camera: camera, size: size))
        XCTAssertNil(TravelGlobeRenderer.foot(of: paris, camera: camera, size: size), "지구 뒤쪽 깃발은 누를 수 없다")
        let flags = [osaka, bangkok, paris]
        XCTAssertEqual(TravelGlobeTouch.flag(at: foot, flags: flags, camera: camera, size: size), "osaka")
        XCTAssertEqual(TravelGlobeTouch.flag(at: CGPoint(x: foot.x + 12, y: foot.y - 28), flags: flags, camera: camera, size: size), "osaka", "깃발 천을 눌러도 된다")
        XCTAssertNil(TravelGlobeTouch.flag(at: CGPoint(x: foot.x + 80, y: foot.y), flags: flags, camera: camera, size: size))
        XCTAssertNil(TravelGlobeTouch.flag(at: CGPoint(x: 20, y: 20), flags: flags, camera: camera, size: size))
    }

    /// 색 견본은 메뉴가 한 색으로 덮어 칠하지 않게 원래 색 그림이어야 하고, 가운데가 그 색이다.
    func testSwatchKeepsItsOwnColor() throws {
        for hex in TravelInk.flagHexes {
            let image = TravelInk.swatch(hex, isChosen: false)
            XCTAssertEqual(image.renderingMode, .alwaysOriginal)
            let cg = try XCTUnwrap(image.cgImage)
            let data = try XCTUnwrap(cg.dataProvider?.data as Data?)
            let offset = (cg.height / 2) * cg.bytesPerRow + (cg.width / 2) * 4
            var expected = UInt64(0)
            Scanner(string: String(hex.dropFirst())).scanHexInt64(&expected)
            let channels = Set([Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2])])
            XCTAssertEqual(channels, Set([Int(expected >> 16 & 0xFF), Int(expected >> 8 & 0xFF), Int(expected & 0xFF)]), hex)
        }
        XCTAssertNotEqual(TravelInk.swatch("#C8442E", isChosen: true).pngData(), TravelInk.swatch("#C8442E", isChosen: false).pngData(), "고른 색에는 체크가 그려진다")
    }

    func testFlagColorsFollowOrderUnlessTheUserChoseOne() {
        let trip = TravelTrip(id: "t", title: "일본", startDay: "2026-11-23", endDay: "2026-11-27")
        XCTAssertEqual(TravelInk.flagHex(trip, order: 0), "#C8442E")
        XCTAssertEqual(TravelInk.flagHex(trip, order: 1), "#2F3E6B")
        XCTAssertEqual(TravelInk.flagHex(trip, order: TravelInk.flagHexes.count), "#C8442E", "색이 모자라면 처음부터 다시")
        var chosen = trip
        chosen.flagColorHex = "#2E7D6B"
        XCTAssertEqual(TravelInk.flagHex(chosen, order: 0), "#2E7D6B")
    }
}

/// 언젠가 여행도 1일차·2일차로 짠다(WPS1114A01).
final class WishTripPlanDaysTests: XCTestCase {
    func testWishTripGetsDayColumnsWithoutRealDates() {
        let wish = TravelTrip(id: "w", title: "스시", startDay: "", endDay: "", countryCode: "JP", wishDays: 4)
        XCTAssertTrue(wish.isWish)
        XCTAssertEqual(wish.planStartDay, TravelTrip.wishAnchorDay)
        XCTAssertEqual(wish.planEndDay, "2100-01-04")
        XCTAssertEqual(TravelPlanDays.days(of: wish).map(\.key), ["2100-01-01", "2100-01-02", "2100-01-03", "2100-01-04"])
        let dated = TravelTrip(id: "d", title: "방콕", startDay: "2026-12-01", endDay: "2026-12-05")
        XCTAssertEqual(dated.planStartDay, "2026-12-01")
        XCTAssertEqual(TravelPlanDays.days(of: dated).count, 5)
        XCTAssertEqual(TravelTripDay.days(from: wish.planStartDay, to: "2026-12-01").map { $0 < 0 }, true, "날짜를 정하면 기준일에서 그날로 옮길 날 수가 나온다")
    }
}
