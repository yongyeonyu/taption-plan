import XCTest
@testable import TaptionPlan

/// GPS 로그 GPX 내보내기(PLN1111A01): 위치 점만, 시간 순서, 끊기면 구간 나눔, 다른 자료는 들어가지 않는다.
final class GPXTrackExportTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_794_355_200)

    private func reading(_ seconds: Double, lat: Double? = 37.5, lon: Double = 127.0, altitude: Double = 31.26, verticalAccuracy: Double = 4, horizontalAccuracy: Double = 8) -> SensorReading {
        var value = SensorReading(timestamp: base.addingTimeInterval(seconds))
        if let lat {
            value.point = GeoPoint(latitude: lat, longitude: lon, altitude: altitude, horizontalAccuracy: horizontalAccuracy, verticalAccuracy: verticalAccuracy)
        }
        value.connectedWiFiSSID = "HomeWiFi-Secret"
        return value
    }

    func testKeepsOnlyValidPointsInTimeOrder() {
        let points = GPXTrackExport.points(from: [
            reading(120, lat: 37.52), reading(0, lat: 37.50), reading(60, lat: nil),
            reading(180, lat: 0, lon: 0), reading(240, lat: 91), reading(300, lat: 37.53, verticalAccuracy: -1),
            reading(360, lat: 37.7, horizontalAccuracy: -1),
        ])
        XCTAssertEqual(points.map(\.latitude), [37.50, 37.52, 37.53], "위치 없음·0,0·범위 밖·정확도 없는 점은 뺀다")
        XCTAssertEqual(points.map(\.altitude), [31.26, 31.26, nil], "세로 정확도가 없으면 고도를 적지 않는다")
    }

    func testSplitsSegmentsOnGapsAndWritesWellFormedGPX() throws {
        let points = GPXTrackExport.points(from: [reading(0), reading(60, lat: 37.51), reading(60 + 301, lat: 37.6), reading(60 + 360, lat: 37.61)])
        XCTAssertEqual(GPXTrackExport.segments(points).map(\.count), [2, 2])
        let text = GPXTrackExport.document(points, name: "2026-11-11 <a&b>")
        XCTAssertTrue(XMLParser(data: Data(text.utf8)).parse(), "XML이 깨지면 다른 앱이 못 읽는다")
        XCTAssertEqual(text.components(separatedBy: "<trkseg>").count - 1, 2)
        XCTAssertEqual(text.components(separatedBy: "<trkpt ").count - 1, 4)
        XCTAssertTrue(text.contains(#"<trkpt lat="37.5000000" lon="127.0000000"><ele>31.3</ele><time>2026-11-11T00:00:00Z</time></trkpt>"#), text)
        XCTAssertTrue(text.contains("&lt;a&amp;b&gt;"))
        XCTAssertFalse(text.contains("HomeWiFi"), "와이파이 이름 같은 다른 자료는 들어가지 않는다")
        XCTAssertFalse(text.contains("motion"))
    }

    func testEmptyLogStillParses() {
        XCTAssertTrue(XMLParser(data: Data(GPXTrackExport.document([], name: "x").utf8)).parse())
    }

    func testSameTimestampKeepsOnePoint() {
        XCTAssertEqual(GPXTrackExport.points(from: [reading(0, lat: 37.50), reading(0, lat: 37.50), reading(60, lat: 37.51)]).count, 2)
    }

    func testPreviewCountsPointsDistanceAndKeepsSegments() {
        // 위도 0.01도는 약 1.11 km. 10분 끊긴 뒤의 점은 다른 구간이고 그 사이 거리는 세지 않는다.
        let points = GPXTrackExport.points(from: [reading(0), reading(60, lat: 37.51), reading(660, lat: 37.60), reading(720, lat: 37.61)])
        let preview = GPXTrackExport.preview(points)
        XCTAssertEqual(preview.pointCount, 4)
        XCTAssertEqual(preview.first, base)
        XCTAssertEqual(preview.last, base.addingTimeInterval(720))
        XCTAssertEqual(preview.meters, 2_224, accuracy: 10)
        XCTAssertEqual(preview.track.map(\.count), [2, 2])
        XCTAssertEqual(GPXTrackExport.preview([]).pointCount, 0)
    }

    func testSpanCoversWholeDaysUpToNowAndFixesReversedDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = base.addingTimeInterval(10 * 3_600)
        let dayStart = calendar.startOfDay(for: now)
        let earlier = dayStart.addingTimeInterval(-2 * 86_400 + 3_600)
        let span = GPXTrackExport.span(from: now, to: earlier, now: now, calendar: calendar)
        XCTAssertEqual(span.start, calendar.startOfDay(for: earlier))
        XCTAssertEqual(span.end, now)
        let past = GPXTrackExport.span(from: earlier, to: earlier, now: now, calendar: calendar)
        XCTAssertEqual(past.end.timeIntervalSince(past.start), 86_400)
        XCTAssertFalse(GPXTrackExport.name(past, calendar: calendar).contains("_"))
        XCTAssertTrue(GPXTrackExport.name(span, calendar: calendar).contains("_"))
    }
}
