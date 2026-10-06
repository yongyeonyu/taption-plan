import Foundation
import Darwin
import SQLite3
import XCTest
@testable import TaptionPlan
import TaptionPlanCore

final class SQLitePlanRepositoryTests: XCTestCase {
    private func recordFixture(count: Int = 1_500) -> TaptionDataSnapshot {
        var value = TaptionDataSnapshot.empty
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let duplicateID = UUID()
        value.actuals = (0..<count).map { i in
            ActualRecord(id: i < 2 ? duplicateID : UUID(), planID: nil,
                title: i.isMultiple(of: 2) ? "Caf\u{00E9}" : "Cafe\u{0301}", categoryID: "activity",
                startedAt: start.addingTimeInterval(Double(count - i) * 60),
                endedAt: i.isMultiple(of: 3) ? nil : start.addingTimeInterval(Double(count - i) * 60 + 30),
                source: .location, createdAt: start, behavior: "fixture", evidence: ["source-fixture", "Cafe\u{0301}"],
                modelVersion: "fixture-v1", isClassificationLocked: true)
        }
        return value
    }

    func testInlineHistoryImportsOnceIntoTypedRowsWithAllProvenance() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let value = recordFixture()
        let store = try TaptionPlanDayStore(url: url, allowsUndatedSnapshots: true)
        let day = TaptionPlanDayKey(year: 0, month: 0, day: 0)
        try await store.saveSnapshot(.init(domain: "plan.actuals", day: day, revision: 1,
            updatedAt: Date(timeIntervalSince1970: 1_790_000_000), payload: try PlanActualStorage.encode(value.actuals)))
        let repository = try SQLitePlanRepository(databaseURL: url)
        let loaded = try await repository.load()
        XCTAssertTrue(PlanActualStorage.exactlyEqual(loaded.actuals[...], value.actuals[...]))
        let root = try await store.snapshot(domain: "plan.actuals", day: day)
        let header = try PlanActualStorage.nativeHeader(XCTUnwrap(root).payload)
        XCTAssertEqual(header.count, value.actuals.count)
        let revision = try await store.actualRecordRevision()
        let reopened = try await SQLitePlanRepository(databaseURL: url).load()
        let secondRevision = try await store.actualRecordRevision()
        XCTAssertEqual(revision, secondRevision)
        XCTAssertTrue(PlanActualStorage.exactlyEqual(reopened.actuals[...], value.actuals[...]))
        XCTAssertEqual(reopened.actuals[0].id, reopened.actuals[1].id)
        try await repository.deleteAll()
        let rows = try await store.actualRecords()
        XCTAssertTrue(rows.isEmpty)
    }

    func testTypedHistoryWritesOneRowAndHandlesAppendReorderShrinkEmpty() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        let store = try TaptionPlanDayStore(url: url, allowsUndatedSnapshots: true)
        var value = recordFixture()
        try await repository.save(value)
        let before = try await store.actualRecordRevision()
        var record = value.actuals[512]
        record.title = "Cafe\u{0301}\0native"
        record.evidence[1] = "Caf\u{00E9}"
        let edit = try XCTUnwrap(PlanActualEdit(replacing: record, at: 512, in: value.actuals))
        value.actuals = edit.result
        try await repository.save(value, actualEdit: edit)
        let compared = await repository.lastComparedActualRecords
        let written = await repository.lastWrittenActualRecords
        let after = try await store.actualRecordRevision()
        XCTAssertEqual(compared, 1)
        XCTAssertEqual(written, 1)
        XCTAssertEqual(after - before, 1)
        let reader = try SQLitePlanRepository(databaseURL: url)
        let first = try await reader.load()
        XCTAssertTrue(PlanActualStorage.exactlyEqual(first.actuals[...], value.actuals[...]))
        value.actuals.append(value.actuals[0])
        try await repository.save(value)
        let appended = await repository.lastWrittenActualRecords
        XCTAssertEqual(appended, 1)
        value.actuals.reverse()
        try await repository.save(value)
        let reordered = try await reader.load()
        XCTAssertTrue(PlanActualStorage.exactlyEqual(reordered.actuals[...], value.actuals[...]))
        value.actuals = Array(value.actuals.prefix(1))
        try await repository.save(value)
        let shrunk = try await reader.load()
        XCTAssertEqual(shrunk.actuals, value.actuals)
        value.actuals = []
        try await repository.save(value)
        let empty = try await reader.load()
        let noRows = try await store.actualRecords()
        XCTAssertTrue(empty.actuals.isEmpty)
        XCTAssertTrue(noRows.isEmpty)
    }

    func testNativeImportFailureRollsBackAndRetryCompletes() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let value = recordFixture()
        let store = try TaptionPlanDayStore(url: url, allowsUndatedSnapshots: true)
        let day = TaptionPlanDayKey(year: 0, month: 0, day: 0)
        let source = TaptionPlanDayStore.Snapshot(domain: "plan.actuals", day: day,
            revision: 1, updatedAt: Date(timeIntervalSince1970: 1_790_000_000), payload: try PlanActualStorage.encode(value.actuals))
        try await store.saveSnapshot(source)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER fail_native BEFORE INSERT ON actual_records WHEN NEW.position=500 BEGIN SELECT RAISE(ABORT,'fixture'); END;", nil, nil, nil), SQLITE_OK)
        let repository = try SQLitePlanRepository(databaseURL: url)
        do { _ = try await repository.load(); XCTFail("Failed import must not activate") } catch {}
        let original = try await store.snapshot(domain: "plan.actuals", day: day)
        let rows = try await store.actualRecords()
        let revision = try await store.actualRecordRevision()
        XCTAssertEqual(original, source)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(revision, 0)
        XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER fail_native;", nil, nil, nil), SQLITE_OK)
        let afterRetry = try await repository.load()
        XCTAssertTrue(PlanActualStorage.exactlyEqual(afterRetry.actuals[...], value.actuals[...]))
    }

    func testExternalTypedRowChangeInvalidatesCacheWithoutRootRevisionChange() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        var value = recordFixture()
        try await repository.save(value)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "UPDATE actual_records SET title='external' WHERE position=1;", nil, nil, nil), SQLITE_OK)
        let loaded = try await repository.load()
        value.actuals[1].title = "external"
        XCTAssertTrue(PlanActualStorage.exactlyEqual(loaded.actuals[...], value.actuals[...]))
        XCTAssertEqual(sqlite3_exec(database, "UPDATE actual_records SET evidence=X'00' WHERE position=1;", nil, nil, nil), SQLITE_OK)
        do { _ = try await repository.load(); XCTFail("Corruption must not be hidden by cached root") } catch {}
        try await repository.save(value)
        await repository.handleMemoryPressure()
        let repaired = try await repository.load()
        XCTAssertTrue(PlanActualStorage.exactlyEqual(repaired.actuals[...], value.actuals[...]))
    }

    func testIndexedDayQueryRejectsUnsavedOrExternallyChangedSource() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        var value = recordFixture()
        try await repository.save(value)
        let start = value.actuals[800].startedAt
        let span = TimeSpan(start: start, end: start.addingTimeInterval(60))
        let query = try await repository.actuals(in: span, matching: value.actuals)
        let expected = value.actuals.filter { $0.startedAt <= span.end && ($0.endedAt == nil || max($0.startedAt, $0.endedAt!) >= span.start) }
        XCTAssertEqual(query, expected)
        value.actuals[0].title = "unsaved"
        let pending = try await repository.actuals(in: span, matching: value.actuals)
        XCTAssertNil(pending)
        let current = try await repository.load()
        let external = try SQLitePlanRepository(databaseURL: url)
        var externalValue = current
        externalValue.actuals[0].title = "external"
        try await external.save(externalValue)
        let stale = try await repository.actuals(in: span, matching: current.actuals)
        XCTAssertNil(stale)
        try await repository.save(value)
        await repository.handleMemoryPressure()
        let memoryPressure = try await repository.actuals(in: span, matching: value.actuals)
        XCTAssertNil(memoryPressure)
    }

    func testEditHintFallsBackWhenAnotherRecordAlsoChanged() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        var value = recordFixture()
        try await repository.save(value)
        var record = value.actuals[0]
        record.title = "first"
        let edit = try XCTUnwrap(PlanActualEdit(replacing: record, at: 0, in: value.actuals))
        value.actuals = edit.result
        value.actuals[900].title = "second"
        try await repository.save(value, actualEdit: edit)
        let written = await repository.lastWrittenActualRecords
        XCTAssertEqual(written, 2)
        let loaded = try await SQLitePlanRepository(databaseURL: url).load()
        XCTAssertEqual(loaded.actuals, value.actuals)
    }

    func testEveryActualFieldSurvivesTypedDeltaAndModelRoundTrip() throws {
        let value = recordFixture(count: 1_024)
        let mutations: [(inout ActualRecord) -> Void] = [
            { $0.id = UUID() }, { $0.planID = UUID() }, { $0.routineID = UUID() },
            { $0.title = "Cafe\u{0301}" }, { $0.categoryID = "work" },
            { $0.startedAt.addTimeInterval(0.125) }, { $0.endedAt = .now },
            { $0.source = .manual }, { $0.confidence = .low }, { $0.createdAt.addTimeInterval(0.125) },
            { $0.behavior = "other" }, { $0.evidence[1] = "Caf\u{00E9}" },
            { $0.routeID = UUID() }, { $0.sensorChunkID = UUID() }, { $0.modelVersion = "v2" },
            { $0.manuallyCorrected.toggle() }, { $0.isClassificationLocked.toggle() },
        ]
        for mutate in mutations {
            var changed = value.actuals
            mutate(&changed[2])
            let next = try PlanActualStorage.delta(changed, previous: value.actuals,
                previousKeys: PlanActualStorage.keys(for: value.actuals), edit: nil)
            XCTAssertEqual(next.rows.map(\.position), [2])
            let decoded = try PlanActualStorage.records(from: next.rows)
            XCTAssertTrue(PlanActualStorage.exactlyEqual(decoded[...], changed[2...2]))
        }
    }

    func testNoOpPreparationReusesStorageButKeepsByteDistinctEdits() throws {
        let previous = recordFixture(count: 3).actuals
        var identical = previous
        identical[0].title = "temporary"
        identical[0] = previous[0]
        let reused = PlanActualStorage.reusingUnchangedStorage(identical, previous: previous, cancellationCheck: {})
        XCTAssertTrue(PlanActualStorage.sharesStorage(reused, previous))
        var changed = previous
        changed[0].title = "Cafe\u{0301}"
        XCTAssertEqual(changed[0].title, previous[0].title)
        let preserved = PlanActualStorage.reusingUnchangedStorage(changed, previous: previous, cancellationCheck: {})
        XCTAssertFalse(PlanActualStorage.sharesStorage(preserved, previous))
        XCTAssertEqual(Array(preserved[0].title.utf8), Array(changed[0].title.utf8))
        XCTAssertThrowsError(try PlanActualStorage.reusingUnchangedStorage(identical, previous: previous,
            cancellationCheck: { throw CancellationError() }))
    }

    @MainActor
    func testAppDayProjectionUsesIndexedSourceAndGoalLinkUsesExplicitDelta() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let date = Date(timeIntervalSince1970: 1_791_250_000)
        var value = TaptionDataSnapshot.empty
        value.categories = CategoryCatalog.builtIn
        value.settings.locationEnabled = false
        value.settings.healthEnabled = false
        value.settings.weatherEnabled = false
        let actual = ActualRecord(planID: nil, title: "합성 활동", categoryID: "work",
            startedAt: date, endedAt: date.addingTimeInterval(600), source: .manual)
        let old = ActualRecord(planID: nil, title: "합성 과거", categoryID: "work",
            startedAt: date.addingTimeInterval(-172_800), endedAt: date.addingTimeInterval(-172_200), source: .manual)
        let goal = PlanRecord(title: "루틴:합성 목표", span: TimeSpan(start: date.addingTimeInterval(-60),
            end: date.addingTimeInterval(3_600)), categoryID: "work")
        value.actuals = [old, actual]
        value.plans = [goal]
        let primary = try SQLitePlanRepository(databaseURL: url)
        try await primary.save(value)
        let tracker = IndexedRepositoryProbe(primary: primary)
        let repository = MigratingPlanRepository(primary: tracker, legacy: InMemoryPlanRepository())
        let model = AppModel(repository: repository, cloudSyncService: nil, registersHealthBackgroundHandler: false)
        await model.bootstrap()
        let day = await model.planDaySourceSnapshot(for: date, reusing: nil)
        XCTAssertEqual(day?.actuals.map(\.id), [actual.id])
        let counts = await tracker.queryCounts
        XCTAssertEqual(counts.last, 1)
        await model.connectActualRecord(actual.id, toGoal: goal.id)
        let editCount = await tracker.explicitEdits
        XCTAssertEqual(editCount, 1)
        let compared = await primary.lastComparedActualRecords
        let written = await primary.lastWrittenActualRecords
        XCTAssertEqual(compared, 1)
        XCTAssertEqual(written, 1)
        let stored = try await primary.load()
        XCTAssertEqual(stored.actuals.first { $0.id == actual.id }?.routineID, goal.id)
        XCTAssertEqual(stored.actuals.first { $0.id == old.id }, old)
        let beforePreview = await tracker.queryCounts.count
        _ = await model.cachedPlanDayDataSnapshot(for: date)
        let afterPreview = await tracker.queryCounts.count
        XCTAssertEqual(afterPreview, beforePreview, "Cached preview must not query canonical history")
        await model.sceneEnteredBackground()
    }

    func testFileRepositoryDecodesSecondsSince1970LZFSESnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-plan-legacy-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("snapshot.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        var value = TaptionDataSnapshot.empty
        value.updatedAt = Date(timeIntervalSince1970: 1_725_000_123.25)
        value.plans = [
            PlanRecord(
                title: "Unix 시간 기록",
                span: TimeSpan(
                    start: Date(timeIntervalSince1970: 1_725_000_000.5),
                    end: Date(timeIntervalSince1970: 1_725_000_060.75)
                ),
                categoryID: "activity"
            )
        ]
        let json = try SnapshotExporter.jsonData(value, prettyPrinted: false)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try TaptionSnapshotCompression.encode(json).write(
            to: fileURL,
            options: [.atomic]
        )

        let restored = try await FilePlanRepository(fileURL: fileURL).load()
        XCTAssertEqual(restored.updatedAt, value.updatedAt)
        let restoredPlan = try XCTUnwrap(restored.plans.first)
        let originalPlan = try XCTUnwrap(value.plans.first)
        XCTAssertEqual(restoredPlan.id, originalPlan.id)
        XCTAssertEqual(restoredPlan.title, originalPlan.title)
        XCTAssertEqual(restoredPlan.categoryID, originalPlan.categoryID)
        XCTAssertEqual(
            restoredPlan.span.start.timeIntervalSince1970,
            originalPlan.span.start.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            restoredPlan.span.end.timeIntervalSince1970,
            originalPlan.span.end.timeIntervalSince1970,
            accuracy: 0.000_001
        )
    }

    func testFileRepositoryCreatedBeforeDeletionCannotRestoreStaleData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "taption-plan-file-repository-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent("snapshot.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stale = FilePlanRepository(fileURL: fileURL)
        let deleting = FilePlanRepository(fileURL: fileURL)
        var old = TaptionDataSnapshot.empty
        old.plans = [
            PlanRecord(
                title: "삭제 전 계획",
                span: TimeSpan(start: .now, end: .now.addingTimeInterval(60)),
                categoryID: "work"
            )
        ]
        try await stale.save(old)

        try await deleting.deleteAll()
        do {
            try await stale.save(old)
            XCTFail("stale file repository restored deleted data")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .staleGeneration)
        }
        let restored = try await deleting.load()
        XCTAssertEqual(restored, .empty)
    }

    func testFileRepositoryCanSaveAgainAfterReloadingDeletedGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "taption-plan-file-reload-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent("snapshot.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let reloading = FilePlanRepository(fileURL: fileURL)
        let deleting = FilePlanRepository(fileURL: fileURL)

        try await deleting.deleteAll()
        let empty = try await reloading.load()
        XCTAssertEqual(empty, .empty)

        var fresh = TaptionDataSnapshot.empty
        fresh.plans = [
            PlanRecord(
                title: "삭제 후 계획",
                span: TimeSpan(start: .now, end: .now.addingTimeInterval(60)),
                categoryID: "work"
            )
        ]
        try await reloading.save(fresh)

        let saved = try await FilePlanRepository(fileURL: fileURL).load()
        XCTAssertEqual(saved.plans.map(\.title), ["삭제 후 계획"])
    }

    func testFileRepositoryRecoversInterruptedDeletionBeforeReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "taption-plan-file-interrupted-delete-\(UUID().uuidString)",
                isDirectory: true
            )
        let fileURL = directory.appendingPathComponent("snapshot.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FilePlanRepository(fileURL: fileURL)
        var old = TaptionDataSnapshot.empty
        old.plans = [
            PlanRecord(
                title: "삭제 중단 전 계획",
                span: TimeSpan(start: .now, end: .now.addingTimeInterval(60)),
                categoryID: "work"
            )
        ]
        try await repository.save(old)
        var newer = old
        newer.plans[0].title = "백업에 남은 계획"
        try await repository.save(newer)

        try Data("1".utf8).write(
            to: fileURL.appendingPathExtension("generation"),
            options: [.atomic]
        )
        try Data("1".utf8).write(
            to: fileURL.appendingPathExtension("deletion-pending"),
            options: [.atomic]
        )

        let restored = try await FilePlanRepository(fileURL: fileURL).load()

        XCTAssertEqual(restored, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fileURL.appendingPathExtension("backup").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fileURL.appendingPathExtension("deletion-pending").path
            )
        )
    }

    func testCloudKitTemporaryAssetUsesFileProtection() throws {
        let url = try CloudKitSnapshotSyncService.writeTemporaryAsset(
            Data(repeating: 0x41, count: 850_001)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
#if !targetEnvironment(simulator)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
                as? FileProtectionType,
            .completeUntilFirstUserAuthentication
        )
#endif
    }

    func testFutureWeatherForecastSurvivesSQLiteRoundTrip() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }

        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let forecast = WeatherContext(
            observedAt: observedAt,
            fetchedAt: observedAt.addingTimeInterval(-60),
            isForecast: true,
            condition: "맑음",
            symbolName: "sun.max.fill",
            temperatureCelsius: 27,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5
            )
        )
        var value = TaptionDataSnapshot.empty
        value.weather = [forecast]

        let repository = try SQLitePlanRepository(databaseURL: url)
        try await repository.save(value)
        let reopened = try SQLitePlanRepository(databaseURL: url)
        let restored = try await reopened.load()

        XCTAssertEqual(restored.weather, [forecast])
        XCTAssertEqual(restored.weather.first?.isForecast, true)
    }

    func testMapStickersSurviveSQLiteRoundTrip() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }

        let occurredAt = Date(timeIntervalSince1970: 1_800_000_000)
        var value = TaptionDataSnapshot.empty
        value.stickers = [
            MapSticker(
                title: "현장 메모",
                memo: "원본 위치",
                placement: .map,
                point: GeoPoint(
                    latitude: 37.5,
                    longitude: 127,
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                ),
                occurredAt: occurredAt,
                createdAt: occurredAt,
                updatedAt: occurredAt
            ),
        ]

        let repository = try SQLitePlanRepository(databaseURL: url)
        try await repository.save(value)
        let restored = try await SQLitePlanRepository(databaseURL: url).load()

        XCTAssertEqual(restored.stickers, value.stickers)
    }

    func testLegacyMigrationReturnsBeforePrimaryWriteFinishes() async throws {
        var existing = TaptionDataSnapshot.empty
        existing.updatedAt = Date(timeIntervalSince1970: 1_725_000_000)
        existing.plans = [
            PlanRecord(
                title: "기존 기록",
                span: TimeSpan(
                    start: existing.updatedAt,
                    end: existing.updatedAt.addingTimeInterval(60)
                ),
                categoryID: "activity"
            )
        ]
        let primary = BlockingPlanRepository()
        let repository = MigratingPlanRepository(
            primary: primary,
            legacy: InMemoryPlanRepository(snapshot: existing)
        )

        let loaded = try await repository.load()
        XCTAssertEqual(loaded.plans, existing.plans)
        await primary.waitUntilSaveStarted()
        let primaryBeforeRelease = try await primary.load()
        XCTAssertTrue(primaryBeforeRelease.plans.isEmpty)

        await primary.releaseSave()
        for _ in 0..<100 {
            if (try await primary.load()).plans == existing.plans { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("background legacy migration did not finish")
    }

    func testExplicitSaveWaitsForAndSupersedesLegacyMigration() async throws {
        var existing = TaptionDataSnapshot.empty
        existing.updatedAt = Date(timeIntervalSince1970: 1_725_000_000)
        existing.plans = [
            PlanRecord(
                title: "기존 기록",
                span: TimeSpan(
                    start: existing.updatedAt,
                    end: existing.updatedAt.addingTimeInterval(60)
                ),
                categoryID: "activity"
            )
        ]
        let replacement: TaptionDataSnapshot = {
            var snapshot = TaptionDataSnapshot.empty
            snapshot.plans = [
                PlanRecord(
                    title: "최신 기록",
                    span: TimeSpan(
                        start: existing.updatedAt,
                        end: existing.updatedAt.addingTimeInterval(120)
                    ),
                    categoryID: "work"
                )
            ]
            return snapshot
        }()
        let primary = BlockingPlanRepository()
        let repository = MigratingPlanRepository(
            primary: primary,
            legacy: InMemoryPlanRepository(snapshot: existing)
        )

        _ = try await repository.load()
        await primary.waitUntilSaveStarted()
        let save = Task { try await repository.save(replacement) }
        try await Task.sleep(for: .milliseconds(20))
        let primaryBeforeRelease = try await primary.load()
        XCTAssertTrue(primaryBeforeRelease.plans.isEmpty)

        await primary.releaseSave()
        try await save.value
        let saved = try await primary.load()
        XCTAssertEqual(saved.plans, replacement.plans)
    }

    func testFailedPrimaryMigrationCanRetryOnNextLoad() async throws {
        var existing = TaptionDataSnapshot.empty
        existing.updatedAt = Date(timeIntervalSince1970: 1_725_000_000)
        existing.plans = [
            PlanRecord(
                title: "재시도할 기존 기록",
                span: TimeSpan(
                    start: existing.updatedAt,
                    end: existing.updatedAt.addingTimeInterval(60)
                ),
                categoryID: "activity"
            ),
        ]
        let primary = FailOncePlanRepository()
        let repository = MigratingPlanRepository(
            primary: primary,
            legacy: InMemoryPlanRepository(snapshot: existing)
        )

        let first = try await repository.load()
        XCTAssertEqual(first.plans, existing.plans)
        await primary.waitUntilSaveAttempted()

        let second = try await repository.load()
        XCTAssertEqual(second.plans, existing.plans)
        for _ in 0..<100 {
            if (try await primary.load()).plans == existing.plans { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("primary migration did not retry after its first save failure")
    }

    func testRoundTripReopenAndCanonicalPayload() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        var value = TaptionDataSnapshot.empty
        value.updatedAt = Date(timeIntervalSince1970: 123)
        value.plans = [
            PlanRecord(
                title: "분할 저장",
                span: TimeSpan(
                    start: Date(timeIntervalSince1970: 100),
                    end: Date(timeIntervalSince1970: 200)
                ),
                categoryID: "work",
                createdAt: Date(timeIntervalSince1970: 50),
                updatedAt: Date(timeIntervalSince1970: 60)
            )
        ]

        let repository = try SQLitePlanRepository(databaseURL: url)
        try await repository.save(value)
        let first = try await repository.load()
        XCTAssertEqual(first.plans, value.plans)
        XCTAssertEqual(first.actuals, value.actuals)
        XCTAssertGreaterThan(first.updatedAt, value.updatedAt)

        let reopened = try SQLitePlanRepository(databaseURL: url)
        let second = try await reopened.load()
        XCTAssertEqual(second.plans, first.plans)
        XCTAssertEqual(second.actuals, first.actuals)
        XCTAssertEqual(second.updatedAt, first.updatedAt)

        let store = try TaptionPlanDayStore(url: url, allowsUndatedSnapshots: true)
        let rows = try await store.snapshots(
            day: .init(year: 0, month: 0, day: 0)
        )
        XCTAssertTrue(rows.contains { $0.domain == "plan.plans" })
        XCTAssertFalse(rows.contains { $0.domain == "plan.snapshot" })
        let payload = try XCTUnwrap(
            rows.first(where: { $0.domain == "plan.plans" })?.payload
        )
        XCTAssertEqual(String(decoding: payload.prefix(8), as: UTF8.self), "TP-CANON")
        let encoded = try TaptionPlanCanonicalStorage.encodedPayload(from: payload)
        let plans = try TaptionPlanCanonicalStorage.decode([PlanRecord].self, from: encoded)
        XCTAssertEqual(plans.first?.title, "분할 저장")
    }

    func testSaveOverwritesWithMonotonicRevision() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        try await repository.save(.empty)
        try await repository.save(.empty)

        let store = try TaptionPlanDayStore(url: url, allowsUndatedSnapshots: true)
        let snapshot = try await store.snapshot(
            domain: "plan.metadata",
            day: .init(year: 0, month: 0, day: 0)
        )
        XCTAssertEqual(snapshot?.revision, 2)
    }

    func testUnchangedDomainsAreNotRewritten() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        var value = TaptionDataSnapshot.empty
        value.plans = [
            PlanRecord(
                title: "고정 계획",
                span: TimeSpan(start: .now, end: .now.addingTimeInterval(60)),
                categoryID: "work"
            )
        ]
        let repository = try SQLitePlanRepository(databaseURL: url)
        try await repository.save(value)
        let store = try TaptionPlanDayStore(url: url, allowsUndatedSnapshots: true)
        let day = TaptionPlanDayKey(year: 0, month: 0, day: 0)
        let firstPlan = try await store.snapshot(domain: "plan.plans", day: day)
        let firstPlanRevision = try XCTUnwrap(firstPlan?.revision)

        try await repository.save(value)
        let secondPlan = try await store.snapshot(domain: "plan.plans", day: day)
        let metadata = try await store.snapshot(domain: "plan.metadata", day: day)
        let secondPlanRevision = try XCTUnwrap(secondPlan?.revision)
        let metadataRevision = try XCTUnwrap(metadata?.revision)

        XCTAssertEqual(firstPlanRevision, secondPlanRevision)
        XCTAssertEqual(metadataRevision, 2)
        let encodedDomains = await repository.lastEncodedDomains
        XCTAssertEqual(encodedDomains, ["plan.metadata", "plan.settings"])
    }

    func testSettingsSaveSkipsUnchangedRecordEncodingAfterReload() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        var value = TaptionDataSnapshot.empty
        value.actuals = [ActualRecord(
            planID: nil, title: "합성 기록", categoryID: "work",
            startedAt: .now, endedAt: .now.addingTimeInterval(60),
            source: .location, evidence: ["synthetic-fixture"]
        )]
        try await SQLitePlanRepository(databaseURL: url).save(value)
        let repository = try SQLitePlanRepository(databaseURL: url)
        var reloaded = try await repository.load()
        reloaded.settings.healthEnabled.toggle()

        try await repository.save(reloaded)

        let encoded = await repository.lastEncodedDomains
        XCTAssertEqual(encoded, ["plan.metadata", "plan.settings"])
        let restored = try await SQLitePlanRepository(databaseURL: url).load()
        XCTAssertEqual(restored.actuals, value.actuals)
        XCTAssertEqual(restored.settings, reloaded.settings)
    }

    func testEncodingCacheDetectsFieldChangeWithSameRecordIDAndCount() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        var value = TaptionDataSnapshot.empty
        value.actuals = [ActualRecord(
            planID: nil, title: "합성 기록", categoryID: "work",
            startedAt: .now, endedAt: .now.addingTimeInterval(60),
            source: .location, evidence: ["original-fixture"]
        )]
        try await repository.save(value)
        value.actuals[0].evidence = ["updated-fixture"]
        try await repository.save(value)

        let encoded = await repository.lastEncodedDomains
        XCTAssertEqual(encoded, ["plan.metadata", "plan.actuals", "plan.settings"])
        let restored = try await repository.load()
        XCTAssertEqual(restored.actuals, value.actuals)
    }

    func testEncodingCachePreservesByteDistinctUnicodeWithEqualIDsAndValues() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        var value = TaptionDataSnapshot.empty
        value.plans = [PlanRecord(
            title: "Caf\u{00E9}", span: TimeSpan(start: .now, end: .now.addingTimeInterval(60)),
            categoryID: "work"
        )]
        value.settings.customActivityLabels = ["\u{AC00}"]
        try await repository.save(value)
        let original = value
        value.plans[0].title = "Cafe\u{0301}"
        value.settings.customActivityLabels = ["\u{1100}\u{1161}"]
        XCTAssertEqual(value.plans, original.plans)
        XCTAssertEqual(value.settings, original.settings)
        XCTAssertNotEqual(Array(value.plans[0].title.utf8), Array(original.plans[0].title.utf8))

        try await repository.save(value)

        let restored = try await repository.load()
        XCTAssertEqual(Array(restored.plans[0].title.utf8), Array(value.plans[0].title.utf8))
        XCTAssertEqual(Array(restored.settings.customActivityLabels[0].utf8),
                       Array(value.settings.customActivityLabels[0].utf8))
    }

    func testEncodingCacheChecksExternalDomainRevisionBeforeSkipping() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        let external = try SQLitePlanRepository(databaseURL: url)
        var original = TaptionDataSnapshot.empty
        original.plans = [PlanRecord(
            title: "합성 원본", span: TimeSpan(start: .now, end: .now.addingTimeInterval(60)),
            categoryID: "work"
        )]
        try await repository.save(original)
        var changed = original
        changed.plans[0].title = "외부 변경"
        try await external.save(changed)
        try await repository.save(original)

        let encoded = await repository.lastEncodedDomains
        XCTAssertEqual(encoded, ["plan.metadata", "plan.plans", "plan.settings"])
        let restored = try await external.load()
        XCTAssertEqual(restored.plans, original.plans)
    }

    func testMemoryPressureDropsEncodingCacheWithoutChangingCanonicalData() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        var value = TaptionDataSnapshot.empty
        value.plans = [PlanRecord(
            title: "합성 기록", span: TimeSpan(start: .now, end: .now.addingTimeInterval(60)),
            categoryID: "work"
        )]
        try await repository.save(value)
        await repository.handleMemoryPressure()
        try await repository.save(value)

        let encoded = await repository.lastEncodedDomains
        XCTAssertEqual(encoded.count, 15)
        let store = try TaptionPlanDayStore(url: url, allowsUndatedSnapshots: true)
        let storedRevisions = try await store.snapshotRevisions(day: .init(year: 0, month: 0, day: 0))
        let revisions = Dictionary(uniqueKeysWithValues: storedRevisions.map { ($0.domain, $0.revision) })
        XCTAssertEqual(revisions["plan.plans"], 1)
        XCTAssertEqual(revisions["plan.metadata"], 2)
        let restored = try await repository.load()
        XCTAssertEqual(restored.plans, value.plans)
        XCTAssertEqual(restored.settings, value.settings)
    }

    func testFailedCanonicalLoadDropsTrustedEncodingCache() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        var value = TaptionDataSnapshot.empty
        value.plans = [PlanRecord(
            title: "합성 기록", span: TimeSpan(start: .now, end: .now.addingTimeInterval(60)),
            categoryID: "work"
        )]
        try await repository.save(value)
        let store = try TaptionPlanDayStore(url: url, allowsUndatedSnapshots: true)
        try await store.saveSnapshot(.init(
            domain: "plan.actuals", day: .init(year: 0, month: 0, day: 0),
            revision: 2, updatedAt: .now, payload: Data([0])
        ))
        do {
            _ = try await repository.load()
            XCTFail("Invalid canonical data must fail loading")
        } catch {
            XCTAssertEqual(error as? TaptionPlanCanonicalStorageError, .invalidPayload)
        }
        try await repository.save(value)
        let encoded = await repository.lastEncodedDomains
        XCTAssertEqual(encoded.count, 15)
        let restored = try await repository.load()
        XCTAssertEqual(restored.plans, value.plans)
        XCTAssertEqual(restored.actuals, value.actuals)
    }

    func testSaveReadbackReusesVerifiedSnapshotImmediately() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        var value = TaptionDataSnapshot.empty
        value.actuals = [ActualRecord(planID: nil, title: "합성", categoryID: "work",
            startedAt: Date(timeIntervalSince1970: 1_790_000_000), source: .manual)]
        let repository = try SQLitePlanRepository(databaseURL: url)
        try await repository.save(value)
        let first = try await repository.load()
        let reused = await repository.lastLoadReusedSnapshot
        XCTAssertTrue(reused)
        let skippedPayload = await repository.lastLoadSkippedPayloadRead
        let decoded = await repository.lastDecodedDomains
        XCTAssertTrue(skippedPayload)
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertEqual(first.actuals, value.actuals)
        value.settings.healthEnabled.toggle()
        try await repository.save(value)
        let second = try await repository.load()
        let reusedAfterEdit = await repository.lastLoadReusedSnapshot
        XCTAssertTrue(reusedAfterEdit)
        XCTAssertEqual(second.actuals, value.actuals)
        let reopened = try await SQLitePlanRepository(databaseURL: url).load()
        XCTAssertEqual(reopened, second)
    }

    func testExternalSettingsWriteOnlyDecodesChangedDomains() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        var value = TaptionDataSnapshot.empty
        value.actuals = [ActualRecord(planID: nil, title: "합성", categoryID: "work",
            startedAt: Date(timeIntervalSince1970: 1_790_000_000), source: .manual)]
        try await repository.save(value)
        let external = try SQLitePlanRepository(databaseURL: url)
        var externalValue = try await external.load()
        externalValue.settings.healthEnabled.toggle()
        try await external.save(externalValue)
        let loaded = try await repository.load()
        let decoded = await repository.lastDecodedDomains
        let skipped = await repository.lastLoadSkippedPayloadRead
        XCTAssertFalse(skipped)
        XCTAssertEqual(Set(decoded), ["plan.metadata", "plan.settings"])
        XCTAssertEqual(loaded.actuals, value.actuals)
        XCTAssertEqual(loaded.settings, externalValue.settings)
    }

    func testExternalSensorWriteChecksBytesWithoutDecodingUnchangedPlans() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        try await repository.save(.empty)
        let before = try await repository.load()
        let external = try TaptionPlanDayStore(url: url, allowsUndatedSnapshots: true)
        try await external.appendEvents([.init(day: .init(year: 2026, month: 10, day: 6),
            timestamp: .now, sequence: 1, id: "fixture", domain: "sensor-reading", payload: Data([1]))])
        let after = try await repository.load()
        let reused = await repository.lastLoadReusedSnapshot
        let skipped = await repository.lastLoadSkippedPayloadRead
        let decoded = await repository.lastDecodedDomains
        XCTAssertEqual(after, before)
        XCTAssertTrue(reused)
        XCTAssertFalse(skipped)
        XCTAssertTrue(decoded.isEmpty)
        _ = try await repository.load()
        let nextSkipped = await repository.lastLoadSkippedPayloadRead
        XCTAssertTrue(nextSkipped)
    }

    func testExternalDeletedDomainDoesNotResurrectCachedRecords() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        var value = TaptionDataSnapshot.empty
        value.plans = [PlanRecord(title: "합성", span: .init(start: .now,
            end: .now.addingTimeInterval(60)), categoryID: "work")]
        try await repository.save(value)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database,
            "DELETE FROM snapshots WHERE domain='plan.plans';", nil, nil, nil), SQLITE_OK)
        let loaded = try await repository.load()
        XCTAssertTrue(loaded.plans.isEmpty)
        XCTAssertEqual(loaded.settings, value.settings)
    }

    func testSaveVerifiesSameRevisionExternalBytesBeforeSkippingEncoding() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        var value = TaptionDataSnapshot.empty
        value.plans = [PlanRecord(title: "Caf\u{00E9}",
            span: TimeSpan(start: .now, end: .now.addingTimeInterval(60)), categoryID: "work")]
        try await repository.save(value)
        var external = value.plans
        external[0].title = "Cafe\u{0301}"
        try replacePlansPayload(TaptionPlanCanonicalStorage.envelope(
            for: TaptionPlanCanonicalStorage.encode(external)), databaseURL: url)
        value.settings.healthEnabled.toggle()
        try await repository.save(value)
        let encoded = await repository.lastEncodedDomains
        XCTAssertTrue(encoded.contains("plan.plans"))
        let loaded = try await repository.load()
        XCTAssertEqual(Array(loaded.plans[0].title.utf8), Array(value.plans[0].title.utf8))
    }

    func testWaitingLoadDoesNotRepopulateCacheAfterMemoryPressure() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        try await repository.save(.empty)
        _ = try await repository.load()
        let descriptor = Darwin.open(url.appendingPathExtension("lock").path,
            O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        let pending = Task { try await repository.load() }
        var started = false
        for _ in 0..<200 {
            if !(await repository.lastLoadSkippedPayloadRead) { started = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(started)
        await repository.handleMemoryPressure()
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        _ = try await pending.value
        _ = try await repository.load()
        let skipped = await repository.lastLoadSkippedPayloadRead
        let decoded = await repository.lastDecodedDomains
        XCTAssertFalse(skipped)
        XCTAssertFalse(decoded.isEmpty)
    }

    func testStartupSettingsReadDoesNotDecodeOrTrustHistory() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        var value = TaptionDataSnapshot.empty
        value.settings.healthEnabled = true
        try await repository.save(value)
        try replacePlansPayload(Data([0]), databaseURL: url)
        let startup = try await repository.loadStartupSnapshot()
        XCTAssertEqual(startup?.settings.healthEnabled, true)
        XCTAssertTrue(startup?.plans.isEmpty == true)
        do {
            _ = try await repository.load()
            XCTFail("Settings-only read must not hide corrupt history")
        } catch {
            XCTAssertEqual(error as? TaptionPlanCanonicalStorageError, .invalidPayload)
        }
    }

    func testRepeatedLoadChecksCanonicalBytesEvenWhenRevisionIsUnchanged() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        var value = TaptionDataSnapshot.empty
        value.plans = [PlanRecord(
            title: "Caf\u{00E9}",
            span: TimeSpan(start: .now, end: .now.addingTimeInterval(60)),
            categoryID: "work"
        )]
        try await repository.save(value)
        _ = try await repository.load()
        _ = try await repository.load()
        let reused = await repository.lastLoadReusedSnapshot
        XCTAssertTrue(reused)

        value.plans[0].title = "Cafe\u{0301}"
        let payload = TaptionPlanCanonicalStorage.envelope(
            for: try TaptionPlanCanonicalStorage.encode(value.plans)
        )
        try replacePlansPayload(payload, databaseURL: url)
        let changed = try await repository.load()
        let reusedChanged = await repository.lastLoadReusedSnapshot
        XCTAssertFalse(reusedChanged)
        XCTAssertEqual(Array(changed.plans[0].title.utf8), Array(value.plans[0].title.utf8))

        try replacePlansPayload(Data([0]), databaseURL: url)
        do {
            _ = try await repository.load()
            XCTFail("Same revision must not hide corrupted bytes")
        } catch {
            XCTAssertEqual(error as? TaptionPlanCanonicalStorageError, .invalidPayload)
        }
    }

    func testRepeatedLoadSeesExternalWritesAndMemoryPressure() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        let external = try SQLitePlanRepository(databaseURL: url)
        var value = TaptionDataSnapshot.empty
        try await repository.save(value)
        _ = try await repository.load()
        _ = try await repository.load()
        let reused = await repository.lastLoadReusedSnapshot
        XCTAssertTrue(reused)

        value.settings.healthEnabled.toggle()
        try await external.save(value)
        let changed = try await repository.load()
        let reusedChanged = await repository.lastLoadReusedSnapshot
        XCTAssertFalse(reusedChanged)
        XCTAssertEqual(changed.settings.healthEnabled, value.settings.healthEnabled)

        _ = try await repository.load()
        await repository.handleMemoryPressure()
        let afterPressure = try await repository.load()
        let reusedAfterPressure = await repository.lastLoadReusedSnapshot
        XCTAssertFalse(reusedAfterPressure)
        XCTAssertEqual(afterPressure, changed)

        try await external.deleteAll()
        let deleted = try await repository.load()
        XCTAssertEqual(deleted, .empty)
    }

    private func replacePlansPayload(_ payload: Data, databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteFixture", code: 1)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
            "UPDATE snapshots SET payload = ? WHERE domain = 'plan.plans';",
            -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteFixture", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bindResult = payload.withUnsafeBytes {
            sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient)
        }
        guard bindResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "SQLiteFixture", code: 3)
        }
    }

    func testMissingDatabaseLoadsEmpty() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)

        let value = try await repository.load()

        XCTAssertEqual(value, .empty)
    }

    func testLargeHistorySettingsSaveKeepsCanonicalData() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        var value = TaptionDataSnapshot.empty
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        value.actuals = (0..<120_000).map { index in
            ActualRecord(
                planID: nil, title: "합성 활동", categoryID: "activity",
                startedAt: start.addingTimeInterval(Double(index) * 60),
                endedAt: start.addingTimeInterval(Double(index) * 60 + 30),
                source: .location, evidence: ["synthetic-fixture"],
                isClassificationLocked: true
            )
        }
        let repository = try SQLitePlanRepository(databaseURL: url)
        let initialMemory = RepositoryFootprintProbe()
        let initialStart = ProcessInfo.processInfo.systemUptime
        try await repository.save(value)
        let initialMS = (ProcessInfo.processInfo.systemUptime - initialStart) * 1_000
        let initialPeak = initialMemory.finish()

        value.settings.healthEnabled.toggle()
        let settingsMemory = RepositoryFootprintProbe()
        let settingsStart = ProcessInfo.processInfo.systemUptime
        try await repository.save(value)
        let settingsMS = (ProcessInfo.processInfo.systemUptime - settingsStart) * 1_000
        let settingsPeak = settingsMemory.finish()
        let loadMemory = RepositoryFootprintProbe()
        let loadStart = ProcessInfo.processInfo.systemUptime
        let restored = try await repository.load()
        let loadMS = (ProcessInfo.processInfo.systemUptime - loadStart) * 1_000
        let loadPeak = loadMemory.finish()

        XCTAssertEqual(restored.actuals, value.actuals)
        XCTAssertEqual(restored.settings.healthEnabled, value.settings.healthEnabled)
        print("PER1006B01 fixture records=\(value.actuals.count) initial_ms=\(initialMS) settings_ms=\(settingsMS) load_ms=\(loadMS) initial_peak_mb=\(initialPeak) settings_peak_mb=\(settingsPeak) load_peak_mb=\(loadPeak)")
        let repeatMemory = RepositoryFootprintProbe()
        var repeatMS = 0.0
        for _ in 0..<3 {
            let repeatStart = ProcessInfo.processInfo.systemUptime
            let repeated = try await repository.load()
            repeatMS += (ProcessInfo.processInfo.systemUptime - repeatStart) * 1_000 / 3
            XCTAssertEqual(repeated, restored)
            let reused = await repository.lastLoadReusedSnapshot
            XCTAssertTrue(reused)
        }
        let repeatPeak = repeatMemory.finish()
        print("PER1006C01 fixture records=\(value.actuals.count) first_load_ms=\(loadMS) repeated_mean_ms=\(repeatMS) first_peak_mb=\(loadPeak) repeated_peak_mb=\(repeatPeak)")
        let coldRepository = try SQLitePlanRepository(databaseURL: url)
        let startupStart = ProcessInfo.processInfo.systemUptime
        let startup = try await coldRepository.loadStartupSnapshot()
        let startupMS = (ProcessInfo.processInfo.systemUptime - startupStart) * 1_000
        XCTAssertEqual(startup?.settings.healthEnabled, value.settings.healthEnabled)
        XCTAssertTrue(startup?.actuals.isEmpty == true)
        let coldStart = ProcessInfo.processInfo.systemUptime
        let coldLoaded = try await coldRepository.load()
        let coldMS = (ProcessInfo.processInfo.systemUptime - coldStart) * 1_000
        let coldReused = await coldRepository.lastLoadReusedSnapshot
        XCTAssertFalse(coldReused)
        XCTAssertEqual(coldLoaded, restored)
        print("MAP1006G01 storage records=\(value.actuals.count) startup_settings_ms=\(startupMS) cold_history_ms=\(coldMS) startup_history_records=\(startup?.actuals.count ?? -1)")

        var externalValue = coldLoaded
        externalValue.settings.healthEnabled.toggle()
        try await coldRepository.save(externalValue)
        let externalStart = ProcessInfo.processInfo.systemUptime
        let externalLoaded = try await repository.load()
        let externalMS = (ProcessInfo.processInfo.systemUptime - externalStart) * 1_000
        XCTAssertEqual(externalLoaded.actuals, value.actuals)
        XCTAssertEqual(externalLoaded.settings, externalValue.settings)

        var edited = externalLoaded
        edited.actuals[edited.actuals.count - 1].title = "합성 수정"
        let editStart = ProcessInfo.processInfo.systemUptime
        try await repository.save(edited)
        let editMS = (ProcessInfo.processInfo.systemUptime - editStart) * 1_000
        let compared = await repository.lastComparedActualRecords
        let written = await repository.lastWrittenActualRecords
        XCTAssertEqual(compared, value.actuals.count)
        XCTAssertEqual(written, 1)
        let editedReload = try await SQLitePlanRepository(databaseURL: url).load()
        XCTAssertEqual(editedReload.actuals, edited.actuals)
        print("DBP1006A01 storage records=\(value.actuals.count) external_settings_load_ms=\(externalMS) single_record_save_ms=\(editMS)")
        var directRecord = edited.actuals.last!
        directRecord.title = "직접 수정"
        let direct = try XCTUnwrap(PlanActualEdit(replacing: directRecord, at: edited.actuals.count - 1, in: edited.actuals))
        edited.actuals = direct.result
        let directStart = ProcessInfo.processInfo.systemUptime
        try await repository.save(edited, actualEdit: direct)
        let directMS = (ProcessInfo.processInfo.systemUptime - directStart) * 1_000
        let directCompared = await repository.lastComparedActualRecords
        let directWritten = await repository.lastWrittenActualRecords
        XCTAssertEqual(directCompared, 1)
        XCTAssertEqual(directWritten, 1)
        let span = TimeSpan(start: start.addingTimeInterval(60 * 60 * 24 * 50), end: start.addingTimeInterval(60 * 60 * 24 * 51))
        let dayStart = ProcessInfo.processInfo.systemUptime
        let day = try await repository.actuals(in: span, matching: edited.actuals)
        let dayMS = (ProcessInfo.processInfo.systemUptime - dayStart) * 1_000
        XCTAssertEqual(day?.count, 1_441)
        let final = try await SQLitePlanRepository(databaseURL: url).load()
        XCTAssertTrue(PlanActualStorage.exactlyEqual(final.actuals[...], edited.actuals[...]))
        print("DBP1006C01 native records=\(value.actuals.count) full_diff_ms=\(editMS) direct_edit_ms=\(directMS) compared_records=\(directCompared) written_records=\(directWritten) day_query_ms=\(dayMS) day_records=\(day?.count ?? -1)")
    }

    func testSQLiteRepositoryRetriesFileLockWithoutHoldingItAcrossSuspension()
        async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)

        let blockedLoad = Task { try await repository.load() }
        try await Task.sleep(for: .milliseconds(30))
        blockedLoad.cancel()
        do {
            _ = try await blockedLoad.value
            XCTFail("A load waiting for the file lock ignored cancellation")
        } catch is CancellationError {
            // Lock contention is retried asynchronously outside the lock.
        }

        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        let recovered = try await repository.load()
        XCTAssertEqual(recovered, .empty)
    }

    func testRepositoryCreatedBeforeDeletionCannotRestoreStaleData() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let stale = try SQLitePlanRepository(databaseURL: url)
        let deleting = try SQLitePlanRepository(databaseURL: url)
        var old = TaptionDataSnapshot.empty
        old.plans = [
            PlanRecord(
                title: "삭제 전 계획",
                span: TimeSpan(start: .now, end: .now.addingTimeInterval(60)),
                categoryID: "work"
            )
        ]
        try await stale.save(old)
        _ = try await deleting.load()

        try await deleting.deleteAll()
        do {
            try await stale.save(old)
            XCTFail("stale repository restored deleted data")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .staleGeneration)
        }
        let restored = try await deleting.load()
        XCTAssertEqual(restored, .empty)
    }

    func testRepositoryRecoversInterruptedDeletionBeforeReload() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        var old = TaptionDataSnapshot.empty
        old.plans = [
            PlanRecord(
                title: "삭제 중단 전 계획",
                span: TimeSpan(start: .now, end: .now.addingTimeInterval(60)),
                categoryID: "work"
            )
        ]
        try await repository.save(old)

        try Data("1".utf8).write(
            to: url.appendingPathExtension("generation"),
            options: [.atomic]
        )
        try Data("1".utf8).write(
            to: url.appendingPathExtension("deletion-pending"),
            options: [.atomic]
        )

        let restored = try await SQLitePlanRepository(databaseURL: url).load()

        XCTAssertEqual(restored, .empty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: url.appendingPathExtension("deletion-pending").path
            )
        )
    }

    func testMigratingRepositoryDoesNotRestoreLegacyAfterInterruptedDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "taption-plan-migrating-interrupted-delete-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            TaptionDataDeletionFence.finishRepositoryDeletion()
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let primaryURL = directory.appendingPathComponent("primary.sqlite")
        let legacyURL = directory.appendingPathComponent("legacy.json")
        let primary = try SQLitePlanRepository(databaseURL: primaryURL)
        let legacy = FilePlanRepository(fileURL: legacyURL)
        var old = TaptionDataSnapshot.empty
        old.plans = [
            PlanRecord(
                title: "legacy stale 계획",
                span: TimeSpan(start: .now, end: .now.addingTimeInterval(60)),
                categoryID: "work"
            )
        ]
        try await primary.save(old)
        try await legacy.save(old)

        try await primary.deleteAll()
        TaptionDataDeletionFence.beginRepositoryDeletion()

        let repository = MigratingPlanRepository(primary: primary, legacy: legacy)
        let restored = try await repository.load()
        let legacyRestored = try await FilePlanRepository(
            fileURL: legacyURL
        ).load()

        XCTAssertEqual(restored, .empty)
        XCTAssertEqual(legacyRestored, .empty)
        XCTAssertFalse(TaptionDataDeletionFence.repositoryDeletionIsPending())
    }

    func testRepositoryRejectsSaveWhileGlobalDeletionFenceIsActive() async throws {
        let deletionFence = DataDeletionFenceTestFixture()
        defer { deletionFence.restore() }
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)
        let generation = TaptionDataDeletionFence.advance()
        defer { TaptionDataDeletionFence.finish(generation: generation) }

        do {
            try await repository.save(.empty)
            XCTFail("repository wrote while user data deletion was active")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .staleGeneration)
        }

        try await repository.deleteAll()
        TaptionDataDeletionFence.finish(generation: generation)
        var replacement = TaptionDataSnapshot.empty
        replacement.categories = CategoryCatalog.builtIn
        try await repository.save(replacement)
        let saved = try await repository.load()
        XCTAssertEqual(
            saved.categories,
            CategoryCatalog.builtIn
        )
    }

    func testSeparateRepositoryInstancesAllocateDistinctRevisions() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let first = try SQLitePlanRepository(databaseURL: url)
        let second = try SQLitePlanRepository(databaseURL: url)

        async let firstSave: Void = first.save(.empty)
        async let secondSave: Void = second.save(.empty)
        _ = try await (firstSave, secondSave)

        let store = try TaptionPlanDayStore(url: url, allowsUndatedSnapshots: true)
        let metadata = try await store.snapshot(
            domain: "plan.metadata",
            day: .init(year: 0, month: 0, day: 0)
        )
        XCTAssertEqual(metadata?.revision, 2)
    }

    func testRepositoryResolverKeepsAppGroupSQLiteWithoutLegacyStores() async throws {
        var expected = TaptionDataSnapshot.empty
        expected.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        expected.categories = CategoryCatalog.builtIn
        let selection = PlanRepositoryResolver.resolve(
            appGroupSQLite: InMemoryPlanRepository(snapshot: expected),
            appGroupFile: nil,
            applicationSupportSQLite: nil,
            applicationSupportFile: nil
        )

        let loaded = try await selection.repository.load()
        XCTAssertEqual(selection.source, "sqlite-app-group")
        XCTAssertEqual(loaded, expected)
    }

    func testRepositoryResolverUsesDurableFileWhenSQLiteIsUnavailable() async throws {
        var expected = TaptionDataSnapshot.empty
        expected.updatedAt = Date(timeIntervalSince1970: 1_800_000_001)
        let selection = PlanRepositoryResolver.resolve(
            appGroupSQLite: nil,
            appGroupFile: InMemoryPlanRepository(snapshot: expected),
            applicationSupportSQLite: nil,
            applicationSupportFile: nil
        )

        let loaded = try await selection.repository.load()
        XCTAssertEqual(selection.source, "file-app-group")
        XCTAssertEqual(loaded, expected)
    }

    func testRepositoryResolverFailsClosedWhenEveryDurableStoreIsUnavailable() async {
        let selection = PlanRepositoryResolver.resolve(
            appGroupSQLite: nil,
            appGroupFile: nil,
            applicationSupportSQLite: nil,
            applicationSupportFile: nil
        )

        XCTAssertEqual(selection.source, "unavailable")
        do {
            _ = try await selection.repository.load()
            XCTFail("unavailable repository unexpectedly loaded")
        } catch {
            XCTAssertEqual(
                error as? PlanRepositoryAvailabilityError,
                .unavailable
            )
        }
        do {
            try await selection.repository.save(.empty)
            XCTFail("unavailable repository unexpectedly saved")
        } catch {
            XCTAssertEqual(
                error as? PlanRepositoryAvailabilityError,
                .unavailable
            )
        }
        do {
            try await selection.repository.deleteAll()
            XCTFail("unavailable repository unexpectedly deleted")
        } catch {
            XCTAssertEqual(
                error as? PlanRepositoryAvailabilityError,
                .unavailable
            )
        }
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-plan-repository-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm", ".lock", ".generation", ".deletion-pending"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}

private final class RepositoryFootprintProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let timer = DispatchSource.makeTimerSource(
        queue: DispatchQueue(label: "taption.repository.memory-probe", qos: .utility)
    )
    private var peakMB: Double = 0

    init() {
        sample()
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    func finish() -> Double {
        timer.cancel()
        sample()
        return lock.withLock { peakMB }
    }

    deinit { timer.cancel() }

    private func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let megabytes = Double(info.phys_footprint) / 1_048_576
        lock.withLock { peakMB = max(peakMB, megabytes) }
    }
}

private actor BlockingPlanRepository: PlanDataRepository {
    private var value = TaptionDataSnapshot.empty
    private var saveStarted = false
    private var shouldBlockNextSave = true
    private var pendingSave: CheckedContinuation<Void, Never>?

    func load() async throws -> TaptionDataSnapshot {
        value
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        saveStarted = true
        if shouldBlockNextSave {
            shouldBlockNextSave = false
            await withCheckedContinuation { continuation in
                pendingSave = continuation
            }
        }
        value = snapshot
    }

    func waitUntilSaveStarted() async {
        for _ in 0..<100 {
            if saveStarted { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseSave() {
        pendingSave?.resume()
        pendingSave = nil
    }
}

private actor FailOncePlanRepository: PlanDataRepository {
    private var value = TaptionDataSnapshot.empty
    private var shouldFailNextSave = true
    private var saveAttempts = 0

    func load() async throws -> TaptionDataSnapshot {
        value
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        saveAttempts += 1
        if shouldFailNextSave {
            shouldFailNextSave = false
            throw RepositoryError.cloudPayloadMissing
        }
        value = snapshot
    }

    func deleteAll() async throws {
        value = .empty
    }

    func waitUntilSaveAttempted() async {
        for _ in 0..<100 {
            if saveAttempts > 0 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor IndexedRepositoryProbe: PlanDataRepository {
    let primary: SQLitePlanRepository
    private(set) var queryCounts: [Int] = []
    private(set) var explicitEdits = 0
    init(primary: SQLitePlanRepository) { self.primary = primary }
    func load() async throws -> TaptionDataSnapshot { try await primary.load() }
    func save(_ snapshot: TaptionDataSnapshot) async throws { try await primary.save(snapshot) }
    func save(_ snapshot: TaptionDataSnapshot, actualEdit: PlanActualEdit?) async throws {
        if actualEdit != nil { explicitEdits += 1 }
        try await primary.save(snapshot, actualEdit: actualEdit)
    }
    func actuals(in span: TimeSpan, matching source: [ActualRecord]) async throws -> [ActualRecord]? {
        let result = try await primary.actuals(in: span, matching: source)
        queryCounts.append(result?.count ?? -1)
        return result
    }
    func deleteAll() async throws { try await primary.deleteAll() }
}
