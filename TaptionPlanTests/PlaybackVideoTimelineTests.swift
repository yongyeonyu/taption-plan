import CoreLocation
import XCTest
@testable import TaptionPlan

/// VID1029A01: 영상 렌더용 재생 타임라인은 1/fps초씩 결정적으로 전진한다.
@MainActor
final class PlaybackVideoTimelineTests: XCTestCase {
    private let dayStart = Calendar.autoupdatingCurrent.startOfDay(
        for: Date(timeIntervalSince1970: 1_750_000_000)
    )

    private func inputs(
        end: Double = 600,
        ranges: [MapHomePlaybackMovementRange] = [],
        readings: [SensorReading] = []
    ) -> MapHomePlaybackDriver.Inputs {
        MapHomePlaybackDriver.Inputs(
            startMinute: 0,
            endMinute: end,
            movingRanges: ranges,
            dayStart: dayStart,
            readings: readings,
            travel: [],
            places: [],
            zoomPlan: MapHomePlaybackZoomPlan(inputs: [])
        )
    }

    /// 10분마다 조금씩 북쪽으로 옮겨 가는 센서 기록.
    private func readings() -> [SensorReading] {
        (0...60).map { index in
            SensorReading(
                timestamp: dayStart.addingTimeInterval(Double(index) * 600),
                point: GeoPoint(latitude: 37.5 + Double(index) * 0.001, longitude: 127.0, altitude: 20,
                                horizontalAccuracy: 5, verticalAccuracy: 3),
                motion: .walking, motionConfidence: .high, sequence: index
            )
        }
    }

    private func timeline(_ inputs: MapHomePlaybackDriver.Inputs) -> MapHomePlaybackTimeline {
        MapHomePlaybackTimeline(inputs: inputs, projection: nil)
    }

    func testStationarySpanFrameCount() {
        let rate = MapHomeDayPlaybackMath.stationaryMinutesPerSecond
        let frames = Array(timeline(inputs()).frames(fps: 60))
        // 초당 120분이면 600분은 5초, 60fps로 300프레임.
        XCTAssertEqual(frames.count, Int((600 / rate * 60).rounded()))
        if rate == 120 { XCTAssertEqual(frames.count, 300) }
        XCTAssertEqual(frames.last?.minute ?? 0, 600, accuracy: 0.000_001)
    }

    func testMovingRangeSlowsPlayback() {
        let stationary = MapHomeDayPlaybackMath.stationaryMinutesPerSecond
        let moving = MapHomeDayPlaybackMath.movingMinutesPerSecond
        let range = MapHomePlaybackMovementRange(startMinute: 100, endMinute: 110)
        let frames = Array(timeline(inputs(ranges: [range])).frames(fps: 60))
        let seconds = 100 / stationary + 10 / moving + 490 / stationary
        XCTAssertEqual(frames.count, Int((seconds * 60).rounded()))
    }

    func testMinutesIncreaseMonotonically() {
        let range = MapHomePlaybackMovementRange(startMinute: 200, endMinute: 230, mode: .walking)
        let minutes = timeline(inputs(ranges: [range])).frames(fps: 60).map(\.minute)
        XCTAssertFalse(minutes.isEmpty)
        for (previous, next) in zip(minutes, minutes.dropFirst()) {
            XCTAssertGreaterThan(next, previous)
        }
    }

    func testCoordinatesMatchResolveOrGap() throws {
        let sample = readings()
        var raw = timeline(inputs(readings: sample))
        raw.smoothsPath = false
        let frames = Array(raw.frames(fps: 60))
        for index in stride(from: 0, to: frames.count, by: 37) {
            let frame = frames[index]
            let date = dayStart.addingTimeInterval(frame.minute * 60)
            let expected = try XCTUnwrap(MapHomePlaybackLocation.resolveOrGap(
                at: date, frame: nil, normalizedReadings: sample, travel: [], places: []
            )).cameraCoordinate
            let actual = try XCTUnwrap(frame.coordinate)
            XCTAssertEqual(actual.latitude, expected.latitude, accuracy: 0.000_000_1)
            XCTAssertEqual(actual.longitude, expected.longitude, accuracy: 0.000_000_1)
        }
    }

    func testNoPositionKeepsCameraDistance() {
        let frames = Array(timeline(inputs()).frames(fps: 60))
        XCTAssertTrue(frames.allSatisfy { $0.coordinate == nil })
        XCTAssertTrue(frames.allSatisfy { $0.cameraDistance == MapHomeStartupCameraPolicy.distance })
    }

    func testOutputIsDeterministic() {
        let range = MapHomePlaybackMovementRange(startMinute: 120, endMinute: 180, mode: .car)
        let line = timeline(inputs(ranges: [range], readings: readings()))
        let first = Array(line.frames(fps: 60))
        let second = Array(line.frames(fps: 60))
        XCTAssertEqual(first.count, second.count)
        for (lhs, rhs) in zip(first, second) {
            XCTAssertEqual(lhs.minute, rhs.minute)
            XCTAssertEqual(lhs.cameraDistance, rhs.cameraDistance)
            XCTAssertEqual(lhs.coordinate?.latitude, rhs.coordinate?.latitude)
            XCTAssertEqual(lhs.coordinate?.longitude, rhs.coordinate?.longitude)
        }
    }

    func testEmptySpanHasNoFrames() {
        XCTAssertTrue(Array(timeline(inputs(end: 0)).frames(fps: 60)).isEmpty)
    }
}
