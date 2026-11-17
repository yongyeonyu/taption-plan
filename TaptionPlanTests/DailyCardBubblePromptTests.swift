import XCTest
@testable import TaptionPlan

/// 하루 카드 1시간 전 말풍선 요청(DCB1116A01).
@MainActor
final class DailyCardBubblePromptTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 16) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func defaults() -> UserDefaults {
        let name = "DailyCardBubblePromptTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private let eight = DateComponents(hour: 8, minute: 0)

    func testDueOnlyInsideTheHourBeforeTheCard() {
        func due(_ now: Date) -> Date? {
            DailyCardBubblePrompt.due(now: now, time: eight, enabled: true, lastSent: nil, calendar: calendar)
        }
        XCTAssertNil(due(at(6, 59)))
        XCTAssertEqual(due(at(7, 0)), at(8))
        XCTAssertEqual(due(at(7, 59)), at(8))
        // 카드 시각이 되면(지나면) 그날은 올리지 않는다. 다음 카드는 내일 8시라 창 밖이다.
        XCTAssertNil(due(at(8, 0)))
        XCTAssertNil(due(at(9, 0)))
    }

    /// REV1117A02: 기기 달력이 불기여도 AI에게는 서기 날짜를 보낸다(불기 2569년이 아니라).
    func testTheRequestUsesGregorianDatesOnABuddhistCalendar() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = calendar.timeZone
        XCTAssertEqual(DailyCardBubblePrompt.dayKey(at(8), calendar: buddhist), "2026-11-16")
        let request = DailyCardBubblePrompt.request(card: at(8), calendar: buddhist)
        XCTAssertEqual(request.context["cardDate"], "2026-11-16")
        XCTAssertEqual(request.context["readDate"], "2026-11-15")
    }

    func testAlreadySentOrDisabledSkips() {
        XCTAssertNil(DailyCardBubblePrompt.due(now: at(7, 30), time: eight, enabled: true, lastSent: "2026-11-16", calendar: calendar))
        XCTAssertEqual(DailyCardBubblePrompt.due(now: at(7, 30), time: eight, enabled: true, lastSent: "2026-11-15", calendar: calendar), at(8))
        XCTAssertNil(DailyCardBubblePrompt.due(now: at(7, 30), time: eight, enabled: false, lastSent: nil, calendar: calendar))
    }

    func testCardJustAfterMidnightUsesTheCardDay() throws {
        let time = DateComponents(hour: 0, minute: 30)
        let card = try XCTUnwrap(DailyCardBubblePrompt.due(now: at(23, 40, day: 15), time: time, enabled: true, lastSent: nil, calendar: calendar))
        XCTAssertEqual(card, at(0, 30, day: 16))
        XCTAssertEqual(DailyCardBubblePrompt.dayKey(card, calendar: calendar), "2026-11-16")
        XCTAssertNil(DailyCardBubblePrompt.due(now: at(0, 10, day: 16), time: time, enabled: true, lastSent: "2026-11-16", calendar: calendar))
        XCTAssertNil(DailyCardBubblePrompt.due(now: at(23, 29, day: 15), time: time, enabled: true, lastSent: nil, calendar: calendar))
        let request = DailyCardBubblePrompt.request(card: card, calendar: calendar)
        XCTAssertEqual(request.context["cardDate"], "2026-11-16")
        XCTAssertEqual(request.context["readDate"], "2026-11-15")
        XCTAssertEqual(request.context["cardTime"], "00:30")
        XCTAssertTrue(request.text.contains("get_activity로 2026-11-15"), request.text)
        XCTAssertTrue(request.text.contains("date 2026-11-16, kind \"event\""), request.text)
    }

    func testEarliestBeginPullsToTheWindowStartOnlyWhenEarlierAndAhead() {
        func begin(_ now: Date, _ fallback: Date, enabled: Bool = true) -> Date {
            DailyCardBubblePrompt.earliestBegin(now: now, defaultDate: fallback, time: eight, enabled: enabled, calendar: calendar)
        }
        XCTAssertEqual(begin(at(5), at(9)), at(7))
        XCTAssertEqual(begin(at(5), at(6)), at(6))
        XCTAssertEqual(begin(at(5), at(9), enabled: false), at(9))
        // 이미 창 안이면 당기지 않는다.
        XCTAssertEqual(begin(at(7, 30), at(8, 30)), at(8, 30))
    }

    func testRunEnqueuesOncePerCardDayAndSkipsWithoutConnection() throws {
        let store = defaults()
        store.set(8, forKey: MapHomeAlarmSettings.dailyCardHourKey)
        store.set(0, forKey: MapHomeAlarmSettings.dailyCardMinuteKey)
        // 연결이 없으면 넣지 않고 기억도 남기지 않는다.
        XCTAssertFalse(DailyCardBubblePrompt.runIfDue(now: at(7, 10), authorized: true, defaults: store, calendar: calendar))
        XCTAssertNil(store.string(forKey: DailyCardBubblePrompt.sentKey))
        XCTAssertTrue(AITaskQueue.pendingUploads(store).isEmpty)

        store.set(["key": "피클"], forKey: AssistantKeyLabels.labelsKey)
        // 알림 권한이 없으면 카드가 안 나가니 올리지 않는다.
        XCTAssertFalse(DailyCardBubblePrompt.runIfDue(now: at(7, 10), authorized: false, defaults: store, calendar: calendar))
        XCTAssertTrue(DailyCardBubblePrompt.runIfDue(now: at(7, 10), authorized: true, defaults: store, calendar: calendar))
        XCTAssertFalse(DailyCardBubblePrompt.runIfDue(now: at(7, 40), authorized: true, defaults: store, calendar: calendar))
        let uploads = AITaskQueue.pendingUploads(store)
        XCTAssertEqual(uploads.count, 1)
        let upload = try XCTUnwrap(uploads.first)
        XCTAssertEqual(upload.kind, .other)
        XCTAssertEqual(upload.context?["cardDate"], "2026-11-16")
        XCTAssertEqual(upload.context?["readDate"], "2026-11-15")
        XCTAssertEqual(store.string(forKey: DailyCardBubblePrompt.sentKey), "2026-11-16")
    }

    func testRunSkipsWhenTheDailyCardAlarmIsOff() {
        let store = defaults()
        store.set(["key": "피클"], forKey: AssistantKeyLabels.labelsKey)
        store.set(MapHomeAlarmSettings(enabled: [.wakeUp]).rawValue, forKey: MapHomeAlarmSettings.storageKey)
        XCTAssertFalse(DailyCardBubblePrompt.runIfDue(now: at(7, 10), authorized: true, defaults: store, calendar: calendar))
        XCTAssertTrue(AITaskQueue.pendingUploads(store).isEmpty)
    }

    /// HOF1118A01: 백그라운드 새로고침이 끝나기 전에 넣은 요청을 올린다(올리기를 기다린다).
    func testRunWaitsForTheUploadAfterEnqueueing() async {
        let store = defaults()
        store.set(["key": "피클"], forKey: AssistantKeyLabels.labelsKey)
        var uploads = 0
        await DailyCardBubblePrompt.run(now: at(7, 10), defaults: store, calendar: calendar, isAuthorized: { true }, upload: { uploads += 1 })
        XCTAssertEqual(uploads, 1, "the upload finished before run returned")
        XCTAssertEqual(AITaskQueue.pendingUploads(store).count, 1)
        // 이미 올린 날은 다시 넣지도 올리지도 않는다.
        await DailyCardBubblePrompt.run(now: at(7, 40), defaults: store, calendar: calendar, isAuthorized: { true }, upload: { uploads += 1 })
        XCTAssertEqual(uploads, 1)
    }
}
