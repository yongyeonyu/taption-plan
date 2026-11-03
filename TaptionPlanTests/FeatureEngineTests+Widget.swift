import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

extension FeatureEngineTests {
    func testCatTapRoutingAcceptsOnlyTapsInsideMarkerBounds() {
        let marker = CGPoint(x: 100, y: 200)
        XCTAssertTrue(
            MapHomeCatTapRouting.contains(
                tapPoint: CGPoint(x: 120, y: 200),
                markerPoint: marker
            )
        )
        XCTAssertFalse(
            MapHomeCatTapRouting.contains(
                tapPoint: CGPoint(x: 137, y: 200),
                markerPoint: marker
            )
        )
        // 집에 있을 때 화랑이는 아바타 원 안 오른쪽 아래에 있다(핀 좌표 = 아바타 중심).
        let catAtHome = MapHomeCatTapRouting.markerPoint(
            locationPoint: marker,
            isAtHome: true
        )
        XCTAssertGreaterThan(catAtHome.x, marker.x)
        XCTAssertGreaterThan(catAtHome.y, marker.y)
        XCTAssertLessThan(
            hypot(catAtHome.x - marker.x, catAtHome.y - marker.y),
            MapHomePlacePinLayout.avatarSize / 2,
            "화랑이는 아바타 원 안에 있어야 한다"
        )
        XCTAssertEqual(
            MapHomeCatTapRouting.markerPoint(
                locationPoint: marker,
                isAtHome: false
            ),
            CGPoint(x: 100, y: 182)
        )
    }

    func testIslandClosedSensorProjectionUsesFreshSavedSampleAndExpires() {
        let now = Date()
        let sampleDate = now.addingTimeInterval(-5)
        let walking = ActualRecord(planID: nil, title: "걷기", categoryID: "activity", startedAt: now.addingTimeInterval(-60), endedAt: sampleDate, source: .motion)
        XCTAssertEqual(TaptionCurrentActivityPolicy.categoryID(actuals: [walking], plans: [], at: now, latestSavedAt: sampleDate), "movement")
        let older = ActualRecord(planID: nil, title: "업무", categoryID: "work", startedAt: now.addingTimeInterval(-600), source: .motion)
        XCTAssertEqual(TaptionCurrentActivityPolicy.categoryID(actuals: [older, walking], plans: [], at: now, latestSavedAt: sampleDate), "movement")
        XCTAssertNil(TaptionCurrentActivityPolicy.categoryID(actuals: [walking], plans: [], at: sampleDate.addingTimeInterval(91), latestSavedAt: sampleDate))
        let manual = ActualRecord(planID: nil, title: "수면", categoryID: "sleep", startedAt: now.addingTimeInterval(-60), endedAt: sampleDate, source: .manual)
        XCTAssertNil(TaptionCurrentActivityPolicy.categoryID(actuals: [manual], plans: [], at: now, latestSavedAt: sampleDate))
        XCTAssertNil(TaptionCurrentActivityPolicy.categoryID(actuals: [walking], plans: [], at: now, latestSavedAt: now.addingTimeInterval(1)))
    }

    func testSensorLiveActivityStartsForForegroundSensorSessions() {
        XCTAssertFalse(
            SensorCollectionActivityPolicy.canStart(
                isForeground: true,
                intervalSeconds: 1,
                activitiesEnabled: true
            )
        )
        XCTAssertFalse(
            SensorCollectionActivityPolicy.canStart(
                isForeground: false,
                intervalSeconds: 1,
                activitiesEnabled: true
            )
        )
        XCTAssertFalse(
            SensorCollectionActivityPolicy.canStart(
                isForeground: true,
                intervalSeconds: 10,
                activitiesEnabled: true
            )
        )
        XCTAssertTrue(
            SensorCollectionActivityPolicy.canStart(
                isForeground: true,
                intervalSeconds: 60,
                activitiesEnabled: true
            )
        )
        XCTAssertTrue(
            SensorCollectionActivityPolicy.canStart(
                isForeground: true,
                intervalSeconds: 900,
                activitiesEnabled: true
            )
        )
        XCTAssertFalse(
            SensorCollectionActivityPolicy.canStart(
                isForeground: true,
                intervalSeconds: 0,
                activitiesEnabled: true
            )
        )

        let startedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let justBeforeExpiration = startedAt.addingTimeInterval(
            SensorCollectionActivityPolicy.maximumDuration - 1
        )
        XCTAssertFalse(
            SensorCollectionActivityPolicy.isExpired(
                startedAt: startedAt,
                now: justBeforeExpiration
            )
        )
        XCTAssertTrue(
            SensorCollectionActivityPolicy.isExpired(
                startedAt: startedAt,
                now: SensorCollectionActivityPolicy.expirationDate(
                    startedAt: startedAt
                )
            )
        )
        XCTAssertTrue(
            SensorCollectionActivityPolicy.shouldPublish(
                lastPublishedAt: nil,
                now: startedAt
            )
        )
        XCTAssertFalse(
            SensorCollectionActivityPolicy.shouldPublish(
                lastPublishedAt: startedAt,
                now: startedAt.addingTimeInterval(14)
            )
        )
        XCTAssertTrue(
            SensorCollectionActivityPolicy.shouldPublish(
                lastPublishedAt: startedAt,
                now: startedAt.addingTimeInterval(15)
            )
        )
    }

    func testSensorLiveActivitySaveTokenPublishesBeforePeriodicInterval() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 21_000)
        XCTAssertFalse(
            SensorCollectionActivityPolicy.shouldPublish(
                lastPublishedAt: startedAt,
                now: startedAt.addingTimeInterval(1)
            )
        )
        XCTAssertFalse(
            SensorCollectionActivityPolicy.hasNewSavedSample(
                previousSaveToken: nil,
                currentSaveToken: 0,
                previousSavedAt: nil,
                currentSavedAt: nil
            )
        )
        XCTAssertTrue(
            SensorCollectionActivityPolicy.hasNewSavedSample(
                previousSaveToken: 10,
                currentSaveToken: 11,
                previousSavedAt: startedAt,
                currentSavedAt: startedAt
            )
        )
        XCTAssertFalse(
            SensorCollectionActivityPolicy.hasNewSavedSample(
                previousSaveToken: 11,
                currentSaveToken: 11,
                previousSavedAt: startedAt,
                currentSavedAt: startedAt.addingTimeInterval(1)
            )
        )
        XCTAssertTrue(
            SensorCollectionActivityPolicy.hasNewSavedSample(
                previousSaveToken: nil,
                currentSaveToken: nil,
                previousSavedAt: startedAt,
                currentSavedAt: startedAt.addingTimeInterval(1)
            )
        )
    }

    func testSensorLiveActivityMetersRollOverLatestTenSamplesPerKind() {
        let kinds = ["location", "motion"]
        var masks: [String: Int]?

        for index in 0..<12 {
            masks = SensorCollectionActivityPolicy.updatedSensorMeterMasks(
                previous: masks,
                collectionKinds: kinds,
                validSampleKinds: index.isMultiple(of: 2)
                    ? ["location"]
                    : ["motion"],
                hasNewSample: true
            )
        }

        XCTAssertEqual(masks?["location"], 0b1010101010)
        XCTAssertEqual(masks?["motion"], 0b0101010101)

        let unchanged = SensorCollectionActivityPolicy.updatedSensorMeterMasks(
            previous: masks,
            collectionKinds: ["location", "location", "motion"],
            validSampleKinds: [],
            hasNewSample: false
        )
        XCTAssertEqual(unchanged, masks)
    }

    func testSensorLiveActivityMeterStatusesTrackValidAndStaleSamples() {
        let now = Date(timeIntervalSinceReferenceDate: 23_000)
        let initial = SensorCollectionActivityPolicy.updatedSensorStatuses(
            previous: nil,
            collectionKinds: ["location", "location", "motion"],
            validSampleKinds: [],
            hasNewSample: false,
            now: now,
            lastSavedAt: nil,
            intervalSeconds: 10
        )
        XCTAssertEqual(initial.count, 2)
        XCTAssertEqual(
            initial["location"],
            SensorCollectionActivityAttributes.SensorStatus.waiting.rawValue
        )

        let receiving = SensorCollectionActivityPolicy.updatedSensorStatuses(
            previous: nil,
            collectionKinds: ["location", "motion"],
            validSampleKinds: ["location"],
            hasNewSample: true,
            now: now,
            lastSavedAt: now,
            intervalSeconds: 10
        )
        XCTAssertEqual(
            receiving["location"],
            SensorCollectionActivityAttributes.SensorStatus.receiving.rawValue
        )
        XCTAssertEqual(
            receiving["motion"],
            SensorCollectionActivityAttributes.SensorStatus.waiting.rawValue
        )

        let delayed = SensorCollectionActivityPolicy.updatedSensorStatuses(
            previous: receiving,
            collectionKinds: ["location", "motion"],
            validSampleKinds: [],
            hasNewSample: false,
            now: now.addingTimeInterval(31),
            lastSavedAt: now,
            intervalSeconds: 10
        )
        XCTAssertEqual(
            delayed["location"],
            SensorCollectionActivityAttributes.SensorStatus.delayed.rawValue
        )
        XCTAssertEqual(
            delayed["motion"],
            SensorCollectionActivityAttributes.SensorStatus.delayed.rawValue
        )
    }

    func testWidgetPlaybackAlwaysKeepsAutomaticLanes() {
        let base = makeDate(2026, 8, 1, 12, 0)

        XCTAssertEqual(
            TaptionWidgetPlaybackEngine.lanes(
                for: [],
                at: base
            ),
            [.schedule, .location, .movement, .sleep, .activity, .appUsage]
        )

        let action = TaptionWidgetItem(
            id: UUID(),
            title: "여행 준비",
            categoryID: "travel",
            startsAt: base.addingTimeInterval(-30 * 60),
            endsAt: base.addingTimeInterval(30 * 60),
            status: "planned",
            isFixed: false,
            lane: .action
        )
        XCTAssertEqual(
            TaptionWidgetPlaybackEngine.lanes(
                for: [action],
                at: base
            ),
            [.schedule, .location, .movement, .sleep, .activity, .appUsage, .action]
        )
        XCTAssertEqual(
            TaptionWidgetPlaybackEngine.activeItems(
                in: .action,
                from: [action],
                at: base
            ),
            [action]
        )
    }

    func testWidgetPayloadIsAlwaysCurrentCenteredAtSixHours() {
        let now = makeDate(2026, 8, 1, 18, 0)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.settings.locationEnabled = true
        snapshot.settings.permissions[.location] = .authorized
        let payload = TaptionWidgetPayloadFactory.make(
            from: snapshot,
            now: now
        )

        XCTAssertEqual(payload.displayCenterDate, now)
        XCTAssertEqual(
            payload.displayDuration,
            TaptionWidgetPlaybackEngine.defaultWindowDuration
        )
        XCTAssertEqual(
            payload.displayResolutionLabel,
            TaptionWidgetPlaybackEngine.defaultResolutionLabel
        )
        XCTAssertEqual(payload.displayDuration, 6 * hour)
        XCTAssertEqual(payload.locationTrackingEnabled, true)
        XCTAssertEqual(
            payload.locationPermissionState,
            PermissionState.authorized.rawValue
        )
        XCTAssertEqual(
            payload.sourceFingerprint,
            TaptionWidgetSyncFingerprint.make(items: payload.items)
        )

        let oldOffice = TaptionWidgetItem(
            id: UUID(),
            title: "회사",
            categoryID: "location",
            startsAt: now.addingTimeInterval(-6 * hour),
            endsAt: now.addingTimeInterval(-4 * hour),
            status: "recorded",
            isFixed: true,
            lane: .location
        )
        let currentHome = TaptionWidgetItem(
            id: UUID(),
            title: "집",
            categoryID: "location",
            startsAt: now.addingTimeInterval(-hour),
            endsAt: now.addingTimeInterval(hour),
            status: "recorded",
            isFixed: true,
            lane: .location
        )
        let oldMovement = TaptionWidgetItem(
            id: UUID(),
            title: "자가용",
            categoryID: "movement",
            startsAt: now.addingTimeInterval(-5 * hour),
            endsAt: now.addingTimeInterval(-4 * hour),
            status: "recorded",
            isFixed: true,
            lane: .movement
        )

        XCTAssertEqual(
            TaptionWidgetPlaybackEngine.visibleItems(
                in: .location,
                from: [oldOffice, currentHome, oldMovement],
                at: now
            ).map(\.title),
            ["집"]
        )
        XCTAssertTrue(
            TaptionWidgetPlaybackEngine.visibleItems(
                in: .movement,
                from: [oldOffice, currentHome, oldMovement],
                at: now
            ).isEmpty
        )
    }

    func testWidgetRejectsNewerLegacyCacheWithoutGroundTruthFingerprint() {
        let now = makeDate(2026, 8, 1, 18, 0)
        var groundTruth = TaptionWidgetPayloadFactory.make(
            from: .empty,
            now: now
        )
        groundTruth.sourceFingerprint = "ground-truth"
        var legacyCache = groundTruth
        legacyCache.generatedAt = now.addingTimeInterval(60)
        legacyCache.sourceFingerprint = nil
        legacyCache.items = [
            TaptionWidgetItem(
                id: UUID(),
                title: "회사",
                categoryID: "location",
                startsAt: now.addingTimeInterval(-hour),
                endsAt: now.addingTimeInterval(hour),
                status: "recorded",
                isFixed: true,
                lane: .location
            )
        ]

        XCTAssertEqual(
            TaptionWidgetPayloadSyncPolicy.freshest(
                groundTruth: groundTruth,
                cached: legacyCache
            ),
            groundTruth
        )

        var staleCache = groundTruth
        staleCache.generatedAt = now.addingTimeInterval(120)
        staleCache.sourceSnapshotUpdatedAt = now.addingTimeInterval(-hour)
        groundTruth.sourceSnapshotUpdatedAt = now
        XCTAssertEqual(
            TaptionWidgetPayloadSyncPolicy.freshest(
                groundTruth: groundTruth,
                cached: staleCache
            ),
            groundTruth
        )
    }

    func testWidgetGroundTruthWinsWhenFingerprintsDifferAtSameSourceRevision() {
        let now = makeDate(2026, 8, 1, 18, 0)
        var groundTruth = TaptionWidgetPayload.empty
        groundTruth.generatedAt = now
        groundTruth.sourceSnapshotUpdatedAt = now
        groundTruth.sourceFingerprint = "app-ground-truth"
        groundTruth.items = [
            TaptionWidgetItem(
                id: UUID(),
                title: "집",
                categoryID: "location",
                startsAt: now.addingTimeInterval(-hour),
                endsAt: now.addingTimeInterval(hour),
                status: "recorded",
                isFixed: true,
                lane: .location
            ),
        ]
        var cached = groundTruth
        cached.generatedAt = now.addingTimeInterval(60)
        cached.sourceFingerprint = "stale-cache"
        cached.items = []

        XCTAssertEqual(
            TaptionWidgetPayloadSyncPolicy.selectionReason(
                groundTruth: groundTruth,
                cached: cached
            ),
            .groundTruth
        )
        XCTAssertEqual(
            TaptionWidgetPayloadSyncPolicy.freshest(
                groundTruth: groundTruth,
                cached: cached
            ).items.map(\.title),
            ["집"]
        )
    }

    func testWidgetPayloadDecodesLegacyCacheWithoutSyncMetadata() throws {
        let payload = TaptionWidgetPayloadFactory.make(
            from: .empty,
            now: makeDate(2026, 8, 1, 18, 0)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let encoded = try encoder.encode(payload)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "sourceSnapshotUpdatedAt")
        object.removeValue(forKey: "sourceFingerprint")
        object.removeValue(forKey: "locationTrackingEnabled")
        object.removeValue(forKey: "locationPermissionState")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(
            TaptionWidgetPayload.self,
            from: legacyData
        )

        XCTAssertNil(decoded.sourceSnapshotUpdatedAt)
        XCTAssertNil(decoded.sourceFingerprint)
        XCTAssertNil(decoded.locationTrackingEnabled)
        XCTAssertNil(decoded.locationPermissionState)
    }

    func testWidgetAutomaticallyScrollsOverflowingRowsAndReturns() {
        let reference = Date(timeIntervalSinceReferenceDate: 0)

        XCTAssertEqual(
            TaptionWidgetAutoScrollEngine.progress(
                at: reference,
                rowCount: 4
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TaptionWidgetAutoScrollEngine.progress(
                at: reference.addingTimeInterval(2.5),
                rowCount: 5
            ),
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TaptionWidgetAutoScrollEngine.offset(
                at: reference.addingTimeInterval(3.5),
                contentHeight: 100,
                viewportHeight: 80,
                rowCount: 5
            ),
            20,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TaptionWidgetAutoScrollEngine.offset(
                at: reference.addingTimeInterval(3.5),
                contentHeight: 80,
                viewportHeight: 100,
                rowCount: 5
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TaptionWidgetAutoScrollEngine.progress(
                at: reference.addingTimeInterval(5.5),
                rowCount: 5
            ),
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TaptionWidgetAutoScrollEngine.progress(
                at: reference.addingTimeInterval(60),
                rowCount: 5,
                reducesMotion: true
            ),
            1,
            accuracy: 0.001
        )
    }

    func testWidgetPlaybackUsesMinuteTicksAndExactItemBoundaries() {
        let base = makeDate(2026, 8, 1, 12, 0)
        let startsAt = base.addingTimeInterval(95)
        let endsAt = base.addingTimeInterval(185)
        let movement = TaptionWidgetItem(
            id: UUID(),
            title: "자가용",
            categoryID: "movement",
            startsAt: startsAt,
            endsAt: endsAt,
            status: "recorded",
            isFixed: true,
            lane: .movement
        )
        let dates = TaptionWidgetPlaybackEngine.timelineDates(
            for: [movement],
            from: base,
            horizon: base.addingTimeInterval(5 * 60)
        )

        XCTAssertTrue(dates.contains(base.addingTimeInterval(60)))
        XCTAssertTrue(dates.contains(startsAt))
        XCTAssertTrue(dates.contains(endsAt))
        XCTAssertEqual(dates, dates.sorted())
    }

    func testWidgetCatShowsDetailSceneOnlyWhileRestingWithAtlasCoat() {
        func scene(
            style: String = "calico",
            title: String = "요리",
            action: TaptionWidgetCatAction = .eating,
            reducesMotion: Bool = false
        ) -> TaptionHwarangPose? {
            TaptionHwarangPose.widgetScene(
                style: style,
                categoryID: "routine",
                title: title,
                action: action,
                reducesMotion: reducesMotion
            )
        }

        XCTAssertEqual(scene(), .cooking)
        XCTAssertEqual(scene(style: "white"), .cooking)
        XCTAssertEqual(scene(style: "mackerel"), .cooking)
        XCTAssertNil(scene(style: "black"))
        XCTAssertNil(scene(title: "근무"))
        XCTAssertNil(scene(action: .walking))
        XCTAssertNil(scene(action: .running))
        XCTAssertNil(scene(action: .startled))
        XCTAssertEqual(scene(action: .walking, reducesMotion: true), .cooking)

        // 20초 주기 안에서 장면이 실제로 나오는 칸이 있어야 한다.
        let reference = Date(timeIntervalSinceReferenceDate: 0)
        let resting = (0..<TaptionWidgetCatWalkEngine.stepCount).filter { step in
            let pose = TaptionWidgetCatWalkEngine.pose(
                at: reference.addingTimeInterval(Double(step) * TaptionWidgetCatWalkEngine.defaultStepDuration),
                preferredAction: .eating
            )
            return scene(action: pose.action) != nil
        }
        XCTAssertEqual(resting, Array(20..<24) + Array(30..<34))
    }

    func testCatPickerPreviewIncludesAndAnimatesEveryWidgetAction() {
        let reference = Date(timeIntervalSinceReferenceDate: 0)
        let actions = TaptionWidgetCatAction.allCases

        XCTAssertEqual(actions.count, 12)
        XCTAssertEqual(TaptionCatAnimationEngine.phaseCount, 6)
        XCTAssertEqual(Set(actions.map(\.previewTitle)).count, actions.count)
        XCTAssertTrue(actions.allSatisfy { !$0.previewSystemImage.isEmpty })

        let runningStart = TaptionWidgetCatPreviewEngine.pose(
            at: reference,
            action: .running
        )
        let runningEnd = TaptionWidgetCatPreviewEngine.pose(
            at: reference.addingTimeInterval(2),
            action: .running
        )
        let grooming = TaptionWidgetCatPreviewEngine.pose(
            at: reference.addingTimeInterval(0.2),
            action: .grooming
        )
        let reduced = TaptionWidgetCatPreviewEngine.pose(
            at: reference.addingTimeInterval(1.8),
            action: .fishingPlay,
            reducesMotion: true
        )

        XCTAssertEqual(runningStart.progress, 0, accuracy: 0.001)
        XCTAssertEqual(runningEnd.progress, 1, accuracy: 0.001)
        XCTAssertEqual(grooming.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(grooming.action, .grooming)
        XCTAssertNotEqual(grooming.headTiltDegrees, 0)
        XCTAssertEqual(reduced.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(reduced.action, .fishingPlay)
        XCTAssertEqual(reduced.tailSwing, 0, accuracy: 0.001)
        XCTAssertEqual(reduced.headTiltDegrees, 0, accuracy: 0.001)
    }

    func testEveryCatActionHasFinitePoseAtEveryPhase() {
        let phases = Array(-3...(TaptionCatAnimationEngine.phaseCount + 3))

        for action in TaptionCatAnimationAction.allCases {
            for phase in phases {
                let motion = TaptionCatAnimationEngine.motionDetails(
                    for: action,
                    phase: phase
                )
                XCTAssertTrue(motion.tailSwing.isFinite, "\(action) \(phase)")
                XCTAssertTrue(
                    motion.headTiltDegrees.isFinite,
                    "\(action) \(phase)"
                )
                XCTAssertTrue(motion.legSwing.isFinite, "\(action) \(phase)")
                XCTAssertLessThanOrEqual(abs(motion.tailSwing), 1.01)
                XCTAssertLessThanOrEqual(abs(motion.legSwing), 1.01)
                XCTAssertLessThanOrEqual(abs(motion.headTiltDegrees), 24)

                let pose = TaptionCatAnimationEngine.pose(
                    from: action.rawValue,
                    progress: 0.5,
                    phase: phase,
                    facesLeft: false,
                    tailSwing: motion.tailSwing,
                    headTiltDegrees: motion.headTiltDegrees,
                    legSwing: motion.legSwing
                )
                XCTAssertEqual(pose.action, action)
                XCTAssertTrue((0...1).contains(pose.cycleEase))
            }
        }

        // 위젯이 도는 40스텝 시퀀스가 6프레임 주기를 빠짐없이 채운다.
        let walkPhases = (0..<40).map {
            TaptionWidgetCatWalkEngine.pose(
                at: Date(
                    timeIntervalSinceReferenceDate:
                        Double($0)
                            * TaptionWidgetCatWalkEngine.defaultStepDuration
                            + 0.01
                )
            ).legPhase
        }
        XCTAssertEqual(
            Set(walkPhases),
            Set(0..<TaptionCatAnimationEngine.phaseCount)
        )
    }

    func testCatActionVocabulariesShareRawValuesAndTolerateUnknownStored() {
        XCTAssertEqual(
            Set(TaptionWidgetCatAction.allCases.map(\.rawValue)),
            Set(TaptionCatAnimationAction.allCases.map(\.rawValue))
        )
        for action in TaptionWidgetCatAction.allCases {
            XCTAssertEqual(action.animationAction.rawValue, action.rawValue)
        }

        // 옛 저장본이나 알 수 없는 동작 이름은 기본 동작으로 떨어진다.
        XCTAssertNil(TaptionWidgetCatAction(rawValue: "zoomies"))
        XCTAssertEqual(
            TaptionCatAnimationEngine.pose(
                from: "zoomies",
                progress: 0.5,
                phase: 0,
                facesLeft: false,
                tailSwing: 0,
                headTiltDegrees: 0
            ).action,
            .walking
        )
        XCTAssertEqual(
            TaptionCatAnimationEngine.pose(
                from: "",
                progress: 2,
                phase: 0,
                facesLeft: false,
                tailSwing: 0,
                headTiltDegrees: 0
            ).progress,
            1,
            accuracy: 0.0001
        )
    }

    func testStoredSettingsKeepCatChoiceWhenActionNamesAreUnknown() throws {
        let legacy = """
        {
            "startScale": "day",
            "rememberLastScale": true,
            "catStyle": "cheese",
            "reduceMotion": true,
            "catAction": "zoomies",
            "showsPhotos": false,
            "showsPhotosInWidgets": false,
            "selectedCalendarIDs": [],
            "healthEnabled": false,
            "locationEnabled": false,
            "backgroundPreciseLocationEnabled": false,
            "weatherEnabled": false,
            "notificationsEnabled": false,
            "permissions": []
        }
        """
        let decoded = try JSONDecoder().decode(
            AppFeatureSettings.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(decoded.catStyle, .cheese)
        XCTAssertTrue(decoded.reduceMotion)
        XCTAssertTrue(decoded.rememberLastScale)
        XCTAssertEqual(
            decoded.sensorCollectionProfile,
            AppFeatureSettings.defaults.sensorCollectionProfile
        )
        XCTAssertEqual(
            decoded.gpsLoggingPreferences,
            GPSLoggingPreferences.standard
        )
    }

    func testCatIdleBeatBlinksAndStirsAcrossOneMinute() {
        let step = TaptionCatAnimationEngine.stepDuration
        let beats = (0..<750).map {
            TaptionCatIdleBeat.beat(
                at: Date(timeIntervalSinceReferenceDate: Double($0) * step)
            )
        }

        XCTAssertTrue(beats.allSatisfy {
            $0.eyeOpenness.isFinite
                && $0.earFlick.isFinite
                && $0.tailTip.isFinite
        })
        XCTAssertTrue(beats.allSatisfy { (0...1).contains($0.eyeOpenness) })
        XCTAssertTrue(beats.allSatisfy { abs($0.earFlick) <= 1 })
        XCTAssertTrue(beats.allSatisfy { abs($0.tailTip) <= 1 })

        let closedFrames = beats.filter { $0.eyeOpenness < 0.5 }.count
        XCTAssertGreaterThan(closedFrames, 8)
        // 눈을 감고 있는 시간이 뜨고 있는 시간을 넘으면 졸려 보인다.
        XCTAssertLessThan(Double(closedFrames) / Double(beats.count), 0.15)
        XCTAssertTrue(beats.contains { abs($0.earFlick) > 0.6 })
        XCTAssertTrue(beats.contains { $0.tailTip > 0.7 })
        XCTAssertTrue(beats.contains { $0.tailTip < -0.7 })

        // 기준일 이전 날짜에서도 나머지 연산이 음수로 새지 않는다.
        let past = (1...400).map {
            TaptionCatIdleBeat.beat(
                at: Date(timeIntervalSinceReferenceDate: Double(-$0) * step)
            )
        }
        XCTAssertTrue(past.allSatisfy { (0...1).contains($0.eyeOpenness) })
        XCTAssertTrue(past.allSatisfy { abs($0.earFlick) <= 1 })
        XCTAssertTrue(past.allSatisfy { abs($0.tailTip) <= 1 })
        XCTAssertTrue(past.contains { $0.eyeOpenness < 0.5 })

        XCTAssertEqual(
            TaptionCatIdleBeat.beat(at: Date(timeIntervalSinceReferenceDate: .nan)),
            .still
        )
    }

    func testWidgetCommandMutatesSharedSnapshotWithoutOpeningApp() throws {
        let base = makeDate(2026, 7, 30, 9)
        let plan = PlanRecord(
            title: "집중 작업",
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(hour)
            ),
            categoryID: "project"
        )
        var source = TaptionDataSnapshot.empty
        source.plans = [plan]

        let postponed = try TaptionWidgetCommandEngine.apply(
            TaptionWidgetCommand(
                planID: plan.id,
                kind: .postponeThirtyMinutes,
                requestedAt: base
            ),
            to: source
        )
        XCTAssertEqual(
            postponed.plans[0].span.start,
            base.addingTimeInterval(30 * 60)
        )
        XCTAssertEqual(
            postponed.plans[0].span.end,
            base.addingTimeInterval(90 * 60)
        )

        let completed = try TaptionWidgetCommandEngine.apply(
            TaptionWidgetCommand(
                planID: plan.id,
                kind: .complete,
                requestedAt: base.addingTimeInterval(45 * 60)
            ),
            to: source
        )
        XCTAssertEqual(completed.plans[0].status, .completed)
        XCTAssertEqual(completed.actuals.count, 1)
        XCTAssertEqual(
            completed.actuals[0].endedAt,
            base.addingTimeInterval(hour)
        )
    }

    func testWidgetSyncStatusUsesGroundTruthFingerprint() {
        var groundTruth = TaptionWidgetPayload.empty
        groundTruth.sourceFingerprint = "ground-truth"
        var cached = groundTruth
        cached.generatedAt = .now
        XCTAssertEqual(
            TaptionWidgetSyncStatus.compare(
                groundTruth: groundTruth,
                cached: cached
            ),
            .synchronized(cached.generatedAt)
        )

        cached.sourceFingerprint = "old"
        XCTAssertEqual(
            TaptionWidgetSyncStatus.compare(
                groundTruth: groundTruth,
                cached: cached
            ),
            .pending
        )
        groundTruth.sourceFingerprint = nil
        XCTAssertEqual(
            TaptionWidgetSyncStatus.compare(
                groundTruth: groundTruth,
                cached: cached
            ),
            .unavailable
        )
    }

}
