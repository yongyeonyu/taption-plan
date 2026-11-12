import XCTest
@testable import TaptionWatchSync

final class WatchFacePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func plan(
        _ title: String,
        startsIn start: TimeInterval,
        minutes: Double = 60,
        status: String = "planned",
        isGoal: Bool = false
    ) -> TaptionWatchPlanItem {
        TaptionWatchPlanItem(
            id: UUID(),
            title: title,
            categoryID: "work",
            startsAt: now.addingTimeInterval(start),
            endsAt: now.addingTimeInterval(start + minutes * 60),
            status: status,
            actualStartedAt: nil,
            categoryName: nil,
            categoryHex: nil,
            isGoal: isGoal
        )
    }

    private func payload(
        items: [TaptionWatchPlanItem] = [],
        activity: TaptionWatchCurrentActivity? = nil
    ) -> TaptionWatchPayload {
        TaptionWatchPayload(
            generatedAt: now,
            viewportStart: now.addingTimeInterval(-3_600),
            viewportEnd: now.addingTimeInterval(6 * 3_600),
            items: items,
            catStyle: "calico",
            reducesMotion: false,
            currentActivity: activity
        )
    }

    func testCatAssetUsesPoseThenMajorCategory() {
        XCTAssertEqual(
            TaptionWatchFacePolicy.catAssetName(style: "mackerel", categoryID: "eating.lunch"),
            "WatchCat-mackerel-Eat"
        )
        XCTAssertEqual(
            TaptionWatchFacePolicy.catAssetName(style: "unknown", categoryID: "work", poseName: "meeting"),
            "WatchCat-white-meeting"
        )
        XCTAssertEqual(TaptionWatchFacePolicy.catAction(categoryID: "unconfirmed"), "Check")
        XCTAssertEqual(TaptionWatchFacePolicy.catAction(categoryID: "errand"), "Rest")
    }

    func testHexColor() {
        XCTAssertEqual(
            TaptionWatchFacePolicy.rgb(hex: "#FF0080"),
            TaptionWatchFacePolicy.RGB(red: 1, green: 0, blue: 128.0 / 255)
        )
        XCTAssertNil(TaptionWatchFacePolicy.rgb(hex: "zz"))
        XCTAssertNil(TaptionWatchFacePolicy.rgb(hex: nil))
    }

    func testAgendaPutsRunningFirstAndDropsGoalsAndFinished() {
        let running = plan("진행", startsIn: -600)
        let soon = plan("곧", startsIn: 900)
        let later = plan("나중", startsIn: 7_200)
        let items = [
            later,
            plan("목표", startsIn: -600, isGoal: true),
            plan("끝", startsIn: 300, status: "completed"),
            plan("지남", startsIn: -7_200),
            soon,
            running,
        ]
        XCTAssertEqual(
            TaptionWatchFacePolicy.agenda(items, at: now).map(\.title),
            ["진행", "곧", "나중"]
        )
        XCTAssertEqual(TaptionWatchFacePolicy.agenda(items, at: now, limit: 2).count, 2)
    }

    func testApproachFractionFillsDuringLastHour() {
        XCTAssertEqual(TaptionWatchFacePolicy.approachFraction(startsAt: now.addingTimeInterval(7_200), now: now), 0)
        XCTAssertEqual(TaptionWatchFacePolicy.approachFraction(startsAt: now.addingTimeInterval(1_800), now: now), 0.5, accuracy: 0.001)
        XCTAssertEqual(TaptionWatchFacePolicy.approachFraction(startsAt: now.addingTimeInterval(-60), now: now), 1)
    }

    func testDaySegmentsStackLongestFirst() {
        let summary = TaptionWatchDaySummary(
            date: now, scheduledCount: 0, completedCount: 0, recordedMinutes: 600, activeMinutes: 0,
            categories: [
                TaptionWatchCategoryMinutes(categoryID: "rest", title: "휴식", hex: nil, minutes: 0),
                TaptionWatchCategoryMinutes(categoryID: "work", title: "업무", hex: "5B9BD5", minutes: 360),
                TaptionWatchCategoryMinutes(categoryID: "sleep", title: "수면", hex: nil, minutes: 720),
            ]
        )
        let segments = TaptionWatchFacePolicy.daySegments(summary)
        XCTAssertEqual(segments.map(\.categoryID), ["sleep", "work"])
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[0].end, 0.5, accuracy: 0.001)
        XCTAssertEqual(segments[1].end, 0.75, accuracy: 0.001)
    }

    func testDurationText() {
        XCTAssertEqual(TaptionWatchFacePolicy.durationText(45, language: .korean), "45분")
        XCTAssertEqual(TaptionWatchFacePolicy.durationText(120, language: .korean), "2시간")
        XCTAssertEqual(TaptionWatchFacePolicy.durationText(135, language: .korean), "2시간 15분")
        XCTAssertEqual(TaptionWatchFacePolicy.durationText(-5, language: .korean), "0분")
    }

    func testTimelineHasGridAndPlanBoundariesInsideHorizon() {
        let soon = plan("곧", startsIn: 20 * 60, minutes: 25)
        let far = plan("멀리", startsIn: 3 * 3_600)
        let dates = TaptionWatchFacePolicy.timelineDates(
            now: now,
            payload: payload(items: [soon, far]),
            calendar: Calendar(identifier: .gregorian)
        )
        XCTAssertEqual(dates.first, now)
        XCTAssertTrue(dates.contains(soon.startsAt))
        XCTAssertTrue(dates.contains(soon.endsAt))
        XCTAssertFalse(dates.contains(far.startsAt))
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertLessThanOrEqual(dates.count, 8)
        XCTAssertEqual(TaptionWatchFacePolicy.timelineDates(now: now, payload: nil).first, now)
    }

    func testTimelineIncludesMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let lateNight = midnight.addingTimeInterval(-10 * 60)
        let dates = TaptionWatchFacePolicy.timelineDates(now: lateNight, payload: nil, calendar: calendar)
        XCTAssertTrue(dates.contains(midnight))
    }

    func testRelevanceOrder() {
        let activity = TaptionWatchCurrentActivity(
            categoryID: "work", koreanTitle: "업무", englishTitle: "Work", startedAt: now
        )
        XCTAssertEqual(TaptionWatchFacePolicy.relevanceScore(payload: nil, hasAlert: false, at: now), 0)
        XCTAssertEqual(
            TaptionWatchFacePolicy.relevanceScore(payload: payload(activity: activity), hasAlert: false, at: now), 10
        )
        XCTAssertEqual(
            TaptionWatchFacePolicy.relevanceScore(
                payload: payload(items: [plan("곧", startsIn: 40 * 60)]), hasAlert: false, at: now
            ), 40
        )
        XCTAssertEqual(
            TaptionWatchFacePolicy.relevanceScore(
                payload: payload(items: [plan("곧", startsIn: 10 * 60)]), hasAlert: false, at: now
            ), 70
        )
        XCTAssertEqual(
            TaptionWatchFacePolicy.relevanceScore(
                payload: payload(items: [plan("곧", startsIn: 10 * 60)]), hasAlert: true, at: now
            ), 80
        )
    }

    func testDecodeCacheDecodesSameBytesOnce() throws {
        let cache = TaptionWatchDecodeCache<TaptionWatchPayload>()
        let first = try JSONEncoder().encode(payload())
        let second = try JSONEncoder().encode(payload(items: [plan("곧", startsIn: 600)]))
        XCTAssertEqual(cache.value(for: first)?.items.count, 0)
        XCTAssertEqual(cache.value(for: first)?.items.count, 0)
        XCTAssertEqual(cache.decodeCount, 1)
        XCTAssertEqual(cache.value(for: second)?.items.count, 1)
        XCTAssertEqual(cache.decodeCount, 2)
        XCTAssertNil(cache.value(for: Data("x".utf8)))
        cache.reset()
        XCTAssertEqual(cache.value(for: first)?.items.count, 0)
        XCTAssertEqual(cache.decodeCount, 4)
    }
}
