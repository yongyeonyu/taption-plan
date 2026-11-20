import XCTest
@testable import TaptionPlan

/// RTA1120A01: 앱 전면 실시간 반영(끔/3초/1초) 값·반복·편집 보호·실패 표시·계획 카드.
@MainActor
final class AssistantLiveSyncTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "live-sync-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private final class Counter { var commands = 0, plans = 0, lights: [Bool] = []; var failed = false }

    private func hooks(_ c: Counter) -> AssistantLiveSync.Hooks {
        .init(commands: { light in c.commands += 1; c.lights.append(light) }, plan: { c.plans += 1 }, failed: { c.failed })
    }

    func testIntervalsFollowModeLowPowerAndHeat() {
        typealias S = AssistantLiveSync
        XCTAssertEqual(S.interval(mode: .three, lowPower: false, thermal: .nominal), 3)
        XCTAssertEqual(S.interval(mode: .one, lowPower: false, thermal: .nominal), 1)
        XCTAssertEqual(S.interval(mode: .one, lowPower: true, thermal: .nominal), 3, "저전력에서 1초는 3초")
        XCTAssertEqual(S.interval(mode: .one, lowPower: false, thermal: .serious), 10)
        XCTAssertEqual(S.interval(mode: .three, lowPower: false, thermal: .critical), 10)
        XCTAssertEqual(S.interval(mode: .off, lowPower: false, thermal: .nominal), AssistantCommandPolling.idleInterval)
    }

    func testDefaultIsThreeSecondsAndOneSecondFallsBackAfterThirtyMinutes() {
        let d = defaults(), t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertEqual(AssistantLiveSync.mode(defaults: d, now: t0), .three)
        AssistantLiveSync.setMode(.one, defaults: d, now: t0)
        XCTAssertEqual(AssistantLiveSync.mode(defaults: d, now: t0.addingTimeInterval(29 * 60)), .one)
        XCTAssertEqual(AssistantLiveSync.mode(defaults: d, now: t0.addingTimeInterval(31 * 60)), .three)
        XCTAssertEqual(AssistantLiveSync.mode(defaults: d, now: t0), .three, "돌아온 값이 저장된다")
        AssistantLiveSync.setMode(.off, defaults: d)
        XCTAssertEqual(AssistantLiveSync.mode(defaults: d), .off)
    }

    func testLoopDoesNotRefreshWhenSceneIsNotActive() async {
        var calls = 0
        await AssistantLiveSync.runLoop(isActive: { false }, interval: { 1 }, wait: { _ in }, refresh: { calls += 1 })
        XCTAssertEqual(calls, 0)
    }

    func testLoopWaitsTheIntervalBeforeEachRefreshAndStopsWhenInactive() async {
        var waits: [TimeInterval] = [], calls = 0, active = true
        await AssistantLiveSync.runLoop(isActive: { active }, interval: { 3 }, wait: { waits.append($0) }, refresh: { calls += 1; if calls == 3 { active = false } })
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(waits, [3, 3, 3, 3])
    }

    func testShortRefreshKeepsHeavyChoresOnTheFiveMinutePath() async {
        let sync = AssistantLiveSync(), c = Counter(), t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)
        await sync.refresh(reason: .poll, language: .current, hooks: hooks(c), now: t0)
        await sync.refresh(reason: .poll, language: .current, hooks: hooks(c), now: t0.addingTimeInterval(3))
        await sync.refresh(reason: .poll, language: .current, hooks: hooks(c), now: t0.addingTimeInterval(6))
        XCTAssertEqual(c.lights, [false, true, true], "처음 한 번만 무거운 곁일, 이후 3초 확인은 가볍게")
        await sync.refresh(reason: .poll, language: .current, hooks: hooks(c), now: t0.addingTimeInterval(301))
        XCTAssertEqual(c.lights.last, false, "5분이 지나면 다시 무거운 곁일")
    }

    func testRefreshDefersWhileEditingThenApplies() async {
        let sync = AssistantLiveSync(), c = Counter()
        sync.beginEditing()
        await sync.refresh(reason: .poll, language: .current, hooks: hooks(c))
        XCTAssertEqual(c.commands, 0, "편집 중에는 반영하지 않고 서버 큐에 둔다")
        sync.endEditing()
        await sync.refresh(reason: .poll, language: .current, hooks: hooks(c))
        XCTAssertEqual(c.commands, 1)
    }

    func testPlanIsCheckedOnlyWhileTravelScreenIsOpen() async {
        let sync = AssistantLiveSync(), c = Counter()
        await sync.refresh(reason: .poll, language: .current, hooks: hooks(c))
        XCTAssertEqual(c.plans, 0)
        sync.hold("travel")
        await sync.refresh(reason: .poll, language: .current, hooks: hooks(c))
        XCTAssertEqual(c.plans, 1)
        sync.release("travel")
        await sync.refresh(reason: .poll, language: .current, hooks: hooks(c))
        XCTAssertEqual(c.plans, 1)
    }

    func testNewPlanBecomesCardOnceAndSameHashIsNotShownAgain() {
        let sync = AssistantLiveSync(), d = defaults()
        sync.offer(plan: "{\"a\":1}", defaults: d)
        XCTAssertEqual(sync.pendingPlan, "{\"a\":1}")
        sync.dismissPlan()
        sync.offer(plan: "{\"a\":1}", defaults: d)
        XCTAssertNil(sync.pendingPlan, "같은 내용은 다시 뜨지 않는다")
        sync.offer(plan: "{\"a\":2}", defaults: d)
        sync.acceptPlan()
        XCTAssertEqual(sync.acceptedPlan, "{\"a\":2}")
        XCTAssertNil(sync.pendingPlan)
    }

    func testFailureLineAppearsAfterThreeInARowOncePerFiveMinutes() {
        let sync = AssistantLiveSync(), t0 = Date(timeIntervalSinceReferenceDate: 3_000_000)
        AssistantInbox.current.show(nil)
        sync.record(failed: true, language: .current, now: t0)
        sync.record(failed: true, language: .current, now: t0.addingTimeInterval(3))
        XCTAssertNil(AssistantInbox.current.notice)
        sync.record(failed: true, language: .current, now: t0.addingTimeInterval(6))
        XCTAssertNotNil(AssistantInbox.current.notice)
        AssistantInbox.current.show(nil)
        sync.record(failed: true, language: .current, now: t0.addingTimeInterval(9))
        XCTAssertNil(AssistantInbox.current.notice, "5분 안에는 다시 띄우지 않는다")
        sync.record(failed: true, language: .current, now: t0.addingTimeInterval(400))
        XCTAssertNotNil(AssistantInbox.current.notice)
        sync.record(failed: false, language: .current, now: t0.addingTimeInterval(403))
        XCTAssertNil(AssistantInbox.current.notice, "성공하면 거둔다")
    }
}
