import XCTest
@testable import TaptionPlan

/// 같은 입력이면 예상 경로를 다시 만들지 않는다(LAG1107A01).
final class MapHomeExpectedRouteRefreshGateTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_794_355_200)

    private func readings(_ count: Int) -> [SensorReading] {
        (0..<count).map {
            SensorReading(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0)) ?? UUID(),
                timestamp: day.addingTimeInterval(Double($0) * 60)
            )
        }
    }

    private func signature(
        readings count: Int, places: [PlaceStay] = [], sleep: [TimeSpan] = [], interval: TimeInterval = 60
    ) -> MapHomeExpectedRouteBuildSignature {
        // 부를 때마다 배열을 새로 만든다. 세대가 바뀌어 새로 읽은 자료도 내용이 같으면 같은 입력이어야 한다.
        let readings = readings(count)
        return MapHomeExpectedRouteBuildSignature(
            selectedDay: day, dayEnd: day.addingTimeInterval(86_400), isPreview: false,
            travel: [], places: places, actuals: [],
            normalizedReadings: readings, playbackReadings: readings,
            sleepSessions: [], confirmedSleepSpans: sleep, gpsLoggingInterval: interval
        )
    }

    /// 시작 흐름을 흉내 낸다: 요청이 올 때마다 문을 지나고, 지난 것은 끝까지 만들어 화면에 올린다.
    private func builds(_ requests: [MapHomeExpectedRouteBuildSignature]) -> (built: Int, skipped: Int) {
        var gate = MapHomeExpectedRouteRefreshGate<MapHomeExpectedRouteBuildSignature>()
        var displayed: MapHomeExpectedRouteBuildSignature?
        for request in requests where gate.begin(request, isDisplayed: displayed == request) {
            displayed = request
            gate.complete(request)
        }
        return (gate.builtCount, gate.skippedCount)
    }

    /// 기기 로그(빌드 290, 2초에 6번)의 모양: 표본 1개 → 하루 자료(장소) 도착 → 표본 6개로 네 번.
    func testStartupBurstBuildsOncePerDistinctInput() {
        let home = [PlaceStay(placeKey: "home", displayName: "집", span: TimeSpan(start: day, end: day.addingTimeInterval(3_600)), confidence: .high)]
        let burst = [
            signature(readings: 1), signature(readings: 1, places: home), signature(readings: 6, places: home),
            signature(readings: 6, places: home), signature(readings: 6, places: home), signature(readings: 6, places: home),
        ]
        let result = builds(burst)
        XCTAssertEqual(result.built, 3, "입력이 다른 세 번만 만든다")
        XCTAssertEqual(result.skipped, 3, "같은 입력 세 번은 건너뛴다")
    }

    func testChangedInputAlwaysBuilds() {
        let base = signature(readings: 6)
        let sleep = TimeSpan(start: day, end: day.addingTimeInterval(3_600))
        XCTAssertEqual(builds([base, signature(readings: 7)]).built, 2, "새 위치 표본")
        XCTAssertEqual(builds([base, signature(readings: 6, sleep: [sleep])]).built, 2, "수면 확정")
        XCTAssertEqual(builds([base, signature(readings: 6, interval: 5)]).built, 2, "기록 간격")
        XCTAssertEqual(builds([base, signature(readings: 7), base]).built, 3, "되돌아온 입력도 화면이 바뀌었으니 다시 만든다")
        XCTAssertEqual(signature(readings: 7).changedFields(from: base), ["normalized_readings", "playback_readings"])
        XCTAssertEqual(signature(readings: 6, sleep: [sleep]).changedFields(from: base), ["sleep"])
        XCTAssertEqual(signature(readings: 6).changedFields(from: base), [])
    }

    /// 시뮬레이터 시작에서 잰 모양: 하루를 다시 판정해 머문 곳의 ID만 새로 매겨졌다.
    func testRenumberedPlaceIDsAreTheSameInput() {
        func home(_ end: TimeInterval = 3_600) -> [PlaceStay] {
            [PlaceStay(placeKey: "home", displayName: "집", span: TimeSpan(start: day, end: day.addingTimeInterval(end)), confidence: .high)]
        }
        let first = signature(readings: 5, places: home()), second = signature(readings: 5, places: home())
        XCTAssertNotEqual(first.places, second.places, "ID는 다르다")
        XCTAssertEqual(builds([first, second]).built, 1)
        XCTAssertEqual(builds([first, signature(readings: 5, places: home(7_200))]).built, 2, "머문 시간이 달라지면 다시 만든다")
        XCTAssertEqual(builds([first, signature(readings: 5)]).built, 2, "머문 곳 수가 달라지면 다시 만든다")
    }

    func testUnfinishedOrClearedResultIsBuiltAgain() {
        var gate = MapHomeExpectedRouteRefreshGate<Int>()
        XCTAssertTrue(gate.begin(1, isDisplayed: false))
        XCTAssertTrue(gate.begin(1, isDisplayed: true), "끝까지 만들지 못한 것은 다시 만든다")
        gate.complete(1)
        XCTAssertFalse(gate.begin(1, isDisplayed: true))
        XCTAssertTrue(gate.begin(1, isDisplayed: false), "화면에서 지워졌으면 다시 만든다")
        gate.complete(1)
        gate.invalidate()
        XCTAssertTrue(gate.begin(1, isDisplayed: true), "앱이 뒤로 갔다 오면 다시 만든다")
        gate.complete(1)
        XCTAssertTrue(gate.begin(2, isDisplayed: true))
        XCTAssertTrue(gate.begin(1, isDisplayed: true), "다른 입력을 만들다 끊겼으면 앞 결과를 믿지 않는다")
        XCTAssertEqual(gate.builtCount, 6)
        XCTAssertEqual(gate.skippedCount, 1)
    }
}
