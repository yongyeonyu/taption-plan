import CoreLocation
import XCTest
@testable import TaptionPlan

/// GPS가 끊겼을 때 화랑이를 둘 자리(LOC1104A01). 좌표는 지어낸 값이다.
final class MapHomeLastKnownLocationPolicyTests: XCTestCase {
    private func point(_ latitude: Double, _ longitude: Double = 20, accuracy: Double = 8) -> GeoPoint {
        GeoPoint(latitude: latitude, longitude: longitude, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 4)
    }

    private func coordinate(_ latitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: 20)
    }

    // MARK: 마지막 위치 후보

    func testTakesTheFirstCandidateThatHasAPoint() {
        let found = MapHomeLastKnownLocationPolicy.point(candidates: [{ nil }, { self.point(11) }, { self.point(12) }])
        XCTAssertEqual(found?.latitude, 11, "최신 센서에 위치가 없으면 다음 후보(실시간 경로)의 마지막 점")
    }

    func testSkipsPointsThatCannotBeDrawn() {
        let found = MapHomeLastKnownLocationPolicy.point(candidates: [
            { self.point(11, accuracy: -1) }, { self.point(91) }, { self.point(12, 181) }, { self.point(13) },
        ])
        XCTAssertEqual(found?.latitude, 13, "정확도 없음·범위 밖 좌표는 건너뛴다")
        XCTAssertTrue(MapHomeLastKnownLocationPolicy.isValid(point(-90, -180, accuracy: 0)), "경계값은 쓴다")
    }

    func testDoesNotEvaluateLaterCandidatesOnceFound() {
        var evaluatedLater = false
        let found = MapHomeLastKnownLocationPolicy.point(candidates: [{ self.point(11) }, { evaluatedLater = true; return self.point(12) }])
        XCTAssertEqual(found?.latitude, 11)
        XCTAssertFalse(evaluatedLater, "앞에서 정해지면 하루치 병합은 계산하지 않는다")
    }

    func testNoCandidateMeansNoLocation() {
        XCTAssertNil(MapHomeLastKnownLocationPolicy.point(candidates: []))
        XCTAssertNil(MapHomeLastKnownLocationPolicy.point(candidates: [{ nil }, { self.point(11, accuracy: -1) }]))
    }

    // MARK: 화면에 둘 자리

    private func displayed(
        isToday: Bool, selected: Bool, playback: Double? = nil, loaded: Bool = true, live: Double? = 30, lastRecorded: Double? = 40
    ) -> Double? {
        MapHomeLastKnownLocationPolicy.displayed(
            isToday: isToday, hasSelectedMinute: selected,
            playback: { playback.map(self.coordinate) }, isDayLoaded: loaded,
            live: { live.map(self.coordinate) }, lastRecorded: { lastRecorded.map(self.coordinate) }
        )?.latitude
    }

    func testTodayWithoutSelectionStaysOnLiveOrLastKnownLocation() {
        XCTAssertEqual(displayed(isToday: true, selected: false), 30, "GPS가 끊겨도 오늘은 마지막 위치에 둔다")
        XCTAssertNil(displayed(isToday: true, selected: false, live: nil), "한 번도 위치를 못 받았으면 그리지 않는다")
    }

    func testOtherDayWithoutSelectionShowsNothing() {
        XCTAssertNil(displayed(isToday: false, selected: false))
    }

    func testSelectedMinuteUsesItsOwnLocationFirst() {
        XCTAssertEqual(displayed(isToday: true, selected: true, playback: 50), 50)
        XCTAssertEqual(displayed(isToday: false, selected: true, playback: 50), 50)
    }

    func testSelectedMinuteWithoutLocationFallsBackByDay() {
        XCTAssertEqual(displayed(isToday: true, selected: true), 30, "오늘은 마지막 위치")
        XCTAssertEqual(displayed(isToday: false, selected: true), 40, "다른 날은 그 시각까지 기록된 마지막 자리")
        XCTAssertNil(displayed(isToday: false, selected: true, loaded: false), "불러오는 중에는 전날 기록을 쓰지 않는다")
        XCTAssertNil(displayed(isToday: false, selected: true, lastRecorded: nil), "그날 첫 기록보다 이르면 그리지 않는다")
    }
}
