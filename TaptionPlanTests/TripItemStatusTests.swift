import XCTest
@testable import TaptionPlan

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
}
