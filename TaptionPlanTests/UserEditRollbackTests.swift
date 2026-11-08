import XCTest
import TaptionPlanCore
@testable import TaptionPlan

/// 다음 저장 하나를 붙잡아 두었다가 성공이나 실패로 끝낸다.
actor HeldSavePlanRepository: PlanDataRepository {
    private var stored: TaptionDataSnapshot
    private(set) var saved: [TaptionDataSnapshot] = []
    private var holdsNext = false
    private var failsHeld = false
    private var isHolding = false
    private var holdStarted: CheckedContinuation<Void, Never>?
    private var holdRelease: CheckedContinuation<Void, Never>?

    init(snapshot: TaptionDataSnapshot) { stored = snapshot }

    func load() async throws -> TaptionDataSnapshot { stored }

    func holdNextSave(failing: Bool) {
        holdsNext = true
        failsHeld = failing
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        if holdsNext {
            holdsNext = false
            isHolding = true
            holdStarted?.resume()
            holdStarted = nil
            await withCheckedContinuation { holdRelease = $0 }
            isHolding = false
            if failsHeld { throw RepositoryError.invalidSnapshot }
        }
        saved.append(snapshot)
        stored = snapshot
    }

    func waitUntilHolding() async {
        guard !isHolding else { return }
        await withCheckedContinuation { holdStarted = $0 }
    }

    func release() {
        holdRelease?.resume()
        holdRelease = nil
    }
}

@MainActor
final class UserEditRollbackTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_790_000_000)

    private var stored: TaptionDataSnapshot {
        var value = TaptionDataSnapshot.empty
        value.categories = CategoryCatalog.builtIn
        value.settings.locationEnabled = false
        value.settings.weatherEnabled = false
        value.settings.healthEnabled = false
        return value
    }

    private var option: ActivityCorrectionOption {
        ActivityCorrectionOption(id: "phase.work", title: "업무", behavior: nil, categoryID: "work",
                                 systemImage: "circle.fill", isAutomatic: false, isCustom: false)
    }

    private var span: TimeSpan { TimeSpan(start: day, end: day.addingTimeInterval(3_600)) }

    private func makeModel(_ repository: PlanDataRepository) async -> AppModel {
        let model = AppModel(repository: repository, cloudSyncService: nil, registersHealthBackgroundHandler: false)
        await model.bootstrap()
        await drainWrites(model)
        model.userFacingError = nil
        return model
    }

    private func drainWrites(_ model: AppModel) async {
        for _ in 0..<50 {
            await Task.yield()
            if let task = model.repositoryWriteTask { _ = await task.result }
        }
    }

    private func hasManualWork(_ snapshot: TaptionDataSnapshot) -> Bool {
        snapshot.actuals.contains { $0.source == .manual && $0.categoryID == "work" && $0.startedAt == day }
    }

    func testFailedSaveRollsBackEditAndShowsError() async {
        var source = stored
        let plan = PlanRecord(title: "지울 계획", span: span, categoryID: "work")
        source.plans = [plan]
        let model = await makeModel(RejectingSavePlanRepository(snapshot: source))
        let undoCount = model.userEditUndoHistory.count

        await model.classifyUnconfirmedSpan(span, with: option)
        XCTAssertFalse(hasManualWork(model.snapshot))
        XCTAssertEqual(model.userEditUndoHistory.count, undoCount)
        XCTAssertNotNil(model.userFacingError)

        model.userFacingError = nil
        await model.deletePlan(plan.id)
        XCTAssertEqual(model.snapshot.plans.map(\.id), [plan.id])
        XCTAssertNotNil(model.userFacingError)
    }

    func testCancelledSaveRollsBackQuietly() async {
        let model = await makeModel(CancellationSavePlanRepository(snapshot: stored))
        await model.classifyUnconfirmedSpan(span, with: option)
        XCTAssertFalse(hasManualWork(model.snapshot))
        XCTAssertNil(model.userFacingError)
    }

    /// 실패한 저장을 기다리는 사이에 다른 변경이 들어오면 그 변경은 남기고 이 편집만 되돌린다.
    func testRollbackKeepsChangesMadeWhileSaveWasPending() async {
        let repository = HeldSavePlanRepository(snapshot: stored)
        let model = await makeModel(repository)
        await repository.holdNextSave(failing: true)

        let edit = Task { @MainActor in await model.classifyUnconfirmedSpan(span, with: option) }
        await repository.waitUntilHolding()
        let concurrent = PlanRecord(title: "동시 계획", span: span, categoryID: "study")
        model.snapshot.plans.append(concurrent)
        await repository.release()
        await edit.value
        await drainWrites(model)

        XCTAssertFalse(hasManualWork(model.snapshot))
        XCTAssertTrue(model.snapshot.plans.contains { $0.id == concurrent.id })
        XCTAssertNotNil(model.userFacingError)
        let saved = await repository.saved
        XCTAssertFalse(saved.contains(where: hasManualWork))
        XCTAssertTrue(saved.last?.plans.contains { $0.id == concurrent.id } == true)
    }

    /// 앞 저장이 늦게 끝나도, 뒤에 줄 선 전체 저장이 있으면 그 사이의 옛 값은 쓰지 않는다.
    func testQueuedStaleSnapshotWriteIsDiscarded() async throws {
        let repository = HeldSavePlanRepository(snapshot: stored)
        let model = await makeModel(repository)
        await repository.holdNextSave(failing: false)
        let sequence = model.repositoryWriteSequence

        let first = try XCTUnwrap(model.addPlan(title: "첫째", categoryID: "work", startAt: day, duration: 600))
        await repository.waitUntilHolding()
        let second = try XCTUnwrap(model.addPlan(title: "둘째", categoryID: "work", startAt: day.addingTimeInterval(900), duration: 600))
        let third = try XCTUnwrap(model.addPlan(title: "셋째", categoryID: "work", startAt: day.addingTimeInterval(1_800), duration: 600))
        for _ in 0..<200 where model.repositoryWriteSequence < sequence &+ 3 { await Task.yield() }
        XCTAssertGreaterThanOrEqual(model.repositoryWriteSequence, sequence &+ 3)
        await repository.release()
        await drainWrites(model)

        let saved = await repository.saved
        let ids = saved.map { Set($0.plans.map(\.id)) }
        XCTAssertFalse(ids.contains { $0.contains(second) && !$0.contains(third) }, "늦은 옛 값이 저장됨")
        XCTAssertEqual(ids.first, [first])
        XCTAssertTrue(ids.last?.isSuperset(of: [first, second, third]) == true)
        XCTAssertNil(model.userFacingError)
    }

    func testWriteLedgerMarksOnlyOlderWritesSuperseded() {
        let ledger = SnapshotWriteLedger()
        ledger.begin(3)
        ledger.begin(5)
        XCTAssertTrue(ledger.isSuperseded(3))
        XCTAssertFalse(ledger.isSuperseded(5))
        ledger.begin(4)
        XCTAssertEqual(ledger.latestSequence, 5)
    }

    // MARK: - 불러오기 전 저장 막기 (NLE1103A04)

    func testClipEditSaveIsBlockedBeforeRecordsLoad() async {
        var source = stored
        let actual = ActualRecord(planID: nil, title: "기존 기록", categoryID: "work",
                                  startedAt: day, endedAt: day.addingTimeInterval(3_600), source: .manual)
        source.actuals = [actual]
        let repository = GatedStartupPlanRepository(snapshot: source)
        let model = AppModel(repository: repository, cloudSyncService: nil, registersHealthBackgroundHandler: false)
        await model.prepareStartupSettings()

        let request = ActivitySectionEditRequest(
            sourceIDs: [actual.id], originalSpan: span, originalOption: option,
            mode: .replace(editedSpan: span, option: option)
        )
        let saved = await model.saveClipEditBatch(main: [request], detail: [])
        XCTAssertFalse(saved)
        XCTAssertNotNil(model.userFacingError)
        let saves = await repository.saves
        XCTAssertEqual(saves, 0)

        await repository.releaseHistory()
        await model.prepareLocalDataForDisplay()
        await model.waitForBootstrapPreparation()
        XCTAssertEqual(model.snapshot.actuals.map(\.id), [actual.id])
    }

    func testClipSaveGateWaitsForDayAndRecords() {
        XCTAssertFalse(NLEClipSaveGate(hasChanges: true, isSaving: false, isDayLoaded: false, recordsLoaded: true).canApply)
        XCTAssertFalse(NLEClipSaveGate(hasChanges: true, isSaving: false, isDayLoaded: true, recordsLoaded: false).canApply)
        XCTAssertFalse(NLEClipSaveGate(hasChanges: true, isSaving: true, isDayLoaded: true, recordsLoaded: true).canApply)
        XCTAssertFalse(NLEClipSaveGate(hasChanges: false, isSaving: false, isDayLoaded: true, recordsLoaded: true).canApply)
        XCTAssertTrue(NLEClipSaveGate(hasChanges: true, isSaving: false, isDayLoaded: true, recordsLoaded: true).canApply)
    }
}
