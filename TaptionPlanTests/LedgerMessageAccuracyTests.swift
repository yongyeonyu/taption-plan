import XCTest
@testable import TaptionPlan

/// 결제 문자 읽기 정확도(PLN1111A01 제안 8-1·8-2). 문자 모양은 실제 카드사 문자가 아니라 코드에서 짚은 빈틈을 재현한 것이다.
final class LedgerMessageAccuracyTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return value
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 20))! }
    private func parse(_ text: String) -> LedgerMessageParser.Draft? { LedgerMessageParser.parse(text, now: now, calendar: calendar) }

    func testMerchantThatStartsWithACardCompanyNameIsKept() {
        XCTAssertEqual(parse("삼성1234승인 홍*동\n23,000원 일시불\n11/10 12:30 롯데마트 잠실")?.merchant, "롯데마트 잠실")
        XCTAssertEqual(parse("NH농협카드 승인\n8,000원\n11/10 12:30\n하나로마트")?.merchant, "하나로마트")
        XCTAssertEqual(parse("롯데카드 승인 5,000원\n11/10 12:30 삼성전자서비스")?.merchant, "삼성전자서비스")
        XCTAssertNil(parse("신한카드 승인 5,000원\n11/10 12:30\n현대카드 M")?.merchant, "카드 이름 줄은 가게가 아니다")
    }

    func testCardComesFromTheCardNameNotFromTheMerchant() {
        XCTAssertEqual(parse("롯데카드 승인 5,000원\n11/10 12:30 삼성전자서비스")?.card, "롯데카드")
        XCTAssertEqual(parse("신한카드(1234)승인 홍*동\n3,500원 일시불\n11/10 08:10 이삭토스트")?.card, "신한카드")
        XCTAssertEqual(parse("NH농협카드 승인\n8,000원\n11/10 12:30\n하나로마트")?.card, "NH농협카드")
        XCTAssertEqual(parse("삼성1234승인 홍*동\n23,000원 일시불\n11/10 12:30 롯데마트 잠실")?.card, "삼성카드")
        XCTAssertEqual(parse("[Web발신]\nKB국민카드 1*3*승인\n12,000원\n11/10 12:30\n스타벅스")?.card, "KB국민카드")
        XCTAssertNil(parse("승인 4,500원\n11/10 12:30 이삭토스트")?.card, "가게 이름 속 「토스」는 카드가 아니다")
    }

    func testDeclinedAndCardBillAreNotPayments() {
        XCTAssertFalse(LedgerMessageParser.isPaymentCandidate("신한카드 승인거절 12,000원 잔액부족 11/10 12:30"))
        XCTAssertFalse(LedgerMessageParser.isPaymentCandidate("[우리은행] 신한카드 결제대금 출금 1,200,000원 잔액 300,000원"))
        XCTAssertTrue(LedgerMessageParser.isPaymentCandidate("신한카드(1234)승인 홍*동\n12,000원 일시불\n11/10 12:30 스타벅스"))
        XCTAssertTrue(LedgerMessageParser.isPaymentCandidate("KB국민은행 출금 12,000원 스타벅스강남 잔액 345,000원"))
    }

    func testWonInsideAWordIsNotAnAmount() {
        let soup = parse("하나카드 승인 11/10 12:30 원조국밥 9,000원")
        XCTAssertEqual(soup?.amount, 9_000)
        XCTAssertEqual(soup?.merchant, "원조국밥")
        let store = parse("신한카드 승인\n11/10 12:30 GS25 원효로점\n4,500원")
        XCTAssertEqual(store?.amount, 4_500)
        XCTAssertEqual(store?.merchant, "GS25 원효로점")
        XCTAssertEqual(LedgerMessageParser.amount("12,000원(일시불)")?.value, 12_000)
        XCTAssertEqual(LedgerMessageParser.amount("8,500원 일시불")?.value, 8_500)
        XCTAssertEqual(LedgerMessageParser.amount("결제 금액은 12,000원입니다")?.value, 12_000)
    }

    func testOneLineAppAlertFindsTheMerchant() {
        let bank = parse("KB국민은행 출금 12,000원 스타벅스강남 잔액 345,000원")
        XCTAssertEqual(bank?.amount, 12_000)
        XCTAssertEqual(bank?.merchant, "스타벅스강남")
        XCTAssertEqual(parse("카카오뱅크 체크카드 결제 4,500원 메가커피")?.merchant, "메가커피")
        XCTAssertNil(parse("토스뱅크 출금 30,000원")?.merchant)
        XCTAssertEqual(parse("신한카드 승인 5,000원 CU역삼점 누적 10,000원")?.merchant, "CU역삼점")
    }

    func testOnlyPaymentLookingTextGoesToAI() {
        XCTAssertTrue(LedgerMessageParser.looksLikePayment("현대카드 해외승인 12.50 USD 11/10 09:10 AMAZON"))
        XCTAssertTrue(LedgerMessageParser.looksLikePayment("스타벅스\n아메리카노 4,500\n합계 4,500"))
        XCTAssertFalse(LedgerMessageParser.looksLikePayment("내일 3시에 회의 있어요. 자료 챙겨 오세요."))
        XCTAssertFalse(LedgerMessageParser.looksLikePayment("(광고) 오늘만 50% 할인 쿠폰 5,000원"))
        XCTAssertFalse(LedgerMessageParser.looksLikePayment("신한카드 승인거절 12,000원 잔액부족"))
    }

    /// 제안 7-3: 메모의 외화 단위.
    func testMemoAmountReadsYenDollarAndEuro() {
        XCTAssertEqual(LedgerMemoAmount.find("라멘 1200엔"), .init(amount: 1_200, currency: "JPY", kind: .expense, title: "라멘"))
        XCTAssertEqual(LedgerMemoAmount.find("커피 4.5달러")?.currency, "USD")
        XCTAssertEqual(LedgerMemoAmount.find("입장권 €9")?.currency, "EUR")
        XCTAssertEqual(LedgerMemoAmount.find("¥1,200 편의점")?.amount, 1_200)
        XCTAssertEqual(LedgerMemoAmount.find("커피 4500")?.currency, "KRW")
        XCTAssertNotEqual(LedgerMemoAmount.find("2000엔진 오일 교환")?.currency, "JPY", "낱말 속 「엔」은 단위가 아니다")
    }

    /// 리뷰에서 짚은 것: 금액 앞 구두점과 붙여 쓴 결제 낱말은 금액이 맞다.
    func testPunctuationBeforeAndPaymentWordAfterTheAmountStillCount() {
        XCTAssertEqual(LedgerMessageParser.amount("신한카드 승인 금액:12,000원 스타벅스")?.value, 12_000)
        XCTAssertEqual(LedgerMessageParser.amount("홍*동,12,000원")?.value, 12_000)
        XCTAssertEqual(LedgerMessageParser.amount("삼성카드 12,000원결제 스타벅스")?.value, 12_000)
        XCTAssertEqual(LedgerMessageParser.amount("5,000원승인")?.value, 5_000)
        XCTAssertEqual(LedgerMessageParser.amount("12,000원일시불")?.value, 12_000)
        XCTAssertNil(LedgerMessageParser.amount("11/10 12:30 원조국밥"))
        XCTAssertEqual(LedgerMemoAmount.find("라멘 1200엔에 먹음")?.currency, "JPY")
        XCTAssertTrue(LedgerMessageParser.looksLikePayment("REWE\nSUMME 12,50 €"))
        XCTAssertFalse(LedgerMessageParser.looksLikePayment("병원 3시 예약"))
    }
}
