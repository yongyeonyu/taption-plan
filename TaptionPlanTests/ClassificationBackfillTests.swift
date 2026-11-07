import Foundation
import XCTest
@testable import TaptionPlan

/// 규칙 버전이 바뀐 뒤 지난 날짜 전체 일괄 재계산(HMM1101A01).
final class ClassificationBackfillTests: XCTestCase {
    private final class Markers: ClassificationRecomputeMarkerStore, @unchecked Sendable {
        var values: [String: String] = [:]
        func isCompleted(_ key: String) async -> Bool { values[key] != nil }
        func markCompleted(_ key: String, outcome: String) async { values[key] = outcome }
    }

    private let calendar = Calendar.autoupdatingCurrent
    private var now: Date { Date(timeIntervalSince1970: 1_790_000_000) }
    private var today: Date { calendar.startOfDay(for: now) }

    private func daysAgo(_ count: Int) -> Date {
        calendar.date(byAdding: .day, value: -count, to: today)!
    }

    func testProcessesPastDaysNewestFirstAndSkipsToday() async {
        let markers = Markers()
        var seen: [Date] = []
        let summary = await ClassificationBackfill(markers: markers).run(
            days: [daysAgo(3), now, daysAgo(1), daysAgo(2).addingTimeInterval(3_600), daysAgo(1)],
            now: now,
            recompute: { seen.append($0); return true }
        )
        XCTAssertEqual(seen, [daysAgo(1), daysAgo(2), daysAgo(3)])
        XCTAssertEqual(summary, .init(recomputed: 3, alreadyDone: 0, failed: 0, finished: true))
        XCTAssertNotNil(markers.values[ClassificationRecomputeCoordinator.markerKey(for: daysAgo(2))])
        XCTAssertNil(markers.values[ClassificationRecomputeCoordinator.markerKey(for: today)], "오늘은 하루 갱신에 맡긴다")
    }

    func testResumesAfterInterruptionWithoutRedoingFinishedDays() async {
        let markers = Markers()
        let days = (1...5).map(daysAgo)
        var seen: [Date] = []
        var allowed = 2
        let first = await ClassificationBackfill(markers: markers).run(
            days: days, now: now,
            shouldContinue: { defer { allowed -= 1 }; return allowed > 0 },
            recompute: { seen.append($0); return true }
        )
        XCTAssertFalse(first.finished)
        XCTAssertEqual(seen, [daysAgo(1), daysAgo(2)])
        XCTAssertNil(markers.values[ClassificationBackfill.completionKey])

        // 앱을 다시 켠 것처럼 같은 저장소로 새로 만든다.
        seen = []
        let second = await ClassificationBackfill(markers: markers).run(days: days, now: now, recompute: { seen.append($0); return true })
        XCTAssertEqual(seen, [daysAgo(3), daysAgo(4), daysAgo(5)])
        XCTAssertEqual(second, .init(recomputed: 3, alreadyDone: 2, failed: 0, finished: true))
    }

    func testCancellationStopsWithoutMarkingTheDay() async {
        let markers = Markers()
        let days = (1...3).map(daysAgo)
        let now = self.now
        let task = Task { [markers, days, now] in
            await ClassificationBackfill(markers: markers).run(days: days, now: now, recompute: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return false
            })
        }
        let summary = await task.value
        XCTAssertFalse(summary.finished)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertNil(markers.values[ClassificationRecomputeCoordinator.markerKey(for: daysAgo(1))])
        XCTAssertNil(markers.values[ClassificationBackfill.completionKey])
    }

    func testRunsOncePerRulesVersion() async {
        let markers = Markers()
        var calls = 0
        _ = await ClassificationBackfill(markers: markers).run(days: [daysAgo(1)], now: now, recompute: { _ in calls += 1; return false })
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(markers.values[ClassificationBackfill.completionKey], "실패한 날이 있어도 한 번 돈 뒤에는 끝난 것으로 둔다")
        XCTAssertTrue(ClassificationBackfill.completionKey.hasSuffix(ClassificationRules.version))

        // 같은 버전이면 날짜 표식이 없어도, 새 날이 생겨도 다시 돌지 않는다.
        let again = await ClassificationBackfill(markers: markers).run(days: [daysAgo(1), daysAgo(9)], now: now, recompute: { _ in calls += 1; return true })
        XCTAssertTrue(again.finished)
        XCTAssertEqual(calls, 1)
        let finished = await ClassificationBackfill(markers: markers).isFinished()
        XCTAssertTrue(finished)
    }

    func testDayMarkersFollowRulesVersion() {
        XCTAssertTrue(ClassificationRecomputeCoordinator.markerKey(for: today).hasPrefix(ClassificationRules.version + ":"))
        XCTAssertNotEqual(ClassificationRules.version, "classifier-v1", "규칙을 올렸으므로 예전 표식으로 건너뛰지 않는다")
    }

    /// 다시 만든 날도 사용자 기록·잠금은 바이트 그대로, 원본은 읽기만 한다.
    func testRecomputeKeepsUserRecordsAndRawData() async {
        let day = daysAgo(1)
        let span = TimeSpan(start: day, end: day.addingTimeInterval(86_400))
        let user = ActualRecord(
            planID: nil, title: "업무", categoryID: "work",
            startedAt: day.addingTimeInterval(9 * 3_600), endedAt: day.addingTimeInterval(10 * 3_600),
            source: .motion, modelVersion: "classifier-v1/activity", manuallyCorrected: true, lockReason: .user
        )
        let locked = ActualRecord(
            planID: nil, title: "휴식", categoryID: "activity",
            startedAt: day.addingTimeInterval(13 * 3_600), endedAt: day.addingTimeInterval(14 * 3_600),
            source: .motion, modelVersion: "classifier-v1/activity", lockReason: .stability
        )
        let manual = ActualRecord(
            planID: nil, title: "운동", categoryID: "exercise",
            startedAt: day.addingTimeInterval(18 * 3_600), endedAt: day.addingTimeInterval(19 * 3_600),
            source: .manual
        )
        var stored = [user, locked, manual]
        let raw = Array(repeating: 1, count: 500)
        let rawBefore = raw

        _ = await ClassificationBackfill(markers: Markers()).run(days: [day], now: now, recompute: { day in
            let prepared = ClassificationRecomputeCoordinator.prepare(
                stored, rawSampleCount: raw.count, inside: span, activityCorrections: [:]
            )
            XCTAssertEqual(prepared.outcome, .recomputed)
            // 새 규칙이 두 자동 구간을 모두 '걷기'로 다시 만든 경우.
            let fresh = [user, locked].map { previous -> ActualRecord in
                var value = previous
                value.title = "걷기"
                value.categoryID = "movement"
                value.manuallyCorrected = false
                value.lockReason = nil
                return value
            }
            let existing = prepared.records.filter { $0.source.usesAutomaticClassification }
            stored = ActivityClassificationLockEngine.mergingLockedClassifications(
                existing: existing, fresh: fresh, inside: span
            ) + prepared.records.filter { !$0.source.usesAutomaticClassification }
            return true
        })

        XCTAssertEqual(stored.first { $0.id == user.id }?.title, "업무")
        XCTAssertEqual(stored.first { $0.id == user.id }?.lockReason, .user)
        XCTAssertEqual(stored.first { $0.id == locked.id }?.title, "걷기", "안정 잠금만 풀려 새 규칙을 따른다")
        XCTAssertTrue(PlanActualStorage.exactlyEqual([stored.first { $0.id == manual.id }!][...], [manual][...]))
        XCTAssertEqual(raw, rawBefore)
    }

    @MainActor
    func testLocalDaysCoverBothEndsOfUTCDay() {
        var seoul = Calendar(identifier: .gregorian)
        seoul.timeZone = TimeZone(identifier: "Asia/Seoul")!
        // 1970-01-02 UTC = 서울 1/2 09:00 ~ 1/3 08:59
        let days = AppModel.localDays(fromUTCDayNumbers: [1], calendar: seoul).sorted()
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(seoul.component(.day, from: days[0]), 2)
        XCTAssertEqual(seoul.component(.day, from: days[1]), 3)
    }
}
