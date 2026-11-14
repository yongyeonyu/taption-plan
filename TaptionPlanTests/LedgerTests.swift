import XCTest
@testable import TaptionPlan
import TaptionPlanEngine

/// 가계부(LED1110A01): AI 명령 읽기, 환율, 단체 정산, 오늘 손익, 메모리 장부.
@MainActor
final class LedgerTests: XCTestCase {
    /// 「AI에게 요청하기」가 여는 AI(AIG1114A01): 고른 AI → OAuth 앱 이름 → Claude.
    func testAITaskRequestPicksConnectedProvider() {
        let name = "ai-request-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        XCTAssertEqual(AITaskRequest.provider(defaults: store), .claude)
        AssistantKeyLabels.saveClients([AssistantScopedKey(id: "k1", scope: .write, expiresAt: nil, source: "oauth", client: "ChatGPT")], defaults: store)
        XCTAssertEqual(AITaskRequest.provider(defaults: store), .chatGPT)
        AssistantKeyProviders.save("k2", provider: .pickle, defaults: store)
        XCTAssertEqual(AITaskRequest.provider(defaults: store), .pickle)
        XCTAssertTrue(AITaskRequest.prompt.contains("get_ai_tasks"))
    }

    /// 앨범 영수증 자동 확인(RPA1114A01): 영수증만 고르고, 켜면 하루 전부터 본다.
    @MainActor
    func testAITaskRequestChatURLCarriesPrompt() {
        let url = AITaskRequest.chatURL(.claude, prompt: "Check now & reply")
        XCTAssertEqual(url?.host, "claude.ai")
        XCTAssertEqual(url?.path, "/new")
        XCTAssertEqual(URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "Check now & reply")
        XCTAssertEqual(AITaskRequest.chatURL(.chatGPT)?.host, "chatgpt.com")
    }

    func testPaymentInboxHidesTextsChosenAsSkip() throws {
        let name = "PaymentInboxSkip-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var skipped = PaymentInbox.Item(text: "discount notice 1,000", receivedAt: .now, outcome: .skipped, message: "")
        skipped.choice = .ignore
        var transfer = PaymentInbox.Item(text: "card top-up 5,000", receivedAt: .now, outcome: .skipped, message: "")
        transfer.choice = .ignore
        transfer.isInternal = true
        let plain = PaymentInbox.Item(text: "shop 3,000", receivedAt: .now, outcome: .unread, message: "")
        defaults.set(try JSONEncoder().encode([skipped, transfer, plain]), forKey: PaymentInbox.key)
        XCTAssertEqual(PaymentInbox.items(defaults).map(\.id), [transfer.id, plain.id])
    }

    func testRideLabelShowsSubwayLinesAndNothingForUnknownBus() {
        let span = TimeSpan(start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_001_800))
        func segment(_ mode: TravelMode) -> TravelSegment {
            TravelSegment(mode: mode, span: span, distanceMeters: 3_000, confidence: .high, evidence: [])
        }
        var subway = segment(.subway)
        XCTAssertEqual(MapHomeRideLabel.text(for: subway), "?")
        subway.subwayRoute = SubwayRoutePath(stops: [], lineNames: ["1호선", "2호선"], transferStationNames: [])
        XCTAssertEqual(MapHomeRideLabel.text(for: subway), "1호선→2호선")
        let name = "RideLabel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(MapHomeRideLabel.text(for: segment(.bus), defaults: defaults), "?")
        // 근거에 적힌 노선과, 그 시각 교통 지출에 적힌 번호로도 정한다.
        var noted = segment(.bus)
        noted.evidence = ["노선 80·81"]
        XCTAssertEqual(MapHomeRideLabel.text(for: noted, defaults: defaults), "80·81")
        let fare = LedgerEntry(occurredAt: span.end.addingTimeInterval(600), amount: 1_500, category: .transport, title: "버스 요금 · 80번")
        let lunch = LedgerEntry(occurredAt: span.start, amount: 9_000, category: .food, title: "분식 3번 테이블")
        XCTAssertEqual(MapHomeRideLabel.busNumber(in: [fare, lunch], for: segment(.bus)), "80")
        XCTAssertNil(MapHomeRideLabel.busNumber(in: [lunch], for: segment(.bus)))
        // 정해 준 노선은 이름표에 나오고, 더는 AI에게 맡길 구간이 아니다.
        let unknownSubway = segment(.subway)
        XCTAssertNotNil(RideLineTasks.candidates(unknownSubway, defaults: defaults))
        SubwayLineChoice.remember(unknownSubway, line: "9호선", defaults: defaults)
        XCTAssertEqual(MapHomeRideLabel.text(for: unknownSubway, defaults: defaults), "9호선")
        XCTAssertNil(RideLineTasks.candidates(unknownSubway, defaults: defaults))
        XCTAssertEqual(RideLineTasks.candidates(segment(.bus), defaults: defaults), [], "an unknown bus goes to the AI without candidates")
        BusRouteCheck.remember(segment(.bus), routes: [.init(number: "80", kind: "")], defaults: defaults)
        XCTAssertNil(RideLineTasks.candidates(segment(.bus), defaults: defaults))
        XCTAssertNil(RideLineTasks.candidates(segment(.car), defaults: defaults))
        // 오래된 구간은 맡기지 않는다: 끝난 지 10분~36시간인 것만.
        let ride = segment(.bus)
        XCTAssertTrue(RideLineTasks.pending([ride], now: span.end.addingTimeInterval(300)).isEmpty)
        XCTAssertEqual(RideLineTasks.pending([ride], now: span.end.addingTimeInterval(3_600)).count, 1)
        XCTAssertTrue(RideLineTasks.pending([ride], now: span.end.addingTimeInterval(40 * 3_600)).isEmpty)
    }

    @MainActor
    func testRuleStoreAppliesUserEditsAndFeedsTheLedgerPipeline() {
        // 서버 사본에 사용자가 끄고 지운 것을 얹는다.
        let cafe = Rule(id: "r1", type: "merchant_category", match: ["contains": .list(["빵집"])], result: ["category": .text("cafe")], source: .init(by: "ai"))
        let later = Rule(id: "r2", type: "place_pair_mode", match: ["from": .text("집"), "to": .text("회사")], result: ["mode": .text("bus")], source: .init(by: "ai"))
        let gone = Rule(id: "r3", type: "skip_word", match: ["word": .text("광고")], source: .init(by: "user"))
        let set = RuleSet(version: 4, rules: [cafe, later, gone])
        let edited = AssistantRuleStore.applying([.init(op: "disable", id: "r1"), .init(op: "delete", id: "r3"), .init(op: "enable", id: "r1")], to: set)
        XCTAssertEqual(edited.rules.map(\.id), ["r1", "r2"])
        XCTAssertEqual(edited.rules.first?.enabled, true)
        // 읽을 수는 있어도 이 빌드가 판단에 쓰지 않는 종류는 「건너뜀」으로 알린다.
        let parts = AssistantRuleStore.split(edited)
        XCTAssertEqual(parts.rules.map(\.id), ["r1"])
        XCTAssertEqual(parts.skipped, ["r2"])
        XCTAssertEqual(AssistantRuleStore.stableID("광고"), AssistantRuleStore.stableID("광고"))
        XCTAssertNotEqual(AssistantRuleStore.stableID("광고"), AssistantRuleStore.stableID("이벤트"))

        // 판단에 쓰는 사본을 바꾸면 가게 분류와 영수증 판정이 따라간다.
        defer { AssistantRuleSnapshot.set([]) }
        XCTAssertEqual(LedgerCategory.guess("동네 빵집"), .other)
        AssistantRuleSnapshot.set([cafe, Rule(id: "r4", type: "receipt_hint", match: ["contains": .list(["필터 추가"])], result: ["isReceipt": .flag(false)])])
        XCTAssertEqual(LedgerCategory.guess("동네 빵집"), .cafe)
        XCTAssertEqual(LedgerCategory.guess("스타벅스"), .cafe, "the built-in table still answers what no rule covers")
        let screenshot = ["합계 12,000원", "카드 승인", "영수증", "필터 추가"]
        XCTAssertFalse(ReceiptPhotoScanner.isReceipt(screenshot), "a rule says this layout is not a receipt")
        XCTAssertEqual(AssistantRuleListView.summary(cafe), "빵집 → cafe")
    }

    func testReceiptPhotoMarksKeepLatestWithinLimit() {
        let name = "ReceiptPhotoMarks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(ReceiptPhotoMarks.contains("a", defaults: defaults))
        ReceiptPhotoMarks.add("a", defaults: defaults)
        ReceiptPhotoMarks.add("a", defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: ReceiptPhotoMarks.key), ["a"])
        for index in 0..<ReceiptPhotoMarks.limit { ReceiptPhotoMarks.add("p\(index)", defaults: defaults) }
        XCTAssertFalse(ReceiptPhotoMarks.contains("a", defaults: defaults))
        XCTAssertTrue(ReceiptPhotoMarks.contains("p0", defaults: defaults))
        XCTAssertEqual(defaults.stringArray(forKey: ReceiptPhotoMarks.key)?.count, ReceiptPhotoMarks.limit)
        // AI가 끝낸 일이 이 사진에서 온 것이면 「AI」 표시가 붙는다.
        ReceiptPhotoMarks.link("photo-1", task: "task-1", defaults: defaults)
        ReceiptPhotoMarks.noteReviewed(["other-task"], defaults: defaults)
        XCTAssertFalse(ReceiptPhotoMarks.isReviewed("photo-1", defaults: defaults))
        ReceiptPhotoMarks.noteReviewed(["task-1", "task-1"], defaults: defaults)
        XCTAssertTrue(ReceiptPhotoMarks.isReviewed("photo-1", defaults: defaults))
        XCTAssertEqual(defaults.stringArray(forKey: ReceiptPhotoMarks.reviewedKey), ["photo-1"])
    }

    func testReceiptPhotoJudgementAndEnabling() {
        let receipt = ["맛있는식당", "사업자 123-45-67890", "김치찌개 9,000", "공기밥 1,000", "부가세 909", "합계 10,000원", "승인번호 12345678"]
        XCTAssertTrue(ReceiptPhotoScanner.isReceipt(receipt))
        XCTAssertFalse(ReceiptPhotoScanner.isReceipt(["오늘의 메뉴", "아메리카노 4,500원", "라떼 5,000원", "영업 09:00"]), "menu board is not a receipt")
        XCTAssertFalse(ReceiptPhotoScanner.isReceipt(["합계 10,000원", "영수증"]), "too few lines")
        XCTAssertFalse(ReceiptPhotoScanner.isReceipt([]))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(ReceiptPhotoScanner.skipsUnreadable(created: now.addingTimeInterval(-600), now: now))
        XCTAssertTrue(ReceiptPhotoScanner.skipsUnreadable(created: now.addingTimeInterval(-7_200), now: now))
        // 영수증에 찍힌 날이 찍은 날보다 앞이면 그날로(어제 결제, 오늘 촬영).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let taken = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 1, minute: 20))!
        let yesterday = ReceiptPhotoScanner.receiptDay(["거래일시 2026-11-13 18:42:10", "합계 10,000원"], taken: taken, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.month, .day], from: yesterday), DateComponents(month: 11, day: 13))
        XCTAssertEqual(calendar.component(.day, from: ReceiptPhotoScanner.receiptDay(["26.11.12 12:00"], taken: taken, calendar: calendar)), 12)
        XCTAssertEqual(ReceiptPhotoScanner.receiptDay(["2026/11/14 00:50"], taken: taken, calendar: calendar), taken, "same day keeps the photo time")
        XCTAssertEqual(ReceiptPhotoScanner.receiptDay(["2027-01-01"], taken: taken, calendar: calendar), taken, "a future date is not trusted")
        XCTAssertEqual(ReceiptPhotoScanner.receiptDay(["사업자 123-45-67890"], taken: taken, calendar: calendar), taken)
        // 결제 문자로 이미 들어간 같은 결제는 한 건으로(금액·시각 10분·가게 이름).
        let paidAt = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 18, minute: 44))!
        let fromText = LedgerEntry(occurredAt: paidAt, amount: 10_000, title: "맛있는식당 본점", source: .message)
        let other = LedgerEntry(occurredAt: paidAt, amount: 10_000, title: "동네약국", source: .message)
        let moment = ReceiptPhotoScanner.receiptMoment(["거래일시 2026-11-13 18:42:10"], day: yesterday, calendar: calendar)
        XCTAssertEqual(moment.map { calendar.component(.minute, from: $0) }, 42)
        XCTAssertEqual(ReceiptPhotoScanner.sameSpending(amount: 10_000, merchant: "맛있는식당", day: yesterday, moment: moment, in: [other, fromText], calendar: calendar)?.id, fromText.id)
        XCTAssertNil(ReceiptPhotoScanner.sameSpending(amount: 9_000, merchant: "맛있는식당", day: yesterday, moment: moment, in: [fromText], calendar: calendar), "different amount")
        XCTAssertNil(ReceiptPhotoScanner.sameSpending(amount: 10_000, merchant: "맛있는식당", day: yesterday, moment: moment?.addingTimeInterval(3_600), in: [fromText], calendar: calendar), "an hour apart")
        XCTAssertNil(ReceiptPhotoScanner.sameSpending(amount: 10_000, merchant: "다른가게", day: yesterday, moment: moment, in: [fromText], calendar: calendar), "different shop")
        XCTAssertNotNil(ReceiptPhotoScanner.sameSpending(amount: 10_000, merchant: "맛있는식당", day: yesterday, moment: nil, in: [fromText], calendar: calendar), "no time on the receipt: same day")
        // 「AI」·「내역」 탭은 고른 날 것만.
        let today = AITaskQueue.Task(id: "t", kind: .receiptText, status: .waiting, createdAt: taken)
        let old = AITaskQueue.Task(id: "o", kind: .receiptText, status: .done, createdAt: paidAt)
        let pending = AITaskQueue.Task(id: "p", kind: .other, status: .waiting)
        XCTAssertEqual(AITaskPanel.tasks([today, old, pending], on: taken, now: taken, calendar: calendar).map(\.id), ["t", "p"])
        XCTAssertEqual(AITaskPanel.tasks([today, old, pending], on: paidAt, now: taken, calendar: calendar).map(\.id), ["o"])
        let name = "receipt-scan-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        // 스위치 없이 늘 돈다. 처음에는 하루 전부터 보고, 그 뒤로는 적어 둔 자리부터.
        XCTAssertEqual(ReceiptPhotoScanner.startCursor(now: now, defaults: store), now.addingTimeInterval(-86_400))
        XCTAssertEqual(ReceiptPhotoScanner.startCursor(now: now.addingTimeInterval(3_600), defaults: store), now.addingTimeInterval(-86_400))
    }

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

    func testAcknowledgedTasksLeaveTheQueueAndAreNotSentAgain() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AITaskQueueTests-\(UUID())"))
        defaults.set(["key": "피클"], forKey: AssistantKeyLabels.labelsKey)
        XCTAssertTrue(AITaskQueue.enqueue(.other, text: "first", defaults: defaults))
        XCTAssertTrue(AITaskQueue.enqueue(.other, text: "second", defaults: defaults))
        let ids = AITaskQueue.pendingUploads(defaults).map(\.id)
        AITaskQueue.acknowledge([ids[0], "server-only"], defaults: defaults)
        XCTAssertEqual(AITaskQueue.pendingUploads(defaults).map(\.text), ["second"])
        XCTAssertEqual(AITaskQueue.unsent(defaults).map(\.text), ["second"])
        // 응답을 못 받아 큐에 남아 있던 일도, 서버가 받은 id면 다시 올리지 않는다.
        defaults.set([ids[1]], forKey: AITaskQueue.ackedKey)
        XCTAssertTrue(AITaskQueue.unsent(defaults).isEmpty)
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

    /// TOL1112A01: 퇴근길이 일곱 조각으로 잡혀 통행료가 일곱 번 들어간 것(대표 신고 2026-11-12).
    func testFragmentedDriveAddsOneTollAndOldDuplicatesAreRemoved() {
        let rules = ["집→회사": LedgerTollRepeat.Rule(amount: 900, currency: "KRW", title: "통행료 (출근)", learnedAt: at(0))]
        let fragments = (0..<7).map { LedgerTollRepeat.Drive(from: "회사", to: "집", start: at(19 + Double($0) * 0.1), end: at(19.78)) }
        let added = LedgerTollRepeat.entries(drives: fragments, existing: [], rules: rules, handled: [], now: at(21))
        XCTAssertEqual(added.count, 1)
        let apart = [LedgerTollRepeat.Drive(from: "회사", to: "집", start: at(12), end: at(12.5)),
                     LedgerTollRepeat.Drive(from: "회사", to: "집", start: at(19), end: at(19.7))]
        XCTAssertEqual(LedgerTollRepeat.entries(drives: apart, existing: [], rules: rules, handled: [], now: at(21)).count, 2, "떨어진 두 번은 따로")

        func auto(_ hour: Double, note: String = "같은 길 통행료 자동 추가 · 회사 → 집") -> LedgerEntry {
            var entry = toll(hour, title: "통행료 (퇴근)")
            entry.note = note
            return entry
        }
        let book = (0..<7).map { _ in auto(19.78) } + [auto(9.6, note: "같은 길 통행료 자동 추가 · 집 → 회사"), toll(19.78, title: "통행료 (퇴근)")]
        let extra = LedgerTollRepeat.duplicates(in: book)
        XCTAssertEqual(extra.count, 6, "자동으로 넣은 같은 것만, 하나는 남긴다")
        XCTAssertFalse(extra.contains(book[7].id))
        XCTAssertFalse(extra.contains(book[8].id), "손으로 넣은 것은 지우지 않는다")
        XCTAssertTrue(LedgerTollRepeat.duplicates(in: [auto(19.78), auto(19.78 + 24)]).isEmpty, "다음 날 것은 중복이 아니다")
    }

    /// TOL1112B01: 시간·차종 할인. base는 2026-11-11(수) 00:00 UTC.
    func testTollDiscountByTimeAndVehicle() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")! // base가 UTC 자정(수요일)이라 시각을 그대로 읽는다
        let rate = { (hour: Double, vehicle: LedgerTollDiscount.Vehicle, off: Bool) in
            LedgerTollDiscount.applied(at: self.at(hour), vehicle: vehicle, isOffDay: off, calendar: calendar)
        }
        XCTAssertEqual(rate(6.5, .standard, false), .init(rate: 0.5, reason: .commuteHalf))
        XCTAssertEqual(rate(8, .standard, false), .init(rate: 0.2, reason: .commuteFifth))
        XCTAssertEqual(rate(10, .standard, false), .init(rate: 0, reason: .none))
        XCTAssertEqual(rate(19.5, .standard, false), .init(rate: 0.2, reason: .commuteFifth))
        XCTAssertEqual(rate(21, .standard, false), .init(rate: 0.5, reason: .commuteHalf))
        XCTAssertEqual(rate(22, .standard, false).rate, 0)
        XCTAssertEqual(rate(8, .standard, true), .init(rate: -0.05, reason: .weekend), "주말에는 출퇴근 할인이 없고 할증")
        XCTAssertEqual(rate(23, .standard, true).rate, 0)
        XCTAssertEqual(rate(10, .compact, false), .init(rate: 0.5, reason: .compact))
        XCTAssertEqual(rate(10, .compact, true).rate, 0.5, "할인받는 차는 할증하지 않는다")
        XCTAssertEqual(rate(8, .electric, false), .init(rate: 0.3, reason: .electric), "2026년 30%가 출퇴근 20%보다 크다")
        XCTAssertEqual(rate(6, .electric, false).reason, .commuteHalf, "큰 것 하나만")
        XCTAssertEqual(LedgerTollDiscount.vehicleRate(.electric, year: 2027), 0.2)
        XCTAssertEqual(LedgerTollDiscount.vehicleRate(.electric, year: 2028), 0)
        XCTAssertEqual(LedgerTollDiscount.amount(base: 900, rate: 0.2), 720)
        XCTAssertEqual(LedgerTollDiscount.amount(base: 900, rate: -0.05), 950, "945는 10원 단위로")
        XCTAssertEqual(LedgerTollDiscount.base(from: 720, rate: 0.2), 900)
    }

    func testReturnTollUsesDiscountAndAsksWhenBandsDiffer() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")! // base가 UTC 자정(수요일)이라 시각을 그대로 읽는다
        let rules = ["집→회사": LedgerTollRepeat.Rule(amount: 900, currency: "KRW", title: "통행료 (출근)", learnedAt: at(9.66))]
        let add = { (start: Double, end: Double, vehicle: LedgerTollDiscount.Vehicle) in
            LedgerTollRepeat.entries(drives: [.init(from: "회사", to: "집", start: self.at(start), end: self.at(end))], existing: [], rules: rules,
                                     handled: [], now: self.at(23.5), vehicle: vehicle, calendar: calendar).first
        }
        let evening = add(19.1, 19.78, .standard)
        XCTAssertEqual(evening?.entry.amount, 720, "18~20시 20%")
        XCTAssertEqual(evening?.suspicious, false)
        XCTAssertEqual(add(19.1, 19.78, .compact)?.entry.amount, 450)
        XCTAssertEqual(add(13, 13.5, .standard)?.entry.amount, 900)
        let crossing = add(19.7, 20.3, .standard)
        XCTAssertEqual(crossing?.suspicious, true, "20%와 50% 사이에 걸치면 확인을 받는다")

        // 이미 900원으로 넣은 퇴근 통행료를 720원으로 맞추고, 손으로 고친 금액은 두기.
        var old = toll(19.78, title: "통행료 (퇴근)")
        old.note = "같은 길 통행료 자동 추가 · 회사 → 집"
        let applied = LedgerTollDiscount.applied(at: old.occurredAt, vehicle: .standard, isOffDay: false, calendar: calendar)
        let fixed = LedgerTollRepeat.adjusted(old, rules: rules, base: { $0.amount }, applied: applied, label: "출퇴근 할인 20%")
        XCTAssertEqual(fixed?.amount, 720)
        XCTAssertEqual(fixed?.note, "같은 길 통행료 자동 추가 · 회사 → 집 · 출퇴근 할인 20%")
        XCTAssertNil(fixed.flatMap { LedgerTollRepeat.adjusted($0, rules: rules, base: { $0.amount }, applied: applied, label: "출퇴근 할인 20%") }, "한 번 맞춘 것은 다시 안 고친다")
        old.amount = 1_000
        XCTAssertNil(LedgerTollRepeat.adjusted(old, rules: rules, base: { $0.amount }, applied: applied, label: nil), "손으로 고친 금액")
        var manual = toll(19.78, title: "통행료 (퇴근)")
        manual.note = "내가 넣음"
        XCTAssertNil(LedgerTollRepeat.adjusted(manual, rules: rules, base: { $0.amount }, applied: applied, label: nil))
    }
}

/// STL1111A01: 원 단위 나누기와 최소 송금(Taption Trip `TripSettlementChecksTests`·`TripSettlementTests`의 숫자를 그대로 옮김).
final class LedgerSplitTests: XCTestCase {
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func nets(_ pairs: [(String, Int)]) -> [(name: String, net: Int)] { pairs.map { (name: $0.0, net: $0.1) } }

    private func residual(_ balances: [String: Int], _ transfers: [LedgerSplit.Transfer]) -> [String: Int] {
        var left = balances
        for transfer in transfers {
            left[transfer.from, default: 0] += transfer.amount
            left[transfer.to, default: 0] -= transfer.amount
        }
        return left
    }

    func testExactSearchUsesFewerTransfersWhenBalancesSplitIntoZeroSumGroups() {
        let order = ["나", "현우", "지연", "민수", "수아"]
        let balances = ["나": 5_000, "현우": 4_000, "지연": -4_000, "민수": -3_000, "수아": -2_000]
        // {+5, −2, −3}과 {+4, −4}: 그냥 짝지으면 4건, 묶으면 3건.
        XCTAssertEqual(LedgerSplit.greedy(order.map { (name: $0, net: balances[$0]!) }).count, 4)
        let transfers = LedgerSplit.transfers(balances, order: order)
        XCTAssertEqual(transfers.count, 3)
        XCTAssertTrue(residual(balances, transfers).values.allSatisfy { $0 == 0 })
        XCTAssertTrue(transfers.contains(.init(from: "지연", to: "현우", amount: 4_000)))
        XCTAssertEqual(transfers, LedgerSplit.transfers(balances, order: order), "결과 순서가 매번 같아야 한다")
    }

    func testGreedyResultIsKeptUnchangedWhenAlreadyMinimal() {
        let order = ["나", "A", "B", "C"]
        let balances = ["나": 9_000, "A": -3_000, "B": -3_000, "C": -3_000]
        XCTAssertEqual(LedgerSplit.transfers(balances, order: order), LedgerSplit.greedy(order.map { (name: $0, net: balances[$0]!) }))
    }

    func testMoreThanTwelveNonZeroBalancesKeepGreedy() {
        let pairs = (0..<14).map { ("P\($0)", $0 < 7 ? ($0 + 1) * 1_000 : -($0 - 6) * 1_000) }
        XCTAssertNil(LedgerSplit.zeroSumGroups(nets(pairs)))
        XCTAssertEqual(LedgerSplit.transfers(Dictionary(uniqueKeysWithValues: pairs), order: pairs.map(\.0)), LedgerSplit.greedy(nets(pairs)))
    }

    func testRandomBalancesSettleExactlyWithNoMoreTransfersThanGreedy() {
        var generator = SeededGenerator(state: 0x5EED_0006)
        var improved = 0
        for _ in 0..<400 {
            let count = Int.random(in: 2...10, using: &generator)
            let names = (0..<count).map { "P\($0)" }
            var values = (0..<(count - 1)).map { _ in Int.random(in: -30...30, using: &generator) * 1_000 }
            values.append(-values.reduce(0, +))
            let balances = Dictionary(uniqueKeysWithValues: zip(names, values).map { ($0, $1) })
            let transfers = LedgerSplit.transfers(balances, order: names)
            let greedy = LedgerSplit.greedy(nets(Array(zip(names, values))))
            XCTAssertLessThanOrEqual(transfers.count, greedy.count)
            if transfers.count < greedy.count { improved += 1 }
            XCTAssertTrue(residual(balances, transfers).values.allSatisfy { $0 == 0 }, "\(values)")
            XCTAssertTrue(transfers.allSatisfy { $0.amount > 0 && $0.from != $0.to })
            XCTAssertLessThanOrEqual(transfers.count, max(0, values.filter { $0 != 0 }.count - 1))
        }
        XCTAssertGreaterThan(improved, 0, "묶음 탐색이 한 번도 줄이지 못하면 탐색이 동작하지 않는 것이다")
    }

    func testEvenSplitGivesLeftoverWonToThePayerFirst() {
        XCTAssertEqual(LedgerSplit.even(10_000, among: ["나", "A", "B"], payer: "나"), [3_334, 3_333, 3_333])
        XCTAssertEqual(LedgerSplit.even(10_000, among: ["나", "A", "B"], payer: "B"), [3_333, 3_333, 3_334])
        XCTAssertEqual(LedgerSplit.even(10_001, among: ["나", "A", "B"], payer: "C"), [3_334, 3_334, 3_333], "낸 사람이 없으면 목록 순서")
        var generator = SeededGenerator(state: 0xC0FFEE)
        for _ in 0..<200 {
            let people = (0..<Int.random(in: 1...9, using: &generator)).map { "P\($0)" }
            let total = Int.random(in: 0...1_000_000, using: &generator)
            let shares = LedgerSplit.even(total, among: people, payer: people.randomElement(using: &generator)!)
            XCTAssertEqual(shares.reduce(0, +), total)
            XCTAssertLessThanOrEqual((shares.max() ?? 0) - (shares.min() ?? 0), 1)
        }
    }

    func testTripSheetUsesWholeWonAndBalancesSumToZero() {
        let trip = LedgerTrip(id: "t1", name: "대구", start: .distantPast, end: .distantPast, budgetKRW: nil, members: ["A", "B"])
        let entry = LedgerEntry(occurredAt: .distantPast, amount: 10_000, amountKRW: 10_000, title: "택시", tripID: "t1")
        let sheet = LedgerTripMath.sheet(trip, entries: [entry])
        XCTAssertEqual(sheet.myCost, 3_334)
        XCTAssertEqual(sheet.balances["A"], -3_333)
        XCTAssertEqual(sheet.balances["B"], -3_333)
        XCTAssertEqual(sheet.transfers.reduce(0) { $0 + $1.amountKRW }, 6_666)
        XCTAssertEqual(sheet.receivable, 6_666)

        var generator = SeededGenerator(state: 0xBEEF)
        let pool = ["A", "B", "C", "D", "E"]
        for _ in 0..<120 {
            let members = Array(pool.prefix(Int.random(in: 1...pool.count, using: &generator)))
            let trip = LedgerTrip(id: "t1", name: "여행", start: .distantPast, end: .distantPast, budgetKRW: nil, members: members)
            let everyone = trip.everyone
            let entries = (0..<Int.random(in: 1...12, using: &generator)).map { _ -> LedgerEntry in
                let amount = Double(Int.random(in: 1...200_000, using: &generator)) + (Bool.random(using: &generator) ? 0.5 : 0)
                var entry = LedgerEntry(occurredAt: .distantPast, amount: amount, amountKRW: amount, title: "지출",
                                        payer: everyone.randomElement(using: &generator), tripID: "t1")
                let share = everyone.filter { _ in Bool.random(using: &generator) }
                entry.shareNames = Bool.random(using: &generator) ? nil : share
                return entry
            }
            let sheet = LedgerTripMath.sheet(trip, entries: entries)
            XCTAssertEqual(sheet.balances.values.reduce(0, +), 0)
            XCTAssertTrue(sheet.balances.values.allSatisfy { $0 == $0.rounded() }, "잔액은 원 단위")
            var left = sheet.balances
            for transfer in sheet.transfers {
                left[transfer.from, default: 0] += transfer.amountKRW
                left[transfer.to, default: 0] -= transfer.amountKRW
            }
            XCTAssertTrue(left.values.allSatisfy { $0 == 0 }, "송금하면 모두 0원")
        }
    }

    func testDailySettlementIsDeterministicForEqualDebts() {
        let entries = [LedgerEntry(occurredAt: .distantPast, amount: 30_000, amountKRW: 30_000, title: "저녁")]
        let first = LedgerSettlement.transfers(entries, people: ["지영", "민수"], me: "나")
        XCTAssertEqual(first.map(\.from), ["민수", "지영"])
        XCTAssertEqual(first.map(\.amountKRW), [10_000, 10_000])
        for _ in 0..<20 { XCTAssertEqual(LedgerSettlement.transfers(entries, people: ["지영", "민수"], me: "나"), first) }
    }
}

/// LDS1111A01: 가계부 기록 읽기 안전망. 빌드 316이 쓴 모양, 키가 빠진 기록, 모르는 값, 모든 칸 왕복, 읽기 실패 개수.
final class LedgerDecodeSafetyTests: XCTestCase {
    private let id = "6F9C1C2E-3B7A-4F7E-9C11-2A1D5B6E7F80"

    private func decode<Value: Decodable>(_ json: String, as type: Value.Type) -> Value? {
        try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func keyCount(_ data: Data) throws -> Int {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).count
    }

    func testReadsAnEntryWrittenByBuild316() throws {
        let json = """
        {"id":"\(id)","occurredAt":800000000,"amount":12000,"currency":"KRW","amountKRW":12000,"kind":"expense","category":"food",\
        "title":"점심","place":"강남","payer":"민수","tripID":"t1","source":"message","createdAt":800000100,\
        "shareNames":["@me","민수"],"transfer":{"kind":"funding","tripID":"t1"}}
        """
        let entry = try XCTUnwrap(decode(json, as: LedgerEntry.self))
        XCTAssertEqual(entry.id.uuidString, id)
        XCTAssertEqual(entry.occurredAt, Date(timeIntervalSinceReferenceDate: 800_000_000))
        XCTAssertEqual(entry.amountKRW, 12_000)
        XCTAssertEqual(entry.category, .food)
        XCTAssertEqual(entry.title, "점심")
        XCTAssertEqual(entry.payer, "민수")
        XCTAssertEqual(entry.source, .message)
        XCTAssertEqual(entry.createdAt, Date(timeIntervalSinceReferenceDate: 800_000_100))
        XCTAssertEqual(entry.shareNames, [LedgerTrip.me, "민수"])
        XCTAssertEqual(entry.transfer, LedgerTransfer(kind: .funding, tripID: "t1"))
        XCTAssertNil(entry.canceledAt)
    }

    func testMissingKeysGetDefaultsInsteadOfDroppingTheEntry() throws {
        let entry = try XCTUnwrap(decode(#"{"id":"\#(id)","occurredAt":800000000,"amount":5000}"#, as: LedgerEntry.self))
        XCTAssertEqual(entry.currency, "KRW")
        XCTAssertNil(entry.amountKRW)
        XCTAssertEqual(entry.kind, .expense)
        XCTAssertEqual(entry.category, .other)
        XCTAssertEqual(entry.title, "")
        XCTAssertEqual(entry.source, .manual)
        XCTAssertEqual(entry.createdAt, entry.occurredAt, "만든 시각이 없으면 쓴 시각(읽을 때마다 바뀌지 않게)")
        XCTAssertNil(decode(#"{"id":"\#(id)","amount":5000}"#, as: LedgerEntry.self), "시각이 없으면 읽지 않는다")
        XCTAssertNil(decode(#"{"occurredAt":800000000,"amount":5000}"#, as: LedgerEntry.self), "id가 없으면 읽지 않는다")
    }

    func testUnknownCategoryAndSourceAreReplacedButUnknownMoneyDirectionIsNotRead() throws {
        let base = #""id":"\#(id)","occurredAt":800000000,"amount":5000"#
        let entry = try XCTUnwrap(decode("{\(base),\"category\":\"pet\",\"source\":\"bank\"}", as: LedgerEntry.self))
        XCTAssertEqual(entry.category, .other)
        XCTAssertEqual(entry.source, .manual)
        XCTAssertNil(decode("{\(base),\"kind\":\"refund\"}", as: LedgerEntry.self), "지출/수입을 모르면 잘못 세지 않게 읽지 않는다")
        XCTAssertNil(decode("{\(base),\"transfer\":{\"kind\":\"loan\",\"tripID\":\"t1\"}}", as: LedgerEntry.self), "이체 종류를 모르면 읽지 않는다")
    }

    func testEveryFieldSurvivesARoundTrip() throws {
        var entry = LedgerEntry(occurredAt: Date(timeIntervalSinceReferenceDate: 800_000_000), amount: 15.5, currency: "USD", amountKRW: 21_000,
                                kind: .income, category: .travel, title: "환불", place: "JFK", payer: "A", tripID: "t1",
                                memoID: UUID(), note: "메모", source: .receipt, createdAt: Date(timeIntervalSinceReferenceDate: 800_000_050))
        entry.shareNames = [LedgerTrip.me, "A"]
        entry.transfer = LedgerTransfer(kind: .settlement, tripID: "t1")
        entry.canceledAt = Date(timeIntervalSinceReferenceDate: 800_000_200)
        let data = try JSONEncoder().encode(entry)
        XCTAssertEqual(try keyCount(data), Mirror(reflecting: entry).children.count, "새 칸이 생겼으면 이 시험 기록에도 채우고 디코더에도 더한다")
        XCTAssertEqual(try JSONDecoder().decode(LedgerEntry.self, from: data), entry)

        let trip = LedgerTrip(id: "t1", name: "오사카", start: Date(timeIntervalSinceReferenceDate: 800_000_000), end: Date(timeIntervalSinceReferenceDate: 800_259_200),
                              budgetKRW: 500_000, members: ["A", "B"], fundingDate: Date(timeIntervalSinceReferenceDate: 799_990_000),
                              settlementKRW: -20_000, settlementDate: Date(timeIntervalSinceReferenceDate: 800_300_000))
        let tripData = try JSONEncoder().encode(trip)
        XCTAssertEqual(try keyCount(tripData), Mirror(reflecting: trip).children.count, "새 칸이 생겼으면 이 시험 여행에도 채우고 디코더에도 더한다")
        XCTAssertEqual(try JSONDecoder().decode(LedgerTrip.self, from: tripData), trip)
    }

    func testTripWithoutMembersAndBudgetWithUnknownCategory() throws {
        let trip = try XCTUnwrap(decode(#"{"id":"t1","name":"대구","start":800000000,"end":800086400}"#, as: LedgerTrip.self))
        XCTAssertEqual(trip.members, [])
        XCTAssertNil(trip.budgetKRW)
        XCTAssertEqual(decode(#"{"period":"2026-11","amountKRW":300000}"#, as: LedgerBudget.self)?.id, "2026-11|all")
        XCTAssertNil(decode(#"{"period":"2026-11","category":"pet","amountKRW":300000}"#, as: LedgerBudget.self),
                     "모르는 분류 예산을 기타 예산으로 바꾸면 id가 달라져 다른 예산을 덮는다")
    }

    func testUnreadableRowsAreCountedAndTheRestStillLoad() {
        let good = #"{"id":"\#(id)","occurredAt":800000000,"amount":5000}"#
        let unknownKind = #"{"id":"\#(UUID().uuidString)","occurredAt":800000000,"amount":5000,"kind":"refund"}"#
        let result = LedgerBook.decodeRows([good, "{broken", unknownKind], as: LedgerEntry.self)
        XCTAssertEqual(result.values.map(\.id.uuidString), [id])
        XCTAssertEqual(result.failed, 2)
    }
}

/// 버스·지하철 요금 자동 넣기(TRF1113A01). 요금은 앱에 든 요금표(수도권 2026) 기준이다.
@MainActor
final class LedgerTransitFareTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_794_000_000)
    private var calculator: FareCalculator { FareCalculator.bundled! }

    private func ride(_ mode: TravelMode, _ startMinute: Double, _ minutes: Double, km: Double) -> LedgerTransitFare.Ride {
        let start = base.addingTimeInterval(startMinute * 60)
        return .init(mode: mode, start: start, end: start.addingTimeInterval(minutes * 60), meters: km * 1_000)
    }

    private func additions(_ rides: [LedgerTransitFare.Ride], existing: [LedgerEntry] = [], handled: Set<String> = []) -> [LedgerTransitFare.Addition] {
        LedgerTransitFare.additions(rides: rides, region: "수도권", existing: existing, handled: handled, calculator: calculator, language: .korean)
    }

    func testOneBusRideIsTheAdultBusFare() {
        let result = additions([ride(.bus, 0, 25, km: 8)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.entry.amount, 1_500)
        XCTAssertEqual(result.first?.entry.title, "버스 요금")
        XCTAssertEqual(result.first?.entry.category, .transport)
        XCTAssertEqual(result.first?.entry.occurredAt, base)
        XCTAssertEqual(result.first?.suspicious, false)
    }

    func testBusThenSubwayWithinTransferTimeIsOneTripWithDistanceFare() {
        let result = additions([ride(.bus, 0, 15, km: 6), ride(.subway, 20, 25, km: 14)])
        XCTAssertEqual(result.count, 1, "환승은 한 건")
        XCTAssertEqual(result.first?.entry.title, "대중교통 요금")
        // 지하철 기본 1,550원 + 20km는 10km 넘는 10km에 5km마다 100원 = 1,750원.
        XCTAssertEqual(result.first?.entry.amount, 1_750)
    }

    func testAlreadyPaidOrHandledTripIsNotAddedAgain() {
        var paid = LedgerEntry(occurredAt: base.addingTimeInterval(10 * 60), amount: 1_500, title: "인천e음 교통")
        paid.category = .transport
        XCTAssertTrue(additions([ride(.bus, 0, 25, km: 8)], existing: [paid]).isEmpty)
        XCTAssertTrue(additions([ride(.bus, 0, 25, km: 8)], handled: [LedgerTransitFare.key(base)]).isEmpty)
        var food = paid
        food.category = .food
        XCTAssertEqual(additions([ride(.bus, 0, 25, km: 8)], existing: [food]).count, 1, "교통비가 아닌 지출은 상관없다")
    }

    func testLongBusRideAsksForReview() {
        XCTAssertEqual(additions([ride(.bus, 0, 70, km: 45)]).first?.suspicious, true)
    }

    func testShortRidesAndOtherModesAreIgnored() {
        func segment(_ mode: TravelMode, minutes: Double) -> TravelSegment {
            TravelSegment(id: UUID(), fromPlaceID: nil, toPlaceID: nil, mode: mode,
                          span: TimeSpan(start: base, end: base.addingTimeInterval(minutes * 60)), distanceMeters: 3_000,
                          confidence: .high, evidence: [], isConfirmed: false)
        }
        let rides = LedgerTransitFare.rides([segment(.bus, minutes: 2), segment(.car, minutes: 30), segment(.subway, minutes: 12)])
        XCTAssertEqual(rides.map(\.mode), [.subway])
    }
}

/// 내 차가 아닌 차량 이동을 버스로 보기(TRF1113A01). 좌표는 꾸민 것(위도 1도 ≈ 111km 직선 길).
final class BusRideRecognizerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_794_000_000)

    /// 초 단위 (움직임 m/s, 걸린 초) 조각으로 GPS 점을 만든다.
    private func track(_ legs: [(speed: Double, seconds: Int)], car: String? = nil) -> [SensorReading] {
        var readings: [SensorReading] = []
        var meters = 0.0, t = 0
        for leg in legs {
            for _ in stride(from: 0, to: leg.seconds, by: 5) {
                let point = GeoPoint(latitude: 37.5 + meters / 111_000, longitude: 126.7, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
                readings.append(SensorReading(timestamp: base.addingTimeInterval(TimeInterval(t)), point: point, motion: .automotive,
                                              motionConfidence: .high, carAudioRouteName: car))
                meters += leg.speed * 5
                t += 5
            }
        }
        return readings
    }

    /// 버스: 1분 남짓 달리고 20~40초씩 서기를 열 번.
    private var busLegs: [(speed: Double, seconds: Int)] {
        (0..<10).flatMap { index in [(speed: 9.0, seconds: 60), (speed: 0.0, seconds: index % 2 == 0 ? 20 : 40)] }
    }

    /// 자가용: 길게 달리고 신호에서 90~150초씩 서기를 세 번.
    private var carLegs: [(speed: Double, seconds: Int)] {
        [(14, 300), (0, 120), (14, 300), (0, 90), (14, 240), (0, 150), (14, 120)]
    }

    private func segment(_ readings: [SensorReading], evidence: [String] = []) -> TravelSegment {
        TravelSegment(mode: .car, span: TimeSpan(start: readings.first!.timestamp, end: readings.last!.timestamp),
                      distanceMeters: 0, confidence: .high, evidence: evidence)
    }

    func testStopAndGoWithoutMyCarBecomesBus() {
        let readings = track(busLegs)
        let stops = BusRideRecognizer.stops(in: readings)
        XCTAssertGreaterThanOrEqual(stops.short, 8)
        XCTAssertEqual(stops.long, 0)
        let result = BusRideRecognizer.applying([segment(readings)], readings: readings, registered: ["내 차"], corrections: [], stopDefaults: UserDefaults(suiteName: "BusRideRecognizerTests")!)
        XCTAssertEqual(result.first?.mode, .bus)
        XCTAssertEqual(result.first?.confidence, .medium)
        XCTAssertGreaterThan(result.first?.distanceMeters ?? 0, 4_000, "거리가 없던 구간은 GPS 거리로 채운다")
        XCTAssertTrue(result.first?.evidence.contains { $0.hasPrefix(BusRideRecognizer.evidencePrefix) } == true)
    }

    func testStopAndGoBetweenBusStopsIsASureBus() {
        let readings = track(busLegs)
        let ride = segment(readings)
        let defaults = UserDefaults(suiteName: "BusRideRecognizerStops")!
        defaults.removePersistentDomain(forName: "BusRideRecognizerStops")
        BusStopCheck.remember(.board, segment: ride, isStop: true, defaults: defaults)
        BusStopCheck.remember(.alight, segment: ride, isStop: true, defaults: defaults)
        let result = BusRideRecognizer.applying([ride], readings: readings, registered: ["내 차"], corrections: [], stopDefaults: defaults)
        XCTAssertEqual(result.first?.mode, .bus)
        XCTAssertEqual(result.first?.confidence, .high)
        XCTAssertTrue(result.first?.evidence.contains(BusRideRecognizer.stopEvidence) == true)
    }

    func testLongTrafficLightStopsStayCar() {
        let readings = track(carLegs)
        XCTAssertFalse(BusRideRecognizer.looksLikeBus(BusRideRecognizer.stops(in: readings)))
        XCTAssertEqual(BusRideRecognizer.applying([segment(readings)], readings: readings, registered: ["내 차"], corrections: [], stopDefaults: UserDefaults(suiteName: "BusRideRecognizerTests")!).first?.mode, .car)
    }

    func testMyCarConnectionUserChoiceOrNoRegisteredCarKeepsCar() {
        let connected = track(busLegs, car: "내 차")
        XCTAssertEqual(BusRideRecognizer.applying([segment(connected)], readings: connected, registered: ["내 차"], corrections: [], stopDefaults: UserDefaults(suiteName: "BusRideRecognizerTests")!).first?.mode, .car)
        let readings = track(busLegs)
        XCTAssertEqual(BusRideRecognizer.applying([segment(readings)], readings: readings, registered: [], corrections: [], stopDefaults: UserDefaults(suiteName: "BusRideRecognizerTests")!).first?.mode, .car,
                       "등록한 차가 없으면 남의 차인지 알 수 없다")
        XCTAssertEqual(BusRideRecognizer.applying([segment(readings, evidence: ["사용자 확인 · 자동차"])], readings: readings, registered: ["내 차"], corrections: [], stopDefaults: UserDefaults(suiteName: "BusRideRecognizerTests")!).first?.mode, .car)
        let span = segment(readings).span
        let correction = TravelModeCorrection(span: span, mode: .car, inferredMode: .car, inferredConfidence: .high)
        XCTAssertEqual(BusRideRecognizer.applying([segment(readings)], readings: readings, registered: ["내 차"], corrections: [correction], stopDefaults: UserDefaults(suiteName: "BusRideRecognizerTests")!).first?.mode, .car)
    }
}

/// 승하차 지점 버스정류장 확인(BST1113A01). 지도 타일은 시험에서 직접 만든 것.
final class BusStopCheckTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_794_000_000)
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "BusStopCheckTests")
        defaults.removePersistentDomain(forName: "BusStopCheckTests")
    }

    private func point(_ meters: Double) -> GeoPoint {
        GeoPoint(latitude: 37.5 + meters / 111_000, longitude: 126.7, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
    }

    /// 일정한 속도로 서지 않고 달린 길(정차 모양만으로는 버스가 아님).
    private func straight() -> [SensorReading] {
        (0..<120).map { index in
            SensorReading(timestamp: base.addingTimeInterval(TimeInterval(index * 5)), point: point(Double(index) * 60), motion: .automotive, motionConfidence: .high)
        }
    }

    private func segment(_ readings: [SensorReading]) -> TravelSegment {
        TravelSegment(mode: .car, span: TimeSpan(start: readings.first!.timestamp, end: readings.last!.timestamp),
                      distanceMeters: 0, confidence: .high, evidence: [])
    }

    // MARK: 벡터 타일 만들기

    private func varint(_ value: UInt64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }
    private func field(_ number: Int, _ bytes: [UInt8]) -> [UInt8] { varint(UInt64(number << 3 | 2)) + varint(UInt64(bytes.count)) + bytes }
    private func text(_ number: Int, _ value: String) -> [UInt8] { field(number, Array(value.utf8)) }
    private func zigzag(_ value: Int64) -> UInt64 { UInt64(bitPattern: (value << 1) ^ (value >> 63)) }

    /// poi 층: 가운데 정류장 하나와 카페 하나.
    private func tile() -> Data {
        func feature(subclassValue: UInt64, x: Int64, y: Int64) -> [UInt8] {
            field(2, ([0, 0, 1, subclassValue] as [UInt64]).flatMap { varint($0) }) + field(4, [9, zigzag(x), zigzag(y)].flatMap { varint($0) })
        }
        let layer = text(1, "poi") + field(2, feature(subclassValue: 1, x: 2_048, y: 2_048)) + field(2, feature(subclassValue: 2, x: 100, y: 100))
            + text(3, "class") + text(3, "subclass") + field(4, text(1, "bus")) + field(4, text(1, "bus_stop")) + field(4, text(1, "cafe"))
            + varint(UInt64(5 << 3)) + varint(4_096)
        return Data(field(3, layer))
    }

    func testBusStopsAreReadFromTheVectorTilePoiLayer() {
        let id = BusStopCheck.TileID(x: 13_960, y: 6_340)
        let stops = BusStopCheck.busStops(inTile: tile(), id: id)
        XCTAssertEqual(stops.count, 1, "카페는 정류장이 아니다")
        let back = BusStopCheck.tile(stops[0])
        XCTAssertEqual(back, id, "타일 가운데 점은 같은 타일로 돌아온다")
        XCTAssertTrue(BusStopCheck.busStops(inTile: Data([1, 2, 3]), id: id).isEmpty)
    }

    func testOnlyPointsWithinThirtyMetersCount() {
        XCTAssertTrue(BusStopCheck.isNearStop([point(0)], stops: [point(20)]))
        XCTAssertFalse(BusStopCheck.isNearStop([point(0)], stops: [point(91)]), "집에서 91m인 정류장은 아니다")
    }

    func testBoardWindowLooksAtTheWaitBeforeTheRide() {
        let readings = straight()
        let ride = TravelSegment(mode: .car, span: TimeSpan(start: readings[60].timestamp, end: readings[100].timestamp),
                                 distanceMeters: 0, confidence: .high, evidence: [])
        XCTAssertEqual(BusStopCheck.points(.board, segment: ride, readings: readings).count, 49, "3분 전~1분 뒤")
        XCTAssertEqual(BusStopCheck.points(.alight, segment: ride, readings: readings).count, 32, "1분 전~2분 뒤")
    }

    /// 정류장 가까운 두 곳을 차로 곧장 간 것은 차다(BRF1113A01, 대표 신고: 세컨카 레이로 950m·5분이 버스로).
    func testBothEndsAtBusStopsWithoutStopAndGoStayCar() {
        let readings = straight()
        let ride = segment(readings)
        BusStopCheck.remember(.board, segment: ride, isStop: true, defaults: defaults)
        BusStopCheck.remember(.alight, segment: ride, isStop: true, defaults: defaults)
        let result = BusRideRecognizer.applying([ride], readings: readings, registered: ["내 차"], corrections: [], stopDefaults: defaults)
        XCTAssertEqual(result.first?.mode, .car)
    }

    func testNoBusStopAtEitherEndKeepsCar() {
        let readings = straight()
        let ride = segment(readings)
        BusStopCheck.remember(.board, segment: ride, isStop: false, defaults: defaults)
        BusStopCheck.remember(.alight, segment: ride, isStop: false, defaults: defaults)
        XCTAssertEqual(BusRideRecognizer.applying([ride], readings: readings, registered: ["내 차"], corrections: [], stopDefaults: defaults).first?.mode, .car)
    }

    func testWithoutARegisteredCarStopsAloneAreNotEnough() {
        let readings = straight()
        let ride = segment(readings)
        BusStopCheck.remember(.board, segment: ride, isStop: true, defaults: defaults)
        BusStopCheck.remember(.alight, segment: ride, isStop: true, defaults: defaults)
        XCTAssertEqual(BusRideRecognizer.applying([ride], readings: readings, registered: [], corrections: [], stopDefaults: defaults).first?.mode, .car,
                       "등록한 차가 없으면 정차 모양까지 맞아야 한다")
    }
}

/// 버스 구간의 잠긴 「자동차」 기록 이름 맞추기(BST1113A01, 330 대표 신고).
final class BusRecordRetitleTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_794_000_000)

    private func record(_ title: String, behavior: String?, manual: Bool = false, minutes: Double = 15) -> ActualRecord {
        ActualRecord(planID: nil, title: title, categoryID: "movement", startedAt: base, endedAt: base.addingTimeInterval(minutes * 60),
                     source: .motion, behavior: behavior, modelVersion: "classifier-v1/motion", manuallyCorrected: manual,
                     isClassificationLocked: true, lockReason: .stability)
    }

    func testLockedCarRecordOverABusRideBecomesBus() {
        let span = TimeSpan(start: base, end: base.addingTimeInterval(15 * 60))
        let result = BusRideRecognizer.retitling([record("자동차", behavior: "automotive")], busSpans: [span], asOf: base.addingTimeInterval(3_600))
        XCTAssertEqual(result.first?.title, "버스")
        XCTAssertEqual(MovementPresentation.mode(for: result[0]), .bus)
    }

    func testShortCarSliverJustBeforeTheBusAlsoBecomesBus() {
        let bus = TimeSpan(start: base.addingTimeInterval(60), end: base.addingTimeInterval(16 * 60))
        let sliver = ActualRecord(planID: nil, title: "자동차", categoryID: "movement", startedAt: base, endedAt: base.addingTimeInterval(19),
                                  source: .motion, behavior: "automotive", modelVersion: "classifier-v1/gap", isClassificationLocked: true, lockReason: .stability)
        XCTAssertEqual(BusRideRecognizer.retitling([sliver], busSpans: [bus], asOf: base.addingTimeInterval(3_600)).first?.title, "버스")
    }

    func testUserFixedRecordsAndOtherTimesStay() {
        let span = TimeSpan(start: base, end: base.addingTimeInterval(15 * 60))
        XCTAssertEqual(BusRideRecognizer.retitling([record("자동차", behavior: "automotive", manual: true)], busSpans: [span], asOf: base).first?.title, "자동차")
        let later = TimeSpan(start: base.addingTimeInterval(7_200), end: base.addingTimeInterval(8_000))
        XCTAssertEqual(BusRideRecognizer.retitling([record("자동차", behavior: "automotive")], busSpans: [later], asOf: base).first?.title, "자동차")
        XCTAssertEqual(BusRideRecognizer.retitling([record("걷기", behavior: "walking")], busSpans: [span], asOf: base).first?.title, "걷기")
    }
}

/// 할 일 목록 패널(TDP1113A01): 탭 순서, 「전체」 섞기 순서, 「일정」의 앱 계획.
final class TodoPanelTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_794_000_000)

    func testTabsPutCheckAndScheduleRightAfterAll() {
        XCTAssertEqual(LedgerMemoFilter.allCases, [.today, .check, .schedule, .memos, .inbox, .ai])
        XCTAssertEqual(LedgerMemoFilter.inbox.title(.korean), "내역")
        XCTAssertEqual(LedgerMemoFilter.today.title(.korean), "지출")
        XCTAssertEqual(LedgerMemoFilter.check.title(.korean), "확인")
        XCTAssertEqual(LedgerMemoFilter.schedule.title(.korean), "일정")
    }

    func testAllTabPutsUntimedFirstThenTime() {
        let timeless = ActionMemo(occurredAt: day.addingTimeInterval(5 * 3600), isTimeless: true, kind: .idea, text: "시각 없음", createdAt: day.addingTimeInterval(5 * 3600))
        let lateMemo = ActionMemo(occurredAt: day.addingTimeInterval(3 * 3600), kind: .idea, text: "세 시")
        let allDay = CalendarRecord(id: "a", calendarID: "c", title: "종일", span: TimeSpan(start: day, end: day.addingTimeInterval(86_400)), isAllDay: true, calendarTitle: "c")
        let event = CalendarRecord(id: "e", calendarID: "c", title: "한 시", span: TimeSpan(start: day.addingTimeInterval(3600), end: day.addingTimeInterval(7200)), isAllDay: false, calendarTitle: "c")
        let plan = PlanRecord(title: "두 시", span: TimeSpan(start: day.addingTimeInterval(2 * 3600), end: day.addingTimeInterval(3 * 3600)), categoryID: "work")
        let rows = MapHomeTodoPanelRow.ordered([.memo(lateMemo), .plan(plan), .event(event), .memo(timeless), .event(allDay)])
        XCTAssertEqual(rows.map(\.id), [
            "event-a", "memo-\(timeless.id.uuidString)", "event-e", "plan-\(plan.id.uuidString)", "memo-\(lateMemo.id.uuidString)",
        ])
    }

    func testScheduleKeepsOnlyThatDaysOwnPlans() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let start = calendar.startOfDay(for: day)
        let mine = PlanRecord(title: "운동", span: TimeSpan(start: start.addingTimeInterval(9 * 3600), end: start.addingTimeInterval(10 * 3600)), categoryID: "health")
        let fromCalendar = PlanRecord(title: "회의", span: mine.span, categoryID: "work", externalEventID: "ev")
        let otherDay = PlanRecord(title: "내일", span: TimeSpan(start: start.addingTimeInterval(30 * 3600), end: start.addingTimeInterval(31 * 3600)), categoryID: "work")
        XCTAssertEqual(MapHomeTodoPanelRow.plans([otherDay, fromCalendar, mine], on: day, calendar: calendar).map(\.title), ["운동"])
    }
}

/// 같은 날 기록 묶기(LGP1113A01: 한 번에 묶도록 바꾼 뒤에도 순서·묶음이 같다).
final class LedgerDayGroupingTests: XCTestCase {
    func testGroupsKeepDaysAndTimeOrder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 9))!
        let entries = [
            LedgerEntry(occurredAt: day.addingTimeInterval(86_400), amount: 3, title: "내일"),
            LedgerEntry(occurredAt: day.addingTimeInterval(3600), amount: 2, title: "열 시"),
            LedgerEntry(occurredAt: day, amount: 1, title: "아홉 시"),
        ]
        let groups = LedgerDayGroup.groups(entries, calendar: calendar)
        XCTAssertEqual(groups.map { $0.entries.map(\.title) }, [["아홉 시", "열 시"], ["내일"]])
        XCTAssertEqual(groups.first?.day, calendar.startOfDay(for: day))
        XCTAssertTrue(LedgerDayGroup.groups([], calendar: calendar).isEmpty)
    }
}

/// 「머무름」 기록에 찾은 장소 이름(KKP1113A01, 대표 신고: 식당이 「머무름」·건물 이름으로).
@MainActor
final class StayPlaceNamingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_794_000_000)
    private let point = GeoPoint(latitude: 37.5, longitude: 126.67, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)

    private func stay(minutes: Double, manual: Bool = false) -> ActualRecord {
        ActualRecord(planID: nil, title: StationaryContextKind.unknownStay.title, categoryID: "activity", startedAt: base,
                     endedAt: base.addingTimeInterval(minutes * 60), source: .location, behavior: StationaryContextKind.unknownStay.rawValue,
                     modelVersion: "classifier-v1/context", manuallyCorrected: manual)
    }

    private var place: PlaceStay {
        PlaceStay(placeKey: "p", displayName: "확인된 위치", span: TimeSpan(start: base, end: base.addingTimeInterval(90 * 60)),
                  confidence: .medium, point: point, isConfirmed: false)
    }

    func testUnknownStayTakesTheFoundNameAndUserEditsStay() {
        let names = [NLEPlaceLane.nameKey(for: point): "뷔페 식당"]
        let named = StayPlaceNaming.retitling([stay(minutes: 90)], places: [place], names: names, asOf: base.addingTimeInterval(7_200))
        XCTAssertEqual(named.first?.title, "뷔페 식당")
        XCTAssertTrue(named.first?.evidence.contains(StayPlaceNaming.evidence) == true)
        XCTAssertEqual(StayPlaceNaming.retitling([stay(minutes: 90, manual: true)], places: [place], names: names, asOf: base.addingTimeInterval(7_200)).first?.title,
                       StationaryContextKind.unknownStay.title, "사용자가 고친 기록은 그대로")
        XCTAssertEqual(StayPlaceNaming.retitling([stay(minutes: 5)], places: [place], names: names, asOf: base.addingTimeInterval(7_200)).first?.title,
                       StationaryContextKind.unknownStay.title, "잠깐 선 곳은 이름을 붙이지 않는다")
        XCTAssertTrue(StayPlaceNaming.pointsNeedingNames([stay(minutes: 90)], places: [place], known: names, asOf: base.addingTimeInterval(7_200)).isEmpty)
        XCTAssertEqual(StayPlaceNaming.pointsNeedingNames([stay(minutes: 90)], places: [place], known: [:], asOf: base.addingTimeInterval(7_200)).count, 1)
    }
}

/// 버스 노선 확인(BRT1113A01): TAGO 응답 읽기, 공통 노선, 이름·요금·판별.
final class BusRouteCheckTests: XCTestCase {
    func testReadsTagoItemsWhetherOneOrMany() {
        let many = Data(#"{"response":{"body":{"items":{"item":[{"citycode":23,"nodeid":"ICB164000123","nodenm":"정류소","gpslati":37.53,"gpslong":126.67},{"citycode":"23","nodeid":"ICB164000124","gpslati":"37.5302","gpslong":"126.6701"}]}}}}"#.utf8)
        XCTAssertEqual(BusRouteCheck.stops(many).map(\.nodeID), ["ICB164000123", "ICB164000124"])
        let one = Data(#"{"response":{"body":{"items":{"item":{"routeno":80,"routetp":"간선버스"}}}}}"#.utf8)
        XCTAssertEqual(BusRouteCheck.routes(one), [.init(number: "80", kind: "간선버스")])
        XCTAssertTrue(BusRouteCheck.routes(Data(#"{"response":{"body":{"items":""}}}"#.utf8)).isEmpty)
    }

    func testSeoulStationsAndErrorResponses() {
        let stops = Data(#"{"msgHeader":{"headerCd":"0"},"msgBody":{"itemList":[{"arsId":"01234","stationNm":"시청","gpsX":"126.97","gpsY":"37.56"},{"arsId":"0","gpsX":"126.9","gpsY":"37.5"}]}}"#.utf8)
        XCTAssertTrue(BusRouteCheck.isValid(stops, seoul: true))
        XCTAssertEqual(BusRouteCheck.seoulStops(stops).map(\.nodeID), ["01234"])
        let routes = Data(#"{"msgHeader":{"headerCd":"0"},"msgBody":{"itemList":{"busRouteNm":"9401","busRouteType":"6"}}}"#.utf8)
        XCTAssertEqual(BusRouteCheck.seoulRoutes(routes), [.init(number: "9401", kind: "광역버스")])
        XCTAssertTrue(BusRouteCheck.isValid(Data(#"{"msgHeader":{"headerCd":"4"},"msgBody":{"itemList":null}}"#.utf8), seoul: true), "결과 없음은 정상")
        XCTAssertFalse(BusRouteCheck.isValid(Data(#"{"msgHeader":{"headerCd":"7","headerMsg":"인증 실패"}}"#.utf8), seoul: true))
        XCTAssertTrue(BusRouteCheck.isValid(Data(#"{"response":{"header":{"resultCode":"00"},"body":{"items":""}}}"#.utf8), seoul: false))
        XCTAssertFalse(BusRouteCheck.isValid(Data("<OpenAPI_ServiceResponse>SERVICE_KEY_IS_NOT_REGISTERED_ERROR</OpenAPI_ServiceResponse>".utf8), seoul: false),
                       "등록 안 된 키 오류를 「정류장 없음」으로 믿지 않는다")
    }

    func testCommonRoutesNameAndFare() {
        let board: [BusRouteCheck.Route] = [.init(number: "80", kind: "간선버스"), .init(number: "1100", kind: "광역버스")]
        let alight: [BusRouteCheck.Route] = [.init(number: "80", kind: "간선버스"), .init(number: "42", kind: "지선버스")]
        let common = BusRouteCheck.common(board, alight)
        XCTAssertEqual(common.map(\.number), ["80"])
        XCTAssertEqual(BusRouteCheck.title(common), "버스 · 80번")
        XCTAssertEqual(BusRouteCheck.title([]), "버스")
        XCTAssertEqual(BusRouteCheck.fareMode(common), "서울_간선지선")
        XCTAssertEqual(BusRouteCheck.fareMode([.init(number: "1100", kind: "광역버스")]), "서울_광역")
        XCTAssertEqual(BusRouteCheck.fareMode([.init(number: "9100", kind: "직행좌석버스")]), "경기_직행좌석")
    }

    func testNoCommonRouteVetoesABusAndKnownRouteNamesTheRecord() {
        let base = Date(timeIntervalSince1970: 1_794_000_000)
        var readings: [SensorReading] = []
        var meters = 0.0
        for index in 0..<200 {
            let moving = (index % 16) < 12
            let point = GeoPoint(latitude: 37.5 + meters / 111_000, longitude: 126.7, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
            readings.append(SensorReading(timestamp: base.addingTimeInterval(TimeInterval(index * 5)), point: point, motion: .automotive, motionConfidence: .high))
            if moving { meters += 45 }
        }
        let ride = TravelSegment(mode: .car, span: TimeSpan(start: readings.first!.timestamp, end: readings.last!.timestamp), distanceMeters: 0, confidence: .high, evidence: [])
        XCTAssertTrue(BusRideRecognizer.looksLikeBus(BusRideRecognizer.stops(in: readings)))
        let defaults = UserDefaults(suiteName: "BusRouteCheckTests")!
        defaults.removePersistentDomain(forName: "BusRouteCheckTests")
        BusRouteCheck.remember(ride, routes: [], defaults: defaults)
        XCTAssertEqual(BusRideRecognizer.applying([ride], readings: readings, registered: ["내 차"], corrections: [], stopDefaults: defaults).first?.mode, .car,
                       "두 정류소를 함께 지나는 노선이 없으면 버스가 아니다")
        BusRouteCheck.remember(ride, routes: [.init(number: "80", kind: "간선버스")], defaults: defaults)
        let bus = BusRideRecognizer.applying([ride], readings: readings, registered: ["내 차"], corrections: [], stopDefaults: defaults).first
        XCTAssertEqual(bus?.mode, .bus)
        XCTAssertTrue(bus?.evidence.contains("노선 80") == true)
        let record = ActualRecord(planID: nil, title: "버스", categoryID: "movement", startedAt: ride.span.start, endedAt: ride.span.end, source: .motion,
                                  behavior: WatchBehaviorKind.publicTransit.rawValue, evidence: ["버스 구간 확정"], modelVersion: "classifier-v1/motion")
        XCTAssertEqual(BusRideRecognizer.retitling([record], busSpans: [ride.span], titles: ["버스 · 80번"], asOf: ride.span.end).first?.title, "버스 · 80번")
    }
}

/// 대중교통 근거 없이 버스로 잠긴 구간 되돌리기(BRV1114A01, 대표 신고: 세컨카 레이로 950m·5분이 333에서도 버스).
final class BusRevertTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_794_000_000)

    private func straight(minutes: Int) -> [SensorReading] {
        (0..<(minutes * 12)).map { index in
            SensorReading(timestamp: base.addingTimeInterval(TimeInterval(index * 5)),
                          point: GeoPoint(latitude: 37.5 + Double(index) * 0.0003, longitude: 126.7, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10),
                          motion: .automotive, motionConfidence: .high)
        }
    }

    private func bus(_ readings: [SensorReading], evidence: [String]) -> TravelSegment {
        TravelSegment(mode: .bus, span: TimeSpan(start: readings.first!.timestamp, end: readings.last!.timestamp), distanceMeters: 950, confidence: .high, evidence: evidence)
    }

    func testOldStopOnlyBusWithoutStopAndGoGoesBackToCar() {
        let readings = straight(minutes: 6)
        let defaults = UserDefaults(suiteName: "BusRevertTests")!
        defaults.removePersistentDomain(forName: "BusRevertTests")
        let old = bus(readings, evidence: ["차량 가능 속도", BusRideRecognizer.stopEvidence])
        let result = BusRideRecognizer.applying([old], readings: readings, registered: ["내 차"], corrections: [], stopDefaults: defaults).first
        XCTAssertEqual(result?.mode, .car)
        XCTAssertTrue(result?.evidence.contains(BusRideRecognizer.revertedEvidence) == true)
        XCTAssertFalse(result?.evidence.contains(BusRideRecognizer.stopEvidence) == true)
        let routed = bus(readings, evidence: ["대중교통 도로 경로 일치"])
        XCTAssertEqual(BusRideRecognizer.applying([routed], readings: readings, registered: ["내 차"], corrections: [], stopDefaults: defaults).first?.mode, .bus,
                       "다른 판정의 대중교통 근거가 있으면 그대로")
        XCTAssertEqual(BusRideRecognizer.applying([old], readings: readings, registered: [], corrections: [], stopDefaults: defaults).first?.mode, .bus,
                       "등록한 차가 없으면 건드리지 않는다")
    }

    func testRecordRenamedByTheBusRuleReturnsToCarWhenTheBusIsGone() {
        let record = ActualRecord(planID: nil, title: "버스", categoryID: "movement", startedAt: base, endedAt: base.addingTimeInterval(300), source: .motion,
                                  behavior: WatchBehaviorKind.publicTransit.rawValue, evidence: ["iPhone Core Motion", "버스 구간 확정"], modelVersion: "classifier-v1/motion")
        let back = BusRideRecognizer.retitling([record], busSpans: [], asOf: base.addingTimeInterval(600)).first
        XCTAssertEqual(back?.title, "자동차")
        XCTAssertEqual(back?.behavior, WatchBehaviorKind.automotive.rawValue)
        XCTAssertFalse(back?.evidence.contains("버스 구간 확정") == true)
    }
}

/// 머문 곳 후보에서 고르기와 식사(SPC1114A01, 대표 신고: 같은 건물 빵집 이름으로 붙음).
@MainActor
final class StayCandidateTests: XCTestCase {
    func testMealTimeLongStayPicksTheRestaurantOverABakery() {
        let list = [
            StayPlaceCandidate(name: "빵집", code: "FD6", category: "음식점 > 간식 > 제과,베이커리", meters: 8),
            StayPlaceCandidate(name: "뷔페 식당", code: "FD6", category: "음식점 > 뷔페", meters: 21),
            StayPlaceCandidate(name: "동네 카페", code: "CE7", category: "음식점 > 카페", meters: 15),
        ]
        XCTAssertEqual(StayPlaceCandidate.choose(list, mealStay: true)?.name, "뷔페 식당")
        XCTAssertEqual(StayPlaceCandidate.choose(list, mealStay: false)?.name, "빵집")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let dinner = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 18, minute: 39))!
        XCTAssertTrue(StayPlaceNaming.isMealStay(TimeSpan(start: dinner, end: dinner.addingTimeInterval(94 * 60)), calendar: calendar))
        XCTAssertFalse(StayPlaceNaming.isMealStay(TimeSpan(start: dinner, end: dinner.addingTimeInterval(20 * 60)), calendar: calendar))
    }

    func testStayRecordBecomesAMealWithCandidatesInEvidence() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 18, minute: 39))!
        let point = GeoPoint(latitude: 37.53, longitude: 126.67, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
        let stay = ActualRecord(planID: nil, title: StationaryContextKind.unknownStay.title, categoryID: "activity", startedAt: start,
                                endedAt: start.addingTimeInterval(94 * 60), source: .location, behavior: StationaryContextKind.unknownStay.rawValue,
                                modelVersion: "classifier-v1/context")
        let place = PlaceStay(placeKey: "p", displayName: "확인된 위치", span: TimeSpan(start: start, end: start.addingTimeInterval(94 * 60)),
                              confidence: .medium, point: point, isConfirmed: false)
        let key = NLEPlaceLane.nameKey(for: point)
        let candidates = [key: [
            StayPlaceCandidate(name: "빵집", code: "FD6", category: "음식점 > 간식 > 제과,베이커리", meters: 8),
            StayPlaceCandidate(name: "뷔페 식당", code: "FD6", category: "음식점 > 뷔페", meters: 21),
        ]]
        let named = StayPlaceNaming.retitling([stay], places: [place], names: [key: "빵집"], candidates: candidates,
                                              calendar: calendar, asOf: start.addingTimeInterval(7_200)).first
        XCTAssertEqual(named?.title, "식사 · 뷔페 식당")
        XCTAssertEqual(named?.categoryID, "eating")
        XCTAssertEqual(named?.behavior, "meal")
        XCTAssertTrue(named?.evidence.contains("근처 후보: 빵집·뷔페 식당") == true)
        // 이미 이름을 붙인 기록도 다시 고른다(어제 「빵집」로 붙은 것).
        var old = stay
        old.title = "빵집"
        old.evidence.append(StayPlaceNaming.evidence)
        XCTAssertEqual(StayPlaceNaming.retitling([old], places: [place], names: [:], candidates: candidates, calendar: calendar,
                                                 asOf: start.addingTimeInterval(7_200)).first?.title, "식사 · 뷔페 식당")
    }
}

/// 결제 시각으로 머문 곳·활동 확정(PAY1114A01). 가게 이름은 지어낸 것이다.
@MainActor
final class PaymentStayAnchorTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_794_000_000)
    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    private func record(_ title: String, _ behavior: String, _ from: Double, _ to: Double, source: ActualSource = .location, manual: Bool = false) -> ActualRecord {
        ActualRecord(planID: nil, title: title, categoryID: "rest", startedAt: at(from), endedAt: at(to), source: source,
                     behavior: behavior, modelVersion: "classifier-v1/context", manuallyCorrected: manual)
    }

    private func pay(_ minute: Double, _ merchant: String, _ category: LedgerCategory) -> PaymentStayAnchor.Payment {
        .init(id: UUID(), time: at(minute), merchant: merchant, category: category)
    }

    func testOutingInsideHomeRadiusIsCarvedOutOfHomeRest() {
        let home = record("집에서 휴식", StationaryContextKind.homeRest.rawValue, 0, 480)
        let walk = record("걷기", "walking", 372, 374, source: .motion)
        let payments = [pay(370, "가나의원", .other), pay(371, "가나의원", .other), pay(376, "다라약국", .health), pay(381, "마바카페", .cafe)]
        let result = PaymentStayAnchor.applying([home, walk], payments: payments, places: [], candidates: [:], asOf: at(600))
        let outings = result.filter { $0.modelVersion == PaymentStayAnchor.modelVersion }
        XCTAssertEqual(outings.map(\.title), ["병원·약국 · 가나의원", "병원·약국 · 다라약국", "카페 · 마바카페"])
        XCTAssertEqual(outings.map(\.categoryID), ["health", "health", "rest"])
        XCTAssertEqual(outings.first?.startedAt, at(355), "첫 결제 15분 전부터")
        XCTAssertEqual(outings.first?.endedAt, at(373), "같은 가게 두 번째 결제 2분 뒤까지 한 방문")
        let homes = result.filter { $0.behavior == StationaryContextKind.homeRest.rawValue }
        XCTAssertEqual(homes.count, 2)
        XCTAssertEqual(homes.first?.endedAt, at(355))
        XCTAssertEqual(homes.last?.startedAt, at(383))
        // 다시 돌려도 같다.
        XCTAssertEqual(PaymentStayAnchor.applying(result, payments: payments, places: [], candidates: [:], asOf: at(600)).count, result.count)
    }

    func testOnlinePaymentAtHomeWithoutWalkingChangesNothing() {
        let home = record("집에서 휴식", StationaryContextKind.homeRest.rawValue, 0, 480)
        let result = PaymentStayAnchor.applying([home], payments: [pay(200, "온라인몰", .shopping)], places: [], candidates: [:], asOf: at(600))
        XCTAssertEqual(result, [home])
        let edited = record("집에서 휴식", StationaryContextKind.homeRest.rawValue, 0, 480, manual: true)
        let walk = record("걷기", "walking", 201, 203, source: .motion)
        XCTAssertEqual(PaymentStayAnchor.applying([edited, walk], payments: [pay(200, "가나의원", .other)], places: [], candidates: [:], asOf: at(600)).count, 2,
                       "사용자가 고친 기록은 자르지 않는다")
    }

    func testPaymentConfirmsAnUnnamedStayOnlyWhenTheMerchantIsNearby() {
        let point = GeoPoint(latitude: 37.5, longitude: 126.7, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
        let stay = record("빵집", StationaryContextKind.unknownStay.rawValue, 0, 94)
        let place = PlaceStay(placeKey: "p", displayName: "확인된 위치", span: TimeSpan(start: at(0), end: at(94)), confidence: .medium, point: point, isConfirmed: false)
        let candidates = [NLEPlaceLane.nameKey(for: point): [
            StayPlaceCandidate(name: "빵집", code: "FD6", category: "음식점 > 간식", meters: 8),
            StayPlaceCandidate(name: "뷔페 식당 본점", code: "FD6", category: "음식점 > 뷔페", meters: 21),
        ]]
        let named = PaymentStayAnchor.applying([stay], payments: [pay(90, "뷔페 식당", .food)], places: [place], candidates: candidates, asOf: at(200)).first
        XCTAssertEqual(named?.title, "식사 · 뷔페 식당")
        XCTAssertEqual(named?.categoryID, "eating")
        XCTAssertTrue(named?.evidence.contains("결제 확인: 뷔페 식당") == true)
        XCTAssertEqual(PaymentStayAnchor.applying([stay], payments: [pay(90, "온라인몰", .shopping)], places: [place], candidates: candidates, asOf: at(200)).first?.title, "빵집",
                       "근처 후보에 없는 가게 결제는 쓰지 않는다")
        XCTAssertEqual(PaymentStayAnchor.label(pay(0, "가나정형외과의원", .other)).categoryID, "health")
    }
}

/// 문자 출처와 넣지 않을 낱말(SMS1114A01), 탈것 탑승 질문(BCF1114A01).
final class SkipWordAndRideTests: XCTestCase {
    func testSkipWordsAreTrimmedDeduplicatedAndMatched() {
        let defaults = UserDefaults(suiteName: "SkipWordAndRideTests")!
        defaults.removePersistentDomain(forName: "SkipWordAndRideTests")
        XCTAssertTrue(PaymentAlertSources.addSkipWord("  자동이체 ", defaults: defaults))
        XCTAssertFalse(PaymentAlertSources.addSkipWord("자동이체", defaults: defaults))
        XCTAssertFalse(PaymentAlertSources.addSkipWord("   ", defaults: defaults))
        XCTAssertEqual(PaymentAlertSources.skipWord(in: "[Web발신] 자동이체 출금 10,000원", defaults: defaults), "자동이체")
        XCTAssertNil(PaymentAlertSources.skipWord(in: "승인 4,500원 카페", defaults: defaults))
        PaymentAlertSources.removeSkipWord("자동이체", defaults: defaults)
        XCTAssertTrue(PaymentAlertSources.skipWords(defaults).isEmpty)
        // 문자도 한 출처로 스위치를 따른다.
        PaymentAlertSources.set(.init(name: PaymentAlertSources.smsName, expense: true, income: false, lastSeen: .now), defaults: defaults)
        XCTAssertFalse(PaymentAlertSources.allows(PaymentAlertSources.smsName, income: true, defaults: defaults))
        XCTAssertTrue(PaymentAlertSources.allows(PaymentAlertSources.smsName, income: false, defaults: defaults))
    }

    func testRideQuestionIsAskedForUnconfirmedVehicleRides() {
        let base = Date(timeIntervalSince1970: 1_794_000_000)
        let defaults = UserDefaults(suiteName: "SkipWordAndRideTests.ride")!
        defaults.removePersistentDomain(forName: "SkipWordAndRideTests.ride")
        func segment(_ mode: TravelMode, minutes: Double = 15, confirmed: Bool = false, evidence: [String] = [], offset: Double = 0) -> TravelSegment {
            var value = TravelSegment(mode: mode, span: TimeSpan(start: base.addingTimeInterval(offset), end: base.addingTimeInterval(offset + minutes * 60)),
                                      distanceMeters: 3_000, confidence: .high, evidence: evidence)
            value.isConfirmed = confirmed
            return value
        }
        XCTAssertTrue(RideConfirmation.needsAnswer(segment(.bus), corrections: [], stopDefaults: defaults))
        XCTAssertTrue(RideConfirmation.needsAnswer(segment(.cycling), corrections: [], stopDefaults: defaults))
        XCTAssertTrue(RideConfirmation.needsAnswer(segment(.train), corrections: [], stopDefaults: defaults))
        XCTAssertFalse(RideConfirmation.needsAnswer(segment(.bus, confirmed: true), corrections: [], stopDefaults: defaults))
        XCTAssertFalse(RideConfirmation.needsAnswer(segment(.bus, evidence: ["사용자 확인 · 수단 수정"]), corrections: [], stopDefaults: defaults))
        XCTAssertFalse(RideConfirmation.needsAnswer(segment(.bus, minutes: 2), corrections: [], stopDefaults: defaults), "3분 안 되는 구간은 묻지 않는다")
        XCTAssertFalse(RideConfirmation.needsAnswer(segment(.walking), corrections: [], stopDefaults: defaults))
        // 차량인데 탄 곳·내린 곳이 둘 다 정류소면 묻는다.
        let car = segment(.car, offset: 7_200)
        XCTAssertFalse(RideConfirmation.needsAnswer(car, corrections: [], stopDefaults: defaults))
        BusStopCheck.remember(.board, segment: car, isStop: true, defaults: defaults)
        BusStopCheck.remember(.alight, segment: car, isStop: true, defaults: defaults)
        XCTAssertTrue(RideConfirmation.needsAnswer(car, corrections: [], stopDefaults: defaults))
        BusRouteCheck.remember(car, routes: [.init(number: "80", kind: "간선버스")], defaults: defaults)
        BusRouteCheck.remember(car, names: .init(board: "가 정류소", alight: "나 정류소"), defaults: defaults)
        XCTAssertEqual(RideConfirmation.routeChoices(car, stopDefaults: defaults).map(\.number), ["80"])
        XCTAssertEqual(BusRouteCheck.stopNames(car, defaults: defaults)?.alight, "나 정류소")
        XCTAssertEqual(RideConfirmation.pending([car, segment(.bus)], corrections: [], stopDefaults: defaults).count, 2)
    }
}

/// 집 날씨는 보고 있는 시각의 것(WTH1114A01).
final class HomeWeatherDateTests: XCTestCase {
    func testPastDayAndPlaybackUseTheirOwnTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 9))!
        let pastDay = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10))!
        let picked = pastDay.addingTimeInterval(15 * 3600)
        let playing = pastDay.addingTimeInterval(8 * 3600)
        typealias Policy = MapHomeHomeWeatherBadgePolicy
        XCTAssertEqual(Policy.displayDate(playback: nil, selectedDay: now, selection: now.addingTimeInterval(-3600), now: now, calendar: calendar), now)
        XCTAssertEqual(Policy.displayDate(playback: nil, selectedDay: pastDay, selection: picked, now: now, calendar: calendar), picked)
        XCTAssertEqual(Policy.displayDate(playback: playing, selectedDay: pastDay, selection: picked, now: now, calendar: calendar), playing)
    }
}

/// 진료과 이름만 있는 가게도 의료·건강(HLT1114A01). 가게 이름은 지어낸 것이다.
final class LedgerHealthCategoryTests: XCTestCase {
    func testClinicNamesWithoutHospitalWordAreHealth() {
        for name in ["가나마취통증의학과", "다라정형외과", "마바내과", "사아피부과", "자차한의원", "카타이비인후과", "파하클리닉"] {
            XCTAssertEqual(LedgerCategory.guess(name), .health, name)
        }
        XCTAssertEqual(LedgerCategory.guess("가나카페"), .cafe)
        XCTAssertEqual(LedgerCategory.guess("다라식당"), .food)
    }
}

/// 「내부」로 정한 글이 넣은 기록 찾기(INT1114A01).
final class InternalTransferChoiceTests: XCTestCase {
    func testFindsTheEntryThisTextAdded() {
        let received = Date(timeIntervalSince1970: 1_794_000_000)
        let item = PaymentInbox.Item(text: "출금 50,000원 입출금통장 → 지역카드", receivedAt: received, outcome: .added, message: "")
        var added = LedgerEntry(occurredAt: received, amount: 50_000, title: "지역카드")
        added.source = .message
        added.createdAt = received.addingTimeInterval(2)
        var manual = LedgerEntry(occurredAt: received, amount: 50_000, title: "직접 넣음")
        manual.createdAt = received
        var other = LedgerEntry(occurredAt: received, amount: 3_500, title: "카페")
        other.source = .message
        other.createdAt = received
        var old = LedgerEntry(occurredAt: received, amount: 50_000, title: "지난 충전")
        old.source = .message
        old.createdAt = received.addingTimeInterval(-3_600)
        XCTAssertEqual(PaymentInboxChoice.addedEntry(for: item, in: [manual, other, old, added])?.id, added.id)
        XCTAssertNil(PaymentInboxChoice.addedEntry(for: item, in: [manual, other, old]), "직접 넣은 것·다른 금액·오래된 것은 지우지 않는다")
    }
}
