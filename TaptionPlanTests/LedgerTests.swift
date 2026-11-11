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
