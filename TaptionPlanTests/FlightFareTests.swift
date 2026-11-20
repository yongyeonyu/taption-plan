import XCTest
@testable import TaptionPlan
import TaptionPlanStore

/// FLT1120A01 C: 항공권 결제 판정·카드 매칭·취소 처리. 편명·금액은 전부 익명이다.
final class FlightFareTests: XCTestCase {
    private let day = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func card(_ number: String, trip: String = "t1", item: String = "i1", hour: Double = 9) -> TravelTripItem {
        TravelTripItem(tripID: trip, itemID: item, kind: "flight", title: number, start: day.addingTimeInterval(hour * 3_600), end: day.addingTimeInterval((hour + 1) * 3_600),
                       startOffsetSeconds: 0, endOffsetSeconds: 0, planID: nil, flightNumber: number, originCode: "GMP", destinationCode: "CJU")
    }

    private func expense(_ id: String = "e1", number: String? = nil, airline: String? = nil, roundTrip: Bool = false, trip: String? = nil) -> FlightFare.Expense {
        FlightFare.Expense(id: id, amount: 89_000, currency: "KRW", tripID: trip, flightNumber: number, airlineCode: airline, isRoundTrip: roundTrip)
    }

    func testAirlinePaymentTextIsAFlightAndAttachesToTheCardWithThatFlightNumber() {
        let text = "[Web발신] 대한항공 KE1201 항공권 승인 89,000원 일시불 11/21 10:00"
        XCTAssertEqual(FlightFare.classify(text), .flight(airline: "KE"))
        XCTAssertEqual(FlightFare.flightNumber(in: text), "KE1201")
        let cards = [card("KE1201", item: "a"), card("KE1203", item: "b")]
        XCTAssertEqual(FlightFare.match(expense(number: "KE1201"), cards: cards), .attach(tripID: "t1", itemID: "a", roundTrip: false))
    }

    func testAirlineOnlyTextIsAmbiguousAndNeverAutoAttached() {
        XCTAssertEqual(FlightFare.classify("대한항공 89,000원 승인"), .ambiguous)
        XCTAssertEqual(FlightFare.classify("야놀자 89,000원 승인"), .ambiguous, "OTA 이름만으로 항공권이라 정하지 않는다")
        // 같은 항공사 카드가 둘이면 1:1로 정해지지 않아 후보만 보인다.
        let cards = [card("KE1201", item: "a"), card("KE1203", trip: "t2", item: "b")]
        if case .candidates(let ids) = FlightFare.match(expense(airline: "KE"), cards: cards) { XCTAssertEqual(ids.count, 2) } else { XCTFail("후보여야 한다") }
    }

    func testRoundTripPaymentGoesToOneCardOnly() {
        let cards = [card("KE1201", item: "out", hour: 9), card("KE1202", item: "back", hour: 20)]
        XCTAssertEqual(FlightFare.match(expense(airline: "KE", roundTrip: true), cards: cards), .attach(tripID: "t1", itemID: "out", roundTrip: true))
        var linked = cards
        linked[0].applyFare(amount: 89_000, currency: "KRW", source: "paymentText:roundTrip", expenseID: "e1")
        // 같은 지출은 같은 카드(잠금), 다른 지출은 이미 가격이 붙은 카드를 건너뛴다.
        XCTAssertEqual(FlightFare.match(expense("e1", airline: "KE", roundTrip: true), cards: linked), .attach(tripID: "t1", itemID: "out", roundTrip: true))
        XCTAssertEqual(FlightFare.match(expense("e2", airline: "KE"), cards: linked), .attach(tripID: "t1", itemID: "back", roundTrip: false))
        XCTAssertEqual(FlightFare.fareText(linked[0], language: .korean), "₩89,000 · 결제 문자 · 왕복 결제")
    }

    func testCancelPartialCancelAndInstallmentShowStatusInsteadOfAmount() {
        XCTAssertEqual(FlightFare.status(of: "대한항공 승인취소 89,000원"), .canceled)
        XCTAssertEqual(FlightFare.status(of: "대한항공 부분취소 30,000원"), .partialCancel)
        XCTAssertEqual(FlightFare.status(of: "대한항공 KE1201 3개월 할부 89,000원"), .installment)
        XCTAssertEqual(FlightFare.status(of: "대한항공 KE1201 승인 89,000원"), .normal)
        var item = card("KE1201")
        item.applyFare(amount: 89_000, currency: "KRW", source: "paymentText", expenseID: "e1")
        item.fareSource = "canceled"
        XCTAssertEqual(FlightFare.fareText(item, language: .korean), "취소됨")
    }

    func testHotelAndRentalPaymentsAreNotFlightsAndNeverAttach() {
        XCTAssertEqual(FlightFare.classify("야놀자 제주 호텔 체크인 11/21 89,000원 승인"), .notFlight)
        XCTAssertEqual(FlightFare.classify("롯데렌터카 89,000원 승인"), .notFlight)
        XCTAssertEqual(FlightFare.classify("스타벅스 4,500원 승인 KB1234"), .notFlight, "카드 번호 같은 글자·숫자는 편명이 아니다")
        XCTAssertEqual(FlightFare.match(expense(), cards: [card("KE1201")]), .none)
    }

    func testDeletingTheExpenseClearsTheFareButKeepsTheCard() {
        var item = card("KE1201")
        item.applyFare(amount: 89_000, currency: "USD", source: "paymentText", expenseID: "e1")
        XCTAssertEqual(FlightFare.fareText(item, language: .korean), "USD 89,000 · 결제 문자")
        item.clearFare()
        XCTAssertNil(item.fareAmount); XCTAssertNil(item.fareExpenseID); XCTAssertNil(item.fareSource); XCTAssertNil(item.fareCurrency)
        XCTAssertTrue(item.isFlight)
        XCTAssertEqual(item.flightNumber, "KE1201")
        XCTAssertNil(FlightFare.fareText(item, language: .korean))
    }

    func testFareFieldsStayOutOfTheStoredBytesWhenEmpty() throws {
        let data = try JSONEncoder().encode(card("KE1201"))
        let text = String(decoding: data, as: UTF8.self)
        for key in ["fareAmount", "fareCurrency", "fareSource", "fareExpenseID"] { XCTAssertFalse(text.contains(key), "예전 저장본 바이트가 그대로여야 한다: \(key)") }
        let decoded = try JSONDecoder().decode(TravelTripItem.self, from: data)
        XCTAssertNil(decoded.fareAmount)
    }
}

extension FlightFareTests {
    func testNightsWordOnlyCountsAfterANumberAndSurnameIsNotLodging() {
        XCTAssertEqual(FlightFare.classify("박OO 대한항공 KE1201 항공권 승인 89,000원"), .flight(airline: "KE"), "이름의 박은 숙박 단서가 아니다")
        XCTAssertEqual(FlightFare.classify("야놀자 2박 3일 제주 89,000원 승인"), .notFlight)
    }
}
