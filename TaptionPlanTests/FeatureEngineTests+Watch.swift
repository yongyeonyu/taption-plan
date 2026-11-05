import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

extension FeatureEngineTests {
    func testWatchDaySummaryTopCategoriesAndOldPayloadDecode() throws {
        let summary = TaptionWatchDaySummary(
            date: .now, scheduledCount: 0, completedCount: 0, recordedMinutes: 100, activeMinutes: 0,
            categories: [
                TaptionWatchCategoryMinutes(categoryID: "a", title: "A", hex: nil, minutes: 10),
                TaptionWatchCategoryMinutes(categoryID: "b", title: "B", hex: nil, minutes: 50),
                TaptionWatchCategoryMinutes(categoryID: "c", title: "C", hex: nil, minutes: 30),
                TaptionWatchCategoryMinutes(categoryID: "d", title: "D", hex: nil, minutes: 20),
                TaptionWatchCategoryMinutes(categoryID: "e", title: "E", hex: nil, minutes: 0),
            ]
        )
        XCTAssertEqual(summary.topCategories().map(\.categoryID), ["b", "c", "d"])
        let old = #"{"date":0,"scheduledCount":1,"completedCount":0,"recordedMinutes":5,"activeMinutes":1}"#
        let decoded = try JSONDecoder().decode(TaptionWatchDaySummary.self, from: Data(old.utf8))
        XCTAssertNil(decoded.categories)
        XCTAssertEqual(decoded.topCategories(), [])
    }

    func testWatchRecordedFractionComparesToElapsedDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        func summary(_ minutes: Int) -> TaptionWatchDaySummary {
            TaptionWatchDaySummary(date: dayStart, scheduledCount: 0, completedCount: 0, recordedMinutes: minutes, activeMinutes: 0)
        }
        let noon = dayStart.addingTimeInterval(12 * 3_600)
        XCTAssertEqual(summary(360).recordedFraction(at: noon, calendar: calendar), 0.5, accuracy: 0.001)
        XCTAssertEqual(summary(2_000).recordedFraction(at: noon, calendar: calendar), 1)
        XCTAssertEqual(summary(10).recordedFraction(at: dayStart, calendar: calendar), 0)
    }

    func testWatchNextPlanSkipsGoalsPastAndFinishedItems() {
        let now = Date(timeIntervalSince1970: 1_000)
        func item(_ title: String, _ offset: TimeInterval, status: String = "planned", isGoal: Bool = false) -> TaptionWatchPlanItem {
            var value = TaptionWatchPlanItem(
                id: UUID(), title: title, categoryID: "work",
                startsAt: now.addingTimeInterval(offset), endsAt: now.addingTimeInterval(offset + 60),
                status: status, actualStartedAt: nil, categoryName: nil, categoryHex: nil
            )
            value.isGoal = isGoal
            return value
        }
        let items = [item("past", -60), item("goal", 10, isGoal: true), item("done", 20, status: "completed"), item("later", 90), item("next", 30)]
        XCTAssertEqual(items.nextPlan(after: now)?.title, "next")
        XCTAssertNil([item("past", -60)].nextPlan(after: now))
    }

    /// 워치 페이로드가 지금 대분류를 실어 나르고, 그 값이 없던 예전 페이로드도 읽힌다.
    func testWatchPayloadCarriesCurrentActivity() throws {
        let startedAt = Date(timeIntervalSince1970: 900)
        let payload = TaptionWatchPayload(
            generatedAt: Date(timeIntervalSince1970: 1_000),
            viewportStart: Date(timeIntervalSince1970: 0),
            viewportEnd: Date(timeIntervalSince1970: 86_400),
            items: [],
            catStyle: "white",
            reducesMotion: false,
            todaySummary: nil,
            currentActivity: TaptionWatchCurrentActivity(
                categoryID: "movement.walking",
                koreanTitle: "이동",
                englishTitle: "Movement",
                startedAt: startedAt
            )
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TaptionWatchPayload.self, from: data)
        XCTAssertEqual(decoded.currentActivity?.categoryID, "movement.walking")
        XCTAssertEqual(decoded.currentActivity?.startedAt, startedAt)
        XCTAssertEqual(decoded.currentActivity?.title(for: .english), "Movement")

        // 예전 빌드가 보낸 페이로드(currentActivity 키 없음)도 그대로 읽힌다.
        var legacy = payload
        legacy.currentActivity = nil
        let legacyData = try JSONEncoder().encode(legacy)
        let legacyJSON = try XCTUnwrap(
            String(data: legacyData, encoding: .utf8)
        )
        XCTAssertFalse(legacyJSON.contains("currentActivity"))
        let legacyDecoded = try JSONDecoder().decode(
            TaptionWatchPayload.self,
            from: legacyData
        )
        XCTAssertNil(legacyDecoded.currentActivity)
    }

    @MainActor
    func testBackgroundWorkReusesTheApplicationSensorAndWatchOwner() {
        let model = AppModel(
            repository: InMemoryPlanRepository(),
            cloudSyncService: nil
        )

        XCTAssertTrue(AppModel.backgroundTaskInstance() === model)
        XCTAssertTrue(
            AppModel.backgroundTaskInstance()
                === AppModel.backgroundTaskInstance()
        )
    }

    func testAppleWatchVibrationAloneDoesNotConfirmSubway() {
        let base = makeDate(2026, 7, 30, 8, 0)
        let readings: [SensorReading] = (0..<6).map { index -> SensorReading in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: index < 2 ? 14 : nil,
                motion: .automotive,
                motionConfidence: .high,
                relativeAltitudeMeters: Double(index) * -2,
                stepCount: 100,
                watchAccelerationStandardDeviationG: 0.04,
                watchAccelerationMeanJerkGPerSecond: 0.16,
                gpsAvailable: index < 2,
                nearbyStation: true,
                frequentStops: true
            )
        }

        // 워치 진동과 지하 신호만으로는 탑승·하차역을 알 수 없어 지하철로 확정하지 않는다(PAW1102A03).
        let result = TravelModeClassifier().classify(readings: readings)
        XCTAssertNotEqual(result.mode, .subway)
        XCTAssertTrue(result.evidence.contains { $0.hasPrefix("지하철 조건 부족") })
    }

    func testWatchVibrationWithoutUndergroundContextDoesNotBecomeSubway() {
        let base = makeDate(2026, 7, 30, 8, 0)
        let readings = (0..<4).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                speedMetersPerSecond: 13,
                motion: .automotive,
                motionConfidence: .high,
                stepCount: 20,
                watchAccelerationStandardDeviationG: 0.04,
                watchAccelerationMeanJerkGPerSecond: 0.16,
                gpsAvailable: true
            )
        }

        XCTAssertNotEqual(
            TravelModeClassifier().classify(readings: readings).mode,
            .subway
        )
    }

    func testAppleWatchWorkoutTiesUseStableTravelModeOrder() {
        let start = makeDate(2026, 8, 10, 9, 0)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(5 * 60))
        let evidence = [
            AppleMovementEvidence(
                span: span,
                source: .appleWatch,
                kind: .workout,
                workoutMode: .walking,
                sourceName: "Apple Watch"
            ),
            AppleMovementEvidence(
                span: span,
                source: .appleWatch,
                kind: .workout,
                workoutMode: .running,
                sourceName: "Apple Watch"
            ),
        ]
        let classifier = TravelModeClassifier()
        let forward = classifier.classify(
            readings: [],
            inside: span,
            healthEvidence: evidence
        )
        let reversed = classifier.classify(
            readings: [],
            inside: span,
            healthEvidence: Array(evidence.reversed())
        )

        XCTAssertEqual(forward.mode, .walking)
        XCTAssertEqual(forward.confidence, .high)
        XCTAssertEqual(reversed, forward)
    }

    func testAppleWatchWorkoutOverridesConflictingIPhoneMotion() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(10 * 60)
        )
        let readings = (0..<6).map { index in
            SensorReading(
                timestamp: base.addingTimeInterval(Double(index) * 2 * 60),
                speedMetersPerSecond: 8,
                motion: .automotive,
                motionConfidence: .high,
                stepCount: index * 100
            )
        }
        let watchWorkout = AppleMovementEvidence(
            span: span,
            source: .appleWatch,
            kind: .workout,
            workoutMode: .walking,
            stepCount: 1_000,
            distanceMeters: 800,
            sourceName: "Apple Watch",
            deviceName: "Apple Watch"
        )

        let result = TravelModeClassifier().classify(
            readings: readings,
            inside: span,
            healthEvidence: [watchWorkout]
        )

        XCTAssertEqual(result.mode, .walking)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertTrue(
            result.evidence.contains("Apple Watch 걷기 운동")
        )
    }

    /// 워치가 밤을 직접 쟀으면 아이폰 추정이 그 위에 섞이지 않는다.
    func testWatchStagesReplaceIPhoneEstimateForSameNight() {
        let base = makeDate(2026, 9, 2, 22)
        let sessions = SleepAnalysisEngine().sessions(from: [
            SleepSegment(
                stage: .asleepUnspecified,
                span: TimeSpan(start: base, end: base.addingTimeInterval(10 * hour)),
                sourceName: "iPhone",
                sourceBundleIdentifier: "com.apple.Health"
            ),
            SleepSegment(
                stage: .core,
                span: TimeSpan(
                    start: base.addingTimeInterval(hour),
                    end: base.addingTimeInterval(8 * hour)
                ),
                sourceName: "Apple Watch",
                deviceName: "Apple Watch"
            )
        ])

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].asleepDuration, 7 * hour)
        XCTAssertEqual(sessions[0].sourceTier, .appleWatch)
        XCTAssertFalse(sessions[0].isProvisional)
        XCTAssertTrue(sessions[0].isWatchAuthoritative)
    }

    func testWatchReconciliationRecordsReplacedIPhoneEstimate() {
        let base = makeDate(2026, 9, 4, 22)
        let estimate = SleepAnalysisEngine().sessions(from: [
            SleepSegment(
                stage: .asleepUnspecified,
                span: TimeSpan(start: base, end: base.addingTimeInterval(10 * hour)),
                sourceName: "iPhone",
                sourceBundleIdentifier: "com.apple.Health"
            )
        ])
        let confirmed = SleepAnalysisEngine().sessions(from: [
            SleepSegment(
                stage: .core,
                span: TimeSpan(
                    start: base.addingTimeInterval(hour),
                    end: base.addingTimeInterval(8 * hour)
                ),
                sourceName: "Apple Watch",
                deviceName: "Apple Watch"
            )
        ])
        let records = SleepAnalysisEngine().reconciliations(
            previous: estimate,
            resolved: confirmed,
            now: base.addingTimeInterval(9 * hour)
        )

        XCTAssertEqual(records.count, 1)
        let record = records[0]
        XCTAssertEqual(record.reason, .watchReplacedEstimate)
        XCTAssertEqual(record.estimatedTier, .iPhone)
        XCTAssertEqual(record.authoritativeTier, .appleWatch)
        XCTAssertEqual(record.estimatedAsleepDuration, 10 * hour)
        XCTAssertEqual(record.authoritativeAsleepDuration, 7 * hour)
        XCTAssertEqual(record.asleepDurationDelta, -3 * hour)
        XCTAssertEqual(record.spanStartDelta, hour)
    }

    /// 워치가 이미 확정한 밤은 다시 보정 기록을 만들지 않는다.
    func testWatchReconciliationIgnoresAlreadyConfirmedNight() {
        let base = makeDate(2026, 9, 5, 23)
        let confirmed = SleepAnalysisEngine().sessions(from: [
            SleepSegment(
                stage: .core,
                span: TimeSpan(start: base, end: base.addingTimeInterval(7 * hour)),
                sourceName: "Apple Watch",
                deviceName: "Apple Watch"
            )
        ])

        XCTAssertTrue(
            SleepAnalysisEngine().reconciliations(
                previous: confirmed,
                resolved: confirmed
            ).isEmpty
        )
    }

    func testWatchCollectionAndDataSyncProfilesAreIndependent() throws {
        XCTAssertEqual(
            TaptionWatchAccelerationProfile.batterySaver.interval,
            15 * 60
        )
        XCTAssertEqual(
            TaptionWatchAccelerationProfile.accuracy.interval,
            60
        )
        XCTAssertEqual(
            TaptionWatchDataSyncProfile.balanced.interval,
            5 * 60
        )
        XCTAssertNil(TaptionWatchDataSyncProfile.off.intervalMinutes)

        let settings = TaptionWatchAccelerationSettings(
            profile: .accuracy,
            samplingWindowSeconds: 90
        )
        XCTAssertEqual(settings.samplingWindowSeconds, 60)
        XCTAssertTrue(settings.isEnabled)

        let data = try JSONEncoder().encode(
            TaptionWatchPayload(
                generatedAt: .now,
                viewportStart: .now,
                viewportEnd: .now,
                items: [],
                catStyle: "calico",
                reducesMotion: false,
                accelerationSettings: settings,
                dataSyncProfile: .batterySaver,
                locationTrackingEnabled: true,
                locationPermissionState: PermissionState.authorized.rawValue,
                commerceLocked: true
            )
        )
        let decoded = try JSONDecoder().decode(
            TaptionWatchPayload.self,
            from: data
        )
        XCTAssertEqual(decoded.accelerationSettings, settings)
        XCTAssertEqual(decoded.dataSyncProfile, .batterySaver)
        XCTAssertEqual(decoded.locationTrackingEnabled, true)
        XCTAssertEqual(decoded.commerceLocked, true)
        XCTAssertEqual(
            decoded.locationPermissionState,
            PermissionState.authorized.rawValue
        )
    }

    func testMergingTravelPreservesPrimaryThenWatchPriority() {
        let base = makeDate(2026, 8, 1, 9, 0)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(10 * 60)
        )
        let watchWorkout = AppleMovementEvidence(
            span: span,
            source: .appleWatch,
            kind: .workout,
            workoutMode: .walking,
            distanceMeters: 800,
            sourceName: "Apple Watch"
        )
        let motion = MotionActivityRecord(
            span: span,
            motion: .automotive,
            confidence: .high
        )

        let watchWins = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: [],
            motionActivities: [motion],
            pedometer: nil,
            healthEvidence: [watchWorkout]
        )

        XCTAssertEqual(watchWins.count, 1)
        XCTAssertEqual(watchWins[0].mode, .walking)
        XCTAssertTrue(watchWins[0].evidence.contains("Apple Watch 운동 기록"))

        let gps = TravelSegment(
            mode: .car,
            span: span,
            distanceMeters: 5_000,
            confidence: .high,
            evidence: ["GPS"]
        )
        let primaryWins = AppleDeviceGroundTruthEngine.mergingTravel(
            gpsSegments: [gps],
            motionActivities: [motion],
            pedometer: nil,
            healthEvidence: [watchWorkout]
        )

        XCTAssertEqual(primaryWins, [gps])
    }

    func testLinkedWatchWorkoutSupersedesItsTimerActual() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let planID = UUID()
        let timer = ActualRecord(
            planID: planID,
            title: "아침 달리기",
            categoryID: "exercise",
            startedAt: base,
            endedAt: base.addingTimeInterval(30 * 60),
            source: .timer
        )
        let otherTimer = ActualRecord(
            planID: UUID(),
            title: "다른 계획",
            categoryID: "project",
            startedAt: base,
            endedAt: base.addingTimeInterval(30 * 60),
            source: .timer
        )
        let watchWorkout = ActualRecord(
            planID: planID,
            title: "아침 달리기",
            categoryID: "exercise",
            startedAt: base.addingTimeInterval(20),
            endedAt: base.addingTimeInterval(31 * 60),
            source: .healthKit
        )

        let result = AppleDeviceGroundTruthEngine.replacingHealthKitActuals(
            existing: [timer, otherTimer],
            with: [watchWorkout],
            inside: TimeSpan(
                start: base.addingTimeInterval(-60),
                end: base.addingTimeInterval(60 * 60)
            )
        )

        XCTAssertFalse(result.contains(timer))
        XCTAssertTrue(result.contains(otherTimer))
        XCTAssertTrue(result.contains(watchWorkout))
    }

    func testWatchPayloadAndCommandRoundTrip() throws {
        let planID = UUID()
        let command = TaptionWatchCommand(
            planID: planID,
            kind: .postponeThirtyMinutes
        )
        let commandData = try JSONEncoder().encode(command)
        XCTAssertEqual(
            try JSONDecoder().decode(
                TaptionWatchCommand.self,
                from: commandData
            ),
            command
        )

        let base = makeDate(2026, 7, 30, 9, 0)
        let payload = TaptionWatchPayload(
            generatedAt: base,
            viewportStart: base,
            viewportEnd: base.addingTimeInterval(24 * hour),
            items: [
                TaptionWatchPlanItem(
                    id: planID,
                    title: "워치 연동",
                    categoryID: "project",
                    startsAt: base,
                    endsAt: base.addingTimeInterval(hour),
                    status: PlanStatus.planned.rawValue,
                    actualStartedAt: nil,
                    categoryName: "프로젝트",
                    categoryHex: "#5C81B1"
                )
            ],
            catStyle: CatStyle.calico.rawValue,
            reducesMotion: false,
            todaySummary: TaptionWatchDaySummary(
                date: base,
                scheduledCount: 3,
                completedCount: 1,
                recordedMinutes: 95,
                activeMinutes: 40
            )
        )
        let payloadData = try JSONEncoder().encode(payload)
        XCTAssertEqual(
            try JSONDecoder().decode(
                TaptionWatchPayload.self,
                from: payloadData
            ),
            payload
        )
    }

    func testWatchLiveItemPolicyDropsPastItemsAndKeepsParallelCurrentItems() {
        let now = makeDate(2026, 8, 1, 10, 0)
        let past = TaptionWatchPlanItem(
            id: UUID(),
            title: "지난 계획",
            categoryID: "project",
            startsAt: now.addingTimeInterval(-2 * hour),
            endsAt: now.addingTimeInterval(-hour),
            status: PlanStatus.planned.rawValue,
            actualStartedAt: nil,
            categoryName: "프로젝트",
            categoryHex: "#5C81B1"
        )
        let goal = TaptionWatchPlanItem(
            id: UUID(),
            title: "목표: 운동",
            categoryID: "exercise",
            startsAt: now.addingTimeInterval(-30 * 60),
            endsAt: now.addingTimeInterval(90 * 60),
            status: PlanStatus.planned.rawValue,
            actualStartedAt: nil,
            categoryName: "운동",
            categoryHex: "#4E8E63",
            isGoal: true
        )
        let plan = TaptionWatchPlanItem(
            id: UUID(),
            title: "달리기",
            categoryID: "exercise",
            startsAt: now,
            endsAt: now.addingTimeInterval(30 * 60),
            status: PlanStatus.running.rawValue,
            actualStartedAt: now,
            categoryName: "운동",
            categoryHex: "#4E8E63",
            parentID: goal.id
        )
        let completed = TaptionWatchPlanItem(
            id: UUID(),
            title: "완료된 계획",
            categoryID: "project",
            startsAt: now.addingTimeInterval(-15 * 60),
            endsAt: now.addingTimeInterval(15 * 60),
            status: PlanStatus.completed.rawValue,
            actualStartedAt: nil,
            categoryName: "프로젝트",
            categoryHex: "#5C81B1"
        )
        let upcoming = TaptionWatchPlanItem(
            id: UUID(),
            title: "다음 계획",
            categoryID: "project",
            startsAt: now.addingTimeInterval(2 * hour),
            endsAt: now.addingTimeInterval(3 * hour),
            status: PlanStatus.planned.rawValue,
            actualStartedAt: nil,
            categoryName: "프로젝트",
            categoryHex: "#5C81B1"
        )

        let items = [past, goal, plan, completed, upcoming]
        XCTAssertEqual(
            TaptionWatchLiveItemPolicy.current(items, at: now).map(\.id),
            [goal.id, plan.id]
        )
        XCTAssertEqual(
            TaptionWatchLiveItemPolicy.upcoming(items, at: now).map(\.id),
            [upcoming.id]
        )
        XCTAssertFalse(TaptionWatchLiveItemPolicy.isLive(past, at: now))
        XCTAssertFalse(
            TaptionWatchLiveItemPolicy.isLive(completed, at: now)
        )
    }

    func testWatchPlanItemDecodesPayloadWithoutNewGoalFields() throws {
        let id = UUID()
        let base = makeDate(2026, 8, 1, 10)
        let legacy: [String: Any] = [
            "id": id.uuidString,
            "title": "기존 워치 계획",
            "categoryID": "project",
            "startsAt": base.timeIntervalSince1970,
            "endsAt": base.addingTimeInterval(hour).timeIntervalSince1970,
            "status": PlanStatus.planned.rawValue,
            "categoryName": "프로젝트",
            "categoryHex": "#5C81B1"
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let item = try decoder.decode(TaptionWatchPlanItem.self, from: data)
        XCTAssertFalse(item.isGoal)
        XCTAssertNil(item.parentID)
        XCTAssertEqual(item.id, id)
    }

    func testWatchDaySummaryMergesOverlappingActuals() {
        let base = makeDate(2026, 7, 30, 9)
        let plans = [
            PlanRecord(
                title: "완료한 계획",
                span: TimeSpan(
                    start: base,
                    end: base.addingTimeInterval(hour)
                ),
                categoryID: "project",
                status: .completed
            ),
            PlanRecord(
                title: "다음 계획",
                span: TimeSpan(
                    start: base.addingTimeInterval(2 * hour),
                    end: base.addingTimeInterval(3 * hour)
                ),
                categoryID: "study"
            ),
            PlanRecord(
                title: "건너뛴 계획",
                span: TimeSpan(
                    start: base,
                    end: base.addingTimeInterval(hour)
                ),
                categoryID: "hobby",
                status: .skipped
            ),
        ]
        let actuals = [
            ActualRecord(
                planID: nil,
                title: "걷기",
                categoryID: "movement",
                startedAt: base,
                endedAt: base.addingTimeInterval(hour),
                source: .appleWatch
            ),
            ActualRecord(
                planID: nil,
                title: "운동",
                categoryID: "exercise",
                startedAt: base.addingTimeInterval(30 * 60),
                endedAt: base.addingTimeInterval(90 * 60),
                source: .healthKit
            ),
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "project",
                startedAt: base.addingTimeInterval(3 * hour),
                endedAt: base.addingTimeInterval(4 * hour),
                source: .timer
            ),
        ]

        let summary = TaptionWatchDaySummaryFactory.make(
            plans: plans,
            actuals: actuals,
            at: base.addingTimeInterval(6 * hour),
            calendar: utcCalendar
        )

        XCTAssertEqual(summary.scheduledCount, 2)
        XCTAssertEqual(summary.completedCount, 1)
        XCTAssertEqual(summary.recordedMinutes, 150)
        XCTAssertEqual(summary.activeMinutes, 90)
    }

    func testWatchSensorSummaryRoundTripCreatesOneActivityAndHealthReplacesIt()
        throws {
        let base = makeDate(2026, 7, 30, 9, 0)
        let plan = PlanRecord(
            title: "출근 달리기",
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(30 * 60)
            ),
            categoryID: "exercise"
        )
        let summary = TaptionWatchSensorSummary(
            sessionID: UUID(),
            sequence: 2,
            workoutKind: .running,
            linkedPlanID: plan.id,
            linkedPlanTitle: plan.title,
            linkedCategoryID: plan.categoryID,
            startedAt: base,
            endedAt: base.addingTimeInterval(30 * 60),
            isFinal: true,
            accelerometerSampleCount: 18_000,
            accelerometerAverageG: TaptionWatchSensorVector3(
                x: 0.1,
                y: -0.2,
                z: 0.9
            ),
            peakAccelerationG: 2.4,
            gyroscopeSampleCount: 18_000,
            gyroscopeAverageRadiansPerSecond: TaptionWatchSensorVector3(
                x: 0.2,
                y: 0.1,
                z: -0.1
            ),
            peakRotationRateRadiansPerSecond: 3.1,
            gravity: TaptionWatchSensorVector3(x: 0, y: 0, z: -1),
            userAccelerationG: TaptionWatchSensorVector3(
                x: 0.1,
                y: 0.2,
                z: 0.3
            ),
            rotationRateRadiansPerSecond: TaptionWatchSensorVector3(
                x: 0.2,
                y: 0.3,
                z: 0.4
            ),
            attitudeRadians: TaptionWatchSensorVector3(
                x: 0.3,
                y: 0.4,
                z: 0.5
            ),
            relativeAltitudeMeters: 8.4,
            pressureKilopascals: 100.8,
            stepCount: 3_210,
            distanceMeters: 4_800,
            floorsAscended: 2,
            floorsDescended: 1,
            latestHeartRate: 154,
            averageHeartRate: 146,
            maximumHeartRate: 171,
            activeEnergyKilocalories: 280
        )

        let encoded = try JSONEncoder().encode(summary)
        XCTAssertEqual(
            try JSONDecoder().decode(
                TaptionWatchSensorSummary.self,
                from: encoded
            ),
            summary
        )

        let watchActuals = AppleWatchSensorActivityEngine.upserting(
            summary,
            into: [],
            linkedPlan: plan
        )
        let repeated = AppleWatchSensorActivityEngine.upserting(
            summary,
            into: watchActuals,
            linkedPlan: plan
        )
        XCTAssertEqual(repeated.count, 1)
        XCTAssertEqual(repeated[0].id, summary.sessionID)
        XCTAssertEqual(repeated[0].source, .appleWatch)
        XCTAssertEqual(repeated[0].planID, plan.id)

        let healthActual = ActualRecord(
            id: summary.sessionID,
            planID: plan.id,
            title: plan.title,
            categoryID: plan.categoryID,
            startedAt: summary.startedAt,
            endedAt: summary.endedAt,
            source: .healthKit
        )
        let reconciled = AppleDeviceGroundTruthEngine
            .replacingHealthKitActuals(
                existing: repeated,
                with: [healthActual],
                inside: TimeSpan(
                    start: base.addingTimeInterval(-60),
                    end: base.addingTimeInterval(hour)
                )
            )
        XCTAssertEqual(reconciled, [healthActual])
    }

    func testWatchBehaviorRulesPrioritizeWorkoutAndDetectStairs() {
        let workout = WatchBehaviorClassifier.classify(
            WatchBehaviorInput(
                workoutKind: .running,
                duration: 30,
                steps: 20
            )
        )
        XCTAssertEqual(workout.kind, .running)
        XCTAssertGreaterThan(workout.confidenceScore, 0.9)
        XCTAssertTrue(workout.evidence.contains("Apple Watch 운동 종류"))

        let stairs = WatchBehaviorClassifier.classify(
            WatchBehaviorInput(
                duration: 120,
                accelerometerSampleCount: 3_000,
                accelerometerStandardDeviationG: 0.12,
                accelerometerMeanJerkGPerSecond: 0.3,
                steps: 140,
                floorsAscended: 3,
                altitudeDeltaMeters: 9
            )
        )
        XCTAssertEqual(stairs.kind, .stairsUp)
        XCTAssertTrue(stairs.evidence.contains("걸음·층수 증가"))
    }

    func testWatchHARWindowExtractsPeriodicWalkingFeatures() throws {
        let start = makeDate(2026, 8, 2, 9)
        let samples = (0..<65).map { index in
            let elapsed = Double(index) / 25
            let wave = sin(2 * .pi * 1.8 * elapsed) * 0.14
            return WatchMotionSample(
                capturedAt: start.addingTimeInterval(elapsed),
                acceleration: TaptionWatchSensorVector3(
                    x: 0,
                    y: 0,
                    z: 1 + wave
                ),
                rotationRate: TaptionWatchSensorVector3(x: 0.2, y: 0, z: 0),
                gravity: TaptionWatchSensorVector3(x: 0, y: 0, z: 1)
            )
        }
        let features = try XCTUnwrap(
            WatchBehaviorWindowAnalyzer.features(from: samples)
        )
        XCTAssertGreaterThan(features.bodyAccelerationRMSG, 0.05)
        XCTAssertGreaterThan(features.dominantFrequencyHz ?? 0, 1.2)
        XCTAssertLessThan(features.dominantFrequencyHz ?? 0, 4.2)

        let inference = WatchBehaviorClassifier.classifyWindow(
            features,
            context: WatchBehaviorInput(
                duration: features.duration,
                accelerometerSampleCount: features.sampleCount,
                steps: 3,
                gpsAvailable: false
            )
        )
        XCTAssertEqual(inference.kind, .walking)
        XCTAssertTrue(inference.evidence.contains("IMU 보행 주기"))
        XCTAssertEqual(inference.modelVersion, WatchBehaviorClassifier.rulesVersion)
    }

    func testWatchHARWindowDistinguishesFineHandBehaviors() {
        let typing = WatchBehaviorClassifier.classify(
            WatchBehaviorInput(
                duration: 2.56,
                accelerometerSampleCount: 64,
                steps: 0,
                accelerationBodyRMSG: 0.06,
                accelerationZeroCrossingRateHz: 0.8,
                gyroscopeRMSG: 0.3
            )
        )
        XCTAssertEqual(typing.kind, .typing)

        let brushing = WatchBehaviorClassifier.classify(
            WatchBehaviorInput(
                duration: 2.56,
                accelerometerSampleCount: 64,
                steps: 0,
                accelerationBodyRMSG: 0.08,
                gyroscopeRMSG: 1.8
            )
        )
        XCTAssertEqual(brushing.kind, .brushingTeeth)
    }

    func testWatchHARWindowRefinesBroadWorkoutWithoutLosingFallback() throws {
        let start = makeDate(2026, 8, 2, 9)
        let samples = (0..<65).map { index in
            let elapsed = Double(index) / 25
            let wave = sin(2 * .pi * 1.8 * elapsed) * 0.14
            return WatchMotionSample(
                capturedAt: start.addingTimeInterval(elapsed),
                acceleration: TaptionWatchSensorVector3(
                    x: 0,
                    y: 0,
                    z: 1 + wave
                ),
                rotationRate: nil,
                gravity: TaptionWatchSensorVector3(x: 0, y: 0, z: 1)
            )
        }
        let features = try XCTUnwrap(
            WatchBehaviorWindowAnalyzer.features(from: samples)
        )
        let refined = WatchBehaviorClassifier.classifyWindow(
            features,
            context: WatchBehaviorInput(
                workoutKind: .walking,
                duration: features.duration,
                steps: 3
            )
        )
        XCTAssertEqual(refined.kind, .walking)

        let fallback = WatchBehaviorClassifier.classifyWindow(
            WatchBehaviorWindowFeatures(
                startedAt: start,
                endedAt: start.addingTimeInterval(2.56),
                sampleCount: 64,
                sampleRateHz: 25,
                accelerationMeanG: 1,
                accelerationStandardDeviationG: 0,
                bodyAccelerationRMSG: 0,
                jerkRMSGPerSecond: 0,
                zeroCrossingRateHz: 0,
                dominantFrequencyHz: nil,
                gyroscopeRMSGPerSecond: 0,
                posturePitchRadians: 0,
                postureRollRadians: 0
            ),
            context: WatchBehaviorInput(
                workoutKind: .cycling,
                duration: 2.56
            )
        )
        XCTAssertEqual(fallback.kind, .cycling)
    }

    func testWatchHARFeatureVectorAndTemporalAggregation() throws {
        let start = makeDate(2026, 8, 2, 9)
        let samples = (0..<65).map { index in
            let elapsed = Double(index) / 25
            let wave = sin(2 * .pi * 1.8 * elapsed) * 0.14
            return WatchMotionSample(
                capturedAt: start.addingTimeInterval(elapsed),
                acceleration: TaptionWatchSensorVector3(
                    x: 0,
                    y: 0,
                    z: 1 + wave
                ),
                rotationRate: nil,
                gravity: TaptionWatchSensorVector3(x: 0, y: 0, z: 1)
            )
        }
        let features = try XCTUnwrap(
            WatchBehaviorWindowAnalyzer.features(from: samples)
        )
        XCTAssertEqual(
            features.featureVector.count,
            12
        )
        XCTAssertEqual(
            WatchBehaviorWindowFeatures.featureSchemaVersion,
            "watch-har-window-v1"
        )
        XCTAssertEqual(
            WatchBehaviorKind.fromModelLabel("달리기"),
            .running
        )
        XCTAssertEqual(
            WatchBehaviorKind.fromModelLabel("stairsUp"),
            .stairsUp
        )

        let walking = WatchBehaviorSegment(
            startedAt: start,
            endedAt: start.addingTimeInterval(10),
            behavior: .walking,
            confidenceScore: 0.8,
            evidence: ["보행"],
            modelVersion: WatchBehaviorClassifier.rulesVersion
        )
        let stationary = WatchBehaviorSegment(
            startedAt: start.addingTimeInterval(10),
            endedAt: start.addingTimeInterval(18),
            behavior: .stationary,
            confidenceScore: 0.95,
            evidence: ["저진동"],
            modelVersion: WatchBehaviorClassifier.rulesVersion
        )
        let aggregate = WatchBehaviorClassifier.aggregate(
            [walking, stationary],
            fallback: WatchBehaviorInference(
                kind: .unknown,
                confidenceScore: 0.2,
                evidence: [],
                modelVersion: WatchBehaviorClassifier.rulesVersion
            )
        )
        XCTAssertEqual(aggregate.kind, .walking)
        XCTAssertTrue(aggregate.evidence.contains("시간 가중 집계"))
    }

    func testWatchRawReplayUsesOverlappingChunkWithoutMatchingSequence() {
        let start = makeDate(2026, 8, 2, 9)
        let sessionID = UUID()
        let summary = TaptionWatchSensorSummary(
            sessionID: sessionID,
            sequence: 1,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: start,
            endedAt: start.addingTimeInterval(3.1),
            isFinal: false,
            accelerometerSampleCount: 32,
            accelerometerAverageG: nil,
            peakAccelerationG: 1.14,
            gyroscopeSampleCount: 0,
            gyroscopeAverageRadiansPerSecond: nil,
            peakRotationRateRadiansPerSecond: nil,
            gravity: nil,
            userAccelerationG: nil,
            rotationRateRadiansPerSecond: nil,
            attitudeRadians: nil,
            relativeAltitudeMeters: nil,
            pressureKilopascals: nil,
            stepCount: nil,
            distanceMeters: nil,
            floorsAscended: nil,
            floorsDescended: nil,
            latestHeartRate: nil,
            averageHeartRate: nil,
            maximumHeartRate: nil,
            activeEnergyKilocalories: nil,
            behavior: .stationary,
            behaviorConfidenceScore: 0.55,
            behaviorEvidence: ["기존 요약"],
            behaviorModelVersion: WatchBehaviorClassifier.rulesVersion
        )
        let samples = (0..<32).map { index in
            TaptionWatchAccelerationSample(
                capturedAt: start.addingTimeInterval(Double(index) * 0.1),
                acceleration: TaptionWatchSensorVector3(
                    x: 1 + sin(Double(index) * 0.8) * 0.14,
                    y: 0,
                    z: 0
                ),
                sessionID: sessionID,
                sequence: index + 1,
                isAmbient: false
            )
        }
        let chunk = TaptionWatchAccelerationChunk(
            sessionID: sessionID,
            sequence: 99,
            startedAt: start,
            endedAt: start.addingTimeInterval(3.1),
            samples: samples
        )

        let replayed = WatchActivityRawReplayEngine.replaying(
            summaries: [summary],
            chunks: [chunk]
        )

        XCTAssertEqual(replayed.count, 1)
        XCTAssertEqual(
            replayed.first?.behaviorModelVersion,
            WatchActivityRawReplayEngine.modelVersion
        )
        XCTAssertTrue(
            replayed.first?.behaviorEvidence?.contains("raw 표본 32개") == true
        )
    }

    func testWatchSensorChunksUpdateTheSameImmutableActivity() {
        let base = makeDate(2026, 8, 2, 9)
        let sessionID = UUID()
        let first = TaptionWatchSensorSummary(
            sessionID: sessionID,
            sequence: 1,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: base,
            endedAt: base.addingTimeInterval(30),
            isFinal: false,
            accelerometerSampleCount: 750,
            accelerometerAverageG: nil,
            peakAccelerationG: 0.9,
            gyroscopeSampleCount: 0,
            gyroscopeAverageRadiansPerSecond: nil,
            peakRotationRateRadiansPerSecond: nil,
            gravity: nil,
            userAccelerationG: nil,
            rotationRateRadiansPerSecond: nil,
            attitudeRadians: nil,
            relativeAltitudeMeters: nil,
            pressureKilopascals: nil,
            stepCount: 40,
            distanceMeters: 30,
            floorsAscended: nil,
            floorsDescended: nil,
            latestHeartRate: 90,
            averageHeartRate: 88,
            maximumHeartRate: 95,
            activeEnergyKilocalories: 4,
            behavior: .walking,
            behaviorConfidenceScore: 0.8,
            behaviorEvidence: ["걸음"],
            behaviorModelVersion: WatchBehaviorClassifier.rulesVersion
        )
        let second = TaptionWatchSensorSummary(
            sessionID: sessionID,
            sequence: 2,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: base,
            endedAt: base.addingTimeInterval(90),
            isFinal: true,
            accelerometerSampleCount: 2_250,
            accelerometerAverageG: nil,
            peakAccelerationG: 1.1,
            gyroscopeSampleCount: 0,
            gyroscopeAverageRadiansPerSecond: nil,
            peakRotationRateRadiansPerSecond: nil,
            gravity: nil,
            userAccelerationG: nil,
            rotationRateRadiansPerSecond: nil,
            attitudeRadians: nil,
            relativeAltitudeMeters: nil,
            pressureKilopascals: nil,
            stepCount: 130,
            distanceMeters: 100,
            floorsAscended: nil,
            floorsDescended: nil,
            latestHeartRate: 98,
            averageHeartRate: 92,
            maximumHeartRate: 105,
            activeEnergyKilocalories: 14,
            behavior: .walking,
            behaviorConfidenceScore: 0.9,
            behaviorEvidence: ["걸음"],
            behaviorModelVersion: WatchBehaviorClassifier.rulesVersion
        )
        let firstActual = AppleWatchSensorActivityEngine.upserting(
            first,
            into: [],
            linkedPlan: nil
        )
        let finalActual = AppleWatchSensorActivityEngine.upserting(
            second,
            into: firstActual,
            linkedPlan: nil
        )
        XCTAssertEqual(finalActual.count, 1)
        XCTAssertEqual(finalActual[0].endedAt, second.endedAt)
        XCTAssertEqual(finalActual[0].behavior, WatchBehaviorKind.walking.rawValue)
        XCTAssertEqual(finalActual[0].modelVersion, WatchBehaviorClassifier.rulesVersion)
    }

    func testAmbientWatchMotionAtHomeCreatesHouseworkRecord() {
        let base = makeDate(2026, 8, 2, 14)
        let sessionID = UUID()
        let first = TaptionWatchSensorSummary(
            sessionID: sessionID,
            sequence: 1,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: base,
            endedAt: base.addingTimeInterval(30),
            isFinal: false,
            accelerometerSampleCount: 150,
            accelerometerAverageG: nil,
            peakAccelerationG: 1.2,
            accelerometerStandardDeviationG: 0.08,
            accelerometerMeanJerkGPerSecond: 0.2,
            gyroscopeSampleCount: 0,
            gyroscopeAverageRadiansPerSecond: nil,
            peakRotationRateRadiansPerSecond: nil,
            gravity: nil,
            userAccelerationG: nil,
            rotationRateRadiansPerSecond: nil,
            attitudeRadians: nil,
            relativeAltitudeMeters: nil,
            pressureKilopascals: nil,
            stepCount: nil,
            distanceMeters: nil,
            floorsAscended: nil,
            floorsDescended: nil,
            latestHeartRate: nil,
            averageHeartRate: nil,
            maximumHeartRate: nil,
            activeEnergyKilocalories: nil,
            behavior: .stationary,
            behaviorConfidenceScore: 0.7,
            behaviorEvidence: ["지속 움직임"],
            behaviorModelVersion: WatchBehaviorClassifier.rulesVersion,
            isAmbient: true
        )
        var second = first
        second.sequence = 2
        second.endedAt = base.addingTimeInterval(60)

        let firstActuals = AppleWatchSensorActivityEngine.upserting(
            first,
            into: [],
            linkedPlan: nil,
            atHome: true
        )
        let finalActuals = AppleWatchSensorActivityEngine.upserting(
            second,
            into: firstActuals,
            linkedPlan: nil,
            atHome: true
        )

        XCTAssertEqual(finalActuals.count, 1)
        XCTAssertEqual(finalActuals[0].title, "집안일")
        XCTAssertEqual(finalActuals[0].behavior, WatchBehaviorKind.housework.rawValue)
        XCTAssertEqual(finalActuals[0].endedAt, second.endedAt)

        let outsideHome = AppleWatchSensorActivityEngine.upserting(
            second,
            into: [],
            linkedPlan: nil,
            atHome: false
        )
        XCTAssertTrue(outsideHome.isEmpty)
    }

    func testWatchAsksAboutShowerFromHomeWaterLockAndMotion() throws {
        let base = makeDate(2026, 8, 9, 7)
        let summary = TaptionWatchSensorSummary(
            sessionID: UUID(),
            sequence: 1,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: base,
            endedAt: base.addingTimeInterval(2 * 60),
            isFinal: true,
            accelerometerSampleCount: 1_500,
            accelerometerAverageG: nil,
            peakAccelerationG: 1.3,
            accelerometerStandardDeviationG: 0.08,
            accelerometerMeanJerkGPerSecond: 0.2,
            gyroscopeSampleCount: 0,
            gyroscopeAverageRadiansPerSecond: nil,
            peakRotationRateRadiansPerSecond: 1.2,
            gravity: nil,
            userAccelerationG: nil,
            rotationRateRadiansPerSecond: nil,
            attitudeRadians: nil,
            relativeAltitudeMeters: nil,
            pressureKilopascals: nil,
            stepCount: 0,
            distanceMeters: nil,
            floorsAscended: nil,
            floorsDescended: nil,
            latestHeartRate: nil,
            averageHeartRate: 82,
            maximumHeartRate: nil,
            activeEnergyKilocalories: nil,
            behavior: .housework,
            behaviorConfidenceScore: 0.62,
            behaviorEvidence: ["손목 움직임"],
            behaviorModelVersion: WatchBehaviorClassifier.rulesVersion,
            isAmbient: true,
            waterLockEnabled: true
        )

        let resolution = WatchActivityPersonalizationEngine.resolve(
            summary,
            atHome: true,
            learnedSamples: [],
            now: base.addingTimeInterval(2 * 60)
        )
        let suggestion = try XCTUnwrap(resolution.suggestion)
        XCTAssertNil(resolution.learnedBehavior)
        XCTAssertEqual(suggestion.proposedBehavior, .showering)
        XCTAssertTrue(suggestion.alternativeBehaviors.contains(.housework))
        XCTAssertTrue(suggestion.evidence.contains("Water Lock 켜짐"))
    }

    func testThreeMatchingWatchConfirmationsEnableAutomaticClassification()
        throws {
        let pattern = WatchActivityPattern(
            duration: 120,
            accelerationVariationG: 0.08,
            jerkGPerSecond: 0.2,
            peakRotationRate: 1.2,
            stepsPerMinute: 0,
            averageHeartRate: 82,
            atHome: true,
            waterLockEnabled: true,
            observedBehavior: .housework
        )
        let samples = (0..<3).map { index in
            WatchActivityPatternSample(
                capturedAt: makeDate(2026, 8, 6 + index, 7),
                pattern: pattern,
                label: .showering
            )
        }

        let learned = try XCTUnwrap(
            WatchActivityPersonalizationEngine.learnedBehavior(
                for: pattern,
                samples: samples
            )
        )
        XCTAssertEqual(learned.kind, .showering)
        XCTAssertGreaterThanOrEqual(learned.confidenceScore, 0.8)
        XCTAssertTrue(learned.evidence.first?.contains("3회") == true)
    }

    func testWatchConfirmationUsesOnlyPredefinedActivities() {
        let choices = WatchBehaviorKind.confirmationChoices

        XCTAssertFalse(choices.isEmpty)
        XCTAssertFalse(choices.contains(.unknown))
        XCTAssertEqual(Set(choices).count, choices.count)
        XCTAssertTrue(choices.contains(.showering))
        XCTAssertTrue(choices.contains(.housework))
    }

    func testCatFrameClocksSupportWatchSizedIntOverflowDates() {
        let currentEra = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let phases = 0...(TaptionCatAnimationEngine.phaseCount - 1)

        XCTAssertTrue(
            phases.contains(
                TaptionCatAnimationEngine.pose(at: currentEra).phase
            )
        )
        XCTAssertTrue(
            phases.contains(
                TaptionWidgetCatWalkEngine.pose(at: currentEra).legPhase
            )
        )
        XCTAssertTrue(
            phases.contains(
                TaptionWidgetCatPreviewEngine.pose(
                    at: currentEra,
                    action: .walking
                ).legPhase
            )
        )
    }

    func testRecentWatchContactOverridesTransientInstallationFlag() {
        let now = makeDate(2026, 8, 9, 22, 0)
        XCTAssertEqual(
            AppleWatchConnectionPolicy.state(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: false,
                isReachable: false,
                lastContactAt: now.addingTimeInterval(-60),
                now: now
            ),
            .background
        )
        XCTAssertEqual(
            AppleWatchConnectionPolicy.state(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: false,
                isReachable: false,
                lastContactAt: now.addingTimeInterval(-31 * 60),
                now: now
            ),
            .appNotInstalled
        )
    }

    func testStationaryContextUsesWatchRawMotionForPlaceDetails() {
        let start = makeDate(2026, 8, 4, 10, 0)
        let end = start.addingTimeInterval(2 * hour)
        let readings = [
            makeContextReading(at: start, flat: true),
            makeContextReading(at: start.addingTimeInterval(hour), flat: true),
            makeContextReading(at: start.addingTimeInterval(90 * 60), flat: true),
        ]
        let sessionID = UUID()
        let rawSamples = makeWatchRawSamples(
            start: start,
            sessionID: sessionID,
            count: 12
        )
        let typing = makeWatchSummary(
            start: start,
            duration: end.timeIntervalSince(start),
            sessionID: sessionID,
            behavior: .typing
        )

        let home = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(start: start, end: end),
                placeKind: .home,
                readings: readings,
                watchSummaries: [typing],
                watchAccelerationSamples: rawSamples,
                calendar: utcCalendar,
                now: end.addingTimeInterval(hour)
            )
        )
        XCTAssertEqual(home.kind, .housework)
        XCTAssertTrue(
            home.evidence.contains("집에서 Apple Watch 가속도·손목 움직임")
        )

        let company = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(start: start, end: end),
                placeKind: .company,
                readings: readings,
                watchSummaries: [typing],
                watchAccelerationSamples: rawSamples,
                calendar: utcCalendar,
                now: end.addingTimeInterval(hour)
            )
        )
        XCTAssertEqual(company.kind, .work)
        XCTAssertTrue(
            company.evidence.contains("회사에서 Apple Watch 타이핑 감지")
        )

        let restaurant = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(start: start, end: end),
                placeKind: .restaurant,
                readings: readings,
                watchSummaries: [
                    makeWatchSummary(
                        start: start,
                        duration: end.timeIntervalSince(start),
                        sessionID: sessionID,
                        behavior: .eating
                    )
                ],
                watchAccelerationSamples: rawSamples,
                calendar: utcCalendar,
                now: end.addingTimeInterval(hour)
            )
        )
        XCTAssertEqual(restaurant.kind, .mealPlace)
        XCTAssertTrue(
            restaurant.evidence.contains("식당에서 Apple Watch 식사 감지")
        )

        let summaryOnly = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(start: start, end: end),
                placeKind: .home,
                readings: readings,
                watchSummaries: [typing],
                calendar: utcCalendar,
                now: end.addingTimeInterval(hour)
            )
        )
        XCTAssertEqual(summaryOnly.kind, .homeRest)
    }

    func testWatchRawReplayRecomputesOnlyWhenRawChunkExists() {
        let start = makeDate(2026, 8, 4, 10, 0)
        let sessionID = UUID()
        let summary = makeWatchSummary(
            start: start,
            duration: 30,
            sessionID: sessionID,
            behavior: .automotive
        )
        let legacy = WatchActivityRawReplayEngine.replaying(
            summaries: [summary],
            chunks: []
        )
        XCTAssertEqual(legacy.first?.behavior, .automotive)
        XCTAssertEqual(
            legacy.first?.behaviorModelVersion,
            WatchBehaviorClassifier.rulesVersion
        )

        let samples = makeWatchRawSamples(
            start: start,
            sessionID: sessionID,
            count: 65
        )
        let chunk = TaptionWatchAccelerationChunk(
            sessionID: sessionID,
            sequence: 1,
            startedAt: start,
            endedAt: start.addingTimeInterval(30),
            samples: samples
        )
        let replayed = WatchActivityRawReplayEngine.replaying(
            summaries: [summary],
            chunks: [chunk]
        ).first

        XCTAssertEqual(
            replayed?.behaviorModelVersion,
            WatchActivityRawReplayEngine.modelVersion
        )
        XCTAssertTrue(replayed?.behaviorEvidence?.contains("Apple Watch raw 재생성") == true)
        XCTAssertTrue(
            WatchActivityRawReplayEngine.hasRawEvidence(
                for: summary,
                in: [chunk]
            )
        )
    }

    func testStationaryContextUsesWatchRawMotionForHomeHousework() {
        let start = makeDate(2026, 8, 8, 14, 0)
        let end = start.addingTimeInterval(hour)
        let inference = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(start: start, end: end),
                placeKind: .home,
                readings: [
                    makeContextReading(at: start, flat: true),
                    makeContextReading(
                        at: start.addingTimeInterval(20 * 60),
                        flat: true
                    ),
                    makeContextReading(
                        at: start.addingTimeInterval(40 * 60),
                        flat: true
                    ),
                ],
                watchAccelerationSamples: makeWatchRawSamples(
                    start: start,
                    values: [0, 0.08, 0, 0.08]
                ),
                calendar: utcCalendar,
                now: end
            )
        )

        XCTAssertEqual(inference.kind, .housework)
        XCTAssertTrue(
            inference.evidence.contains("집에서 Apple Watch 가속도·손목 움직임")
        )
    }

    func testStationaryContextAddsWatchEvidenceAtCompanyAndRestaurant() {
        let start = makeDate(2026, 8, 8, 14, 0)
        let end = start.addingTimeInterval(hour)
        let samples = makeWatchRawSamples(
            start: start,
            values: [0, 0.08, 0, 0.08]
        )
        let company = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(start: start, end: end),
                placeKind: .company,
                watchAccelerationSamples: samples,
                calendar: utcCalendar,
                now: end
            )
        )
        let restaurant = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(start: start, end: end),
                placeKind: .restaurant,
                watchAccelerationSamples: samples,
                calendar: utcCalendar,
                now: end
            )
        )

        XCTAssertEqual(company.kind, .work)
        XCTAssertTrue(
            company.evidence.contains("회사에서 Apple Watch 손목 활동")
        )
        XCTAssertEqual(restaurant.kind, .mealPlace)
        XCTAssertTrue(
            restaurant.evidence.contains("식당에서 Apple Watch 손목 활동")
        )
    }

    func testStationaryContextTravelWinsOverWatchFineDetail() {
        let start = makeDate(2026, 8, 8, 14, 0)
        let end = start.addingTimeInterval(hour)
        let travel = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: start.addingTimeInterval(20 * 60),
                end: start.addingTimeInterval(30 * 60)
            ),
            distanceMeters: 500,
            confidence: .medium,
            evidence: ["이동"]
        )
        let inference = StationaryContextClassifier().classify(
            StationaryContextInput(
                stay: makeContextStay(start: start, end: end),
                placeKind: .home,
                travel: [travel],
                watchAccelerationSamples: makeWatchRawSamples(
                    start: start,
                    values: [0, 0.08, 0, 0.08]
                ),
                calendar: utcCalendar,
                now: end
            )
        )

        XCTAssertNotEqual(inference.kind, .housework)
    }

    func testWatchWalkingWorkoutIsExerciseWithWalkingActivity() throws {
        let day = dayPhaseDay()
        let span = TimeSpan(
            start: day.start.addingTimeInterval(18 * hour),
            end: day.start.addingTimeInterval(19 * hour)
        )
        let workout = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "exercise",
            startedAt: span.start,
            endedAt: span.end,
            source: .appleWatch,
            behavior: WatchBehaviorKind.exercise.rawValue,
            evidence: [AutomaticRecordTimelineEngine.healthWorkoutEvidence]
        )
        let travel = TravelSegment(
            mode: .walking,
            span: span,
            distanceMeters: 5_600,
            confidence: .high,
            evidence: ["Apple Watch 운동 경로"]
        )

        let displayed = MovementDisplayEngine.reviewActuals(
            [workout],
            travel: [travel],
            asOf: day.end
        )
        let walking = try XCTUnwrap(
            displayed.first {
                ActualRecordCategoryResolver.categoryID(for: $0) == "movement"
            }
        )
        XCTAssertEqual(MovementPresentation.title(for: walking), "걷기")
        XCTAssertFalse(displayed.contains { $0.id == workout.id })

        let evidence = DayPhaseEvidenceEngine.records(
            from: [workout],
            intersecting: day,
            asOf: day.end
        )
        let phases = DayPhaseEngine.phases(
            actuals: evidence,
            travel: [travel],
            stays: [],
            placeKinds: [:],
            in: day,
            asOf: day.end
        )
        XCTAssertEqual(
            phases.filter { $0.phase == .exercise }.map(\.span),
            [span]
        )
    }

    func testDiagnosticsPackageIncludesIPhoneAndWatchLogs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let package = try TaptionPlanDiagnosticsLogPackageBuilder(
            packageDirectoryURL: root
        ).makePackage(
            summary: ["build": "47", "actuals": "12"],
            iphoneLog: "iphone-event",
            watchLog: "health snapshot ready workouts=2\nwatch-event"
        )
        let text = String(decoding: try gunzipLogForTest(Data(contentsOf: package)), as: UTF8.self)

        XCTAssertTrue(text.contains("## iphone_log"))
        XCTAssertTrue(text.contains("iphone-event"))
        XCTAssertTrue(text.contains("## apple_watch_log"))
        XCTAssertTrue(text.contains("watch-event"))
        XCTAssertFalse(text.contains("workouts=2"))
        XCTAssertTrue(text.contains("raw health values are excluded"))
    }

    func testTransitBoardingUsesAppleWatchRouteReadings() {
        let start = makeDate(2026, 8, 28, 15)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let station = TransitBoardingPlace(
            mapKitName: "서울역",
            kind: .trainStation,
            point: point
        )
        let watchReadings = [
            transitReading(
                at: start,
                point: point,
                sourceDevice: .appleWatch
            ),
            transitReading(
                at: start.addingTimeInterval(3 * 60),
                point: point,
                sourceDevice: .appleWatch
            ),
        ]

        XCTAssertTrue(
            TransitBoardingCandidateEngine.candidates(
                readings: watchReadings,
                registeredLocations: [],
                nearbyPlaces: [station]
            ).isEmpty
        )

        let candidates = TransitBoardingCandidateEngine.candidates(
            readings: watchReadings,
            registeredLocations: [],
            nearbyPlaces: [station],
            travel: [uncertainTransitTravel(at: start)]
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.source, .mapKit)
        XCTAssertEqual(candidates.first?.kind, .trainStation)

    let watchSummaryWithoutRoutePoint = SensorReading(
        timestamp: start,
        motion: .stationary,
        gpsAvailable: false,
        sourceDevice: .appleWatch
        )
        XCTAssertTrue(
            TransitBoardingCandidateEngine.candidates(
                readings: [watchSummaryWithoutRoutePoint],
                registeredLocations: [],
                nearbyPlaces: [station]
            ).isEmpty
        )
    }

}
