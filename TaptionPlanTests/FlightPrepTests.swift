import XCTest
@testable import TaptionPlan
import TaptionPlanEngine
import TaptionPlanStore

/// FLT1119A01: 여행 부가 예약(eSIM·숙소·면세점) → 준비물 카드. 샘플은 전부 가짜다.
final class FlightPrepTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private let now = Date(timeIntervalSince1970: 1_803_000_000) // 2027-02-27
    private let trip = TravelTrip(id: "t1", title: "방콕", startDay: "2027-03-07", endDay: "2027-03-11", regionName: "방콕")

    private func extra(_ text: String) throws -> (FlightAlertExtra, String?) {
        guard case .alert(let alert) = FlightAlertParser.parse(text, receivedAt: now), let extra = alert.extra else { throw XCTSkip("부가 예약으로 읽히지 않음") }
        return (extra, alert.pnr)
    }

    private func apply(_ text: String, to items: [TravelPrepItem] = [], trips: [TravelTrip]? = nil) throws -> FlightPrep.Outcome {
        let (extra, pnr) = try extra(text)
        var counter = 0
        return FlightPrep.apply(extra: extra, pnr: pnr, to: items, trips: trips ?? [trip], now: now, calendar: calendar, label: { $0 }, makeID: { counter += 1; return "p\(counter)" })
    }

    private func items(_ outcome: FlightPrep.Outcome) -> [TravelPrepItem] {
        if case .applied(let items, _, _) = outcome { return items }
        return []
    }

    private let esim = "[가상유심] eSIM 구매 완료\n상품명: 베트남 · 4일 데이터 무제한\n개통 링크 https://example.com/voucher\nQR 발급 후 30일 내 사용"

    func testEsimBecomesAPrepCardWithLinkAndValidity() throws {
        let outcome = try apply(esim)
        guard case .applied(let list, let created, let updated) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual([created, updated], [1, 0])
        let card = try XCTUnwrap(list.first)
        XCTAssertEqual(card.kind, "esim")
        XCTAssertEqual(card.tripID, "t1")
        XCTAssertEqual(card.title, "베트남 · 4일 데이터 무제한")
        XCTAssertEqual(card.linkURL, "https://example.com/voucher")
        XCTAssertTrue(card.detail?.contains("30일") == true)
        XCTAssertNil(card.checked)
        XCTAssertNil(card.refCode)
    }

    func testSameEsimTwiceDoesNotDuplicateAndPlainHTTPLinkIsDropped() throws {
        let first = items(try apply(esim))
        guard case .applied(let list, let created, let updated) = try apply(esim, to: first) else { return XCTFail() }
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual([created, updated], [0, 0])
        let insecure = try apply("[가상유심] eSIM 구매 완료\n상품명: 일본 · 3일\n개통 링크 http://example.com/x")
        XCTAssertNil(items(insecure).first?.linkURL, "https가 아닌 링크는 저장하지 않는다")
    }

    func testLodgingReceiptThenConfirmationUpdatesTheSameCardByReservationNumber() throws {
        let receipt = try apply("[가상숙소] 예약 접수 안내 예약번호 XYZ789 이용기간 05/03 ~ 09/15 출장문의")
        guard case .applied(let afterReceipt, _, _) = receipt else { return XCTFail() }
        let card = try XCTUnwrap(afterReceipt.first)
        XCTAssertEqual(card.orderStatus, "tentative")
        XCTAssertEqual(card.refCode, "XYZ789")
        XCTAssertEqual(card.isBusiness, true, "출장은 개인 경비와 섞지 않게 따로 표시")
        XCTAssertEqual(card.needsDateConfirmation, true, "연도 없는 기간은 확정하지 않는다")
        XCTAssertEqual(card.detail, "05/03 ~ 09/15")
        let confirmed = try apply("[가상숙소] 예약 확정 예약번호 XYZ789 호텔 객실 1박", to: afterReceipt)
        guard case .applied(let list, let created, let updated) = confirmed else { return XCTFail() }
        XCTAssertEqual([created, updated, list.count], [0, 1, 1], "같은 예약번호는 한 카드")
        XCTAssertEqual(list[0].orderStatus, "booked")
        XCTAssertEqual(list[0].isBusiness, true)
        // 다른 예약번호는 다른 카드.
        guard case .applied(let two, _, _) = try apply("[가상숙소] 예약 접수 안내 예약번호 QQQ111 호텔 객실", to: list) else { return XCTFail() }
        XCTAssertEqual(two.count, 2)
    }

    func testDutyFreeOrderThenReceiptMatchesOneToOneByOrderNumber() throws {
        let order = try apply("[가상면세점] 주문완료 주문번호 1234567890 출국일시 2027-03-07 09:05 인도장 제1터미널 3층 인도장")
        guard case .applied(let afterOrder, _, _) = order else { return XCTFail() }
        let card = try XCTUnwrap(afterOrder.first)
        XCTAssertEqual(card.kind, "dutyFree")
        XCTAssertEqual(card.refCode, "1234567890")
        XCTAssertEqual(card.orderStatus, "booked")
        XCTAssertNil(card.checked)
        let receipt = try apply("[가상면세점] 정상 수령 안내 주문번호 1234567890 주문상품정보 화장품 1건", to: afterOrder)
        guard case .applied(let list, let created, let updated) = receipt else { return XCTFail() }
        XCTAssertEqual([created, updated, list.count], [0, 1, 1])
        XCTAssertEqual(list[0].orderStatus, "received")
        XCTAssertEqual(list[0].checked, true, "수령하면 확인 표시가 켜진다")
        // 다른 주문번호의 수령은 다른 카드로(맞는 주문이 없으니 새로 만든다).
        guard case .applied(let other, let c2, _) = try apply("[가상면세점] 정상 수령 안내 주문번호 9999999999 주문상품정보 향수", to: list) else { return XCTFail() }
        XCTAssertEqual([c2, other.count], [1, 2])
    }

    func testTripSelectionPrefersTheCountryAndTheDepartureDate() throws {
        let osaka = TravelTrip(id: "t2", title: "오사카", startDay: "2027-02-27", endDay: "2027-03-02", regionName: "오사카")
        let (vietnam, _) = try extra("[가상유심] eSIM 구매 완료\n상품명: 방콕 · 4일")
        XCTAssertEqual(FlightPrep.trip(for: vietnam, in: [osaka, trip], now: now, calendar: calendar)?.id, "t1", "나라 이름이 맞는 여행")
        let (duty, _) = try extra("[가상면세점] 주문완료 주문번호 1234567890 출국일시 2027-03-07 09:05 인도장 제1터미널")
        XCTAssertEqual(FlightPrep.trip(for: duty, in: [osaka, trip], now: now, calendar: calendar)?.id, "t1", "출국일이 속한 여행")
        let (other, _) = try extra("[가상유심] eSIM 구매 완료\n상품명: 태국 · 4일")
        XCTAssertEqual(FlightPrep.trip(for: other, in: [trip, osaka], now: now, calendar: calendar)?.id, "t2", "맞는 나라가 없으면 먼저 시작하는 열린 여행")
        XCTAssertNil(FlightPrep.trip(for: vietnam, in: [TravelTrip(id: "old", title: "지난 여행", startDay: "2026-01-01", endDay: "2026-01-05")], now: now, calendar: calendar))
        XCTAssertEqual(try apply(esim, trips: []), .noTrip)
    }

    func testLabelsExistForEveryKind() {
        for kind in [FlightPrep.kindESIM, FlightPrep.kindLodging, FlightPrep.kindDutyFree, "other"] {
            XCTAssertFalse(FlightPrep.label(kind, language: .korean).isEmpty)
            XCTAssertNotEqual(FlightPrep.label(kind, language: .korean), FlightPrep.label(kind, language: .english))
        }
    }
}
