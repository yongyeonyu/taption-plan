import Synchronization
import XCTest
@testable import TaptionPlan

/// RTA1120A02: 앱의 실시간 소켓. 가짜 소켓·가짜 시계만 쓰고 네트워크는 타지 않는다.
@MainActor
final class AssistantRealtimeTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "realtime-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    /// 미리 정한 글자를 차례로 돌려주고, 다 주면 오류(연결 끊김)를 던진다.
    private final class ScriptedSocket: AssistantSocket {
        private struct State { var script: [String]; var cancelled = false; var sent: [String] = [] }
        private let state: Mutex<State>
        init(_ script: [String]) { state = Mutex(State(script: script)) }
        var cancelled: Bool { state.withLock { $0.cancelled } }
        func receive() async throws -> String {
            guard let next = state.withLock({ $0.script.isEmpty ? nil : $0.script.removeFirst() }) else { throw URLError(.networkConnectionLost) }
            return next
        }
        func send(_ text: String) async throws { state.withLock { $0.sent.append(text) } }
        func cancel() { state.withLock { $0.cancelled = true } }
    }

    func testParseReadsKnownMessagesAndIgnoresJunk() {
        XCTAssertEqual(AssistantRealtimeMessage.parse(#"{"type":"hello","latest":412,"oldest":213,"now":1}"#), .hello(latest: 412, oldest: 213))
        XCTAssertEqual(AssistantRealtimeMessage.parse(#"{"type":"cmd","e":7,"id":"c1","kind":"addMemo","at":1}"#), .event(RealtimeEvent(e: 7, type: "cmd", entity: nil, id: "c1")))
        XCTAssertEqual(AssistantRealtimeMessage.parse(#"{"type":"patch","e":8,"entity":"plan","at":1}"#), .event(RealtimeEvent(e: 8, type: "patch", entity: "plan", id: nil)))
        XCTAssertEqual(AssistantRealtimeMessage.parse(#"{"type":"resync"}"#), .resync)
        XCTAssertEqual(AssistantRealtimeMessage.parse(#"{"type":"ready","latest":9}"#), .ready(latest: 9))
        for junk in ["null", "pong", "{bad", "[]", #"{"type":5}"#, #"{"type":"nope"}"#, String(repeating: "x", count: 200_000)] {
            XCTAssertNil(AssistantRealtimeMessage.parse(junk), junk.prefix(20).description)
        }
    }

    func testHelloLatestIsNotUsedAsCursorUntilEventsAreAllReceived() {
        var cursor = AssistantRealtimeCursor(value: 3)
        cursor.beginConnection()
        XCTAssertEqual(cursor.apply(.hello(latest: 10, oldest: 1)), [])
        XCTAssertEqual(cursor.value, 3, "hello만으로는 커서가 앞서지 않는다")
        XCTAssertEqual(cursor.apply(.events([RealtimeEvent(e: 4, type: "cmd", entity: nil, id: "a"), RealtimeEvent(e: 5, type: "cmd", entity: nil, id: "b")], more: true)), [.refresh], "같은 종류는 한 번만")
        XCTAssertEqual(cursor.value, 5)
        _ = cursor.apply(.ready(latest: 10))
        XCTAssertEqual(cursor.value, 10)
        XCTAssertEqual(cursor.apply(.event(RealtimeEvent(e: 9, type: "cmd", entity: nil, id: "old"))), [], "이미 본 이벤트는 다시 일하지 않는다")
        XCTAssertEqual(cursor.apply(.resync), [.fullRefresh])
        XCTAssertEqual(cursor.value, 0)
    }

    func testPatchEntitiesMapToOnlyTheScreensThatNeedThem() {
        func act(_ entity: String) -> AssistantRealtimeAction? { AssistantRealtimeCursor.action(for: RealtimeEvent(e: 1, type: "patch", entity: entity, id: nil)) }
        XCTAssertEqual(act("plan"), .refresh)
        XCTAssertEqual(act("tasks"), .tasks)
        XCTAssertEqual(act("rules"), .rules)
        XCTAssertNil(act("day")); XCTAssertNil(act("memo")); XCTAssertNil(act("app"))
    }

    func testBackoffGrowsFromOneSecondToSixtyWithJitter() {
        XCTAssertEqual(AssistantRealtimeBackoff.delay(attempt: 1, jitter: 0), 1)
        XCTAssertEqual(AssistantRealtimeBackoff.delay(attempt: 4, jitter: 0), 8)
        XCTAssertEqual(AssistantRealtimeBackoff.delay(attempt: 20, jitter: 0), 60)
        XCTAssertEqual(AssistantRealtimeBackoff.delay(attempt: 2, jitter: 0.25), 2.5)
    }

    func testCommandEventRefreshesOnceAndCursorIsSavedAndRestored() async {
        let d = defaults()
        let realtime = AssistantRealtime()
        let socket = ScriptedSocket([#"{"type":"hello","latest":2,"oldest":1,"now":1}"#, #"{"type":"cmd","e":1,"id":"c1","kind":"addMemo","at":1}"#, "pong", #"{"type":"cmd","e":1,"id":"c1","kind":"addMemo","at":1}"#, #"{"type":"ready","latest":2}"#])
        var applied: [AssistantRealtimeAction] = []
        var sockets = 0
        await realtime.run(defaults: d, makeSocket: { since in
            sockets += 1
            XCTAssertEqual(since, 0)
            return sockets == 1 ? socket : nil
        }, wait: { _ in withUnsafeCurrentTask { $0?.cancel() } }, apply: { applied.append($0) })
        XCTAssertEqual(applied, [.refresh], "같은 이벤트 두 번 → 반영 1회")
        XCTAssertEqual(d.integer(forKey: AssistantRealtime.cursorKey), 2)
        XCTAssertTrue(socket.cancelled)
        XCTAssertFalse(realtime.isConnected)
    }

    func testDisabledToggleOrOffModeNeverOpensASocket() async {
        let d = defaults()
        AssistantRealtime.setEnabled(false, defaults: d)
        var opened = 0
        await AssistantRealtime().run(defaults: d, makeSocket: { _ in opened += 1; return nil }, wait: { _ in withUnsafeCurrentTask { $0?.cancel() } }, apply: { _ in })
        XCTAssertEqual(opened, 0, "토글 끔 → 소켓 0개")
        AssistantRealtime.setEnabled(true, defaults: d)
        AssistantLiveSync.setMode(.off, defaults: d)
        await AssistantRealtime().run(defaults: d, makeSocket: { _ in opened += 1; return nil }, wait: { _ in withUnsafeCurrentTask { $0?.cancel() } }, apply: { _ in })
        XCTAssertEqual(opened, 0, "세그먼트 끔 → 소켓 0개")
    }

    func testThreeFailedConnectionsFallBackToPollingAndRetryOnlyAfterThirtyMinutes() async {
        let d = defaults()
        let realtime = AssistantRealtime()
        var waits: [TimeInterval] = []
        var sockets = 0
        await realtime.run(defaults: d, makeSocket: { _ in sockets += 1; return ScriptedSocket([]) }, wait: { seconds in
            waits.append(seconds)
            if seconds >= AssistantRealtime.retryAfterDown { withUnsafeCurrentTask { $0?.cancel() } }
        }, apply: { _ in })
        XCTAssertEqual(sockets, 3)
        XCTAssertTrue(realtime.isDown)
        XCTAssertEqual(waits.last, AssistantRealtime.retryAfterDown)
        XCTAssertFalse(realtime.isConnected, "끊기면 짧은 폴링이 다시 맡는다")
    }

    func testLiveIntervalDropsToSafetyNetOnlyWhileConnected() async {
        let realtime = AssistantRealtime.shared
        XCTAssertFalse(realtime.isConnected)
        XCTAssertEqual(AssistantLiveSync.liveInterval(), AssistantLiveSync.interval(mode: AssistantLiveSync.mode(), lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState))
    }
}
