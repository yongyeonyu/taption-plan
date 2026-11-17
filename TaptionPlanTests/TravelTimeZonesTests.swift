import XCTest
import TaptionPlanStore
@testable import TaptionPlan

/// 여행 일정의 시간대(REV1117A01): 출국 비행 전은 출발지(한국), 도착부터는 여행지, 귀국편도 같다.
final class TravelTimeZonesTests: XCTestCase {
    private let seoul = 9 * 3_600, bangkok = 7 * 3_600, losAngeles = -8 * 3_600

    private func time(_ day: String, _ hour: Int, _ minute: Int = 0, offset: Int) -> Date {
        TravelQuickEntrySheet.date(dayKey: day, minute: hour * 60 + minute, offsetSeconds: offset)
    }

    private func flight(_ id: String, trip: String = "t1", from: Date, fromOffset: Int, to: Date, toOffset: Int) -> TravelTripItem {
        TravelTripItem(tripID: trip, itemID: id, kind: "flight", title: id, start: from, end: to, startOffsetSeconds: fromOffset, endOffsetSeconds: toOffset, planID: nil)
    }

    private let bangkokTrip = TravelTrip(id: "t1", title: "방콕", startDay: "2031-12-01", endDay: "2031-12-06", countryCode: "TH", timeZoneID: "Asia/Bangkok")

    /// 서울 12-01 23:00 출발(+9) → 방콕 12-02 03:30 도착(+7) = 비행 6시간 30분. 귀국 방콕 12-05 18:00(+7) → 서울 12-06 01:30(+9) = 5시간 30분.
    private var flights: [TravelTripItem] {
        [
            flight("out", from: time("2031-12-01", 23, offset: seoul), fromOffset: seoul, to: time("2031-12-02", 3, 30, offset: bangkok), toOffset: bangkok),
            flight("back", from: time("2031-12-05", 18, offset: bangkok), fromOffset: bangkok, to: time("2031-12-06", 1, 30, offset: seoul), toOffset: seoul),
        ]
    }

    func testFlightDurationIsRealWhenEachEndUsesItsOwnZone() {
        let out = flights[0], back = flights[1]
        XCTAssertEqual(out.end.timeIntervalSince(out.start), 6.5 * 3_600, "+9 → +7: 시차 2시간이 비행 시간 안에서 맞는다")
        XCTAssertEqual(back.end.timeIntervalSince(back.start), 5.5 * 3_600, "+7 → +9 방향도 같다")
    }

    func testItemsBeforeTheOutboundFlightUseHomeZoneAndAfterArrivalUseTheTripZone() {
        let items = flights
        XCTAssertEqual(TravelTimeZones.offset(trip: bangkokTrip, items: items, dayKey: "2031-12-01", minute: 10 * 60), seoul, "출국 전 낮: 한국 시각")
        XCTAssertEqual(TravelTimeZones.offset(trip: bangkokTrip, items: items, dayKey: "2031-12-01", minute: 22 * 60), seoul)
        XCTAssertEqual(TravelTimeZones.offset(trip: bangkokTrip, items: items, dayKey: "2031-12-02", minute: 3 * 60), seoul, "비행 중(도착 전)은 출발지 쪽")
        XCTAssertEqual(TravelTimeZones.offset(trip: bangkokTrip, items: items, dayKey: "2031-12-02", minute: 3 * 60 + 30), bangkok, "도착 시각부터 현지")
        XCTAssertEqual(TravelTimeZones.offset(trip: bangkokTrip, items: items, dayKey: "2031-12-03", minute: 12 * 60), bangkok)
        XCTAssertEqual(TravelTimeZones.offset(trip: bangkokTrip, items: items, dayKey: "2031-12-05", minute: 17 * 60), bangkok, "귀국편 출발 전까지 현지")
        XCTAssertEqual(TravelTimeZones.offset(trip: bangkokTrip, items: items, dayKey: "2031-12-06", minute: 0), bangkok, "귀국 도착 전")
        XCTAssertEqual(TravelTimeZones.offset(trip: bangkokTrip, items: items, dayKey: "2031-12-06", minute: 9 * 60), seoul, "귀국 도착 뒤는 한국")
    }

    func testWestboundTripUsesTheNegativeOffsetAndAMidnightCrossingFlight() {
        let trip = TravelTrip(id: "t1", title: "LA", startDay: "2031-12-01", endDay: "2031-12-05", countryCode: "US", timeZoneID: "America/Los_Angeles")
        // 서울 12-01 22:00 출발 → LA 12-01 16:00 도착(날짜가 거꾸로: 비행 10시간 + 17시간 시차 = 같은 날 오후).
        let out = flight("out", from: time("2031-12-01", 22, offset: seoul), fromOffset: seoul, to: time("2031-12-01", 15, offset: losAngeles), toOffset: losAngeles)
        XCTAssertEqual(out.end.timeIntervalSince(out.start), 10 * 3_600)
        XCTAssertEqual(TravelTimeZones.offset(trip: trip, items: [out], dayKey: "2031-12-01", minute: 9 * 60), seoul)
        XCTAssertEqual(TravelTimeZones.offset(trip: trip, items: [out], dayKey: "2031-12-01", minute: 14 * 60), seoul, "LA 도착 15:00 전")
        XCTAssertEqual(TravelTimeZones.offset(trip: trip, items: [out], dayKey: "2031-12-01", minute: 16 * 60), losAngeles)
        XCTAssertEqual(TravelTimeZones.offset(trip: trip, items: [out], dayKey: "2031-12-02", minute: 9 * 60), losAngeles)
    }

    func testTripWithoutFlightsUsesTheDestinationZoneAndOldTripsFallBackToTheDevice() {
        XCTAssertEqual(TravelTimeZones.offset(trip: bangkokTrip, items: [], dayKey: "2031-12-03", minute: 600), bangkok)
        let byCountry = TravelTrip(id: "t1", title: "도쿄", startDay: "2031-12-01", endDay: "2031-12-02", countryCode: "JP")
        XCTAssertEqual(TravelTimeZones.offset(trip: byCountry, items: [], dayKey: "2031-12-01", minute: 600), 9 * 3_600, "나라만 있어도 대표 시간대")
        let old = TravelTrip(id: "t1", title: "옛 여행", startDay: "2031-12-01", endDay: "2031-12-02")
        XCTAssertEqual(TravelTimeZones.destination(old).identifier, TimeZone.autoupdatingCurrent.identifier, "시간대도 나라도 없으면 지금처럼 기기 시간대")
        XCTAssertEqual(TravelTimeZones.zoneID(countryCode: "kr"), "Asia/Seoul")
        XCTAssertNil(TravelTimeZones.zoneID(countryCode: "ZZ"))
    }

    func testHandMadeFlightGetsHomeThenDestinationAndTheReturnGoesBackHome() {
        let home = TimeZone(identifier: "Asia/Seoul")!
        let first = TravelTimeZones.flightOffsets(trip: bangkokTrip, items: [], dayKey: "2031-12-01", minute: 23 * 60, home: home)
        XCTAssertEqual([first.start, first.end], [seoul, bangkok], "첫 비행: 한국 출발, 현지 도착")
        let out = flights[0]
        let back = TravelTimeZones.flightOffsets(trip: bangkokTrip, items: [out], dayKey: "2031-12-05", minute: 18 * 60, home: home)
        XCTAssertEqual([back.start, back.end], [bangkok, seoul], "귀국편: 현지 출발, 한국 도착")
        let another = TravelTimeZones.flightOffsets(trip: bangkokTrip, items: [out], dayKey: "2031-12-01", minute: 9 * 60, home: home)
        XCTAssertEqual([another.start, another.end], [seoul, bangkok], "출국 전에 하나 더 넣는 비행도 같은 방향")
    }

    func testOtherTripsFlightsAndDetailPlansAreIgnored() {
        var other = flights[0]
        other.tripID = "t2"
        var detail = flights[0]
        detail.itemID = "detail"
        detail.parentItemID = "x"
        XCTAssertEqual(TravelTimeZones.offset(trip: bangkokTrip, items: [other, detail], dayKey: "2031-12-03", minute: 600), bangkok, "비행이 없는 것과 같다")
    }
}
