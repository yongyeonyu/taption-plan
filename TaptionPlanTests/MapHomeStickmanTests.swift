import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

@MainActor
final class MapHomeStickmanTests: XCTestCase {
    func testMapActionLookupCostWithHalfMillionInactiveRecords() {
        let date = Date(timeIntervalSince1970: 1_791_250_000)
        let active = ActualRecord(
            planID: nil, title: "합성 활동", categoryID: "eating",
            startedAt: date.addingTimeInterval(-60), endedAt: date.addingTimeInterval(60),
            source: .motion
        )
        let history = (0..<524_953).map { index in
            let start = date.addingTimeInterval(-172_800 - Double(index) * 30)
            return ActualRecord(
                planID: nil, title: "합성 과거", categoryID: "activity",
                startedAt: start, endedAt: start.addingTimeInterval(20), source: .motion
            )
        }
        let full = history + [active]
        let day = [active]
        func lookup(_ actuals: [ActualRecord]) -> MapHomeStickmanAction {
            if MapHomeStickmanActionResolver.hasAppleWatchConfirmedSleep(
                at: date, actuals: actuals, sleepSessions: []
            ) { return .sleeping }
            return MapHomeStickmanActionResolver.action(
                at: date, actuals: actuals, travel: [], places: [], frequentPlaces: []
            )
        }
        XCTAssertEqual(lookup(full), .eating)
        XCTAssertEqual(lookup(day), .eating)
        for (label, records) in [("full_history", full), ("day_input", day)] {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<5 {
                for _ in 0..<8 { XCTAssertEqual(lookup(records), .eating) }
            }
            let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000 / 5
            print("MAP1006F01 \(label) records=\(records.count) eight_lookups_ms=\(milliseconds)")
        }
    }

    func testCurrentActionIgnoresLargeInactiveHistoryAndTracksChangedFields() {
        let date = Date(timeIntervalSince1970: 1_791_250_000)
        var active = ActualRecord(
            planID: nil, title: "식사", categoryID: "eating",
            startedAt: date.addingTimeInterval(-60), endedAt: date.addingTimeInterval(60),
            source: .manual
        )
        let history = (0..<120_000).map { index in
            let start = date.addingTimeInterval(Double(index) * 60 - 365 * 24 * 60 * 60)
            return ActualRecord(
                planID: nil, title: "합성 과거 수면", categoryID: "sleep",
                startedAt: start, endedAt: start.addingTimeInterval(30), source: .appleWatch
            )
        }
        let full = history + [active]
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<20 {
            XCTAssertEqual(MapHomeStickmanActionResolver.action(
                at: date, actuals: full, travel: [], places: [], frequentPlaces: []
            ), .eating)
        }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000 / 20
        print("PER1006B01 action records=\(full.count) mean_ms=\(milliseconds)")
        active.title = "업무"
        active.categoryID = "work"
        XCTAssertEqual(MapHomeStickmanActionResolver.action(
            at: date, actuals: history + [active], travel: [], places: [], frequentPlaces: []
        ), .computer)
    }

    func testDestinationActionsUseCompanySchoolAndRestaurantSemantics() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127.0,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5
        )
        let company = FrequentPlace(
            kind: .company,
            name: "회사",
            point: point
        )
        let companyStay = PlaceStay(
            placeKey: company.stablePlaceKey,
            displayName: company.name,
            span: TimeSpan(start: start, end: start.addingTimeInterval(30 * 60)),
            confidence: .high,
            point: point,
            isConfirmed: true
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(10 * 60),
                actuals: [],
                travel: [],
                places: [companyStay],
                frequentPlaces: [company]
            ),
            .company
        )
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "work", label: "업무"), .computer)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "work", label: "회사"), .company)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "company", label: "Work"), .company)

        let school = FrequentPlace(kind: .school, name: "학교", point: point)
        let schoolStay = PlaceStay(
            placeKey: school.stablePlaceKey,
            displayName: school.name,
            span: TimeSpan(start: start, end: start.addingTimeInterval(30 * 60)),
            confidence: .high,
            point: point,
            isConfirmed: true
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(10 * 60),
                actuals: [],
                travel: [],
                places: [schoolStay],
                frequentPlaces: [school]
            ),
            .school
        )
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "study", label: "수업"), .reading)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "study", label: "학교"), .school)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: "school", label: "Study"), .school)

        let restaurant = FrequentPlace(
            kind: .restaurant,
            name: "식당",
            point: point
        )
        let restaurantStay = PlaceStay(
            placeKey: restaurant.stablePlaceKey,
            displayName: restaurant.name,
            span: TimeSpan(start: start, end: start.addingTimeInterval(30 * 60)),
            confidence: .high,
            point: point,
            isConfirmed: true
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(10 * 60),
                actuals: [],
                travel: [],
                places: [restaurantStay],
                frequentPlaces: [restaurant]
            ),
            .eating
        )
    }

    func testTravelAndActualActionsHaveDeterministicPriority() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let span = TimeSpan(start: start, end: start.addingTimeInterval(30 * 60))
        let subway = TravelSegment(
            mode: .subway,
            span: span,
            distanceMeters: 4_000,
            confidence: .high,
            evidence: []
        )
        let sleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: start,
            endedAt: span.end,
            source: .healthKit,
            behavior: "core"
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(10 * 60),
                actuals: [sleep],
                travel: [subway],
                places: [],
                frequentPlaces: []
            ),
            .subway
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(for: TravelMode.cycling),
            .cycling
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(for: TravelMode.car),
            .car
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(for: TravelMode.bus),
            .bus
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(10 * 60),
                actuals: [sleep],
                travel: [],
                places: [],
                frequentPlaces: []
            ),
            .sleeping
        )
    }

    func testAppleWatchConfirmedSleepOverridesTravelAndUsesSleepAction() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let twoHours = 2 * 60 * 60.0
        let span = TimeSpan(start: start, end: start.addingTimeInterval(twoHours))
        let session = SleepSession(
            id: UUID(),
            span: span,
            asleepDuration: twoHours,
            awakeDuration: 0,
            inBedDuration: twoHours,
            stageDurations: [.core: twoHours],
            sourceNames: ["HealthKit"],
            segments: [
                SleepSegment(
                    stage: .core,
                    span: span,
                    sourceName: "HealthKit",
                    deviceName: "Apple Watch"
                )
            ]
        )
        let subway = TravelSegment(
            mode: .subway,
            span: span,
            distanceMeters: 4_000,
            confidence: .high,
            evidence: []
        )

        XCTAssertTrue(session.isAppleWatchConfirmed)
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(30 * 60),
                actuals: [],
                travel: [subway],
                places: [],
                frequentPlaces: [],
                sleepSessions: [session]
            ),
            .sleeping
        )

        let healthKitSleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: span.start,
            endedAt: span.end,
            source: .healthKit
        )
        let normalized = SleepActualReconciliationEngine.applying(
            [healthKitSleep],
            sessions: [session],
            inside: span,
            asOf: span.end
        )
        XCTAssertEqual(normalized.first?.source, .appleWatch)
    }

    // CAT1029A01: 수면 시간의 대분류는 수면이다. 자동 이동은 지우고, 재생도 정지 배속으로 지나간다.
    private func watchSleepSession(_ span: TimeSpan) -> SleepSession {
        SleepSession(
            id: UUID(), span: span, asleepDuration: span.duration, awakeDuration: 0,
            inBedDuration: span.duration, stageDurations: [.core: span.duration],
            sourceNames: ["Apple Watch"], segments: []
        )
    }

    func testWatchSleepRemovesCoveredAutomaticTravelButKeepsConfirmedAndOutsideTravel() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let hour = 60 * 60.0
        let night = TimeSpan(start: start, end: start.addingTimeInterval(7 * hour))
        let covered = TravelSegment(
            mode: .subway, span: TimeSpan(start: start.addingTimeInterval(2 * hour), end: start.addingTimeInterval(3 * hour)),
            distanceMeters: 4_000, confidence: .high, evidence: [], isClassificationLocked: true
        )
        let confirmed = TravelSegment(
            mode: .subway, span: covered.span, distanceMeters: 4_000, confidence: .high,
            evidence: [], isConfirmed: true
        )
        // 잠들기 직전 귀가: 대부분이 수면 밖이라 남는다.
        let walkHome = TravelSegment(
            mode: .walking, span: TimeSpan(start: start.addingTimeInterval(-50 * 60), end: start.addingTimeInterval(10 * 60)),
            distanceMeters: 900, confidence: .high, evidence: []
        )

        let result = SleepTravelReconciliationEngine.removingAutomaticTravel(
            [walkHome, covered, confirmed],
            sessions: [watchSleepSession(night)],
            inside: TimeSpan(start: start.addingTimeInterval(-hour), end: start.addingTimeInterval(8 * hour)),
            asOf: start.addingTimeInterval(8 * hour)
        )

        XCTAssertEqual(result.map(\.id), [walkHome.id, confirmed.id])
    }

    func testWatchSleepTrimsAutomaticMovementRecords() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let night = TimeSpan(start: start, end: start.addingTimeInterval(6 * 60 * 60))
        let gapSubway = ActualRecord(
            planID: nil, title: "지하철", categoryID: "movement",
            startedAt: start.addingTimeInterval(60 * 60), endedAt: start.addingTimeInterval(2 * 60 * 60),
            source: .motion, modelVersion: TaptionActivityEngineAdapter.inferredGapModelVersion
        )

        let result = SleepActualReconciliationEngine.applying(
            [gapSubway], sessions: [watchSleepSession(night)], inside: night, asOf: night.end
        )

        XCTAssertEqual(result.map(\.categoryID), ["sleep"])
    }

    func testPlaybackSpeedFollowsSleepCategoryOverMovement() {
        let dayStart = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let sleep = ActualRecord(
            planID: nil, title: "수면", categoryID: "sleep",
            startedAt: dayStart.addingTimeInterval(60 * 60), endedAt: dayStart.addingTimeInterval(5 * 60 * 60),
            source: .appleWatch
        )
        let snapshot = PlanDayDataSnapshot(
            day: dayStart, sourceRevision: 1, sourceUpdatedAt: dayStart,
            actuals: [sleep], places: [], travel: [], readings: [], isComplete: true
        )

        let ranges = MapHomePlaybackCategoryRanges.removingSleep(
            [MapHomePlaybackMovementRange(startMinute: 30, endMinute: 400, mode: .subway)],
            snapshot: snapshot, dayStart: dayStart
        )

        XCTAssertEqual(ranges.map(\.startMinute), [30, 300])
        XCTAssertEqual(ranges.map(\.endMinute), [60, 400])
    }

    // CAT1029A02: 센서 원본 열은 대분류가 아니라 HealthKit·iPhone 모션·GPS 원본으로 선다.
    func testSensorEvidenceLaneUsesHealthKitSleepThenIPhoneMotionAndGPSSpeed() {
        let dayStart = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func at(_ minute: Int) -> Date { dayStart.addingTimeInterval(Double(minute) * 60) }
        let still = stride(from: 60, through: 475, by: 5).map {
            SensorReading(timestamp: at($0), motion: .stationary)
        }
        // 자차 출근: 모션은 모름이어도 GPS 속도가 차량을 말한다.
        let drive = (550...607).map {
            SensorReading(timestamp: at($0), speedMetersPerSecond: 15, motion: .unknown)
        }
        let sleep = watchSleepSession(TimeSpan(start: at(90), end: at(440)))

        let lane = MapHomeNLESensorEvidence.segments(
            readings: still + drive, sleepSessions: [sleep], healthActuals: [],
            dayStart: dayStart, now: at(1_000)
        )

        XCTAssertEqual(lane.map(\.title), ["정지 · iPhone", "수면 · HealthKit", "정지 · iPhone", "차량 · GPS 속도"])
        XCTAssertEqual(lane.map(\.startMinute), [60, 90, 440, 550])
        XCTAssertEqual(lane.map(\.endMinute), [90, 440, 485, 608])
    }

    /// 센서 원본 열은 움직임·헬스·화면·연결·장소 다섯 줄로 갈라 서서, 한 분에 값이 여럿이어도 서로 가리지 않는다(UIX1031A17).
    func testSensorEvidenceChannelsKeepScreenNetworkPlaceAndHealthSeparate() {
        let dayStart = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func at(_ minute: Int) -> Date { dayStart.addingTimeInterval(Double(minute) * 60) }
        let readings: [SensorReading] = (600...620).map { minute in
            var reading = SensorReading(timestamp: at(minute), motion: .walking)
            reading.screenIsOn = true
            reading.connectedWiFiSSID = "HomeWiFi"
            reading.nearbyStationName = "강남"
            reading.watchWorkoutKind = "running"
            reading.stepCount = 1_000 + minute
            return reading
        }
        let sleep = watchSleepSession(TimeSpan(start: at(0), end: at(300)))
        let segments = MapHomeNLESensorEvidence.channelSegments(
            readings: readings, sleepSessions: [sleep], healthActuals: [], dayStart: dayStart, now: at(1_000)
        )
        func titles(_ channel: MapHomeNLESensorChannel) -> [String] {
            segments.filter { $0.channel == channel }.map(\.title)
        }
        XCTAssertEqual(titles(.motion), ["걷기 · iPhone"])
        XCTAssertEqual(titles(.screen), ["화면 켜짐"])
        XCTAssertEqual(titles(.network), ["Wi-Fi · HomeWiFi"])
        XCTAssertEqual(titles(.place), ["정류장 근처 · 강남"])
        XCTAssertEqual(titles(.health), ["수면 · HealthKit", "운동 running · 워치"])
        XCTAssertTrue(MapHomeNLESensorChannel.motion.isRestorable)
        XCTAssertFalse(MapHomeNLESensorChannel.screen.isRestorable)

        // 고른 분의 원본 값은 가장 가까운 측정값에서 풀어 쓴다. 10분을 넘게 떨어지면 없다.
        let near = MapHomeNLESensorEvidence.nearestReading(atMinute: 610, in: readings, dayStart: dayStart)
        XCTAssertEqual(near?.timestamp, at(610))
        XCTAssertNil(MapHomeNLESensorEvidence.nearestReading(atMinute: 700, in: readings, dayStart: dayStart))
        let lines = MapHomeNLESensorEvidence.rawLines(for: readings[10], language: .korean)
        XCTAssertTrue(lines.contains("걸음 1,610"))
        XCTAssertTrue(lines.contains("Wi-Fi HomeWiFi"))
        XCTAssertTrue(lines.contains("가까운 정류장 강남"))
        XCTAssertTrue(lines.contains("워치 운동 running"))
    }

    func testLegacyWatchSleepBehaviorStillOverridesTravel() {
        let start = Date(timeIntervalSinceReferenceDate: 800_050_000)
        let span = TimeSpan(
            start: start,
            end: start.addingTimeInterval(2 * 60 * 60)
        )
        let legacyWatchSleep = ActualRecord(
            planID: nil,
            title: "활동",
            categoryID: "activity",
            startedAt: span.start,
            endedAt: span.end,
            source: .appleWatch,
            behavior: WatchBehaviorKind.sleep.rawValue
        )
        let subway = TravelSegment(
            mode: .subway,
            span: span,
            distanceMeters: 4_000,
            confidence: .high,
            evidence: []
        )

        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(30 * 60),
                actuals: [legacyWatchSleep],
                travel: [subway],
                places: [],
                frequentPlaces: []
            ),
            .sleeping
        )
    }

    func testAppleWatchMajorActivityOverridesInferredIPhoneMovement() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let span = TimeSpan(
            start: start,
            end: start.addingTimeInterval(30 * 60)
        )
        let watchActivity = ActualRecord(
            planID: nil,
            title: "운동",
            categoryID: "activity",
            startedAt: span.start,
            endedAt: span.end,
            source: .appleWatch,
            behavior: WatchBehaviorKind.exercise.rawValue
        )
        let inferredCar = SensorReading(
            timestamp: start.addingTimeInterval(10 * 60),
            motion: .automotive,
            motionConfidence: .high
        )

        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(10 * 60),
                actuals: [watchActivity],
                travel: [],
                places: [],
                frequentPlaces: [],
                readings: [inferredCar]
            ),
            .activity
        )
    }

    func testMajorCategoryControlsStickmanInsteadOfDetailedActivity() {
        let start = Date(timeIntervalSinceReferenceDate: 800_100_000)
        let detailActivity = ActualRecord(
            planID: nil,
            title: "업무",
            categoryID: "activity",
            startedAt: start,
            endedAt: start.addingTimeInterval(30 * 60),
            source: .timer,
            behavior: "computer"
        )

        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(10 * 60),
                actuals: [detailActivity],
                travel: [],
                places: [],
                frequentPlaces: []
            ),
            .activity
        )
    }

    func testIPhoneOnlySleepDoesNotClaimAppleWatchPriority() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let twoHours = 2 * 60 * 60.0
        let span = TimeSpan(start: start, end: start.addingTimeInterval(twoHours))
        let session = SleepSession(
            id: UUID(),
            span: span,
            asleepDuration: twoHours,
            awakeDuration: 0,
            inBedDuration: twoHours,
            stageDurations: [.asleepUnspecified: twoHours],
            sourceNames: ["iPhone"],
            segments: []
        )
        let walking = TravelSegment(
            mode: .walking,
            span: span,
            distanceMeters: 500,
            confidence: .high,
            evidence: []
        )

        XCTAssertFalse(session.isAppleWatchConfirmed)
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                at: start.addingTimeInterval(30 * 60),
                actuals: [],
                travel: [walking],
                places: [],
                frequentPlaces: [],
                sleepSessions: [session]
            ),
            .walking
        )
    }

    func testAnimationPhaseIsStableAndReduceMotionFreezesIt() {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let next = date.addingTimeInterval(MapHomeStickmanAnimationEngine.frameDuration)
        XCTAssertNotEqual(
            MapHomeStickmanAnimationEngine.phase(at: date),
            MapHomeStickmanAnimationEngine.phase(at: next)
        )
        XCTAssertEqual(
            MapHomeStickmanAnimationEngine.phase(at: next, reducesMotion: true),
            0
        )
        XCTAssertEqual(
            MapHomeStickmanAnimationEngine.oscillation(for: 0),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(MapHomeStickmanAnimationEngine.phaseCount, 24)
        XCTAssertEqual(
            MapHomeStickmanAnimationEngine.frameDuration,
            1.0 / 12.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(MapHomeStickmanAnimationEngine.phase(for: 0), 0)
        XCTAssertEqual(MapHomeStickmanAnimationEngine.phase(for: 0.5), 12)
        XCTAssertEqual(MapHomeStickmanAnimationEngine.phase(for: 1), 23)
    }

    func testOnlyMovementStickmanActionsAnimate() {
        XCTAssertEqual(
            Set(MapHomeStickmanAction.allCases.filter(\.isMoving)),
            [.movement, .walking, .running, .car, .subway, .privateVehicle,
             .bus, .ship, .airplane, .cycling]
        )
    }

    func testObjectOnlyActivityMarkersAnimateTheirProps() {
        let actions: [MapHomeStickmanAction] = [.computer, .eating, .reading, .hobby]
        XCTAssertTrue(actions.allSatisfy(\.animatesPresentation))
        XCTAssertTrue(actions.allSatisfy { !$0.isMoving })
        XCTAssertTrue(MapHomeStickmanAction.sleeping.animatesPresentation)
    }

    func testEveryMajorCategoryHasItsOwnHwarangScene() {
        // 행동 분류마다 화랑이 장면이 전부 다르다(대표 지시, RIG1101A01).
        let majors = MapHomeSidebarMajorCategory.all.map(\.stickmanAction.hwarangScene)
        XCTAssertGreaterThanOrEqual(majors.count, 10)
        XCTAssertEqual(Set(majors).count, majors.count, "\(majors)")
        XCTAssertEqual(MapHomeSpeedTier.walking.scene, .walkLoop)
        XCTAssertEqual(MapHomeSpeedTier.running.scene, .runLoop)
    }

    func testHatIsDrawnOnTheHwarangHead() {
        let hat = "Hat_kr_gyeongbokgung"
        XCTAssertGreaterThan(
            HwarangDiagnostics.paintedPixels(scene: .walkLoop, sec: 1, hat: hat),
            HwarangDiagnostics.paintedPixels(scene: .walkLoop, sec: 1) + 100
        )
    }

    func testEveryHwarangSceneDrawsThroughItsWholeLoop() {
        for scene in HwarangScene.allCases {
            XCTAssertGreaterThan(scene.totalDuration, 0)
            var time = 0.0
            while time < Double(scene.totalDuration) + 1 {
                XCTAssertGreaterThan(HwarangDiagnostics.paintedPixels(scene: scene, sec: time), 500, "\(scene) \(time)")
                time += 0.73
            }
        }
    }

    func testStickmanFacingFollowsScreenDirectionAndHoldsWhenVertical() {
        XCTAssertFalse(MapHomeStickmanFacing.resolve(headingDegrees: 90, cameraHeading: 0, previous: true))
        XCTAssertTrue(MapHomeStickmanFacing.resolve(headingDegrees: 270, cameraHeading: 0, previous: false))
        // 지도가 돌아가 있으면 화면 기준으로 뒤집힌다.
        XCTAssertTrue(MapHomeStickmanFacing.resolve(headingDegrees: 90, cameraHeading: 180, previous: false))
        // 거의 위아래로 가면 이전 방향을 유지한다.
        XCTAssertTrue(MapHomeStickmanFacing.resolve(headingDegrees: 5, cameraHeading: 0, previous: true))
        XCTAssertFalse(MapHomeStickmanFacing.resolve(headingDegrees: 185, cameraHeading: 0, previous: false))
    }

    func testArticulatedStickmanPoseCoversEveryActionAndStaysOnCanvas() {
        for action in TaptionStickmanPoseAction.allCases {
            let poses = (0..<12).map {
                TaptionStickmanPoseEngine.pose(
                    action: action,
                    phase: $0,
                    phaseCount: 12
                )
            }
            for pose in poses {
                let points = [
                    pose.head,
                    pose.neck,
                    pose.leftShoulder,
                    pose.leftElbow,
                    pose.leftHand,
                    pose.rightShoulder,
                    pose.rightElbow,
                    pose.rightHand,
                    pose.leftHip,
                    pose.leftKnee,
                    pose.leftFoot,
                    pose.rightHip,
                    pose.rightKnee,
                    pose.rightFoot,
                ]
                XCTAssertTrue(
                    points.allSatisfy { (0...64).contains($0.x) && (0...56).contains($0.y) },
                    "\(action.rawValue) 관절이 64×56 좌표 밖으로 나갑니다."
                )
                XCTAssertGreaterThan(pose.headRadius, 0)
                XCTAssertNotEqual(pose.leftElbow, pose.leftHand)
                XCTAssertNotEqual(pose.rightElbow, pose.rightHand)
                XCTAssertNotEqual(pose.leftKnee, pose.leftFoot)
                XCTAssertNotEqual(pose.rightKnee, pose.rightFoot)
            }
            XCTAssertNotEqual(poses.first, poses[3], "\(action.rawValue) 관절이 움직이지 않습니다.")
        }
    }

    func testArticulatedStickmanPoseNormalizesMapAndLiveCadences() {
        for action in TaptionStickmanPoseAction.allCases {
            let mapPose = TaptionStickmanPoseEngine.pose(
                action: action,
                phase: 3,
                phaseCount: 12
            )
            let livePose = TaptionStickmanPoseEngine.pose(
                action: action,
                phase: 2,
                phaseCount: 8
            )
            XCTAssertEqual(mapPose, livePose, action.rawValue)
        }
        XCTAssertEqual(
            TaptionStickmanPoseEngine.normalizedPhase(-1, phaseCount: 12),
            11.0 / 12.0,
            accuracy: 0.000_001
        )
    }

    func testStickmanLocomotionUsesContactSwingFlightAndCounterPhase() {
        let walkContact = TaptionStickmanPoseEngine.pose(
            action: .walking,
            phase: 0,
            phaseCount: 12
        )
        let walkSwing = TaptionStickmanPoseEngine.pose(
            action: .walking,
            phase: 3,
            phaseCount: 12
        )
        let walkOppositeContact = TaptionStickmanPoseEngine.pose(
            action: .walking,
            phase: 6,
            phaseCount: 12
        )
        XCTAssertEqual(walkContact.leftFoot.y, 45, accuracy: 0.000_001)
        XCTAssertEqual(walkContact.rightFoot.y, 45, accuracy: 0.000_001)
        XCTAssertEqual(walkSwing.leftFoot.y, 45, accuracy: 0.000_001)
        XCTAssertLessThan(walkSwing.rightFoot.y, 45)
        XCTAssertEqual(walkOppositeContact.rightFoot.y, 45, accuracy: 0.000_001)
        XCTAssertGreaterThan(walkOppositeContact.leftFoot.x, walkContact.leftFoot.x)
        XCTAssertLessThan(walkOppositeContact.leftHand.x, walkContact.leftHand.x)

        let runningFlight = TaptionStickmanPoseEngine.pose(
            action: .running,
            phase: 4,
            phaseCount: 12
        )
        XCTAssertLessThan(runningFlight.leftFoot.y, 45)
        XCTAssertLessThan(runningFlight.rightFoot.y, 45)
    }

    func testStickmanLocomotionKeepsContactFeetPlanted() {
        let first = TaptionStickmanPoseEngine.pose(
            action: .walking,
            phase: 0,
            phaseCount: 12
        )
        let next = TaptionStickmanPoseEngine.pose(
            action: .walking,
            phase: 1,
            phaseCount: 12
        )

        XCTAssertLessThan(abs(next.leftFoot.x - first.leftFoot.x), 1.0)
        XCTAssertLessThan(abs(next.rightFoot.x - first.rightFoot.x), 1.0)
        XCTAssertEqual(next.leftFoot.y, 45, accuracy: 0.000_001)
        XCTAssertEqual(next.rightFoot.y, 45, accuracy: 0.000_001)
    }

    func testStickmanCyclingUsesOppositeCrankPositionsWithStablePelvis() {
        let first = TaptionStickmanPoseEngine.pose(
            action: .cycling,
            phase: 0,
            phaseCount: 12
        )
        let opposite = TaptionStickmanPoseEngine.pose(
            action: .cycling,
            phase: 6,
            phaseCount: 12
        )
        XCTAssertLessThan(first.leftFoot.y, first.rightFoot.y)
        XCTAssertGreaterThan(opposite.leftFoot.y, opposite.rightFoot.y)
        XCTAssertLessThan(abs(first.leftHip.y - opposite.leftHip.y), 0.5)
        XCTAssertLessThan(abs(first.rightHip.y - opposite.rightHip.y), 0.5)
    }

    func testStickmanWalkTransfersWeightAndOpposesArmSwing() {
        let leftSupport = TaptionStickmanPoseEngine.pose(
            action: .walking,
            phase: 3,
            phaseCount: 12
        )
        let rightSupport = TaptionStickmanPoseEngine.pose(
            action: .walking,
            phase: 9,
            phaseCount: 12
        )
        let leftSupportCenter =
            (leftSupport.leftHip.x + leftSupport.rightHip.x) / 2
        let rightSupportCenter =
            (rightSupport.leftHip.x + rightSupport.rightHip.x) / 2

        XCTAssertLessThan(leftSupportCenter, rightSupportCenter)
        XCTAssertLessThan(
            leftSupport.leftHip.y,
            leftSupport.rightHip.y
        )
        XCTAssertGreaterThan(
            leftSupport.rightHip.y,
            rightSupport.rightHip.y
        )

        let first = TaptionStickmanPoseEngine.pose(
            action: .walking,
            phase: 0,
            phaseCount: 12
        )
        let opposite = TaptionStickmanPoseEngine.pose(
            action: .walking,
            phase: 6,
            phaseCount: 12
        )
        XCTAssertGreaterThan(first.leftHand.x, opposite.leftHand.x)
    }

    func testStickmanTypingFramesProgressAndBlinkAtBothCadences() {
        let mapFrames = (0..<MapHomeStickmanAnimationEngine.phaseCount).map {
            TaptionStickmanTypingAnimation.frame(
                phase: $0,
                phaseCount: MapHomeStickmanAnimationEngine.phaseCount
            )
        }
        let liveFrames = (0..<TaptionLiveActivityStickmanAnimation.phaseCount).map {
            TaptionStickmanTypingAnimation.frame(
                phase: $0,
                phaseCount: TaptionLiveActivityStickmanAnimation.phaseCount
            )
        }

        for frames in [mapFrames, liveFrames] {
            XCTAssertEqual(frames.first?.lineUnits, [1, 0, 0])
            XCTAssertEqual(frames.last?.lineUnits, [5, 4, 3])
            let totals = frames.map { $0.lineUnits.reduce(0, +) }
            XCTAssertTrue(
                zip(totals, totals.dropFirst()).allSatisfy { pair in
                    pair.0 <= pair.1
                }
            )
            XCTAssertTrue(frames.contains { $0.cursorVisible })
            XCTAssertTrue(frames.contains { !$0.cursorVisible })
        }
        XCTAssertEqual(
            TaptionStickmanTypingAnimation.frame(
                phase: -1,
                phaseCount: MapHomeStickmanAnimationEngine.phaseCount
            ),
            mapFrames.last
        )
    }

    func testWalkingSceneryFramesWrapAndMatchMapAndLiveCadences() {
        let mapFrames = (0..<MapHomeStickmanAnimationEngine.phaseCount).map {
            TaptionStickmanWalkingSceneryAnimation.frame(
                phase: $0,
                phaseCount: MapHomeStickmanAnimationEngine.phaseCount
            )
        }
        let liveFrames = (0..<TaptionLiveActivityStickmanAnimation.phaseCount)
            .map {
                TaptionStickmanWalkingSceneryAnimation.frame(
                    phase: $0,
                    phaseCount: TaptionLiveActivityStickmanAnimation.phaseCount
                )
            }

        for frame in mapFrames + liveFrames {
            XCTAssertEqual(frame.treeX.count, 2)
            XCTAssertEqual(frame.cloudX.count, 2)
            XCTAssertTrue(frame.treeX.allSatisfy { (-12..<76).contains($0) })
            XCTAssertTrue(frame.cloudX.allSatisfy { (-12..<76).contains($0) })
            XCTAssertTrue((0..<8).contains(frame.groundOffset))
        }
        XCTAssertGreaterThan(
            abs(mapFrames[1].treeX[0] - mapFrames[0].treeX[0]),
            abs(mapFrames[1].cloudX[0] - mapFrames[0].cloudX[0])
        )
        let cloudStep = abs(
            mapFrames[1].cloudX[0] - mapFrames[0].cloudX[0]
        )
        for (last, first) in zip(
            mapFrames.last!.cloudX.sorted(),
            mapFrames.first!.cloudX.sorted()
        ) {
            XCTAssertEqual(abs(last - first), cloudStep, accuracy: 0.0001)
        }
        XCTAssertEqual(mapFrames, liveFrames)
        XCTAssertEqual(
            TaptionStickmanWalkingSceneryAnimation.frame(
                phase: -1,
                phaseCount: MapHomeStickmanAnimationEngine.phaseCount
            ),
            mapFrames.last
        )
    }

    func testMapStickmanResolvesMajorCategoryBeforeActivityDetail() {
        let majorCategories: [(String, String, MapHomeStickmanAction)] = [
            ("activity", "활동", .activity),
            ("work", "업무", .computer),
            ("work", "회사", .company),
            ("study", "수업", .reading),
            ("study", "학교", .school),
            ("hobby", "취미", .hobby),
            ("sleep", "수면", .sleeping),
            ("movement", "이동", .movement),
            ("eating", "식사", .eating),
            ("exercise", "운동", .exercise),
            ("unconfirmed", "미확인", .unconfirmed),
        ]
        let movementDetails = [
            "걷기", "달리기", "자동차", "지하철", "자가용",
            "버스", "배", "비행기", "자전거",
        ]

        for (categoryID, title, action) in majorCategories {
            XCTAssertEqual(
                MapHomeStickmanActionResolver.action(
                    for: categoryID,
                    label: title
                ),
                action,
                "\(categoryID) 대분류 동작이 다릅니다."
            )
        }
        for title in movementDetails {
            XCTAssertEqual(
                MapHomeStickmanActionResolver.action(
                    for: "movement",
                    label: title
                ),
                .movement,
                "\(title) 상세가 이동 대분류를 덮었습니다."
            )
        }
        XCTAssertEqual(MapHomeStickmanAction.allCases.count, 21)
        XCTAssertEqual(Set(MapHomeStickmanAction.allCases).count, 21)
        XCTAssertEqual(Set(MapHomeStickmanAction.allCases.map(\.title)).count, 21)
        XCTAssertEqual(MapHomeStickmanActionResolver.action(for: TravelMode.running), .running)
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                for: "activity",
                label: "업무"
            ),
            .activity
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                for: "activity",
                label: "미확인 동작"
            ),
            .activity
        )
        XCTAssertEqual(
            MapHomeStickmanActionResolver.action(
                for: "custom.user",
                label: "사용자 카테고리"
            ),
            .activity
        )
        XCTAssertNotEqual(
            MapHomeStickmanActionResolver.action(
                for: "hobby",
                label: "배드민턴"
            ),
            .ship
        )
        XCTAssertEqual(TaptionStickmanPoseEngine.wbsHeadRadius, 8.6)
        XCTAssertEqual(MapHomeStickmanMarker.size.width, 36)
        XCTAssertEqual(MapHomeStickmanMarker.size.height, 36)
    }

    func testLiveActivityStickmanResolvesEveryMajorCategory() {
        let expected: [(String, String, TaptionLiveActivityStickmanAction)] = [
            ("activity", "활동", .activity),
            ("work", "업무", .computer),
            ("study", "수업", .reading),
            ("hobby", "취미", .hobby),
            ("sleep", "수면", .sleeping),
            ("eating", "식사", .eating),
            ("movement", "이동", .movement),
            ("exercise", "운동", .exercise),
            ("unconfirmed", "미확인", .unconfirmed),
        ]

        for (categoryID, title, action) in expected {
            XCTAssertEqual(
                TaptionLiveActivityStickmanAction.resolve(
                    categoryID: categoryID,
                    title: title
                ),
                action,
                "\(categoryID) 대분류의 Dynamic Island 동작이 다릅니다."
            )
        }
        XCTAssertEqual(
            TaptionLiveActivityStickmanAction.resolve(
                categoryID: "movement",
                title: "걷기"
            ),
            .movement
        )
        let movementDetails = [
            "걷기", "달리기", "자동차", "지하철", "자가용",
            "버스", "배", "비행기", "자전거",
        ]
        for title in movementDetails {
            XCTAssertEqual(
                TaptionLiveActivityStickmanAction.resolve(
                    categoryID: "movement",
                    title: title
                ),
                .movement,
                "\(title) 상세가 Live Activity 이동 대분류를 덮었습니다."
            )
        }
        XCTAssertEqual(TaptionLiveActivityStickmanAction.allCases.count, 18)
        XCTAssertEqual(Set(TaptionLiveActivityStickmanAction.allCases).count, 18)
        XCTAssertEqual(
            TaptionLiveActivityStickmanAction.resolve(
                categoryID: "activity",
                title: "업무"
            ),
            .activity
        )
        XCTAssertEqual(
            TaptionLiveActivityStickmanAction.resolve(
                categoryID: "custom.user",
                title: "사용자 카테고리"
            ),
            .activity
        )
        XCTAssertNotEqual(
            TaptionLiveActivityStickmanAction.resolve(
                categoryID: "hobby",
                title: "배드민턴"
            ),
            .ship
        )
        XCTAssertEqual(TaptionLiveActivityStickmanStyle.inkHex, "#916446")
        XCTAssertEqual(TaptionLiveActivityStickmanStyle.headFillHex, "#B7B1A8")
        XCTAssertEqual(TaptionLiveActivityStickmanStyle.personStrokeWidth, 1.55)
    }

    func testLiveActivityStickmanAnimationHonorsReduceMotion() {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let next = date.addingTimeInterval(
            TaptionLiveActivityStickmanAnimation.frameDuration
        )
        XCTAssertNotEqual(
            TaptionLiveActivityStickmanAnimation.phase(at: date),
            TaptionLiveActivityStickmanAnimation.phase(at: next)
        )
        XCTAssertEqual(
            TaptionLiveActivityStickmanAnimation.phase(
                at: next,
                reducesMotion: true
            ),
            0
        )
        XCTAssertEqual(TaptionLiveActivityStickmanAnimation.frameCount, 24)
        XCTAssertEqual(
            TaptionLiveActivityStickmanAnimation.frameDuration,
            1.0 / 12.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(TaptionLiveActivityStickmanAnimation.phaseCount, 24)
        XCTAssertEqual(
            TaptionLiveActivityStickmanAnimation.frameIndex(
                at: 24 * (1.0 / 12.0),
                isAnimating: true
            ),
            0
        )
    }

    func testOnlyMovementLiveActivityStickmanActionsAnimate() {
        XCTAssertEqual(
            Set(TaptionLiveActivityStickmanAction.allCases.filter(\.isMoving)),
            [.movement, .walking, .running, .car, .subway, .privateVehicle,
             .bus, .ship, .airplane, .cycling]
        )
    }

    func testLiveActivityStickmanKeepsAllRawActionsAndUsesDeterministicSharedPoses() {
        let expectedRawValues = [
            "activity", "computer", "reading", "hobby", "sleeping",
            "movement", "eating", "exercise", "unconfirmed", "walking",
            "running", "car", "subway", "privateVehicle", "bus", "ship",
            "airplane", "cycling",
        ]
        XCTAssertEqual(
            TaptionLiveActivityStickmanAction.allCases.map(\.rawValue),
            expectedRawValues
        )

        for action in TaptionLiveActivityStickmanAction.allCases {
            let pose = TaptionStickmanPoseEngine.pose(
                action: TaptionStickmanPoseAction(rawValue: action.rawValue)!,
                phase: 7,
                phaseCount: TaptionLiveActivityStickmanAnimation.frameCount
            )
            XCTAssertEqual(
                pose,
                TaptionStickmanPoseEngine.pose(
                    action: TaptionStickmanPoseAction(rawValue: action.rawValue)!,
                    phase: 7,
                    phaseCount: TaptionLiveActivityStickmanAnimation.frameCount
                )
            )
            XCTAssertGreaterThan(pose.headRadius, 0)
        }
    }

    func testRegisteredCompanyClassificationCanReplaceUnknownStayLock() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let inside = TimeSpan(start: start, end: start.addingTimeInterval(60 * 60))
        let previous = ActualRecord(
            planID: nil,
            title: "머무름",
            categoryID: "activity",
            startedAt: start,
            endedAt: start.addingTimeInterval(30 * 60),
            source: .location,
            behavior: StationaryContextKind.unknownStay.rawValue,
            isClassificationLocked: true
        )
        let fresh = ActualRecord(
            planID: nil,
            title: "근무",
            categoryID: "work",
            startedAt: start.addingTimeInterval(60),
            endedAt: start.addingTimeInterval(31 * 60),
            source: .location,
            behavior: StationaryContextKind.work.rawValue,
            evidence: ["자주가는 곳: 회사", "평일 09–18시"]
        )

        let result = ActivityClassificationLockEngine.mergingLockedClassifications(
            existing: [previous],
            fresh: [fresh],
            inside: inside
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].categoryID, "work")
        XCTAssertEqual(result[0].title, "근무")
        XCTAssertEqual(result[0].behavior, StationaryContextKind.work.rawValue)
        XCTAssertTrue(result[0].isClassificationLocked)
    }

    func testMapMemoFilterShowsAllOrOnlySelectedScheduleAndTarget() {
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let planID = UUID()
        let planMemo = ActionMemo(
            planID: planID,
            mapPoint: point,
            kind: .idea,
            text: "일정 메모"
        )
        let placeMemo = ActionMemo(
            targetID: "place.target",
            mapPoint: point,
            kind: .decision,
            text: "장소 메모"
        )
        let timelineOnlyMemo = ActionMemo(
            kind: .nextAction,
            text: "타임라인 메모"
        )

        XCTAssertEqual(
            MapMemoDisplayFilterEngine.visibleMemos(
                [planMemo, placeMemo, timelineOnlyMemo],
                filter: .all,
                selectedPlanIDs: [],
                selectedTargetIDs: []
            ),
            [planMemo, placeMemo]
        )
        XCTAssertEqual(
            MapMemoDisplayFilterEngine.visibleMemos(
                [planMemo, placeMemo, timelineOnlyMemo],
                filter: .relevant,
                selectedPlanIDs: [planID],
                selectedTargetIDs: []
            ),
            [planMemo]
        )
        XCTAssertEqual(
            MapMemoDisplayFilterEngine.visibleMemos(
                [planMemo, placeMemo, timelineOnlyMemo],
                filter: .relevant,
                selectedPlanIDs: [],
                selectedTargetIDs: ["place.target"]
            ),
            [placeMemo]
        )
    }

    func testMapMemoFilterLimitsVisibleMemosToSelectedDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        let selectedDay = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 29, hour: 9)
        )!
        let sameDay = ActionMemo(
            occurredAt: selectedDay,
            mapPoint: point,
            kind: .idea,
            text: "오늘 지도 메모"
        )
        let otherDay = ActionMemo(
            occurredAt: calendar.date(
                from: DateComponents(year: 2026, month: 8, day: 30, hour: 9)
            )!,
            mapPoint: point,
            kind: .idea,
            text: "다음 날 지도 메모"
        )

        let visible = MapMemoDisplayFilterEngine.visibleMemos(
            [sameDay, otherDay],
            on: selectedDay,
            filter: .all,
            selectedPlanIDs: [],
            selectedTargetIDs: [],
            calendar: calendar
        )

        XCTAssertEqual(visible.map(\.id), [sameDay.id])
    }

    func testMapMemoFilterHonorsPlaybackCutoffButKeepsPlayheadMemo() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        let playhead = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 29, hour: 10)
        )!
        let before = ActionMemo(
            occurredAt: playhead.addingTimeInterval(-60),
            mapPoint: point,
            kind: .idea,
            text: "재생 전 메모"
        )
        let atPlayhead = ActionMemo(
            occurredAt: playhead,
            mapPoint: point,
            kind: .decision,
            text: "현재 시각 메모"
        )
        let after = ActionMemo(
            occurredAt: playhead.addingTimeInterval(60),
            mapPoint: point,
            kind: .nextAction,
            text: "아직 오지 않은 메모"
        )

        let visible = MapMemoDisplayFilterEngine.visibleMemos(
            [before, atPlayhead, after],
            on: playhead,
            filter: .all,
            selectedPlanIDs: [],
            selectedTargetIDs: [],
            calendar: calendar,
            through: playhead
        )

        XCTAssertEqual(visible.map(\.text), [before.text, atPlayhead.text])
    }

    @MainActor
    func testAddingMapMemoKeepsLocationTimeAndTimelineLink() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let planStart = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 29, hour: 9)
        )!
        let planEnd = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 29, hour: 10)
        )!
        let plan = PlanRecord(
            title: "현장 방문",
            span: TimeSpan(
                start: planStart,
                end: planEnd
            ),
            categoryID: "work"
        )
        var stored = TaptionDataSnapshot.empty
        stored.plans = [plan]
        let repository = InMemoryPlanRepository(snapshot: stored)
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil
        )
        await model.bootstrap()
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        let occurredAt = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 29, hour: 9, minute: 30)
        )!

        let id = try XCTUnwrap(
            model.addMapMemo(
                text: "입구가 동쪽",
                kind: .idea,
                mapPoint: point,
                planID: plan.id,
                occurredAt: occurredAt
            )
        )
        let memo = try XCTUnwrap(model.snapshot.memos.first { $0.id == id })

        XCTAssertEqual(memo.mapPoint, point)
        XCTAssertEqual(memo.occurredAt, occurredAt)
        XCTAssertEqual(memo.planID, plan.id)
        XCTAssertEqual(memo.categoryID, plan.categoryID)
        XCTAssertEqual(model.timelineMemos(in: plan.span).map(\.id), [id])

        let deadline = Date.now.addingTimeInterval(2)
        var persisted = try await repository.load()
        while persisted.memos.map(\.id) != [id], Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            persisted = try await repository.load()
        }
        XCTAssertEqual(persisted.memos.map(\.id), [id])
    }

    @MainActor
    func testAddingMapMemoAtPlanEndDoesNotLinkEndedPlan() async throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let plan = PlanRecord(
            title: "끝난 계획",
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(3_600)
            ),
            categoryID: "work"
        )
        var stored = TaptionDataSnapshot.empty
        stored.plans = [plan]
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: stored),
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()

        let id = try XCTUnwrap(
            model.addMapMemo(
                text: "계획 종료 뒤 메모",
                kind: .idea,
                mapPoint: GeoPoint(
                    latitude: 37.5,
                    longitude: 127,
                    altitude: 0,
                    horizontalAccuracy: 0,
                    verticalAccuracy: 0
                ),
                occurredAt: plan.span.end,
                shouldPersist: false
            )
        )
        let memo = try XCTUnwrap(
            model.snapshot.memos.first { $0.id == id }
        )

        XCTAssertNil(memo.planID)
        XCTAssertEqual(memo.categoryID, MemoTimelineEngine.categoryID)
        model.discardMapMemoDraft(id)
    }

    @MainActor
    func testEditingMapMemoReevaluatesPlanLinkAtNewTime() async throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let firstPlan = PlanRecord(
            title: "첫 계획",
            span: TimeSpan(
                start: start,
                end: start.addingTimeInterval(3_600)
            ),
            categoryID: "work"
        )
        let secondStart = start.addingTimeInterval(7_200)
        let secondPlan = PlanRecord(
            title: "두 번째 계획",
            span: TimeSpan(
                start: secondStart,
                end: secondStart.addingTimeInterval(3_600)
            ),
            categoryID: "exercise"
        )
        var stored = TaptionDataSnapshot.empty
        stored.plans = [firstPlan, secondPlan]
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: stored),
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()

        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        let memoID = try XCTUnwrap(
            model.addMapMemo(
                text: "시간 이동 메모",
                kind: .idea,
                mapPoint: point,
                planID: firstPlan.id,
                occurredAt: start.addingTimeInterval(1_800),
                shouldPersist: false
            )
        )

        XCTAssertTrue(
            model.updateMapMemo(
                memoID,
                text: "두 번째 계획으로 이동",
                kind: .decision,
                mapPoint: point,
                occurredAt: secondStart.addingTimeInterval(1_800)
            )
        )
        XCTAssertEqual(
            model.snapshot.memos.first { $0.id == memoID }?.planID,
            secondPlan.id
        )
        XCTAssertEqual(
            model.snapshot.memos.first { $0.id == memoID }?.categoryID,
            secondPlan.categoryID
        )

        XCTAssertTrue(
            model.updateMapMemo(
                memoID,
                text: "계획 종료 뒤 독립 메모",
                kind: .idea,
                mapPoint: point,
                occurredAt: secondPlan.span.end
            )
        )
        XCTAssertNil(model.snapshot.memos.first { $0.id == memoID }?.planID)
        XCTAssertEqual(
            model.snapshot.memos.first { $0.id == memoID }?.categoryID,
            MemoTimelineEngine.categoryID
        )
        model.discardMapMemoDraft(memoID)
    }

    func testMapMemoSaveRejectsInvalidGeometryAndDanglingPlanLink() async throws {
        let repository = InMemoryPlanRepository()
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil
        )
        await model.bootstrap()

        let invalidPoint = GeoPoint(
            latitude: .nan,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        XCTAssertNil(
            model.addMapMemo(
                text: "잘못된 좌표",
                kind: .idea,
                mapPoint: invalidPoint,
                occurredAt: .now
            )
        )
        XCTAssertTrue(model.snapshot.memos.isEmpty)

        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        let id = try XCTUnwrap(
            model.addMapMemo(
                text: "계획 연결 확인",
                kind: .idea,
                mapPoint: point,
                planID: UUID(),
                occurredAt: .now
            )
        )
        XCTAssertNil(model.snapshot.memos.first { $0.id == id }?.planID)
    }

    func testMapMemoDraftIsNotPersistedWhenDiscarded() async throws {
        let repository = InMemoryPlanRepository()
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil
        )
        await model.bootstrap()

        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        let draftID = try XCTUnwrap(
            model.addMapMemo(
                text: "임시 지도 메모",
                kind: .idea,
                mapPoint: point,
                occurredAt: .now,
                shouldPersist: false
            )
        )

        XCTAssertNotNil(model.snapshot.memos.first { $0.id == draftID })
        model.discardMapMemoDraft(draftID)

        XCTAssertNil(model.snapshot.memos.first { $0.id == draftID })
        let stored = try await repository.load()
        XCTAssertTrue(stored.memos.isEmpty)
    }

    @MainActor
    func testMapMemoDraftStaysOutOfConcurrentPersistence() async throws {
        let repository = InMemoryPlanRepository()
        let model = AppModel(
            repository: repository,
            cloudSyncService: nil,
            registersHealthBackgroundHandler: false
        )
        await model.bootstrap()

        let draftID = try XCTUnwrap(
            model.addMapMemo(
                text: "저장 전 지도 메모",
                kind: .idea,
                mapPoint: GeoPoint(
                    latitude: 37.5,
                    longitude: 127,
                    altitude: 0,
                    horizontalAccuracy: 0,
                    verticalAccuracy: 0
                ),
                occurredAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
                shouldPersist: false
            )
        )

        await model.setNotificationsEnabled(false)

        XCTAssertNotNil(model.snapshot.memos.first { $0.id == draftID })
        let stored = try await repository.load()
        XCTAssertTrue(stored.memos.isEmpty)
        model.discardMapMemoDraft(draftID)
    }

    func testActionMemoWithoutMapPointKeepsBackwardDecodingCompatibility() throws {
        let memo = ActionMemo(kind: .idea, text: "기존 메모")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(memo)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "mapPoint")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ActionMemo.self, from: data)

        XCTAssertEqual(decoded.text, memo.text)
        XCTAssertNil(decoded.mapPoint)
    }

    func testMapStickersAreLimitedToSelectedDayAndMapPlacement() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let point = GeoPoint(
            latitude: 37.5,
            longitude: 127,
            altitude: 0,
            horizontalAccuracy: 10,
            verticalAccuracy: 10
        )
        let selectedDay = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 29, hour: 9)
        )!
        let sameDay = MapSticker(
            title: "오늘",
            memo: "오늘 메모",
            placement: .map,
            point: point,
            occurredAt: selectedDay
        )
        let otherDay = MapSticker(
            title: "다음 날",
            placement: .map,
            point: point,
            occurredAt: calendar.date(
                from: DateComponents(year: 2026, month: 8, day: 30, hour: 9)
            )!
        )
        let schedule = MapSticker(
            title: "일정",
            placement: .schedule,
            occurredAt: selectedDay
        )

        let visible = MapStickerDisplayFilterEngine.visibleMapStickers(
            [sameDay, otherDay, schedule],
            on: selectedDay,
            calendar: calendar
        )

        XCTAssertEqual(visible.map(\.id), [sameDay.id])
        XCTAssertEqual(visible.first?.memo, "오늘 메모")
    }

    func testMapStickerMemoDecodesWhenMissingFromOlderArchive() throws {
        let sticker = MapSticker(
            title: "메모 스티커",
            memo: "현장 메모",
            placement: .map,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 0,
                verticalAccuracy: 0
            ),
            occurredAt: .now
        )
        let encoded = try JSONEncoder().encode(sticker)
        let decoded = try JSONDecoder().decode(MapSticker.self, from: encoded)
        XCTAssertEqual(decoded.memo, sticker.memo)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "memo")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(MapSticker.self, from: legacyData)
        XCTAssertNil(legacy.memo)
    }

    func testCloudMergeKeepsStickersAndHonorsStickerDeletionTombstone() {
        let localSticker = MapSticker(
            title: "로컬",
            placement: .map,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 127,
                altitude: 0,
                horizontalAccuracy: 0,
                verticalAccuracy: 0
            ),
            occurredAt: .now
        )
        let remoteSticker = MapSticker(
            title: "클라우드",
            placement: .schedule,
            occurredAt: .now
        )
        let deletedSticker = MapSticker(
            title: "삭제된 스티커",
            placement: .map,
            point: localSticker.point,
            occurredAt: .now
        )
        var local = TaptionDataSnapshot.empty
        local.stickers = [localSticker]
        local.settings.cloudDeletedRecordKeys = [
            CloudBackupRecordKey.sticker(deletedSticker.id)
        ]
        var remote = TaptionDataSnapshot.empty
        remote.stickers = [remoteSticker, deletedSticker]

        let merged = CloudSnapshotRecoveryEngine.merge(local: local, remote: remote)

        XCTAssertEqual(Set(merged.stickers.map(\.id)), [localSticker.id, remoteSticker.id])
        XCTAssertFalse(merged.stickers.contains(where: { $0.id == deletedSticker.id }))
    }
}
