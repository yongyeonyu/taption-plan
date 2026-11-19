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

    /// 이체·입금의 보낸 사람·받는 사람(TPY1115A01). 이름은 지어낸 것이다.
    func testTransferPartyReadsSenderAndRecipient() {
        let cases: [(String, String?)] = [
            ("홍길동님이 140,000원을 보냈어요", "홍길동"),
            ("김철수님에게 30,000원을 보냈어요", "김철수"),
            ("[카카오뱅크] 입금 140,000원\n홍길동 → 내 입출금통장(1234)", "홍길동"),
            ("[카카오뱅크] 출금 30,000원\n내 입출금통장(1234) → 김철수", "김철수"),
            ("[KB]11/15 14:24\n801302**207\n홍*동\n입금\n140,000\n잔액1,000,000", "홍*동"),
            ("[Web발신]\n신한 11/15 14:24 110-***-123456 입금 140,000 잔액 1,000,000 홍길동", "홍길동"),
            ("농협 출금30,000원\n11/15 14:24 351-****-1234-56 김철수님 잔액1,000,000원", "김철수"),
            ("고객님이 요청하신 이체 30,000원이 완료되었습니다", nil),
            ("[카카오뱅크] 입금 140,000원 잔액 1,000,000원", nil),
            ("스타벅스 4,500원 결제", nil),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(LedgerMessageParser.transferParty(text), expected, text)
        }
    }

    /// 은행 이름으로 이미 들어간 입금을 받은 글의 이름으로 고친다. 가게 기록·금액이 다른 기록은 두고, 고친 기록은 다시 고치지 않는다.
    func testExistingBankTitledDepositIsRenamedFromTheInbox() {
        var deposit = entry("카카오뱅크", 140_000, minutes: 1, note: "카카오뱅크")
        deposit.kind = .income
        deposit.createdAt = base.addingTimeInterval(60)
        var shop = entry("가나다식당", 140_000, minutes: 1)
        shop.createdAt = base.addingTimeInterval(60)
        let item = PaymentInbox.Item(text: "[카카오뱅크] 입금 140,000원\n홍길동 → 내 입출금통장(1234)", receivedAt: base.addingTimeInterval(62), outcome: .added, message: "")
        let fixed = LedgerTransferRename.renames(entries: [shop, deposit], inbox: [item])
        XCTAssertEqual(fixed.map(\.id), [deposit.id])
        XCTAssertEqual(fixed.first?.title, "홍길동")
        XCTAssertEqual(fixed.first?.note, "카카오뱅크")
        XCTAssertTrue(LedgerTransferRename.renames(entries: fixed, inbox: [item]).isEmpty, "고친 기록은 그대로")
        var later = item
        later.receivedAt = base.addingTimeInterval(3_600)
        XCTAssertTrue(LedgerTransferRename.renames(entries: [deposit], inbox: [later]).isEmpty, "시각이 먼 글은 짝이 아니다")
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

/// NTR1119A01: 결제 알림은 가계부로, 가계부가 아닌 예매·예약·배송 알림은 AI 태스크 큐(`notification_review`)로 간다.
@MainActor
final class NotificationReviewDelegationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let payment = "신한카드 승인 3,000원 가짜편의점"
    private let booking = "[가짜티켓] 가짜 뮤지컬 예매가 확정되었어요. 11월 21일 19:30 3층 B열 2매 가짜극장"

    private func defaults(connected: Bool = true) throws -> UserDefaults {
        let store = try XCTUnwrap(UserDefaults(suiteName: "NotificationReviewTests-\(UUID())"))
        if connected { store.set(["key": "피클"], forKey: AssistantKeyLabels.labelsKey) }
        return store
    }

    func testPaymentGoesToLedgerAndBookingGoesToAI() throws {
        XCTAssertTrue(LedgerMessageParser.isPaymentCandidate(payment))
        XCTAssertFalse(LedgerMessageParser.isAIReviewCandidate(payment), "결제는 가계부 몫이다")
        XCTAssertFalse(LedgerMessageParser.isPaymentCandidate(booking))
        XCTAssertTrue(LedgerMessageParser.isAIReviewCandidate(booking))

        let store = try defaults()
        PaymentAlertSources.set(.init(name: "가짜앱", lastSeen: now, aiAnalysis: true), defaults: store)
        XCTAssertNil(PaymentTextCapture.delegateToAI(payment, source: "가짜앱", now: now, language: .korean, defaults: store))
        XCTAssertTrue(AITaskQueue.pendingUploads(store).isEmpty, "결제 글은 알림 분석 일로 올리지 않는다")

        let message = try XCTUnwrap(PaymentTextCapture.delegateToAI(booking, source: "가짜앱", now: now, language: .korean, defaults: store))
        XCTAssertFalse(message.isEmpty)
        let task = try XCTUnwrap(AITaskQueue.pendingUploads(store).first)
        XCTAssertEqual(task.kind, .notificationReview)
        XCTAssertEqual(task.kind.rawValue, "notification_review")
        XCTAssertEqual(task.text, booking)
        XCTAssertEqual(task.context?["sourceApp"], "가짜앱")
        XCTAssertEqual(task.context?["receivedAt"], ISO8601DateFormatter().string(from: now))
        XCTAssertEqual(task.date, AITaskQueue.dayText(now))
    }

    func testAdsCodesAndSkippedTextsAreNotDelegated() throws {
        let store = try defaults()
        PaymentAlertSources.set(.init(name: "가짜앱", lastSeen: now, aiAnalysis: true), defaults: store)
        for text in ["(광고) 가짜식당 가을 이벤트 안내입니다. 많은 관심 부탁드려요", "[가짜은행] 인증번호 123456을 입력해 주세요 타인 노출 금지",
                     "가짜쇼핑 혜택 안내 무료거부 080-000-0000 수신거부", "가짜앱 비밀번호 변경 안내입니다 확인해 주세요", "짧음"] {
            XCTAssertFalse(LedgerMessageParser.isAIReviewCandidate(text), text)
            XCTAssertNil(PaymentTextCapture.delegateToAI(text, source: "가짜앱", now: now, language: .korean, defaults: store), text)
        }
        XCTAssertTrue(AITaskQueue.pendingUploads(store).isEmpty)
        // 「넣지 않을 낱말」이 든 글은 `process`가 여기 오기 전에 걸러 AI에도 가지 않는다.
        let standard = UserDefaults.standard
        let before = PaymentAlertSources.skipWords(standard)
        PaymentAlertSources.addSkipWord("가짜광고낱말", defaults: standard)
        defer { PaymentAlertSources.removeSkipWord("가짜광고낱말", defaults: standard); XCTAssertEqual(PaymentAlertSources.skipWords(standard), before) }
        XCTAssertNotNil(PaymentAlertSources.skipWord(in: booking + " 가짜광고낱말", defaults: standard))
    }

    func testNeedsAConnectionAndTheAppSwitch() throws {
        let unconnected = try defaults(connected: false)
        PaymentAlertSources.set(.init(name: "가짜앱", lastSeen: now, aiAnalysis: true), defaults: unconnected)
        XCTAssertNil(PaymentTextCapture.delegateToAI(booking, source: "가짜앱", now: now, language: .korean, defaults: unconnected), "맡길 AI가 없다")

        let store = try defaults()
        XCTAssertFalse(PaymentAlertSources.allowsAIReview("가짜앱", defaults: store), "처음 본 앱은 꺼 둔다(사용자가 고른 앱만)")
        XCTAssertNil(PaymentTextCapture.delegateToAI(booking, source: "가짜앱", now: now, language: .korean, defaults: store))
        PaymentAlertSources.set(.init(name: "가짜앱", lastSeen: now, aiAnalysis: true), defaults: store)
        XCTAssertNotNil(PaymentTextCapture.delegateToAI(booking, source: "가짜앱", now: now, language: .korean, defaults: store), "고른 앱은 맡긴다")
        PaymentAlertSources.set(.init(name: "가짜앱", lastSeen: now, aiAnalysis: false), defaults: store)
        XCTAssertNil(PaymentTextCapture.delegateToAI(booking, source: "가짜앱", now: now, language: .korean, defaults: store), "앱마다 끌 수 있다")
        XCTAssertFalse(PaymentAlertSources.allowsAIReview(nil, defaults: store))
        // 문자와 메신저 앱은 스위치가 켜져 있어도 안 된다.
        for name in [PaymentAlertSources.smsName, "카카오톡", "KakaoTalk", "LINE", "라인", "Telegram", "WhatsApp", "메시지", "Messenger", "Slack", "iMessage"] {
            PaymentAlertSources.set(.init(name: name, lastSeen: now, aiAnalysis: true), defaults: store)
            XCTAssertFalse(PaymentAlertSources.allowsAIReview(name, defaults: store), name)
            XCTAssertNil(PaymentTextCapture.delegateToAI(booking, source: name, now: now, language: .korean, defaults: store), name)
        }
        XCTAssertFalse(PaymentAlertSources.isMessenger("가짜항공 Airline"), "line이 든 이름이 모두 메신저는 아니다")
        XCTAssertFalse(PaymentAlertSources.isMessenger("가짜티켓"))
        XCTAssertTrue(AITaskQueue.pendingUploads(store).count == 1)
        // 지출·수입 스위치와는 따로다.
        PaymentAlertSources.set(.init(name: "가짜앱", expense: false, income: false, lastSeen: now, aiAnalysis: true), defaults: store)
        XCTAssertTrue(PaymentAlertSources.allowsAIReview("가짜앱", defaults: store))
    }

    func testOldSourcesWithoutTheSwitchStillDecode() throws {
        let old = #"[{"name":"가짜앱","expense":true,"income":false,"lastSeen":0}]"#
        let store = try defaults()
        store.set(Data(old.utf8), forKey: PaymentAlertSources.key)
        let sources = PaymentAlertSources.all(store)
        XCTAssertEqual(sources.map(\.name), ["가짜앱"])
        XCTAssertNil(sources.first?.aiAnalysis)
        XCTAssertFalse(PaymentAlertSources.allowsAIReview("가짜앱", defaults: store), "예전 저장값은 꺼진 채로")
    }

    func testNonPaymentNotificationIsNotAddedToTheLedger() async {
        let (message, outcome) = await PaymentTextCapture.process(booking, requiresTime: false, source: "가짜앱", now: now)
        XCTAssertEqual(outcome, .skipped, "AI에 연결되지 않은 기기에서는 가계부에도 AI에도 가지 않는다: \(message)")
    }
}
