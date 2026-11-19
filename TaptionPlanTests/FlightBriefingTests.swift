import XCTest
@testable import TaptionPlan
import TaptionPlanEngine
import TaptionPlanStore

/// FLT1119A01: 출발 전 브리핑 알림 계획(출발 전날 저녁 8시·4시간 전·지연 즉시).
final class FlightBriefingTests: XCTestCase {
    /// 2027-03-07 09:05 KST = 00:05Z.
    private let departure = Date(timeIntervalSince1970: 1_804_377_900)

    private func flight(start: Date? = nil, origin: String = "ICN", destination: String = "BKK", offset: Int = 32_400, log: String? = nil, itemID: String = "i1", kind: String = "flight") -> TravelTripItem {
        var item = TravelTripItem(tripID: "t1", itemID: itemID, kind: kind, title: "AB123 \(origin) → \(destination)", start: start ?? departure, end: (start ?? departure).addingTimeInterval(18_000),
                                  startOffsetSeconds: offset, endOffsetSeconds: 25_200, planID: nil)
        item.originCode = origin
        item.destinationCode = destination
        item.flightLog = log
        return item
    }

    func testEveAndFourHoursBeforeAreScheduledInTheDepartureAirportsLocalTime() throws {
        let now = departure.addingTimeInterval(-3 * 86_400)
        let list = FlightBriefingPolicy.briefings(items: [flight()], now: now, language: .korean)
        XCTAssertEqual(list.map(\.kind), [.eve, .fourHours])
        // 전날(03/06) 20:00 KST = 11:00Z
        XCTAssertEqual(list[0].fireAt.timeIntervalSince1970, 1_804_377_900 - 13 * 3_600 - 5 * 60 + 0)
        XCTAssertEqual(list[1].fireAt, departure.addingTimeInterval(-4 * 3_600))
        XCTAssertTrue(list[0].title.contains("AB123 ICN → BKK"))
        XCTAssertEqual(list[0].body, "공항에 06:05까지 도착하세요.", "국제선은 출발 180분 전")
        XCTAssertTrue(list[0].id.hasPrefix("flight-"))
        XCTAssertNotEqual(list[0].id, list[1].id)
    }

    func testPastTimesAreDroppedAndOnlyFutureFlightsCount() {
        let afterEve = departure.addingTimeInterval(-10 * 3_600)
        XCTAssertEqual(FlightBriefingPolicy.briefings(items: [flight()], now: afterEve, language: .korean).map(\.kind), [.fourHours])
        let afterBoth = departure.addingTimeInterval(-3_600)
        XCTAssertTrue(FlightBriefingPolicy.briefings(items: [flight()], now: afterBoth, language: .korean).isEmpty)
        XCTAssertTrue(FlightBriefingPolicy.briefings(items: [flight()], now: departure.addingTimeInterval(60), language: .korean).isEmpty)
        XCTAssertTrue(FlightBriefingPolicy.briefings(items: [flight(kind: "sight")].map { var i = $0; i.clearFlight(); return i }, now: departure.addingTimeInterval(-86_400), language: .korean).isEmpty, "비행이 아닌 일정은 뺀다")
    }

    func testDomesticUsesSixtyMinutesAndOnsiteGuidanceOverrides() throws {
        let domestic = flight(start: departure, origin: "GMP", destination: "CJU")
        let list = FlightBriefingPolicy.briefings(items: [domestic], now: departure.addingTimeInterval(-86_400 * 2), language: .korean)
        XCTAssertEqual(list.first?.body, "공항에 08:05까지 도착하세요.")
        let guided = flight(log: #"{"onsiteArrive":150}"#)
        XCTAssertEqual(FlightBriefingPolicy.briefings(items: [guided], now: departure.addingTimeInterval(-86_400 * 2), language: .korean).first?.body, "공항에 06:35까지 도착하세요.", "현장 안내가 준 권장 시간이 앞선다")
        XCTAssertEqual(FlightBriefingPolicy.arriveBy(guided), departure.addingTimeInterval(-150 * 60))
    }

    func testEnglishWording() {
        let list = FlightBriefingPolicy.briefings(items: [flight()], now: departure.addingTimeInterval(-86_400 * 2), language: .english)
        XCTAssertEqual(list.first?.body, "Arrive at the airport by 06:05.")
        XCTAssertTrue(list.first?.title.hasPrefix("Departing tomorrow") == true)
    }

    func testOnlyTheNextEightFlightsAreScheduled() {
        let items = (0..<12).map { flight(start: departure.addingTimeInterval(Double($0) * 86_400 * 2), itemID: "i\($0)") }
        let list = FlightBriefingPolicy.briefings(items: items, now: departure.addingTimeInterval(-86_400 * 3), language: .korean)
        XCTAssertEqual(Set(list.map(\.itemID)).count, FlightBriefingPolicy.maximumFlights)
        XCTAssertEqual(Set(list.map(\.id)).count, list.count, "알림 식별자는 겹치지 않는다")
    }

    func testDelayBriefingIsImmediateAndNamesTheNewDepartureTime() throws {
        let now = departure.addingTimeInterval(-6 * 3_600)
        let item = flight(start: departure.addingTimeInterval(65 * 60)) // 새 출발 10:10
        let briefing = try XCTUnwrap(FlightBriefingPolicy.delayBriefing(item: item, delayMinutes: 65, now: now, language: .korean))
        XCTAssertEqual(briefing.kind, .delay)
        XCTAssertEqual(briefing.fireAt, now.addingTimeInterval(2))
        XCTAssertEqual(briefing.body, "65분 지연, 새 출발 시각 10:10")
        XCTAssertTrue(briefing.title.contains("지연 알림"))
        XCTAssertNil(FlightBriefingPolicy.delayBriefing(item: item, delayMinutes: 0, now: now, language: .korean))
        XCTAssertNil(FlightBriefingPolicy.delayBriefing(item: item, delayMinutes: 5, now: item.start.addingTimeInterval(3_600), language: .korean), "이미 출발한 뒤에는 알리지 않는다")
        XCTAssertEqual(FlightBriefingPolicy.delayBriefing(item: item, delayMinutes: 65, now: now, language: .english)?.body.contains("Delayed 65 min"), true)
    }

    func testFlightWithoutAirportsGetsNoBriefing() {
        var item = flight()
        item.originCode = nil
        XCTAssertTrue(FlightBriefingPolicy.briefings(items: [item], now: departure.addingTimeInterval(-86_400 * 2), language: .korean).isEmpty)
    }
}
