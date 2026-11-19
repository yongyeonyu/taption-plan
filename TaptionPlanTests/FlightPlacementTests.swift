import XCTest
@testable import TaptionPlan
import TaptionPlanEngine
import TaptionPlanStore

/// FLT1119A01: 고른 항공편을 여행 일정 칸으로. 시차·도착은 `FlightTimeMath`·`FlightAirportCatalog`만 쓴다.
final class FlightPlacementTests: XCTestCase {
    private func listing(_ flight: String = "AB123", origin: String = "ICN", destination: String = "BKK", time: String = "09:05") -> FlightListing {
        FlightListing(flight: flight, airline: String(flight.prefix(2)), origin: origin, destination: destination, time: time, dayOffset: 0, terminal: "2", gate: nil, codeshare: false, master: flight, season: "2027S", status: nil)
    }

    func testEstimatedMinutesFollowDistanceAndStayPlausible() throws {
        let bangkok = try XCTUnwrap(FlightPlacement.estimatedMinutes(origin: "ICN", destination: "BKK"))
        XCTAssertTrue((280...340).contains(bangkok), "인천~방콕 약 3,700km → 어림 \(bangkok)분")
        let jeju = try XCTUnwrap(FlightPlacement.estimatedMinutes(origin: "GMP", destination: "CJU"))
        XCTAssertTrue((60...90).contains(jeju), "김포~제주 약 450km")
        XCTAssertGreaterThanOrEqual(FlightPlacement.estimatedMinutes(origin: "ICN", destination: "GMP") ?? 0, 45)
        XCTAssertNil(FlightPlacement.estimatedMinutes(origin: "ICN", destination: "ZZZ"))
    }

    func testDepartureListingBecomesAnItemWithBothTimeZones() throws {
        let leg = try XCTUnwrap(FlightPlacement.leg(from: listing(), day: "2027-03-07", direction: .dep, durationMinutes: 330))
        let draft = try XCTUnwrap(FlightPlacement.draft(for: leg, legIndex: 0, itineraryID: "it-1"))
        // 2027-03-07 09:05 KST = 00:05Z, +330분 = 05:35Z = 방콕 12:35.
        XCTAssertEqual(draft.start.timeIntervalSince1970, 1_804_377_900)
        XCTAssertEqual(draft.end.timeIntervalSince(draft.start), 330 * 60)
        XCTAssertEqual(draft.startOffsetSeconds, 9 * 3_600)
        XCTAssertEqual(draft.endOffsetSeconds, 7 * 3_600)
        XCTAssertEqual(draft.title, "AB123 ICN → BKK")
        XCTAssertEqual(draft.fields, TravelFlightFields(flightNumber: "AB123", originCode: "ICN", destinationCode: "BKK", terminal: "2", legIndex: 0, itineraryID: "it-1"))
        XCTAssertFalse(draft.isEstimated, "비행 시간을 알면 어림이 아니다")
        XCTAssertEqual(draft.arrivalDayOffset, 0)
    }

    func testMissingDurationIsEstimatedAndFlagged() throws {
        let leg = try XCTUnwrap(FlightPlacement.leg(from: listing(), day: "2027-03-07", direction: .dep))
        let draft = try XCTUnwrap(FlightPlacement.draft(for: leg))
        XCTAssertTrue(draft.isEstimated)
        XCTAssertGreaterThan(draft.end, draft.start)
    }

    func testOvernightArrivalCountsTheLocalDayOffset() throws {
        let leg = try XCTUnwrap(FlightPlacement.leg(from: listing("AB901", destination: "CDG", time: "23:30"), day: "2027-05-01", direction: .dep, durationMinutes: 840))
        let draft = try XCTUnwrap(FlightPlacement.draft(for: leg))
        XCTAssertEqual(draft.arrivalDayOffset, 1)
    }

    func testArrivalListingDerivesDepartureBackwardsAndMarksEstimate() throws {
        // 귀국편: 인천 도착 08:30 조회줄. 출발(방콕)은 도착 시각에서 비행 시간을 거꾸로 뺀다.
        let row = listing("AB124", origin: "BKK", destination: "ICN", time: "08:30")
        let leg = try XCTUnwrap(FlightPlacement.leg(from: row, day: "2027-03-11", direction: .arr, durationMinutes: 330))
        let draft = try XCTUnwrap(FlightPlacement.draft(for: leg))
        XCTAssertTrue(draft.isEstimated)
        XCTAssertEqual(draft.end.timeIntervalSince(draft.start), 330 * 60)
        XCTAssertEqual(draft.startOffsetSeconds, 7 * 3_600)
        XCTAssertEqual(draft.endOffsetSeconds, 9 * 3_600)
        let local = Int(draft.end.timeIntervalSince1970) + draft.endOffsetSeconds
        XCTAssertEqual((local % 86_400) / 60, 8 * 60 + 30)
    }

    func testManualLegWithoutDurationIsEstimated() throws {
        let leg = try XCTUnwrap(FlightPlacement.manualLeg(flight: "AB123", origin: "ICN", destination: "DAD", day: "2027-03-07", minute: 545, durationMinutes: nil))
        XCTAssertEqual(leg.confidence, 0.8)
        XCTAssertTrue(try XCTUnwrap(FlightPlacement.draft(for: leg)).isEstimated)
    }

    func testManualLegUsesTypedTimeAndNormalizesFlight() throws {
        let leg = try XCTUnwrap(FlightPlacement.manualLeg(flight: " ab 123 ", origin: "ICN", destination: "DAD", day: "2027-03-07", minute: 9 * 60 + 5, durationMinutes: 300))
        XCTAssertEqual(leg.flight, "AB123")
        XCTAssertEqual(leg.airline, "AB")
        XCTAssertEqual(leg.source, "manual")
        XCTAssertEqual(leg.confidence, 1, "비행 시간을 적으면 어림이 아니다")
        let draft = try XCTUnwrap(FlightPlacement.draft(for: leg))
        XCTAssertFalse(draft.isEstimated)
        XCTAssertEqual(draft.endOffsetSeconds, 7 * 3_600)
        XCTAssertNil(FlightPlacement.manualLeg(flight: nil, origin: "ICN", destination: "DAD", day: "bad", minute: 10, durationMinutes: nil))
        XCTAssertNil(FlightPlacement.manualLeg(flight: nil, origin: "ICN", destination: "DAD", day: "2027-03-07", minute: 1_440, durationMinutes: nil))
        XCTAssertNil(FlightPlacement.manualLeg(flight: "", origin: "ICN", destination: "DAD", day: "2027-03-07", minute: 60, durationMinutes: nil)?.flight, "편명이 비면 nil")
    }

    func testUnknownAirportOrBrokenTimeGivesNoDraft() {
        XCTAssertNil(FlightPlacement.leg(from: listing(), day: "not-a-day", direction: .dep))
        XCTAssertNil(FlightPlacement.leg(from: listing(time: "bad"), day: "2027-03-07", direction: .dep))
        let unknown = FlightLeg(flight: "AB123", origin: "ICN", destination: "ZZZ", departure: FlightLocalTime(year: 2027, month: 3, day: 7, hour: 9, minute: 5), durationMinutes: 300)
        XCTAssertNil(FlightPlacement.draft(for: unknown))
        XCTAssertNil(FlightPlacement.draft(for: FlightLeg(origin: "ICN", destination: "BKK")))
    }

    func testTitleWithoutFlightNumber() {
        XCTAssertEqual(FlightPlacement.title(for: FlightLeg(origin: "ICN", destination: "DAD")), "ICN → DAD")
    }

    func testDefaultDayIsFirstDayOutboundAndLastDayReturning() {
        let trip = TravelTrip(id: "t1", title: "방콕", startDay: "2027-03-07", endDay: "2027-03-11")
        XCTAssertEqual(FlightPlacement.defaultDay(for: trip, returning: false), "2027-03-07")
        XCTAssertEqual(FlightPlacement.defaultDay(for: trip, returning: true), "2027-03-11")
        let someday = TravelTrip(id: "t2", title: "언젠가", startDay: "", endDay: "", wishDays: 5)
        XCTAssertNil(FlightPlacement.defaultDay(for: someday, returning: false))
    }

    func testTravelAirportsNowReadTheCatalog() {
        XCTAssertEqual(TravelAirports.coordinate("icn")?.latitude ?? 0, 37.46, accuracy: 0.001)
        XCTAssertEqual(TravelAirports.coordinate(" BKK ")?.longitude ?? 0, 100.75, accuracy: 0.001)
        XCTAssertNotNil(TravelAirports.coordinate("HIN"), "새로 늘어난 공항도 보인다")
        XCTAssertNil(TravelAirports.coordinate("XXX"))
        XCTAssertNil(TravelAirports.coordinate(nil))
    }
}
