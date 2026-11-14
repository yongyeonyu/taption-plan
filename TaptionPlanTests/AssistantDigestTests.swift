import XCTest
import TaptionPlanCore
@testable import TaptionPlan

/// 「AI가 정리한 N건」 전·후 보기(ABA1114A15): 요약 글, 날짜별 묶음, 되돌리기 상태, 옛 기록 읽기.
@MainActor
final class AssistantDigestTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func clock(_ hour: Int, _ minute: Int = 0) -> String { AssistantEditText.clock(at(hour, minute)) }

    private func walk(_ from: Date, _ to: Date, _ title: String = "걷기") -> ActualRecord {
        ActualRecord(planID: nil, title: title, categoryID: "movement", startedAt: from, endedAt: to, source: .motion)
    }

    private func entry(
        _ kind: AssistantActionKind, applied: Date, delta: AssistantEditDelta = .init(),
        undone: Bool = false, rejected: String? = nil, irreversible: Bool? = nil
    ) -> AssistantLogEntry {
        AssistantLogEntry(
            commandID: UUID().uuidString, kind: kind, appliedAt: applied, before: "전", after: "후", delta: delta,
            undoneAt: undone ? applied : nil, rejectedReason: rejected, irreversible: irreversible
        )
    }

    // MARK: - 요약 글

    func testMergeSummaryCountsRecordsAndShowsTheWholeRange() {
        let three = [walk(at(14, 20), at(14, 30)), walk(at(14, 10), at(14, 20)), walk(at(14, 30), at(14, 40))]
        XCTAssertEqual(AssistantChangeSummary.merged(three, language: .korean), "걷기 3건 (\(clock(14, 10))–\(clock(14, 40)))")
        XCTAssertEqual(AssistantChangeSummary.merged(three, language: .english), "걷기 ×3 (\(clock(14, 10))–\(clock(14, 40)))")
        let mixed = [walk(at(9), at(10), "업무"), walk(at(10), at(11), "회의"), walk(at(11), at(12), "정리"), walk(at(12), at(13), "업무")]
        XCTAssertEqual(AssistantChangeSummary.merged(mixed, language: .korean), "업무·회의… 4건 (\(clock(9))–\(clock(13)))")
        XCTAssertEqual(AssistantChangeSummary.merged([], language: .korean), "")
        XCTAssertEqual(AssistantChangeSummary.mergedInto("14:10–14:40 걷기", language: .korean), "1건으로 합침 · 14:10–14:40 걷기")
    }

    func testMoveSummaryKeepsTheTimeOnBothSides() {
        let span = TimeSpan(start: at(8, 30), end: at(9))
        XCTAssertEqual(AssistantChangeSummary.move(span, mode: "버스"), "\(clock(8, 30))–\(clock(9)) 버스")
    }

    func testExpenseSummaryShowsOnlyTheFieldsThatChanged() {
        let toll = LedgerEntry(occurredAt: at(9), amount: 900, category: .other, title: "통행료")
        XCTAssertEqual(AssistantChangeSummary.expense(toll, language: .korean), "통행료 900원 · \(AssistantDataText.day(at(9))) · 기타")

        var sorted = toll
        sorted.category = .transport
        let category = AssistantChangeSummary.expensePair(before: toll, after: sorted, language: .korean)
        XCTAssertEqual(category.before, "통행료 900원 · 기타")
        XCTAssertEqual(category.after, "통행료 900원 · 교통")

        var moved = toll
        moved.amount = 1_900
        moved.occurredAt = at(9, day: 11)
        moved.tripID = "trip"
        let many = AssistantChangeSummary.expensePair(before: toll, after: moved, language: .korean)
        XCTAssertEqual(many.before, "통행료 900원 · \(AssistantDataText.day(at(9))) · 일상 지출")
        XCTAssertEqual(many.after, "통행료 1,900원 · \(AssistantDataText.day(at(9, day: 11))) · 여행 지출")

        var noted = toll
        noted.note = "메모만 바뀜"
        let same = AssistantChangeSummary.expensePair(before: toll, after: noted, language: .korean)
        XCTAssertEqual(same.before, same.after, "보이지 않는 칸만 바뀌면 이름과 금액만 적는다")
    }

    func testMemoSummaryShowsWhereALongMemoChanged() {
        let short = AssistantChangeSummary.memoPair("커피 마심", "카페에서 커피를 마셨다")
        XCTAssertEqual(short.before, "커피 마심")
        XCTAssertEqual(short.after, "카페에서 커피를 마셨다")

        let head = String(repeating: "가", count: 200)
        let long = AssistantChangeSummary.memoPair(head + "끝이 틀림", head + "끝을 고침")
        XCTAssertNotEqual(long.before, long.after, "앞 80자가 같아도 달라진 곳이 보인다")
        XCTAssertTrue(long.before.hasPrefix("…") && long.before.hasSuffix("끝이 틀림"))
        XCTAssertTrue(long.after.hasSuffix("끝을 고침"))
        XCTAssertLessThanOrEqual(long.after.count, 81)

        let trimmed = AssistantChangeSummary.memoPair(head + "꼬리", head)
        XCTAssertTrue(trimmed.before.hasSuffix("꼬리"))
        XCTAssertEqual(trimmed.after, "…" + String(repeating: "가", count: 20))
    }

    // MARK: - 날짜별 묶음

    func testDigestGroupsByTheDayOfTheChangedRecordNotTheDayItWasApplied() {
        let record = walk(at(14, 10, day: 9), at(14, 40, day: 9))
        var merged = AssistantEditDelta()
        merged.actuals = [.init(id: record.id, before: record, after: nil)]
        var spent = AssistantEditDelta()
        spent.ledgerEntry = LedgerEntry(occurredAt: at(8, day: 9), amount: 900, title: "통행료")
        var memo = AssistantEditDelta()
        let note = ActionMemo(occurredAt: at(20, day: 10), kind: .nextAction, text: "메모")
        memo.memos = [.init(id: note.id, before: nil, after: note)]
        let log = [
            entry(.mergeRecords, applied: at(23, day: 10), delta: merged),
            entry(.addExpense, applied: at(23, day: 10), delta: spent),
            entry(.updateMemo, applied: at(23, day: 10), delta: memo),
            entry(.setLanguage, applied: at(23, day: 10)),
        ]
        let ninth = AssistantDigest.day(log, on: at(0, day: 9), calendar: calendar)
        XCTAssertEqual(ninth.items.map(\.entry.kind), [.mergeRecords, .addExpense], "어제 기록을 오늘 고쳐도 어제 것으로 묶는다")
        let tenth = AssistantDigest.day(log, on: at(0, day: 10), calendar: calendar)
        XCTAssertEqual(tenth.items.map(\.entry.kind), [.updateMemo, .setLanguage], "날짜가 없는 설정은 반영한 날로 묶는다")
        XCTAssertEqual(AssistantDigest.day(log, on: at(0, day: 11), calendar: calendar).count, 0)
    }

    func testDigestLeavesOutRejectedCommandsAndQuestionsAndSplitsUndoStates() {
        let log = [
            entry(.mergeRecords, applied: at(9)),
            entry(.setTravelMode, applied: at(10), undone: true),
            entry(.addExpense, applied: at(11)),
            entry(.operation("refreshRecords"), applied: at(12), irreversible: true),
            entry(.updateMemo, applied: at(13), rejected: "no_memo"),
            entry(.askUser, applied: at(14)),
            entry(.operation("rule.merchant_category"), applied: at(15)),
        ]
        let digest = AssistantDigest.day(log, on: at(0), calendar: calendar)
        XCTAssertEqual(digest.count, 5)
        XCTAssertEqual([digest.count(.undoable), digest.count(.undone), digest.count(.irreversible)], [3, 1, 1])
        XCTAssertEqual(digest.groups.map(\.group), [.records, .settings, .ledger], "많은 것부터")
        XCTAssertEqual(digest.groups.map(\.count), [2, 2, 1])
        XCTAssertEqual(AssistantDigest.headline(digest.count, language: .korean), "AI가 정리한 5건")
        XCTAssertEqual(AssistantDigest.breakdown(digest, language: .korean), "기록 2 · 설정 2 · 가계부 1")
        XCTAssertEqual(AssistantDigest.undoLine(digest, language: .korean), "되돌릴 수 있는 것 3건 · 되돌린 것 1건 · 되돌릴 수 없는 것 1건")
        XCTAssertEqual(AssistantDigest.undoLine(.init(items: Array(digest.items.prefix(1))), language: .korean), "되돌릴 수 있는 것 1건")
    }

    /// 기록 형식은 바꾸지 않았다. 새 칸이 하나도 없는 옛 기록이 그대로 읽히고 반영한 날로 묶인다.
    func testOldLogEntriesStillDecodeAndLandOnTheAppliedDay() throws {
        let applied = at(9).timeIntervalSinceReferenceDate
        let json = """
        [{"id":"\(UUID().uuidString)","commandID":"old","kind":"mergeRecords","appliedAt":\(applied),
          "before":"09:00–10:00 업무 · 10:00–11:00 회의","after":"09:00–11:00 업무",
          "delta":{"plans":[],"memos":[],"actuals":[],"corrections":[],"addedSleepSpans":[],"removedSleepSpans":[]}}]
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aba-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        try Data(json.utf8).write(to: file)
        let log = AssistantActionLog.load(from: file)
        XCTAssertEqual(log.map(\.commandID), ["old"])
        let digest = AssistantDigest.day(log, on: at(0), calendar: calendar)
        XCTAssertEqual(digest.items.map(\.state), [.undoable])
        XCTAssertEqual(digest.items.first?.entry.before, "09:00–10:00 업무 · 10:00–11:00 회의")
    }

    // MARK: - 반영 경로

    func testAppliedMergeAndTravelModeWriteReadableSummariesAndStayUndoable() async throws {
        let name = "AssistantDigestTests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        var seed = TaptionDataSnapshot.empty
        let walks = [walk(at(14, 10), at(14, 20)), walk(at(14, 20), at(14, 30)), walk(at(14, 30), at(14, 40))]
        let ride = TravelSegment(mode: .car, span: TimeSpan(start: at(8, 30), end: at(9)), distanceMeters: 8_000, confidence: .medium, evidence: [])
        seed.actuals = walks
        seed.travel = [ride]
        let model = AppModel(repository: InMemoryPlanRepository(snapshot: seed), cloudSyncService: nil)
        await model.bootstrap()

        func apply(_ action: String, _ extra: [String: Any]) async throws -> AssistantLogEntry {
            let item = ["format": "bokki-command", "version": 1, "id": UUID().uuidString, "action": action, "date": "2026-11-10"].merging(extra) { $1 }
            let data = try JSONSerialization.data(withJSONObject: ["commands": [item]])
            let batch = try XCTUnwrap(AssistantCommandParser.parse(data, now: at(15), calendar: calendar))
            let applied = await model.applyAssistantCommands(batch, defaults: store)
            let outcome = try XCTUnwrap(applied)
            XCTAssertEqual(outcome.results.map(\.applied), [true], "\(outcome.results)")
            return try XCTUnwrap(outcome.entries.first)
        }

        let merged = try await apply("mergeRecords", ["recordIds": walks.map(\.id.uuidString)])
        let range = "\(clock(14, 10))–\(clock(14, 40))"
        XCTAssertTrue(merged.before.contains("3") && merged.before.contains("(\(range))"), merged.before)
        XCTAssertTrue(merged.after.hasSuffix("\(range) 걷기"), merged.after)
        XCTAssertTrue(calendar.isDate(AssistantDigest.recordDate(merged), inSameDayAs: at(0)))

        let moved = try await apply("setTravelMode", ["moveId": ride.id.uuidString, "mode": "bus", "line": "80"])
        XCTAssertTrue(moved.before.hasPrefix("\(clock(8, 30))–\(clock(9)) "), moved.before)
        XCTAssertTrue(moved.after.hasPrefix("\(clock(8, 30))–\(clock(9)) ") && moved.after.hasSuffix(" · 80"), moved.after)
        XCTAssertNotEqual(moved.before, moved.after)

        let digest = AssistantDigest.day([moved, merged], on: at(0), calendar: calendar)
        XCTAssertEqual(digest.items.map(\.group), [.records, .records])
        for item in digest.items {
            let undone = await model.undoAssistantEntry(item.entry, preferences: .test(store))
            XCTAssertTrue(undone)
        }
        XCTAssertEqual(Set(model.snapshot.actuals.map(\.id)), Set(walks.map(\.id)), "원래 기록 세 개가 그대로 남는다")
        XCTAssertEqual(model.snapshot.travel.first?.mode, .car)
    }
}
