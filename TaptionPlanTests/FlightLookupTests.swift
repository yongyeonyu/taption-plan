import XCTest
@testable import TaptionPlan
import TaptionPlanEngine
import TaptionPlanStore

/// FLT1119A01: 항공편 조회 응답 읽기·합치기·쿼리. 값은 전부 익명이다.
final class FlightLookupTests: XCTestCase {
    private func reply(source: String = "season", available: Bool? = nil, flights: String, updatedAt: String? = "2027-03-07T03:00:00.000Z") -> Data {
        let extra = (available.map { #","available":\#($0)"# } ?? "") + (updatedAt.map { #","updatedAt":"\#($0)""# } ?? "")
        return Data(#"{"airport":"ICN","date":"2027-03-07","direction":"dep","source":"\#(source)"\#(extra),"flights":[\#(flights)]}"#.utf8)
    }

    private func row(_ flight: String = "AB123", time: String = "09:05", destination: String = "BKK", status: String? = nil, terminal: String? = "2") -> String {
        let terminalText = terminal.map { #""\#($0)""# } ?? "null"
        return #"{"flight":"\#(flight)","airline":"\#(flight.prefix(2))","origin":"ICN","destination":"\#(destination)","time":"\#(time)","dayOffset":0,"terminal":\#(terminalText),"gate":null,"codeshare":false,"master":"\#(flight)","season":"2027S","status":\#(status ?? "null")}"#
    }

    func testQueryCarriesOnlyAirportDateDirectionAndFlight() {
        let items = FlightLookup.query(airport: "icn", day: "2027-03-07", direction: .dep, flight: " ab 123 ")
        XCTAssertEqual(items.map(\.name), ["airport", "date", "direction", "flight"])
        XCTAssertEqual(items.map(\.value), ["ICN", "2027-03-07", "dep", "AB123"])
        XCTAssertEqual(FlightLookup.query(airport: "GMP", day: "2027-03-07", direction: .arr).map(\.name), ["airport", "date", "direction"])
        XCTAssertEqual(FlightLookup.query(airport: "GMP", day: "2027-03-07", direction: .arr, flight: "  ").map(\.name).count, 3)
    }

    func testDecodeReadsRowsSourceAndUpdatedAt() throws {
        guard case .found(let found) = FlightLookup.decode(reply(flights: row() + "," + row("CD456", time: "15:55", destination: "NRT")), status: 200) else { return XCTFail("읽혀야 한다") }
        XCTAssertEqual(found.flights.map(\.flight), ["AB123", "CD456"])
        XCTAssertEqual(found.source, .season)
        XCTAssertTrue(found.isAvailable)
        XCTAssertNotNil(found.updatedAt)
        XCTAssertEqual(found.flights[0].terminal, "2")
        XCTAssertNil(found.flights[0].status)
    }

    func testDecodeDropsMalformedRowsAndMapsStatusCodes() {
        guard case .found(let found) = FlightLookup.decode(reply(flights: row() + "," + row("AB1", time: "25:00") + "," + row("CD456", time: "bad") + "," + row("EF789", destination: "TOOLONG")), status: 200) else { return XCTFail() }
        XCTAssertEqual(found.flights.map(\.flight), ["AB123"], "시각·공항 모양이 다른 줄은 버린다")
        XCTAssertEqual(FlightLookup.decode(Data(), status: 503), .unavailable(.keyMissing))
        XCTAssertEqual(FlightLookup.decode(Data(), status: 429), .unavailable(.limited))
        XCTAssertEqual(FlightLookup.decode(Data(), status: 422), .unavailable(.outOfRange))
        XCTAssertEqual(FlightLookup.decode(Data(), status: 400), .unavailable(.outOfRange))
        XCTAssertEqual(FlightLookup.decode(Data(), status: 502), .unavailable(.failed))
        XCTAssertEqual(FlightLookup.decode(Data("not json".utf8), status: 200), .unavailable(.failed))
        XCTAssertEqual(FlightLookup.decode(Data(#"{"hello":1}"#.utf8), status: 200), .unavailable(.failed))
        XCTAssertEqual(FlightLookup.decode(Data(count: FlightLookup.maximumBytes + 1), status: 200), .unavailable(.failed))
    }

    func testStatusSourceAndUnavailableFlag() {
        let live = #"{"state":"delayed","scheduled":"09:05","expected":"10:10","delayMinutes":65,"terminal":"1","gate":"252","baggage":null}"#
        guard case .found(let found) = FlightLookup.decode(reply(source: "status", available: true, flights: row(status: live)), status: 200) else { return XCTFail() }
        XCTAssertEqual(found.source, .status)
        XCTAssertEqual(found.flights[0].status?.delayMinutes, 65)
        XCTAssertTrue(found.flights[0].status?.isProblem == true)
        guard case .found(let none) = FlightLookup.decode(reply(source: "status", available: false, flights: ""), status: 200) else { return XCTFail() }
        XCTAssertFalse(none.isAvailable)
        XCTAssertTrue(none.flights.isEmpty)
    }

    func testMergeAttachesLiveStatusByFlightAndScheduledTime() throws {
        let live = #"{"state":"delayed","scheduled":"09:05","expected":"10:10","delayMinutes":65,"terminal":"1","gate":"252","baggage":null}"#
        guard case .found(let schedule) = FlightLookup.decode(reply(flights: row() + "," + row("CD456", time: "15:55")), status: 200),
              case .found(let status) = FlightLookup.decode(reply(source: "status", available: true, flights: row(status: live)), status: 200) else { return XCTFail() }
        let merged = try XCTUnwrap(FlightLookup.merged(schedule: schedule, status: status))
        XCTAssertEqual(merged.source, .status)
        XCTAssertEqual(merged.flights[0].status?.expected, "10:10")
        XCTAssertEqual(merged.flights[0].terminal, "1", "운항현황의 터미널이 앞선다")
        XCTAssertEqual(merged.flights[0].gate, "252")
        XCTAssertNil(merged.flights[1].status, "현황이 없는 줄은 정기 그대로")
        XCTAssertEqual(merged.flights.count, 2)
        // 현황을 못 받으면 정기 스케줄 그대로(「정기 스케줄 기준」).
        XCTAssertEqual(FlightLookup.merged(schedule: schedule, status: nil), schedule)
        XCTAssertEqual(FlightLookup.merged(schedule: nil, status: status), status)
        XCTAssertNil(FlightLookup.merged(schedule: nil, status: nil))
        var unavailable = status
        unavailable.isAvailable = false
        XCTAssertEqual(FlightLookup.merged(schedule: schedule, status: unavailable), schedule)
    }

    func testClockMinuteAndSearchLink() {
        XCTAssertEqual(FlightLookup.clockMinute("09:05"), 545)
        XCTAssertEqual(FlightLookup.clockMinute("00:00"), 0)
        XCTAssertNil(FlightLookup.clockMinute("24:00"))
        XCTAssertNil(FlightLookup.clockMinute("9"))
        XCTAssertNil(FlightLookup.clockMinute("09:60"))
        let url = FlightLookup.searchURL(for: " ab 123 ")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertTrue(url?.absoluteString.contains("AB123") == true)
        XCTAssertNil(FlightLookup.searchURL(for: "  "))
    }

    func testNoPersonalFieldAppearsInAnyQueryOrDecodedModel() {
        let names = Set(FlightLookup.query(airport: "ICN", day: "2027-03-07", direction: .dep, flight: "AB123").map(\.name))
        XCTAssertTrue(names.isDisjoint(with: ["pnr", "name", "phone", "booking", "reservation"]))
    }
}
