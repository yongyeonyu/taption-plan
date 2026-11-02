import SwiftUI
import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

@MainActor
final class MapHomeCounterTimelinePolicyTests: XCTestCase {
    private let dayStart = Date(timeIntervalSince1970: 1_700_000_000)

    func testCutoffFollowsGivenMinute() {
        XCTAssertNil(MapHomeCounterTimelinePolicy.cutoff(dayStart: dayStart, minute: nil))
        XCTAssertNil(MapHomeCounterTimelinePolicy.cutoff(dayStart: dayStart, minute: .nan))
        XCTAssertEqual(
            MapHomeCounterTimelinePolicy.cutoff(dayStart: dayStart, minute: 90),
            dayStart.addingTimeInterval(90 * 60)
        )
    }

    func testCutoffStopsAtEndOfDay() {
        XCTAssertEqual(
            MapHomeCounterTimelinePolicy.cutoff(dayStart: dayStart, minute: 2_000),
            dayStart.addingTimeInterval(24 * 60 * 60)
        )
    }

    func testStepsCountOnlyReadingsUpToCutoff() {
        let readings = [
            SensorReading(timestamp: dayStart.addingTimeInterval(60), stepCount: 120),
            SensorReading(timestamp: dayStart.addingTimeInterval(3_600), stepCount: 900),
            SensorReading(timestamp: dayStart.addingTimeInterval(7_200), stepCount: 2_400),
        ]
        XCTAssertEqual(MapHomeCounterTimelinePolicy.stepCount(readings: readings, cutoff: nil), 2_400)
        XCTAssertEqual(
            MapHomeCounterTimelinePolicy.stepCount(
                readings: readings,
                cutoff: dayStart.addingTimeInterval(3_600)
            ),
            900
        )
        XCTAssertNil(
            MapHomeCounterTimelinePolicy.stepCount(
                readings: readings,
                cutoff: dayStart.addingTimeInterval(30)
            )
        )
    }

    func testTravelDistanceProratesOngoingSegment() {
        let segments = [
            TravelSegment(
                mode: .walking,
                span: TimeSpan(start: dayStart, end: dayStart.addingTimeInterval(600)),
                distanceMeters: 600,
                confidence: .high,
                evidence: []
            ),
            TravelSegment(
                mode: .subway,
                span: TimeSpan(
                    start: dayStart.addingTimeInterval(600),
                    end: dayStart.addingTimeInterval(1_800)
                ),
                distanceMeters: 4_000,
                confidence: .high,
                evidence: []
            ),
        ]
        XCTAssertEqual(
            MapHomeCounterTimelinePolicy.travelMeters(segments: segments, cutoff: nil),
            4_600,
            accuracy: 0.5
        )
        XCTAssertEqual(
            MapHomeCounterTimelinePolicy.travelMeters(
                segments: segments,
                cutoff: dayStart.addingTimeInterval(600)
            ),
            600,
            accuracy: 0.5
        )
        // 두 번째 구간을 절반 지난 시점: 600 + 2,000.
        XCTAssertEqual(
            MapHomeCounterTimelinePolicy.travelMeters(
                segments: segments,
                cutoff: dayStart.addingTimeInterval(1_200)
            ),
            2_600,
            accuracy: 0.5
        )
    }

    /// 창의 시계는 10초마다 깨어나지만, 하루를 다시 세는 일은 분에 한 번이다.
    func testCategorySecondsAreCachedPerMinuteOnTheLiveClock() {
        let cache = MapHomeCounterValueCache()
        // 버킷은 epoch부터 60초로 끊는다. 시험 기준점도 분 경계에 맞춘다
        // (정수 나눗셈이 아니라 Double로 내림해야 한다 — 리터럴이 Double로 추론된다).
        let minuteStart = Date(timeIntervalSince1970: (1_700_000_000.0 / 60).rounded(.down) * 60)
        var computed = 0
        func read(_ now: Date) -> [String: TimeInterval] {
            cache.categorySeconds(cutoff: nil, now: now, revision: 7) { _ in
                computed += 1
                return ["work": 60]
            }
        }
        XCTAssertEqual(read(minuteStart.addingTimeInterval(5)), ["work": 60])
        XCTAssertEqual(read(minuteStart.addingTimeInterval(35)), ["work": 60])
        XCTAssertEqual(computed, 1, "같은 분 안에서는 다시 세지 않는다")
        _ = read(minuteStart.addingTimeInterval(65))
        XCTAssertEqual(computed, 2, "분이 바뀌면 다시 센다")
    }

    /// 같은 분이라도 기록이 바뀌면(클립 편집·새 센서) 다시 센다.
    func testCategorySecondsFollowDataChangesWithinTheSameMinute() {
        let cache = MapHomeCounterValueCache()
        var computed = 0
        func read(_ revision: UInt64) -> [String: TimeInterval] {
            cache.categorySeconds(
                cutoff: nil,
                now: dayStart.addingTimeInterval(10),
                revision: revision
            ) { _ in
                computed += 1
                return ["work": Double(computed) * 60]
            }
        }
        XCTAssertEqual(read(3), ["work": 60])
        XCTAssertEqual(read(3), ["work": 60])
        XCTAssertEqual(computed, 1)
        XCTAssertEqual(read(4), ["work": 120])
        XCTAssertEqual(computed, 2, "기록이 바뀌면 같은 분이라도 다시 센다")
    }

    /// 재생 중에는 지금 시각이 아니라 재생 시각으로 버킷을 잡는다.
    func testPlaybackCutoffStillDrivesTheBucket() {
        let cache = MapHomeCounterValueCache()
        // 재생 시각도 분 경계에 맞춰, 아래 +50초가 같은 분 안에 남게 한다.
        let cutoff = Date(timeIntervalSince1970: (1_700_000_000.0 / 60).rounded(.down) * 60 + 3_600)
        var computed = 0
        func read(_ playback: Date?, _ now: Date) -> [String: TimeInterval] {
            cache.categorySeconds(cutoff: playback, now: now, revision: 1) { date in
                computed += 1
                // 재생 시각을 그대로 받았는지 확인하려고 값에 표시를 남긴다.
                return ["work": date == cutoff ? 60 : -1]
            }
        }
        XCTAssertEqual(read(cutoff, cutoff), ["work": 60])
        XCTAssertEqual(read(cutoff, cutoff.addingTimeInterval(50)), ["work": 60])
        XCTAssertEqual(computed, 1, "재생 시각이 같으면 지금 시각이 흘러도 다시 세지 않는다")
        // 재생 시각이 1분 넘어가면 다시 세고, 그때는 새 재생 시각을 넘긴다.
        XCTAssertEqual(read(cutoff.addingTimeInterval(60), cutoff.addingTimeInterval(60)), ["work": -1])
        XCTAssertEqual(computed, 2)
    }

    /// 진행 중인 업무 기록은 시계가 흐르는 만큼 늘어난다 — 카운터 숫자가 실시간으로 오르는 근거다.
    func testOpenWorkRecordGrowsWithTheClock() {
        let start = dayStart.addingTimeInterval(9 * 3_600)
        let record = ActualRecord(
            planID: nil,
            title: "업무",
            categoryID: "work",
            startedAt: start,
            source: .motion
        )
        let day = TimeSpan(start: dayStart, end: dayStart.addingTimeInterval(24 * 3_600))
        func workSeconds(at now: Date) -> TimeInterval {
            TaptionSealedDayBuilder.categoryDurations(
                actuals: [record],
                travel: [],
                stays: [],
                placeKinds: [:],
                day: day,
                asOf: now
            )["work"] ?? 0
        }
        XCTAssertEqual(workSeconds(at: start.addingTimeInterval(600)), 600, accuracy: 1)
        XCTAssertEqual(workSeconds(at: start.addingTimeInterval(1_200)), 1_200, accuracy: 1)
    }

    /// 자정을 넘긴 구간은 이 날 몫만, 겹친 구간은 한 번만 센다. 핸들 시각을 움직이면 거리도 따라 바뀐다.
    func testTravelMetersClipsToDayAndCountsOverlapOnce() {
        let dayStart = Date(timeIntervalSince1970: 1_800_000_000)
        let day = TimeSpan(start: dayStart, end: dayStart.addingTimeInterval(86_400))
        func segment(_ from: Double, _ to: Double, meters: Double) -> TravelSegment {
            TravelSegment(
                mode: .car, span: TimeSpan(start: dayStart.addingTimeInterval(from * 60), end: dayStart.addingTimeInterval(to * 60)),
                distanceMeters: meters, confidence: .high, evidence: []
            )
        }
        // 전날 23:30~오늘 00:30, 1,000m 중 오늘 몫은 500m.
        XCTAssertEqual(MapHomeCounterTimelinePolicy.travelMeters(segments: [segment(-30, 30, meters: 1_000)], cutoff: nil, day: day), 500, accuracy: 0.5)
        // 똑같은 구간이 두 번 저장돼도 한 번만 센다.
        let twice = [segment(60, 120, meters: 1_000), segment(60, 120, meters: 1_000)]
        XCTAssertEqual(MapHomeCounterTimelinePolicy.travelMeters(segments: twice, cutoff: nil, day: day), 1_000, accuracy: 0.5)
        // 핸들이 첫 구간 절반에 있으면 그만큼만, 시작 전이면 0.
        XCTAssertEqual(MapHomeCounterTimelinePolicy.travelMeters(segments: [segment(60, 120, meters: 1_000)], cutoff: dayStart.addingTimeInterval(90 * 60), day: day), 500, accuracy: 0.5)
        XCTAssertEqual(MapHomeCounterTimelinePolicy.travelMeters(segments: [segment(60, 120, meters: 1_000)], cutoff: dayStart, day: day), 0)
        XCTAssertEqual(MapHomeCounterTimelinePolicy.cutoff(dayStart: dayStart, minute: 0), dayStart)
        XCTAssertNil(MapHomeCounterTimelinePolicy.cutoff(dayStart: dayStart, minute: nil))
    }

    /// 회사 반경 안 식당에 머물면 식당이 우선이고, 식사 시간은 자동 업무에서 빠진다(MEA1102A01).
    func testSmallerRadiusPlaceWinsAndMealIsCarvedFromWork() {
        func geo(_ latitude: Double) -> GeoPoint {
            GeoPoint(latitude: latitude, longitude: 127, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
        }
        var company = FrequentPlace(kind: .company)
        company.point = geo(37.5)
        company.radiusMeters = 300
        var restaurant = FrequentPlace(kind: .restaurant)
        restaurant.point = geo(37.5015)
        restaurant.radiusMeters = 50
        let engine = FrequentPlaceResolutionEngine()
        // 식당 자리: 회사 반경 안(약 167m)이어도 식당.
        XCTAssertEqual(engine.nearestMatch(to: geo(37.5015), candidates: [company, restaurant])?.kind, .restaurant)
        // 회사 자리: 식당 반경 밖이면 회사.
        XCTAssertEqual(engine.nearestMatch(to: geo(37.5), candidates: [company, restaurant])?.kind, .company)

        let nine = dayStart.addingTimeInterval(9 * 3_600)
        func hours(_ value: Double) -> Date { nine.addingTimeInterval(value * 3_600) }
        let work = ActualRecord(planID: nil, title: "근무", categoryID: "work", startedAt: nine, endedAt: hours(8), source: .location, modelVersion: "classifier-v1/context")
        let meal = ActualRecord(planID: nil, title: "식사", categoryID: "eating", startedAt: hours(3), endedAt: hours(4), source: .location, modelVersion: RestaurantMealActualEngine.modelVersion)
        let carved = RestaurantMealActualEngine.carvingMeals(from: [work, meal], asOf: hours(9))
        let pieces = carved.filter { $0.categoryID == "work" }.sorted { $0.startedAt < $1.startedAt }
        XCTAssertEqual(pieces.map(\.startedAt), [nine, hours(4)])
        XCTAssertEqual(pieces.map(\.endedAt), [hours(3), hours(8)])
        XCTAssertEqual(pieces.first?.id, work.id)
        XCTAssertEqual(Set(carved.map(\.id)).count, carved.count)
        // 다시 돌려도 같다.
        XCTAssertEqual(RestaurantMealActualEngine.carvingMeals(from: carved, asOf: hours(9)), carved)
        // 사용자가 고친 업무는 그대로 둔다.
        var manual = work
        manual.manuallyCorrected = true
        XCTAssertEqual(RestaurantMealActualEngine.carvingMeals(from: [manual, meal], asOf: hours(9)).filter { $0.categoryID == "work" }.count, 1)
    }

    /// 8층 자리는 겹친 1층 식당 반경 안이어도 회사다. 높이 근거가 없으면 작은 반경이 이긴다(ALT1102A01).
    func testPlaceHeightSeparatesFloorsInOverlappingRadius() {
        func geo(_ altitude: Double, vertical: Double = 5) -> GeoPoint {
            GeoPoint(latitude: 37.5, longitude: 127, altitude: altitude, horizontalAccuracy: 10, verticalAccuracy: vertical)
        }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var company = FrequentPlace(kind: .company, name: "회사", point: geo(50), floor: 8)
        company.radiusMeters = 200
        company.floorReferencePoints = [FloorCalibrationPoint(
            floor: 8, point: geo(50), relativeAltitudeMeters: nil, pressureKilopascals: nil,
            altimeterSessionID: nil, capturedAt: now.addingTimeInterval(-86_400)
        )]
        var restaurant = FrequentPlace(kind: .restaurant, name: "식당", point: geo(0, vertical: -1), floor: 1)
        restaurant.radiusMeters = 30
        func reading(_ altitude: Double) -> SensorReading {
            SensorReading(timestamp: now, point: geo(altitude), motion: .stationary)
        }
        let engine = FrequentPlaceResolutionEngine()
        let here = geo(50)
        XCTAssertEqual(engine.nearestMatch(to: here, candidates: [company, restaurant], readings: [reading(50)])?.kind, .company)
        let ground = 50 - 7 * company.floorHeightMeters
        XCTAssertEqual(engine.nearestMatch(to: here, candidates: [company, restaurant], readings: [reading(ground)])?.kind, .restaurant)
        XCTAssertEqual(engine.nearestMatch(to: here, candidates: [company, restaurant])?.kind, .restaurant)
    }

    func testFloorLabelsByLanguage() {
        XCTAssertEqual(FloorLabel.korean(1), "1층")
        XCTAssertEqual(FloorLabel.english(1), "1Floor")
    }

    /// 조각마다가 아니라 탑승 전체로 본다. 등록 차에 연결돼 있으면 같은 길이어도 지하철이 아니다(SUB1102A01).
    func testRailJourneyIsJudgedOverTheWholeRide() throws {
        let stations = ["마곡나루", "계양", "검암"].compactMap { name in
            SubwayStationCatalog.route(for: [name, "서구청"])?.stops.first { $0.stationName.hasPrefix(name) }
        }
        XCTAssertEqual(stations.count, 3)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func reading(_ stop: SubwayRouteStop, _ minute: Double, speed: Double, kPa: Double, car: String? = nil) -> SensorReading {
            var value = SensorReading(
                timestamp: start.addingTimeInterval(minute * 60),
                point: GeoPoint(latitude: stop.latitude ?? 0, longitude: stop.longitude ?? 0, altitude: 10, horizontalAccuracy: 10, verticalAccuracy: 5),
                motion: .automotive
            )
            value.speedMetersPerSecond = speed
            value.pressureKilopascals = kPa
            value.gpsAvailable = true
            value.carAudioRouteName = car
            return value
        }
        func ride(car: String?) -> [SensorReading] {
            [
                reading(stations[0], 0, speed: 1, kPa: 102.40, car: car), reading(stations[0], 6, speed: 1, kPa: 102.38, car: car),
                reading(stations[1], 16, speed: 1, kPa: 102.00, car: car), reading(stations[1], 17, speed: 20, kPa: 102.00, car: car),
                reading(stations[2], 23, speed: 1, kPa: 101.90, car: car),
            ]
        }
        let journeys = RailJourneyRecognizer.journeys(readings: ride(car: nil))
        XCTAssertEqual(journeys.first?.stationNames.count, 3)
        XCTAssertTrue(RailJourneyRecognizer.journeys(readings: ride(car: "CarPlay")).isEmpty)

        // 노선을 따라가지만 역 사이 신호에 멈추고 탑승역에 머물지 않은 차는 지하철이 아니다.
        let start0 = try XCTUnwrap(stations[1].latitude), lng0 = try XCTUnwrap(stations[1].longitude)
        let end0 = try XCTUnwrap(stations[2].latitude), lng1 = try XCTUnwrap(stations[2].longitude)
        var redLight = SensorReading(
            timestamp: start.addingTimeInterval(19 * 60),
            point: GeoPoint(latitude: (start0 + end0) / 2, longitude: (lng0 + lng1) / 2, altitude: 10, horizontalAccuracy: 10, verticalAccuracy: 5),
            motion: .automotive
        )
        redLight.speedMetersPerSecond = 0.5
        redLight.gpsAvailable = true
        var moving = redLight
        moving.timestamp = start.addingTimeInterval(20 * 60)
        moving.speedMetersPerSecond = 14
        let carRide = [
            reading(stations[0], 5.5, speed: 12, kPa: 102.40), reading(stations[0], 6, speed: 14, kPa: 102.38),
            reading(stations[1], 16, speed: 1, kPa: 102.00), reading(stations[1], 17, speed: 20, kPa: 102.00),
            redLight, moving,
            reading(stations[2], 23, speed: 1, kPa: 101.90), reading(stations[2], 24, speed: 14, kPa: 101.90),
        ]
        XCTAssertTrue(RailJourneyRecognizer.journeys(readings: carRide).isEmpty)

        // 직접 고친 기록은 이름을 바꾸지 않는다.
        let span = TimeSpan(start: start.addingTimeInterval(7 * 60), end: start.addingTimeInterval(9 * 60))
        var corrected = ActualRecord(planID: nil, title: "자동차", categoryID: "movement", startedAt: span.start, endedAt: span.end, source: .motion, behavior: "automotive")
        corrected.manuallyCorrected = true
        var automatic = corrected
        automatic.manuallyCorrected = false
        automatic.id = UUID()
        let retitled = RailJourneyRecognizer.retitling([corrected, automatic], subwaySpans: journeys.map(\.span), asOf: span.end)
        XCTAssertEqual(retitled.map(\.title), ["자동차", "지하철"])

        let car = TravelSegment(
            mode: .car, span: TimeSpan(start: start.addingTimeInterval(7 * 60), end: start.addingTimeInterval(9 * 60)),
            distanceMeters: 0, confidence: .high, evidence: [], isConfirmed: false
        )
        let applied = RailJourneyRecognizer.applying(journeys, to: [car], corrections: [])
        XCTAssertEqual(applied.map(\.mode), [.subway])
        XCTAssertNotNil(applied.first?.subwayRoute)
    }

    /// 일정 메모는 옛 저장 자료에 없다. 없어도 읽히고, 구글 설명의 HTML은 글자만 남는다.
    func testCalendarNotesDecodeAndPlainText() throws {
        let record = CalendarRecord(
            id: "a", calendarID: "b", title: "제목", span: TimeSpan(start: .distantPast, end: .distantPast),
            isAllDay: false, calendarTitle: "c", calendarColorHex: nil, sourceTitle: nil
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "notes")
        let decoded = try JSONDecoder().decode(CalendarRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.notes)
        XCTAssertEqual(CalendarNotesText.plain("<p>회의&nbsp;자료</p><br>준비 &amp; 확인"), "회의 자료\n준비 & 확인")
        XCTAssertNil(CalendarNotesText.plain("  <br> "))
    }

    func testPhotoPinMovesOffCatAndPlaceIcons() {
        let pin = CGPoint(x: 200, y: 300)
        XCTAssertEqual(MapHomePhotoPlacement.point(for: pin, avoiding: []), pin)
        let cat = MapHomePhotoPlacement.obstacle(center: CGPoint(x: 200, y: 280), side: 72)
        let home = MapHomePhotoPlacement.obstacle(center: CGPoint(x: 130, y: 280), side: 78)
        let moved = MapHomePhotoPlacement.point(for: pin, avoiding: [cat, home])
        XCTAssertNotEqual(moved, pin)
        let rect = CGRect(x: moved.x - 27, y: moved.y - 54, width: 54, height: 54)
        XCTAssertFalse(rect.intersects(cat))
        XCTAssertFalse(rect.intersects(home))
    }

    func testHomeTitleNamesTheBuilding() {
        XCTAssertEqual(MapHomeHomeNames.names.count, 366)
        XCTAssertEqual(MapHomeGrowthPolicy.homeTitle(level: 366, language: .korean), "우리집 (\(MapHomeHomeNames.names[365].korean))")
        XCTAssertEqual(MapHomeGrowthPolicy.homeTitle(level: 999, language: .korean), MapHomeGrowthPolicy.homeTitle(level: 366, language: .korean))
    }

    /// 메뉴의 글꼴 넷은 모두 앱에 들어 있고, 굵기마다 실제로 불러올 수 있다.
    func testEveryFontChoiceLoads() {
        for font in TaptionFont.allCases {
            for weight in [Font.Weight.regular, .medium, .semibold, .bold, .heavy] {
                XCTAssertNotNil(UIFont(name: font.name(for: weight), size: 12), font.name(for: weight))
            }
        }
    }
}
