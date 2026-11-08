import Foundation
import XCTest
@testable import TaptionPlan

/// 낮잠은 Apple Watch가 잰 낮 수면만이다(RIG1103A02).
final class AppleWatchNapPolicyTests: XCTestCase {
    private let calendar = Calendar.autoupdatingCurrent
    private let hour: TimeInterval = 3_600

    private var day: Date {
        calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
    }

    private var daySpan: TimeSpan {
        TimeSpan(start: day, end: day.addingTimeInterval(24 * hour))
    }

    private func watch(_ from: Double, _ to: Double) -> SleepSegment {
        SleepSegment(
            stage: .core,
            span: TimeSpan(start: day.addingTimeInterval(from * hour), end: day.addingTimeInterval(to * hour)),
            sourceName: "Apple Watch",
            deviceName: "Apple Watch"
        )
    }

    private func iPhone(_ from: Double, _ to: Double) -> SleepSegment {
        SleepSegment(
            stage: .asleepUnspecified,
            span: TimeSpan(start: day.addingTimeInterval(from * hour), end: day.addingTimeInterval(to * hour)),
            sourceName: "iPhone",
            sourceBundleIdentifier: "com.apple.Health"
        )
    }

    private func sessions(_ segments: [SleepSegment]) -> [SleepSession] {
        SleepAnalysisEngine().sessions(from: segments)
    }

    private func healthActual(_ session: SleepSession) -> ActualRecord {
        ActualRecord(
            id: session.id, planID: nil, title: "수면", categoryID: "sleep",
            startedAt: session.span.start, endedAt: session.span.end,
            source: session.isAppleWatchConfirmed ? .appleWatch : .healthKit,
            behavior: "sleep", evidence: ["HealthKit 수면 기록"], modelVersion: "healthkit-sleep-v1"
        )
    }

    func testWatchDaytimeSleepBecomesNapWithProvenance() throws {
        let all = sessions([watch(0, 7), watch(14, 15)])
        XCTAssertEqual(all.count, 2)
        let labeled = AppleWatchNapPolicy.labeling(all.map(healthActual), sessions: all, inside: daySpan, calendar: calendar)
        let nap = try XCTUnwrap(labeled.first { $0.id == all[1].id })
        XCTAssertEqual(nap.title, "낮잠")
        XCTAssertEqual(nap.behavior, "nap")
        XCTAssertEqual(nap.categoryID, "sleep")
        XCTAssertEqual(nap.source, .appleWatch)
        XCTAssertTrue(nap.evidence.contains(AppleWatchNapPolicy.evidence))
        XCTAssertTrue(nap.evidence.contains("HealthKit 수면 기록"), "원래 근거는 남는다")
        XCTAssertEqual(nap.modelVersion, "healthkit-sleep-v1", "HealthKit 원본 버전은 그대로")
        XCTAssertEqual(nap.startedAt, all[1].span.start)
        XCTAssertEqual(nap.endedAt, all[1].span.end)
        XCTAssertNotNil(RecordClassificationCatalog.options.first { $0.categoryID == "sleep" && $0.behavior == nap.behavior })
        XCTAssertEqual(RecordAnalysisCategoryPolicy.categoryID(for: nap), "sleep", "낮잠도 수면으로 분석한다")
    }

    func testNightSleepIsUnchanged() throws {
        let all = sessions([watch(0, 7), watch(14, 15)])
        let night = healthActual(all[0])
        let labeled = AppleWatchNapPolicy.labeling([night], sessions: all, inside: daySpan, calendar: calendar)
        XCTAssertEqual(labeled, [night])
        XCTAssertFalse(AppleWatchNapPolicy.isNap(all[0], among: all, calendar: calendar))
    }

    func testIPhoneOnlyDaytimeSleepIsNotNap() {
        let all = sessions([watch(0, 7), iPhone(14, 15)])
        XCTAssertFalse(AppleWatchNapPolicy.isNap(all[1], among: all, calendar: calendar))
        let actual = healthActual(all[1])
        XCTAssertEqual(AppleWatchNapPolicy.labeling([actual], sessions: all, inside: daySpan, calendar: calendar), [actual])
    }

    func testPhoneStillnessRecordIsNeverNap() {
        let all = sessions([watch(0, 7), watch(14, 15)])
        // 휴대폰 정지로 만든 자동 수면은 같은 시간에 워치 낮잠이 있어도 바꾸지 않는다.
        let stillness = ActualRecord(
            planID: nil, title: "수면", categoryID: "sleep",
            startedAt: all[1].span.start, endedAt: all[1].span.end,
            source: .motion, behavior: "sleep", modelVersion: "classifier-v1/sleep"
        )
        XCTAssertEqual(AppleWatchNapPolicy.labeling([stillness], sessions: all, inside: daySpan, calendar: calendar), [stillness])
    }

    func testUserEnteredWatchSampleAndLongDaySleepAreNotNaps() {
        var entered = watch(14, 15)
        entered.isUserEntered = true
        let manual = sessions([watch(0, 7), entered])
        XCTAssertFalse(AppleWatchNapPolicy.isNap(manual[1], among: manual, calendar: calendar))
        let long = sessions([watch(0, 7), watch(12, 16.5)])
        XCTAssertFalse(AppleWatchNapPolicy.isNap(long[1], among: long, calendar: calendar), "4시간보다 길면 낮잠이 아니다")
        let evening = sessions([watch(0, 7), watch(20.5, 22)])
        XCTAssertFalse(AppleWatchNapPolicy.isNap(evening[1], among: evening, calendar: calendar), "21시를 넘기면 낮잠이 아니다")
    }

    func testLateMorningSleepWithoutNightSessionIsMainSleep() {
        // 밤에 워치를 차지 않았다면 오전 잠이 그 밤의 본 수면이다.
        let all = sessions([watch(10, 11.5)])
        XCTAssertFalse(AppleWatchNapPolicy.isNap(all[0], among: all, calendar: calendar))
        let withNight = sessions([watch(0, 7), watch(10, 11.5)])
        XCTAssertTrue(AppleWatchNapPolicy.isNap(withNight[1], among: withNight, calendar: calendar))
    }

    func testUserEditedRecordIsUntouched() {
        let all = sessions([watch(0, 7), watch(14, 15)])
        var edited = healthActual(all[1])
        edited.title = "독서"
        edited.categoryID = "sleep"
        edited.manuallyCorrected = true
        XCTAssertEqual(AppleWatchNapPolicy.labeling([edited], sessions: all, inside: daySpan, calendar: calendar), [edited])
    }

    func testNapReturnsToSleepWhenRuleNoLongerMatches() throws {
        let napSessions = sessions([watch(0, 7), watch(14, 15)])
        let nap = try XCTUnwrap(AppleWatchNapPolicy.labeling(
            [healthActual(napSessions[1])], sessions: napSessions, inside: daySpan, calendar: calendar
        ).first)
        XCTAssertEqual(nap.behavior, "nap")
        // 밤 세션 없이 오전 잠만 남으면 그날의 본 수면이므로 다시 수면이 된다.
        var morning = napSessions[1]
        morning.span = TimeSpan(start: day.addingTimeInterval(10 * hour), end: day.addingTimeInterval(11 * hour))
        let reverted = try XCTUnwrap(AppleWatchNapPolicy.labeling([nap], sessions: [morning], inside: daySpan, calendar: calendar).first)
        XCTAssertEqual(reverted.title, "수면")
        XCTAssertEqual(reverted.behavior, "sleep")
        XCTAssertFalse(reverted.evidence.contains(AppleWatchNapPolicy.evidence))
    }

    /// 수면 반영 경로(`SleepActualReconciliationEngine`)가 워치 낮 수면을 낮잠으로 만든다.
    func testSleepReconciliationCreatesNapFromWatchSession() throws {
        let all = sessions([watch(0, 7), watch(14, 15)])
        let result = SleepActualReconciliationEngine.applying(
            [], sessions: all, inside: daySpan, asOf: daySpan.end
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.title), ["수면", "낮잠"])
        XCTAssertEqual(result.map(\.behavior), ["sleep", "nap"])
    }
}
