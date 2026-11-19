import XCTest
@testable import TaptionPlan
import TaptionPlanStore

/// FLT1119A01: 출발 당일 배너 줄(지연·터미널·탑승구·수하물, 정기/실시간).
final class FlightDayBoardTests: XCTestCase {
    /// 2027-03-07 09:05 KST.
    private let departure = Date(timeIntervalSince1970: 1_804_377_900)

    private func item(_ id: String = "i1", flight: String = "AB123", start: Date? = nil, origin: String = "ICN", destination: String = "BKK", terminal: String? = "2", gate: String? = nil, kind: String = "flight") -> TravelTripItem {
        var item = TravelTripItem(tripID: "t1", itemID: id, kind: kind, title: "\(flight) \(origin) → \(destination)", start: start ?? departure, end: (start ?? departure).addingTimeInterval(19_800),
                                  startOffsetSeconds: 32_400, endOffsetSeconds: 25_200, planID: nil)
        item.flightNumber = flight; item.originCode = origin; item.destinationCode = destination; item.terminal = terminal; item.gate = gate
        return item
    }

    private func listing(state: String = "delayed", delay: Int = 65, terminal: String? = "1", gate: String? = "252", baggage: String? = "7") -> FlightListing {
        FlightListing(flight: "AB123", airline: "AB", origin: "ICN", destination: "BKK", time: "09:05", dayOffset: 0, terminal: nil, gate: nil, codeshare: false, master: "AB123", season: nil,
                      status: FlightLiveStatus(state: state, scheduled: "09:05", expected: "10:10", delayMinutes: delay, terminal: terminal, gate: gate, baggage: baggage))
    }

    func testRowsShowStoredValuesAsScheduledWhenThereIsNoLiveStatus() throws {
        let rows = FlightDayBoard.rows(items: [item(gate: "10")], live: [:], now: departure.addingTimeInterval(-6 * 3_600))
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.timeText, "09:05")
        XCTAssertEqual([row.terminal, row.gate, row.baggage], ["2", "10", nil])
        XCTAssertFalse(row.isLive)
        XCTAssertEqual(row.delayMinutes, 0)
        XCTAssertFalse(row.isCancelled)
    }

    func testLiveStatusOverridesTerminalGateAndBaggageAndMarksLive() throws {
        let row = try XCTUnwrap(FlightDayBoard.rows(items: [item()], live: ["AB123": listing()], now: departure.addingTimeInterval(-6 * 3_600)).first)
        XCTAssertTrue(row.isLive)
        XCTAssertEqual(row.delayMinutes, 65)
        XCTAssertEqual([row.terminal, row.gate, row.baggage], ["1", "252", "7"])
        let cancelled = try XCTUnwrap(FlightDayBoard.rows(items: [item()], live: ["AB123": listing(state: "cancelled", delay: 0)], now: departure.addingTimeInterval(-3_600)).first)
        XCTAssertTrue(cancelled.isCancelled)
        // 정시 운항현황이면 저장된 지연이 아니라 0(실시간 값이 앞선다).
        let onTime = try XCTUnwrap(FlightDayBoard.rows(items: [item()], live: ["AB123": listing(state: "ontime", delay: 0, terminal: nil, gate: nil, baggage: nil)], now: departure.addingTimeInterval(-3_600)).first)
        XCTAssertEqual(onTime.delayMinutes, 0)
        XCTAssertEqual(onTime.terminal, "2", "현황에 값이 없으면 저장된 값")
    }

    func testWindowKeepsJustDepartedFlightsAndHidesFarOnes() {
        let now = departure
        XCTAssertEqual(FlightDayBoard.rows(items: [item()], live: [:], now: now.addingTimeInterval(-25 * 3_600)).count, 0, "24시간보다 먼 비행은 아직 안 보인다")
        XCTAssertEqual(FlightDayBoard.rows(items: [item()], live: [:], now: now.addingTimeInterval(-23 * 3_600)).count, 1)
        XCTAssertEqual(FlightDayBoard.rows(items: [item()], live: [:], now: now.addingTimeInterval(2 * 3_600)).count, 1, "떠난 지 3시간 안")
        XCTAssertEqual(FlightDayBoard.rows(items: [item()], live: [:], now: now.addingTimeInterval(4 * 3_600)).count, 0)
        XCTAssertEqual(FlightDayBoard.rows(items: [item(kind: "sight")].map { var i = $0; i.clearFlight(); return i }, live: [:], now: now).count, 0)
    }

    func testOnlyIncheonFlightsAreLookedUpAndOnlyPublicValuesAreAsked() throws {
        let outbound = item("o", flight: "AB123", origin: "ICN", destination: "BKK")
        let returning = item("r", flight: "AB124", start: departure.addingTimeInterval(4 * 86_400), origin: "BKK", destination: "ICN")
        let foreign = item("f", flight: "CD1", origin: "BKK", destination: "SIN")
        let asks = FlightDayBoard.lookups(items: [outbound, returning, foreign], now: departure.addingTimeInterval(4 * 86_400 - 3_600))
        XCTAssertEqual(asks.count, 1, "범위 안의 인천 도착편만")
        XCTAssertEqual(asks[0].flight, "AB124")
        XCTAssertEqual(asks[0].direction, .arr)
        XCTAssertEqual(asks[0].day.count, 10)
        let outAsk = try XCTUnwrap(FlightDayBoard.lookups(items: [outbound], now: departure.addingTimeInterval(-3_600)).first)
        XCTAssertEqual([outAsk.flight, outAsk.day], ["AB123", "2027-03-07"])
        XCTAssertEqual(outAsk.direction, .dep)
        XCTAssertTrue(FlightDayBoard.lookups(items: [foreign], now: departure).isEmpty, "인천이 아닌 구간은 묻지 않는다")
    }
}
