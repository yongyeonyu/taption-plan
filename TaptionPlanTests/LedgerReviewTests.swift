import XCTest
@testable import TaptionPlan

/// 가계부 「확인 필요」·취소·입금·내 계좌(LRV1111A01·LCN1111A01·LIN1111A01, 대표 결정).
@MainActor
final class LedgerReviewTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_794_355_200)
    private func entry(_ title: String, _ amount: Double = 4_500, minutes: Double = 0, note: String? = "신한카드", source: LedgerEntry.Source = .message) -> LedgerEntry {
        LedgerEntry(occurredAt: base.addingTimeInterval(minutes * 60), amount: amount, title: title, note: note, source: source)
    }

    func testDuplicateVerdictSeparatesTheSamePaymentFromANearbyOne() {
        let saved = [entry("스타벅스")]
        XCTAssertEqual(LedgerMessageParser.duplicateVerdict(entry("스타벅스", minutes: 2), in: saved), .same, "문자와 앱 알림이 같은 결제를 넘김")
        XCTAssertEqual(LedgerMessageParser.duplicateVerdict(entry("신한카드", minutes: 2), in: saved), .same, "가게를 못 읽은 쪽은 같은 결제로 본다")
        XCTAssertEqual(LedgerMessageParser.duplicateVerdict(entry("스타벅스 강남점", minutes: 2), in: saved), .same)
        XCTAssertEqual(LedgerMessageParser.duplicateVerdict(entry("메가커피", minutes: 2), in: saved), .suspect, "같은 금액의 다른 가게는 버리지 않는다")
        XCTAssertEqual(LedgerMessageParser.duplicateVerdict(entry("메가커피", minutes: 30), in: saved), .none)
        XCTAssertEqual(LedgerMessageParser.duplicateVerdict(entry("스타벅스", minutes: 2), in: [entry("스타벅스", source: .manual)]), .none, "직접 넣은 기록과는 견주지 않는다")
    }

    func testReviewStoreKeepsOneRowPerPaymentAndAcceptOrDiscard() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LedgerReviewTests-\(UUID())"))
        let store = LedgerReviewStore(defaults: defaults)
        store.add(entry("신한카드"), reason: .noMerchant)
        store.add(entry("신한카드", minutes: 1), reason: .noMerchant)
        store.add(entry("이체", 30_000, minutes: 5), reason: .transfer)
        XCTAssertEqual(store.items.map(\.reason), [.noMerchant, .transfer], "같은 결제는 한 줄만")
        XCTAssertEqual(LedgerReviewStore(defaults: defaults).items.count, 2, "기기에 남는다")
        store.remove(try XCTUnwrap(store.items.last).id)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(LedgerReviewStore(defaults: defaults).items.count, 1)
    }

    func testCancelFindsTheOriginalAndCanceledEntriesLeaveTheTotals() {
        let coffee = entry("스타벅스", 12_000, minutes: -60 * 24 * 3)
        let other = entry("메가커피", 12_000, minutes: -60 * 24 * 2)
        let old = entry("스타벅스", 12_000, minutes: -60 * 24 * 40)
        let cancel = entry("스타벅스", 12_000)
        XCTAssertEqual(LedgerMessageParser.canceledOriginal(for: cancel, in: [old, coffee, other])?.id, coffee.id, "가게가 같은 것을 먼저")
        XCTAssertEqual(LedgerMessageParser.canceledOriginal(for: entry("신한카드", 12_000), in: [old, coffee, other])?.id, other.id, "가게를 모르면 가장 최근 것")
        XCTAssertNil(LedgerMessageParser.canceledOriginal(for: cancel, in: [old]), "30일이 넘으면 잇지 않는다")
        var canceled = coffee
        canceled.amountKRW = 12_000
        var kept = other
        kept.amountKRW = 12_000
        XCTAssertEqual(LedgerBook.total([canceled, kept], .expense), 24_000)
        canceled.canceledAt = base
        XCTAssertEqual(LedgerBook.total([canceled, kept], .expense), 12_000, "취소된 결제는 합계에서 빠진다")
        XCTAssertEqual(canceled.signedKRW, 0)
        XCTAssertNil(LedgerMessageParser.canceledOriginal(for: cancel, in: [canceled]), "이미 취소된 것은 다시 잇지 않는다")
    }

    func testCanceledAtSurvivesStorageAndOldRecordsDecode() throws {
        var value = entry("스타벅스")
        value.canceledAt = base
        let decoded = try JSONDecoder().decode(LedgerEntry.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded.canceledAt, base)
        let old = #"{"id":"6E3B1A52-0C33-4C1D-9F11-2B0E7A9D4A10","occurredAt":0,"amount":4500,"currency":"KRW","kind":"expense","category":"cafe","title":"커피","source":"manual","createdAt":0}"#
        XCTAssertNil(try JSONDecoder().decode(LedgerEntry.self, from: Data(old.utf8)).canceledAt, "예전 기록은 그대로 읽힌다")
    }

    func testSalaryDepositIsIncomeAndOtherDepositsAreNot() {
        let salary = LedgerMessageParser.salaryDeposit("[KB국민] 입금 3,200,000원 급여 (주)회사 잔액 4,100,000원", now: base)
        XCTAssertEqual(salary?.amount, 3_200_000)
        XCTAssertEqual(salary?.kind, .income)
        XCTAssertEqual(salary?.category, .salary)
        XCTAssertNil(LedgerMessageParser.salaryDeposit("[KB국민] 입금 50,000원 홍길동", now: base), "받은 송금은 수입으로 넣지 않는다")
        XCTAssertNil(LedgerMessageParser.salaryDeposit("(광고) 급여 통장 입금 이벤트 10,000원", now: base))
    }

    @MainActor
    func testSameTextWithinTwoMinutesIsHandledOnce() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PaymentRepeat-\(UUID())"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let text = "신한카드 승인 12,000원 스타벅스"
        XCTAssertNil(PaymentTextCapture.repeated(text, now: now, defaults: defaults))
        PaymentInbox.record(text, outcome: .added, message: "넣었어요", now: now, defaults: defaults)
        XCTAssertEqual(PaymentTextCapture.repeated(text, now: now.addingTimeInterval(5), defaults: defaults), "넣었어요", "여덟 트리거가 같은 문자를 다시 넘긴다")
        XCTAssertNil(PaymentTextCapture.repeated(text, now: now.addingTimeInterval(121), defaults: defaults))
        XCTAssertNil(PaymentTextCapture.repeated("신한카드 승인 3,000원 편의점", now: now.addingTimeInterval(5), defaults: defaults))
    }

    func testOwnAccountTransfersAreRecognisedOnlyWhenRegistered() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LedgerOwnAccounts-\(UUID())"))
        LedgerOwnAccounts.set([" 토스통장 ", "토스통장", "a", "홍길동"], defaults: defaults)
        XCTAssertEqual(LedgerOwnAccounts.names(defaults), ["토스통장", "홍길동"])
        let names = LedgerOwnAccounts.names(defaults)
        XCTAssertTrue(LedgerOwnAccounts.isOwnTransfer("카카오뱅크 출금 500,000원 홍길동(토스통장)", names: names))
        XCTAssertFalse(LedgerOwnAccounts.isOwnTransfer("카카오뱅크 출금 500,000원 김철수", names: names))
        XCTAssertFalse(LedgerOwnAccounts.isOwnTransfer("신한카드 승인 4,500원 홍길동커피", names: names), "이체 낱말이 없으면 결제다")
        XCTAssertFalse(LedgerOwnAccounts.isOwnTransfer("카카오뱅크 출금 500,000원 홍길동", names: []))
        XCTAssertTrue(LedgerMessageParser.looksLikeTransfer("토스 송금 30,000원"))
        let bill = "출금 1,450,770원 입출금통장(1234) → 홍길동현대카드 잔액 825,430원"
        XCTAssertTrue(LedgerMessageParser.looksLikeCardBill(bill, merchant: LedgerMessageParser.parse(bill, now: .now)?.merchant))
        XCTAssertFalse(LedgerMessageParser.looksLikeCardBill("출금 12,000원 입출금통장(1234) → 김밥천국", merchant: "김밥천국"))
        XCTAssertFalse(LedgerMessageParser.looksLikeCardBill("신한카드 승인 12,000원 스타벅스", merchant: "스타벅스"))
    }
}
