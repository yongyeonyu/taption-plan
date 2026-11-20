import XCTest
@testable import TaptionPlan
import TaptionPlanStore

/// FLT1120A01: 항공편 찾기 화면의 순수 계산. 값은 전부 익명이다.
final class FlightSearchTests: XCTestCase {
    private func row(_ flight: String, _ origin: String, _ destination: String, time: String, dep: String? = nil, arr: String? = nil,
                     duration: Int? = nil, codeshare: Bool = false, master: String? = nil) -> FlightListing {
        FlightListing(flight: flight, airline: String(flight.prefix(2)), origin: origin, destination: destination, time: time,
                      departureTime: dep, arrivalTime: arr, durationMinutes: duration, dayOffset: 0, terminal: nil, gate: nil,
                      codeshare: codeshare, master: master ?? flight, season: nil, status: nil)
    }

    func testDomesticAirportsAreKoreaWithoutIncheon() {
        let codes = FlightSearch.domesticAirportCodes()
        XCTAssertEqual(codes.count, FlightPlacement.koreanAirports.count - 1)
        XCTAssertFalse(codes.contains("ICN"))
        XCTAssertTrue(FlightSearch.isDomestic("GMP", "CJU"))
        XCTAssertFalse(FlightSearch.isDomestic("ICN", "CJU"))
        XCTAssertFalse(FlightSearch.isDomestic("GMP", "NRT"))
        XCTAssertFalse(FlightSearch.isDomestic("GMP", nil))
    }

    func testDomesticUnionHasNoDuplicatesAndKeepsOneSidedFlights() {
        let dep = [row("AB101", "GMP", "CJU", time: "09:00", arr: "10:10"), row("AB103", "GMP", "CJU", time: "12:00")]
        let arr = [row("AB101", "GMP", "CJU", time: "10:10"), row("AB105", "GMP", "CJU", time: "18:30"), row("ZZ9", "PUS", "CJU", time: "08:00")]
        let result = FlightSearch.domestic(dep: dep, arr: arr, origin: "GMP", destination: "CJU")
        XCTAssertEqual(Set(result.rows.map(\.listing.flight)), ["AB101", "AB103", "AB105"], "다른 노선 ZZ9는 뺀다")
        XCTAssertEqual(result.rows.count, 3, "양쪽에 있는 AB101은 한 줄")
    }

    func testArrivalComesFromServerThenPairedRowThenEstimate() throws {
        let dep = [row("AB101", "GMP", "CJU", time: "09:00", arr: "10:10", duration: 70), row("AB103", "GMP", "CJU", time: "12:00"), row("AB107", "GMP", "CJU", time: "14:00")]
        let arr = [row("AB103", "GMP", "CJU", time: "13:15")]
        let rows = FlightSearch.domestic(dep: dep, arr: arr, origin: "GMP", destination: "CJU").rows
        let a = try XCTUnwrap(rows.first { $0.listing.flight == "AB101" })
        XCTAssertEqual(a.arrivalMinute, 10 * 60 + 10); XCTAssertEqual(a.durationMinutes, 70); XCTAssertFalse(a.isEstimated)
        let b = try XCTUnwrap(rows.first { $0.listing.flight == "AB103" })
        XCTAssertEqual(b.arrivalMinute, 13 * 60 + 15); XCTAssertEqual(b.durationMinutes, 75); XCTAssertFalse(b.isEstimated)
        let c = try XCTUnwrap(rows.first { $0.listing.flight == "AB107" })
        XCTAssertTrue(c.isEstimated, "짝도 서버 도착 시각도 없으면 거리로 어림하고 숨기지 않는다")
        XCTAssertGreaterThanOrEqual(c.durationMinutes ?? 0, 45)
    }

    func testMidnightCrossingAddsOneDay() throws {
        let dep = [row("AB901", "GMP", "CJU", time: "23:50", arr: "00:20")]
        let r = try XCTUnwrap(FlightSearch.domestic(dep: dep, arr: [], origin: "GMP", destination: "CJU").rows.first)
        XCTAssertEqual(r.durationMinutes, 30)
        XCTAssertEqual(r.arrivalDayOffset, 1)
        XCTAssertEqual(FlightSearch.clockText(r.arrivalMinute), "00:20")
    }

    func testCodeshareRowsAreExcludedAndCounted() {
        let dep = [row("AB101", "GMP", "CJU", time: "09:00", arr: "10:10"),
                   row("XY555", "GMP", "CJU", time: "09:00", arr: "10:10", codeshare: true, master: "AB101"),
                   row("XY556", "GMP", "CJU", time: "11:00", arr: "12:10", master: "AB102")]
        let result = FlightSearch.domestic(dep: dep, arr: [], origin: "GMP", destination: "CJU")
        XCTAssertEqual(result.rows.map(\.listing.flight), ["AB101"])
        XCTAssertEqual(result.excludedCodeshare, 2)
    }

    func testArrivalOnlyFlightEstimatesTheDepartureBackwards() throws {
        let arr = [row("AB105", "GMP", "CJU", time: "18:30")]
        let r = try XCTUnwrap(FlightSearch.domestic(dep: [], arr: arr, origin: "GMP", destination: "CJU").rows.first)
        XCTAssertTrue(r.isEstimated)
        XCTAssertEqual(r.direction, .arr)
        XCTAssertEqual(r.arrivalMinute, 18 * 60 + 30)
        XCTAssertEqual((r.departureMinute ?? 0) + (r.durationMinutes ?? 0), 18 * 60 + 30)
    }

    func testSortAndDirectOnlyChangeOrderAndCount() {
        let dep = [row("AB1", "GMP", "CJU", time: "09:00", arr: "10:40"), row("AB2", "GMP", "CJU", time: "08:00", arr: "10:30"), row("AB3", "GMP", "CJU", time: "10:00", arr: "11:00")]
        let rows = FlightSearch.domestic(dep: dep, arr: [], origin: "GMP", destination: "CJU").rows
        XCTAssertEqual(FlightSearch.sorted(rows, by: .departure).map(\.listing.flight), ["AB2", "AB1", "AB3"])
        XCTAssertEqual(FlightSearch.sorted(rows, by: .arrival).map(\.listing.flight), ["AB2", "AB1", "AB3"])
        XCTAssertEqual(FlightSearch.sorted(rows, by: .duration).map(\.listing.flight).first, "AB3", "60분이 가장 짧다")
        var withShare = rows
        withShare[0].listing.codeshare = true
        XCTAssertEqual(FlightSearch.filtered(withShare, directOnly: true).count, 2)
        XCTAssertEqual(FlightSearch.filtered(withShare, directOnly: false).count, 3)
    }

    func testPickedDomesticRowBecomesCardWithKnownArrival() throws {
        let dep = [row("AB101", "GMP", "CJU", time: "09:00", arr: "10:10", duration: 70)]
        let r = try XCTUnwrap(FlightSearch.domestic(dep: dep, arr: [], origin: "GMP", destination: "CJU").rows.first)
        let draft = try XCTUnwrap(FlightPlacement.draft(from: r, day: "2027-03-07"))
        XCTAssertFalse(draft.isEstimated, "알려진 도착 시각이면 어림이 아니다")
        XCTAssertEqual(draft.end.timeIntervalSince(draft.start), 70 * 60)
        XCTAssertEqual(draft.fields.flightNumber, "AB101")
        XCTAssertEqual(draft.fields.originCode, "GMP")
        XCTAssertEqual(draft.fields.destinationCode, "CJU")
        let estimated = FlightSearch.domestic(dep: [row("AB107", "GMP", "CJU", time: "14:00")], arr: [], origin: "GMP", destination: "CJU").rows[0]
        XCTAssertEqual(FlightPlacement.draft(from: estimated, day: "2027-03-07")?.isEstimated, true)
    }

    func testDecodeNewOptionalFieldsAndRouteMissing() {
        let body = #"{"source":"season","flights":[{"flight":"AB101","airline":"AB","origin":"GMP","destination":"CJU","time":"09:00","departureTime":"09:00","arrivalTime":"10:10","durationMinutes":70,"dayOffset":0,"codeshare":false}]}"#
        guard case .found(let found) = FlightLookup.decode(Data(body.utf8), status: 200) else { return XCTFail() }
        XCTAssertEqual(found.flights[0].arrivalTime, "10:10")
        XCTAssertEqual(found.flights[0].durationMinutes, 70)
        XCTAssertEqual(FlightLookup.decode(Data(), status: 404), .unavailable(.routeMissing))
        let bad = body.replacingOccurrences(of: "\"arrivalTime\":\"10:10\"", with: "\"arrivalTime\":\"99:99\"")
        guard case .found(let dropped) = FlightLookup.decode(Data(bad.utf8), status: 200) else { return XCTFail() }
        XCTAssertTrue(dropped.flights.isEmpty, "모양이 틀린 시각 줄은 버린다")
    }

    func testRecentAirportsKeepFourMostRecentWithoutDuplicates() {
        var raw = ""
        for code in ["GMP", "CJU", "PUS", "TAE", "GMP", "KWJ"] { raw = FlightRecentAirports.adding(code, to: raw) }
        XCTAssertEqual(FlightRecentAirports.codes(raw), ["KWJ", "GMP", "TAE", "PUS"])
    }
}
