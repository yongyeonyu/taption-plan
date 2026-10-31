import SwiftUI
import UIKit
import XCTest
@testable import TaptionPlan

/// 화랑이 머리 위 카운터 줄을 눌렀을 때 뜨는 상세 화면의 값(UIX1031A10).
final class MapHomeCounterDetailTests: XCTestCase {
    private let calendar = Calendar.autoupdatingCurrent

    private var dayStart: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_793_000_000)) }
    private var dayEnd: Date { calendar.date(byAdding: .day, value: 1, to: dayStart)! }

    func testRowIndexPicksByHeightAndClamps() {
        let frame = CGRect(x: 0, y: 100, width: 176, height: 90)
        XCTAssertEqual(MapHomeCounterDetailBuilder.rowIndex(tapY: 101, frame: frame, count: 3), 0)
        XCTAssertEqual(MapHomeCounterDetailBuilder.rowIndex(tapY: 145, frame: frame, count: 3), 1)
        XCTAssertEqual(MapHomeCounterDetailBuilder.rowIndex(tapY: 189, frame: frame, count: 3), 2)
        // 창 가장자리 바깥(여유 8pt로 눌린 경우)은 가장 가까운 줄로 붙는다.
        XCTAssertEqual(MapHomeCounterDetailBuilder.rowIndex(tapY: 95, frame: frame, count: 3), 0)
        XCTAssertEqual(MapHomeCounterDetailBuilder.rowIndex(tapY: 195, frame: frame, count: 3), 2)
        XCTAssertNil(MapHomeCounterDetailBuilder.rowIndex(tapY: 120, frame: frame, count: 0))
        XCTAssertNil(MapHomeCounterDetailBuilder.rowIndex(tapY: 120, frame: .zero, count: 2))
        XCTAssertNil(MapHomeCounterDetailBuilder.rowIndex(tapY: .nan, frame: frame, count: 2))
    }

    func testStepsListHourlyIncreaseFromDailyCumulativeReadings() {
        func reading(hour: Double, steps: Int) -> SensorReading {
            var value = SensorReading(timestamp: dayStart.addingTimeInterval(hour * 3_600))
            value.stepCount = steps
            return value
        }
        let content = MapHomeCounterDetailBuilder.steps(
            readings: [reading(hour: 8.5, steps: 1_000), reading(hour: 9.5, steps: 1_800), reading(hour: 9.9, steps: 2_300)],
            total: "2,300",
            dayStart: dayStart,
            language: .korean
        )
        let rows = content.sections.first?.rows ?? []
        // 8시 시간대: 누적 1000(시작 값 0) → +1000, 9시 시간대: 1000 → 2300 → +1300.
        XCTAssertEqual(rows.map(\.value), ["1,000걸음", "1,300걸음"])
        XCTAssertEqual(content.value, "2,300")
        XCTAssertNil(content.note)
    }

    func testStepsWithoutReadingsShowsNote() {
        let content = MapHomeCounterDetailBuilder.steps(readings: [], total: "–", dayStart: dayStart, language: .korean)
        XCTAssertTrue(content.sections.isEmpty)
        XCTAssertNotNil(content.note)
    }

    func testDistanceListsModesAndTripsLongestFirstAndDropsTinyTrips() {
        func segment(_ mode: TravelMode, hour: Double, meters: Double) -> TravelSegment {
            let start = dayStart.addingTimeInterval(hour * 3_600)
            return TravelSegment(
                mode: mode,
                span: TimeSpan(start: start, end: start.addingTimeInterval(600)),
                distanceMeters: meters,
                confidence: .high,
                evidence: []
            )
        }
        let content = MapHomeCounterDetailBuilder.distance(
            segments: [segment(.walking, hour: 9, meters: 700), segment(.subway, hour: 8, meters: 5_200), segment(.bus, hour: 18, meters: 4)],
            total: "5.9 km",
            language: .korean
        )
        XCTAssertEqual(content.sections.count, 2)
        XCTAssertEqual(content.sections[0].rows.map(\.title), ["지하철", "걷기"])
        XCTAssertEqual(content.sections[1].rows.map(\.subtitle), ["지하철", "걷기"], "구간은 시간순, 10m 미만은 뺀다")
    }

    func testTimeCounterListsOnlyItsCategoryClipsToDayAndAddsRemainder() {
        let work = ActualRecord(
            planID: nil, title: "회의", categoryID: "work",
            startedAt: dayStart.addingTimeInterval(9 * 3_600),
            endedAt: dayStart.addingTimeInterval(10 * 3_600), source: .manual
        )
        let overnight = ActualRecord(
            planID: nil, title: "야근", categoryID: "work",
            startedAt: dayEnd.addingTimeInterval(-3_600),
            endedAt: dayEnd.addingTimeInterval(7_200), source: .manual
        )
        let study = ActualRecord(
            planID: nil, title: "독서", categoryID: "study",
            startedAt: dayStart.addingTimeInterval(11 * 3_600),
            endedAt: dayStart.addingTimeInterval(12 * 3_600), source: .manual
        )
        let content = MapHomeCounterDetailBuilder.time(
            kind: .work,
            actuals: [study, overnight, work],
            totalSeconds: 3 * 3_600,
            total: "3시간",
            dayStart: dayStart, dayEnd: dayEnd, now: dayEnd, language: .korean
        )
        let rows = content.sections.first?.rows ?? []
        XCTAssertEqual(rows.map(\.title), ["회의", "야근", "그 밖의 자동 집계"])
        XCTAssertEqual(rows.map(\.value), ["1시간", "1시간", "1시간"], "야근은 그날 안의 1시간만 센다")
    }

    func testTimeCounterWithoutRecordsOrTotalShowsNoteOnly() {
        let content = MapHomeCounterDetailBuilder.time(
            kind: .hobby, actuals: [], totalSeconds: 0, total: "0분",
            dayStart: dayStart, dayEnd: dayEnd, now: dayEnd, language: .korean
        )
        XCTAssertTrue(content.sections.isEmpty)
        XCTAssertNotNil(content.note)
    }

    func testSalaryShowsRateAndWorkSpans() {
        let span = TimeSpan(start: dayStart.addingTimeInterval(9 * 3_600), end: dayStart.addingTimeInterval(12 * 3_600))
        let content = MapHomeCounterDetailBuilder.salary(spans: [span], earned: "30,000원", hourlyRateText: "10,000원", language: .korean)
        XCTAssertEqual(content.value, "30,000원")
        XCTAssertEqual(content.sections.map(\.title), ["시급", "근무 구간"])
        XCTAssertEqual(content.sections[1].rows.map(\.value), ["3시간"])
    }

    func testDetailContentCarriesSharesCaptionAndHourlyChart() {
        func reading(hour: Double, steps: Int) -> SensorReading {
            var value = SensorReading(timestamp: dayStart.addingTimeInterval(hour * 3_600))
            value.stepCount = steps
            return value
        }
        let steps = MapHomeCounterDetailBuilder.steps(
            readings: [reading(hour: 8.5, steps: 1_000), reading(hour: 9.5, steps: 3_000)],
            total: "3,000", dayStart: dayStart, language: .korean
        )
        XCTAssertEqual(steps.hourly.count, 24)
        XCTAssertEqual(steps.hourly.max(), 1, "가장 높은 시간대가 꽉 찬다")
        XCTAssertEqual(steps.sections.first?.rows.map(\.share), [0.5, 1.0])
        XCTAssertEqual(steps.caption, "걸음이 잡힌 시간대 2곳")

        let work = ActualRecord(
            planID: nil, title: "회의", categoryID: "work",
            startedAt: dayStart.addingTimeInterval(9 * 3_600),
            endedAt: dayStart.addingTimeInterval(10 * 3_600), source: .manual
        )
        let time = MapHomeCounterDetailBuilder.time(
            kind: .work, actuals: [work], totalSeconds: 2 * 3_600, total: "2시간",
            dayStart: dayStart, dayEnd: dayEnd, now: dayEnd, language: .korean
        )
        XCTAssertEqual(time.sections.first?.rows.map(\.share), [0.5, 0.5], "합계 2시간 중 기록 1시간 + 자동 집계 1시간")
        XCTAssertEqual(time.caption, "활동 1건", "자동 집계 줄은 기록 건수에 넣지 않는다")
        XCTAssertTrue(time.hourly.isEmpty)
    }

    // MARK: 화면 확인용(기본은 건너뜀)

    /// `/private/tmp/taption-render-counter-detail` 파일이 있을 때만 상세 시트를 그림 파일로 내보낸다(UIX1031A13 눈으로 확인용).
    @MainActor
    func testRenderSheetImagesWhenRequested() throws {
        let marker = "/private/tmp/taption-render-counter-detail"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: marker), "그림 내보내기 요청 파일이 없음")
        func reading(hour: Double, steps: Int) -> SensorReading {
            var value = SensorReading(timestamp: dayStart.addingTimeInterval(hour * 3_600))
            value.stepCount = steps
            return value
        }
        func trip(_ mode: TravelMode, hour: Double, minutes: Double, meters: Double) -> TravelSegment {
            let start = dayStart.addingTimeInterval(hour * 3_600)
            return TravelSegment(mode: mode, span: TimeSpan(start: start, end: start.addingTimeInterval(minutes * 60)),
                                 distanceMeters: meters, confidence: .high, evidence: [])
        }
        func actual(_ title: String, _ category: String, _ from: Double, _ to: Double) -> ActualRecord {
            ActualRecord(planID: nil, title: title, categoryID: category,
                         startedAt: dayStart.addingTimeInterval(from * 3_600),
                         endedAt: dayStart.addingTimeInterval(to * 3_600), source: .manual)
        }
        let contents = [
            MapHomeCounterDetailBuilder.steps(
                readings: [reading(hour: 7.5, steps: 800), reading(hour: 8.5, steps: 2_900), reading(hour: 12.5, steps: 4_100),
                           reading(hour: 13.4, steps: 5_600), reading(hour: 18.7, steps: 9_200), reading(hour: 19.5, steps: 10_300)],
                total: "10,300", dayStart: dayStart, language: .korean),
            MapHomeCounterDetailBuilder.distance(
                segments: [trip(.subway, hour: 8, minutes: 35, meters: 11_800), trip(.walking, hour: 12, minutes: 20, meters: 1_100),
                           trip(.bus, hour: 18, minutes: 40, meters: 9_400)],
                total: "22.3 km", language: .korean),
            MapHomeCounterDetailBuilder.time(
                kind: .work, actuals: [actual("기획 회의", "work", 9, 10.5), actual("문서 작업", "work", 11, 12.5), actual("코드 리뷰", "work", 14, 17)],
                totalSeconds: 7.5 * 3_600, total: "7시간 30분", dayStart: dayStart, dayEnd: dayEnd, now: dayEnd, language: .korean),
            MapHomeCounterDetailBuilder.time(
                kind: .study, actuals: [], totalSeconds: 0, total: "0분", dayStart: dayStart, dayEnd: dayEnd, now: dayEnd, language: .korean),
            MapHomeCounterDetailBuilder.salary(
                spans: [TimeSpan(start: dayStart.addingTimeInterval(9 * 3_600), end: dayStart.addingTimeInterval(12.5 * 3_600)),
                        TimeSpan(start: dayStart.addingTimeInterval(14 * 3_600), end: dayStart.addingTimeInterval(17 * 3_600))],
                earned: "81,250원", hourlyRateText: "12,500원", language: .korean),
        ]
        for index in 0..<contents.count {
            let host = UIHostingController(rootView: MapHomeCounterDetailSheet(contents: contents, initialIndex: index, dateText: "10월 31일 토요일"))
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 760)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: URL(fileURLWithPath: "/private/tmp/taption-counter-detail-\(index).png"))
            window.isHidden = true
        }
    }
}
