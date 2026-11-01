import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

extension FeatureEngineTests {
    func testHealthBackgroundRefreshCoalescesCallbackBursts() async {
        let coordinator = HealthBackgroundRefreshCoordinator()
        let counter = HealthRefreshCallCounter()
        await coordinator.register {
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(50))
            return true
        }

        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await coordinator.dispatchIfRegistered()
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let callCount = await counter.value

        XCTAssertEqual(results, Array(repeating: true, count: 8))
        XCTAssertEqual(callCount, 1)
    }

    func testAutomaticHealthAndSensorRecordsAreImmutable() {
        let start = makeDate(2026, 8, 1, 9)
        func record(_ source: ActualSource) -> ActualRecord {
            ActualRecord(
                planID: nil,
                title: "활동",
                categoryID: "activity",
                startedAt: start,
                endedAt: start.addingTimeInterval(hour),
                source: source
            )
        }

        XCTAssertTrue(
            AutomaticRecordTimelineEngine.isImmutable(record(.healthKit))
        )
        XCTAssertTrue(
            AutomaticRecordTimelineEngine.isImmutable(record(.appleWatch))
        )
        XCTAssertTrue(
            AutomaticRecordTimelineEngine.isImmutable(record(.location))
        )
        XCTAssertTrue(
            AutomaticRecordTimelineEngine.isImmutable(record(.motion))
        )
        XCTAssertTrue(
            AutomaticRecordTimelineEngine.isImmutable(record(.media))
        )
        XCTAssertTrue(
            AutomaticRecordTimelineEngine.isImmutable(record(.call))
        )
        XCTAssertFalse(
            AutomaticRecordTimelineEngine.isImmutable(record(.manual))
        )
        XCTAssertFalse(
            AutomaticRecordTimelineEngine.isImmutable(record(.timer))
        )
    }

    func testTravelPresentationSeparatesWorkoutWalkingColorClass() {
        let base = makeDate(2026, 8, 9, 18, 0)
        let walking = TravelSegment(
            mode: .walking,
            span: TimeSpan(
                start: base,
                end: base.addingTimeInterval(hour)
            ),
            distanceMeters: 4_800,
            confidence: .high,
            evidence: []
        )
        let workout = ActualRecord(
            planID: nil,
            title: "걷기 운동",
            categoryID: "exercise",
            startedAt: base.addingTimeInterval(10 * 60),
            endedAt: base.addingTimeInterval(55 * 60),
            source: .appleWatch,
            behavior: WatchBehaviorKind.walking.rawValue,
            evidence: [AutomaticRecordTimelineEngine.watchWorkoutEvidence],
            sensorChunkID: UUID()
        )
        let passive = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "movement",
            startedAt: walking.span.start,
            endedAt: walking.span.end,
            source: .motion,
            behavior: WatchBehaviorKind.walking.rawValue
        )

        XCTAssertTrue(
            TravelSegmentPresentationEngine.isWorkoutWalking(
                walking,
                actuals: [workout],
                asOf: base.addingTimeInterval(2 * hour)
            )
        )
        XCTAssertFalse(
            TravelSegmentPresentationEngine.isWorkoutWalking(
                walking,
                actuals: [passive],
                asOf: base.addingTimeInterval(2 * hour)
            )
        )
    }

    func testMovementRouteBuilderSkipsGapWithoutSensorOrHealthEvidence() {
        let start = makeDate(2026, 8, 18, 9)
        let stays = [
            PlaceStay(
                placeKey: "home",
                displayName: "집",
                span: TimeSpan(
                    start: start,
                    end: start.addingTimeInterval(30 * 60)
                ),
                confidence: .high
            ),
            PlaceStay(
                placeKey: "office",
                displayName: "회사",
                span: TimeSpan(
                    start: start.addingTimeInterval(60 * 60),
                    end: start.addingTimeInterval(90 * 60)
                ),
                confidence: .high
            ),
        ]

        XCTAssertTrue(
            MovementRouteBuilder().build(
                stays: stays,
                readings: []
            ).isEmpty
        )
    }

    func testHealthRefreshUsesFifteenMinuteFallbackAndImmediateBackgroundPolicy() {
        XCTAssertEqual(
            HealthRefreshPolicy.foregroundInterval,
            15 * 60
        )
        XCTAssertEqual(
            HealthRefreshPolicy.periodicLookback,
            2 * 86_400
        )
        XCTAssertEqual(
            HealthRefreshPolicy.backgroundFrequency,
            .immediate
        )
        XCTAssertEqual(HealthRefreshPolicy.backgroundFrequency(for: "HKQuantityTypeIdentifierHeartRate"), .hourly)
        XCTAssertEqual(HealthRefreshPolicy.backgroundFrequency(for: "HKQuantityTypeIdentifierStepCount"), .hourly)
        XCTAssertEqual(HealthRefreshPolicy.backgroundFrequency(for: "HKCategoryTypeIdentifierSleepAnalysis"), .immediate)
    }

    func testHealthKitRefreshReplacesOnlyHealthKitGroundTruthWindow() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(24 * hour)
        )
        let manual = ActualRecord(
            planID: nil,
            title: "직접 기록",
            categoryID: "exercise",
            startedAt: base,
            endedAt: base.addingTimeInterval(hour),
            source: .manual
        )
        let staleHealth = ActualRecord(
            planID: nil,
            title: "이전 Watch 기록",
            categoryID: "exercise",
            startedAt: base.addingTimeInterval(2 * hour),
            endedAt: base.addingTimeInterval(3 * hour),
            source: .healthKit
        )
        let freshHealth = ActualRecord(
            planID: nil,
            title: "새 Watch 기록",
            categoryID: "exercise",
            startedAt: base.addingTimeInterval(4 * hour),
            endedAt: base.addingTimeInterval(5 * hour),
            source: .healthKit
        )

        let result = AppleDeviceGroundTruthEngine
            .replacingHealthKitActuals(
                existing: [manual, staleHealth],
                with: [freshHealth, freshHealth],
                inside: span
            )

        XCTAssertTrue(result.contains(manual))
        XCTAssertFalse(result.contains(staleHealth))
        XCTAssertEqual(
            result.filter { $0.source == .healthKit },
            [freshHealth]
        )
    }

    func testWidgetFingerprintStaysStableWhileHealthActivityIsOpen() {
        let startedAt = makeDate(2026, 8, 1, 18, 0)
        var snapshot = TaptionDataSnapshot.empty
        snapshot.updatedAt = startedAt
        snapshot.actuals = [
            ActualRecord(
                planID: nil,
                title: "걷기",
                categoryID: "walking",
                startedAt: startedAt.addingTimeInterval(-10 * 60),
                source: .healthKit
            ),
        ]

        let first = TaptionWidgetPayloadFactory.make(
            from: snapshot,
            now: startedAt
        )
        let later = TaptionWidgetPayloadFactory.make(
            from: snapshot,
            now: startedAt.addingTimeInterval(5 * 60)
        )

        XCTAssertEqual(first.sourceFingerprint, later.sourceFingerprint)
        XCTAssertEqual(
            TaptionWidgetSyncStatus.compare(
                groundTruth: later,
                cached: first
            ),
            .synchronized(first.generatedAt)
        )

        var savedLater = later
        savedLater.sourceSnapshotUpdatedAt = startedAt.addingTimeInterval(1)
        XCTAssertEqual(
            TaptionWidgetSyncStatus.compare(
                groundTruth: savedLater,
                cached: first
            ),
            .pending
        )
    }

    @MainActor
    func testPermissionOnboardingRetriesMissingHealthOnce() {
        let defaults = UserDefaults.standard
        let onboardingKey = "taption.permission-onboarding.v1"
        let reminderKey = "taption.health-permission-reminder.v1"
        defaults.set(false, forKey: onboardingKey)
        defaults.set(false, forKey: reminderKey)
        defer {
            defaults.removeObject(forKey: onboardingKey)
            defaults.removeObject(forKey: reminderKey)
        }
        let model = AppModel(
            repository: InMemoryPlanRepository(),
            cloudSyncService: nil
        )

        model.presentPermissionOnboardingIfNeeded()
        XCTAssertTrue(model.isPermissionOnboardingPresented)
        XCTAssertNil(model.permissionOnboardingStartFeature)

        model.isPermissionOnboardingPresented = false
        defaults.set(true, forKey: onboardingKey)
        model.presentPermissionOnboardingIfNeeded()
        XCTAssertTrue(model.isPermissionOnboardingPresented)
        XCTAssertEqual(model.permissionOnboardingStartFeature, .health)

        model.isPermissionOnboardingPresented = false
        model.presentPermissionOnboardingIfNeeded()
        XCTAssertFalse(model.isPermissionOnboardingPresented)
    }

    func testDayPhaseWindowKeepsOvernightTitlesWorkoutAndOpenRecords() {
        let day = dayPhaseDay()
        let now = day.start.addingTimeInterval(14 * hour)
        let sleep = ActualRecord(
            planID: nil, title: "SLEEP", categoryID: "activity",
            startedAt: day.start.addingTimeInterval(-2 * hour),
            endedAt: day.start.addingTimeInterval(7 * hour), source: .healthKit
        )
        let app = ActualRecord(
            planID: nil, title: "취침 앱", categoryID: "appUsage",
            startedAt: day.start.addingTimeInterval(7 * hour),
            endedAt: day.start.addingTimeInterval(8 * hour), source: .appUsage
        )
        let workout = ActualRecord(
            planID: nil, title: "달리기", categoryID: "exercise",
            startedAt: day.start.addingTimeInterval(12 * hour),
            endedAt: day.start.addingTimeInterval(13 * hour), source: .appleWatch,
            evidence: [AutomaticRecordTimelineEngine.watchWorkoutEvidence]
        )
        let open = ActualRecord(
            planID: nil, title: "업무", categoryID: "work",
            startedAt: day.start.addingTimeInterval(13 * hour),
            source: .location, behavior: StationaryContextKind.work.rawValue
        )
        let future = sleepActual(15, 16, on: day)
        let records = [sleep, app, workout, open, future]
        let phases = DayPhaseEngine.completePhases(
            actuals: records, travel: [], stays: [], placeKinds: [:],
            in: day, asOf: now
        )
        XCTAssertEqual(phases.filter { $0.phase == .sleep }.map(\.span), [
            TimeSpan(start: day.start, end: sleep.endedAt!)
        ])
        XCTAssertEqual(phases.filter { $0.phase == .exercise }.map(\.span), [
            workout.span(asOf: now)
        ])
        XCTAssertEqual(phases.last?.phase, .work)
        XCTAssertEqual(phases.last?.span.end, now)
        XCTAssertEqual(phases.reduce(0) { $0 + $1.span.duration }, 14 * hour, accuracy: 0.001)
        XCTAssertEqual(records.last, future)
        XCTAssertNil(open.endedAt)
    }

    /// iPhone·Watch가 운동으로 확정한 시간은 업무·이동·수면보다 먼저
    /// 일과에 놓인다. 수동 계획이나 수동적 동작 추정은 운동으로 올리지 않는다.
    func testDayPhaseRingPrioritizesConfirmedWorkout() {
        let day = dayPhaseDay()
        let watchWorkout = ActualRecord(
            planID: nil,
            title: "달리기",
            categoryID: "activity",
            startedAt: day.start.addingTimeInterval(6.5 * hour),
            endedAt: day.start.addingTimeInterval(7.5 * hour),
            source: .appleWatch,
            behavior: WatchBehaviorKind.running.rawValue,
            evidence: [AutomaticRecordTimelineEngine.watchWorkoutEvidence],
            sensorChunkID: UUID()
        )
        let passiveMotion = ActualRecord(
            planID: nil,
            title: "운동",
            categoryID: "exercise",
            startedAt: day.start.addingTimeInterval(18 * hour),
            endedAt: day.start.addingTimeInterval(19 * hour),
            source: .motion
        )
        let iPhoneWorkout = ActualRecord(
            planID: nil,
            title: "근력 운동",
            categoryID: "exercise",
            startedAt: day.start.addingTimeInterval(12 * hour),
            endedAt: day.start.addingTimeInterval(13 * hour),
            source: .healthKit,
            behavior: WatchBehaviorKind.exercise.rawValue,
            evidence: [AutomaticRecordTimelineEngine.healthWorkoutEvidence]
        )
        let phases = DayPhaseEngine.phases(
            actuals: [
                sleepActual(0, 7, on: day),
                stationaryContext(.homeRest, 0, 6, on: day),
                stationaryContext(.work, 8, 18, on: day),
                watchWorkout,
                iPhoneWorkout,
                passiveMotion,
            ],
            travel: [travelLeg(.walking, 6, 8, on: day)],
            stays: [],
            placeKinds: [:],
            in: day,
            asOf: day.end
        )

        XCTAssertEqual(
            phases.map(\.phase),
            [.sleep, .exercise, .movement, .work, .exercise, .work]
        )
        XCTAssertEqual(
            phases.filter { $0.phase == .exercise }.map(\.span),
            [watchWorkout.span(asOf: day.end), iPhoneWorkout.span(asOf: day.end)]
        )
        XCTAssertFalse(
            phases.contains {
                $0.span.start == passiveMotion.startedAt
                    && $0.phase == .exercise
            }
        )
        assertPhasesPartitionTheDay(phases, in: day)
    }

    func testWalkingBelongsToMovementUnlessAWorkoutCoversIt() {
        let day = dayPhaseDay()
        let workoutSpan = TimeSpan(
            start: day.start.addingTimeInterval(10 * hour),
            end: day.start.addingTimeInterval(11 * hour)
        )
        let ordinarySpan = TimeSpan(
            start: day.start.addingTimeInterval(12 * hour),
            end: day.start.addingTimeInterval(13 * hour)
        )
        let workout = ActualRecord(
            planID: nil,
            title: "걷기 운동",
            categoryID: "exercise",
            startedAt: workoutSpan.start,
            endedAt: workoutSpan.end,
            source: .appleWatch,
            behavior: WatchBehaviorKind.walking.rawValue,
            evidence: [AutomaticRecordTimelineEngine.watchWorkoutEvidence]
        )
        let phases = DayPhaseEngine.phases(
            actuals: [workout],
            travel: [
                TravelSegment(
                    mode: .walking,
                    span: workoutSpan,
                    distanceMeters: 4_000,
                    confidence: .high,
                    evidence: ["Apple Watch 운동 경로"]
                ),
                TravelSegment(
                    mode: .walking,
                    span: ordinarySpan,
                    distanceMeters: 2_000,
                    confidence: .high,
                    evidence: ["iPhone Core Motion"]
                ),
            ],
            stays: [],
            placeKinds: [:],
            in: day,
            asOf: day.end
        )

        XCTAssertEqual(
            phases.first { $0.span.contains(workoutSpan.start) }?.phase,
            .exercise
        )
        XCTAssertEqual(
            phases.first { $0.span.contains(ordinarySpan.start) }?.phase,
            .movement
        )
    }

}
