import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

extension FeatureEngineTests {
    func testMapZoomScaleRunsFromZeroAtMaxZoomOutToHundredAtMaxZoomIn() {
        typealias Zoom = MapHomeCameraZoomMath
        XCTAssertEqual(Zoom.scale(distance: Zoom.minimumDistance), 100)
        XCTAssertEqual(Zoom.scale(distance: Zoom.maximumDistance), 0)
        XCTAssertEqual(Zoom.scale(distance: Zoom.minimumDistance / 2), 100, "한계를 넘어도 100")
        XCTAssertEqual(Zoom.scale(distance: Zoom.maximumDistance * 2), 0, "한계를 넘어도 0")
        let geometricMean = (Zoom.minimumDistance * Zoom.maximumDistance).squareRoot()
        XCTAssertEqual(Zoom.scale(distance: geometricMean), 50)
        XCTAssertNil(Zoom.scale(distance: nil))
        XCTAssertNil(Zoom.scale(distance: 0))
        // 확대할수록 값이 커진다.
        XCTAssertGreaterThan(Zoom.scale(distance: 500) ?? 0, Zoom.scale(distance: 15_000) ?? 0)
        // 확대·축소 버튼이 한계에서 막히는 지점과 100·0이 일치한다.
        XCTAssertTrue(Zoom.isAtLimit(distance: Zoom.minimumDistance, direction: 1))
        XCTAssertTrue(Zoom.isAtLimit(distance: Zoom.maximumDistance, direction: -1))
    }

    func testFogRevealFollowsTheDrawnStickmanPointWhenAvailable() {
        let stickman = CGPoint(x: 120, y: 340)
        let viewport = CGPoint(x: 150, y: 380)
        XCTAssertEqual(MapHomeFogRevealPolicy.currentLocationPoint(stickmanPoint: stickman, viewportPoint: viewport), stickman)
        XCTAssertEqual(MapHomeFogRevealPolicy.currentLocationPoint(stickmanPoint: nil, viewportPoint: viewport), viewport)
        XCTAssertNil(MapHomeFogRevealPolicy.currentLocationPoint(stickmanPoint: nil, viewportPoint: nil))
    }

    /// PSP1111A01: 여권 책장 앞뒤 번호. 쪽 수가 줄어도 없는 쪽을 찾지 않는다.
    func testPassportPagingStaysInRange() {
        XCTAssertNil(MapHomePassportPaging.previous(of: 0, pageCount: 9))
        XCTAssertEqual(MapHomePassportPaging.previous(of: 3, pageCount: 9), 2)
        XCTAssertEqual(MapHomePassportPaging.previous(of: 10, pageCount: 9), 8, "page count shrank while on page 10")
        XCTAssertNil(MapHomePassportPaging.next(of: 8, pageCount: 9))
        XCTAssertNil(MapHomePassportPaging.next(of: 10, pageCount: 9))
        XCTAssertEqual(MapHomePassportPaging.next(of: 0, pageCount: 9), 1)
        XCTAssertNil(MapHomePassportPaging.previous(of: 1, pageCount: 0))
    }

    /// LDT1111A01: 메모 위 지출 줄은 오늘이면 「오늘 · 이번 달」, 다른 날이면 그 날짜와 그 달이다.
    func testLedgerMemoHeaderUsesTodayAndThisMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))!
        let today = LedgerMemoHeader.periodLabels(day: now, now: now, language: .korean, calendar: calendar)
        XCTAssertEqual(today.day, "오늘")
        XCTAssertEqual(today.month, "이번 달")
        let yesterday = LedgerMemoHeader.periodLabels(day: now.addingTimeInterval(-86_400), now: now, language: .korean, calendar: calendar)
        XCTAssertNotEqual(yesterday.day, "오늘")
        XCTAssertEqual(yesterday.month, "이번 달")
        let lastMonth = LedgerMemoHeader.periodLabels(day: now.addingTimeInterval(-86_400 * 20), now: now, language: .korean, calendar: calendar)
        XCTAssertNotEqual(lastMonth.month, "이번 달")
    }

    /// 표시 > 카운터: 연봉은 설정 화면을 열고, 나머지 일곱 개(하루 지출 포함, SPD1111A01)는 켜고 끄기만 한다.
    func testCounterKindsMapToDayCategories() {
        XCTAssertEqual(MapHomeCounterKind.allCases.count, 7)
        XCTAssertEqual(
            MapHomeCounterKind.allCases.map(\.storageKey),
            [
                "mapHomeCounter.steps",
                "mapHomeCounter.distance",
                "mapHomeCounter.work",
                "mapHomeCounter.study",
                "mapHomeCounter.hobby",
                "mapHomeCounter.exercise",
                "mapHomeCounter.spending",
            ]
        )
        // 걸음·이동은 대분류가 아니라 따로 세고, 나머지는 하루요약 대분류 시간을 그대로 쓴다.
        XCTAssertNil(MapHomeCounterKind.steps.categoryID)
        XCTAssertNil(MapHomeCounterKind.distance.categoryID)
        XCTAssertEqual(MapHomeCounterKind.work.categoryID, MapHomeSalaryPolicy.workKey)
        XCTAssertEqual(MapHomeCounterKind.study.categoryID, "study")
        XCTAssertEqual(MapHomeCounterKind.hobby.categoryID, "hobby")
        XCTAssertEqual(MapHomeCounterKind.exercise.categoryID, "exercise")

        // 같은 시간을 두 카운터가 나눠 갖지 않는다.
        let ids = MapHomeCounterKind.allCases.compactMap(\.categoryID)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    @MainActor
    func testStickmanFeetMatchStoredCoordinateOnEveryMapRenderer() {
        let offset = MapHomeStickmanAnnotationLayout.centerOffset

        XCTAssertEqual(offset.x, 0)
        XCTAssertEqual(offset.y, -MapHomeStickmanMarker.size.height / 2)
    }

    func testInitialLaunchGateWaitsForMapShellWhenAccessIsGranted() {
        let common = (
            hasCompletedInitialProRefresh: true,
            isSecurityStateReady: true,
            hasRenderedInitialDestination: true,
            isBootstrapped: true,
            grantsAccess: true
        )

        XCTAssertFalse(
            AppShellInitialLaunchGate.isReady(
                hasCompletedInitialProRefresh: common.hasCompletedInitialProRefresh,
                isSecurityStateReady: common.isSecurityStateReady,
                hasRenderedInitialDestination: common.hasRenderedInitialDestination,
                hasCompletedInitialMapShellPreparation: false,
                isBootstrapped: common.isBootstrapped,
                grantsAccess: common.grantsAccess
            )
        )
        XCTAssertTrue(
            AppShellInitialLaunchGate.isReady(
                hasCompletedInitialProRefresh: common.hasCompletedInitialProRefresh,
                isSecurityStateReady: common.isSecurityStateReady,
                hasRenderedInitialDestination: common.hasRenderedInitialDestination,
                hasCompletedInitialMapShellPreparation: true,
                isBootstrapped: common.isBootstrapped,
                grantsAccess: common.grantsAccess
            )
        )
    }

    /// 지도가 오늘 경로를 늦게 읽어도, 앱을 쓸 수 있는 상태에서 유예가 지나면 연다.
    func testInitialLaunchGateOpensAfterMapShellGrace() {
        XCTAssertTrue(
            AppShellInitialLaunchGate.isReady(
                hasCompletedInitialProRefresh: true,
                isSecurityStateReady: true,
                hasRenderedInitialDestination: true,
                hasCompletedInitialMapShellPreparation: false,
                mapShellGraceElapsed: true,
                isBootstrapped: true,
                grantsAccess: true
            )
        )
        // 유예는 지도 첫 화면만 대신한다. 저장소 적재·보안·첫 화면은 그대로 필요하다.
        for (securityReady, bootstrapped) in [(false, true), (true, false)] {
            XCTAssertFalse(
                AppShellInitialLaunchGate.isReady(
                    hasCompletedInitialProRefresh: true,
                    isSecurityStateReady: securityReady,
                    hasRenderedInitialDestination: true,
                    hasCompletedInitialMapShellPreparation: false,
                    mapShellGraceElapsed: true,
                    isBootstrapped: bootstrapped,
                    grantsAccess: true
                )
            )
        }
        // 접근 권한이 없으면(상점 잠금) 유예와 상관없이 지도 화면을 기다리지 않는다.
        XCTAssertTrue(
            AppShellInitialLaunchGate.isReady(
                hasCompletedInitialProRefresh: true,
                isSecurityStateReady: true,
                hasRenderedInitialDestination: true,
                hasCompletedInitialMapShellPreparation: false,
                mapShellGraceElapsed: false,
                isBootstrapped: false,
                grantsAccess: false
            )
        )
    }

    func testMapDayCacheFingerprintRejectsChangedRawReadings() {
        let date = makeDate(2026, 8, 25, 8)
        let first = SensorReading(id: UUID(), timestamp: date)
        let second = SensorReading(
            id: UUID(),
            timestamp: date.addingTimeInterval(60)
        )

        XCTAssertEqual(
            MapHomeDayCacheReadingsFingerprint(readings: [first]),
            MapHomeDayCacheReadingsFingerprint(readings: [first])
        )
        XCTAssertNotEqual(
            MapHomeDayCacheReadingsFingerprint(readings: [first]),
            MapHomeDayCacheReadingsFingerprint(readings: [first, second])
        )
    }

    func testMapDaySnapshotSkipsFingerprintForMatchingRevision() {
        let day = makeDate(2026, 10, 6)
        let cached = PlanDayDataSnapshot(
            day: day, sourceRevision: 7, sourceUpdatedAt: day,
            sourceFingerprint: "fixture-fingerprint", actuals: [], places: [],
            travel: [], readings: [], isComplete: true
        )
        var calls = 0
        func fingerprint() -> String? {
            calls += 1
            return "fixture-fingerprint"
        }
        XCTAssertTrue(cached.matchesCurrentSource(revision: 7, fingerprint: fingerprint()))
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(cached.matchesCurrentSource(revision: 8, fingerprint: fingerprint()))
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(cached.matchesCurrentSource(revision: 9, fingerprint: "changed"))
    }

    func testMapDaySnapshotRejectsDifferentRevisionWhenFingerprintsAreUnavailable() {
        let day = makeDate(2026, 8, 25)
        var source = TaptionDataSnapshot.empty
        source.actuals = [
            ActualRecord(
                planID: nil,
                title: String(
                    repeating: "x",
                    count: TaptionPlanCanonicalStorage.maximumUncompressedSize + 1
                ),
                categoryID: "work",
                startedAt: day.addingTimeInterval(hour),
                endedAt: day.addingTimeInterval(2 * hour),
                source: .manual
            ),
        ]
        let stale = PlanDayDataSnapshot.make(
            date: day,
            sourceRevision: 1,
            source: source,
            sensorResult: SensorReadingsLoadResult(
                readings: [],
                isComplete: true
            ),
            calendar: utcCalendar
        )
        let currentFingerprint = PlanDayDataSnapshot.sourceFingerprint(
            date: day,
            source: source,
            calendar: utcCalendar
        )

        XCTAssertNil(stale.sourceFingerprint)
        XCTAssertNil(currentFingerprint)
        XCTAssertTrue(
            stale.matchesCurrentSource(revision: 1, fingerprint: nil)
        )
        XCTAssertFalse(
            stale.matchesCurrentSource(
                revision: 2,
                fingerprint: currentFingerprint
            )
        )

        let valid = PlanDayDataSnapshot.make(
            date: day,
            sourceRevision: 1,
            source: .empty,
            sensorResult: SensorReadingsLoadResult(
                readings: [],
                isComplete: true
            ),
            calendar: utcCalendar
        )
        XCTAssertNotNil(valid.sourceFingerprint)
        XCTAssertTrue(
            valid.matchesCurrentSource(
                revision: 2,
                fingerprint: valid.sourceFingerprint
            )
        )
    }

    func testInitialMapLoadTreatsFailedArchiveAttemptAsResolved() {
        let day = makeDate(2026, 8, 25)
        XCTAssertFalse(MapHomeRouteReadingsLoadState.loading(day).isResolved(for: day))
        XCTAssertTrue(MapHomeRouteReadingsLoadState.failed(day).isResolved(for: day))
        XCTAssertTrue(MapHomeRouteReadingsLoadState.loaded(day).isResolved(for: day))
    }

    func testMapUserActivityIconCatalogExcludesBuiltInAndCustomIcons() {
        let custom = MapUserActivityCategory(
            id: UUID(),
            title: "게임",
            systemImage: "gamecontroller.fill",
            hex: "#29A383"
        )
        let available = MapUserActivityIconCatalog.available(for: [custom])

        XCTAssertFalse(available.contains("gamecontroller.fill"))
        for builtIn in RecordClassificationCatalog.categories {
            XCTAssertFalse(available.contains(builtIn.systemImage))
        }
        XCTAssertEqual(available.count, Set(available).count)
    }

    func testMapUserActivityIconReturnsAfterCategoryDeletion() {
        let custom = MapUserActivityCategory(
            id: UUID(),
            title: "게임",
            systemImage: "gamecontroller.fill",
            hex: "#29A383"
        )

        XCTAssertFalse(
            MapUserActivityIconCatalog.available(for: [custom])
                .contains("gamecontroller.fill")
        )
        XCTAssertTrue(
            MapUserActivityIconCatalog.available(for: [])
                .contains("gamecontroller.fill")
        )
    }

    func testMapCategoryColorOverridesAcceptOnlyValidHexValues() {
        let colors = AppFeatureSettings.normalizedMapCategoryColors([
            "work": "#4f46e5",
            "sleep": "#ABCDEF",
            "invalid": "#123456",
            "activity": "not-a-color",
        ])

        XCTAssertEqual(colors, ["work": "#4F46E5", "sleep": "#ABCDEF"])
        XCTAssertEqual(
            MapHomeSidebarMajorCategory.presentation(
                for: "work",
                categoryColors: colors
            ).hex,
            "#4F46E5"
        )
    }

    func testRegisteredLocationTintsUseDistinctParchmentMapColors() {
        let colors = MapHomeLocationDestination.allCases.map {
            $0.tint.hexRGBString
        }

        XCTAssertEqual(colors, [
            "#976744", "#65745E", "#7B6C55", "#796D82",
            "#A75F4A", "#987F4D", "#A56347", "#756E5B",
        ])
        XCTAssertEqual(Set(colors).count, MapHomeLocationDestination.allCases.count)
    }

    func testMapDayReprojectionKeepsFreshRawWhenClassificationChanges() {
        let date = makeDate(2026, 9, 11, 12)
        let reading = SensorReading(timestamp: date)
        let loaded = PlanDayDataSnapshot.make(
            date: date,
            sourceRevision: 1,
            source: .empty,
            sensorResult: SensorReadingsLoadResult(
                readings: [reading], isComplete: true
            )
        )
        var source = TaptionDataSnapshot.empty
        let actual = ActualRecord(
            planID: nil, title: "이동", categoryID: "movement",
            startedAt: date, endedAt: date.addingTimeInterval(hour),
            source: .motion
        )
        source.actuals = [actual]
        let rebased = PlanDayDataSnapshot.rebase(
            from: loaded,
            date: date,
            sourceRevision: 2,
            source: source,
            cancellationCheck: {}
        )
        XCTAssertEqual(rebased.readings, [reading])
        XCTAssertEqual(rebased.actuals, [actual])
        XCTAssertTrue(rebased.isComplete)
        XCTAssertNotEqual(rebased.sourceFingerprint, loaded.sourceFingerprint)
        XCTAssertEqual(rebased.sourceFingerprint,
            PlanDayDataSnapshot.sourceFingerprint(date: date, source: source))
    }

    func testMapDayRebaseChecksCancellationDuringFingerprintSort() {
        let date = makeDate(2026, 9, 11, 12)
        let reading = SensorReading(timestamp: date)
        let previous = PlanDayDataSnapshot.make(
            date: date,
            sourceRevision: 1,
            source: .empty,
            sensorResult: SensorReadingsLoadResult(
                readings: [reading], isComplete: true
            )
        )
        var source = TaptionDataSnapshot.empty
        source.actuals = (0..<1_024).map { index in
            ActualRecord(
                planID: nil,
                title: "업무 \(index)",
                categoryID: "work",
                startedAt: date.addingTimeInterval(Double(index)),
                endedAt: date.addingTimeInterval(Double(index + 1)),
                source: .manual
            )
        }
        var checks = 0

        XCTAssertThrowsError(
            try PlanDayDataSnapshot.rebase(
                from: previous,
                date: date,
                sourceRevision: 2,
                source: source,
                cancellationCheck: {
                    checks += 1
                    if checks == 11 { throw CancellationError() }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(checks, 11)
    }

    func testRealtimeMapProjectionIgnoresApproximateGPSFixes() {
        let timestamp = makeDate(2026, 8, 18, 7, 1)
        let readings = [
            SensorReading(
                timestamp: timestamp,
                point: GeoPoint(
                    latitude: 37.5,
                    longitude: 127,
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                ),
                locationFixQuality: .approximate,
                gpsAvailable: true
            )
        ]

        XCTAssertNil(
            RealtimeSensorMapProjection.project(
                readings: readings,
                at: timestamp
            )
        )
    }

    func testRealtimeMapProjectionRejectsStaleFallbackAndLongInterpolation() {
        let timestamp = makeDate(2026, 8, 18, 7, 30)
        func reading(_ offset: TimeInterval, latitude: Double) -> SensorReading {
            SensorReading(
                timestamp: timestamp.addingTimeInterval(offset),
                point: GeoPoint(
                    latitude: latitude,
                    longitude: 127,
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                )
            )
        }

        XCTAssertNil(
            RealtimeSensorMapProjection.project(
                readings: [reading(-6 * 60, latitude: 37.5)],
                at: timestamp
            )
        )
        XCTAssertNil(
            RealtimeSensorMapProjection.project(
                readings: [
                    reading(-11 * 60, latitude: 37.5),
                    reading(11 * 60, latitude: 37.6),
                ],
                at: timestamp
            )
        )
    }

    func testRealtimeMapProjectionInterpolatesAcrossDateLine() throws {
        let timestamp = makeDate(2026, 8, 18, 7, 30)
        func reading(_ offset: TimeInterval, longitude: Double) -> SensorReading {
            SensorReading(
                timestamp: timestamp.addingTimeInterval(offset),
                point: GeoPoint(
                    latitude: 37.5,
                    longitude: longitude,
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5
                )
            )
        }

        let projection = try XCTUnwrap(
            RealtimeSensorMapProjection.project(
                readings: [
                    reading(-60, longitude: 179.9),
                    reading(60, longitude: -179.9),
                ],
                at: timestamp
            )
        )

        XCTAssertLessThan(abs(abs(projection.point.longitude) - 180), 0.001)
    }

    func testClockDragMapsEveryQuarterTurnLikeAClock() {
        XCTAssertEqual(RecordClockEngine.labeledHours, Array(0..<24))
        XCTAssertEqual(
            RecordClockEngine.clockFraction(
                x: 100,
                y: 0,
                centerX: 100,
                centerY: 100
            ),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RecordClockEngine.clockFraction(
                x: 200,
                y: 100,
                centerX: 100,
                centerY: 100
            ),
            0.25,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RecordClockEngine.clockFraction(
                x: 100,
                y: 200,
                centerX: 100,
                centerY: 100
            ),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RecordClockEngine.clockFraction(
                x: 0,
                y: 100,
                centerX: 100,
                centerY: 100
            ),
            0.75,
            accuracy: 0.0001
        )
    }

    func testLinearClockKeepsCenteredPlayheadMappedToScrollOffset() {
        XCTAssertEqual(
            RecordClockEngine.playheadFraction(
                contentOffset: 600,
                timelineWidth: 2_400
            ),
            0.25,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RecordClockEngine.contentOffset(
                for: 0.75,
                timelineWidth: 2_400
            ),
            1_800,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RecordClockEngine.playheadFraction(
                contentOffset: 3_000,
                timelineWidth: 2_400
            ),
            1
        )
        XCTAssertEqual(
            RecordClockEngine.contentOffset(
                for: -0.5,
                timelineWidth: 2_400
            ),
            0
        )
    }

    @MainActor
    func testDeletingPlanDetachesLinkedMapMemoAndPersistsIt() async throws {
        let base = makeDate(2026, 8, 4, 10)
        let plan = PlanRecord(
            title: "현장 방문",
            span: TimeSpan(start: base, end: base.addingTimeInterval(hour)),
            categoryID: "work"
        )
        let memo = ActionMemo(
            planID: plan.id,
            targetID: "plan.\(plan.id.uuidString)",
            categoryID: plan.categoryID,
            occurredAt: base.addingTimeInterval(20 * 60),
            mapPoint: GeoPoint(
                latitude: 37.5,
                longitude: 127,
                altitude: 12,
                horizontalAccuracy: 4,
                verticalAccuracy: 6
            ),
            kind: .idea,
            text: "입구가 동쪽",
            createdAt: base,
            updatedAt: base
        )
        var stored = TaptionDataSnapshot.empty
        stored.plans = [plan]
        stored.memos = [memo]
        let repository = InMemoryPlanRepository(snapshot: stored)
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()

        await model.deletePlan(plan.id)

        XCTAssertTrue(model.snapshot.plans.isEmpty)
        let detached = try XCTUnwrap(model.snapshot.memos.first)
        XCTAssertEqual(detached.id, memo.id)
        XCTAssertNil(detached.planID)
        XCTAssertNil(detached.targetID)
        XCTAssertEqual(detached.categoryID, memo.categoryID)
        XCTAssertEqual(detached.occurredAt, memo.occurredAt)
        XCTAssertEqual(detached.mapPoint, memo.mapPoint)
        XCTAssertEqual(detached.text, memo.text)

        let persisted = try await repository.load()
        XCTAssertEqual(persisted.plans, [])
        XCTAssertEqual(persisted.memos, [detached])
    }

    @MainActor
    func testDeletingPendingMapMemoDoesNotCreateCloudTombstone() async throws {
        let repository = InMemoryPlanRepository()
        let model = AppModel(repository: repository, cloudSyncService: nil)
        let memoID = try XCTUnwrap(model.addMapMemo(
            text: "작성 중인 메모",
            kind: .idea,
            mapPoint: GeoPoint(
                latitude: 37.5,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 0,
                verticalAccuracy: 0
            ),
            occurredAt: makeDate(2026, 8, 4, 10),
            shouldPersist: false
        ))

        model.deleteMemo(memoID)

        XCTAssertFalse(model.snapshot.memos.contains { $0.id == memoID })
        XCTAssertFalse(
            model.settings.cloudDeletedRecordKeys.contains(
                CloudBackupRecordKey.memo(memoID)
            )
        )
        let persisted = try await repository.load()
        XCTAssertFalse(persisted.memos.contains { $0.id == memoID })
        XCTAssertFalse(
            persisted.settings.cloudDeletedRecordKeys.contains(
                CloudBackupRecordKey.memo(memoID)
            )
        )
    }

}
