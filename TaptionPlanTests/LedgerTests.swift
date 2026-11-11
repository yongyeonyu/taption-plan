import XCTest
@testable import TaptionPlan

/// 가계부(LED1110A01): AI 명령 읽기, 환율, 단체 정산, 오늘 손익, 메모리 장부.
@MainActor
final class LedgerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func at(_ hour: Int, day: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    private func parse(_ fields: [String: Any]) throws -> AssistantCommandBatch {
        let item = ["format": "bokki-command", "version": 1, "id": "e1", "action": "addExpense"].merging(fields) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: ["commands": [item]])
        return try XCTUnwrap(AssistantCommandParser.parse(data, now: at(12), calendar: calendar))
    }

    func testAddExpenseParsesAndGuessesCategory() throws {
        let batch = try parse(["amount": 12_000, "title": "점심 식당", "date": "2026-11-09", "time": "12:30", "payer": "민수"])
        guard case let .addExpense(entry) = batch.commands.first?.action else { return XCTFail("\(batch)") }
        XCTAssertEqual(entry.amount, 12_000)
        XCTAssertEqual(entry.currency, "KRW")
        XCTAssertEqual(entry.kind, .expense)
        XCTAssertEqual(entry.payer, "민수")
        XCTAssertEqual(entry.source, .assistant)
        XCTAssertEqual(calendar.component(.day, from: entry.occurredAt), 9)
        XCTAssertEqual(calendar.component(.minute, from: entry.occurredAt), 30)
        XCTAssertEqual(batch.commands.first?.action.kind, .addExpense)
        XCTAssertEqual(batch.commands.first?.action.existingChangeCount, 0)
    }

    func testAddExpenseRejectsBadFields() throws {
        for fields: [String: Any] in [
            ["amount": 0, "title": "x"], ["amount": -5, "title": "x"], ["amount": 1e11, "title": "x"],
            ["amount": 10, "title": ""], ["amount": 10, "title": "x", "currency": "KRWW"],
            ["amount": 10, "title": "x", "category": "car"], ["amount": 10, "title": "x", "kind": "loan"],
            ["amount": "10", "title": "x"], ["title": "x"],
        ] {
            XCTAssertEqual(try parse(fields).invalidIDs, ["e1"], "\(fields)")
        }
    }

    func testForeignCurrencyUsesManualRateFirst() {
        let table = LedgerFX.Table(base: "EUR", rates: ["EUR": 1, "KRW": 1_500, "JPY": 160], day: "2026-11-10")
        XCTAssertEqual(LedgerFX.krwPerUnit("KRW", table: nil, manual: [:]), 1)
        XCTAssertEqual(try XCTUnwrap(LedgerFX.krwPerUnit("JPY", table: table, manual: [:])), 1_500 / 160, accuracy: 0.001)
        XCTAssertEqual(LedgerFX.krwPerUnit("JPY", table: table, manual: ["JPY": 9]), 9)
        XCTAssertNil(LedgerFX.krwPerUnit("THB", table: table, manual: [:]))
    }

    func testSettlementNeedsFewestTransfers() {
        let entries = [
            LedgerEntry(occurredAt: at(9), amount: 90_000, amountKRW: 90_000, title: "숙소"),
            LedgerEntry(occurredAt: at(12), amount: 30_000, amountKRW: 30_000, title: "점심", payer: "민수"),
            LedgerEntry(occurredAt: at(13), amount: 5_000, amountKRW: 5_000, kind: .income, title: "환불"),
        ]
        let transfers = LedgerSettlement.transfers(entries, people: ["민수", "지영"], me: "나")
        // 함께 쓴 돈 120,000원 ÷ 3 = 40,000원. 나는 50,000원 더 냈고 민수 10,000원·지영 40,000원을 받는다.
        XCTAssertEqual(transfers.count, 2)
        XCTAssertEqual(Set(transfers.map(\.from)), ["민수", "지영"])
        XCTAssertTrue(transfers.allSatisfy { $0.to == "나" })
        XCTAssertEqual(transfers.reduce(0) { $0 + $1.amountKRW }, 50_000, accuracy: 1)
    }

    func testBookSavesDeletesAndComputesTodayNet() async {
        let book = LedgerBook(store: { nil })
        let lunch = await book.save(LedgerEntry(occurredAt: at(12), amount: 10_000, title: "점심"))
        await book.save(LedgerEntry(occurredAt: at(18), amount: 3_000, kind: .income, title: "용돈"))
        await book.save(LedgerEntry(occurredAt: at(12, day: 9), amount: 7_000, title: "어제"))
        XCTAssertEqual(lunch.amountKRW, 10_000)
        XCTAssertEqual(book.entries(on: at(0), calendar: calendar).count, 2)
        XCTAssertEqual(book.entries(inMonth: "2026-11", calendar: calendar).count, 3)
        // 세후 300만 원 ÷ 30일 = 100,000원 − 10,000 + 3,000.
        XCTAssertEqual(book.todayNet(now: at(20), calendar: calendar, monthlyNet: 3_000_000), 93_000)
        await book.delete(lunch.id)
        XCTAssertEqual(book.entries.count, 2)
    }

    func testAssistantExpenseAppliesAndUndoes() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LedgerTests.\(UUID().uuidString)"))
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: .empty), cloudSyncService: nil)
        await model.bootstrap()
        let outcome = await model.applyAssistantCommands(try parse(["amount": 4_500, "title": "커피"]), defaults: defaults)
        XCTAssertEqual(outcome?.results.first?.applied, true)
        XCTAssertEqual(outcome?.ledger, 1)
        XCTAssertNotNil(outcome?.entries.first?.delta.ledgerEntryID)
        XCTAssertEqual(outcome?.notice(.korean)?.contains("가계부 1개"), true)

        // 되돌리기: 같은 장부에서 더하고 되돌리면 지워지고, 사용자가 고친 뒤면 되돌리지 않는다.
        var preferences = AssistantPreferenceStore.test(defaults)
        let book = LedgerBook(store: { nil })
        preferences.ledger = book
        func log(_ result: AssistantEditResult) -> AssistantLogEntry {
            var delta = AssistantEditDelta.difference(from: model.snapshot, to: model.snapshot, actualIDs: [])
            delta.ledgerEntryID = result.ledgerEntryID
            delta.ledgerEntry = result.ledgerEntry
            return AssistantLogEntry(commandID: "u", kind: .addExpense, appliedAt: .now, before: "", after: result.after, delta: delta)
        }
        let plain = await model.applyAssistantAction(.addExpense(LedgerEntry(occurredAt: at(9), amount: 4_500, title: "커피")), preferences: preferences)
        XCTAssertEqual(book.entries.count, 1)
        let undone = await model.undoAssistantEntry(log(plain), preferences: preferences)
        XCTAssertTrue(undone)
        XCTAssertTrue(book.entries.isEmpty, "undo removes the AI entry")

        let edited = await model.applyAssistantAction(.addExpense(LedgerEntry(occurredAt: at(10), amount: 9_000, title: "점심")), preferences: preferences)
        var changed = try XCTUnwrap(book.entries.first)
        changed.amount = 9_500
        await book.save(changed)
        let refused = await model.undoAssistantEntry(log(edited), preferences: preferences)
        XCTAssertFalse(refused, "an entry the user edited afterwards is not deleted")
        XCTAssertEqual(book.entries.first?.amount, 9_500)
    }

    /// AIQ1111A01: 앱이 넣은 결제 문자 기록을 AI가 updateExpense로 다듬고, 「AI가 한 일」에서 되돌리면 원래대로 돌아온다.
    func testUpdateExpenseParsesAppliesAndUndoesToTheAppEntry() async throws {
        let id = UUID()
        let batch = try parse(["action": "updateExpense", "entryId": id.uuidString, "title": "스타벅스 강남", "category": "cafe"])
        guard case let .updateExpense(entryID, change) = batch.commands.first?.action else { return XCTFail("\(batch)") }
        XCTAssertEqual(entryID, id)
        XCTAssertEqual(change.title, "스타벅스 강남")
        XCTAssertEqual(change.category, .cafe)
        XCTAssertNil(change.amount)
        XCTAssertTrue(try parse(["action": "updateExpense", "entryId": id.uuidString]).commands.isEmpty, "nothing to change")

        let model = AppModel(repository: InMemoryPlanRepository(snapshot: .empty), cloudSyncService: nil)
        await model.bootstrap()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LedgerUpdate-\(UUID())"))
        var preferences = AssistantPreferenceStore.test(defaults)
        let book = LedgerBook(store: { nil })
        preferences.ledger = book
        let original = await book.save(LedgerEntry(id: id, occurredAt: at(9), amount: 12_000, title: "스타벅스", source: .message))
        let result = await model.applyAssistantAction(.updateExpense(entryID: id, change: change), preferences: preferences)
        XCTAssertEqual(book.entries.first?.title, "스타벅스 강남")
        XCTAssertEqual(book.entries.first?.amount, 12_000, "fields not given stay")
        var delta = AssistantEditDelta.difference(from: model.snapshot, to: model.snapshot, actualIDs: [])
        delta.ledgerEntryID = result.ledgerEntryID
        delta.ledgerEntry = result.ledgerEntry
        delta.ledgerBefore = result.ledgerBefore
        let undone = await model.undoAssistantEntry(
            AssistantLogEntry(commandID: "u", kind: .updateExpense, appliedAt: .now, before: "", after: result.after, delta: delta),
            preferences: preferences
        )
        XCTAssertTrue(undone)
        XCTAssertEqual(book.entries, [original], "undo restores the entry the app added")

        let missing = await model.applyAssistantAction(.updateExpense(entryID: UUID(), change: change), preferences: preferences)
        XCTAssertEqual(missing.reason, "no_record")
    }

    /// SHT1111A01: 은행 앱 알림은 「출금」으로 온다. 시각이 없으면 알림 넣기가 받은 때로 채운다.
    func testBankWithdrawalNotificationParses() {
        let draft = LedgerMessageParser.parse("KB국민은행 출금 12,000원 스타벅스강남 잔액 345,000원", now: at(9), calendar: calendar)
        XCTAssertEqual(draft?.amount, 12_000)
        XCTAssertNil(draft?.occurredAt)
        XCTAssertNil(LedgerMessageParser.parse("[광고] KB국민은행 출금 이벤트 10,000원", now: at(9), calendar: calendar))
    }

    func testPromoLinesLocalePrefillAndResetDuringLoad() async {
        let now = at(20)
        let promo = LedgerMessageParser.parse("현대카드 승인 홍*동 15,000원 일시불 11/10 13:00 김밥천국 누적300,000원 청구할인 혜택 이벤트", now: now, calendar: calendar)
        XCTAssertEqual(promo?.amount, 15_000, "a payment with a trailing promo line is still a payment")
        XCTAssertNil(LedgerMessageParser.parse("[광고] 신한카드 승인 이벤트 10,000원", now: now, calendar: calendar))
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(LedgerNumber.parse(LedgerEntryForm.plain(12.5, locale: german), locale: german), 12.5, "the prefilled amount reads back the same")
        XCTAssertEqual(LedgerNumber.parse(LedgerEntryForm.plain(12_000, locale: german), locale: german), 12_000)
        let book = LedgerBook(store: { nil })
        await book.save(LedgerEntry(occurredAt: at(9), amount: 1, title: "old"))
        book.reset()
        XCTAssertTrue(book.entries.isEmpty)
    }

    func testCardMessagesParse() throws {
        let now = at(20)
        let shinhan = try XCTUnwrap(LedgerMessageParser.parse("[Web발신]\n신한카드(1234)승인 홍*동 12,000원(일시불)11/10 12:30 스타벅스 누적1,234,000원", now: now, calendar: calendar))
        XCTAssertEqual(shinhan.amount, 12_000)
        XCTAssertEqual(shinhan.currency, "KRW")
        XCTAssertEqual(shinhan.merchant, "스타벅스")
        XCTAssertEqual(shinhan.card, "신한카드")
        XCTAssertEqual(shinhan.occurredAt, calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12, minute: 30)))
        XCTAssertFalse(shinhan.isCancel)

        let kb = try XCTUnwrap(LedgerMessageParser.parse("KB국민카드1234승인\n홍*동님\n8,500원 일시불\n11/09 19:05\n김밥천국\n누적320,000원", now: now, calendar: calendar))
        XCTAssertEqual(kb.amount, 8_500)
        XCTAssertEqual(kb.merchant, "김밥천국")
        XCTAssertEqual(kb.card, "KB국민카드")

        let foreign = try XCTUnwrap(LedgerMessageParser.parse("현대카드 해외승인 USD 12.50 11/10 09:10 STARBUCKS HONOLULU", now: now, calendar: calendar))
        XCTAssertEqual(foreign.currency, "USD")
        XCTAssertEqual(foreign.amount, 12.5)
        XCTAssertEqual(foreign.merchant, "STARBUCKS HONOLULU")

        let cancel = try XCTUnwrap(LedgerMessageParser.parse("삼성1234승인취소 홍*동 4,500원 11/10 10:00 메가커피", now: now, calendar: calendar))
        XCTAssertTrue(cancel.isCancel)
        XCTAssertEqual(LedgerMessageParser.entry(cancel, now: now).kind, .income)

        XCTAssertNil(LedgerMessageParser.parse("오늘 점심 12,000원 어때?", now: now, calendar: calendar))
        // 12월 문자를 1월에 받으면 작년으로 본다.
        let january = calendar.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 9))!
        let late = try XCTUnwrap(LedgerMessageParser.parse("우리카드 승인 30,000원 12/31 23:50 편의점", now: january, calendar: calendar))
        XCTAssertEqual(late.occurredAt.map { calendar.component(.year, from: $0) }, 2026)
    }

    /// 리뷰 지적: 청구 예정·한도·광고 문자는 기록 후보가 아니고, 쉼표 소수점 지역에서 금액이 100배가 되지 않는다.
    func testReviewFixes() async {
        let now = at(20)
        XCTAssertNil(LedgerMessageParser.parse("[신한카드] 11월 결제예정금액 1,234,560원", now: now, calendar: calendar))
        XCTAssertNil(LedgerMessageParser.parse("KB국민카드 사용가능한도 3,000,000원", now: now, calendar: calendar))
        XCTAssertNil(LedgerMessageParser.parse("(광고) 쿠폰 사용하세요 5,000원", now: now, calendar: calendar))
        XCTAssertEqual(LedgerNumber.parse("12,50", locale: Locale(identifier: "de_DE")), 12.5)
        XCTAssertEqual(LedgerNumber.parse("12,000", locale: Locale(identifier: "ko_KR")), 12_000)
        XCTAssertEqual(LedgerCategory.guess("메가박스 코엑스"), .culture)
        XCTAssertEqual(LedgerCategory.guess("메가커피 강남"), .cafe)
        XCTAssertEqual(LedgerCategory.guess("Cucina Italiana"), .other)
        let book = LedgerBook(store: { nil })
        await book.save(LedgerEntry(occurredAt: at(9), amount: 3_000_000, kind: .income, category: .salary, title: "월급"))
        XCTAssertEqual(book.todayNet(now: at(20), calendar: calendar, monthlyNet: 3_000_000), 100_000, "payday salary is not counted twice")
        let transfers = LedgerSettlement.transfers(
            [LedgerEntry(occurredAt: at(9), amount: 20_000, amountKRW: 20_000, title: "택시", payer: "Minsu")], people: [], me: "나"
        )
        XCTAssertEqual(transfers.first?.to, "Minsu", "an unlisted payer still counts as a member")
    }

    func testReceiptIgnoresNumbersThatAreNotAmounts() {
        XCTAssertNil(LedgerReceiptReader.draft(["가게", "승인번호 12345678", "2026-11-10"]))
        let usd = LedgerReceiptReader.draft(["DINER", "SUBTOTAL 40.00", "TOTAL $45.99"])
        XCTAssertEqual(usd?.amount, 45.99)
        XCTAssertEqual(usd?.currency, "USD")
    }

    /// LED1111A03: 메모 글에서 금액 알아보기. 시각·날짜·전화·단위·연도는 금액이 아니다.
    func testMemoAmountDetection() {
        XCTAssertEqual(LedgerMemoAmount.find("커피 4500"), .init(amount: 4_500, currency: "KRW", kind: .expense, title: "커피"))
        XCTAssertEqual(LedgerMemoAmount.find("택시 12,000원 강남")?.title, "택시 강남")
        XCTAssertEqual(LedgerMemoAmount.find("+3,000,000 월급")?.kind, .income)
        XCTAssertEqual(LedgerMemoAmount.find("Lunch $12.50")?.currency, "USD")
        XCTAssertEqual(LedgerMemoAmount.find("라멘 1200 JPY")?.amount, 1_200)
        XCTAssertEqual(LedgerMemoAmount.find("4500 latte")?.amount, 4_500)
        XCTAssertEqual(LedgerMemoAmount.find("4500 시원한 커피")?.amount, 4_500)
        XCTAssertEqual(LedgerMemoAmount.find("점심 12500")?.amount, 12_500)
        XCTAssertEqual(LedgerMemoAmount.find("커피 주문 4500")?.amount, 4_500, "주문 뒤 둥근 값은 금액")
        XCTAssertEqual(LedgerMemoAmount.find("버스비 1500")?.amount, 1_500)
        XCTAssertEqual(LedgerMemoAmount.find("편의점 4950")?.amount, 4_950, "10원 단위 값도 금액")
        for text in ["14:30 회의", "11/12 병원", "2026 목표", "3층 1203호", "민수 010-1234-5678", "5000보 걷기", "만원 정도", "커피", "4500",
                     "현관 비번 482915", "버스 7016 타기", "주문번호 3000", "회의실 1205"] {
            XCTAssertNil(LedgerMemoAmount.find(text), text)
        }
    }

    func testMemoSyncCreatesUpdatesAndRemovesLinkedEntry() async {
        let book = LedgerBook(store: { nil })
        let memo = UUID()
        let defaults = UserDefaults.standard
        LedgerMemoOptOut.set(memo, optedOut: false, defaults: defaults)
        let first = await book.syncMemo(id: memo, text: "커피 4500", occurredAt: at(9))
        XCTAssertEqual(first?.amountKRW, 4_500)
        XCTAssertEqual(first?.category, .cafe)
        let second = await book.syncMemo(id: memo, text: "커피 5000", occurredAt: at(9))
        XCTAssertEqual(second?.id, first?.id, "editing the memo updates the same entry")
        XCTAssertEqual(book.entries.count, 1)
        XCTAssertEqual(book.entry(forMemo: memo)?.amount, 5_000)
        await book.syncMemo(id: memo, text: "커피 마셨다", occurredAt: at(9))
        XCTAssertTrue(book.entries.isEmpty, "removing the amount removes the entry")
        await book.syncMemo(id: memo, text: "점심 9000", occurredAt: at(12))
        LedgerMemoOptOut.set(memo, optedOut: true, defaults: defaults)
        await book.syncMemo(id: memo, text: "점심 9000", occurredAt: at(12))
        XCTAssertTrue(book.entries.isEmpty, "memo only keeps it out of the ledger")
        LedgerMemoOptOut.set(memo, optedOut: false, defaults: defaults)
        await book.syncMemo(id: memo, text: "점심 9000", occurredAt: at(12))
        await book.removeMemo(memo)
        XCTAssertTrue(book.entries.isEmpty, "deleting the memo deletes the entry")
    }

    /// 리뷰: 메모를 고치고 지우는 모델의 길이 가계부를 따라오게 하는지, 빨리 두 번 고쳐도 기록이 하나인지.
    func testModelMemoEditsKeepTheLedgerInStep() async throws {
        let book = LedgerBook(store: { nil })
        AppModel.memoLedgerBookForTests = book
        defer { AppModel.memoLedgerBookForTests = nil }
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: .empty), cloudSyncService: nil)
        await model.bootstrap()
        let id = try XCTUnwrap(model.addMemo(text: "메모", kind: .idea, categoryID: MemoTimelineEngine.categoryID, on: at(9)))
        model.updateMemo(id, text: "커피 4500", kind: .idea)
        model.updateMemo(id, text: "커피 5000", kind: .idea)
        try await waitUntil { book.entry(forMemo: id)?.amount == 5_000 }
        XCTAssertEqual(book.entries.count, 1, "two quick edits keep one linked entry")
        model.deleteMemo(id)
        try await waitUntil { book.entries.isEmpty }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(condition())
    }

    /// SPD1111A01: 하루 지출 카운터는 그날 지출만, 재생·핸들 시각까지 더한다. 수입은 빼고 다른 날도 뺀다.
    func testDailySpendingCounter() async {
        let book = LedgerBook(store: { nil })
        await book.save(LedgerEntry(occurredAt: at(9), amount: 4_500, title: "커피"))
        await book.save(LedgerEntry(occurredAt: at(13), amount: 9_000, title: "점심"))
        await book.save(LedgerEntry(occurredAt: at(14), amount: 3_000, kind: .income, title: "환불"))
        await book.save(LedgerEntry(occurredAt: at(10, day: 9), amount: 7_000, title: "어제"))
        XCTAssertEqual(LedgerDaySpending.total(day: at(0), cutoff: at(23), calendar: calendar, book: book), 13_500)
        XCTAssertEqual(LedgerDaySpending.total(day: at(0), cutoff: at(12), calendar: calendar, book: book), 4_500, "playback cutoff")
        XCTAssertEqual(MapHomeCounterKind.spending.badgeTitle(.korean), "지출")
        XCTAssertNil(MapHomeCounterKind.spending.categoryID)
    }

    /// LED1111A04: 표 내보내기는 시각순·합계 줄·쉼표와 따옴표 감싸기·계산식 막기, 엑셀용 BOM.
    func testLedgerTableCSV() {
        let entries = [
            LedgerEntry(occurredAt: at(13), amount: 9_000, amountKRW: 9_000, title: "점심, 김밥", payer: "민수"),
            LedgerEntry(occurredAt: at(9), amount: 12.5, currency: "USD", amountKRW: 17_000, title: "=SUM(A1)"),
            LedgerEntry(occurredAt: at(18), amount: 3_000, amountKRW: 3_000, kind: .income, title: "환불 \"부분\""),
        ]
        let csv = LedgerTable.csv(entries, carryOver: 100_000, language: .korean, calendar: calendar)
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}일자,구분,항목,적요,수입,지출,잔액,비고"), "standard ledger columns")
        let lines = csv.dropFirst().components(separatedBy: "\r\n")
        XCTAssertEqual(lines[1], "이월잔액,,,,,,100000,")
        XCTAssertTrue(lines[2].hasPrefix("2026-11-10 09:00,지출,기타,'=SUM(A1),,17000,83000,USD 12.50"), lines[2])
        XCTAssertTrue(lines[3].contains("\"점심, 김밥\",,9000,74000,민수"), lines[3])
        XCTAssertTrue(lines[4].contains("수입,기타,\"환불 \"\"부분\"\"\",3000,,77000"), lines[4])
        XCTAssertEqual(lines[5], "합계,,,,3000,26000,77000,")
        XCTAssertTrue(csv.contains("항목별 지출,지출,비율\r\n기타,26000,100.0%"))
        XCTAssertEqual(MapHomeCardMetricOption(id: MapHomeCardMetricOption.spendingID)?.title(.korean), "지출", "the old card id maps to the calendar expense")
        XCTAssertTrue(MapHomeCardMetricOption.all.contains { $0.id == "expense" })
    }

    // MARK: - LED1111A05 여행 장부(일상 아래 대차대조)

    private func trip(budget: Double?) -> LedgerTrip {
        LedgerTrip(id: "t1", name: "대구", start: at(0, day: 7), end: at(0, day: 8), budgetKRW: budget, members: ["A", "B"])
    }

    private func spend(_ amount: Double, _ title: String, payer: String? = nil, share: [String]? = nil) -> LedgerEntry {
        var entry = LedgerEntry(occurredAt: at(12, day: 7), amount: amount, amountKRW: amount, title: title, payer: payer, tripID: "t1")
        entry.shareNames = share
        return entry
    }

    /// 리뷰 LED1111A08: 장부 없는 여행 기록은 일상으로, 오늘 손익은 일상만, 빠진 동행은 자기 줄, 장부 지우기, 시트 이름, 달력 금액.
    func testLedgerReviewFixes() async {
        let book = LedgerBook(store: { nil })
        await book.save(LedgerEntry(occurredAt: at(12), amount: 15_000, amountKRW: 15_000, title: "예전 여행 점심", tripID: "old-trip"))
        XCTAssertEqual(book.dailyEntries.count, 1, "an entry of a trip without a ledger stays in daily")

        await book.saveTrip(LedgerTrip(id: "t1", name: "대구", start: at(0), end: at(0), budgetKRW: 500_000, members: ["A"]), now: at(12), calendar: calendar)
        await book.save(spend10(300_000, "숙소"))
        XCTAssertEqual(book.todayNet(now: at(20), calendar: calendar, monthlyNet: 0), -515_000, "trip budget transfer + old lunch, not the hotel again")

        let renamed = LedgerTrip(id: "t1", name: "대구", start: at(0), end: at(0), budgetKRW: 500_000, members: ["민수"])
        var dinner = spend10(90_000, "저녁")
        dinner.payer = "A"
        let sheet = LedgerTripMath.sheet(renamed, entries: [dinner])
        XCTAssertEqual(sheet.myPaid, 0, "a removed member's payment is not mine")
        XCTAssertEqual(sheet.balances["A"] ?? 0, 90_000, accuracy: 0.5, "A keeps their own line and is owed the dinner")

        await book.deleteTrip("t1")
        XCTAssertNil(book.trip("t1"))
        XCTAssertTrue(book.entries.allSatisfy { $0.transfer == nil }, "transfer pairs go with the ledger")
        XCTAssertEqual(book.dailyEntries.map(\.title).sorted(), ["숙소", "예전 여행 점심"], "trip entries return to daily")

        XCTAssertEqual(LedgerXLSX.safeSheetName("서울/부산: 1일차"), "서울-부산- 1일차")
        XCTAssertEqual(LedgerXLSX.safeSheetName("'''"), "Sheet1")
        let totals = LedgerDaySpending.monthTotals(month: at(0), calendar: calendar, book: book)
        XCTAssertEqual(totals[calendar.startOfDay(for: at(0))]?.expense, 315_000)
        XCTAssertEqual(MapHomeCalendarTimeTotalsPolicy.moneyCellText(12_600, language: .korean), "1.3만")
        XCTAssertEqual(MapHomeCalendarTimeTotalsPolicy.moneyCellText(350_000, language: .korean), "35만")
        XCTAssertEqual(MapHomeCalendarTimeTotalsPolicy.moneyCellText(0, language: .korean), "")
        XCTAssertTrue(MapHomeCalendarTimeKind.extraKinds.contains(.expense))
    }

    /// LED1111A09: 짝 기록·메모 기록까지 모든 기록을 고치고 지운다.
    func testEveryEntryCanBeEditedAndDeleted() async {
        let book = LedgerBook(store: { nil })
        await book.saveTrip(LedgerTrip(id: "t9", name: "부산", start: at(0, day: 1), end: at(0, day: 1), budgetKRW: 500_000))
        await book.save(LedgerEntry(occurredAt: at(12, day: 1), amount: 300_000, amountKRW: 300_000, title: "숙소", tripID: "t9"))
        await book.syncTrip("t9")
        func pair(_ kind: LedgerTransfer.Kind) -> [LedgerEntry] { book.entries.filter { $0.transfer?.kind == kind } }
        XCTAssertEqual(pair(.settlement).first { $0.tripID == nil }?.amountKRW, 200_000)

        var funding = try! XCTUnwrap(pair(.funding).first { $0.tripID == nil })
        funding.amount = 400_000
        funding.amountKRW = 400_000
        funding.note = "카드에서"
        await book.saveTransfer(funding)
        XCTAssertEqual(book.trip("t9")?.budgetKRW, 400_000)
        XCTAssertEqual(pair(.funding).map(\.amountKRW), [400_000, 400_000], "both sides follow the edit")
        XCTAssertEqual(pair(.funding).first { $0.tripID == nil }?.note, "카드에서")
        XCTAssertEqual(pair(.settlement).first { $0.tripID == nil }?.amountKRW, 100_000, "settlement follows the new budget")

        var settlement = try! XCTUnwrap(pair(.settlement).first { $0.tripID == nil })
        settlement.kind = .expense
        settlement.amount = 50_000
        settlement.amountKRW = 50_000
        await book.saveTransfer(settlement)
        let fixed = try! XCTUnwrap(pair(.settlement).first { $0.tripID == nil })
        XCTAssertEqual(fixed.kind, .expense)
        XCTAssertEqual(fixed.amountKRW, 50_000)
        await book.syncTrip("t9")
        XCTAssertEqual(pair(.settlement).first { $0.tripID == nil }?.amountKRW, 50_000, "an edited settlement stays")

        await book.resetSettlement("t9")
        XCTAssertEqual(pair(.settlement).first { $0.tripID == nil }?.kind, .income)
        XCTAssertEqual(pair(.settlement).first { $0.tripID == nil }?.amountKRW, 100_000)

        await book.remove(try! XCTUnwrap(pair(.settlement).first { $0.tripID == "t9" }))
        await book.syncTrip("t9")
        XCTAssertTrue(pair(.settlement).isEmpty, "a deleted settlement does not come back")
        await book.remove(try! XCTUnwrap(pair(.funding).first))
        XCTAssertTrue(pair(.funding).isEmpty)
        XCTAssertNil(book.trip("t9")?.budgetKRW)

        let memoID = UUID()
        defer { LedgerMemoOptOut.set(memoID, optedOut: false) }
        let created = await book.syncMemo(id: memoID, text: "커피 4500원", occurredAt: at(9))
        let memoEntry = try! XCTUnwrap(created)
        await book.remove(memoEntry)
        let again = await book.syncMemo(id: memoID, text: "커피 4500원 맛있음", occurredAt: at(9))
        XCTAssertNil(again, "a deleted memo entry does not come back")
        XCTAssertNil(book.entry(forMemo: memoID))
    }

    private func spend10(_ amount: Double, _ title: String) -> LedgerEntry {
        LedgerEntry(occurredAt: at(13), amount: amount, amountKRW: amount, title: title, tripID: "t1")
    }

    func testTripSheetSettlesForMe() {
        let entries = [
            spend(300_000, "숙소"),                                   // 내가 내고 다 같이
            spend(90_000, "저녁", payer: "A"),                         // A가 내고 다 같이
            spend(20_000, "기념품", share: [LedgerTrip.me]),           // 나만
            spend(30_000, "택시", payer: "B", share: [LedgerTrip.me, "B"]),
        ]
        let sheet = LedgerTripMath.sheet(trip(budget: 500_000), entries: entries)
        XCTAssertEqual(sheet.myPaid, 320_000)
        XCTAssertEqual(sheet.myCost, 165_000, "100k + 30k + 20k + 15k")
        XCTAssertEqual(sheet.sharedTotal, 420_000)
        XCTAssertEqual(sheet.balances["A"] ?? 0, -40_000, accuracy: 0.5)
        XCTAssertEqual(sheet.balances["B"] ?? 0, -115_000, accuracy: 0.5)
        XCTAssertEqual(sheet.receivable, 155_000)
        XCTAssertEqual(sheet.payable, 0)
        XCTAssertEqual(Set(sheet.mine.map(\.from)), ["A", "B"])
    }

    /// 대표 결정: 공금 없이 n분의 1. 총무로 A에게 미리 받은 돈은 A가 낸 돈으로 친다.
    func testMoneyCollectedFromAFriendCountsForThem() {
        var collected = LedgerEntry(occurredAt: at(9, day: 7), amount: 100_000, amountKRW: 100_000, kind: .income, title: "A 경비", payer: "A", tripID: "t1")
        collected.shareNames = nil
        var funding = LedgerEntry(occurredAt: at(0, day: 7), amount: 500_000, amountKRW: 500_000, kind: .income, title: "경비 받음", tripID: "t1")
        funding.transfer = LedgerTransfer(kind: .funding, tripID: "t1")
        let sheet = LedgerTripMath.sheet(trip(budget: 500_000), entries: [funding, collected, spend(300_000, "숙소")])
        XCTAssertEqual(sheet.receivedFromOthers, 100_000)
        XCTAssertEqual(sheet.otherIncome, 0, "a friend's money is not my income")
        XCTAssertEqual(sheet.balances["A"] ?? 1, 0, accuracy: 0.5, "A already covered their share")
        XCTAssertEqual(sheet.mine.map(\.from), ["B"])
        XCTAssertEqual(sheet.receivable, 100_000)
        XCTAssertEqual(sheet.leftover, 400_000, "budget minus my share")
        XCTAssertEqual(sheet.cashLeft, 300_000, "500k + 100k from A − 300k paid")
    }

    func testTripBudgetAndSettlementPairs() async {
        let book = LedgerBook(store: { nil })
        await book.saveTrip(trip(budget: 500_000), now: at(12, day: 7), calendar: calendar)
        XCTAssertEqual(book.dailyEntries.map(\.amount), [500_000], "the budget leaves daily as an expense")
        XCTAssertEqual(book.tripEntries("t1").first?.kind, .income)
        await book.save(spend(300_000, "숙소"))
        await book.save(spend(90_000, "저녁", payer: "A"))
        await book.syncTrip("t1", now: at(12, day: 8), calendar: calendar)
        XCTAssertNil(book.dailyEntries.first { $0.transfer?.kind == .settlement }, "no settlement before the trip ends")
        await book.syncTrip("t1", now: at(12, day: 10), calendar: calendar)
        let refund = book.dailyEntries.first { $0.transfer?.kind == .settlement }
        XCTAssertEqual(refund?.kind, .income)
        XCTAssertEqual(refund?.amount, 370_000, "500k − my share 130k comes back to daily")
        XCTAssertEqual(book.tripEntries("t1").filter { $0.transfer?.kind == .settlement }.first?.kind, .expense)
        // 예산을 줄이면 모자란 만큼 일상에서 더 보낸다.
        var small = trip(budget: 100_000)
        small.name = "대구"
        await book.saveTrip(small, now: at(12, day: 10), calendar: calendar)
        let topUp = book.dailyEntries.first { $0.transfer?.kind == .settlement }
        XCTAssertEqual(topUp?.kind, .expense)
        XCTAssertEqual(topUp?.amount, 30_000)
        XCTAssertEqual(book.dailyEntries.filter { $0.transfer?.kind == .funding }.map(\.amount), [100_000], "editing the budget moves both pair entries")
        XCTAssertEqual(LedgerDaySpending.total(day: at(0, day: 7), cutoff: at(23, day: 7), calendar: calendar, book: book), 390_000,
                       "the day counter shows real spending, not the transfer")
    }

    func testXLSXIsAZipWithFormulas() {
        XCTAssertEqual(StoreZip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        var sheet = LedgerXLSX(sheetName: "가계부 <1>", widths: [10])
        sheet.add([.init(value: .text("점심 & 커피")), .init(value: .number(9_000), style: .money), .init(value: .formula("SUM(B1:B1)", cached: 9_000), style: .money)])
        let data = sheet.data()
        XCTAssertEqual(data.prefix(2), Data("PK".utf8))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("xl/worksheets/sheet1.xml"))
        XCTAssertTrue(text.contains("<f>SUM(B1:B1)</f><v>9000.0</v>"), "the formula carries its value for previews")
        XCTAssertTrue(text.contains("점심 &amp; 커피"))
        XCTAssertTrue(text.contains(#"name="가계부 &lt;1&gt;""#))
        XCTAssertEqual(data.suffix(22).prefix(4), Data([0x50, 0x4B, 0x05, 0x06]), "ends with the zip directory record")
    }

    func testReceiptTotalLine() {
        let lines = ["맛있는 분식", "사업자 123-45-67890", "떡볶이 1 5,000", "순대 1 4,000", "합계", "9,000", "카드 9,000"]
        let draft = LedgerReceiptReader.draft(lines)
        XCTAssertEqual(draft?.amount, 9_000)
        XCTAssertEqual(draft?.merchant, "맛있는 분식")
        XCTAssertNil(LedgerReceiptReader.draft(["감사합니다"]))
    }

    /// LDU1111A01: 가계부 한 달은 날짜도, 같은 날 안도 오래된 것부터 시간순으로 묶인다.
    func testLedgerDayGroupsAreChronological() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 18))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9, minute: 40))!
        let entries = [
            LedgerEntry(occurredAt: day2.addingTimeInterval(2_280), amount: 1_000, title: "coffee"),
            LedgerEntry(occurredAt: day1, amount: 5_000, title: "dinner"),
            LedgerEntry(occurredAt: day2, amount: 900, title: "toll"),
        ]
        let groups = LedgerDayGroup.groups(entries, calendar: calendar)
        XCTAssertEqual(groups.map(\.entries.count), [1, 2])
        XCTAssertEqual(groups.flatMap(\.entries).map(\.title), ["dinner", "toll", "coffee"])
        XCTAssertEqual(groups.first?.day, calendar.startOfDay(for: day1))
    }

    /// HWY1111A01: 고속도로 통행료는 노선 번호를 찾는다. 긴 이름이 먼저고, 고속도로 낌새가 없으면 찾지 않는다.
    func testHighwayTollFindsRouteNumber() {
        XCTAssertEqual(LedgerHighway.number(in: "경인고속도로 통행료"), 120)
        XCTAssertEqual(LedgerHighway.number(in: "제2경인고속도로"), 110)
        XCTAssertEqual(LedgerHighway.number(in: "중부내륙고속도로 요금소"), 45)
        XCTAssertEqual(LedgerHighway.number(in: "경부 고속도로"), 1)
        XCTAssertEqual(LedgerHighway.number(in: "서울외곽순환 톨게이트"), 100)
        XCTAssertNil(LedgerHighway.number(in: "경인교대 앞 카페"))
        XCTAssertNil(LedgerHighway.number(in: "고속버스 터미널"))
        let entry = LedgerEntry(occurredAt: .now, amount: 900, category: .transport, title: "경인고속도로 통행료")
        XCTAssertEqual(LedgerHighway.number(for: entry), 120)
        // HWY1111A02: 다리·터널 통행료. 영종대교는 공항고속도로 위지만 다리로 본다.
        XCTAssertEqual(LedgerToll.kind(in: "영종대교 통행료"), .bridge)
        XCTAssertEqual(LedgerToll.kind(in: "인천대교"), .bridge)
        XCTAssertEqual(LedgerToll.kind(in: "남산1호터널 혼잡통행료"), .tunnel)
        XCTAssertEqual(LedgerToll.kind(in: "미시령 통행료"), .tunnel)
        XCTAssertEqual(LedgerToll.kind(in: "경인고속도로 통행료"), .highway(120))
        XCTAssertNil(LedgerToll.kind(in: "광화문 대교 칼국수"))
    }
}

/// BKS1111A01: 다른 기기(아이폰 18)가 올린 백업 파일이 이 기기 iCloud 폴더에 보이는지. 비밀번호 없이 이름·크기·시각만 읽고 복원하지 않는다.
/// 기기에서 `TEST_RUNNER_TAPTION_BACKUP_PROBE=1`일 때만 돈다.
final class BackupArrivalProbeTests: XCTestCase {
    func testListICloudBackups() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TAPTION_BACKUP_PROBE"] == "1", "기기 확인용")
        let files = try await TaptionICloudDriveBackupDestination().list().sorted { $0.modifiedAt > $1.modifiedAt }
        let formatter = ISO8601DateFormatter()
        for file in files {
            print("BACKUP_PROBE \(file.name) size=\(file.size) modified=\(formatter.string(from: file.modifiedAt)) downloaded=\(file.isDownloaded)")
        }
        print("BACKUP_PROBE count=\(files.count)")
    }
}

/// AI 확인 목록(AIQ1111A01): 원문 가리기, 서버 목록 읽기, 연결이 없으면 넣지 않기.
@MainActor
final class AITaskQueueTests: XCTestCase {
    func testMaskHidesCardAccountAndPhoneNumbersButKeepsAmountsDatesAndTimes() {
        let text = "[Web발신] 신한 1234-5678-9012-3456 승인 12,000원 11/11 08:12 계좌 110-123-456789 문의 010-1234-5678 2026-11-11"
        let masked = AITaskQueue.mask(text)
        XCTAssertTrue(masked.contains("****-****-****-3456"), masked)
        XCTAssertTrue(masked.contains("***-***-**6789"), masked)
        XCTAssertTrue(masked.contains("***-****-5678"), masked)
        XCTAssertTrue(masked.contains("12,000원"), masked)
        XCTAssertTrue(masked.contains("11/11 08:12"), masked)
        XCTAssertTrue(masked.contains("2026-11-11"), masked)
    }

    func testEnqueueNeedsAConnectionAndStoresMaskedText() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AITaskQueueTests-\(UUID())"))
        XCTAssertFalse(AITaskQueue.enqueue(.paymentText, text: "카드 1234567890123 결제", defaults: defaults))
        XCTAssertTrue(AITaskQueue.pendingUploads(defaults).isEmpty)
        defaults.set(["key": "피클"], forKey: AssistantKeyLabels.labelsKey)
        XCTAssertTrue(AITaskQueue.enqueue(.paymentText, text: "카드 1234567890123 결제", defaults: defaults))
        XCTAssertEqual(AITaskQueue.pendingUploads(defaults).map(\.text), ["카드 *********0123 결제"])
    }

    func testServerTaskListDecodes() throws {
        let json = #"{"format":"bokki-tasks","version":1,"tasks":[{"id":"a","kind":"payment_text","status":"done","result":"스타벅스 12,000원","createdAt":"2026-11-11T05:00:00.123Z","updatedAt":"2026-11-11T05:01:00.000Z"},{"id":"b","kind":"fare_check","text":"교대→마곡나루","status":"processing"}]}"#
        struct Envelope: Decodable { var tasks: [AITaskQueue.Task] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601withFractionalOrPlain
        let tasks = try decoder.decode(Envelope.self, from: Data(json.utf8)).tasks
        XCTAssertEqual(tasks.map(\.status), [.done, .processing])
        XCTAssertEqual(tasks.first?.result, "스타벅스 12,000원")
        XCTAssertNotNil(tasks.first?.createdAt)
    }
}

/// AI 확인 목록 2단계(AIQ1111A02): 하루 기록에서 머문 곳·교통비·조각 합침·경로 확인 거리를 고르고 한 번만 올린다.
@MainActor
final class AITaskProducerTests: XCTestCase {
    private typealias Day = AssistantActivityDay
    private let now = ISO8601DateFormatter().date(from: "2026-11-11T23:00:00+09:00")!

    private func move(_ mode: String, _ start: String, _ end: String, minutes: Int, from: String? = "집", to: String? = "회사") -> Day.Move {
        Day.Move(from: from, to: to, mode: mode, start: "2026-11-11T\(start)+09:00", end: "2026-11-11T\(end)+09:00", minutes: minutes)
    }

    private func day(visits: [Day.Visit] = [], moves: [Day.Move] = [], expenses: [Day.Expense]? = nil) -> Day {
        var value = Day(
            date: "2026-11-11", timeZone: "Asia/Seoul",
            summary: .init(categories: [], recordedMinutes: 0, steps: nil, plansScheduled: 0, plansCompleted: 0),
            records: [Day.Record(id: "r1", start: "2026-11-11T11:40+09:00", end: "2026-11-11T12:30+09:00", title: "머문 곳",
                                 category: .init(id: "activity", title: "활동"), source: "auto")],
            memos: []
        )
        value.visits = visits
        value.moves = moves
        value.expenses = expenses
        return value
    }

    func testPicksUnnamedLongStayOnly() {
        let visits = [
            Day.Visit(place: "머문 곳", start: "2026-11-11T11:45+09:00", end: "2026-11-11T12:20+09:00", minutes: 35),
            Day.Visit(place: "머문 곳", start: "2026-11-11T13:00+09:00", end: "2026-11-11T13:10+09:00", minutes: 10),
            Day.Visit(place: "회사", start: "2026-11-11T13:10+09:00", end: "2026-11-11T18:00+09:00", minutes: 290),
        ]
        let found = AITaskProducer.candidates(day(visits: visits), language: .korean, now: now)
        XCTAssertEqual(found.map(\.kind), [.stayPlace])
        XCTAssertEqual(found.first?.context["recordIds"], "r1")
    }

    func testTransferIsOneFareAndPaidTripIsSkipped() {
        let moves = [
            move("walk", "07:58", "08:20", minutes: 22),
            move("subway", "08:20", "08:40", minutes: 20, from: "교대", to: "고속터미널"),
            move("walk", "08:40", "08:45", minutes: 5),
            move("subway", "08:45", "09:20", minutes: 35, from: "고속터미널", to: "마곡나루"),
            move("car", "18:00", "18:40", minutes: 40),
            move("bus", "19:00", "19:20", minutes: 20, from: "역", to: "집"),
        ]
        let paid = [Day.Expense(id: "e", time: "2026-11-11T19:25+09:00", title: "버스", category: "transport", kind: "expense", amount: 1_500, currency: "KRW", amountKRW: nil)]
        let fares = AITaskProducer.candidates(day(moves: moves, expenses: paid), language: .korean, now: now).filter { $0.kind == .fareCheck }
        XCTAssertEqual(fares.count, 1)
        XCTAssertEqual(fares.first?.context["modes"], "subway,subway")
        XCTAssertEqual(fares.first?.context["from"], "교대")
        XCTAssertEqual(fares.first?.context["to"], "마곡나루")
    }

    func testShortSameModeFragmentsAndUnclearMoves() {
        let moves = [
            move("walk", "10:00", "10:04", minutes: 4),
            move("walk", "10:06", "10:09", minutes: 3),
            move("walk", "10:10", "10:15", minutes: 5),
            move("other", "14:00", "14:10", minutes: 10),
            move("car", "16:00", "16:20", minutes: 20, from: nil, to: nil),
        ]
        let found = AITaskProducer.candidates(day(moves: moves), language: .korean, now: now)
        XCTAssertEqual(found.filter { $0.kind == .mergeReview }.count, 1)
        XCTAssertTrue(found.first { $0.kind == .mergeReview }?.text.contains("× 3") == true)
        XCTAssertEqual(found.filter { $0.kind == .routeCheck }.count, 2)
    }

    func testRecentItemsWaitAndDayIsCapped() {
        let late = [move("other", "22:40", "22:55", minutes: 15)]
        XCTAssertTrue(AITaskProducer.candidates(day(moves: late), language: .korean, now: now).isEmpty)
        let many = (0..<8).map { move("other", String(format: "%02d:00", 8 + $0), String(format: "%02d:10", 8 + $0), minutes: 10) }
        XCTAssertEqual(AITaskProducer.candidates(day(moves: many), language: .korean, now: now).count, AITaskProducer.perDayLimit)
    }

    func testEnqueuesOnceAndRetriesAfterConnecting() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AITaskProducerTests-\(UUID())"))
        let value = day(moves: [move("other", "14:00", "14:10", minutes: 10)])
        XCTAssertEqual(AITaskProducer.enqueue([value], language: .korean, now: now, defaults: defaults), 0)
        defaults.set(["key": "피클"], forKey: AssistantKeyLabels.labelsKey)
        XCTAssertEqual(AITaskProducer.enqueue([value], language: .korean, now: now, defaults: defaults), 1)
        XCTAssertEqual(AITaskProducer.enqueue([value], language: .korean, now: now, defaults: defaults), 0)
        XCTAssertEqual(AITaskQueue.pendingUploads(defaults).map(\.kind), [.routeCheck])
        XCTAssertEqual(AITaskQueue.pendingUploads(defaults).first?.date, "2026-11-11")
    }
}

/// Siri·단축어(SIR1111A01): 앱이 꺼져 있을 때 받은 메모는 쌓였다가 앱이 열리면 반영되고, 화면 열기 요청은 한 번만 꺼낸다.
@MainActor
final class SiriIntentsTests: XCTestCase {
    func testInboxQueuesWithoutALiveModelAndDrainsIntoTheModel() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SiriInbox-\(UUID())"))
        let previous = AppModel.live
        AppModel.live = nil
        defer { AppModel.live = previous }
        let at = Date(timeIntervalSince1970: 1_794_365_000)
        await SiriInbox.addMemo("출근", at: at, defaults: defaults)
        XCTAssertEqual(SiriInbox.pending(defaults).map(\.text), ["출근"])

        let model = AppModel(repository: InMemoryPlanRepository(snapshot: .empty), cloudSyncService: nil)
        await model.bootstrap()
        await SiriInbox.drain(into: model, defaults: defaults)
        XCTAssertTrue(SiriInbox.pending(defaults).isEmpty)
        XCTAssertEqual(model.snapshot.memos.map(\.text), ["출근"])
        XCTAssertEqual(model.snapshot.memos.first?.occurredAt, at)
    }

    /// 요청은 알림으로 홈 화면에 가고, 꺼내면 비워진다(시험 앱의 홈 화면이 먼저 꺼낼 수 있다).
    func testNavigationRequestPostsAndIsTakenOnce() {
        let posted = expectation(forNotification: SiriNavigation.notification, object: nil)
        SiriNavigation.request(.ledger)
        wait(for: [posted], timeout: 1)
        _ = SiriNavigation.take()
        XCTAssertNil(SiriNavigation.take())
    }

    func testCheckInTextsAreDistinct() {
        let texts = [SiriCheckIn.arriveWork, .leaveWork, .wakeUp, .goToBed, .goOut, .comeHome].map { $0.memoText(.korean) }
        XCTAssertEqual(Set(texts).count, texts.count)
        XCTAssertEqual(SiriCheckIn.arriveWork.memoText(.korean), "출근")
    }
}

/// RDE1111A01: 같은 수단의 동작 기록 바로 뒤에 붙은 이동 기록 조각은 「하차」다.
final class RailRidePhaseTests: XCTestCase {
    func testRideRightAfterSameModeMotionBecomesAlighting() {
        let segments = [
            MapHomeTimeRailSegment(startMinute: 568, endMinute: 607, categoryID: "movement", title: "자동차", behavior: "car"),
            MapHomeTimeRailSegment(startMinute: 607, endMinute: 622, categoryID: "movement", title: "자동차 탑승", behavior: "car"),
            MapHomeTimeRailSegment(startMinute: 622, endMinute: 634, categoryID: "movement", title: "걷기", behavior: "walking"),
            MapHomeTimeRailSegment(startMinute: 700, endMinute: 710, categoryID: "movement", title: "지하철 탑승", behavior: "subway"),
        ]
        let labeled = MapHomeTimeRailSegmentEngine.labelingAlighting(segments)
        XCTAssertEqual(labeled.map(\.title), ["자동차", "자동차 하차", "걷기", "지하철 탑승"])
        XCTAssertEqual(labeled[1].startMinute, 607)
    }
}

final class PaymentAutomationFilterTests: XCTestCase {
    func testOnlyPaymentMessagesAreCandidates() {
        XCTAssertTrue(LedgerMessageParser.isPaymentCandidate("[Web발신]\n신한카드(1234)승인 홍*동 12,000원(일시불)11/10 12:30 스타벅스"))
        XCTAssertTrue(LedgerMessageParser.isPaymentCandidate("KB국민은행 출금 12,000원 스타벅스강남 잔액 345,000원"))
        XCTAssertFalse(LedgerMessageParser.isPaymentCandidate("엄마: 저녁 먹었어? 반찬 3만원어치 샀어"))
        XCTAssertFalse(LedgerMessageParser.isPaymentCandidate("인증번호 [123456]을 입력해 주세요"))
        XCTAssertFalse(LedgerMessageParser.isPaymentCandidate("[광고] 신한카드 승인 이벤트 10,000원"))
        XCTAssertFalse(LedgerMessageParser.isPaymentCandidate("현대카드 11월 결제 예정 금액 320,000원"))
    }

    func testSamePaymentFromTextAndAlertIsSavedOnce() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let saved = LedgerEntry(occurredAt: at, amount: 12_000, title: "스타벅스", source: .message)
        XCTAssertTrue(LedgerMessageParser.isDuplicate(LedgerEntry(occurredAt: at.addingTimeInterval(120), amount: 12_000, title: "결제", source: .message), in: [saved]))
        XCTAssertFalse(LedgerMessageParser.isDuplicate(LedgerEntry(occurredAt: at.addingTimeInterval(3_600), amount: 12_000, title: "스타벅스", source: .message), in: [saved]))
        XCTAssertFalse(LedgerMessageParser.isDuplicate(LedgerEntry(occurredAt: at, amount: 4_500, title: "스타벅스", source: .message), in: [saved]))
    }
}

final class MealPlaceLaneTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minute: Int) -> Date { base.addingTimeInterval(TimeInterval(minute * 60)) }
    private func point(_ lat: Double, _ accuracy: Double = 30) -> GeoPoint {
        GeoPoint(latitude: lat, longitude: 127, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1)
    }
    private func meal(_ start: Int, _ end: Int, evidence: [String] = []) -> ActualRecord {
        ActualRecord(id: UUID(), planID: nil, title: "식사", categoryID: "eating", startedAt: at(start), endedAt: at(end),
                     source: .location, confidence: .medium, createdAt: at(start), behavior: "meal", evidence: evidence)
    }

    func testShortIndoorMealBetweenOfficeStaysGetsAPlace() {
        let office = [
            PlaceStay(placeKey: "frequent-office", displayName: "회사", span: TimeSpan(start: at(0), end: at(40)), confidence: .high, point: point(37.5)),
            PlaceStay(placeKey: "frequent-office", displayName: "회사", span: TimeSpan(start: at(75), end: at(200)), confidence: .high, point: point(37.5)),
        ]
        let readings = [50, 55, 60].map { SensorReading(timestamp: at($0), point: point(37.503)) }
        let filled = NLEMealPlaces.filling(places: office, actuals: [meal(45, 61)], readings: readings, frequentPlaces: [])
        XCTAssertEqual(filled.count, 3)
        XCTAssertEqual(filled[1].span, TimeSpan(start: at(45), end: at(61)))
        XCTAssertEqual(filled[1].point?.latitude ?? 0, 37.503, accuracy: 0.0001)
    }

    func testCoveredMealAddsNothingAndRegisteredRestaurantKeepsItsKey() {
        let stay = PlaceStay(placeKey: "a", displayName: "식당", span: TimeSpan(start: at(0), end: at(60)), confidence: .high, point: point(37.5))
        XCTAssertEqual(NLEMealPlaces.filling(places: [stay], actuals: [meal(10, 30)], readings: [], frequentPlaces: []).count, 1)
        XCTAssertEqual(NLEMealPlaces.uncovered(TimeSpan(start: at(0), end: at(30)), by: [TimeSpan(start: at(10), end: at(20))]).count, 2)
        XCTAssertTrue(NLEMealPlaces.filling(places: [], actuals: [meal(10, 30)], readings: [], frequentPlaces: []).isEmpty)
    }
}

/// TOL1111A01: 통행료가 붙은 자동차 이동을 배워 같은 길·되돌아오는 길에 같은 통행료를 한 번만 넣는다.
final class LedgerTollRepeatTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_794_355_200) // 2026-11-11 00:00 KST 근처
    private func at(_ hour: Double) -> Date { base.addingTimeInterval(hour * 3_600) }
    private func toll(_ hour: Double, title: String = "경인고속도로 통행료 (출근)") -> LedgerEntry {
        var entry = LedgerEntry(occurredAt: at(hour), amount: 900, title: title)
        entry.category = .transport
        return entry
    }

    func testLearnsMorningTollAndAddsReturnTripOnce() {
        let morning = LedgerTollRepeat.Drive(from: "집", to: "회사", start: at(9), end: at(9.6))
        let evening = LedgerTollRepeat.Drive(from: "회사", to: "집", start: at(19), end: at(19.7))
        let entries = [toll(9.66)]
        let rules = LedgerTollRepeat.learn(drives: [morning, evening], entries: entries, into: [:])
        XCTAssertEqual(rules[LedgerTollRepeat.pair("집", "회사")]?.amount, 900)
        let added = LedgerTollRepeat.entries(drives: [morning, evening], existing: entries, rules: rules, handled: [], now: at(20.5))
        XCTAssertEqual(added.count, 1, "아침은 이미 있고 저녁만 넣는다")
        XCTAssertEqual(added.first?.entry.title, "경인고속도로 통행료 (퇴근)")
        XCTAssertEqual(added.first?.entry.occurredAt, evening.end)
        XCTAssertEqual(added.first?.entry.category, .transport)
        let again = LedgerTollRepeat.entries(drives: [evening], existing: entries, rules: rules,
                                             handled: [evening.key], now: at(21))
        XCTAssertTrue(again.isEmpty, "넣은 이동은 지워져도 다시 넣지 않는다")
    }

    func testSkipsUnsettledUnknownAndAlreadyPaidDrives() {
        let rules = ["집→회사": LedgerTollRepeat.Rule(amount: 900, currency: "KRW", title: "통행료", learnedAt: at(0))]
        let driving = LedgerTollRepeat.Drive(from: "집", to: "회사", start: at(20), end: at(20.45))
        XCTAssertTrue(LedgerTollRepeat.entries(drives: [driving], existing: [], rules: rules, handled: [], now: at(20.5)).isEmpty, "도착 10분 전에는 기다린다")
        let other = LedgerTollRepeat.Drive(from: "집", to: "마트", start: at(10), end: at(10.5))
        XCTAssertTrue(LedgerTollRepeat.entries(drives: [other], existing: [], rules: rules, handled: [], now: at(12)).isEmpty)
        let paid = LedgerTollRepeat.Drive(from: "집", to: "회사", start: at(8), end: at(9))
        XCTAssertTrue(LedgerTollRepeat.entries(drives: [paid], existing: [toll(8.9, title: "톨비")], rules: rules, handled: [], now: at(12)).isEmpty)
        XCTAssertEqual(LedgerTollRepeat.reversed("통행료 (퇴근)"), "통행료 (출근)")
        XCTAssertFalse(LedgerTollRepeat.isToll(LedgerEntry(occurredAt: at(1), amount: 900, title: "통행료")), "교통 분류가 아니면 통행료로 보지 않는다")
    }
}
