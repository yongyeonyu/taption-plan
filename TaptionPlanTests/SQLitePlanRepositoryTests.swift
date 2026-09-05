import Foundation
import XCTest
@testable import TaptionPlan
import TaptionPlanCore

final class SQLitePlanRepositoryTests: XCTestCase {
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

        let store = try TaptionPlanDayStore(url: url)
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

        let store = try TaptionPlanDayStore(url: url)
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
        let store = try TaptionPlanDayStore(url: url)
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
    }

    func testMissingDatabaseLoadsEmpty() async throws {
        let url = temporaryURL()
        defer { removeDatabase(at: url) }
        let repository = try SQLitePlanRepository(databaseURL: url)

        let value = try await repository.load()

        XCTAssertEqual(value, .empty)
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

        let store = try TaptionPlanDayStore(url: url)
        let metadata = try await store.snapshot(
            domain: "plan.metadata",
            day: .init(year: 0, month: 0, day: 0)
        )
        XCTAssertEqual(metadata?.revision, 2)
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
