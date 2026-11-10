import Foundation
import XCTest
@testable import TaptionPlan

/// 저장·백업 리뷰 수정(REV1110A04)의 회귀 시험.
final class StorageReviewFixTests: XCTestCase {
    private let password = "482915"
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    // MARK: 백업 엔진

    func testMemoOnlyMonthIsBackedUp() async throws {
        let harness = try makeHarness(withMemoStore: true)
        let memoStore = try XCTUnwrap(harness.memoStore)
        try await memoStore.upsertRecords([record("memo-1", start: date(2026, 8, 3))])

        let results = try await harness.engine.backupAllMonths(password: password, now: date(2026, 11, 1))

        let august = results.first { $0.scope == .month(month(2026, 8)) }
        XCTAssertEqual(august?.outcome, .written)
        XCTAssertEqual(august?.header?.recordCount, 1)
    }

    func testRawEventOnlyMonthIsBackedUp() async throws {
        let harness = try makeHarness(withMemoStore: false)
        let event = TaptionRawEvent(
            kind: TaptionRawEvent.Kind.watchSummary, id: "w-1", timestamp: date(2026, 8, 5), payload: "{}"
        )
        _ = try await harness.store.appendRawEvents([event])

        let results = try await harness.engine.backupAllMonths(password: password, now: date(2026, 11, 1))

        XCTAssertEqual(results.first { $0.scope == .month(month(2026, 8)) }?.outcome, .written)
    }

    func testSealedMonthWithoutExistingFileIsNotReplacedByFewRows() async throws {
        let harness = try makeHarness(withMemoStore: false)
        try await harness.store.setMeta("backup.sealed.2026-08", "digest|500")
        try await harness.store.upsertRecords([record("late-1", start: date(2026, 8, 9))])

        let result = try await harness.engine.backup(month: month(2026, 8), password: password, now: date(2026, 11, 1))

        XCTAssertEqual(result.outcome, .skippedSealed)
        let files = try await harness.destination.list().map(\.name)
        XCTAssertFalse(files.contains(month(2026, 8).fileName))
    }

    func testOffloadRemovesVerifiedMemos() async throws {
        let harness = try makeHarness(withMemoStore: true)
        let memoStore = try XCTUnwrap(harness.memoStore)
        try await harness.store.upsertRecords([record("plan-1", kind: "plan", start: date(2026, 8, 3))])
        try await memoStore.upsertRecords([record("memo-1", start: date(2026, 8, 4))])
        _ = try await harness.engine.backupAllMonths(password: password, now: date(2026, 11, 1))

        let results = try await harness.engine.offloadSealedMonths(password: password, now: date(2026, 11, 1))

        XCTAssertEqual(results.first?.outcome, .sealed(readings: 0, records: 2))
        let remaining = try await memoStore.recordsForBackup(from: 0, to: .greatestFiniteMagnitude)
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: 저장소

    func testLoadAfterQueuedSaveSeesSavedPlan() async throws {
        let store = try TaptionStoreV2(url: try makeDirectory().appendingPathComponent("store.sqlite"))
        let repository = TaptionStoreRepository(store: store)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.updatedAt = Date(timeIntervalSince1970: 1_000)
        snapshot.plans = [PlanRecord(
            title: "추가", span: TimeSpan(start: date(2026, 8, 1), end: date(2026, 8, 1, 13)), categoryID: "project"
        )]
        await repository.handleMemoryPressure()
        // 저장이 비교 기준을 다시 읽어도(내부 읽기) 줄을 스스로 기다리다 멈추지 않는다.
        let queued = snapshot
        let saving = Task { try await repository.save(queued) }
        let loaded = try await repository.load()
        try await saving.value
        let reloaded = try await repository.load()

        XCTAssertTrue(loaded.plans.isEmpty || loaded.plans == snapshot.plans)
        XCTAssertEqual(reloaded.plans, snapshot.plans)
        try await repository.save(reloaded)
        let afterSecondSave = try await repository.load()
        XCTAssertEqual(afterSecondSave.plans, snapshot.plans)
    }

    // MARK: 센서 갱신 되돌리기

    @MainActor
    func testOnlyMutationsOutsideSensorRefreshBlockRollback() {
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: .empty), cloudSyncService: nil
        )
        model.isSensorTimelineRefreshing = true
        SensorRefreshMutationScope.$isActive.withValue(true) {
            model.snapshot.updatedAt = Date(timeIntervalSince1970: 10)
        }
        XCTAssertFalse(model.userEditedDuringSensorRefresh)

        model.snapshot.updatedAt = Date(timeIntervalSince1970: 20)
        XCTAssertTrue(model.userEditedDuringSensorRefresh)
        model.isSensorTimelineRefreshing = false
        model.userEditedDuringSensorRefresh = false
    }

    // MARK: 도우미

    private struct Harness {
        let store: TaptionStoreV2
        let memoStore: TaptionStoreV2?
        let destination: TaptionLocalFolderBackupDestination
        let engine: TaptionBackupEngine
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func month(_ year: Int, _ month: Int) -> TaptionBackupMonth {
        TaptionBackupMonth(date: date(year, month, 15), calendar: calendar)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private func makeHarness(withMemoStore: Bool) throws -> Harness {
        let root = try makeDirectory()
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let store = try TaptionStoreV2(url: root.appendingPathComponent("store.sqlite"), calendar: calendar)
        let memoStore = withMemoStore
            ? try TaptionStoreV2(url: root.appendingPathComponent("memos.sqlite"), calendar: calendar) : nil
        let destination = TaptionLocalFolderBackupDestination(
            directory: root.appendingPathComponent("backups", isDirectory: true)
        )
        var configuration = TaptionBackupEngine.Configuration()
        configuration.iterations = 1_000
        configuration.minimumIterations = 1
        configuration.temporaryDirectory = temporary
        let engine = TaptionBackupEngine(
            store: store, memoStore: memoStore, destination: destination, calendar: calendar,
            configuration: configuration
        )
        return Harness(store: store, memoStore: memoStore, destination: destination, engine: engine)
    }

    private func record(_ id: String, kind: String = "memo", start: Date) -> TaptionStoreRecord {
        TaptionStoreRecord(
            id: id, kind: kind, start: start, end: start.addingTimeInterval(60),
            updatedAt: Date(timeIntervalSince1970: 1_790_000_000), origin: .user, isDeleted: false, ord: 0,
            body: "{\"n\":1}"
        )
    }
}
