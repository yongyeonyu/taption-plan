import CoreLocation
import XCTest
@testable import TaptionPlan

/// PLR1104A01: 여러 날 구간을 고른 영상 길이에 맞춘다.
final class MapHomeRangePlaybackTests: XCTestCase {
    private typealias Plan = MapHomeRangeTripPlan

    private let start = Date(timeIntervalSince1970: 1_750_000_000)
    private var span: TimeSpan { TimeSpan(start: start, end: start.addingTimeInterval(4 * 86_400)) }

    private func sample(_ minutes: Double, _ latitude: Double, _ longitude: Double) -> Plan.Sample {
        Plan.Sample(time: start.timeIntervalSinceReferenceDate + minutes * 60, latitude: latitude, longitude: longitude)
    }

    /// 머물고, 조금 걸어 옮기고, 또 머문다.
    private func localTrip() -> [Plan.Sample] {
        var samples = stride(from: 0.0, through: 60, by: 5).map { sample($0, 13.75, 100.50) }
        samples += (1...20).map { sample(60 + Double($0), 13.75 + Double($0) * 0.001, 100.50) }
        samples += stride(from: 85.0, through: 200, by: 5).map { sample($0, 13.77, 100.50) }
        return samples
    }

    /// 서울에 머물다 비행(표본 없음)으로 방콕에 도착해 머문다.
    private func flightTrip() -> [Plan.Sample] {
        var samples = stride(from: 0.0, through: 60, by: 5).map { sample($0, 37.46, 126.44) }
        samples += stride(from: 400.0, through: 500, by: 5).map { sample($0, 13.69, 100.75) }
        return samples
    }

    func testFrameCountDependsOnlyOnChosenLength() throws {
        let short = try XCTUnwrap(Plan.make(samples: localTrip(), span: span, durationSeconds: 30))
        let long = try XCTUnwrap(Plan.make(samples: localTrip(), span: span, durationSeconds: 60))
        XCTAssertEqual(short.frames(fps: 60).count, 1_800)
        XCTAssertEqual(long.frames(fps: 60).count, 3_600)
    }

    func testItemsFillBodyWithoutGapsAndTimeIncreases() throws {
        let plan = try XCTUnwrap(Plan.make(samples: localTrip(), span: span, durationSeconds: 60))
        XCTAssertEqual(plan.items.first?.startSecond ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(plan.items.last?.endSecond ?? -1, plan.bodySeconds, accuracy: 0.001)
        for (first, second) in zip(plan.items, plan.items.dropFirst()) {
            XCTAssertEqual(first.endSecond, second.startSecond, accuracy: 0.001)
        }
        var previous = -Double.infinity
        for second in stride(from: 0.0, to: plan.bodySeconds, by: 0.25) {
            let position = try XCTUnwrap(plan.position(atSecond: second))
            XCTAssertGreaterThanOrEqual(position.time, previous)
            previous = position.time
        }
    }

    func testStaysAreShortAndMovesTakeTheTime() throws {
        let plan = try XCTUnwrap(Plan.make(samples: localTrip(), span: span, durationSeconds: 60))
        XCTAssertEqual(plan.items.map(\.kind), [.stay, .move, .stay])
        XCTAssertEqual(plan.items[0].endSecond - plan.items[0].startSecond, Plan.Tuning.staySeconds, accuracy: 0.001)
        XCTAssertGreaterThan(plan.items[1].endSecond - plan.items[1].startSecond, 50)
    }

    func testFlightFollowsGreatCircleAndIsCapped() throws {
        var samples = flightTrip()
        // 도착 뒤 긴 이동이 더 있어야 비행 상한이 적용된다.
        samples += (1...40).map { sample(500 + Double($0), 13.69 + Double($0) * 0.002, 100.75) }
        samples += stride(from: 545.0, through: 600, by: 5).map { sample($0, 13.77, 100.75) }
        let plan = try XCTUnwrap(Plan.make(samples: samples, span: span, durationSeconds: 60))
        let flight = try XCTUnwrap(plan.items.first { $0.kind == .flight })
        XCTAssertLessThanOrEqual(flight.endSecond - flight.startSecond, Plan.Tuning.flightSecondsLimit + 0.001)
        let middle = flight.points[flight.points.count / 2]
        // 대권 경로의 가운데는 위경도 직선의 가운데와 다르다.
        XCTAssertGreaterThan(abs(middle.latitude - (37.46 + 13.69) / 2), 0.3)
        // 전체 경로를 담으려면 예전 상한(약 336km)보다 훨씬 멀어야 한다.
        XCTAssertGreaterThan(plan.overviewDistance, 3_000_000)
    }

    func testIsolatedJumpIsRemoved() {
        let samples = [
            sample(0, 13.75, 100.50), sample(1, 13.7501, 100.50),
            sample(2, 35.0, 139.0),
            sample(3, 13.7502, 100.50), sample(4, 13.7503, 100.50),
        ]
        XCTAssertEqual(Plan.removingIsolatedJumps(samples).count, 4)
    }

    func testRoutePointsStayUnderLimit() throws {
        let samples: [Plan.Sample] = (0..<20_000).map { index in
            let step = Double(index)
            let zigzag: Double = index % 2 == 0 ? 0.003 : 0
            return sample(step * 0.2, 13.0 + step * 0.0002 + zigzag, 100.0 + step * 0.0002)
        }
        let plan = try XCTUnwrap(Plan.make(samples: samples, span: span, durationSeconds: 60))
        XCTAssertLessThanOrEqual(plan.route.count, Plan.Tuning.maximumRoutePoints + Plan.Tuning.flightSegments)
    }

    /// 한 달을 1분 간격으로 받아도 계획은 바로 만들어져야 한다.
    func testMonthOfSamplesBuildsQuickly() throws {
        let samples: [Plan.Sample] = (0..<44_640).map { index in
            let step = Double(index)
            let zigzag: Double = index % 2 == 0 ? 0.003 : 0
            return sample(step, 13.0 + step * 0.0001 + zigzag, 100.0 + step * 0.0001)
        }
        let started = Date()
        let plan = try XCTUnwrap(Plan.make(samples: samples, span: span, durationSeconds: 90))
        XCTAssertEqual(plan.frames(fps: 60).count, 5_400)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    func testRoutePointTimesIncreaseAndMatchPositions() throws {
        let plan = try XCTUnwrap(Plan.make(samples: localTrip(), span: span, durationSeconds: 60))
        for (first, second) in zip(plan.route, plan.route.dropFirst()) {
            XCTAssertLessThanOrEqual(first.second, second.second)
        }
    }

    func testFramesAreDeterministicAndEndOnOverview() throws {
        let plan = try XCTUnwrap(Plan.make(samples: flightTrip(), span: span, durationSeconds: 30))
        let first = plan.frames(fps: 60), second = plan.frames(fps: 60)
        for (lhs, rhs) in zip(first, second) {
            XCTAssertEqual(lhs.cameraDistance, rhs.cameraDistance)
            XCTAssertEqual(lhs.coordinate?.latitude, rhs.coordinate?.latitude)
        }
        let last = try XCTUnwrap(first.last)
        XCTAssertEqual(last.cameraDistance, plan.overviewDistance, accuracy: plan.overviewDistance * 0.001)
        XCTAssertEqual(try XCTUnwrap(last.coordinate?.latitude), plan.overviewCenter.latitude, accuracy: 0.001)
    }

    func testDateLineFlightDoesNotSpanTheWorld() throws {
        var samples = stride(from: 0.0, through: 60, by: 5).map { sample($0, 21.3, -157.9) }
        samples += stride(from: 500.0, through: 600, by: 5).map { sample($0, 35.5, 139.8) }
        let plan = try XCTUnwrap(Plan.make(samples: samples, span: span, durationSeconds: 30))
        // 호놀룰루-도쿄는 태평양을 건넌다. 중심 경도가 태평양 쪽이어야 한다.
        XCTAssertGreaterThan(abs(plan.overviewCenter.longitude), 150)
    }

    func testHiddenPlaceLeavesNoTrace() throws {
        let home = Plan.Point(latitude: 13.75, longitude: 100.50)
        let plan = try XCTUnwrap(Plan.make(samples: localTrip(), span: span, durationSeconds: 60, hiddenPlaces: [home]))
        for item in plan.items {
            for point in item.points {
                XCTAssertGreaterThan(Plan.meters(point, home), Plan.Tuning.hiddenPlaceMeters)
            }
        }
        XCTAssertGreaterThan(Plan.meters(plan.overviewCenter, home), Plan.Tuning.hiddenPlaceMeters)
    }

    func testDayFramesHoldOutsideHiddenPlace() throws {
        let home = Plan.Point(latitude: 13.75, longitude: 100.50)
        let inside = CLLocationCoordinate2D(latitude: 13.75, longitude: 100.50)
        let outsideA = CLLocationCoordinate2D(latitude: 13.76, longitude: 100.50)
        let outsideB = CLLocationCoordinate2D(latitude: 13.77, longitude: 100.50)
        let frames: [MapHomePlaybackTimeline.Frame] = [inside, outsideA, inside, outsideB, inside].enumerated().map {
            (Double($0.offset), $0.element, 1_000)
        }
        let latitudes = Plan.masked(frames, hiddenPlaces: [home]).map { $0.coordinate?.latitude }
        XCTAssertEqual(latitudes, [13.76, 13.76, 13.76, 13.77, 13.77])
        XCTAssertEqual(Plan.masked(frames, hiddenPlaces: []).first?.coordinate?.latitude, 13.75)
    }

    func testDayEntirelyInsideHiddenPlaceHasNoFrames() {
        let home = Plan.Point(latitude: 13.75, longitude: 100.50)
        let frames: [MapHomePlaybackTimeline.Frame] = [
            (0, CLLocationCoordinate2D(latitude: 13.75, longitude: 100.50), 1_000),
        ]
        XCTAssertTrue(Plan.masked(frames, hiddenPlaces: [home]).isEmpty)
    }

    func testAutomaticLength() {
        XCTAssertEqual(MapHomeRangePreset.automaticSeconds(forDays: 4), 60)
        XCTAssertEqual(MapHomeRangePreset.automaticSeconds(forDays: 31), 90)
        XCTAssertEqual(MapHomeRangePreset.automaticSeconds(forDays: 365), 120)
    }

    func testFlightOnlyTripGivesLeftoverToStays() throws {
        let plan = try XCTUnwrap(Plan.make(samples: flightTrip(), span: span, durationSeconds: 60))
        let flight = try XCTUnwrap(plan.items.first { $0.kind == .flight })
        XCTAssertEqual(plan.items.last?.endSecond ?? 0, plan.bodySeconds, accuracy: 0.001)
        XCTAssertEqual(flight.endSecond - flight.startSecond, Plan.Tuning.flightSecondsLimit, accuracy: 0.001)
    }

    func testNoSamplesMakesNoPlan() {
        XCTAssertNil(Plan.make(samples: [], span: span, durationSeconds: 60))
    }

    func testSingleSpotStillMakesPlan() throws {
        let samples = stride(from: 0.0, through: 60, by: 5).map { sample($0, 13.75, 100.50) }
        let plan = try XCTUnwrap(Plan.make(samples: samples, span: span, durationSeconds: 30))
        XCTAssertEqual(plan.frames(fps: 60).count, 1_800)
        XCTAssertEqual(plan.totalMeters, 0)
    }

    func testPresetSpans() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 15)))
        let last = MapHomeRangePreset.lastMonth.span(selectedDate: now, customStart: now, customEnd: now, now: now, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.month, .day], from: last.start), DateComponents(month: 10, day: 1))
        XCTAssertEqual(calendar.dateComponents([.month, .day], from: last.end), DateComponents(month: 11, day: 1))
        let recent = MapHomeRangePreset.recentSevenDays.span(selectedDate: now, customStart: now, customEnd: now, now: now, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.month, .day], from: recent.start), DateComponents(month: 10, day: 29))
        XCTAssertEqual(recent.end, now)
        let early = try XCTUnwrap(calendar.date(byAdding: .day, value: -200, to: now))
        let custom = MapHomeRangePreset.custom.span(selectedDate: now, customStart: early, customEnd: now, now: now, calendar: calendar)
        XCTAssertEqual(custom.duration, Double(MapHomeRangePreset.maximumDays) * 86_400, accuracy: 3_600)
    }
}
