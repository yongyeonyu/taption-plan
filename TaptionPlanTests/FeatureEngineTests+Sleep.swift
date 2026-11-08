import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

extension FeatureEngineTests {
    func testManualClassificationDoesNotHideConfirmedWorkoutOrSleep() {
        let day = TimeSpan(
            start: makeDate(2026, 8, 10),
            end: makeDate(2026, 8, 11)
        )
        let manual = ActualRecord(
            planID: nil,
            title: "샤워",
            categoryID: "activity",
            startedAt: day.start,
            endedAt: day.start.addingTimeInterval(3 * hour),
            source: .manual,
            manuallyCorrected: true
        )
        let workout = ActualRecord(
            planID: nil,
            title: "걷기 운동",
            categoryID: "exercise",
            startedAt: day.start.addingTimeInterval(hour),
            endedAt: day.start.addingTimeInterval(2 * hour),
            source: .appleWatch
        )
        let sleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: day.start.addingTimeInterval(2 * hour),
            endedAt: day.start.addingTimeInterval(3 * hour),
            source: .healthKit
        )

        let records = ReviewCoverageEngine.records(
            actuals: [manual, workout, sleep],
            in: [day],
            asOf: day.start.addingTimeInterval(3 * hour)
        )

        XCTAssertEqual(
            records.first(where: { $0.title == "걷기 운동" })?.span(
                asOf: day.end
            ).duration ?? 0,
            hour,
            accuracy: 0.001
        )
        XCTAssertEqual(
            records.first(where: { $0.title == "수면" })?.span(
                asOf: day.end
            ).duration ?? 0,
            hour,
            accuracy: 0.001
        )
        XCTAssertEqual(
            records.filter { $0.title == "샤워" }
                .reduce(0) { $0 + $1.span(asOf: day.end).duration },
            hour,
            accuracy: 0.001
        )
    }

    // MARK: - 수면과 겹친 휴식·생활

    /// 사용자 화면의 실제 값: 휴식 00:57 + 8시간 13분, 수면 02:43 + 4시간 50분.
    /// 수면이 휴식 한가운데 들어 있으므로 휴식은 앞뒤 두 조각만 남는다.
    func testSleepInsideRestLeavesTwoRestRemainders() {
        let day = makeDate(2026, 8, 5)
        let rest = makeActual(
            "집에서 휴식",
            "rest",
            start: makeDate(2026, 8, 5, 0, 57),
            minutes: 8 * 60 + 13,
            source: .location
        )
        let sleep = makeActual(
            "수면",
            "sleep",
            start: makeDate(2026, 8, 5, 2, 43),
            minutes: 4 * 60 + 50,
            source: .healthKit
        )
        let asOf = day.addingTimeInterval(24 * hour)

        let trimmed = RestSleepDisplayEngine.visibleActuals(
            [rest, sleep],
            asOf: asOf
        )
        let rests = trimmed.filter(RestSleepDisplayEngine.isRest)

        XCTAssertEqual(rests.count, 2)
        XCTAssertEqual(rests.map(\.startedAt), [
            makeDate(2026, 8, 5, 0, 57),
            makeDate(2026, 8, 5, 7, 33),
        ])
        XCTAssertEqual(rests.map(\.endedAt), [
            makeDate(2026, 8, 5, 2, 43),
            makeDate(2026, 8, 5, 9, 10),
        ])
        // 첫 조각이 원본 식별자를 지켜야 기록 상세가 열린다.
        XCTAssertEqual(rests.first?.id, rest.id)
        XCTAssertEqual(Set(rests.map(\.id)).count, 2)
        // 수면 기록 자체는 손대지 않는다.
        XCTAssertEqual(
            trimmed.filter { $0.categoryID == "sleep" }.map(\.id),
            [sleep.id]
        )
        // 다시 잘라도 같은 값이라야 화면 갱신마다 선택이 풀리지 않는다.
        XCTAssertEqual(
            RestSleepDisplayEngine.visibleActuals([rest, sleep], asOf: asOf),
            trimmed
        )
    }

    func testRestFullyInsideSleepDisappears() {
        let sleep = makeActual(
            "수면",
            "sleep",
            start: makeDate(2026, 8, 5, 1),
            minutes: 6 * 60,
            source: .healthKit
        )
        let rest = makeActual(
            "집에서 휴식",
            "rest",
            start: makeDate(2026, 8, 5, 2),
            minutes: 90,
            source: .location
        )
        let asOf = makeDate(2026, 8, 5, 12)

        XCTAssertTrue(restSpans([rest, sleep], asOf: asOf).isEmpty)
        XCTAssertEqual(
            RestSleepDisplayEngine.visibleActuals([rest, sleep], asOf: asOf)
                .map(\.id),
            [sleep.id]
        )
    }

    func testSleepCutsOverlappingLifeIntoVisibleRemainders() {
        let asOf = makeDate(2026, 8, 6, 12)
        let life = makeActual(
            "집안일",
            "activity",
            start: makeDate(2026, 8, 6, 0),
            minutes: 8 * 60,
            source: .location,
            behavior: StationaryContextKind.housework.rawValue
        )
        let sleep = makeActual(
            "수면",
            "sleep",
            start: makeDate(2026, 8, 6, 1),
            minutes: 5 * 60,
            source: .healthKit
        )

        XCTAssertEqual(
            routineSpans([life, sleep], asOf: asOf),
            [
                TimeSpan(
                    start: makeDate(2026, 8, 6, 0),
                    end: makeDate(2026, 8, 6, 1)
                ),
                TimeSpan(
                    start: makeDate(2026, 8, 6, 6),
                    end: makeDate(2026, 8, 6, 8)
                ),
            ]
        )

        let visible = RestSleepDisplayEngine.visibleActuals(
            [life, sleep],
            asOf: asOf
        )
        let groups = ActualRecordGroupingEngine.groups(
            actuals: visible,
            in: TimeSpan(
                start: makeDate(2026, 8, 6),
                end: makeDate(2026, 8, 7)
            ),
            categories: CategoryCatalog.builtIn,
            asOf: asOf
        )
        XCTAssertEqual(
            groups.first { $0.id == "routine" }?.duration,
            3 * hour
        )
        XCTAssertEqual(
            groups.first { $0.id == "sleep" }?.duration,
            5 * hour
        )
    }

    func testSleepReconciliationRemovesMisclassifiedActivityAndRestoresSession() {
        let start = makeDate(2026, 8, 6, 1)
        let session = SleepSession(
            id: UUID(),
            span: TimeSpan(start: start, end: start.addingTimeInterval(3 * hour)),
            asleepDuration: 3 * hour,
            awakeDuration: 0,
            inBedDuration: 3 * hour,
            stageDurations: [.asleepUnspecified: 3 * hour],
            sourceNames: ["Apple Watch"],
            segments: []
        )
        let activity = makeActual(
            "활동",
            "activity",
            start: start,
            minutes: 3 * 60,
            source: .motion,
            behavior: MotionKind.stationary.rawValue
        )
        let original = activity

        let result = SleepActualReconciliationEngine.applying(
            [activity],
            sessions: [session],
            inside: TimeSpan(
                start: makeDate(2026, 8, 6),
                end: makeDate(2026, 8, 7)
            ),
            asOf: makeDate(2026, 8, 6, 12)
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, session.id)
        XCTAssertEqual(result.first?.categoryID, "sleep")
        XCTAssertEqual(result.first?.source, .appleWatch)
        XCTAssertEqual(activity, original)
    }

    func testPartialSleepOverlapTrimsEachEdge() {
        let asOf = makeDate(2026, 8, 5, 23)
        let sleep = makeActual(
            "수면",
            "sleep",
            start: makeDate(2026, 8, 5, 1),
            minutes: 6 * 60,
            source: .healthKit
        )
        // 휴식이 수면보다 늦게 시작하고 늦게 끝난다: 뒤쪽만 남는다.
        let tail = makeActual(
            "집에서 휴식",
            "rest",
            start: makeDate(2026, 8, 5, 5),
            minutes: 4 * 60,
            source: .location
        )
        XCTAssertEqual(
            restSpans([tail, sleep], asOf: asOf),
            [TimeSpan(
                start: makeDate(2026, 8, 5, 7),
                end: makeDate(2026, 8, 5, 9)
            )]
        )

        // 휴식이 수면보다 먼저 시작하고 먼저 끝난다: 앞쪽만 남는다.
        let head = makeActual(
            "집에서 휴식",
            "rest",
            start: makeDate(2026, 8, 5, 0),
            minutes: 3 * 60,
            source: .location
        )
        let headRemainders = restSpans([head, sleep], asOf: asOf)
        XCTAssertEqual(
            headRemainders,
            [TimeSpan(
                start: makeDate(2026, 8, 5, 0),
                end: makeDate(2026, 8, 5, 1)
            )]
        )
        // 조각이 하나뿐이면 원본 식별자를 그대로 쓴다.
        XCTAssertEqual(
            RestSleepDisplayEngine.visibleActuals([head, sleep], asOf: asOf)
                .first?.id,
            head.id
        )
    }

    func testRestNotOverlappingSleepIsUntouched() {
        let asOf = makeDate(2026, 8, 5, 23)
        let sleep = makeActual(
            "수면",
            "sleep",
            start: makeDate(2026, 8, 5, 1),
            minutes: 6 * 60,
            source: .healthKit
        )
        let rest = makeActual(
            "카페",
            "rest",
            start: makeDate(2026, 8, 5, 14),
            minutes: 70,
            source: .location
        )
        let input = [rest, sleep]

        XCTAssertEqual(
            RestSleepDisplayEngine.visibleActuals(input, asOf: asOf),
            input
        )
        // 수면 기록이 없으면 휴식은 언제나 그대로다.
        XCTAssertEqual(
            RestSleepDisplayEngine.visibleActuals([rest], asOf: asOf),
            [rest]
        )
    }

    /// 근무·수업·통화·회의가 수면과 겹치면 감출 일이 아니라 따로 봐야 할
    /// 잘못이다. 수면 우선 규칙은 휴식·생활 분류에만 닿는다.
    func testSleepDoesNotSwallowWorkOrMeetingRecords() {
        let asOf = makeDate(2026, 8, 5, 23)
        let sleep = makeActual(
            "수면",
            "sleep",
            start: makeDate(2026, 8, 5, 1),
            minutes: 6 * 60,
            source: .healthKit
        )
        let others = [
            makeActual(
                "근무",
                "work",
                start: makeDate(2026, 8, 5, 2),
                minutes: 60,
                source: .location
            ),
            makeActual(
                "수업·학습",
                "study",
                start: makeDate(2026, 8, 5, 3),
                minutes: 60,
                source: .location
            ),
            makeActual(
                "통화",
                "relationship",
                start: makeDate(2026, 8, 5, 4),
                minutes: 20,
                source: .call
            ),
            makeActual(
                "머무름",
                "activity",
                start: makeDate(2026, 8, 5, 5),
                minutes: 30,
                source: .location
            ),
        ]

        XCTAssertEqual(
            RestSleepDisplayEngine.visibleActuals(others + [sleep], asOf: asOf),
            others + [sleep]
        )
    }

    /// 화면에 보이는 목록·눈금판·합계가 모두 같은 값을 읽는지 본다. 세 값이
    /// 흐른 시간(00:57–09:10)을 넘으면 안 된다.
    func testRecordTotalsForOverlappingRestAndSleepMatchElapsedTime() {
        let day = makeDate(2026, 8, 5)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))
        let asOf = day.addingTimeInterval(24 * hour)
        let raw = [
            makeActual(
                "집에서 휴식",
                "rest",
                start: makeDate(2026, 8, 5, 0, 57),
                minutes: 8 * 60 + 13,
                source: .location
            ),
            makeActual(
                "수면",
                "sleep",
                start: makeDate(2026, 8, 5, 2, 43),
                minutes: 4 * 60 + 50,
                source: .healthKit
            ),
        ]
        let elapsed = makeDate(2026, 8, 5, 9, 10)
            .timeIntervalSince(makeDate(2026, 8, 5, 0, 57))
        let expectedRest: TimeInterval = (1 * 60 + 46) * 60
            + (1 * 60 + 37) * 60
        let expectedSleep: TimeInterval = (4 * 60 + 50) * 60

        // 다듬기 전에는 두 값의 합이 흐른 시간을 넘는다.
        XCTAssertGreaterThan(
            ActualRecordGroupingEngine.groups(
                actuals: raw,
                in: span,
                categories: CategoryCatalog.builtIn,
                asOf: asOf
            ).reduce(0) { $0 + $1.duration },
            elapsed
        )

        let actuals = RestSleepDisplayEngine.visibleActuals(raw, asOf: asOf)
        let groups = ActualRecordGroupingEngine.groups(
            actuals: actuals,
            in: span,
            categories: CategoryCatalog.builtIn,
            asOf: asOf
        )
        let byCategory = Dictionary(
            groups.map { ($0.id, $0.duration) },
            uniquingKeysWith: { first, _ in first }
        )

        XCTAssertEqual(byCategory["sleep"], expectedSleep)
        XCTAssertEqual(byCategory["rest"], expectedRest)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.duration }, elapsed)

        // 잘린 두 조각은 제목이 같으므로 목록에서는 한 줄로 합쳐 보인다.
        let restGroup = groups.first { $0.id == "rest" }
        XCTAssertEqual(restGroup?.children.map(\.title), ["집에서 휴식"])
        XCTAssertEqual(restGroup?.children.first?.occurrenceCount, 2)
        XCTAssertEqual(
            restGroup?.children.first?.start,
            makeDate(2026, 8, 5, 0, 57)
        )

        // 눈금판(원형 시간표)도 같은 값을 읽는다.
        let rings = RecordChartEngine.clockRings(
            actuals: actuals,
            in: span,
            asOf: asOf
        )
        XCTAssertEqual(
            rings.first { $0.categoryID == "rest" }?.duration,
            expectedRest
        )
        XCTAssertEqual(
            rings.first { $0.categoryID == "rest" }?.arcs.count,
            2
        )
        XCTAssertEqual(
            rings.reduce(0) { $0 + $1.duration },
            groups.reduce(0) { $0 + $1.duration }
        )
    }

    func testAutomaticActivityIncludesSleepWorkoutAndWatchWithOverlapLanes() {
        let day = makeDate(2026, 8, 1)
        let sleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: day,
            endedAt: day.addingTimeInterval(8 * hour),
            source: .healthKit
        )
        let workout = ActualRecord(
            planID: nil,
            title: "러닝",
            categoryID: "exercise",
            startedAt: day.addingTimeInterval(7 * hour),
            endedAt: day.addingTimeInterval(9 * hour),
            source: .healthKit
        )
        let watch = ActualRecord(
            planID: nil,
            title: "Apple Watch 활동",
            categoryID: "health",
            startedAt: day.addingTimeInterval(10 * hour),
            endedAt: day.addingTimeInterval(11 * hour),
            source: .appleWatch
        )
        let manual = ActualRecord(
            planID: nil,
            title: "직접 기록",
            categoryID: "routine",
            startedAt: day.addingTimeInterval(12 * hour),
            endedAt: day.addingTimeInterval(13 * hour),
            source: .manual
        )
        let span = TimeSpan(
            start: day,
            end: day.addingTimeInterval(24 * hour)
        )

        let activities = AutomaticRecordTimelineEngine.activities(
            from: [manual, watch, workout, sleep],
            inside: span,
            asOf: span.end
        )
        XCTAssertEqual(activities.map(\.id), [sleep.id, workout.id, watch.id])

        let allocation = TimelineLaneAllocator.allocate(
            activities,
            span: { $0.span(asOf: span.end) }
        )
        XCTAssertEqual(allocation.count, 2)
        XCTAssertNotEqual(
            allocation.lanes[sleep.id],
            allocation.lanes[workout.id]
        )
        XCTAssertEqual(allocation.lanes[sleep.id], allocation.lanes[watch.id])
    }

    func testChargingInactivityBecomesSleepOnlyAfterOneHourWithoutWatch() {
        let start = makeDate(2026, 8, 9, 14, 0)
        let readings = (0...4).map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(index) * 15 * 60),
                motion: .stationary,
                motionConfidence: .high,
                stepCount: 0,
                powerState: .charging
            )
        }
        let span = TimeSpan(
            start: start,
            end: start.addingTimeInterval(2 * hour)
        )

        let records = ChargingInactivitySleepEngine.records(
            readings: readings,
            actuals: [],
            inside: span,
            watchAvailable: false,
            maximumSampleGap: 15 * 60,
            asOf: span.end
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.categoryID, "sleep")
        XCTAssertEqual(records.first?.span(asOf: span.end).duration, hour)

        XCTAssertTrue(
            ChargingInactivitySleepEngine.records(
                readings: Array(readings.prefix(4)),
                actuals: [],
                inside: span,
                watchAvailable: false,
                maximumSampleGap: 15 * 60,
                asOf: span.end
            ).isEmpty
        )
        XCTAssertTrue(
            ChargingInactivitySleepEngine.records(
                readings: readings,
                actuals: [],
                inside: span,
                watchAvailable: true,
                maximumSampleGap: 15 * 60,
                asOf: span.end
            ).isEmpty
        )
    }

    func testChargingInactivitySleepIsBlockedByAppUsage() {
        let start = makeDate(2026, 8, 9, 14, 0)
        let readings = (0...4).map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(index) * 15 * 60),
                motion: .stationary,
                stepCount: 0,
                powerState: .full
            )
        }
        let span = TimeSpan(
            start: start,
            end: start.addingTimeInterval(2 * hour)
        )
        let appUsage = ActualRecord(
            planID: nil,
            title: "앱 사용",
            categoryID: "appUsage",
            startedAt: start.addingTimeInterval(10 * 60),
            endedAt: start.addingTimeInterval(50 * 60),
            source: .appUsage
        )

        XCTAssertTrue(
            ChargingInactivitySleepEngine.records(
                readings: readings,
                actuals: [appUsage],
                inside: span,
                watchAvailable: false,
                maximumSampleGap: 15 * 60,
                asOf: span.end
            ).isEmpty
        )
    }

    func testPhoneSleepWakeRequiresDarkScreenAndConfirmsFromExpectedTime() {
        let start = makeDate(2026, 8, 9, 22, 0)
        let readings = (0...14).map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(index) * 5 * 60),
                motion: .stationary,
                motionConfidence: .high,
                stepCount: 0,
                powerState: .unplugged,
                screenBrightness: 0.1,
                screenIsOn: false
            )
        }
        let span = TimeSpan(start: start, end: start.addingTimeInterval(2 * hour))
        let records = PhoneSleepWakeEngine.records(
            readings: readings,
            actuals: [],
            inside: span,
            watchAvailable: false,
            maximumSampleGap: 20 * 60,
            asOf: span.end
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].startedAt, start.addingTimeInterval(5 * 60))
        XCTAssertEqual(records[0].endedAt, readings.last?.timestamp)

        let bright = readings.map {
            var value = $0
            value.screenBrightness = 0.8
            value.screenIsOn = true
            return value
        }
        XCTAssertTrue(
            PhoneSleepWakeEngine.records(
                readings: bright,
                actuals: [],
                inside: span,
                watchAvailable: false,
                maximumSampleGap: 20 * 60,
                asOf: span.end
            ).isEmpty
        )
    }

    func testPhoneSleepWakeAcceptsMissingDisplayTelemetryAfterInactivity() {
        let start = makeDate(2026, 8, 11, 22, 0)
        let readings = (0...14).map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(index) * 5 * 60),
                motion: .stationary,
                motionConfidence: .high,
                stepCount: 0,
                powerState: .full
            )
        }
        let span = TimeSpan(start: start, end: start.addingTimeInterval(2 * hour))

        let records = PhoneSleepWakeEngine.records(
            readings: readings,
            actuals: [],
            inside: span,
            watchAvailable: false,
            maximumSampleGap: 20 * 60,
            asOf: span.end
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].categoryID, "sleep")
        XCTAssertTrue(records[0].isClassificationLocked)
    }

    func testStrictSleepWithoutHomeUsesObservedDarkChargingRunOnly() {
        let start = makeDate(2026, 8, 11, 22, 0)
        var readings = (0...7).map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(index) * 5 * 60),
                motion: .stationary,
                motionConfidence: .high,
                stepCount: 0,
                powerState: .charging,
                screenBrightness: 0.1,
                screenIsOn: false
            )
        }
        readings.append(
            SensorReading(
                timestamp: start.addingTimeInterval(10 * hour),
                motion: .stationary,
                motionConfidence: .high,
                stepCount: 0,
                powerState: .charging,
                screenBrightness: 0.8,
                screenIsOn: true
            )
        )
        let span = TimeSpan(
            start: start,
            end: start.addingTimeInterval(12 * hour)
        )
        let records = TaptionActivityEngineAdapter.strictSleepActuals(
            readings: readings,
            actuals: [],
            inside: span,
            homePoint: nil,
            maximumSampleGap: 20 * 60,
            asOf: span.end
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].startedAt, start.addingTimeInterval(30 * 60))
        XCTAssertEqual(records[0].endedAt, start.addingTimeInterval(35 * 60))

        XCTAssertTrue(
            TaptionActivityEngineAdapter.strictSleepActuals(
                readings: readings.map {
                    var value = $0
                    value.screenBrightness = 0.8
                    value.screenIsOn = true
                    return value
                },
                actuals: [],
                inside: span,
                homePoint: nil,
                maximumSampleGap: 20 * 60,
                asOf: span.end
            ).isEmpty
        )
    }

    func testStrictSleepClosesCompletedRunWhenWakeSampleIsContinuous() {
        let start = makeDate(2026, 8, 12, 22, 0)
        var readings = (0...72).map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(index) * 5 * 60),
                motion: .stationary,
                motionConfidence: .high,
                stepCount: 0,
                powerState: .charging,
                screenBrightness: 0.1,
                screenIsOn: false
            )
        }
        readings.append(
            SensorReading(
                timestamp: start.addingTimeInterval(6 * hour + 5 * 60),
                motion: .walking,
                motionConfidence: .high,
                stepCount: 5,
                powerState: .unplugged,
                screenBrightness: 0.8,
                screenIsOn: true
            )
        )
        let span = TimeSpan(
            start: start,
            end: start.addingTimeInterval(8 * hour)
        )

        let records = TaptionActivityEngineAdapter.strictSleepActuals(
            readings: readings,
            actuals: [],
            inside: span,
            homePoint: nil,
            maximumSampleGap: 20 * 60,
            asOf: span.end
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].startedAt, start.addingTimeInterval(30 * 60))
        XCTAssertEqual(records[0].endedAt, start.addingTimeInterval(6 * hour))
    }

    func testPhoneSleepWakeChargingShortensConfirmationAndAwakeningCanResettle() {
        let start = makeDate(2026, 8, 10, 22, 0)
        var readings = (0...8).map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(index) * 5 * 60),
                motion: .stationary,
                motionConfidence: .high,
                stepCount: 0,
                powerState: .charging,
                screenBrightness: 0.1,
                screenIsOn: false
            )
        }
        let movementAt = start.addingTimeInterval(45 * 60)
        readings.append(
            SensorReading(
                timestamp: movementAt,
                motion: .walking,
                motionConfidence: .high,
                stepCount: 4,
                powerState: .charging,
                screenBrightness: 0.8,
                screenIsOn: true
            )
        )
        readings.append(
            SensorReading(
                timestamp: movementAt.addingTimeInterval(5 * 60),
                motion: .stationary,
                motionConfidence: .high,
                stepCount: 0,
                powerState: .charging,
                screenBrightness: 0.1,
                screenIsOn: false
            )
        )
        let span = TimeSpan(start: start, end: start.addingTimeInterval(2 * hour))
        let records = PhoneSleepWakeEngine.records(
            readings: readings,
            actuals: [],
            inside: span,
            watchAvailable: false,
            maximumSampleGap: 20 * 60,
            asOf: span.end
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].startedAt, start.addingTimeInterval(5 * 60))
    }

    func testPhoneSleepWakeConfirmsFastWhenScreenIsOnAndStepsRise() {
        let start = makeDate(2026, 8, 10, 22, 0)
        var readings = (0...16).map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(index) * 5 * 60),
                motion: .stationary, motionConfidence: .high, stepCount: 0,
                screenBrightness: 0.1, screenIsOn: false
            )
        }
        // 기상 후보가 생기고 20분 동안 화면이 켜진 채 걷는다(1시간 전이라도 확정되어야 한다).
        let wake = start.addingTimeInterval(95 * 60)
        for index in 0...5 {
            readings.append(SensorReading(
                timestamp: wake.addingTimeInterval(Double(index) * 5 * 60),
                motion: .walking, motionConfidence: .high, stepCount: index * 20,
                screenBrightness: 0.8, screenIsOn: true
            ))
        }
        let span = TimeSpan(start: start, end: start.addingTimeInterval(3 * hour))
        let records = PhoneSleepWakeEngine.records(
            readings: readings, actuals: [], inside: span, watchAvailable: false,
            maximumSampleGap: 20 * 60, asOf: span.end
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].endedAt, wake)
    }

    func testPhoneSleepWakeUsesDistinctStableIDsForDifferentSpans() {
        let start = makeDate(2026, 8, 10, 22, 0)
        func record(startedAt: Date) -> ActualRecord? {
            let readings = (0...14).map { index in
                SensorReading(
                    timestamp: startedAt.addingTimeInterval(
                        Double(index) * 5 * 60
                    ),
                    motion: .stationary,
                    stepCount: 0,
                    powerState: .charging,
                    screenBrightness: 0.1,
                    screenIsOn: false
                )
            }
            return PhoneSleepWakeEngine.records(
                readings: readings,
                actuals: [],
                inside: TimeSpan(
                    start: startedAt,
                    end: startedAt.addingTimeInterval(2 * hour)
                ),
                watchAvailable: false,
                maximumSampleGap: 20 * 60,
                asOf: startedAt.addingTimeInterval(2 * hour)
            ).first
        }

        let first = record(startedAt: start)
        let second = record(startedAt: start.addingTimeInterval(24 * hour))

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.id, second?.id)
    }

    func testPhoneSleepFallbackBridgesSparseChargingNight() {
        // 지역 시각 자정부터 본다. UTC 자정은 한국 시각 9~16시라 낮 창 규칙에 걸린다(ALG1102A01).
        let start = Calendar.autoupdatingCurrent.startOfDay(for: makeDate(2026, 8, 24, 12, 0))
        let readings = [0.0, 2, 4, 7].map { hourOffset in
            SensorReading(
                timestamp: start.addingTimeInterval(hourOffset * hour),
                motion: .stationary,
                motionConfidence: .high,
                stepCount: 0,
                powerState: .full,
                screenBrightness: 0.8,
                screenIsOn: true
            )
        }
        let span = TimeSpan(
            start: start,
            end: start.addingTimeInterval(8 * hour)
        )

        let records = PhoneSleepFusion.records(
            readings: readings,
            actuals: [],
            inside: span,
            nominalMaximumSampleGap: 20 * 60,
            asOf: span.end
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].startedAt, start)
        XCTAssertEqual(records[0].endedAt, start.addingTimeInterval(7 * hour))
        XCTAssertEqual(
            records[0].modelVersion,
            ChargingInactivitySleepEngine.modelVersion
        )
    }

    func testPhoneSleepFallbackUsesBackgroundSamplesWithoutScreenTelemetry() {
        let start = makeDate(2026, 8, 24, 22, 0)
        let readings = (0...4).map { index in
            SensorReading(
                timestamp: start.addingTimeInterval(Double(index) * 30 * 60),
                motion: .stationary,
                motionConfidence: .high,
                stepCount: 0,
                powerState: .full
            )
        }
        let span = TimeSpan(
            start: start,
            end: start.addingTimeInterval(2 * hour)
        )

        let records = PhoneSleepFusion.records(
            readings: readings,
            actuals: [],
            inside: span,
            nominalMaximumSampleGap: 20 * 60,
            asOf: span.end
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(
            records[0].startedAt,
            start.addingTimeInterval(5 * 60)
        )
        XCTAssertEqual(records[0].modelVersion, PhoneSleepWakeEngine.modelVersion)
    }

    func testPhoneSleepFallbackDoesNotDuplicateAuthoritativeSleep() {
        let start = makeDate(2026, 8, 24, 0, 0)
        let readings = [0.0, 2, 4, 7].map { hourOffset in
            SensorReading(
                timestamp: start.addingTimeInterval(hourOffset * hour),
                motion: .stationary,
                stepCount: 0,
                powerState: .charging,
                screenBrightness: 0.8,
                screenIsOn: true
            )
        }
        let span = TimeSpan(
            start: start,
            end: start.addingTimeInterval(8 * hour)
        )
        let healthSleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: start,
            endedAt: start.addingTimeInterval(7 * hour),
            source: .healthKit
        )

        XCTAssertTrue(
            PhoneSleepFusion.records(
                readings: readings,
                actuals: [healthSleep],
                inside: span,
                nominalMaximumSampleGap: 20 * 60,
                asOf: span.end
            ).isEmpty
        )
    }

    func testPhoneSleepFallbackIgnoresIPhoneHealthKitSession() {
        let start = makeDate(2026, 8, 24, 0, 0)
        let readings = [0.0, 2, 4, 7].map { hourOffset in
            SensorReading(
                timestamp: start.addingTimeInterval(hourOffset * hour),
                motion: .stationary,
                motionConfidence: .high,
                stepCount: 0,
                powerState: .full,
                screenBrightness: 0.8,
                screenIsOn: true
            )
        }
        let span = TimeSpan(
            start: start,
            end: start.addingTimeInterval(8 * hour)
        )
        let healthKitSession = TimeSpan(
            start: start,
            end: start.addingTimeInterval(7.25 * hour)
        )

        XCTAssertTrue(
            PhoneSleepFusion.records(
                readings: readings,
                actuals: [],
                inside: span,
                nominalMaximumSampleGap: 20 * 60,
                authoritativeSleepSpans: [healthKitSession],
                asOf: span.end
            ).isEmpty
        )
    }

    func testSleepAnalysisBuildsOneSessionWithoutDoubleCountingOverlaps() {
        let base = makeDate(2026, 7, 30, 22, 0)
        let segments = [
            SleepSegment(
                stage: .inBed,
                span: TimeSpan(start: base, end: base.addingTimeInterval(8.5 * hour)),
                sourceName: "iPhone"
            ),
            SleepSegment(
                stage: .core,
                span: TimeSpan(
                    start: base.addingTimeInterval(0.5 * hour),
                    end: base.addingTimeInterval(3 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .deep,
                span: TimeSpan(
                    start: base.addingTimeInterval(3 * hour),
                    end: base.addingTimeInterval(4 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .core,
                span: TimeSpan(
                    start: base.addingTimeInterval(4 * hour),
                    end: base.addingTimeInterval(6 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .rem,
                span: TimeSpan(
                    start: base.addingTimeInterval(6 * hour),
                    end: base.addingTimeInterval(7 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .awake,
                span: TimeSpan(
                    start: base.addingTimeInterval(7 * hour),
                    end: base.addingTimeInterval(7.25 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .rem,
                span: TimeSpan(
                    start: base.addingTimeInterval(7.25 * hour),
                    end: base.addingTimeInterval(8 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .asleepUnspecified,
                span: TimeSpan(
                    start: base.addingTimeInterval(0.5 * hour),
                    end: base.addingTimeInterval(8 * hour)
                ),
                sourceName: "iPhone"
            )
        ]

        let sessions = SleepAnalysisEngine().sessions(from: segments)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].asleepDuration, 7.25 * hour)
        XCTAssertEqual(sessions[0].awakeDuration, 0.25 * hour)
        XCTAssertEqual(sessions[0].inBedDuration, 8.5 * hour)
        XCTAssertEqual(sessions[0].stageDurations[.deep], hour)
        XCTAssertEqual(sessions[0].sourceNames, ["iPhone", "Apple Watch"])
        XCTAssertEqual(
            sessions[0].sleepEfficiency ?? 0,
            7.25 / 8.5,
            accuracy: 0.0001
        )
    }

    func testSleepAnalysisIncludesTrailingAwakeAsWakeBoundary() {
        let base = makeDate(2026, 8, 1, 23)
        let sessions = SleepAnalysisEngine().sessions(from: [
            SleepSegment(
                stage: .core,
                span: TimeSpan(
                    start: base,
                    end: base.addingTimeInterval(7 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .awake,
                span: TimeSpan(
                    start: base.addingTimeInterval(7 * hour),
                    end: base.addingTimeInterval(8.5 * hour)
                ),
                sourceName: "Apple Watch"
            )
        ])

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(
            sessions[0].span.end,
            base.addingTimeInterval(8.5 * hour)
        )
        XCTAssertEqual(sessions[0].asleepDuration, 7 * hour)
        XCTAssertEqual(sessions[0].awakeDuration, 1.5 * hour)
    }

    func testWatchSleepSegmentsBecomeAuthoritativeAppleWatchSleep() {
        let start = makeDate(2026, 8, 4, 23)
        let segments = [
            SleepSegment(
                stage: .core,
                span: TimeSpan(
                    start: start,
                    end: start.addingTimeInterval(7 * hour)
                ),
                sourceName: "Apple Watch"
            )
        ]
        let sessions = SleepAnalysisEngine().sessions(from: segments)
        let actuals = SleepActualReconciliationEngine.applying(
            [],
            sessions: sessions,
            inside: TimeSpan(
                start: start,
                end: start.addingTimeInterval(8 * hour)
            ),
            asOf: start.addingTimeInterval(8 * hour)
        )

        XCTAssertEqual(actuals.count, 1)
        XCTAssertEqual(actuals[0].source, .appleWatch)
        XCTAssertEqual(actuals[0].categoryID, "sleep")
        XCTAssertEqual(actuals[0].behavior, WatchBehaviorKind.sleep.rawValue)
    }

    func testSleepAnalysisAcceptsIPhoneOnlyInBedRecord() {
        let base = makeDate(2026, 8, 2, 23)
        let inBed = TimeSpan(
            start: base,
            end: base.addingTimeInterval(8 * hour)
        )

        let sessions = SleepAnalysisEngine().sessions(from: [
            SleepSegment(
                stage: .inBed,
                span: inBed,
                sourceName: "iPhone",
                sourceBundleIdentifier: "com.apple.Health"
            )
        ])

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].span, inBed)
        XCTAssertEqual(sessions[0].asleepDuration, 0)
        XCTAssertEqual(sessions[0].inBedDuration, 8 * hour)
        XCTAssertEqual(sessions[0].sourceNames, ["iPhone"])
    }

    func testSleepAnalysisUsesIPhoneSleepAndAwakeSamplesWithoutWatch() {
        let base = makeDate(2026, 8, 3, 23)
        let sessions = SleepAnalysisEngine().sessions(from: [
            SleepSegment(
                stage: .asleepUnspecified,
                span: TimeSpan(
                    start: base,
                    end: base.addingTimeInterval(7 * hour)
                ),
                sourceName: "iPhone"
            ),
            SleepSegment(
                stage: .awake,
                span: TimeSpan(
                    start: base.addingTimeInterval(7 * hour),
                    end: base.addingTimeInterval(7.25 * hour)
                ),
                sourceName: "iPhone"
            )
        ])

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(
            sessions[0].span.end,
            base.addingTimeInterval(7.25 * hour)
        )
        XCTAssertEqual(sessions[0].asleepDuration, 7 * hour)
        XCTAssertEqual(sessions[0].awakeDuration, 0.25 * hour)
        XCTAssertEqual(sessions[0].sourceNames, ["iPhone"])
    }

    func testSleepAnalysisSeparatesNapFromNightSleep() {
        let base = makeDate(2026, 7, 30, 1, 0)
        let segments = [
            SleepSegment(
                stage: .core,
                span: TimeSpan(start: base, end: base.addingTimeInterval(6 * hour)),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .asleepUnspecified,
                span: TimeSpan(
                    start: base.addingTimeInterval(12 * hour),
                    end: base.addingTimeInterval(13 * hour)
                ),
                sourceName: "iPhone"
            )
        ]
        XCTAssertEqual(
            SleepAnalysisEngine().sessions(from: segments).count,
            2
        )
    }

    func testSleepSourceTierClassifiesWatchIPhoneAndThirdParty() {
        func tier(_ name: String, bundle: String, device: String?) -> SleepSourceTier {
            SleepSegment.sourceTier(
                sourceName: name,
                sourceBundleIdentifier: bundle,
                deviceName: device
            )
        }

        XCTAssertEqual(
            tier("Apple Watch", bundle: "com.apple.health", device: "Apple Watch"),
            .appleWatch
        )
        XCTAssertEqual(
            tier("건강", bundle: "com.apple.health.5B1F0C4E-0000-4000-8000-000000000000", device: nil),
            .appleWatch
        )
        XCTAssertEqual(tier("iPhone", bundle: "com.apple.Health", device: "iPhone"), .iPhone)
        XCTAssertEqual(tier("건강", bundle: "com.apple.Health", device: nil), .iPhone)
        XCTAssertEqual(tier("Sleep Cycle", bundle: "com.sleepcycle.app", device: nil), .thirdParty)
        XCTAssertEqual(tier("", bundle: "", device: nil), .unknown)
        XCTAssertGreaterThan(
            SleepSourceTier.appleWatch.priority,
            SleepSourceTier.thirdParty.priority
        )
        XCTAssertGreaterThan(
            SleepSourceTier.thirdParty.priority,
            SleepSourceTier.iPhone.priority
        )
    }

    /// 워치가 자지 않은 낮잠까지 지우지는 않는다(겹치는 구간만 워치 것을 쓴다).
    func testWatchNightKeepsIPhoneNapOutsideItsCoverage() {
        let base = makeDate(2026, 9, 3, 0)
        let sessions = SleepAnalysisEngine().sessions(from: [
            SleepSegment(
                stage: .core,
                span: TimeSpan(start: base, end: base.addingTimeInterval(6 * hour)),
                sourceName: "Apple Watch",
                deviceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .asleepUnspecified,
                span: TimeSpan(
                    start: base.addingTimeInterval(13 * hour),
                    end: base.addingTimeInterval(14 * hour)
                ),
                sourceName: "iPhone",
                sourceBundleIdentifier: "com.apple.Health"
            )
        ])

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].sourceTier, .appleWatch)
        XCTAssertEqual(sessions[1].sourceTier, .iPhone)
        XCTAssertTrue(sessions[1].isProvisional)
        XCTAssertEqual(sessions[1].asleepDuration, hour)
    }

    /// 요청 구간 밖의 워치 기록이 구간 안의 아이폰 기록을 지우지 않는다.
    func testSleepSpanClippingKeepsIPhoneEstimateWhenWatchIsOutsideSpan() {
        let base = makeDate(2026, 9, 6, 22)
        let sessions = SleepAnalysisEngine().sessions(
            from: [
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
            ],
            inside: TimeSpan(
                start: base.addingTimeInterval(9 * hour),
                end: base.addingTimeInterval(12 * hour)
            )
        )

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sourceTier, .iPhone)
        XCTAssertEqual(sessions[0].asleepDuration, hour)
    }

    func testHealthKitRefreshKeepsSleepWhenFreshHealthDataHasNoSleep() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(24 * hour)
        )
        let sleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: base.addingTimeInterval(2 * hour),
            endedAt: base.addingTimeInterval(8 * hour),
            source: .healthKit
        )
        let workout = ActualRecord(
            planID: nil,
            title: "걷기",
            categoryID: "exercise",
            startedAt: base.addingTimeInterval(10 * hour),
            endedAt: base.addingTimeInterval(11 * hour),
            source: .healthKit
        )

        let result = AppleDeviceGroundTruthEngine.replacingHealthKitActuals(
            existing: [sleep],
            with: [workout],
            inside: span
        )

        XCTAssertTrue(result.contains(sleep))
        XCTAssertTrue(result.contains(workout))
    }

    func testHealthKitRefreshRemovesLegacyWatchSleepWhenFreshSleepExists() {
        let base = makeDate(2026, 7, 30, 9, 0)
        let span = TimeSpan(
            start: base,
            end: base.addingTimeInterval(24 * hour)
        )
        let oldSleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: base.addingTimeInterval(hour),
            endedAt: base.addingTimeInterval(7 * hour),
            source: .appleWatch
        )
        let freshSleep = ActualRecord(
            planID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: base.addingTimeInterval(2 * hour),
            endedAt: base.addingTimeInterval(8 * hour),
            source: .healthKit
        )

        let result = AppleDeviceGroundTruthEngine.replacingHealthKitActuals(
            existing: [oldSleep],
            with: [freshSleep],
            inside: span
        )

        XCTAssertFalse(result.contains(oldSleep))
        XCTAssertEqual(result.filter { AutomaticRecordTimelineEngine.isSleep($0) }.count, 1)
        XCTAssertEqual(result.first?.id, freshSleep.id)
    }

    func testSleepActualLinksToRoutineOnlyInRelationshipGraph() {
        let start = makeDate(2026, 8, 1, 22)
        let routine = PlanRecord(
            title: "루틴:수면",
            span: TimeSpan(start: start, end: start.addingTimeInterval(10 * hour)),
            categoryID: "sleep"
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
            startedAt: start.addingTimeInterval(15 * 60),
            endedAt: start.addingTimeInterval(8 * hour),
            source: .appleWatch
        )

        let graph = RecordRelationshipEngine.make(
            inside: routine.span,
            plans: [routine, action],
            actuals: [sleep],
            calendarEvents: [],
            places: [],
            travel: []
        )

        XCTAssertTrue(
            graph.edges.contains {
                $0.from == "automatic.actual.\(sleep.id.uuidString)"
                    && $0.to == "routine.\(routine.id.uuidString)"
            }
        )
        XCTAssertFalse(
            graph.edges.contains {
                $0.from == "automatic.actual.\(sleep.id.uuidString)"
                    && $0.to == "action.\(action.id.uuidString)"
            }
        )
        XCTAssertTrue(
            graph.edges.contains {
                $0.from == "routine.\(routine.id.uuidString)"
                    && $0.to == "action.\(action.id.uuidString)"
            }
        )
    }

    func testGoalActivityMatchingCountsExplicitlyLinkedSleepOnly() {
        let start = makeDate(2026, 8, 1, 22)
        let routine = PlanRecord(
            title: "루틴:수면",
            span: TimeSpan(start: start, end: start.addingTimeInterval(10 * hour)),
            categoryID: "sleep"
        )
        let linked = ActualRecord(
            planID: nil,
            routineID: routine.id,
            title: "수면",
            categoryID: "sleep",
            startedAt: start,
            endedAt: start.addingTimeInterval(7 * hour),
            source: .healthKit
        )
        let unlinked = ActualRecord(
            planID: nil,
            routineID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: start,
            endedAt: start.addingTimeInterval(7 * hour),
            source: .healthKit
        )

        XCTAssertEqual(
            GoalActivityMatchingEngine.matches(
                goal: routine,
                plans: [routine],
                actuals: [linked, unlinked]
            ).map(\.actual.id),
            [linked.id]
        )
    }

    func testAutomaticSleepEvidenceUsesBestOverlappingRepeatSegment() {
        let routineStart = makeDate(2026, 8, 1, 22)
        let routine = PlanRecord(
            title: "루틴:수면",
            span: TimeSpan(
                start: routineStart,
                end: routineStart.addingTimeInterval(10 * hour)
            ),
            categoryID: "sleep"
        )
        let repeatSegment = PlanRecord(
            title: "수면 · 주중",
            span: TimeSpan(
                start: makeDate(2026, 8, 1, 23),
                end: makeDate(2026, 8, 2, 6, 30)
            ),
            categoryID: "sleep",
            parentID: routine.id,
            origin: .repeatRule
        )
        let sleep = ActualRecord(
            planID: nil,
            routineID: nil,
            title: "수면",
            categoryID: "sleep",
            startedAt: makeDate(2026, 8, 2, 2),
            endedAt: makeDate(2026, 8, 2, 6),
            source: .healthKit
        )

        let matches = GoalActivityMatchingEngine.matches(
            goal: routine,
            plans: [routine, repeatSegment],
            actuals: [sleep],
            asOf: makeDate(2026, 8, 2, 12)
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.kind, .automatic)
        XCTAssertEqual(matches.first?.matchedPlanID, repeatSegment.id)
        XCTAssertEqual(
            GoalActivityMatchingEngine.progress(
                for: repeatSegment,
                matches: matches,
                asOf: makeDate(2026, 8, 2, 12)
            ),
            4 * hour / (7.5 * hour),
            accuracy: 0.001
        )
    }

    @MainActor
    func testTodayShowsSleepConnectionNoticeUntilHealthOrSleepIsAvailable()
        async {
        var disconnected = makeSnapshot()
        disconnected.settings.healthEnabled = false
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: disconnected),
            cloudSyncService: nil
        )
        await model.bootstrap()
        model.selectedScale = .day
        model.selectedDate = .now

        XCTAssertTrue(model.needsSleepConnectionNotice)

        var connected = makeSnapshot()
        connected.settings.healthEnabled = true
        let connectedModel = AppModel(
            repository: InMemoryPlanRepository(snapshot: connected),
            cloudSyncService: nil
        )
        await connectedModel.bootstrap()
        connectedModel.selectedDate = .now
        XCTAssertFalse(connectedModel.needsSleepConnectionNotice)

        let start = Calendar.autoupdatingCurrent.startOfDay(for: .now)
        var recorded = makeSnapshot(actuals: [
            ActualRecord(
                planID: nil,
                title: "수면",
                categoryID: "sleep",
                startedAt: start,
                endedAt: start.addingTimeInterval(7 * 3_600),
                source: .healthKit,
                confidence: .high,
                createdAt: start,
                behavior: WatchBehaviorKind.sleep.rawValue
            ),
        ])
        recorded.settings.healthEnabled = false
        let recordedModel = AppModel(
            repository: InMemoryPlanRepository(snapshot: recorded),
            cloudSyncService: nil
        )
        await recordedModel.bootstrap()
        recordedModel.selectedDate = .now
        XCTAssertFalse(recordedModel.needsSleepConnectionNotice)

        model.selectedScale = .week
        XCTAssertFalse(model.needsSleepConnectionNotice)
    }

    func testRecordGroupingRoutesActivityRecordsToSleepAndMovement() {
        let day = makeDate(2026, 8, 4)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))
        let actuals = [
            makeActual("수면 추정", "activity", start: day, minutes: 60),
            makeActual(
                "걷기",
                "activity",
                start: day.addingTimeInterval(9 * hour),
                minutes: 30
            ),
            makeActual(
                "서 있기",
                "activity",
                start: day.addingTimeInterval(11 * hour),
                minutes: 10
            ),
        ]

        let groups = ActualRecordGroupingEngine.groups(
            actuals: actuals,
            in: span,
            categories: CategoryCatalog.builtIn,
            asOf: day.addingTimeInterval(24 * hour)
        )

        XCTAssertEqual(
            Set(groups.map(\.id)),
            ["sleep", "movement", "activity"]
        )
        XCTAssertEqual(groups.first { $0.id == "sleep" }?.duration, 60 * 60)
        XCTAssertEqual(groups.first { $0.id == "movement" }?.duration, 30 * 60)
        XCTAssertEqual(groups.first { $0.id == "activity" }?.duration, 10 * 60)
    }

    /// 겹쳐 들어온 수면 단계는 한 줄로 펴고, 화소보다 얇게 그려질 3분짜리
    /// 각성은 이웃에 합친다. 조각을 그대로 그리면 눈에 보이지도 않으면서
    /// 그리는 값만 늘어난다.
    func testSleepStageRingFlattensOverlapAndMergesTooShortStage() throws {
        let dayStart = makeDate(2026, 8, 4)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        func segment(
            _ stage: SleepStage,
            _ from: Double,
            _ to: Double
        ) -> SleepSegment {
            SleepSegment(
                stage: stage,
                span: TimeSpan(
                    start: dayStart.addingTimeInterval(from * hour),
                    end: dayStart.addingTimeInterval(to * hour)
                ),
                sourceName: "Apple Watch"
            )
        }
        let sessions = SleepAnalysisEngine().sessions(
            from: [
                segment(.inBed, 0, 7),
                segment(.core, 0, 1),
                segment(.deep, 1, 2),
                segment(.awake, 2, 2 + 3.0 / 60),
                segment(.core, 2 + 3.0 / 60, 4),
                segment(.rem, 4, 5),
            ]
        )
        XCTAssertEqual(sessions.count, 1)

        let ring = try XCTUnwrap(
            RecordClockDetailEngine.sleepRing(sessions: sessions, in: day)
        )
        XCTAssertEqual(ring.kind, .sleepStage)
        XCTAssertEqual(
            ring.arcs.map(\.token),
            ["core", "deep", "core", "rem", "inBed"]
        )
        // 3분짜리 각성은 앞 조각에 흡수돼 사라진다.
        XCTAssertEqual(
            ring.arcs[1].endFraction,
            (2 * hour + 180) / (24 * hour),
            accuracy: 1e-9
        )
        assertRingHasNoSlivers(ring)
    }

    func testActivitySleepRingKeepsOnlyAsleepStages() throws {
        let dayStart = makeDate(2026, 8, 4)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let segments = [
            SleepSegment(
                stage: .inBed,
                span: TimeSpan(
                    start: dayStart,
                    end: dayStart.addingTimeInterval(5 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .core,
                span: TimeSpan(
                    start: dayStart.addingTimeInterval(hour),
                    end: dayStart.addingTimeInterval(3 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .awake,
                span: TimeSpan(
                    start: dayStart.addingTimeInterval(3 * hour),
                    end: dayStart.addingTimeInterval(4 * hour)
                ),
                sourceName: "Apple Watch"
            ),
            SleepSegment(
                stage: .rem,
                span: TimeSpan(
                    start: dayStart.addingTimeInterval(4 * hour),
                    end: dayStart.addingTimeInterval(5 * hour)
                ),
                sourceName: "Apple Watch"
            ),
        ]
        let sessions = SleepAnalysisEngine().sessions(from: segments)
        let ring = try XCTUnwrap(
            RecordClockDetailEngine.activitySleepRing(
                sessions: sessions,
                in: day
            )
        )

        XCTAssertEqual(ring.arcs.map(\.token), ["core", "rem"])
    }

    func testActivitySleepRingHidesStagesWithoutWatchEvidence() throws {
        let dayStart = makeDate(2026, 8, 4)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let sessions = SleepAnalysisEngine().sessions(
            from: [
                SleepSegment(
                    stage: .core,
                    span: TimeSpan(
                        start: dayStart,
                        end: dayStart.addingTimeInterval(2 * hour)
                    ),
                    sourceName: "iPhone"
                ),
                SleepSegment(
                    stage: .deep,
                    span: TimeSpan(
                        start: dayStart.addingTimeInterval(2 * hour),
                        end: dayStart.addingTimeInterval(3 * hour)
                    ),
                    sourceName: "iPhone"
                ),
            ]
        )
        let ring = try XCTUnwrap(
            RecordClockDetailEngine.activitySleepRing(
                sessions: sessions,
                in: day
            )
        )

        XCTAssertEqual(
            Set(ring.arcs.map(\.token)),
            Set([SleepStage.asleepUnspecified.rawValue])
        )
    }

    func testActivityBandIncludesSleepStagesAndTravelModes() {
        let dayStart = makeDate(2026, 8, 4)
        let day = TimeSpan(
            start: dayStart,
            end: dayStart.addingTimeInterval(24 * hour)
        )
        let sessions = SleepAnalysisEngine().sessions(
            from: [
                SleepSegment(
                    stage: .core,
                    span: TimeSpan(
                        start: dayStart,
                        end: dayStart.addingTimeInterval(2 * hour)
                    ),
                    sourceName: "Apple Watch"
                )
            ]
        )
        let travel = TravelSegment(
            mode: .car,
            span: TimeSpan(
                start: dayStart.addingTimeInterval(8 * hour),
                end: dayStart.addingTimeInterval(9 * hour)
            ),
            distanceMeters: 10_000,
            confidence: .high,
            evidence: ["GPS"]
        )

        let rings = RecordClockDetailEngine.activityRings(
            sleepSessions: sessions,
            travel: [travel],
            in: day
        )

        XCTAssertEqual(rings.map(\.kind), [.sleepStage, .travel])
        XCTAssertEqual(rings[0].arcs.map(\.token), ["core"])
        XCTAssertEqual(rings[1].arcs.map(\.token), ["car"])
    }

    func testActivityDoesNotBorrowSleepPhase() {
        let day = dayPhaseDay()
        let sleepEnd = day.start.addingTimeInterval(8 * hour)
        let phases = [
            DayPhaseSpan(
                phase: .sleep,
                span: TimeSpan(start: day.start, end: sleepEnd)
            ),
            DayPhaseSpan(
                phase: .activity,
                span: TimeSpan(start: sleepEnd, end: day.end)
            ),
        ]
        let stay = TimeSpan(
            start: day.start.addingTimeInterval(7 * hour),
            end: day.start.addingTimeInterval(9 * hour)
        )

        XCTAssertEqual(
            DayPhaseEngine.assignments(of: stay, to: phases)
                .filter {
                    $0.phase == DayPhase.phase(
                        forActivityCategory: "activity"
                    )
                }
                .map(\.phase),
            [.activity]
        )
    }

    func testSleepLocationTimeFilterKeepsOvernightOpenAndCutoffSemantics() {
        let day = dayPhaseDay()
        let cutoff = day.start.addingTimeInterval(6 * hour)
        let overnight = ActualRecord(
            planID: nil, title: "취침", categoryID: "activity",
            startedAt: day.start.addingTimeInterval(-2 * hour),
            endedAt: day.start.addingTimeInterval(4 * hour), source: .healthKit
        )
        let open = ActualRecord(
            planID: nil, title: "sleep", categoryID: "activity",
            startedAt: day.start.addingTimeInterval(5 * hour), source: .appleWatch
        )
        let ignored = [
            sleepActual(-3, 0, on: day), sleepActual(6, 7, on: day),
            ActualRecord(
                planID: nil, title: "수면 앱", categoryID: "appUsage",
                startedAt: day.start.addingTimeInterval(4 * hour),
                endedAt: day.start.addingTimeInterval(5 * hour), source: .appUsage
            ),
        ]
        XCTAssertEqual(
            MapHomeSleepLocationPolicy.spans(
                actuals: ignored + [overnight, open], in: day, through: cutoff
            ),
            [TimeSpan(start: day.start, end: overnight.endedAt!),
             TimeSpan(start: open.startedAt, end: cutoff)]
        )
        XCTAssertNil(open.endedAt)
    }

    /// 수면 근거는 회사 체류와 겹쳐도 수면 일과가 우선한다.
    func testDayPhaseRingKeepsSleepOverWorkAtTheOffice() throws {
        let day = dayPhaseDay()
        let nap = sleepActual(13, 13.75, on: day)
        let actuals = [
            sleepActual(0, 7, on: day),
            stationaryContext(.homeRest, 7, 8, on: day),
            stationaryContext(.work, 8.75, 18, on: day),
            nap,
            stationaryContext(.homeRest, 18.75, 24, on: day),
        ]
        let travel = [
            travelLeg(.subway, 8, 8.75, on: day),
            travelLeg(.subway, 18, 18.75, on: day),
        ]
        let phases = DayPhaseEngine.phases(
            actuals: actuals,
            travel: travel,
            stays: [],
            placeKinds: [:],
            in: day,
            asOf: day.end
        )

        XCTAssertEqual(
            phases.map(\.phase.title),
            ["수면", "활동", "이동", "업무", "수면", "업무", "이동", "활동"]
        )
        let napMiddle = day.start.addingTimeInterval(13.5 * hour)
        XCTAssertEqual(
            phases.first { $0.span.contains(napMiddle) }?.phase,
            .sleep
        )
        assertPhasesPartitionTheDay(phases, in: day)

        // 카테고리 고리는 낮잠을 감추지 않는다.
        let sleepRing = RecordChartEngine.clockRings(
            actuals: actuals,
            in: day,
            asOf: day.end
        )
        .first { $0.categoryID == "sleep" }
        XCTAssertEqual(
            try XCTUnwrap(sleepRing).arcs.map(\.startFraction),
            [0, 13.0 / 24]
        )
    }

}
