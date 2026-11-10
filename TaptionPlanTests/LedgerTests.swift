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
