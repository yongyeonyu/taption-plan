import XCTest
@testable import TaptionPlan

/// 앱 화면이 쓰는 `AppModel` 백업 흐름: 비밀번호 등록 → 지금 백업 → 로컬 정리 → 복원 → 확인 뒤 백업 삭제.
/// 목적지는 로컬 폴더(실제 iCloud는 기기 설치본에서만 확인할 수 있다). 앱 전체 삭제(`deleteAllUserData`)는
/// 실기기 앱 데이터를 지우므로 부르지 않고, 백업 파일 삭제 경로만 확인 인자와 함께 시험한다.
@MainActor
final class AppModelBackupConnectionTests: XCTestCase {
    private let password = "482915"
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func reading(_ time: Date, _ index: Int) -> SensorReading {
        SensorReading(
            timestamp: time,
            point: GeoPoint(latitude: 37.5665 + Double(index) * 0.0001, longitude: 126.978, altitude: 20,
                            horizontalAccuracy: 5, verticalAccuracy: 3),
            motion: .walking, motionConfidence: .high, sequence: index
        )
    }

    private struct Harness {
        let model: AppModel
        let store: TaptionStoreV2
        let backupDirectory: URL
        let defaults: UserDefaults
    }

    private func makeHarness() throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-connect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directories.append(root)
        let store = try TaptionStoreV2(url: root.appendingPathComponent("store.sqlite"), calendar: calendar)
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        var configuration = TaptionBackupEngine.Configuration()
        configuration.iterations = 1_000
        configuration.temporaryDirectory = temporary
        let engine = TaptionBackupEngine(
            store: store, destination: TaptionLocalFolderBackupDestination(directory: backups),
            calendar: calendar, configuration: configuration
        )
        let suite = "AppModelBackupConnectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let security = PlanSecurityService(
            credentialStore: InMemoryPlanCredentialStore(),
            biometricAuthenticator: MockPlanLocalBiometricAuthenticator(),
            settingsDefaults: defaults
        )
        let sensorArchive = try SensorReadingArchive(fileURL: root.appendingPathComponent("readings.jsonl"), store: store)
        let model = AppModel(
            repository: TaptionStoreRepository(store: store),
            sensorService: AppleSensorDataService(archive: sensorArchive),
            cloudSyncService: nil,
            securityService: security,
            backupEngine: engine,
            rawDeviceDataArchive: try RawDeviceDataDayArchive(store: store),
            dayDatabase: PlanDayDatabase(store: store)
        )
        return Harness(model: model, store: store, backupDirectory: backups, defaults: defaults)
    }

    private func backupFileNames(_ harness: Harness) throws -> [String] {
        guard FileManager.default.fileExists(atPath: harness.backupDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: harness.backupDirectory.path)
            .filter { $0.hasSuffix(".taptionbackup") }.sorted()
    }

    func testBackupRequiresARegisteredPasswordAndTheRightOne() async throws {
        let harness = try makeHarness()
        let model = harness.model
        try await harness.store.appendImmutableReadings([reading(date(2026, 10, 10), 1)])

        await model.backUpNow(password: password, now: date(2026, 10, 19))
        XCTAssertEqual(model.lastBackupReport?.succeeded, false, "비밀번호를 등록하기 전에는 백업하지 않는다")
        XCTAssertEqual(try backupFileNames(harness), [])

        try model.configureBackupPIN(password)
        await model.backUpNow(password: "000000", now: date(2026, 10, 19))
        XCTAssertEqual(model.lastBackupReport?.succeeded, false)
        XCTAssertEqual(model.securityStatus.failedAttempts, 1)
        XCTAssertEqual(try backupFileNames(harness), [])
        XCTAssertNil(model.securityStatus.latestSuccessfulBackupDate)
        XCTAssertEqual(model.backupActivity, .idle)
    }

    func testBackupOffloadRestoreAndConfirmedDeletionFlow() async throws {
        let harness = try makeHarness()
        let model = harness.model
        let store = harness.store
        try model.configureBackupPIN(password)
        XCTAssertTrue(model.securityStatus.hasPIN)

        try await store.appendImmutableReadings([
            reading(date(2026, 7, 15), 1), reading(date(2026, 7, 15).addingTimeInterval(60), 2),
            reading(date(2026, 8, 15), 3),
            reading(date(2026, 10, 10), 4),
        ])
        let now = date(2026, 10, 19)

        // 지금 백업: 데이터가 있는 달마다 파일 하나.
        await model.backUpNow(password: password, now: now)
        let report = try XCTUnwrap(model.lastBackupReport)
        XCTAssertTrue(report.succeeded, report.summary)
        XCTAssertEqual(report.operation, .backup)
        let names = try backupFileNames(harness)
        XCTAssertTrue(names.contains("2026-07.taptionbackup"))
        XCTAssertTrue(names.contains("2026-08.taptionbackup"))
        XCTAssertTrue(names.contains("2026-10.taptionbackup"))
        XCTAssertFalse(names.contains("2026-09.taptionbackup"), "데이터가 없는 달은 만들지 않는다")
        XCTAssertEqual(model.securityStatus.latestSuccessfulBackupDate, now)
        XCTAssertEqual(report.items.filter { $0.kind == .done }.count, names.count)

        // 같은 내용으로 다시 백업하면 바뀐 것이 없다고 보고한다.
        await model.backUpNow(password: password, now: now.addingTimeInterval(60))
        let again = try XCTUnwrap(model.lastBackupReport)
        XCTAssertTrue(again.items.allSatisfy { $0.kind != .done })
        XCTAssertTrue(again.items.contains { $0.kind == .unchanged })

        // 목록: 비밀번호 없이는 월·크기만, 비밀번호를 넣으면 행 수.
        await model.refreshBackupListings()
        let bare = try XCTUnwrap(model.backupListings.first { $0.name == "2026-07.taptionbackup" })
        XCTAssertNil(bare.rowCount)
        XCTAssertFalse(bare.metadataShown)
        XCTAssertGreaterThan(bare.size, 0)
        await model.refreshBackupListings(password: password)
        let detailed = try XCTUnwrap(model.backupListings.first { $0.name == "2026-07.taptionbackup" })
        XCTAssertEqual(detailed.rowCount, 2)
        XCTAssertTrue(detailed.metadataShown)

        // 로컬 정리: 기본값으로 이번 달과 지난달만 남긴다.
        XCTAssertEqual(model.securityStatus.localMonthsToKeep, 2)
        let revisionBeforeOffload = model.backupRestoreRevision
        await model.offloadLocalMonths(password: password, now: now)
        let offload = try XCTUnwrap(model.lastBackupReport)
        XCTAssertTrue(offload.succeeded, offload.summary)
        XCTAssertEqual(offload.items.filter { $0.kind == .done }.map(\.name).sorted(), ["2026-07", "2026-08"])
        let c1 = try await store.readingCount()
        XCTAssertEqual(c1, 1, "7월·8월 센서 행은 이 기기에서 지워졌다")
        XCTAssertGreaterThan(model.backupRestoreRevision, revisionBeforeOffload)
        await model.refreshBackupListings(password: password)
        XCTAssertTrue(try XCTUnwrap(model.backupListings.first { $0.name == "2026-07.taptionbackup" }).isOffloaded)
        XCTAssertFalse(try XCTUnwrap(model.backupListings.first { $0.name == "2026-10.taptionbackup" }).isOffloaded)

        // 틀린 비밀번호로는 복원하지 않는다.
        await model.restoreBackup(.month(TaptionBackupMonth(year: 2026, month: 7)), password: "111111")
        XCTAssertEqual(model.lastBackupReport?.succeeded, false)
        let c2 = try await store.readingCount()
        XCTAssertEqual(c2, 1)

        // 복원: 정리한 달을 다시 불러온다.
        let revisionBeforeRestore = model.backupRestoreRevision
        await model.restoreBackup(.month(TaptionBackupMonth(year: 2026, month: 7)), password: password)
        let restore = try XCTUnwrap(model.lastBackupReport)
        XCTAssertTrue(restore.succeeded, restore.summary)
        let c3 = try await store.readingCount()
        XCTAssertEqual(c3, 3)
        XCTAssertGreaterThan(model.backupRestoreRevision, revisionBeforeRestore)
        XCTAssertEqual(model.backupActivity, .idle)

        // 백업 전체 삭제는 확인(confirmed) 없이는 아무것도 지우지 않는다.
        do {
            try await model.deleteAllBackupFiles(confirmed: false)
            XCTFail("확인 없이 백업을 지우면 안 된다")
        } catch is CancellationError {}
        XCTAssertFalse(try backupFileNames(harness).isEmpty)
        XCTAssertNotNil(model.securityStatus.latestSuccessfulBackupDate)

        try await model.deleteAllBackupFiles(confirmed: true)
        XCTAssertEqual(try backupFileNames(harness), [])
        XCTAssertTrue(model.backupListings.isEmpty)
        XCTAssertNil(model.securityStatus.latestSuccessfulBackupDate)
        let c4 = try await store.readingCount()
        XCTAssertEqual(c4, 3, "백업 삭제는 로컬 데이터를 건드리지 않는다")
    }

    func testChangingThePasswordKeepsOldBackupsReadableOnlyWithTheOldOne() async throws {
        let harness = try makeHarness()
        let model = harness.model
        try model.configureBackupPIN(password)
        try await harness.store.appendImmutableReadings([reading(date(2026, 10, 10), 1)])
        await model.backUpNow(password: password, now: date(2026, 10, 19))
        XCTAssertEqual(model.lastBackupReport?.succeeded, true)

        try model.configureBackupPIN("739104")
        await model.restoreBackup(.month(TaptionBackupMonth(year: 2026, month: 10)), password: "739104")
        XCTAssertEqual(model.lastBackupReport?.succeeded, false, "바꾸기 전에 만든 백업은 새 비밀번호로 열리지 않는다")
        await model.restoreBackup(.month(TaptionBackupMonth(year: 2026, month: 10)), password: password)
        XCTAssertEqual(model.lastBackupReport?.succeeded, true)
    }

    func testPresenterDescribesRejectedOverwriteAndSkippedOffload() {
        let kept = PlanBackupPresenter.item(for: TaptionBackupEngine.BackupResult(
            scope: .month(TaptionBackupMonth(year: 2026, month: 7)),
            outcome: .keptExisting(.fewerRows(existing: 10, new: 4)), header: nil, message: ""
        ))
        XCTAssertEqual(kept.kind, .rejected)
        XCTAssertEqual(kept.name, "2026-07")
        XCTAssertTrue(kept.detail.contains("10") && kept.detail.contains("4"))
        for message in [
            "2026-07.taptionbackup 백업이 없거나 읽을 수 없다.",
            "2026-07.taptionbackup은 달이 끝나기 전에 만든 백업이라 지우지 않는다. 다시 백업해야 한다.",
            "2026-07.taptionbackup의 내용이 로컬과 달라 지우지 않는다. 다시 백업해야 한다.",
            "2026-07.taptionbackup 검증 후 로컬에 새 행이 들어와 지우지 않았다.",
            "2026-07.taptionbackup 검증 실패로 지우지 않았다: wrongPassword",
        ] {
            XCTAssertNotEqual(PlanBackupPresenter.skipDetail(message), PlanBackupPresenter.skipDetail("알 수 없음"), message)
        }
    }

    func testICloudPlaceholderNamesResolveToTheRealFile() {
        XCTAssertEqual(
            TaptionICloudDriveBackupDestination.placeholderTarget(".2026-07.taptionbackup.icloud"),
            "2026-07.taptionbackup"
        )
        XCTAssertNil(TaptionICloudDriveBackupDestination.placeholderTarget("2026-07.taptionbackup"))
        XCTAssertNil(TaptionICloudDriveBackupDestination.placeholderTarget(".icloud"))
        XCTAssertEqual(TaptionICloudDriveBackupDestination.defaultContainerIdentifier, "iCloud.com.taption.plan")
    }
}
