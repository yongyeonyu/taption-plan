import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

extension FeatureEngineTests {
    /// 확정 요약은 하루 한 행으로 저장되고, 다시 열어도 값이 그대로다.
    func testSealedDayDigestPersistsAsASingleCompactRow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("seal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TaptionStoreV2(url: directory.appendingPathComponent(TaptionStoreV2.fileName))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let sealedAt = Date(timeIntervalSince1970: 1_700_100_000)
        let digest = TaptionSealedDayBuilder.make(
            day: day,
            sealedAt: sealedAt,
            sourceFingerprint: "fingerprint-1",
            categories: ["work": 7_200, "movement": 1_800, "sleep": 0],
            metrics: ["distance": 4_200, "trips": 3],
            steps: 8_400,
            distanceMeters: 4_200,
            readings: [],
            weather: WeatherContext(
                observedAt: day.addingTimeInterval(3_600),
                condition: "Clear",
                symbolName: "sun.max.fill",
                temperatureCelsius: 18.5
            ),
            memoCount: 2,
            actualCount: 5,
            travelCount: 3,
            placeCount: 2
        )
        try await store.upsertSealedDays([digest])

        let countAfterSeal = try await store.sealedDayCount()
        XCTAssertEqual(countAfterSeal, 1)
        let storedDay = try await store.sealedDay(for: day)
        let loaded = try XCTUnwrap(storedDay)
        XCTAssertEqual(loaded.dayStart, day)
        XCTAssertEqual(loaded.sealedAt, sealedAt)
        XCTAssertEqual(loaded.sourceFingerprint, "fingerprint-1")
        XCTAssertEqual(loaded.categorySeconds["work"], 7_200)
        XCTAssertNil(loaded.categorySeconds["sleep"])
        XCTAssertEqual(loaded.metrics["distance"], 4_200)
        XCTAssertEqual(loaded.workSeconds, 7_200)
        XCTAssertEqual(loaded.stepCount, 8_400)
        XCTAssertEqual(loaded.memoCount, 2)
        XCTAssertEqual(loaded.weather?.symbolName, "sun.max.fill")
        XCTAssertTrue(loaded.matches(sourceFingerprint: "fingerprint-1"))
        XCTAssertFalse(loaded.matches(sourceFingerprint: "other"))

        // 같은 날을 다시 확정하면 한 행을 덮어쓴다.
        var revised = digest
        revised.workSeconds = 7_500
        try await store.upsertSealedDays([revised])
        let countAfterRevision = try await store.sealedDayCount()
        XCTAssertEqual(countAfterRevision, 1)
        let revisedDay = try await store.sealedDay(for: day)
        XCTAssertEqual(revisedDay?.workSeconds, 7_500)

        try await store.deleteSealedDays(
            numbers: [TaptionReadingRowCodec.dayNumber(for: day, calendar: calendar)]
        )
        let countAfterDelete = try await store.sealedDayCount()
        XCTAssertEqual(countAfterDelete, 0)
    }

    @MainActor
    func testPersistenceCancellationDoesNotSurfaceAsSaveError() async throws {
        let day = makeDate(2026, 8, 12)
        let span = TimeSpan(
            start: day.addingTimeInterval(9 * hour),
            end: day.addingTimeInterval(10 * hour)
        )
        let travel = TravelSegment(
            mode: .walking,
            span: span,
            distanceMeters: 1_000,
            confidence: .high,
            evidence: ["테스트"],
            isConfirmed: true,
            isClassificationLocked: true
        )
        var stored = TaptionDataSnapshot.empty
        stored.categories = CategoryCatalog.builtIn
        stored.travel = [travel]
        stored.settings.locationEnabled = false
        stored.settings.weatherEnabled = false
        stored.settings.healthEnabled = false
        let repository = CancellationSavePlanRepository(snapshot: stored)
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()

        let result = await model.saveActivitySectionEdit(
            ActivitySectionEditRequest(
                sourceIDs: [travel.id],
                originalSpan: span,
                originalOption: phaseOption("movement", title: "이동"),
                mode: .replace(
                    editedSpan: span,
                    option: phaseOption("work", title: "업무")
                )
            )
        )

        XCTAssertNil(result)
        XCTAssertNil(model.userFacingError)
    }

    @MainActor
    func testRepositoryLoadFailureRetriesAfterRepositoryRecovers() async {
        let storedPlan = PlanRecord(
            title: "저장된 계획",
            span: TimeSpan(
                start: Date(timeIntervalSince1970: 1_800_000_000),
                end: Date(timeIntervalSince1970: 1_800_003_600)
            ),
            categoryID: "work"
        )
        var stored = TaptionDataSnapshot.empty
        stored.categories = CategoryCatalog.builtIn
        stored.plans = [storedPlan]
        stored.updatedAt = Date(timeIntervalSince1970: 1_800_003_600)
        let repository = RecoveringLoadPlanRepository(snapshot: stored)
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )

        await model.bootstrap()
        XCTAssertFalse(model.snapshot.plans.contains { $0.id == storedPlan.id })
        XCTAssertNil(
            model.addPlan(
                title: "차단된 계획",
                categoryID: "activity",
                startAt: .now,
                duration: 3_600
            )
        )

        await model.bootstrap()

        XCTAssertTrue(model.snapshot.plans.contains { $0.id == storedPlan.id })
        XCTAssertFalse(
            AppModelMessage.isDataLoadFailure(model.userFacingError)
        )
        XCTAssertNotNil(
            model.addPlan(
                title: "복구 뒤 계획",
                categoryID: "activity",
                startAt: .now,
                duration: 3_600
            )
        )
        XCTAssertNotNil(model.addMemo(
            text: "복구 뒤 메모",
            kind: .idea,
            categoryID: "activity",
            on: .now
        ))
    }

    @MainActor
    func testConcurrentAcceptedActivityEditsPreserveLatestSnapshot() async throws {
        let day = makeDate(2026, 8, 14)
        let firstSpan = TimeSpan(
            start: day.addingTimeInterval(9 * hour),
            end: day.addingTimeInterval(10 * hour)
        )
        let secondSpan = TimeSpan(
            start: day.addingTimeInterval(11 * hour),
            end: day.addingTimeInterval(12 * hour)
        )
        let firstTravel = TravelSegment(
            mode: .walking,
            span: firstSpan,
            distanceMeters: 1_000,
            confidence: .high,
            evidence: ["첫 번째"],
            isConfirmed: true,
            isClassificationLocked: true
        )
        let secondTravel = TravelSegment(
            mode: .cycling,
            span: secondSpan,
            distanceMeters: 2_000,
            confidence: .high,
            evidence: ["두 번째"],
            isConfirmed: true,
            isClassificationLocked: true
        )
        var stored = TaptionDataSnapshot.empty
        stored.categories = CategoryCatalog.builtIn
        stored.travel = [firstTravel, secondTravel]
        stored.settings.locationEnabled = false
        stored.settings.weatherEnabled = false
        stored.settings.healthEnabled = false
        let repository = GatedSavePlanRepository(snapshot: stored)
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()

        let firstRequest = ActivitySectionEditRequest(
            sourceIDs: [firstTravel.id],
            originalSpan: firstSpan,
            originalOption: phaseOption("movement", title: "이동"),
            mode: .replace(
                editedSpan: firstSpan,
                option: phaseOption("work", title: "업무")
            )
        )
        let secondRequest = ActivitySectionEditRequest(
            sourceIDs: [secondTravel.id],
            originalSpan: secondSpan,
            originalOption: phaseOption("movement", title: "이동"),
            mode: .replace(
                editedSpan: secondSpan,
                option: phaseOption("exercise", title: "운동")
            )
        )
        let firstTask = Task { @MainActor in
            await model.saveActivitySectionEdit(firstRequest)
        }
        await repository.waitForFirstSave()
        let secondTask = Task { @MainActor in
            await model.saveActivitySectionEdit(secondRequest)
        }

        await repository.releaseFirstSave()
        _ = await firstTask.value
        _ = await secondTask.value

        let persisted = try await repository.load()
        XCTAssertTrue(
            persisted.actuals.contains {
                $0.categoryID == "work" && $0.title == "업무"
            }
        )
        XCTAssertTrue(
            persisted.actuals.contains {
                $0.categoryID == "exercise" && $0.title == "운동"
            }
        )
    }

    @MainActor
    func testSensorLocalSaveCancellationIsQuietButRealFailureSurfaces() async throws {
        var stored = TaptionDataSnapshot.empty
        stored.categories = CategoryCatalog.builtIn
        stored.settings.locationEnabled = false
        stored.settings.weatherEnabled = false
        stored.settings.healthEnabled = false

        let cancellationModel = AppModel(
            repository: CancellationSavePlanRepository(snapshot: stored),
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await cancellationModel.bootstrap()
        await cancellationModel.refreshEnabledData(
            persistDeviceSnapshot: true
        )
        XCTAssertNil(cancellationModel.userFacingError)

        let failureModel = AppModel(
            repository: RejectingSavePlanRepository(snapshot: stored),
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await failureModel.bootstrap()
        await failureModel.refreshEnabledData(
            persistDeviceSnapshot: true
        )
        XCTAssertTrue(
            failureModel.userFacingError?.hasPrefix(
                AppModelMessage.sensorSaveFailed("").lead()
            ) == true
        )
    }

    @MainActor
    func testPersistedTrackingReadingsRecoverAutomaticAndManualSessions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sensorService = AppleSensorDataService(
            archive: try SensorReadingArchive(
                fileURL: directory.appendingPathComponent("readings.jsonl")
            )
        )
        let model = AppModel(
            repository: InMemoryPlanRepository(),
            sensorService: sensorService,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        let capturedAt = Date.now.addingTimeInterval(60)

        sensorService.onReadingsPersisted?([
            SensorReading(
                timestamp: capturedAt,
                trackingSessionID: UUID(),
                trackingKind: .automatic,
                sourceDevice: .iPhone
            )
        ])
        await Task.yield()
        XCTAssertEqual(model.activeTrackingSession?.kind, .automatic)
        XCTAssertTrue(model.activeTrackingSession?.wasAutomaticallyDetected == true)

        sensorService.onReadingsPersisted?([
            SensorReading(
                timestamp: capturedAt.addingTimeInterval(1),
                trackingSessionID: UUID(),
                trackingKind: .walking,
                trackingWasAutomaticallyDetected: true,
                sourceDevice: .iPhone
            )
        ])
        await Task.yield()
        XCTAssertEqual(model.activeTrackingSession?.kind, .walking)
        XCTAssertTrue(model.activeTrackingSession?.wasAutomaticallyDetected == true)

        sensorService.onReadingsPersisted?([
            SensorReading(
                timestamp: capturedAt.addingTimeInterval(2),
                trackingSessionID: UUID(),
                trackingKind: .walking,
                trackingWasAutomaticallyDetected: false,
                sourceDevice: .iPhone
            )
        ])
        await Task.yield()
        XCTAssertEqual(model.activeTrackingSession?.kind, .walking)
        XCTAssertFalse(model.activeTrackingSession?.wasAutomaticallyDetected == true)
    }

    @MainActor
    func testLateStartupSettingsCannotReplaceLoadedHistory() async throws {
        let date = Date(timeIntervalSince1970: 1_791_250_000)
        var source = TaptionDataSnapshot.empty
        source.updatedAt = date
        source.settings.locationEnabled = false
        source.settings.healthEnabled = false
        source.settings.weatherEnabled = false
        source.actuals = [ActualRecord(planID: nil, title: "합성 원본", categoryID: "eating",
            startedAt: date, endedAt: date.addingTimeInterval(60), source: .manual,
            isClassificationLocked: true)]
        let repository = GatedStartupPlanRepository(snapshot: source, holdsStartup: true)
        await repository.releaseHistory()
        let model = AppModel(repository: repository, cloudSyncService: nil,
            registersHealthBackgroundHandler: false)
        let activation = Task { @MainActor in await model.sceneBecameActive() }
        await repository.waitUntilStartupStarted()
        await model.prepareLocalDataForDisplay()
        XCTAssertTrue(model.isBootstrapped)
        await repository.releaseStartup()
        await activation.value
        XCTAssertFalse(model.hasPreparedStartupSettings)
        XCTAssertEqual(model.snapshot.actuals, source.actuals)
        await model.bootstrap()
        await model.sceneEnteredBackground()
    }

    @MainActor
    func testStartupSettingsDoNotAllowWritesAfterHistoryLoadFails() async throws {
        var source = TaptionDataSnapshot.empty
        source.updatedAt = Date(timeIntervalSince1970: 1_791_250_000)
        source.settings.locationEnabled = false
        source.settings.healthEnabled = false
        source.settings.weatherEnabled = false
        let repository = GatedStartupPlanRepository(snapshot: source, failsHistory: true)
        let model = AppModel(repository: repository, cloudSyncService: nil,
            registersHealthBackgroundHandler: false)
        await model.sceneBecameActive()
        XCTAssertTrue(model.hasPreparedStartupSettings)
        await repository.releaseHistory()
        await model.prepareLocalDataForDisplay()
        XCTAssertTrue(model.isBootstrapped)
        XCTAssertFalse(model.hasPreparedStartupSettings)
        XCTAssertNotNil(model.userFacingError)
        XCTAssertNil(model.addPlan(title: "실패 뒤 편집", categoryID: "work",
            startAt: source.updatedAt, duration: 60))
        let saves = await repository.saves
        XCTAssertEqual(saves, 0)
        await model.sceneEnteredBackground()
    }

    @MainActor
    func testInitialSceneDoesNotWaitForBootstrapNormalizationSave() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var stored = TaptionDataSnapshot.empty
        stored.updatedAt = date
        stored.categories = CategoryCatalog.builtIn
        stored.settings.locationEnabled = false
        stored.settings.healthEnabled = false
        stored.settings.weatherEnabled = false
        stored.travel = [TravelSegment(
            mode: .walking,
            span: TimeSpan(start: date, end: date.addingTimeInterval(600)),
            distanceMeters: 500,
            confidence: .high,
            evidence: [],
            isConfirmed: true,
            isClassificationLocked: false
        )]
        let repository = GatedSavePlanRepository(snapshot: stored)
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        let sceneReady = expectation(description: "Local data is ready before save finishes")
        var sceneReadyBeforeSaveRelease = false
        let startedAt = ProcessInfo.processInfo.systemUptime
        let scene = Task { @MainActor in
            await model.sceneBecameActive()
            sceneReadyBeforeSaveRelease = true
            sceneReady.fulfill()
        }
        await fulfillment(of: [sceneReady], timeout: 1)
        let wasReady = sceneReadyBeforeSaveRelease
        let presentationMilliseconds = Int((
            ProcessInfo.processInfo.systemUptime - startedAt
        ) * 1_000)
        await repository.waitForFirstSave()
        var normalizationFinished = false
        let completeBootstrap = Task { @MainActor in
            await model.bootstrap()
            normalizationFinished = true
        }
        await Task.yield()
        XCTAssertFalse(normalizationFinished)
        await repository.releaseFirstSave()
        await scene.value
        await completeBootstrap.value
        XCTAssertTrue(wasReady)
        XCTAssertTrue(model.isBootstrapped)
        XCTAssertTrue(normalizationFinished)
        XCTAssertTrue(model.snapshot.travel.allSatisfy(\.isClassificationLocked))
        let persisted = try await repository.load()
        XCTAssertEqual(persisted.travel, model.snapshot.travel)
        print("LOG1006A01 initial_scene_ms=\(presentationMilliseconds) ready_before_save_release=\(wasReady)")
        await model.sceneEnteredBackground()
    }

    @MainActor
    func testBootstrapPreparationPreservesCorrectionAndSourceEvidence() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let original = ActualRecord(
            planID: nil, title: "원래 활동", categoryID: "activity",
            startedAt: date, endedAt: date.addingTimeInterval(600),
            source: .location,
            behavior: StationaryContextKind.unknownStay.rawValue,
            evidence: ["fixture"]
        )
        var stored = TaptionDataSnapshot.empty
        stored.updatedAt = date
        stored.actuals = [original]
        stored.settings.locationEnabled = false
        stored.settings.healthEnabled = false
        stored.settings.weatherEnabled = false
        stored.settings.activityCorrections[original.id] = ActivityCorrection(
            title: "수정된 활동", behavior: original.behavior, categoryID: "work"
        )
        let repository = InMemoryPlanRepository(snapshot: stored)
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()
        let corrected = try XCTUnwrap(model.snapshot.actuals.first)
        XCTAssertEqual(corrected.id, original.id)
        XCTAssertEqual(corrected.title, "수정된 활동")
        XCTAssertEqual(corrected.categoryID, "work")
        XCTAssertEqual(corrected.source, original.source)
        XCTAssertEqual(corrected.evidence, original.evidence)
        XCTAssertTrue(corrected.isClassificationLocked)
        XCTAssertTrue(corrected.manuallyCorrected)
        let persisted = try await repository.load()
        XCTAssertEqual(persisted.actuals, model.snapshot.actuals)
    }

    func testInitialLaunchGateKeepsSecurityAndStoredDataRequired() {
        for (securityReady, localDataReady) in [(false, true), (true, false)] {
            XCTAssertFalse(AppShellInitialLaunchGate.isReady(
                hasCompletedInitialProRefresh: true,
                isSecurityStateReady: securityReady,
                hasRenderedInitialDestination: true,
                hasCompletedInitialMapShellPreparation: true,
                isBootstrapped: localDataReady,
                grantsAccess: true
            ))
        }
    }

    /// 같은 박자로 400번 돌려도 90%를 넘지 않고, 그 자리에서 멈춘다(멈춘 게 아니라 기다리는 중).
    func testLaunchProgressParksAtTheCapUntilTheStoreIsLoaded() {
        var progress = 0.0
        for _ in 0..<400 {
            progress = AppShellInitialLaunchProgressMath.next(
                current: progress,
                target: AppShellInitialLaunchProgressMath.goal(
                    current: progress,
                    target: 0.98,
                    bootstrapped: false
                )
            )
            XCTAssertLessThanOrEqual(progress, 0.90 + 0.000_001)
        }
        XCTAssertEqual(progress, 0.90, accuracy: 0.000_001)

        // 적재가 끝난 뒤에는 97%까지 올라가고, 1.0은 걷는 순간에만 온다.
        for _ in 0..<400 {
            progress = AppShellInitialLaunchProgressMath.next(
                current: progress,
                target: AppShellInitialLaunchProgressMath.goal(
                    current: progress,
                    target: 0.98,
                    bootstrapped: true
                )
            )
            XCTAssertLessThanOrEqual(progress, 0.97 + 0.000_001)
        }
        XCTAssertEqual(progress, 0.97, accuracy: 0.000_001)
    }

    func testCanonicalAnalysisDoesNotMutateStoredRecord() {
        let record = ActualRecord(
            planID: nil,
            title: "집에서 휴식",
            categoryID: "rest",
            startedAt: makeDate(2026, 8, 13, 9, 0),
            endedAt: makeDate(2026, 8, 13, 10, 0),
            source: .location,
            behavior: StationaryContextKind.homeRest.rawValue
        )

        XCTAssertEqual(
            RecordAnalysisCategoryPolicy.categoryID(for: record),
            "activity"
        )
        XCTAssertEqual(
            RecordAnalysisCategoryNormalizer.categoryID(
                for: record.categoryID,
                title: record.title,
                behavior: record.behavior
            ),
            "activity"
        )
        XCTAssertEqual(record.categoryID, "rest")
        XCTAssertEqual(record.title, "집에서 휴식")
    }

    @MainActor
    func testSceneActivationPublishesLocalSnapshotBeforeDeferredRefresh()
        async {
        let updatedAt = makeDate(2026, 8, 12, 9, 0)
        var stored = TaptionDataSnapshot.empty
        stored.updatedAt = updatedAt
        stored.settings.locationEnabled = false
        stored.settings.healthEnabled = false
        stored.settings.weatherEnabled = false
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: stored),
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )

        await model.sceneBecameActive()

        XCTAssertTrue(model.isBootstrapped)
        XCTAssertEqual(model.snapshot.updatedAt, updatedAt)

        await model.sceneEnteredBackground()
    }

    func testHistoricalDailyBackupSurvivesMissingLocalSource() throws {
        let start = makeDate(2026, 2, 10, 9)
        let firstAsOf = makeDate(2026, 2, 11)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.actuals = [
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: start,
                endedAt: start.addingTimeInterval(2 * hour),
                source: .manual
            )
        ]
        snapshot.yearlyReports = try ReviewReportArchiveEngine.refreshed(
            snapshot: snapshot,
            asOf: firstAsOf,
            calendar: utcCalendar
        )
        snapshot.actuals = []

        let recovered = try ReviewReportArchiveEngine.refreshed(
            snapshot: snapshot,
            asOf: makeDate(2026, 2, 12),
            calendar: utcCalendar
        )
        let archivedDay = recovered[0].days.first { $0.span.contains(start) }

        XCTAssertEqual(
            archivedDay?.groups.first { $0.id == "work" }?.duration,
            2 * hour
        )
    }

    func testCloudRecoveryMergesDifferentDailyReportsInSameYear() throws {
        let first = makeDate(2026, 3, 2, 9)
        let second = makeDate(2026, 3, 8, 10)
        let asOf = makeDate(2026, 3, 10)
        var local = TaptionDataSnapshot.empty
        local.updatedAt = asOf
        local.actuals = [
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: first,
                endedAt: first.addingTimeInterval(hour),
                source: .manual
            )
        ]
        local.yearlyReports = try ReviewReportArchiveEngine.refreshed(
            snapshot: local,
            asOf: asOf,
            calendar: utcCalendar
        )
        var remote = TaptionDataSnapshot.empty
        remote.updatedAt = asOf.addingTimeInterval(-hour)
        remote.actuals = [
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: second,
                endedAt: second.addingTimeInterval(2 * hour),
                source: .manual
            )
        ]
        remote.yearlyReports = try ReviewReportArchiveEngine.refreshed(
            snapshot: remote,
            asOf: asOf,
            calendar: utcCalendar
        )

        let recovered = CloudSnapshotRecoveryEngine.merge(
            local: local,
            remote: remote
        )
        let work = recovered.yearlyReports[0].report.categories.first {
            $0.categoryID == "work"
        }

        XCTAssertTrue(recovered.yearlyReports[0].days.contains {
            $0.span.contains(first)
        })
        XCTAssertTrue(recovered.yearlyReports[0].days.contains {
            $0.span.contains(second)
        })
        XCTAssertEqual(work?.actual, 3 * hour)
    }

    func testSnapshotWithoutYearlyReportsDecodesAsEmptyArchive() throws {
        let data = try JSONEncoder().encode(TaptionDataSnapshot.empty)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "yearlyReports")

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            TaptionDataSnapshot.self,
            from: legacy
        )

        XCTAssertTrue(decoded.yearlyReports.isEmpty)
    }

    @MainActor
    func testAppleTransportEnrichmentPersistsConfirmedMagongnaruGeomamGajeongJourney() async throws {
        let base = makeDate(2026, 8, 18, 20, 22)
        let samples: [(Double, Double, Double)] = [
            (0, 37.5667, 126.8273),
            (5, 37.5667, 126.8273),
            (6, 37.5600, 126.8273),
            (10, 37.5590, 126.8273),
            (20, 37.5692, 126.6737),
            (25, 37.5692, 126.6737),
            (26, 37.5680, 126.6737),
            (30, 37.5670, 126.6737),
            (40, 37.5248, 126.6744),
            (45, 37.5248, 126.6744),
            (46, 37.5500, 126.7500),
            (47, 37.5500, 126.7500),
        ]
        let readings = samples.map { minute, latitude, longitude in
            SensorReading(
                timestamp: base.addingTimeInterval(minute * 60),
                point: GeoPoint(
                    latitude: latitude,
                    longitude: longitude,
                    altitude: 20,
                    horizontalAccuracy: 12,
                    verticalAccuracy: 8
                ),
                speedMetersPerSecond: minute == 0 || minute == 5
                    || minute == 20 || minute == 25 ? 0 : 12,
                motion: minute == 0 || minute == 5
                    || minute == 20 || minute == 25
                    ? .stationary : .automotive,
                motionConfidence: .high
            )
        }

        let service = AppleTransportContextService()
        let enriched = await service.enriching(readings)
        let railReadings = enriched.filter(\.matchesRailRoute)

        XCTAssertGreaterThanOrEqual(railReadings.count, 4)
        XCTAssertEqual(railReadings.first?.nearbyStationName, "마곡나루")
        XCTAssertEqual(
            railReadings.last?.nearbyStationName,
            "가정"
        )
        let result = TravelModeClassifier().classify(readings: enriched)
        XCTAssertEqual(result.mode, .subway)
        XCTAssertEqual(result.subwayRoute?.transferStationNames, ["검암"])
        XCTAssertEqual(result.subwayRoute?.stops.first?.stationName, "마곡나루")
        XCTAssertEqual(result.subwayRoute?.stops.last?.stationName, "가정")
    }

    func testResolvingOverlapsHandlesLargeArchiveWithoutUnboundedPasses() {
        let base = makeDate(2026, 8, 4, 10, 0)
        let segments = (0..<4_667).map { index in
            TravelSegment(
                mode: .walking,
                span: TimeSpan(
                    start: base.addingTimeInterval(Double(index) * 30),
                    end: base.addingTimeInterval(Double(index) * 30 + 120)
                ),
                distanceMeters: 100,
                confidence: .medium,
                evidence: ["GPS"]
            )
        }

        measure {
            let resolved = AppleDeviceGroundTruthEngine.resolvingOverlaps(
                segments
            )
            XCTAssertTrue(
                zip(resolved, resolved.dropFirst()).allSatisfy {
                    $0.span.intersection(with: $1.span) == nil
                }
            )
        }
    }

    func testSensorArchivePersistsFullHistoryWithoutRetentionPruning() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("taption-sensors-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("readings.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = try SensorReadingArchive(
            fileURL: fileURL
        )
        let now = makeDate(2026, 7, 30, 12, 0)
        let motion = DeviceMotionSnapshot(
            gravity: SensorVector3(x: 0, y: 0, z: -1),
            userAcceleration: SensorVector3(x: 0.1, y: 0, z: 0),
            rotationRate: SensorVector3(x: 0, y: 0.2, z: 0),
            attitudeRadians: SensorVector3(x: 0, y: 0, z: 1)
        )
        try await archive.append(
            SensorReading(
                timestamp: now.addingTimeInterval(-2 * 86_400),
                motion: .walking,
                stepCount: 100
            ),
            now: now
        )
        try await archive.append(
            SensorReading(
                timestamp: now,
                motion: .running,
                stepCount: 220,
                deviceMotion: motion
            ),
            now: now
        )
        try await archive.compact(now: now)

        let reopened = try SensorReadingArchive(
            fileURL: fileURL
        )
        let restored = try await reopened.readings(
            in: TimeSpan(
                start: now.addingTimeInterval(-3 * 86_400),
                end: now.addingTimeInterval(hour)
            )
        )
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored[0].motion, .walking)
        XCTAssertEqual(restored[0].stepCount, 100)
        XCTAssertEqual(restored[1].motion, .running)
        XCTAssertEqual(restored[1].stepCount, 220)
        XCTAssertEqual(restored[1].deviceMotion, motion)
    }

    @MainActor
    func testSnapshotExportRemovesStaleTemporaryFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaptionPlanExport", isDirectory: true)
        let stale = directory.appendingPathComponent("stale.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("private".utf8).write(to: stale)
        let model = AppModel(
            repository: InMemoryPlanRepository(),
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )

        let export = try model.exportSnapshotURL()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.path))
        XCTAssertEqual(export.lastPathComponent, "Taption-Plan-Data.json")
    }

    func testSnapshotCompressionRejectsOversizedHeaderBeforeAllocation() {
        var stored = Data([0x54, 0x50, 0x5A, 0x31])
        let oversized = UInt64(64 * 1_024 * 1_024 + 1)
        for shift in stride(from: 0, to: 64, by: 8) {
            stored.append(UInt8((oversized >> UInt64(shift)) & 0xFF))
        }
        stored.append(0)

        XCTAssertEqual(TaptionSnapshotCompression.decode(stored), stored)
    }

    func testBiometricProtectedSnapshotCodecEncryptsCompressedSnapshot() throws {
        var snapshot = TaptionDataSnapshot.empty
        snapshot.categories = CategoryCatalog.builtIn
        snapshot.plans = [
            PlanRecord(
                title: "보호 기록",
                span: TimeSpan(
                    start: makeDate(2026, 8, 18, 9),
                    end: makeDate(2026, 8, 18, 10)
                ),
                categoryID: "activity"
            ),
        ]
        let key = Data(repeating: 0x5A, count: 32)
        let archive = try BiometricProtectedSnapshotCodec.archive(
            snapshot: snapshot,
            keyData: key,
            now: makeDate(2026, 8, 18, 11)
        )

        let restored = try BiometricProtectedSnapshotCodec.snapshot(
            from: archive,
            keyData: key
        )

        XCTAssertEqual(archive.version, BiometricProtectedSnapshotArchive.currentVersion)
        XCTAssertEqual(restored.schemaVersion, snapshot.schemaVersion)
        XCTAssertEqual(restored.plans.map(\.title), snapshot.plans.map(\.title))
        XCTAssertEqual(restored.plans.map(\.span), snapshot.plans.map(\.span))
        XCTAssertEqual(restored.categories.map(\.id), snapshot.categories.map(\.id))
        XCTAssertThrowsError(
            try BiometricProtectedSnapshotCodec.snapshot(
                from: archive,
                keyData: Data(repeating: 0xA5, count: 32)
            )
        )
    }

    @MainActor
    func testDisabledCommerceGrantsAccessWithoutLoadingAProduct() async throws {
        let suiteName = "commerce-disabled-\(UUID().uuidString)"
        let localStore = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { localStore.removePersistentDomain(forName: suiteName) }
        let expiredStart = makeDate(2026, 8, 1, 12)
        let persistence = TaptionProTrialPersistence(
            cloudStore: nil,
            localStore: localStore,
            keychainService: nil
        )
        _ = persistence.startTrial(at: expiredStart)
        let controller = TaptionProAccessController(
            trialPersistence: persistence,
            now: makeDate(2026, 9, 7, 12)
        )

        await controller.refresh()
        await controller.purchase()
        await controller.restore()

        XCTAssertTrue(controller.grantsAccess)
        XCTAssertNil(controller.product)
        XCTAssertNil(controller.message)
        XCTAssertFalse(controller.isActionInFlight)
    }

    @MainActor
    func testStoreKitProductPurchaseEntitlementAndRestore() async throws {
        #if targetEnvironment(simulator)
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        if osVersion.majorVersion == 26, osVersion.minorVersion == 5 {
            throw XCTSkip("iOS 26.5 StoreKitTest fails with SKInternalErrorDomain Code 3")
        }
        #endif

        let configurationURL = try XCTUnwrap(
            Bundle(for: FeatureEngineTests.self).url(
                forResource: "Products",
                withExtension: "storekit"
            )
        )
        let session = try SKTestSession(contentsOf: configurationURL)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        defer {
            session.clearTransactions()
            session.resetToDefaultState()
        }

        func waitForEntitlement(
            _ service: StoreKitPurchaseService,
            expected: Bool
        ) async -> Bool {
            let deadline = Date.now.addingTimeInterval(5)
            repeat {
                if await service.hasProEntitlement() == expected { return true }
                try? await Task.sleep(for: .milliseconds(50))
            } while Date.now < deadline
            return false
        }

        let suiteName = "storekit-access-\(UUID().uuidString)"
        let localStore = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { localStore.removePersistentDomain(forName: suiteName) }
        let purchaseService = StoreKitPurchaseService()
        let controller = TaptionProAccessController(
            purchaseService: purchaseService,
            trialPersistence: TaptionProTrialPersistence(
                cloudStore: nil,
                localStore: localStore,
                keychainService: nil
            )
        )
        let loadedProduct = try await purchaseService.loadProProduct()
        let product = try XCTUnwrap(loadedProduct)
        let entitlementBeforePurchase = await purchaseService.hasProEntitlement()
        await controller.purchase()
        let entitlementAfterPurchase = await waitForEntitlement(
            purchaseService,
            expected: true
        )
        session.clearTransactions()
        let entitlementCleared = await waitForEntitlement(
            purchaseService,
            expected: false
        )
        guard entitlementCleared else {
            XCTFail("StoreKit test transaction did not clear")
            return
        }
        _ = try await session.buyProduct(
            identifier: TaptionCommercePolicy.proProductID
        )
        let restoreService = StoreKitPurchaseService()
        let externalEntitlement = await waitForEntitlement(
            restoreService,
            expected: true
        )
        guard externalEntitlement else {
            XCTFail("External StoreKit purchase did not become an entitlement")
            return
        }
        let restored = try await restoreService.restorePurchases()

        XCTAssertEqual(product.id, TaptionCommercePolicy.proProductID)
        XCTAssertFalse(entitlementBeforePurchase)
        if TaptionCommercePolicy.supportsPaidPurchase {
            XCTAssertTrue(controller.hasPermanentAccess)
            XCTAssertTrue(entitlementAfterPurchase)
        } else {
            // 결제 판매 보류 중(`supportsPaidPurchase == false`)에는 컨트롤러가 구매를 시작하지 않는다. 이전에는 이 두 단언이
            // 항상 실패했다. 서비스 자체의 구매·외부 구매 반영·복원은 위 흐름과 아래 단언으로 계속 확인한다.
            XCTAssertFalse(controller.hasPermanentAccess)
            XCTAssertFalse(entitlementAfterPurchase)
        }
        XCTAssertTrue(restored)
    }

    @MainActor
    func testProTrialPersistenceRestoresLocalRecordAcrossInstances() throws {
        let suiteName = "TaptionPlanTests.proTrial.\(UUID().uuidString)"
        let localStore = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        localStore.removePersistentDomain(forName: suiteName)
        defer { localStore.removePersistentDomain(forName: suiteName) }

        let start = makeDate(2026, 8, 23, 12)
        let first = TaptionProTrialPersistence(
            cloudStore: nil,
            localStore: localStore,
            keychainService: nil
        )
        XCTAssertEqual(first.startTrial(at: start).startedAt, start)

        let second = TaptionProTrialPersistence(
            cloudStore: nil,
            localStore: localStore,
            keychainService: nil
        )
        let restored = try XCTUnwrap(
            second.record(observedAt: start.addingTimeInterval(86_400))
        )

        XCTAssertEqual(restored.startedAt, start)
        XCTAssertEqual(
            restored.lastObservedAt,
            start.addingTimeInterval(86_400)
        )
    }

    func testSettingsMigrationDefaultsNotificationToggleToOff() throws {
        let encoded = try JSONEncoder().encode(AppFeatureSettings.defaults)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        object.removeValue(forKey: "notificationsEnabled")
        object.removeValue(forKey: "movementCorrections")
        object.removeValue(forKey: "suppressedActualIDs")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let migrated = try JSONDecoder().decode(
            AppFeatureSettings.self,
            from: legacyData
        )

        XCTAssertFalse(migrated.notificationsEnabled)
        XCTAssertTrue(migrated.movementCorrections.isEmpty)
        XCTAssertTrue(migrated.suppressedActualIDs.isEmpty)
        XCTAssertEqual(migrated.startScale, .day)
        XCTAssertEqual(
            migrated.permissions.count,
            PermissionFeature.allCases.count
        )
        XCTAssertEqual(migrated.timelineRowOrder, TimelineRowOrder.defaults)
    }

    func testCloudKitRequiresExactContainerEntitlement() {
        XCTAssertFalse(
            CloudKitEntitlementPolicy.canInitialize(
                containerIdentifier: "iCloud.com.taption.plan",
                embeddedProfileData: nil
            )
        )
        XCTAssertFalse(
            CloudKitEntitlementPolicy.canInitialize(
                containerIdentifier: "iCloud.com.taption.plan",
                embeddedProfileData: Data(
                    "iCloud.com.example.other".utf8
                )
            )
        )
        XCTAssertTrue(
            CloudKitEntitlementPolicy.canInitialize(
                containerIdentifier: "iCloud.com.taption.plan",
                embeddedProfileData: Data(
                    """
                    <key>com.apple.developer.icloud-container-identifiers</key>
                    <array><string>iCloud.com.taption.plan</string></array>
                    """.utf8
                )
            )
        )
    }

    func testCloudKitProductionSchemaErrorIsHandledAsUnavailable() {
        let error = NSError(
            domain: "CKErrorDomain",
            code: 15,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Cannot create new type TaptionSnapshot in production schema"
            ]
        )
        XCTAssertTrue(
            CloudKitErrorPolicy.isProductionSchemaUnavailable(error)
        )
        XCTAssertFalse(
            CloudKitErrorPolicy.isProductionSchemaUnavailable(
                NSError(domain: "CKErrorDomain", code: 3)
            )
        )
        XCTAssertEqual(
            CloudUnavailableReason.schemaMissing.statusLabel(preference: .korean),
            "서버 설정 필요"
        )
        XCTAssertTrue(
            CloudUnavailableReason.schemaMissing.guidance.contains("Production")
        )
    }

    func testCloudKitRecordConflictRecognizesCodeAndOplockMessage() {
        XCTAssertTrue(
            CloudKitErrorPolicy.isRecordConflict(
                NSError(domain: "CKErrorDomain", code: 14)
            )
        )
        XCTAssertTrue(
            CloudKitErrorPolicy.isRecordConflict(
                NSError(
                    domain: "CKInternalErrorDomain",
                    code: 2_000,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "client oplock error updating record"
                    ]
                )
            )
        )
        XCTAssertFalse(
            CloudKitErrorPolicy.isRecordConflict(
                NSError(domain: "CKErrorDomain", code: 3)
            )
        )
    }

    func testCloudKitTempAssetCleanupPreservesFreshAndUnrelatedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let now = Date.now
        let stale = root.appendingPathComponent("taption-cloud-stale.json")
        let fresh = root.appendingPathComponent("taption-cloud-fresh.json")
        let unrelated = root.appendingPathComponent("other.json")
        for url in [stale, fresh, unrelated] {
            try Data("payload".utf8).write(to: url)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7_200)],
            ofItemAtPath: stale.path
        )

        XCTAssertEqual(
            CloudKitSnapshotSyncService.removeStaleTemporaryAssets(
                in: root,
                before: now.addingTimeInterval(-3_600)
            ),
            1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @MainActor
    func testUnchangedPermissionRefreshDoesNotSaveOrPublishNewSnapshot() async throws {
        let repository = PermissionCountingPlanRepository()
        let model = AppModel(
            repository: repository, cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.refreshPermissions()
        try await Task.sleep(for: .seconds(2))
        let writes = await repository.saveCount
        let revision = model.snapshotRevision
        let settings = model.snapshot.settings

        async let first: Void = model.refreshPermissions()
        async let second: Void = model.refreshPermissions()
        _ = await (first, second)
        await model.refreshPermissions()
        try await Task.sleep(for: .seconds(2))

        let finalWrites = await repository.saveCount
        XCTAssertEqual(finalWrites, writes)
        XCTAssertEqual(model.snapshotRevision, revision)
        XCTAssertEqual(model.snapshot.settings, settings)
    }

    func testCloudRecoveryRestoresRecordsMissingFromNewerLocalSnapshot() {
        let base = makeDate(2026, 8, 9, 9)
        let localPlan = PlanRecord(
            title: "로컬 계획",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "activity",
            updatedAt: base.addingTimeInterval(2 * hour)
        )
        let cloudPlan = PlanRecord(
            title: "백업 계획",
            span: TimeSpan(
                start: base.addingTimeInterval(2 * hour),
                end: base.addingTimeInterval(3 * hour)
            ),
            categoryID: "activity",
            updatedAt: base
        )
        let cloudMemo = ActionMemo(
            planID: cloudPlan.id,
            kind: .decision,
            text: "백업 메모",
            createdAt: base,
            updatedAt: base
        )
        var local = TaptionDataSnapshot.empty
        local.updatedAt = base.addingTimeInterval(3 * hour)
        local.plans = [localPlan]
        var remote = TaptionDataSnapshot.empty
        remote.updatedAt = base.addingTimeInterval(hour)
        remote.plans = [cloudPlan]
        remote.memos = [cloudMemo]

        let recovered = CloudSnapshotRecoveryEngine.merge(
            local: local,
            remote: remote
        )

        XCTAssertEqual(Set(recovered.plans.map(\.id)), [localPlan.id, cloudPlan.id])
        XCTAssertEqual(recovered.memos, [cloudMemo])
        XCTAssertEqual(recovered.updatedAt, local.updatedAt)
    }

    func testCloudRecoveryUsesNewestVersionOfSameRecord() {
        let base = makeDate(2026, 8, 9, 10)
        let id = UUID()
        let localPlan = PlanRecord(
            id: id,
            title: "이전 제목",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "activity",
            updatedAt: base
        )
        let cloudPlan = PlanRecord(
            id: id,
            title: "최신 제목",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "activity",
            updatedAt: base.addingTimeInterval(hour)
        )
        var local = TaptionDataSnapshot.empty
        local.updatedAt = base.addingTimeInterval(2 * hour)
        local.plans = [localPlan]
        var remote = TaptionDataSnapshot.empty
        remote.updatedAt = base.addingTimeInterval(hour)
        remote.plans = [cloudPlan]

        let recovered = CloudSnapshotRecoveryEngine.merge(
            local: local,
            remote: remote
        )

        XCTAssertEqual(recovered.plans, [cloudPlan])
    }

    func testCloudRecoveryDoesNotResurrectDeletedRecords() {
        let base = makeDate(2026, 8, 9, 11)
        let plan = PlanRecord(
            title: "삭제한 계획",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "activity"
        )
        let memo = ActionMemo(
            planID: plan.id,
            kind: .idea,
            text: "삭제한 메모"
        )
        let actual = ActualRecord(
            planID: nil,
            title: "삭제한 기록",
            categoryID: "activity",
            startedAt: base,
            endedAt: base.addingTimeInterval(hour),
            source: .manual
        )
        var local = TaptionDataSnapshot.empty
        local.updatedAt = base.addingTimeInterval(2 * hour)
        local.settings.cloudDeletedRecordKeys = [
            CloudBackupRecordKey.plan(plan.id),
            CloudBackupRecordKey.memo(memo.id),
        ]
        local.settings.suppressedActualIDs = [actual.id]
        var remote = TaptionDataSnapshot.empty
        remote.updatedAt = base
        remote.plans = [plan]
        remote.memos = [memo]
        remote.actuals = [actual]

        let recovered = CloudSnapshotRecoveryEngine.merge(
            local: local,
            remote: remote
        )

        XCTAssertTrue(recovered.plans.isEmpty)
        XCTAssertTrue(recovered.memos.isEmpty)
        XCTAssertTrue(recovered.actuals.isEmpty)
    }

    func testCloudRecoveryKeepsExplicitFullReset() {
        let base = makeDate(2026, 8, 9, 12)
        var reset = TaptionDataSnapshot.empty
        reset.updatedAt = base
        reset.settings.cloudResetAt = base
        var staleDevice = TaptionDataSnapshot.empty
        staleDevice.updatedAt = base.addingTimeInterval(hour)
        staleDevice.plans = [
            PlanRecord(
                title: "초기화 전 계획",
                span: TimeSpan(
                    start: base,
                    end: base.addingTimeInterval(hour)
                ),
                categoryID: "activity"
            )
        ]

        let recovered = CloudSnapshotRecoveryEngine.merge(
            local: reset,
            remote: staleDevice
        )

        XCTAssertEqual(recovered, reset)
    }

    func testScreenTimeRetriesTransientDeviceActivityStoreErrorOnly() {
        let transient = NSError(
            domain: "DeviceActivity.DeviceActivityDataStore.DataStoreError",
            code: 0
        )
        let denied = NSError(
            domain: "DeviceActivity.DeviceActivityDataStore.DataStoreError",
            code: 2
        )

        XCTAssertTrue(ScreenTimeUsageRetryPolicy.shouldRetry(transient))
        XCTAssertFalse(ScreenTimeUsageRetryPolicy.shouldRetry(denied))
        XCTAssertEqual(ScreenTimeUsageRetryPolicy.maximumAttempts, 3)
    }

    @MainActor
    func testResetSettingsRestoresDefaultsAndReloadsPersistedState() async throws {
        let plan = PlanRecord(
            title: "남겨 둘 계획",
            span: TimeSpan(
                start: makeDate(2026, 8, 4, 9),
                end: makeDate(2026, 8, 4, 10)
            ),
            categoryID: "activity"
        )
        var stored = TaptionDataSnapshot.empty
        stored.updatedAt = .now
        stored.plans = [plan]
        stored.settings.startScale = .month
        stored.settings.rememberLastScale = true
        stored.settings.reduceMotion = true
        let repository = InMemoryPlanRepository(snapshot: stored)
        let model = AppModel(repository: repository, cloudSyncService: nil)

        await model.resetSettingsToDefaults()

        XCTAssertEqual(model.settings, .defaults)
        XCTAssertEqual(model.snapshot.plans.map(\.id), [plan.id])
        let persisted = try await repository.load()
        XCTAssertEqual(persisted.settings, .defaults)
        XCTAssertEqual(persisted.plans.map(\.id), [plan.id])
    }

    // MARK: - 메모 줄

    @MainActor
    func testTimestampOnlyPersistenceKeepsDayProjectionCacheRevision() async {
        let model = AppModel(
            repository: InMemoryPlanRepository(),
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        let snapshotRevision = model.snapshotRevision
        let dayRevision = model.dayProjectionRevision
        let timelineRevision = model.timelineRevision

        await model.setCalendarEnabled(false)
        let firstSaveDayRevision = model.dayProjectionRevision
        let firstSaveTimelineRevision = model.timelineRevision
        await model.setCalendarEnabled(false)

        XCTAssertGreaterThan(model.snapshotRevision, snapshotRevision)
        XCTAssertEqual(firstSaveDayRevision, dayRevision)
        XCTAssertEqual(model.dayProjectionRevision, firstSaveDayRevision)
        XCTAssertEqual(firstSaveTimelineRevision, timelineRevision)
        XCTAssertEqual(model.timelineRevision, firstSaveTimelineRevision)
    }

    /// 고른 칸을 모두 끄면 지금까지의 화면(기간 하나)으로 돌아간다. 지난
    /// 기간의 칸만 남아 있을 때도 마찬가지라 빈 화면에 갇히지 않는다.
    func testClearingBucketSelectionRestoresWholePeriod() {
        let engine = TimelineAggregationEngine(calendar: utcCalendar)
        let asOf = makeDate(2026, 9, 1)
        let date = makeDate(2026, 8, 15)
        let period = engine.interval(for: .month, containing: date)
        let buckets = ReviewSelectionEngine.buckets(
            for: .month,
            in: period,
            calendar: engine.calendar
        )
        let actual = ActualRecord(
            planID: nil,
            title: "학습",
            categoryID: "study",
            startedAt: makeDate(2026, 8, 12, 9, 0),
            endedAt: makeDate(2026, 8, 12, 10, 0),
            source: .manual
        )

        XCTAssertEqual(
            ReviewSelectionEngine.spans(
                period: period,
                buckets: buckets,
                selectedIDs: []
            ),
            [period]
        )
        XCTAssertEqual(
            ReviewSelectionEngine.spans(
                period: period,
                buckets: buckets,
                selectedIDs: ["지난 달에 고른 칸"]
            ),
            [period]
        )

        let review = ReviewEngine(calendar: utcCalendar)
        let cleared = review.report(
            over: [period],
            plans: [],
            actuals: [actual],
            weather: [],
            photos: [],
            memos: [],
            asOf: asOf
        )
        let single = review.report(
            for: .month,
            containing: date,
            plans: [],
            actuals: [actual],
            weather: [],
            photos: [],
            memos: [],
            asOf: asOf
        )
        XCTAssertEqual(cleared.span, single.span)
        XCTAssertEqual(cleared.categories, single.categories)
        XCTAssertEqual(cleared.actualDuration, single.actualDuration)
        XCTAssertEqual(cleared.actualDuration, hour)
    }

    /// 판독은 7일만 보관한다. 보관 기간이 지난 날을 열면 문맥을 다시 만들
    /// 근거가 없는데, 그렇다고 저장된 근무·수업 기록까지 지우면 되살릴 원본이
    /// 없다. 근거가 없는 갱신은 아무것도 지우지 않는다.
    @MainActor
    func testRefreshingADayWithoutArchivedReadingsKeepsStoredContextRecords()
        async throws {
        let day = makeDate(2026, 6, 1)
        let stored = ActualRecord(
            planID: nil,
            title: "근무",
            categoryID: "work",
            startedAt: makeDate(2026, 6, 1, 10),
            endedAt: makeDate(2026, 6, 1, 18),
            source: .location,
            confidence: .medium,
            createdAt: makeDate(2026, 6, 1, 10),
            behavior: "work",
            modelVersion: StationaryContextClassifier.modelVersion
        )
        var snapshot = makeSnapshot(actuals: [stored])
        snapshot.updatedAt = day
        snapshot.settings.locationEnabled = false
        snapshot.settings.weatherEnabled = false
        snapshot.settings.healthEnabled = false
        // 사진에 남은 위치 한 점만으로도 갱신은 판독 없이 끝까지 진행한다.
        snapshot.photos = [
            PhotoMoment(
                id: "photo-1",
                capturedAt: makeDate(2026, 6, 1, 12),
                pixelWidth: 100,
                pixelHeight: 100,
                isFavorite: false,
                isHiddenFromTimeline: false,
                location: GeoPoint(
                    latitude: 37.5,
                    longitude: 127.0,
                    altitude: 30,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 10
                )
            ),
        ]

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: snapshot),
            sensorService: AppleSensorDataService(
                archive: try SensorReadingArchive(
                    fileURL: directory
                        .appendingPathComponent("sensor-readings.jsonl")
                )
            ),
            cloudSyncService: nil
        )
        await model.bootstrap()
        // 불러오기 뒷정리가 끝난 뒤에 갱신해야 결과가 되돌려지지 않는다.
        let deadline = Date.now.addingTimeInterval(10)
        while model.snapshot.categories.isEmpty, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.snapshot.categories.isEmpty)

        await model.refreshSensorTimeline(containing: day)

        XCTAssertEqual(
            model.snapshot.actuals
                .filter { $0.source == .location }
                .map(\.id),
            [stored.id]
        )
    }

    func testDiagnosticsICloudExporterKeepsSourceAndAvoidsCollision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let package = root.appendingPathComponent("TaptionLogs-test.txt")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try "diagnostics".write(to: package, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let exporter = TaptionPlanDiagnosticsICloudExporter(
            ubiquityContainerURL: { root.appendingPathComponent("iCloud") },
            transferItem: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
            }
        )

        let first = try exporter.export(package)
        let second = try exporter.export(package)

        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(second.lastPathComponent, "TaptionLogs-test-2.txt")
        let manifestURL = first.deletingLastPathComponent()
            .appendingPathComponent(TaptionDiagnosticsLatestLogManifest.fileName)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifestDecoder = JSONDecoder()
        manifestDecoder.dateDecodingStrategy = .iso8601
        let manifest = try manifestDecoder.decode(
            TaptionDiagnosticsLatestLogManifest.self,
            from: manifestData
        )
        XCTAssertEqual(manifest.fileName, second.lastPathComponent)
        XCTAssertEqual(manifest.byteCount, "diagnostics".utf8.count)
    }

}
