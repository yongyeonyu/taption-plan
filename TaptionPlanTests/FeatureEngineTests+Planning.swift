import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

extension FeatureEngineTests {
    func testSchedulePreviewShowsOnlyMemosWithinThirtyMinutesOfTheSidebarTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))!
        func sticker(_ title: String, hour: Int, minute: Int, placement: MapStickerPlacement = .schedule,
                     dayOffset: Int = 0) -> MapSticker {
            let date = calendar.date(byAdding: .day, value: dayOffset, to: day)!
                .addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
            return MapSticker(title: title, placement: placement, occurredAt: date)
        }
        let early = sticker("이른", hour: 9, minute: 0)
        let near = sticker("근처", hour: 14, minute: 20)
        let map = sticker("지도용", hour: 14, minute: 30, placement: .map)
        let otherDay = sticker("다음 날", hour: 14, minute: 30, dayOffset: 1)
        let all = [early, near, map, otherDay]
        let now = day.addingTimeInterval(14 * 3_600)
        XCTAssertEqual(MapHomeMemoPreviewPolicy.nearest(in: all, at: now, selectedDate: day, calendar: calendar)?.title, "근처")
        // 31분 밖이면 안 보인다.
        XCTAssertNil(MapHomeMemoPreviewPolicy.nearest(
            in: all, at: day.addingTimeInterval(14 * 3_600 + 52 * 60), selectedDate: day, calendar: calendar))
        // 정확히 30분 경계는 보인다.
        XCTAssertNotNil(MapHomeMemoPreviewPolicy.nearest(
            in: all, at: day.addingTimeInterval(13 * 3_600 + 50 * 60), selectedDate: day, calendar: calendar))
        // 닫은 메모는 다시 보이지 않고, 지도 배치 스티커·다른 날 메모는 대상이 아니다.
        XCTAssertNil(MapHomeMemoPreviewPolicy.nearest(
            in: all, at: now, selectedDate: day, dismissed: [near.id], calendar: calendar))
        // 둘이 가까우면 더 가까운 것.
        let closer = sticker("더 가까운", hour: 14, minute: 5)
        XCTAssertEqual(MapHomeMemoPreviewPolicy.nearest(
            in: all + [closer], at: now, selectedDate: day, calendar: calendar)?.title, "더 가까운")
    }

    /// 메모는 별도 파일에 저장하고, 옛 파일에 남아 있던 메모는 한 번만 옮긴다.
    func testMemosMoveToTheirOwnStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaptionStoreV2(url: directory.appendingPathComponent(TaptionStoreV2.fileName))
        let memoStore = try TaptionStoreV2(
            url: directory.appendingPathComponent(TaptionStoreV2.memoFileName)
        )
        let memo = ActionMemo(
            occurredAt: Date(timeIntervalSince1970: 900),
            kind: .idea,
            text: "메모 본문"
        )
        var snapshot = TaptionDataSnapshot.empty
        snapshot.updatedAt = Date(timeIntervalSince1970: 1_000)
        snapshot.memos = [memo]

        // 1) 예전 방식(메모를 본 저장소에 씀).
        let legacy = TaptionStoreRepository(store: store)
        try await legacy.save(snapshot)
        let legacyCount = try await store.recordCount(kind: "memo")
        let emptyMemoCount = try await memoStore.recordCount(kind: "memo")
        XCTAssertEqual(legacyCount, 1)
        XCTAssertEqual(emptyMemoCount, 0)

        // 2) 메모 저장소를 붙이면 읽을 때 옛 행을 옮기고, 본 저장소에는 남기지 않는다.
        let repository = TaptionStoreRepository(store: store, memoStore: memoStore)
        let migrated = try await repository.load()
        XCTAssertEqual(migrated.memos.map(\.id), [memo.id])
        let memoCountAfterMigration = try await memoStore.recordCount(kind: "memo")
        let mainCountAfterMigration = try await store.recordCount(kind: "memo")
        XCTAssertEqual(memoCountAfterMigration, 1)
        XCTAssertEqual(mainCountAfterMigration, 0)

        // 3) 이후 저장은 메모 파일로만 간다.
        var edited = snapshot
        edited.updatedAt = Date(timeIntervalSince1970: 2_000)
        edited.memos = [
            memo,
            ActionMemo(
                occurredAt: Date(timeIntervalSince1970: 1_500),
                kind: .blocker,
                text: "두 번째"
            ),
        ]
        try await repository.save(edited)
        let memoCountAfterEdit = try await memoStore.recordCount(kind: "memo")
        let mainCountAfterEdit = try await store.recordCount(kind: "memo")
        XCTAssertEqual(memoCountAfterEdit, 2)
        XCTAssertEqual(mainCountAfterEdit, 0)

        // 4) 메모를 지우면 메모 파일에서 지워진다.
        var deleted = edited
        deleted.updatedAt = Date(timeIntervalSince1970: 3_000)
        deleted.memos = [edited.memos[1]]
        try await repository.save(deleted)
        let reloaded = try await repository.load()
        XCTAssertEqual(reloaded.memos.map(\.id), [edited.memos[1].id])
    }

    /// 달력 합계는 확정한 날을 다시 계산하지 않고 저장된 값을 쓴다(원본을 백업으로 옮긴 달도 값이 나온다).
    func testCalendarTotalsUseSealedDayValues() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day = calendar.startOfDay(for: now)
        let digest = TaptionSealedDayBuilder.make(
            day: day,
            sealedAt: now,
            sourceFingerprint: nil,
            categories: ["work": 7_200, "unconfirmed": 600],
            metrics: ["distance": 4_000],
            steps: 0,
            distanceMeters: 4_000,
            readings: [],
            weather: nil,
            memoCount: 0,
            actualCount: 0,
            travelCount: 0,
            placeCount: 0
        )
        let totals = MapHomeCalendarTimeTotalsPolicy.totals(
            actuals: [],
            travel: [],
            stays: [],
            placeKinds: [:],
            month: day,
            asOf: now,
            calendar: calendar,
            sealed: [day: digest]
        )
        XCTAssertEqual(totals[day]?["work"], 7_200)
        XCTAssertEqual(totals[day]?["distance"], 4_000)
        // 미확인은 달력 지표로 세지 않는다.
        XCTAssertNil(totals[day]?["unconfirmed"])
    }

    func testCurrentIslandUsesConfirmedAndSharedCategoryWithTimeBoundaries() {
        let now = Date()
        let automatic = ActualRecord(planID: nil, title: "걷기", categoryID: "activity", startedAt: now.addingTimeInterval(-60), source: .motion)
        let sleep = ActualRecord(planID: nil, title: "수면", categoryID: "sleep", startedAt: now.addingTimeInterval(-120), endedAt: now.addingTimeInterval(60), source: .manual)
        XCTAssertEqual(TaptionCurrentActivityPolicy.categoryID(actuals: [automatic], plans: [], at: now), "movement")
        XCTAssertEqual(TaptionCurrentActivityPolicy.categoryID(actuals: [sleep, automatic], plans: [], at: now), "sleep")
        XCTAssertEqual(TaptionCurrentActivityPolicy.categoryID(actuals: [automatic, sleep], plans: [], at: now), "sleep")
        XCTAssertEqual(TaptionCurrentActivityPolicy.categoryID(actuals: [sleep, automatic], plans: [], at: now.addingTimeInterval(60)), "movement")
        XCTAssertNil(TaptionCurrentActivityPolicy.categoryID(actuals: [sleep], plans: [], at: now.addingTimeInterval(-121)))
    }

    @MainActor
    func testSensorTimelineCancellationKeepsErrorButReadFailureIsReported() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try SensorReadingArchive(
            fileURL: directory.appendingPathComponent("readings.jsonl")
        )
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: .empty),
            sensorService: AppleSensorDataService(
                archive: archive,
                archivedReadingsLoader: { _ in
                    throw CocoaError(.fileReadCorruptFile)
                }
            ),
            cloudSyncService: nil
        )
        model.userFacingError = "기존 오류"
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await model.refreshSensorTimeline()
        }
        let cancellationResult = await cancelled.value
        XCTAssertFalse(cancellationResult)
        XCTAssertEqual(model.userFacingError, "기존 오류")

        model.userFacingError = nil
        let failureResult = await model.refreshSensorTimeline()
        XCTAssertFalse(failureResult)
        XCTAssertTrue(
            model.userFacingError?.hasPrefix(
                AppModelMessage.locationReadFailed("").lead()
            ) == true
        )
    }

    @MainActor
    func testRepositoryLoadFailureRejectsInMemoryEdits() async {
        let model = AppModel(
            repository: UnavailablePlanRepository(),
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()
        let fallback = model.snapshot
        let revision = model.snapshotRevision

        let planID = model.addPlan(
            title: "저장되지 않을 계획",
            categoryID: "activity",
            startAt: .now,
            duration: 3_600
        )
        let blockedPoint = GeoPoint(
            latitude: 37.5,
            longitude: 126.9,
            altitude: 20,
            horizontalAccuracy: 8,
            verticalAccuracy: 10
        )
        XCTAssertFalse(model.addMapUserActivityCategory(
            title: "저장되지 않을 행동",
            systemImage: "gamecontroller.fill",
            hex: "#29A383"
        ))
        XCTAssertNil(model.addMemo(
            text: "저장되지 않을 메모",
            kind: .idea,
            categoryID: "activity",
            on: .now
        ))
        XCTAssertNil(model.addMapMemo(
            text: "저장되지 않을 지도 메모",
            kind: .idea,
            mapPoint: blockedPoint,
            occurredAt: .now,
            shouldPersist: false
        ))
        XCTAssertNil(model.addCustomCategory(
            name: "저장되지 않을 대분류",
            icon: .memo,
            lightHex: "#29A383"
        ))
        XCTAssertNil(model.addMapSticker(
            title: "저장되지 않을 스티커",
            placement: .map,
            point: blockedPoint,
            planID: nil,
            occurredAt: .now
        ))
        XCTAssertNil(model.addUserTransitLocation(
            name: "저장되지 않을 공항",
            kind: .airport,
            latitude: blockedPoint.latitude,
            longitude: blockedPoint.longitude
        ))
        model.setReduceMotion(!fallback.settings.reduceMotion)

        XCTAssertNil(planID)
        XCTAssertEqual(model.snapshot, fallback)
        XCTAssertEqual(model.snapshotRevision, revision)
        XCTAssertTrue(
            AppModelMessage.isDataLoadFailure(model.userFacingError)
        )
        do {
            try await model.protectCurrentDataWithBiometrics()
            XCTFail("Fallback snapshot must not replace biometric data")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testBackgroundFlushDoesNotRebuildReviewReports() async throws {
        let start = makeDate(2026, 8, 15, 9)
        let actual = ActualRecord(
            planID: nil,
            title: "업무",
            categoryID: "work",
            startedAt: start,
            endedAt: start.addingTimeInterval(hour),
            source: .manual
        )
        var stored = TaptionDataSnapshot.empty
        stored.categories = CategoryCatalog.builtIn
        stored.actuals = [actual]
        stored.yearlyReports = []
        stored.settings.locationEnabled = false
        stored.settings.weatherEnabled = false
        stored.settings.healthEnabled = false
        let repository = InMemoryPlanRepository(snapshot: stored)
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()
        XCTAssertTrue(model.snapshot.yearlyReports.isEmpty)

        await model.sceneEnteredBackground()

        XCTAssertTrue(model.snapshot.yearlyReports.isEmpty)
        let persisted = try await repository.load()
        XCTAssertTrue(persisted.yearlyReports.isEmpty)
    }

    /// 저장소 적재가 도는 동안에는 90%가 천장이다. 예전에는 목표(0.86)에 닿은 뒤
    /// 0.97까지 밀려 올라가, 데이터를 읽는 내내 "97%에서 멈춘" 것처럼 보였다.
    func testLaunchProgressGoalStopsAtTheCapWhileTheStoreIsLoading() {
        XCTAssertEqual(
            AppShellInitialLaunchProgressMath.crawlCap(bootstrapped: false),
            0.90,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            AppShellInitialLaunchProgressMath.crawlCap(bootstrapped: true),
            0.97,
            accuracy: 0.000_001
        )
        // 0.96·0.98은 적재가 끝나기 전에 불린다. 목표가 천장 위여도 90%까지만 간다.
        for target in [0.96, 0.98] {
            XCTAssertEqual(
                AppShellInitialLaunchProgressMath.goal(
                    current: 0.60,
                    target: target,
                    bootstrapped: false
                ),
                0.90,
                accuracy: 0.000_001
            )
        }
        // 목표가 천장 아래면 먼저 목표까지 간다. 천장은 그 다음 박자부터 걸린다.
        XCTAssertEqual(
            AppShellInitialLaunchProgressMath.goal(
                current: 0.60,
                target: 0.86,
                bootstrapped: false
            ),
            0.86,
            accuracy: 0.000_001
        )
        // 적재가 끝나면 지도 첫 화면만 남으므로 97%까지 기어갈 수 있다.
        XCTAssertEqual(
            AppShellInitialLaunchProgressMath.goal(
                current: 0.92,
                target: 0.98,
                bootstrapped: true
            ),
            0.97,
            accuracy: 0.000_001
        )
        // 1.0은 스플래시를 걷는 순간이다. 천장에 막히면 안 된다.
        XCTAssertEqual(
            AppShellInitialLaunchProgressMath.goal(
                current: 0.97,
                target: 1,
                bootstrapped: false
            ),
            1,
            accuracy: 0.000_001
        )
    }

    func testTimelineHierarchyIsSeparateFromRecordSource() {
        let span = TimeSpan(
            start: makeDate(2026, 8, 8, 9, 0),
            end: makeDate(2026, 8, 8, 10, 0)
        )
        let routine = PlanRecord(
            title: "루틴: 운동",
            span: span,
            categoryID: "activity",
            middleCategoryName: "운동"
        )
        let detailedActivity = ActualRecord(
            planID: nil,
            title: "깊은 수면",
            categoryID: "sleep",
            startedAt: span.start,
            endedAt: span.end,
            source: .healthKit,
            behavior: "deepSleep"
        )

        XCTAssertEqual(routine.semanticLevel, .activity)
        XCTAssertEqual(routine.sourceKind, .routine)
        XCTAssertEqual(detailedActivity.semanticLevel, .activity)
        XCTAssertEqual(detailedActivity.sourceKind, .automatic)
    }

    func testActivitySectionOverrideIDsAreStableAcrossRepeatedSave() {
        let span = TimeSpan(
            start: makeDate(2026, 8, 12, 9, 0),
            end: makeDate(2026, 8, 12, 10, 0)
        )
        let sourceID = UUID()
        let request = ActivitySectionEditRequest(
            sourceIDs: [sourceID],
            originalSpan: span,
            originalOption: phaseOption("work", title: "업무"),
            mode: .replace(
                editedSpan: span,
                option: phaseOption("eating", title: "식사")
            )
        )

        XCTAssertEqual(
            ActivitySectionOverrideEngine.records(for: request).map(\.id),
            ActivitySectionOverrideEngine.records(for: request).map(\.id)
        )
    }

    @MainActor
    func testSelectedDateAssignmentWithinSameCalendarDayDoesNotRefresh()
        async {
        let calendar = Calendar.autoupdatingCurrent
        let selectedDate = makeDate(2026, 8, 17, 12)
        let model = await makeActiveIntegrationModel(
            selectedDate: selectedDate
        )
        defer { TaptionPlanDiagnosticsLogger.shared.clear() }

        model.selectedDate = calendar.startOfDay(for: selectedDate)
            .addingTimeInterval(hour)
        try? await Task.sleep(for: .milliseconds(350))

        XCTAssertTrue(integrationRefreshStartLines().isEmpty)

        await model.sceneEnteredBackground()
    }

    @MainActor
    func testPlanDayDataSnapshotRawRefreshReadsNewArchiveSampleWithoutTimelineRefresh()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "plan-day-raw-refresh-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: directory)
            TaptionPlanDiagnosticsLogger.shared.clear()
        }
        let date = makeDate(2026, 8, 24, 12)
        let archive = try SensorReadingArchive(
            fileURL: directory.appendingPathComponent("readings.jsonl")
        )
        let sensorService = AppleSensorDataService(archive: archive)
        let model = AppModel(
            repository: InMemoryPlanRepository(),
            sensorService: sensorService,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()
        TaptionPlanDiagnosticsLogger.shared.clear()

        let reading = SensorReading(
            timestamp: date.addingTimeInterval(hour),
            point: GeoPoint(
                latitude: 37.5,
                longitude: 127,
                altitude: 30,
                horizontalAccuracy: 8,
                verticalAccuracy: 10
            ),
            locationFixQuality: .precise,
            gpsAvailable: true
        )
        let before = await model.planDayDataSnapshot(
            for: date,
            forceReload: false
        )
        XCTAssertFalse(before.readings.contains { $0.id == reading.id })

        try await archive.append(
            reading,
            now: reading.timestamp.addingTimeInterval(hour)
        )
        let after = await model.planDayDataSnapshot(
            for: date,
            forceReload: false,
            refreshRawReadings: true
        )

        XCTAssertTrue(after.readings.contains { $0.id == reading.id })
        XCTAssertFalse(
            TaptionPlanDiagnosticsLogger.shared
                .combinedLog()
                .contains("sensor_timeline_refresh_started")
        )
    }

    func testCloudSnapshotKeepsExternalCalendarDataOnDevice() {
        var snapshot = TaptionDataSnapshot.empty
        snapshot.calendarEvents = [
            CalendarRecord(
                id: "external-event",
                calendarID: "google-calendar",
                title: "Private meeting",
                span: TimeSpan(
                    start: makeDate(2026, 8, 12, 9, 0),
                    end: makeDate(2026, 8, 12, 10, 0)
                ),
                isAllDay: false,
                calendarTitle: "Work",
                calendarColorHex: nil,
                sourceTitle: "Google"
            )
        ]

        XCTAssertTrue(
            AppModel.cloudPortableSnapshot(snapshot).calendarEvents.isEmpty
        )
        XCTAssertEqual(snapshot.calendarEvents.count, 1)
    }

    @MainActor
    func testConfirmedUnconfirmedCategorySurvivesReloadAndLateAutomaticRecord()
        async throws {
        let day = makeDate(2026, 8, 12)
        let span = TimeSpan(
            start: day.addingTimeInterval(9 * hour),
            end: day.addingTimeInterval(10 * hour)
        )
        var stored = TaptionDataSnapshot.empty
        stored.settings.locationEnabled = false
        stored.settings.weatherEnabled = false
        stored.settings.healthEnabled = false
        let repository = InMemoryPlanRepository(snapshot: stored)
        let firstModel = AppModel(
            repository: repository,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await firstModel.bootstrap()

        let save = await firstModel.saveActivitySectionEdit(
            ActivitySectionEditRequest(
                sourceIDs: [],
                originalSpan: span,
                originalOption: ActivitySectionOverrideEngine.unconfirmedOption,
                mode: .replace(
                    editedSpan: span,
                    option: phaseOption("work", title: "업무")
                )
            )
        )
        XCTAssertNotNil(save)

        let reopenedModel = AppModel(
            repository: repository,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await reopenedModel.bootstrap()
        let lateAutomatic = ActualRecord(
            planID: nil,
            title: "자동 활동",
            categoryID: "activity",
            startedAt: day.addingTimeInterval(9.25 * hour),
            endedAt: day.addingTimeInterval(9.75 * hour),
            source: .healthKit,
            confidence: .high,
            evidence: ["HealthKit"]
        )
        let rail = MapHomeTimeRailSegmentEngine.segments(
            from: reopenedModel.snapshot.actuals + [lateAutomatic],
            travel: reopenedModel.snapshot.travel,
            on: day,
            asOf: day.addingTimeInterval(24 * hour),
            calendar: utcCalendar
        )

        XCTAssertEqual(
            MapHomeTimeRailSegmentEngine.segment(
                at: 9 * 60 + 30,
                in: rail
            )?.categoryID,
            "work"
        )
        XCTAssertFalse(rail.contains {
            $0.categoryID == "unconfirmed"
                && $0.startMinute < 10 * 60
                && $0.endMinute > 9 * 60
        })
    }

    @MainActor
    func testUserPlanUndoRedo() async throws {
        let day = makeDate(2026, 8, 12)
        var stored = TaptionDataSnapshot.empty
        stored.updatedAt = day
        stored.settings.locationEnabled = false
        stored.settings.weatherEnabled = false
        stored.settings.healthEnabled = false
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: stored),
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()

        let planID = model.addPlan(
            title: "집중 작업",
            categoryID: "work",
            startAt: day.addingTimeInterval(9 * hour),
            duration: hour
        )
        let savedID = try XCTUnwrap(planID)
        XCTAssertTrue(model.canUndo)
        model.undoLastUserEdit()
        XCTAssertFalse(model.snapshot.plans.contains { $0.id == savedID })
        XCTAssertTrue(model.canRedo)
        model.redoLastUserEdit()
        XCTAssertEqual(
            model.snapshot.plans.first(where: { $0.id == savedID })?.title,
            "집중 작업"
        )
        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)
    }

    func testReviewCoverageMakesPastDayExactlyTwentyFourHours() {
        let day = TimeSpan(
            start: makeDate(2026, 8, 4),
            end: makeDate(2026, 8, 5)
        )
        let activity = ActualRecord(
            planID: nil,
            title: "생활",
            categoryID: "routine",
            startedAt: day.start,
            endedAt: day.start.addingTimeInterval(12 * hour),
            source: .location
        )
        let sleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: day.start.addingTimeInterval(2 * hour),
            endedAt: day.start.addingTimeInterval(8 * hour),
            source: .healthKit
        )
        let movement = ActualRecord(
            planID: nil,
            title: "자동차",
            categoryID: "movement",
            startedAt: day.start.addingTimeInterval(10 * hour),
            endedAt: day.start.addingTimeInterval(14 * hour),
            source: .motion
        )

        let records = ReviewCoverageEngine.records(
            actuals: [activity, sleep, movement],
            in: [day],
            asOf: day.end
        )
        XCTAssertEqual(
            records.reduce(0) { $0 + $1.span(asOf: day.end).duration },
            24 * hour
        )
        XCTAssertEqual(
            records.filter { $0.categoryID == "sleep" }
                .reduce(0) { $0 + $1.span(asOf: day.end).duration },
            6 * hour
        )
        XCTAssertEqual(
            records.filter {
                $0.categoryID == ReviewCoverageEngine.unconfirmedCategoryID
            }.reduce(0) { $0 + $1.span(asOf: day.end).duration },
            10 * hour
        )
        let ordered = records.map { $0.span(asOf: day.end) }
            .sorted { $0.start < $1.start }
        for pair in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.end, pair.1.start)
        }
    }

    func testReviewCoverageFillsCurrentDayOnlyThroughNow() {
        let day = TimeSpan(
            start: makeDate(2026, 8, 6),
            end: makeDate(2026, 8, 7)
        )
        let now = day.start.addingTimeInterval(11 * hour + 15 * 60)
        let records = ReviewCoverageEngine.records(
            actuals: [],
            in: [day],
            asOf: now
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].title, "미확인")
        XCTAssertEqual(records[0].span(asOf: now).duration, 11 * hour + 15 * 60)
        XCTAssertEqual(records[0].endedAt, now)
    }

    func testAutomaticTimelineDoesNotForecastPastNow() {
        let now = makeDate(2026, 8, 3, 12)
        let ongoing = ActualRecord(
            planID: nil,
            title: "정지·휴식",
            categoryID: "activity",
            startedAt: now.addingTimeInterval(-hour),
            endedAt: now.addingTimeInterval(hour),
            source: .motion
        )
        let future = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "activity",
            startedAt: now.addingTimeInterval(10 * 60),
            endedAt: now.addingTimeInterval(20 * 60),
            source: .appleWatch
        )

        let visible = AutomaticRecordTimelineEngine.activities(
            from: [ongoing, future],
            inside: TimeSpan(
                start: now.addingTimeInterval(-2 * hour),
                end: now.addingTimeInterval(2 * hour)
            ),
            asOf: now
        )

        XCTAssertEqual(visible.map(\.id), [ongoing.id])
        XCTAssertEqual(visible[0].endedAt, now)
    }

    func testGanttViewportStopsAtOneMinuteForEveryTimelineDuration() {
        let durations: [TimeInterval] = [
            24 * 60 * 60,
            7 * 24 * 60 * 60,
            31 * 24 * 60 * 60,
            366 * 24 * 60 * 60,
        ]

        for duration in durations {
            let minimumLength = GanttViewport.oneMinuteMinimumLength(
                for: duration
            )
            let zoomed = GanttViewport.full.magnifying(
                by: 1_000_000,
                anchor: 0.5,
                minimumLength: minimumLength
            )

            XCTAssertEqual(
                duration * zoomed.length,
                60,
                accuracy: 0.001
            )
        }
    }

    func testScheduleDragSnapsToFifteenMinutes() throws {
        let base = makeDate(2026, 7, 30, 9, 0)
        let plan = PlanRecord(
            title: "초안",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "project"
        )
        let moved = try ScheduleEditEngine.move(plan, by: 22 * 60)
        XCTAssertEqual(moved.span.start.timeIntervalSince(base), 15 * 60)
    }

    func testQuickActionsPreservePlanAndCreateSeparateActual() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let plan = PlanRecord(
            title: "러닝",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "exercise"
        )
        let started = QuickActionEngine.start(plan: plan, actuals: [], at: base)
        XCTAssertEqual(started.plan.span, plan.span)
        XCTAssertEqual(started.plan.status, .running)
        XCTAssertEqual(started.actuals.count, 1)

        let completed = QuickActionEngine.complete(
            plan: started.plan,
            actuals: started.actuals,
            at: base.addingTimeInterval(40 * 60)
        )
        XCTAssertEqual(completed.plan.status, .completed)
        XCTAssertEqual(completed.actuals[0].span().duration, 40 * 60)
        XCTAssertEqual(completed.plan.span.duration, hour)
    }

    func testReviewDescribesDifferenceInsteadOfScoring() {
        let base = makeDate(2026, 7, 27)
        let plan = PlanRecord(
            title: "학습",
            span: TimeSpan(start: base, end: base.addingTimeInterval(2 * hour)),
            categoryID: "study"
        )
        let actual = ActualRecord(
            planID: plan.id,
            title: plan.title,
            categoryID: "study",
            startedAt: base,
            endedAt: base.addingTimeInterval(hour),
            source: .manual
        )
        let report = ReviewEngine(calendar: utcCalendar).report(
            for: .week,
            containing: base,
            plans: [plan],
            actuals: [actual],
            weather: [],
            photos: [],
            memos: [],
            asOf: base.addingTimeInterval(hour)
        )
        XCTAssertEqual(report.plannedDuration, 2 * hour)
        XCTAssertEqual(report.actualDuration, hour)
    }

    func testReviewArchiveStoresDailyWeeklyAndMonthlyDataInsideYear() throws {
        let first = makeDate(2026, 1, 2, 9)
        let second = makeDate(2026, 1, 8, 10)
        let asOf = makeDate(2026, 1, 11, 12)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.actuals = [
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: first,
                endedAt: first.addingTimeInterval(hour),
                source: .manual
            ),
            ActualRecord(
                planID: nil,
                title: "운동",
                categoryID: "exercise",
                startedAt: second,
                endedAt: second.addingTimeInterval(2 * hour),
                source: .manual
            ),
        ]

        let archives = try ReviewReportArchiveEngine.refreshed(
            snapshot: snapshot,
            asOf: asOf,
            calendar: utcCalendar
        )

        XCTAssertEqual(archives.count, 1)
        XCTAssertEqual(archives[0].months.count, 1)
        XCTAssertGreaterThanOrEqual(archives[0].months[0].weeks.count, 2)
        XCTAssertEqual(
            Set(archives[0].months[0].dayIDs),
            Set(archives[0].days.map(\.id))
        )
    }

    func testReviewArchiveRefreshChecksCancellationDuringLongSourceSpan() {
        let start = makeDate(2026, 1, 1)
        let end = makeDate(2030, 1, 1)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.actuals = [
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: start,
                endedAt: end,
                source: .manual
            )
        ]
        var cancellationChecks = 0

        XCTAssertThrowsError(
            try ReviewReportArchiveEngine.refreshed(
                snapshot: snapshot,
                asOf: end,
                calendar: utcCalendar,
                cancellationCheck: {
                    cancellationChecks += 1
                    if cancellationChecks == 20 {
                        throw CancellationError()
                    }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancellationChecks, 20)
    }

    func testReviewArchiveFingerprintRejectsUnencodableSourceInsteadOfReusingCache()
        throws
    {
        let start = makeDate(2026, 2, 3, 9)
        let asOf = makeDate(2026, 2, 4)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.actuals = [
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: start,
                endedAt: start.addingTimeInterval(hour),
                source: .manual
            )
        ]
        snapshot.yearlyReports = try ReviewReportArchiveEngine.refreshed(
            snapshot: snapshot,
            asOf: asOf,
            calendar: utcCalendar
        )
        snapshot.yearlyReports[0].days[0].sourceFingerprint =
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        snapshot.weather = [
            WeatherContext(
                observedAt: start,
                condition: "invalid",
                symbolName: "questionmark",
                temperatureCelsius: .nan
            )
        ]

        XCTAssertThrowsError(
            try ReviewReportArchiveEngine.refreshed(
                snapshot: snapshot,
                asOf: asOf,
                calendar: utcCalendar
            )
        )
    }

    func testAllCustomCategoryRequirementsExist() throws {
        XCTAssertEqual(CategoryCatalog.builtIn.count, 32)
        XCTAssertGreaterThanOrEqual(CategoryIcon.allCases.count, 32)
        XCTAssertEqual(
            Set(CategoryCatalog.builtIn.map(\.icon)).count,
            CategoryCatalog.builtIn.count,
            "기본 대분류 아이콘은 서로 겹치지 않아야 합니다."
        )
        let custom = try CategoryCatalog.makeCustom(
            name: "봉사",
            icon: .family,
            lightHex: "AABBCC",
            existing: CategoryCatalog.builtIn
        )
        XCTAssertFalse(custom.isBuiltIn)
        XCTAssertEqual(custom.lightHex, "#AABBCC")
    }

    func testEveryBuiltInCategoryProvidesMiddleCategorySuggestions() {
        XCTAssertEqual(
            Set(CategoryHierarchyCatalog.middleSuggestionsByCategoryID.keys),
            Set(CategoryCatalog.builtIn.map(\.id))
        )

        for category in CategoryCatalog.builtIn {
            let suggestions = CategoryHierarchyCatalog.middleSuggestions(
                for: category.id
            )
            XCTAssertGreaterThanOrEqual(
                suggestions.count,
                4,
                "\(category.name) 중분류 추천이 부족합니다."
            )
            XCTAssertEqual(Set(suggestions).count, suggestions.count)
            XCTAssertTrue(suggestions.allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        }

        XCTAssertEqual(
            CategoryHierarchyCatalog.middleSuggestions(
                for: "custom.volunteer"
            ),
            CategoryHierarchyCatalog.defaultMiddleSuggestions
        )
    }

    func testQuickPlanDraftUsesHalfHourDefaultsAndTitleFallback() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let input = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 8,
                day: 1,
                hour: 12,
                minute: 57
            )
        )!
        let rounded = QuickPlanDraftEngine.roundedUpToHalfHour(input)

        XCTAssertEqual(calendar.component(.hour, from: rounded), 13)
        XCTAssertEqual(calendar.component(.minute, from: rounded), 0)
        XCTAssertEqual(QuickPlanDraftEngine.defaultDuration, 30 * 60)
        XCTAssertEqual(QuickPlanDraftEngine.adjustmentStep, 5 * 60)
        XCTAssertEqual(
            QuickPlanDraftEngine.resolvedTitle(
                subcategory: "청계천 산책",
                middleCategory: "산책"
            ),
            "청계천 산책"
        )
        XCTAssertEqual(
            QuickPlanDraftEngine.resolvedTitle(
                subcategory: "   ",
                middleCategory: "산책"
            ),
            "산책"
        )
        XCTAssertNil(
            QuickPlanDraftEngine.resolvedTitle(
                subcategory: "",
                middleCategory: ""
            )
        )
    }

    func testDeletingCustomCategoryReassignsRecords() throws {
        let custom = try CategoryCatalog.makeCustom(
            name: "봉사",
            icon: .family,
            lightHex: "#AABBCC",
            existing: CategoryCatalog.builtIn
        )
        let base = makeDate(2026, 7, 30)
        let plan = PlanRecord(
            title: "봉사",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: custom.id
        )
        let result = try CategoryCatalog.deleting(
            categoryID: custom.id,
            reassigningTo: "relationship",
            categories: CategoryCatalog.builtIn + [custom],
            plans: [plan],
            actuals: []
        )
        XCTAssertEqual(result.plans[0].categoryID, "relationship")
        XCTAssertFalse(result.categories.contains(where: { $0.id == custom.id }))
    }

    func testCategoryDragReorderingMovesInsteadOfSwapping() {
        let categories = Array(CategoryCatalog.builtIn.prefix(4))
        let reordered = CategoryCatalog.moving(
            categories,
            fromOffsets: IndexSet(integer: 0),
            toOffset: 3
        )

        XCTAssertEqual(
            reordered.map(\.id),
            [
                categories[1].id,
                categories[2].id,
                categories[0].id,
                categories[3].id,
            ]
        )
        XCTAssertEqual(
            reordered.map(\.sortOrder),
            Array(0..<categories.count)
        )
    }

    func testAutomaticMajorCategoryRemainsLockedAcrossRefresh() {
        let start = makeDate(2026, 8, 12, 9, 0)
        let old = ActualRecord(
            planID: nil,
            title: "활동",
            categoryID: "activity",
            startedAt: start,
            endedAt: start.addingTimeInterval(20 * 60),
            source: .motion,
            isClassificationLocked: true
        )
        let fresh = ActualRecord(
            planID: nil,
            title: "이동",
            categoryID: "movement",
            startedAt: start.addingTimeInterval(60),
            endedAt: start.addingTimeInterval(21 * 60),
            source: .motion
        )

        let result = ActivityClassificationLockEngine.mergingLockedClassifications(
            existing: [old],
            fresh: [fresh],
            inside: TimeSpan(start: start, end: start.addingTimeInterval(hour))
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].categoryID, "activity")
        XCTAssertTrue(result[0].isClassificationLocked)
    }

    func testMemoEditingPreservesIdentityAndAttachments() throws {
        let createdAt = makeDate(2026, 7, 30, 9, 0)
        let updatedAt = createdAt.addingTimeInterval(60)
        let attachment = MemoAttachment(
            kind: .photo,
            localIdentifier: "photo-id",
            createdAt: createdAt
        )
        let original = ActionMemo(
            planID: UUID(),
            targetID: "automatic.actual.item",
            kind: .idea,
            text: "초안",
            attachments: [attachment],
            createdAt: createdAt,
            updatedAt: createdAt
        )

        let updated = try XCTUnwrap(
            ActionMemoEditingEngine.updating(
                original,
                text: "  다음 행동  ",
                kind: .nextAction,
                at: updatedAt
            )
        )

        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.planID, original.planID)
        XCTAssertEqual(updated.targetID, original.targetID)
        XCTAssertEqual(updated.text, "다음 행동")
        XCTAssertEqual(updated.kind, .nextAction)
        XCTAssertEqual(updated.attachments, [attachment])
        XCTAssertEqual(updated.createdAt, createdAt)
        XCTAssertEqual(updated.updatedAt, updatedAt)
        XCTAssertNil(
            ActionMemoEditingEngine.updating(
                original,
                text: "  ",
                kind: .decision
            )
        )
    }

    func testSensorLiveActivityPhaseTimelineAndLegacyFallback() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 20_000)
        let waiting = SensorCollectionActivityAttributes.ContentState(
            startedAt: startedAt,
            lastSavedAt: nil,
            collectionKinds: ["location"],
            isCollecting: true,
            phaseRawValue: SensorCollectionActivityPhase.waiting.rawValue
        )
        XCTAssertEqual(waiting.phase, .waiting)

        let pulseUntil = SensorCollectionActivityPolicy.pulseUntil(
            now: startedAt
        )
        let pulse = SensorCollectionActivityAttributes.ContentState(
            startedAt: startedAt,
            lastSavedAt: startedAt,
            collectionKinds: ["location"],
            isCollecting: true,
            saveToken: 4,
            phaseRawValue: SensorCollectionActivityPhase.pulse.rawValue,
            phaseUntil: pulseUntil
        )
        XCTAssertEqual(pulse.phase, .pulse)
        XCTAssertFalse(
            SensorCollectionActivityPolicy.isPhaseExpired(
                pulse.phase,
                until: pulse.phaseUntil,
                now: startedAt.addingTimeInterval(0.999)
            )
        )
        XCTAssertTrue(
            SensorCollectionActivityPolicy.isPhaseExpired(
                pulse.phase,
                until: pulse.phaseUntil,
                now: pulseUntil
            )
        )

        let intervalPulseUntil = SensorCollectionActivityPolicy.pulseUntil(
            now: startedAt,
            intervalSeconds: 60
        )
        XCTAssertEqual(
            intervalPulseUntil.timeIntervalSince(startedAt),
            30,
            accuracy: 0.000_001
        )

        let flatline = SensorCollectionActivityAttributes.ContentState(
            startedAt: startedAt,
            lastSavedAt: startedAt,
            collectionKinds: ["location"],
            isCollecting: true,
            saveToken: 4,
            phaseRawValue: SensorCollectionActivityPhase.flatline.rawValue
        )
        XCTAssertEqual(flatline.phase, .flatline)

        let stopped = SensorCollectionActivityAttributes.ContentState(
            startedAt: startedAt,
            lastSavedAt: startedAt,
            collectionKinds: ["location"],
            isCollecting: false
        )
        XCTAssertEqual(stopped.phase, .hidden)
    }

    func testPlanDayDataSnapshotLoadsOneNormalizedDayWithoutMutatingSource() {
        let base = makeDate(2026, 7, 30, 0, 0)
        let id = UUID()
        let source = TaptionDataSnapshot.empty
        let sensorResult = SensorReadingsLoadResult(
            readings: [
                SensorReading(
                    id: id,
                    timestamp: base.addingTimeInterval(10 * 60),
                    motion: .walking
                ),
                SensorReading(
                    id: id,
                    timestamp: base.addingTimeInterval(10 * 60),
                    motion: .running
                ),
                SensorReading(
                    timestamp: base.addingTimeInterval(24 * 60 * 60),
                    motion: .cycling
                ),
            ],
            isComplete: true
        )

        let projected = PlanDayDataSnapshot.make(
            date: base,
            sourceRevision: 7,
            source: source,
            sensorResult: sensorResult
        )

        XCTAssertEqual(projected.day, Calendar.autoupdatingCurrent.startOfDay(for: base))
        XCTAssertEqual(projected.sourceRevision, 7)
        XCTAssertTrue(projected.isComplete)
        XCTAssertEqual(projected.readings.count, 1)
        XCTAssertEqual(projected.readings.first?.motion, .running)
        XCTAssertEqual(source, TaptionDataSnapshot.empty)
    }

    func testWidgetCatActionMatchesCurrentActionItemCategoryAndTitle() {
        XCTAssertEqual(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "exercise",
                title: "근력 운동"
            ),
            .ballPlay
        )
        XCTAssertEqual(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "hobby",
                title: "기타 연습"
            ),
            .fishingPlay
        )
        XCTAssertEqual(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "routine",
                title: "저녁 식사"
            ),
            .eating
        )
        XCTAssertEqual(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "sleep",
                title: "낮잠"
            ),
            .sleeping
        )
        XCTAssertEqual(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "movement",
                title: "아침 산책"
            ),
            .walking
        )
        XCTAssertEqual(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "exercise",
                title: "러닝"
            ),
            .running
        )
        XCTAssertNil(
            TaptionWidgetCatActionSelector.preferredAction(
                categoryID: "custom-unknown",
                title: "사용자 항목"
            )
        )
    }

    func testWidgetDeepLinkParsesExactPlan() throws {
        let planID = UUID()
        let link = TaptionDeepLink(
            url: URL(
                string: "taptionplan://plan/\(planID.uuidString)"
            )!
        )

        XCTAssertEqual(link, .plan(planID))
        XCTAssertEqual(
            TaptionDeepLink(url: URL(string: "taptionplan://today")!),
            .today
        )
        XCTAssertEqual(
            TaptionDeepLink(url: URL(string: "taptionplan://cats")!),
            .catPicker
        )
        // 센서 수집 위젯의 widgetURL. 예전에는 해석되지 않아 파싱 단계에서 nil이었다.
        XCTAssertEqual(
            TaptionDeepLink(url: URL(string: "taptionplan://sensor")!),
            .sensor
        )
        XCTAssertNil(TaptionDeepLink(url: URL(string: "taptionplan://unknown")!))
    }

    func testPlanNotificationPolicyKeepsOnlyUpcomingPlansInOrder() {
        let now = makeDate(2026, 7, 30, 9)
        let past = PlanRecord(
            title: "지난 계획",
            span: TimeSpan(
                start: now.addingTimeInterval(-hour),
                end: now
            ),
            categoryID: "project"
        )
        let later = PlanRecord(
            title: "두 번째",
            span: TimeSpan(
                start: now.addingTimeInterval(2 * hour),
                end: now.addingTimeInterval(3 * hour)
            ),
            categoryID: "project"
        )
        let first = PlanRecord(
            title: "첫 번째",
            span: TimeSpan(
                start: now.addingTimeInterval(hour),
                end: now.addingTimeInterval(2 * hour)
            ),
            categoryID: "study"
        )
        var completed = later
        completed.id = UUID()
        completed.status = .completed

        let reminders = PlanNotificationPolicy.reminderPlans(
            from: [past, later, completed, first],
            now: now
        )

        XCTAssertEqual(reminders.map(\.id), [first.id, later.id])
        XCTAssertEqual(
            PlanNotificationScheduler.identifier(for: first.id),
            "plan-start-\(first.id.uuidString)"
        )
    }

    func testTimelineRowOrderMovesRowsAndKeepsUnknownRowsStable() {
        let rows = ["calendar", "location", "movement", "sleep", "photo"]
        let saved = TimelineRowOrder.defaults

        XCTAssertEqual(
            TimelineRowOrder.ordered(
                rows,
                id: { $0 },
                savedIDs: saved
            ),
            rows
        )
        XCTAssertEqual(
            TimelineRowOrder.moved(
                rows,
                sourceID: "photo",
                targetID: "location",
                savedIDs: saved
            ),
            ["calendar", "photo", "location", "movement", "sleep"]
        )
        XCTAssertEqual(
            TimelineRowOrder.moved(
                rows,
                sourceID: "calendar",
                targetID: "movement",
                savedIDs: saved
            ),
            ["location", "calendar", "movement", "sleep", "photo"]
        )
    }

    func testCalendarSyncReconcilesAccountsButPreservesEmptyStore() {
        XCTAssertEqual(
            CalendarSyncPolicy.reconciledCalendarIDs(
                existing: ["work"],
                live: ["work", "personal"]
            ),
            ["work"]
        )
        XCTAssertEqual(
            CalendarSyncPolicy.reconciledCalendarIDs(
                existing: ["apple", "google", "naver"],
                live: []
            ),
            ["apple", "google", "naver"]
        )
        XCTAssertEqual(
            CalendarSyncPolicy.reconciledCalendarIDs(
                existing: ["apple", "google", "naver"],
                live: ["apple", "naver"]
            ),
            ["apple", "naver"]
        )
        XCTAssertEqual(
            CalendarSyncPolicy.reconciledCalendarIDs(
                existing: ["old"],
                live: ["new"]
            ),
            ["new"]
        )
        XCTAssertEqual(
            CalendarSyncPolicy.reconciledCalendarIDs(
                existing: [],
                live: ["new"]
            ),
            ["new"]
        )
        XCTAssertTrue(CalendarSyncPolicy.hasCompleteSelection(
            selected: ["apple", "google"],
            live: ["apple", "google", "naver"]
        ))
        XCTAssertFalse(CalendarSyncPolicy.hasCompleteSelection(
            selected: ["apple", "google"],
            live: ["apple"]
        ))
    }

    @MainActor
    func testCalendarSelectionSurvivesPermissionRefresh() async {
        var stored = TaptionDataSnapshot.empty
        stored.settings.selectedCalendarIDs = ["work", "personal"]
        stored.settings.permissions[.calendar] = .denied
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: stored),
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )

        await model.refreshPermissions()

        XCTAssertEqual(
            model.snapshot.settings.selectedCalendarIDs,
            ["work", "personal"]
        )
    }

    func testCalendarEventDisplayPreservesAllDayAndFloatingWallClock() {
        var displayCalendar = Calendar(identifier: .gregorian)
        displayCalendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let allDay = CalendarRecord(
            id: "all-day",
            calendarID: "calendar",
            title: "휴일",
            span: TimeSpan(
                start: makeDate(2026, 9, 4, 15),
                end: makeDate(2026, 9, 5, 15)
            ),
            isAllDay: true,
            calendarTitle: "개인",
            calendarColorHex: nil,
            sourceTitle: "Apple",
            originalStartDateComponents: DateComponents(
                year: 2026,
                month: 9,
                day: 5
            ),
            originalEndDateComponents: DateComponents(
                year: 2026,
                month: 9,
                day: 6
            )
        )
        let normalizedAllDay = allDay.normalizedForDisplay(
            in: displayCalendar
        )
        XCTAssertEqual(
            displayCalendar.component(.day, from: normalizedAllDay.span.start),
            5
        )
        XCTAssertEqual(normalizedAllDay.span.duration, 24 * 60 * 60)

        let floating = CalendarRecord(
            id: "floating",
            calendarID: "calendar",
            title: "떠 있는 일정",
            span: TimeSpan(
                start: makeDate(2026, 9, 4, 15),
                end: makeDate(2026, 9, 4, 16)
            ),
            isAllDay: false,
            calendarTitle: "개인",
            calendarColorHex: nil,
            sourceTitle: "Apple",
            isFloatingTime: true,
            originalStartDateComponents: DateComponents(
                year: 2026,
                month: 9,
                day: 5,
                hour: 10,
                minute: 30
            ),
            originalEndDateComponents: DateComponents(
                year: 2026,
                month: 9,
                day: 5,
                hour: 11,
                minute: 30
            )
        )
        let normalizedFloating = floating.normalizedForDisplay(
            in: displayCalendar
        )
        XCTAssertEqual(
            displayCalendar.dateComponents(
                [.day, .hour, .minute],
                from: normalizedFloating.span.start
            ),
            DateComponents(day: 5, hour: 10, minute: 30)
        )

        var changedDeviceCalendar = Calendar(identifier: .gregorian)
        changedDeviceCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let storedAllDay = normalizedAllDay
        let reloadedAllDay = storedAllDay.normalizedForDisplay(
            in: changedDeviceCalendar
        )
        XCTAssertEqual(
            changedDeviceCalendar.component(
                .day,
                from: reloadedAllDay.span.start
            ),
            5
        )
        let storedFloating = normalizedFloating
        let reloadedFloating = storedFloating.normalizedForDisplay(
            in: changedDeviceCalendar
        )
        XCTAssertEqual(
            changedDeviceCalendar.dateComponents(
                [.day, .hour, .minute],
                from: reloadedFloating.span.start
            ),
            DateComponents(day: 5, hour: 10, minute: 30)
        )
    }

    func testCalendarDeduplicationUsesAccountAndOccurrence() {
        let start = makeDate(2026, 9, 5, 10)
        func event(
            id: String,
            source: String,
            occurrence: Date = start,
            sourceTitle: String = "Google"
        ) -> CalendarRecord {
            CalendarRecord(
                id: id,
                calendarID: "calendar",
                title: "회의",
                span: TimeSpan(
                    start: occurrence,
                    end: occurrence.addingTimeInterval(hour)
                ),
                isAllDay: false,
                calendarTitle: "업무",
                calendarColorHex: nil,
                sourceTitle: sourceTitle,
                sourceIdentifier: source,
                externalIdentifier: "external-1",
                recurrenceIdentifier: "weekly"
            )
        }

        let deduplicated = CalendarSyncPolicy.deduplicatedEvents([
            event(id: "copy-a", source: "google-account"),
            event(id: "copy-b", source: "google-account"),
            event(
                id: "renamed-source",
                source: "google-account",
                sourceTitle: "Apple"
            ),
            event(id: "other-account", source: "google-account-2"),
            event(
                id: "other-occurrence",
                source: "google-account",
                occurrence: start.addingTimeInterval(24 * 60 * 60)
            ),
            CalendarRecord(
                id: "all-day-a",
                calendarID: "calendar",
                title: "휴일",
                span: TimeSpan(
                    start: start,
                    end: start.addingTimeInterval(24 * 60 * 60)
                ),
                isAllDay: true,
                calendarTitle: "업무",
                calendarColorHex: nil,
                sourceTitle: "Google",
                sourceIdentifier: "google-account",
                originalStartDateComponents: DateComponents(
                    year: 2026,
                    month: 9,
                    day: 5
                ),
                externalIdentifier: "all-day-1"
            ),
            CalendarRecord(
                id: "all-day-b",
                calendarID: "other-calendar",
                title: "휴일",
                span: TimeSpan(
                    start: start.addingTimeInterval(9 * 60 * 60),
                    end: start.addingTimeInterval(33 * 60 * 60)
                ),
                isAllDay: true,
                calendarTitle: "업무 복사본",
                calendarColorHex: nil,
                sourceTitle: "Google",
                sourceIdentifier: "google-account",
                originalStartDateComponents: DateComponents(
                    year: 2026,
                    month: 9,
                    day: 5
                ),
                externalIdentifier: "all-day-1"
            ),
        ])
        XCTAssertEqual(deduplicated.map(\.id), [
            "copy-a",
            "other-account",
            "other-occurrence",
            "all-day-a",
        ])

        let movedOccurrence = event(
            id: "moved",
            source: "google-account",
            occurrence: start.addingTimeInterval(48 * 60 * 60)
        )
        var originalOccurrence = event(
            id: "original",
            source: "google-account"
        )
        originalOccurrence.occurrenceDate = start
        var moved = movedOccurrence
        moved.occurrenceDate = start
        moved.recurrenceIdentifier = nil
        XCTAssertEqual(
            CalendarSyncPolicy.eventIdentityKey(originalOccurrence),
            CalendarSyncPolicy.eventIdentityKey(moved)
        )
    }

    func testCalendarMergeAddsAndRemovesAccountsAtomically() {
        let refresh = TimeSpan(
            start: makeDate(2026, 9, 5, 0),
            end: makeDate(2026, 9, 6, 0)
        )
        func event(
            id: String,
            calendarID: String,
            start: Date
        ) -> CalendarRecord {
            CalendarRecord(
                id: id,
                calendarID: calendarID,
                title: id,
                span: TimeSpan(
                    start: start,
                    end: start.addingTimeInterval(hour)
                ),
                isAllDay: false,
                calendarTitle: calendarID,
                calendarColorHex: nil,
                sourceTitle: calendarID,
                sourceIdentifier: calendarID,
                externalIdentifier: id
            )
        }
        let removedAccount = event(
            id: "removed-account",
            calendarID: "icloud",
            start: makeDate(2026, 9, 3, 9)
        )
        let retained = event(
            id: "retained",
            calendarID: "google",
            start: makeDate(2026, 9, 4, 9)
        )
        let fresh = event(
            id: "fresh",
            calendarID: "google",
            start: makeDate(2026, 9, 5, 9)
        )

        let merged = CalendarSyncPolicy.mergingEvents(
            existing: [removedAccount, retained],
            fresh: [fresh],
            in: refresh,
            liveCalendarIDs: ["google"]
        )

        XCTAssertEqual(merged.map(\.id), ["retained", "fresh"])
    }

    func testCalendarMergeReplacesMovedRecurringOccurrenceOutsideRange() {
        let originalOccurrence = makeDate(2026, 9, 4, 10)
        func event(id: String, start: Date) -> CalendarRecord {
            CalendarRecord(
                id: id,
                calendarID: "google",
                title: "주간 회의",
                span: TimeSpan(
                    start: start,
                    end: start.addingTimeInterval(hour)
                ),
                isAllDay: false,
                calendarTitle: "업무",
                calendarColorHex: nil,
                sourceTitle: "Google",
                sourceIdentifier: "google-account",
                externalIdentifier: "weekly-meeting",
                occurrenceDate: originalOccurrence
            )
        }
        let stale = event(id: "stale", start: originalOccurrence)
        let moved = event(
            id: "moved",
            start: makeDate(2026, 9, 8, 14)
        )
        let refresh = TimeSpan(
            start: makeDate(2026, 9, 8, 0),
            end: makeDate(2026, 9, 9, 0)
        )

        let merged = CalendarSyncPolicy.mergingEvents(
            existing: [stale],
            fresh: [moved],
            in: refresh,
            liveCalendarIDs: ["google"]
        )

        XCTAssertEqual(merged.map(\.id), ["moved"])
    }

    func testCalendarSyncRefreshesTodayWithoutBridgingFarHistory() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 5,
            hour: 12
        ))!
        let todayStart = calendar.startOfDay(for: now)
        let today = TimeSpan(
            start: todayStart,
            end: calendar.date(byAdding: .day, value: 1, to: todayStart)!
        )
        let automatic = CalendarSyncPolicy.refreshSpans(
            requested: today,
            includesCurrentDeviceDay: true,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(automatic.count, 1)
        XCTAssertLessThanOrEqual(automatic[0].start, today.start)
        XCTAssertGreaterThanOrEqual(automatic[0].end, today.end)

        let history = TimeSpan(
            start: calendar.date(from: DateComponents(
                year: 2020,
                month: 1,
                day: 1
            ))!,
            end: calendar.date(from: DateComponents(
                year: 2020,
                month: 2,
                day: 1
            ))!
        )
        let split = CalendarSyncPolicy.refreshSpans(
            requested: history,
            includesCurrentDeviceDay: true,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split[1], history)
    }

    func testCalendarSyncLimitsAutomaticRangeBetweenWideRefreshes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 5,
            hour: 12
        ))!
        let history = TimeSpan(
            start: calendar.date(from: DateComponents(
                year: 2020,
                month: 1,
                day: 1
            ))!,
            end: calendar.date(from: DateComponents(
                year: 2020,
                month: 1,
                day: 2
            ))!
        )
        let spans = CalendarSyncPolicy.refreshSpans(
            requested: history,
            includesCurrentDeviceDay: true,
            refreshesAutomaticRange: false,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].start, calendar.startOfDay(for: now))
        XCTAssertEqual(
            spans[0].end,
            calendar.date(byAdding: .day, value: 1, to: spans[0].start)
        )
        XCTAssertEqual(spans[1], history)
        XCTAssertFalse(CalendarSyncPolicy.shouldRefreshAutomaticRange(
            lastRefresh: now.addingTimeInterval(-60),
            now: now
        ))
        XCTAssertTrue(CalendarSyncPolicy.shouldRefreshAutomaticRange(
            lastRefresh: now.addingTimeInterval(
                -CalendarSyncPolicy.automaticRefreshInterval
            ),
            now: now
        ))
        XCTAssertTrue(CalendarSyncPolicy.shouldRefreshAutomaticRange(
            lastRefresh: now,
            now: now,
            force: true
        ))
    }

    func testCloudRecoveryDetachesMemoWhenLinkedPlanWasDeleted() {
        let base = makeDate(2026, 8, 9, 10)
        let plan = PlanRecord(
            title: "삭제된 계획",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "work"
        )
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127.0,
            altitude: 12,
            horizontalAccuracy: 4,
            verticalAccuracy: 6
        )
        let memo = ActionMemo(
            planID: plan.id,
            targetID: "plan.\(plan.id.uuidString)",
            categoryID: plan.categoryID,
            occurredAt: base.addingTimeInterval(20 * 60),
            mapPoint: point,
            kind: .idea,
            text: "계획에서 독립한 메모",
            createdAt: base,
            updatedAt: base
        )
        var local = TaptionDataSnapshot.empty
        local.updatedAt = base.addingTimeInterval(hour)
        local.settings.cloudDeletedRecordKeys = [
            CloudBackupRecordKey.plan(plan.id)
        ]
        var remote = TaptionDataSnapshot.empty
        remote.updatedAt = base
        remote.plans = [plan]
        remote.memos = [memo]

        let recovered = CloudSnapshotRecoveryEngine.merge(
            local: local,
            remote: remote
        )

        let detached = recovered.memos.first
        XCTAssertTrue(recovered.plans.isEmpty)
        XCTAssertEqual(detached?.id, memo.id)
        XCTAssertNil(detached?.planID)
        XCTAssertNil(detached?.targetID)
        XCTAssertEqual(detached?.categoryID, memo.categoryID)
        XCTAssertEqual(detached?.occurredAt, memo.occurredAt)
        XCTAssertEqual(detached?.mapPoint, memo.mapPoint)
        XCTAssertEqual(detached?.text, memo.text)
    }

    func testGoalDetailBranchesAndDeduplicatesOverlappingTime() {
        let start = makeDate(2026, 8, 1, 9)
        let repeatGoal = PlanRecord(
            title: "수면",
            span: TimeSpan(start: start, end: start.addingTimeInterval(30 * 86_400)),
            categoryID: "sleep",
            repeatRules: [
                GoalRepeatRule(
                    weekdays: [2, 3, 4, 5, 6],
                    startMinuteOfDay: 23 * 60,
                    endMinuteOfDay: 6 * 60 + 30
                ),
            ]
        )
        XCTAssertEqual(
            GoalDetailEngine.make(
                goal: repeatGoal,
                plans: [repeatGoal],
                actuals: [],
                referenceDate: start,
                calendar: utcCalendar
            ).mode,
            .habit
        )

        let projectGoal = PlanRecord(
            title: "자격증",
            span: TimeSpan(start: start, end: start.addingTimeInterval(10 * 86_400)),
            categoryID: "study"
        )
        let child = PlanRecord(
            title: "강의 듣기",
            span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            categoryID: "study",
            parentID: projectGoal.id
        )
        XCTAssertEqual(
            GoalDetailEngine.make(
                goal: projectGoal,
                plans: [projectGoal, child],
                actuals: [],
                referenceDate: start,
                calendar: utcCalendar
            ).mode,
            .project
        )
        XCTAssertEqual(
            GoalDetailEngine.make(
                goal: projectGoal,
                plans: [projectGoal],
                actuals: [],
                referenceDate: start,
                calendar: utcCalendar
            ).mode,
            .empty
        )
        XCTAssertEqual(
            GoalDetailEngine.unionDuration([
                TimeSpan(start: start, end: start.addingTimeInterval(hour)),
                TimeSpan(
                    start: start.addingTimeInterval(30 * 60),
                    end: start.addingTimeInterval(2 * hour)
                ),
            ]),
            2 * hour
        )
    }

    func testRelationshipGraphOmitsRepeatSegmentsAndKeepsFocusedRoutineChain() {
        let start = makeDate(2026, 8, 2, 22)
        let routine = PlanRecord(
            title: "루틴:수면",
            span: TimeSpan(start: start, end: start.addingTimeInterval(10 * hour)),
            categoryID: "sleep"
        )
        let repeatSegment = PlanRecord(
            title: "수면 · 주중",
            span: TimeSpan(
                start: start.addingTimeInterval(hour),
                end: start.addingTimeInterval(8 * hour)
            ),
            categoryID: "sleep",
            parentID: routine.id,
            origin: .repeatRule
        )
        let action = PlanRecord(
            title: "취침 준비",
            span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            categoryID: "sleep",
            parentID: routine.id
        )
        let sleep = ActualRecord(
            planID: action.id,
            routineID: routine.id,
            title: "수면",
            categoryID: "sleep",
            startedAt: start.addingTimeInterval(2 * hour),
            endedAt: start.addingTimeInterval(7 * hour),
            source: .healthKit
        )

        let graph = RecordRelationshipEngine.make(
            inside: sleep.span(),
            plans: [routine, repeatSegment, action],
            actuals: [sleep],
            calendarEvents: [],
            places: [],
            travel: [],
            focusNodeID: "automatic.actual.\(sleep.id.uuidString)"
        )

        XCTAssertFalse(graph.nodes.contains { $0.id == "routine.\(repeatSegment.id.uuidString)" })
        XCTAssertTrue(graph.edges.contains {
            $0.from == "automatic.actual.\(sleep.id.uuidString)"
                && $0.to == "routine.\(routine.id.uuidString)"
        })
        XCTAssertFalse(graph.edges.contains {
            $0.from == "automatic.actual.\(sleep.id.uuidString)"
                && $0.to == "action.\(action.id.uuidString)"
        })
        XCTAssertTrue(graph.edges.contains {
            $0.from == "routine.\(routine.id.uuidString)"
                && $0.to == "action.\(action.id.uuidString)"
        })
    }

    func testRelationshipGraphCanonicalizesLegacyRepeatLink() {
        let start = makeDate(2026, 8, 3, 8)
        let routine = PlanRecord(
            title: "루틴:출근",
            span: TimeSpan(start: start, end: start.addingTimeInterval(2 * hour)),
            categoryID: "work"
        )
        let repeatSegment = PlanRecord(
            title: "출근 · 월요일",
            span: TimeSpan(start: start, end: start.addingTimeInterval(hour)),
            categoryID: "work",
            parentID: routine.id,
            origin: .repeatRule
        )
        let place = PlaceStay(
            id: UUID(),
            placeKey: "company",
            displayName: "회사",
            floor: nil,
            span: TimeSpan(start: start, end: start.addingTimeInterval(30 * 60)),
            confidence: .high,
            point: nil
        )
        let graph = RecordRelationshipEngine.make(
            inside: place.span,
            plans: [routine, repeatSegment],
            actuals: [],
            calendarEvents: [],
            places: [place],
            travel: [],
            recordLinks: [
                RecordLink(
                    fromNodeID: "automatic.place.\(place.id.uuidString)",
                    toNodeID: "action.\(repeatSegment.id.uuidString)"
                )
            ]
        )

        XCTAssertTrue(graph.edges.contains {
            $0.from == "automatic.place.\(place.id.uuidString)"
                && $0.to == "routine.\(routine.id.uuidString)"
        })
        XCTAssertFalse(graph.edges.contains {
            $0.to == "action.\(repeatSegment.id.uuidString)"
        })
    }

    func testGoalRecordPolicyKeepsOrdinaryPlansOutOfGoalTab() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let goal = PlanRecord(
            title: "목표:달리기",
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(86_400)
            ),
            categoryID: "exercise"
        )
        let ordinaryPlan = PlanRecord(
            title: "청계천 달리기",
            span: TimeSpan(
                start: start.addingTimeInterval(3_600),
                end: start.addingTimeInterval(5_400)
            ),
            categoryID: "exercise"
        )
        let childPlan = PlanRecord(
            title: "인터벌 훈련",
            span: TimeSpan(
                start: start.addingTimeInterval(7_200),
                end: start.addingTimeInterval(9_000)
            ),
            categoryID: "exercise",
            parentID: goal.id
        )
        let skippedGoal = PlanRecord(
            title: "목표:지난 목표",
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(3_600)
            ),
            categoryID: "exercise",
            status: .skipped
        )

        let visible = GoalRecordPolicy.visibleGoals(
            in: [ordinaryPlan, childPlan, skippedGoal, goal]
        )

        XCTAssertEqual(visible.map(\.id), [goal.id])
        XCTAssertFalse(GoalRecordPolicy.isGoal(ordinaryPlan))
        XCTAssertFalse(GoalRecordPolicy.isGoal(childPlan))
    }

    func testScheduleHeaderUsesKoreanCalendarTitles() {
        let date = makeDate(2026, 7, 31)
        let formatter = ScheduleHeaderFormatter(calendar: utcCalendar)

        XCTAssertEqual(
            formatter.title(for: date, scale: .day),
            "7월 31일 (금)"
        )
        XCTAssertEqual(
            formatter.title(for: date, scale: .week),
            "7월 27일 – 8월 2일"
        )
        XCTAssertEqual(
            formatter.title(for: date, scale: .month),
            "2026년 7월"
        )
        XCTAssertEqual(
            formatter.title(for: date, scale: .year),
            "2026년"
        )
        XCTAssertEqual(
            formatter.playheadTitle(for: date, scale: .week),
            "7월 31일 (금)"
        )
        XCTAssertEqual(
            formatter.playheadTitle(for: date, scale: .month),
            "7월 31일 (금)"
        )
        XCTAssertEqual(
            formatter.playheadTitle(for: date, scale: .year),
            "7월 31일 (금)"
        )
    }

    func testScreenTimeUsageExplainsCategoryAndUnknownFallbacks() {
        let start = makeDate(2026, 8, 3, 14)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(hour))
        let records = ScreenTimeUsageRecordEngine.records(
            from: [
                ScreenTimeUsageSample(
                    key: "category:소셜",
                    title: "어플 · 소셜",
                    span: span,
                    duration: 18 * 60,
                    pickups: 0,
                    notifications: 0,
                    nameSource: .category
                ),
                ScreenTimeUsageSample(
                    key: "total",
                    title: "어플",
                    span: span,
                    duration: 40 * 60,
                    pickups: 2,
                    notifications: 0,
                    nameSource: .unknown
                ),
            ],
            suppressedIDs: []
        )

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(
            records.first { $0.title == "어플 · 소셜" }?.evidence,
            [
                "Screen Time 시간대 합계",
                "사용 18분",
                "앱 이름을 읽을 수 없어 카테고리 단위로 묶었습니다",
            ]
        )
        XCTAssertEqual(
            records.first { $0.title == "어플" }?.evidence,
            [
                "Screen Time 시간대 합계",
                "사용 40분",
                "앱 열기 2회",
                "앱 이름과 카테고리를 모두 읽을 수 없어 시간대 합계만 남겼습니다",
            ]
        )
    }

    func testRecordGroupingMergesRepeatedTitlesAndClipsToSpan() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(
            start: day.addingTimeInterval(9 * hour),
            end: day.addingTimeInterval(12 * hour)
        )
        let actuals = [
            // 기간 앞으로 삐져나온 기록은 겹치는 만큼만 센다.
            makeActual(
                "회의",
                "work",
                start: day.addingTimeInterval(8.5 * hour),
                minutes: 60
            ),
            makeActual(
                "회의",
                "work",
                start: day.addingTimeInterval(10 * hour),
                minutes: 30
            ),
            // 같은 제목이 겹치면 한 번만 센다.
            makeActual(
                "회의",
                "work",
                start: day.addingTimeInterval(10 * hour + 15 * 60),
                minutes: 30
            ),
        ]

        let groups = ActualRecordGroupingEngine.groups(
            actuals: actuals,
            in: span,
            categories: CategoryCatalog.builtIn,
            asOf: day.addingTimeInterval(24 * hour)
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "업무")
        XCTAssertEqual(groups[0].children.count, 1)
        XCTAssertEqual(groups[0].children[0].occurrenceCount, 3)
        XCTAssertEqual(groups[0].children[0].duration, 75 * 60)
        XCTAssertEqual(groups[0].duration, 75 * 60)
    }

    func testClockLegendKeepsOnlyTheChosenCategory() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))
        let rings = RecordChartEngine.clockRings(
            actuals: [
                makeActual("수면", "sleep", start: day, minutes: 6 * 60),
                makeActual(
                    "걷기",
                    "movement",
                    start: day.addingTimeInterval(12 * hour),
                    minutes: 60
                ),
            ],
            in: span,
            asOf: day.addingTimeInterval(24 * hour)
        )

        XCTAssertEqual(
            RecordClockEngine.rings(rings, isolating: nil).count,
            2
        )
        XCTAssertEqual(
            RecordClockEngine.rings(rings, isolating: "movement")
                .map(\.categoryID),
            ["movement"]
        )
        XCTAssertTrue(
            RecordClockEngine.rings(rings, isolating: "sleepless").isEmpty
        )
    }

    func testMemoShellMigrationLiftsMemoAndRemovesShellPlan() {
        let start = makeDate(2026, 8, 4, 9, 30)
        let shell = makeMemoShellPlan(start: start)
        var snapshot = makeSnapshot(
            plans: [shell],
            memos: [
                ActionMemo(planID: shell.id, kind: .idea, text: "회의 정리"),
            ]
        )

        MemoShellPlanMigration.apply(to: &snapshot)

        XCTAssertTrue(snapshot.plans.isEmpty)
        XCTAssertEqual(snapshot.memos.count, 1)
        let lifted = snapshot.memos[0]
        XCTAssertNil(lifted.planID)
        XCTAssertEqual(lifted.categoryID, "activity")
        XCTAssertEqual(lifted.occurredAt, start)
        XCTAssertEqual(lifted.text, "회의 정리")
    }

    func testMemoShellMigrationKeepsRealOneMinuteUserPlans() {
        let start = makeDate(2026, 8, 4, 9, 30)
        let sameShapeDifferentTitle = PlanRecord(
            title: "약 먹기",
            span: TimeSpan(start: start, end: start.addingTimeInterval(60)),
            categoryID: "health"
        )
        let importantShellLookalike = PlanRecord(
            title: "메모 - 활동",
            span: TimeSpan(start: start, end: start.addingTimeInterval(60)),
            categoryID: "activity",
            isImportant: true
        )
        let longerShellLookalike = PlanRecord(
            title: "메모 - 활동",
            span: TimeSpan(start: start, end: start.addingTimeInterval(120)),
            categoryID: "activity"
        )
        let trackedShellLookalike = PlanRecord(
            title: "메모 - 활동",
            span: TimeSpan(start: start, end: start.addingTimeInterval(60)),
            categoryID: "activity"
        )
        let linkedShellLookalike = PlanRecord(
            title: "메모 - 활동",
            span: TimeSpan(start: start, end: start.addingTimeInterval(60)),
            categoryID: "activity"
        )
        var snapshot = makeSnapshot(
            plans: [
                sameShapeDifferentTitle,
                importantShellLookalike,
                longerShellLookalike,
                trackedShellLookalike,
                linkedShellLookalike,
            ],
            actuals: [
                ActualRecord(
                    planID: trackedShellLookalike.id,
                    title: "메모 - 활동",
                    categoryID: "activity",
                    startedAt: start,
                    endedAt: start.addingTimeInterval(60),
                    source: .timer
                ),
            ],
            recordLinks: [
                RecordLink(
                    fromNodeID: "action.\(linkedShellLookalike.id.uuidString)",
                    toNodeID: "action.\(sameShapeDifferentTitle.id.uuidString)"
                ),
            ]
        )
        let before = snapshot.plans

        MemoShellPlanMigration.apply(to: &snapshot)

        XCTAssertEqual(snapshot.plans, before)
    }

    func testMemoShellMigrationIsIdempotent() {
        let start = makeDate(2026, 8, 4, 9, 30)
        let shell = makeMemoShellPlan(start: start)
        let keeper = PlanRecord(
            title: "논문 읽기",
            span: TimeSpan(start: start, end: start.addingTimeInterval(3_600)),
            categoryID: "study"
        )
        var snapshot = makeSnapshot(
            plans: [shell, keeper],
            memos: [
                ActionMemo(planID: shell.id, kind: .idea, text: "회의 정리"),
                ActionMemo(planID: keeper.id, kind: .idea, text: "3장까지"),
            ]
        )

        MemoShellPlanMigration.apply(to: &snapshot)
        let once = snapshot
        MemoShellPlanMigration.apply(to: &snapshot)

        XCTAssertEqual(snapshot, once)
        XCTAssertEqual(snapshot.plans.map(\.id), [keeper.id])
        XCTAssertEqual(
            snapshot.memos.first { $0.text == "3장까지" }?.planID,
            keeper.id
        )
    }

    func testMemoShellMigrationCancellationLeavesSnapshotUnchanged() {
        let start = makeDate(2026, 8, 4, 9, 30)
        var snapshot = makeSnapshot(
            plans: (0..<1_024).map { index in
                makeMemoShellPlan(
                    categoryName: "활동 \(index)",
                    start: start.addingTimeInterval(TimeInterval(index * 60))
                )
            }
        )
        let original = snapshot
        var cancellationChecks = 0

        XCTAssertThrowsError(try MemoShellPlanMigration.apply(
            to: &snapshot,
            cancellationCheck: {
                cancellationChecks += 1
                throw CancellationError()
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancellationChecks, 1)
        XCTAssertEqual(snapshot, original)
    }

    func testLoadedSnapshotPreparationCancelsDuringPlanNormalization() {
        let start = makeDate(2026, 8, 4, 9, 30)
        let snapshot = makeSnapshot(
            plans: (0..<1_024).map { index in
                PlanRecord(
                    title: "계획 \(index)",
                    span: TimeSpan(
                        start: start.addingTimeInterval(TimeInterval(index * 60)),
                        end: start.addingTimeInterval(TimeInterval((index + 1) * 60))
                    ),
                    categoryID: "activity"
                )
            }
        )
        var cancellationChecks = 0

        XCTAssertThrowsError(try AppModel.preparedLoadedSnapshot(
            snapshot,
            cancellationCheck: {
                cancellationChecks += 1
                if cancellationChecks == 3 { throw CancellationError() }
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancellationChecks, 3)
    }

    @MainActor
    func testSavingCategoryMemoCreatesNoPlan() async {
        let repository = InMemoryPlanRepository()
        let model = AppModel(repository: repository, cloudSyncService: nil)
        let day = makeDate(2026, 8, 4, 9, 30)

        model.addMemo(
            text: "무릎 상태 확인",
            kind: .idea,
            categoryID: "activity",
            on: day
        )

        XCTAssertTrue(model.snapshot.plans.isEmpty)
        XCTAssertEqual(model.snapshot.memos.count, 1)
        let saved = model.memos(forCategoryID: "activity", on: day)
        XCTAssertEqual(saved.map(\.text), ["무릎 상태 확인"])
        XCTAssertNil(saved.first?.planID)
    }

    /// 메모 입력의 입구는 하나뿐이다. 계획도 기록도 카테고리도 고르지 않고
    /// 순간 하나만 받아 저장하며, 그 순간이 곧 메모 줄에서의 자리다.
    @MainActor
    func testGlobalMemoEntryHasNoHostAndLandsOnTheMemoRowAtOccurredAt() async throws {
        let model = AppModel(
            repository: InMemoryPlanRepository(),
            cloudSyncService: nil
        )
        let instant = makeDate(2026, 8, 4, 14, 12)
        let day = TimeSpan(
            start: makeDate(2026, 8, 4),
            end: makeDate(2026, 8, 5)
        )

        model.openMemoEntry(at: instant)
        XCTAssertEqual(model.detail, .memo)
        XCTAssertEqual(model.memoEntry?.occurredAt, instant)
        model.addMemoAtEntryInstant(text: "여기서 막혔다", kind: .blocker)

        XCTAssertTrue(model.snapshot.plans.isEmpty)
        let saved = try XCTUnwrap(model.snapshot.memos.first)
        XCTAssertEqual(model.snapshot.memos.count, 1)
        XCTAssertNil(saved.planID)
        XCTAssertNil(saved.targetID)
        XCTAssertEqual(saved.categoryID, MemoTimelineEngine.categoryID)
        XCTAssertEqual(saved.occurredAt, instant)

        let markers = MemoTimelineEngine.markers(
            from: model.timelineMemos(in: day),
            in: day,
            visibleDuration: day.duration
        )
        XCTAssertEqual(markers.map(\.span.start), [instant])
        XCTAssertEqual(markers.map(\.title), ["여기서 막혔다"])
        XCTAssertEqual(markers.map(\.memoIDs), [[saved.id]])

        // 표식을 다시 누르면 그 자리의 메모가 열린다.
        let marker = try XCTUnwrap(markers.first)
        model.openMemoEntry(
            at: marker.span.start,
            memoIDs: MemoTimelineEngine.memoIDs(
                in: marker.span,
                from: model.snapshot.memos
            )
        )
        XCTAssertEqual(model.memoEntryMemos.map(\.id), [saved.id])
        model.deleteMemo(saved.id)
        XCTAssertTrue(model.memoEntryMemos.isEmpty)
        XCTAssertEqual(model.memoEntry?.memoIDs, [])
    }

    /// 메모를 더해도 시간표가 다시 그려지지 않으면 새 메모가 줄에 나타나지
    /// 않는다. 배치 캐시를 깨우는 개정 번호가 메모까지 본다.
    @MainActor
    func testSavingAMemoInvalidatesTheTimelineLayout() async {
        let model = AppModel(
            repository: InMemoryPlanRepository(),
            cloudSyncService: nil
        )
        let before = model.timelineRevision
        model.openMemoEntry(at: makeDate(2026, 8, 4, 14, 12))
        model.addMemoAtEntryInstant(text: "여기서 막혔다", kind: .blocker)
        XCTAssertNotEqual(model.timelineRevision, before)
    }

    /// 순간을 그리는 표식이 화소보다 얇아지면 안 된다. 붙어 있는 메모는 낱개로
    /// 그리지 않고 하나로 합친다 — 눈금판 띠와 같은 기준을 쓴다.
    func testClusteredMemosMergeIntoOneMarkerInsteadOfSlivers() throws {
        let base = makeDate(2026, 8, 4, 9, 0)
        let day = TimeSpan(
            start: makeDate(2026, 8, 4),
            end: makeDate(2026, 8, 5)
        )
        let clustered = (0..<5).map { offset in
            memoFixture(at: base.addingTimeInterval(Double(offset) * 60))
        }

        let merged = MemoTimelineEngine.markers(
            from: clustered,
            in: day,
            visibleDuration: day.duration
        )
        let marker = try XCTUnwrap(merged.first)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(marker.count, 5)
        XCTAssertEqual(marker.title, "메모 5개")
        XCTAssertEqual(marker.span.start, base)
        // 합쳐도 표식 하나 길이 아래로는 내려가지 않는다.
        XCTAssertGreaterThanOrEqual(
            marker.span.duration,
            MemoTimelineEngine.markerDuration
        )
        XCTAssertEqual(
            MemoTimelineEngine.memoIDs(in: marker.span, from: clustered),
            clustered.map(\.id)
        )

        // 표식 하나 길이보다 멀리 떨어진 메모는 합쳐지지 않는다.
        let apart = clustered + [
            memoFixture(at: base.addingTimeInterval(3_600)),
        ]
        let separate = MemoTimelineEngine.markers(
            from: apart,
            in: day,
            visibleDuration: day.duration
        )
        XCTAssertEqual(separate.map(\.count), [5, 1])
        // 이웃 표식의 메모를 끌어오지 않는다.
        XCTAssertEqual(
            MemoTimelineEngine.memoIDs(
                in: try XCTUnwrap(separate.first).span,
                from: apart
            )
            .count,
            5
        )
    }

    /// 주·월·년으로 넓힐수록 표식은 더 크게 뭉친다. 하루에서 30분씩 떨어져
    /// 보이던 메모 셋은 주 배율에서 이미 한 표식이다.
    func testMemoRowCollapsesFurtherAsTheScaleWidens() throws {
        let base = makeDate(2026, 8, 4, 9, 0)
        let memos = (0..<3).map { offset in
            memoFixture(at: base.addingTimeInterval(Double(offset) * 30 * 60))
        }
        let day = TimeSpan(
            start: makeDate(2026, 8, 4),
            end: makeDate(2026, 8, 5)
        )
        let week = TimeSpan(
            start: makeDate(2026, 8, 3),
            end: makeDate(2026, 8, 10)
        )
        let month = TimeSpan(
            start: makeDate(2026, 8, 1),
            end: makeDate(2026, 9, 1)
        )
        let year = TimeSpan(
            start: makeDate(2026, 1, 1),
            end: makeDate(2027, 1, 1)
        )

        func markers(_ span: TimeSpan) -> [MemoTimelineEngine.Marker] {
            MemoTimelineEngine.markers(
                from: memos,
                in: span,
                visibleDuration: span.duration
            )
        }

        XCTAssertEqual(markers(day).map(\.count), [1, 1, 1])
        XCTAssertEqual(markers(week).map(\.count), [3])
        XCTAssertEqual(markers(month).map(\.count), [3])
        XCTAssertEqual(markers(year).map(\.count), [3])
        XCTAssertEqual(markers(year).map(\.title), ["메모 3개"])
        // 넓은 배율일수록 더 많이 합친다.
        let intervals = [day, week, month, year].map {
            MemoTimelineEngine.clusterInterval(visibleDuration: $0.duration)
        }
        XCTAssertEqual(intervals, intervals.sorted())
        XCTAssertEqual(intervals.first, MemoTimelineEngine.markerDuration)
        // 기간 밖의 메모는 그 줄에 오르지 않는다.
        XCTAssertTrue(
            MemoTimelineEngine.markers(
                from: memos,
                in: TimeSpan(
                    start: makeDate(2026, 8, 5),
                    end: makeDate(2026, 8, 6)
                ),
                visibleDuration: 86_400
            )
            .isEmpty
        )
    }

    /// 메모는 "지금" 남기는 것이 기본이지만, 지난 기간을 펼쳐 두었다면 그
    /// 기간에 남는다. 어제에 남긴 메모는 어제에 남는다.
    func testMemoEntryInstantFollowsTheTimelineNotTheWallClock() {
        let now = makeDate(2026, 8, 4, 14, 0)
        XCTAssertEqual(
            MemoTimelineEngine.entryDate(
                now: now,
                visibleSpan: TimeSpan(
                    start: makeDate(2026, 8, 4),
                    end: makeDate(2026, 8, 5)
                )
            ),
            now
        )
        XCTAssertEqual(
            MemoTimelineEngine.entryDate(
                now: now,
                visibleSpan: TimeSpan(
                    start: makeDate(2026, 8, 3),
                    end: makeDate(2026, 8, 4)
                )
            ),
            makeDate(2026, 8, 3, 12, 0)
        )
    }

    /// Archives written before memos had their own identity carry a required
    /// `planID` and neither `categoryID` nor `occurredAt`.
    func testLegacyMemoDecodesWithPlanDerivedDefaults() throws {
        let planID = UUID()
        let createdAt = makeDate(2026, 8, 4, 9, 30)
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "planID": "\(planID.uuidString)",
          "kind": "idea",
          "text": "예전 메모",
          "attachments": [],
          "isHighlightedInReview": true,
          "createdAt": \(createdAt.timeIntervalSince1970),
          "updatedAt": \(createdAt.timeIntervalSince1970)
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let memo = try decoder.decode(
            ActionMemo.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(memo.planID, planID)
        XCTAssertNil(memo.categoryID)
        XCTAssertEqual(memo.occurredAt, createdAt)
    }

    // MARK: - 기록 화면에서 여러 칸 고르기

    func testAutomaticTimelineKeepsEveryDayPhaseRowWithoutData() {
        XCTAssertEqual(
            DayPhase.timelineRows,
            [
                .sleep, .movement, .exercise, .work, .study, .hobby, .activity,
                .appointment, .unconfirmed,
            ]
        )
    }

    /// 오늘 적은 지난주 이야기는 지난주에 남는다. 메모가 놓이는 자리는
    /// 적은 시각이 아니라 그 메모가 말하는 시각이다.
    func testHighlightedMemoLandsOnTheWeekItIsAbout() {
        let occurredAt = makeDate(2026, 8, 4, 15, 0)
        let createdAt = makeDate(2026, 8, 20, 9, 0)
        let memo = ActionMemo(
            categoryID: "activity",
            occurredAt: occurredAt,
            kind: .decision,
            text: "무릎이 아팠던 날",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let engine = ReviewEngine(calendar: utcCalendar)

        let aboutWeek = engine.report(
            for: .week,
            containing: occurredAt,
            plans: [],
            actuals: [],
            weather: [],
            photos: [],
            memos: [memo],
            asOf: createdAt
        )
        XCTAssertEqual(aboutWeek.contexts.map(\.text), ["무릎이 아팠던 날"])
        XCTAssertEqual(aboutWeek.contexts.first?.date, occurredAt)

        let writtenWeek = engine.report(
            for: .week,
            containing: createdAt,
            plans: [],
            actuals: [],
            weather: [],
            photos: [],
            memos: [memo],
            asOf: createdAt
        )
        XCTAssertTrue(writtenWeek.contexts.isEmpty)
    }

    // MARK: - 현재 층수로 보정하기

    /// 실기기 모양 그대로: 카테고리 줄에 남긴 메모는 껍데기 계획에만 붙어
    /// 있었고 분류도 시각도 저장돼 있지 않았다. 이관 뒤에도 같은 분류·같은
    /// 날에서 찾을 수 있어야 하고, 기록 탭의 "이 기간을 설명한 기록"에도
    /// 그대로 떠야 한다.
    func testMemoShellMigrationKeepsLegacyMemoReachableAndRendered() throws {
        let start = makeDate(2026, 8, 4, 9, 30)
        let shell = makeMemoShellPlan(start: start)
        let legacyMemo = ActionMemo(
            planID: shell.id,
            categoryID: nil,
            occurredAt: nil,
            kind: .idea,
            text: "운동",
            createdAt: start,
            updatedAt: start
        )
        var snapshot = makeSnapshot(plans: [shell], memos: [legacyMemo])

        MemoShellPlanMigration.apply(to: &snapshot)

        XCTAssertTrue(snapshot.plans.isEmpty)
        let lifted = try XCTUnwrap(snapshot.memos.first)
        XCTAssertEqual(snapshot.memos.count, 1)
        XCTAssertEqual(lifted.id, legacyMemo.id)
        XCTAssertEqual(lifted.text, "운동")
        XCTAssertNil(lifted.planID)
        XCTAssertNil(lifted.targetID)
        XCTAssertEqual(lifted.categoryID, "activity")
        XCTAssertEqual(lifted.occurredAt, start)

        // 기록 탭의 맥락 줄을 만드는 바로 그 엔진.
        let report = ReviewEngine(calendar: utcCalendar).report(
            for: .day,
            containing: start,
            plans: snapshot.plans,
            actuals: [],
            weather: [],
            photos: [],
            memos: snapshot.memos,
            asOf: start.addingTimeInterval(hour)
        )
        XCTAssertEqual(report.contexts.map(\.text), ["운동"])
        XCTAssertEqual(report.contexts.map(\.symbolName), ["note.text"])
    }

    /// 자동 기록 줄에 남긴 메모는 껍데기 계획과 기록 키를 함께 들고 있었다.
    /// 이관은 계획 고리만 끊고 기록 키는 그대로 둬야 한다.
    func testMemoShellMigrationKeepsAutomaticRecordTargetKey() throws {
        let start = makeDate(2026, 8, 4, 9, 30)
        let shell = makeMemoShellPlan(start: start)
        let targetID = "automatic.actual.\(UUID().uuidString)"
        var snapshot = makeSnapshot(
            plans: [shell],
            memos: [
                ActionMemo(
                    planID: shell.id,
                    targetID: targetID,
                    kind: .idea,
                    text: "무릎 상태 확인",
                    createdAt: start,
                    updatedAt: start
                ),
            ]
        )

        MemoShellPlanMigration.apply(to: &snapshot)

        let lifted = try XCTUnwrap(snapshot.memos.first)
        XCTAssertNil(lifted.planID)
        XCTAssertEqual(lifted.targetID, targetID)
        XCTAssertEqual(lifted.categoryID, "activity")
        XCTAssertEqual(lifted.occurredAt, start)

        let report = ReviewEngine(calendar: utcCalendar).report(
            for: .day,
            containing: start,
            plans: snapshot.plans,
            actuals: [],
            weather: [],
            photos: [],
            memos: snapshot.memos,
            asOf: start.addingTimeInterval(hour)
        )
        XCTAssertEqual(report.contexts.map(\.text), ["무릎 상태 확인"])
    }

    /// 저장소에서 불러오는 실제 경로를 그대로 태운다. 껍데기 계획은 사라지고
    /// 메모는 분류 줄에서 다시 찾을 수 있어야 한다.
    @MainActor
    func testMemoShellMigrationSurvivesAppLoad() async {
        let start = makeDate(2026, 8, 4, 9, 30)
        let shell = makeMemoShellPlan(start: start)
        var stored = makeSnapshot(
            plans: [shell],
            memos: [
                ActionMemo(
                    planID: shell.id,
                    kind: .idea,
                    text: "운동",
                    createdAt: start,
                    updatedAt: start
                ),
            ]
        )
        stored.updatedAt = start
        stored.categories = CategoryCatalog.builtIn
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: stored),
            cloudSyncService: nil
        )

        await model.bootstrap()
        // 이관은 첫 화면을 붙잡지 않도록 별도 작업에서 돈다.
        let deadline = Date.now.addingTimeInterval(10)
        while !model.snapshot.plans.isEmpty, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(model.snapshot.plans.isEmpty)
        XCTAssertEqual(model.snapshot.memos.count, 1)
        XCTAssertEqual(
            model.memos(forCategoryID: "activity", on: start).map(\.text),
            ["운동"]
        )
    }

}
