import XCTest
import TaptionPlanCore
@testable import TaptionPlan

/// 기기 원본 재생 결과를 익명 조각으로 고정한다(HMM1101A01·MEAL1103A1·CLP1105A01).
/// 조각은 내보낸 원본에서 잘라 냈다. 시각은 그날 0시 뒤 초이고 가상의 날에 놓는다. 좌표는 고정 거리만큼 옮겼고,
/// 기록 id·Wi-Fi·차량 오디오·기기 이름·일정 제목은 뺐다. 등록 장소 목록은 원본에 없어 체류에서 되살렸다.
final class RawReplayRegressionTests: XCTestCase {
    private struct Day {
        var start: Date
        var readings: [SensorReading] = []
        var actuals: [ActualRecord] = []
        var travel: [TravelSegment] = []
        var places: [PlaceStay] = []
        var registry: [FrequentPlace] = []
        var end: Date { start.addingTimeInterval(86_400) }
    }

    private static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        return value
    }()

    /// 원본 요일을 지킨 가상의 날(화요일).
    private static let dayStart = calendar.date(from: DateComponents(year: 2026, month: 1, day: 27)) ?? .distantPast

    private static func rows(_ text: String) -> [[String]] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }

    private static func placeID(_ index: String) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", Int(index) ?? 0)) ?? UUID()
    }

    private static func day(readings: String, actuals: String, travel: String, places: String, registry: String) throws -> Day {
        let start = dayStart
        func at(_ value: String) -> Date { start.addingTimeInterval(Double(value) ?? 0) }
        var day = Day(start: start)
        let sessions = (0..<8).map { _ in UUID() }
        let decoded: [[String: Any]] = rows(readings).enumerated().map { index, row in
            var value: [String: Any] = [
                "id": UUID().uuidString, "timestamp": at(row[0]).timeIntervalSinceReferenceDate, "motion": row[1],
                "motionConfidence": "high", "gpsAvailable": row[2] == "1", "sourceDevice": "iPhone", "sequence": index,
            ]
            for flag in ["nearbyStation", "matchesRailRoute", "matchesPublicTransitRoute", "frequentStops", "rideHailingHint", "nearAirport", "nearPort", "onWater"] {
                value[flag] = false
            }
            if let latitude = Double(row[3]), let longitude = Double(row[4]) {
                value["point"] = ["latitude": latitude, "longitude": longitude, "altitude": Double(row[5]) ?? 0,
                                  "horizontalAccuracy": Double(row[6]) ?? 0, "verticalAccuracy": Double(row[7]) ?? 0]
            }
            if let altitude = Double(row[8]) { value["relativeAltitudeMeters"] = altitude }
            if let pressure = Double(row[9]) { value["pressureKilopascals"] = pressure }
            if let session = Int(row[10]) { value["altimeterSessionID"] = sessions[session % sessions.count].uuidString }
            if !row[11].isEmpty { value["screenIsOn"] = row[11] == "1" }
            if let steps = Int(row[12]) { value["stepCount"] = steps }
            return value
        }
        day.readings = try JSONDecoder().decode([SensorReading].self, from: JSONSerialization.data(withJSONObject: decoded))
        day.actuals = rows(actuals).map { row in
            let manual = row[6] == "1", locked = row[7] == "1"
            return ActualRecord(
                planID: nil, title: row[4], categoryID: row[3], startedAt: at(row[0]), endedAt: at(row[1]),
                source: ActualSource(rawValue: row[2]) ?? .motion, createdAt: at(row[0]),
                behavior: row[5].isEmpty ? nil : row[5],
                evidence: row[9].split(separator: "|").map(String.init),
                modelVersion: row[8].isEmpty ? nil : row[8], manuallyCorrected: manual,
                isClassificationLocked: locked, lockReason: locked ? .stability : nil
            )
        }
        day.travel = rows(travel).map { row in
            TravelSegment(mode: TravelMode(rawValue: row[2]) ?? .walking, span: TimeSpan(start: at(row[0]), end: at(row[1])),
                          distanceMeters: Double(row[3]) ?? 0, confidence: .high, evidence: [], isClassificationLocked: true)
        }
        func point(_ latitude: String, _ longitude: String) -> GeoPoint? {
            guard let latitude = Double(latitude), let longitude = Double(longitude) else { return nil }
            return GeoPoint(latitude: latitude, longitude: longitude, altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10)
        }
        day.registry = rows(registry).map { row in
            FrequentPlace(id: placeID(row[0]), kind: FrequentPlaceKind(rawValue: row[1]) ?? .custom, name: row[2],
                          point: point(row[3], row[4]), radiusMeters: Double(row[5]) ?? 120)
        }
        day.places = rows(places).map { row in
            PlaceStay(placeKey: "frequent-\(placeID(row[2]).uuidString.lowercased())", displayName: row[3],
                      span: TimeSpan(start: at(row[0]), end: at(row[1])), confidence: .high, point: point(row[4], row[5]), isConfirmed: true)
        }
        return day
    }

    private func rail(_ day: Day, actuals: [ActualRecord]) -> [MapHomeTimeRailSegment] {
        MapHomePlaceFirstPolicy.apply(
            to: MapHomeTimeRailSegmentEngine.segments(from: actuals, travel: day.travel, on: day.start, asOf: day.end, calendar: Self.calendar),
            stays: day.places, frequentPlaces: day.registry, on: day.start, calendar: Self.calendar
        )
    }

    private func minute(_ hour: Int, _ minute: Int) -> Int { hour * 60 + minute }

    private func category(at value: Int, in rail: [MapHomeTimeRailSegment]) -> String? {
        MapHomeTimeRailSegmentEngine.segment(at: value, in: rail)?.categoryID
    }

    private func owned(_ actuals: [ActualRecord]) -> [ActualRecord] {
        actuals.filter { ActualRecord.userOwned($0) }.sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
    }

    // MARK: - MEAL1103A1 점심 식당

    /// 사용자 편집이 없을 때 등록 식당 체류(11:53–12:25)는 식사이고, 앞뒤 회사 시간은 업무다.
    func testLunchAtRegisteredRestaurantIsMealWithoutUserEdits() throws {
        let day = try Self.day(readings: Lunch.readings, actuals: Lunch.actuals, travel: Lunch.travel, places: Lunch.places, registry: Lunch.registry)
        let automatic = day.actuals.filter { !ActualRecord.userOwned($0) }
        let window = TimeSpan(start: day.start.addingTimeInterval(41_000), end: day.start.addingTimeInterval(46_500))
        let meals = RestaurantMealActualEngine.records(restaurants: day.registry, readings: day.readings, inside: window, asOf: window.end)
        let stay = try XCTUnwrap(day.places.first { $0.displayName == "사용자 지점" }).span
        let covered = meals.compactMap { $0.span(asOf: window.end).intersection(with: stay)?.duration }.reduce(0, +)
        XCTAssertGreaterThanOrEqual(covered / stay.duration, 0.8, "식당 체류를 식사로 덮지 못했다")
        let rail = rail(day, actuals: RestaurantMealActualEngine.carvingMeals(from: automatic + meals, asOf: window.end))
        for value in [minute(11, 56), minute(12, 5), minute(12, 20)] {
            XCTAssertEqual(category(at: value, in: rail), "eating", "\(value / 60):\(value % 60)")
        }
        XCTAssertEqual(category(at: minute(11, 45), in: rail), "work")
        XCTAssertEqual(category(at: minute(12, 45), in: rail), "work")
    }

    /// 회사로 묶였을 때 잠긴 `근무`가 식당을 등록한 뒤 새 식사 판정을 덮지 않는다. 원본에는 식당 근거를 단 근무가 남아 있었다.
    func testStaleLockedWorkAtRegisteredRestaurantYieldsToFreshMeal() throws {
        let day = try Self.day(readings: "", actuals: Lunch.actuals, travel: Lunch.travel, places: Lunch.places, registry: Lunch.registry)
        let stale = try XCTUnwrap(day.actuals.first { $0.categoryID == "work" && $0.evidence == ["자주가는 곳: 식당"] })
        var fresh = stale
        fresh.title = StationaryContextKind.mealPlace.title
        fresh.categoryID = StationaryContextKind.mealPlace.categoryID
        fresh.behavior = StationaryContextKind.mealPlace.rawValue
        fresh.isClassificationLocked = false
        fresh.lockReason = nil
        let span = TimeSpan(start: day.start, end: day.end)
        let merged = ActivityClassificationLockEngine.mergingLockedClassifications(existing: [stale], fresh: [fresh], inside: span)
        XCTAssertEqual(merged.map(\.behavior), [StationaryContextKind.mealPlace.rawValue])

        var unregistered = fresh
        unregistered.title = StationaryContextKind.work.title
        unregistered.categoryID = StationaryContextKind.work.categoryID
        unregistered.behavior = StationaryContextKind.work.rawValue
        unregistered.evidence = ["자주가는 곳: 회사"]
        var lockedMeal = fresh
        lockedMeal.isClassificationLocked = true
        lockedMeal.lockReason = .stability
        let back = ActivityClassificationLockEngine.mergingLockedClassifications(existing: [lockedMeal], fresh: [unregistered], inside: span)
        XCTAssertEqual(back.map(\.behavior), [StationaryContextKind.work.rawValue], "식당 등록을 지우면 식사도 따라간다")

        var corrected = stale
        corrected.manuallyCorrected = true
        let kept = ActivityClassificationLockEngine.mergingLockedClassifications(existing: [corrected], fresh: [fresh], inside: span)
        XCTAssertEqual(kept.map(\.behavior), [StationaryContextKind.work.rawValue], "사용자가 고친 기록은 그대로다")
    }

    // MARK: - HMM1101A01 사용자 편집이 든 날

    /// 사용자 편집(업무·걷기)이 든 점심 조각: 재계산 단계를 거쳐도 사용자 기록은 그대로이고, 막대도 사용자 기록을 따른다.
    /// 걷기 점심 이동을 버스·지하철·자동차로 바꾸지 않는다.
    func testUserEditedLunchSurvivesReclassification() throws {
        let day = try Self.day(readings: Lunch.readings, actuals: Lunch.actuals, travel: Lunch.travel, places: Lunch.places, registry: Lunch.registry)
        let span = TimeSpan(start: day.start.addingTimeInterval(41_000), end: day.start.addingTimeInterval(46_500))
        let before = owned(day.actuals)
        XCTAssertEqual(before.count, 9)
        let timeline = try ClassifierAdapter.travelTimeline(readings: day.readings, in: span)
        var actuals = ActivityClassificationLockEngine.releasingStabilityLocks(day.actuals, inside: span, activityCorrections: [:]).records
        let meals = RestaurantMealActualEngine.records(restaurants: day.registry, readings: day.readings, inside: span, asOf: span.end)
        actuals = RestaurantMealActualEngine.carvingMeals(from: actuals + meals, asOf: span.end)
        actuals = ClassifierAdapter.scoring(actuals, timeline: timeline, inside: span, activityCorrections: [:])
        actuals = RailJourneyRecognizer.retitling(actuals, subwaySpans: RailJourneyRecognizer.journeys(readings: day.readings).map(\.span), asOf: span.end)
        XCTAssertEqual(owned(actuals), before, "사용자 기록이 바뀌었다")

        let rail = rail(day, actuals: actuals)
        XCTAssertEqual(category(at: minute(12, 0), in: rail), "work", "사용자가 업무로 고친 시간")
        XCTAssertEqual(category(at: minute(12, 15), in: rail), "work", "사용자가 업무로 고친 시간")

        let resolved = ClassifierAdapter.resolvingTravelModes(day.travel, timeline: timeline)
        XCTAssertEqual(resolved.map(\.mode), [.walking, .walking])
    }

    // MARK: - CLP1105A01 장소 우선 대분류

    /// 11-04 회사 오후: 회사 안 걷기는 수동 기록이어도 업무 + 상세 걷기, 식당 체류는 식사, 퇴근 차는 이동이다.
    func testOfficeAfternoonShowsPlaceCategoryFirst() throws {
        let day = try Self.day(readings: "", actuals: Office.actuals, travel: Office.travel, places: Office.places, registry: Office.registry)
        let rail = rail(day, actuals: day.actuals)
        for value in [minute(16, 0), minute(16, 30), minute(18, 30), minute(18, 50)] {
            let segment = try XCTUnwrap(MapHomeTimeRailSegmentEngine.segment(at: value, in: rail), "\(value)")
            XCTAssertEqual(segment.categoryID, "work", "\(value / 60):\(value % 60)")
            XCTAssertTrue(segment.walkSpans.contains { $0.contains(value) }, "상세 걷기 \(value / 60):\(value % 60)")
        }
        XCTAssertEqual(category(at: minute(15, 45), in: rail), "work")
        for value in [minute(17, 58), minute(18, 0), minute(18, 7)] {
            XCTAssertEqual(category(at: value, in: rail), "eating", "\(value / 60):\(value % 60)")
        }
        XCTAssertEqual(category(at: minute(19, 49), in: rail), "movement")
        // 18:09부터는 회사로 돌아가는 걷기라 업무 + 상세 걷기다. 식당 시간은 앞뒤 업무와 잇지 않는다.
        XCTAssertFalse(rail.contains { $0.categoryID == "work" && $0.endMinute > minute(17, 57) && $0.startMinute < minute(18, 8) },
                       "식당 시간은 업무로 잇지 않는다")
    }
}

/// 11-03 점심 11:40–12:55. 회사 → 등록 식당(사용자 지점) → 회사, 그 위에 사용자가 고친 업무·걷기.
/// 행: 표본 `초,동작,GPS,위도,경도,고도,수평오차,수직오차,상대고도,기압,고도계세션,화면,걸음`,
/// 기록 `시작,끝,출처,대분류,제목,behavior,수동,잠금,모델,근거`, 이동 `시작,끝,수단,m`, 체류 `시작,끝,장소,이름,위도,경도`,
/// 등록 장소 `번호,종류,이름,위도,경도,반경`.
private enum Lunch {
    static let readings = """
        42455.0,unknown,1,37.212334,127.229434,52.3,7.8,17.2,-0.233,102.3943,0,1,
        42455.5,unknown,1,37.212334,127.229434,52.3,7.8,17.2,0.301,102.3896,1,0,
        42823.7,walking,1,37.212860,127.228197,43.4,28.3,34.4,-0.248,102.5367,2,0,17
        42823.7,walking,1,37.212860,127.228197,43.4,28.3,34.4,,,2,0,
        42823.9,walking,0,,,,,,,,2,0,
        42854.7,walking,1,37.212947,127.228265,44.3,20.9,30.0,-0.164,102.5357,2,0,21
        42894.7,unknown,1,37.212985,127.228336,44.3,21.9,30.0,-0.391,102.5385,2,0,21
        42911.4,unknown,1,37.212904,127.228334,50.3,26.7,30.0,-0.011,102.5338,2,0,21
        42925.3,unknown,1,37.212941,127.228351,43.4,19.4,30.0,-0.079,102.5347,2,0,21
        42926.4,unknown,1,37.213014,127.228357,43.8,17.5,30.0,-0.048,102.5343,2,0,21
        42944.4,unknown,1,37.212956,127.228335,43.5,18.5,30.0,-0.095,102.5349,2,0,21
        42950.4,unknown,1,37.212861,127.228303,50.3,16.9,30.0,-0.011,102.5338,2,0,21
        42964.5,unknown,1,37.212934,127.228324,43.5,17.4,30.0,-0.053,102.5344,2,0,21
        43052.4,unknown,1,37.212851,127.228305,43.5,22.5,30.0,0.021,102.5334,2,0,21
        43059.9,unknown,1,37.212897,127.228312,43.5,19.1,30.0,-0.042,102.5342,2,0,21
        43076.1,unknown,1,37.212977,127.228336,43.6,15.4,30.0,0.565,102.5269,2,0,21
        43098.4,unknown,1,37.212881,127.228322,43.5,24.9,30.0,0.423,102.5286,2,0,21
        43115.4,unknown,1,37.212817,127.228299,43.6,21.4,30.0,0.417,102.5286,2,0,21
        43147.8,unknown,1,37.212888,127.228321,43.5,18.7,30.0,0.375,102.5291,2,0,21
        43148.9,unknown,1,37.213009,127.228350,43.6,18.3,30.0,0.259,102.5306,2,0,21
        43196.0,unknown,1,37.212882,127.228302,43.2,16.0,30.3,0.412,102.5287,2,1,30
        43210.7,unknown,1,37.212926,127.228317,43.4,14.2,30.0,0.291,102.5302,2,1,30
        43239.8,unknown,1,37.212974,127.228328,41.7,18.2,30.0,0.766,102.5244,2,1,30
        43264.2,stationary,1,37.212896,127.228318,42.6,21.1,30.0,0.676,102.5255,2,1,30
        43307.7,unknown,1,37.212952,127.228286,41.8,18.6,30.0,1.501,102.5155,2,1,45
        43361.3,unknown,1,37.212977,127.228337,43.2,18.7,30.0,1.554,102.5149,2,1,45
        43418.0,unknown,1,37.212884,127.228300,41.7,23.9,30.0,1.580,102.5146,2,1,45
        43425.5,unknown,1,37.212803,127.228269,41.7,25.4,30.0,1.480,102.5158,2,1,45
        43433.0,unknown,1,37.212946,127.228324,41.7,18.1,30.0,1.585,102.5145,2,1,45
        43480.0,unknown,1,37.212991,127.228334,41.9,15.9,30.0,2.072,102.5086,2,1,45
        43493.6,unknown,1,37.212988,127.228333,43.2,13.7,30.0,,,3,1,
        43500.9,unknown,0,,,,,,,,3,1,
        43500.9,unknown,1,37.212988,127.228333,43.2,14.8,32.1,,,4,1,
        43501.0,unknown,0,,,,,,,,4,1,
        43531.7,unknown,1,37.212998,127.228334,41.7,18.3,35.4,-0.164,102.5088,5,1,
        43763.7,unknown,1,37.213063,127.228347,44.4,12.4,30.4,,,6,1,
        43842.7,unknown,0,,,,,,,,7,1,
        43842.7,unknown,1,37.213047,127.228338,44.0,14.5,30.0,,,8,1,
        43848.2,unknown,1,37.213131,127.228368,43.6,13.3,30.0,-0.106,102.5119,8,1,
        43854.2,unknown,1,37.213076,127.228356,50.1,14.4,30.0,-0.137,102.5122,8,1,
        43860.2,unknown,1,37.213161,127.228383,44.7,15.4,30.0,-0.449,102.5160,8,1,
        43862.5,unknown,1,37.213200,127.228395,44.7,18.0,30.7,0.259,102.5128,9,1,
        43869.0,unknown,1,37.213162,127.228389,43.7,11.6,30.0,,,10,1,
        43899.4,unknown,1,37.212732,127.228288,50.4,22.0,30.0,-0.233,102.5159,10,1,
        43904.4,unknown,1,37.212985,127.228343,43.5,15.6,30.0,0.132,102.5176,11,1,
        43933.0,unknown,1,37.213125,127.228304,43.5,13.9,30.0,,,12,1,
        43939.9,unknown,1,37.213014,127.228314,44.2,12.2,30.0,0.344,102.5181,12,1,
        43939.9,unknown,1,37.213014,127.228314,44.2,12.2,30.0,-0.365,102.5185,13,1,
        43969.9,unknown,1,37.212986,127.228327,43.5,16.2,30.0,,,14,1,
        43982.6,unknown,1,37.213096,127.228295,43.3,15.2,30.0,-0.164,102.5211,14,1,
        43991.5,unknown,1,37.213144,127.228342,43.6,17.1,30.5,-0.090,102.5191,15,1,
        44017.2,unknown,1,37.213083,127.228355,43.5,12.8,30.0,,,16,1,
        44029.6,unknown,1,37.213024,127.228353,43.6,14.8,30.0,-0.095,102.5211,16,1,
        44045.7,unknown,1,37.212973,127.228338,43.5,17.9,30.0,-0.259,102.5169,17,1,
        44103.1,unknown,1,37.213025,127.228348,43.6,13.1,30.0,,,18,1,
        44109.5,unknown,1,37.213076,127.228292,43.6,13.5,30.0,-0.021,102.5207,18,1,
        44110.6,unknown,1,37.213117,127.228253,43.6,17.9,30.0,-0.026,102.5207,18,1,
        44115.1,unknown,1,37.213107,127.228349,43.5,16.7,30.0,-0.079,102.5214,18,1,
        44121.1,unknown,1,37.213025,127.228273,44.0,16.8,30.0,-0.079,102.5214,18,1,
        44122.0,unknown,1,37.212995,127.228236,43.6,19.5,30.0,0.021,102.5222,19,1,
        44173.7,unknown,1,37.213041,127.228353,44.0,14.9,34.4,,,20,1,
        44177.3,unknown,1,37.213018,127.228347,44.0,12.9,31.1,0.222,102.5234,21,1,
        44243.0,unknown,1,37.213091,127.228350,44.0,12.1,30.0,,,22,1,
        44268.3,unknown,1,37.213145,127.228376,44.0,11.8,30.0,-0.291,102.5233,22,1,
        44274.3,unknown,1,37.213098,127.228362,43.6,12.8,30.0,-0.026,102.5201,22,1,
        44304.3,unknown,1,37.213041,127.228345,44.0,14.1,30.0,0.132,102.5182,22,1,
        44369.3,unknown,1,37.213166,127.228277,44.0,16.7,30.0,0.005,102.5197,22,1,
        44375.6,unknown,1,37.213052,127.228356,43.6,15.0,30.0,-0.270,102.5231,22,1,
        44418.9,unknown,1,37.212982,127.228335,43.4,14.7,30.0,-0.153,102.5182,23,1,
        44451.3,unknown,1,37.212902,127.228323,50.1,12.2,30.0,,,24,1,
        44462.5,unknown,1,37.212999,127.228348,43.4,11.0,34.4,-0.026,102.5138,24,1,
        44490.8,unknown,1,37.212949,127.228318,44.6,11.8,30.0,0.222,102.5108,24,1,
        44509.3,unknown,1,37.213010,127.228337,43.8,10.3,30.0,0.174,102.5114,24,1,
        44520.6,unknown,1,37.212891,127.228310,43.8,22.0,30.0,0.201,102.5132,25,1,
        44591.4,unknown,1,37.213087,127.228345,43.5,9.3,30.0,,,26,1,
        44626.9,unknown,1,37.213135,127.228346,44.0,14.0,30.0,0.201,102.5016,26,1,
        44632.9,unknown,1,37.213015,127.228321,43.6,12.8,30.0,0.444,102.4987,26,1,
        44638.9,unknown,1,37.213078,127.228349,43.7,11.8,30.0,0.502,102.4980,26,1,
        44644.9,unknown,1,37.213033,127.228333,44.0,12.7,30.0,0.270,102.5008,26,1,
        44662.9,unknown,1,37.213098,127.228366,43.6,13.4,30.0,0.301,102.5004,26,1,
        44669.1,unknown,1,37.213072,127.228360,43.6,13.3,30.0,,,27,1,
        44669.1,unknown,1,37.213072,127.228360,43.6,13.3,30.0,,,28,1,
        44674.9,unknown,1,37.213079,127.228342,44.1,12.0,30.0,0.005,102.4992,28,1,
        44709.9,unknown,1,37.213072,127.228365,43.4,16.8,30.0,0.439,102.4998,29,1,
        45568.3,unknown,0,37.212077,127.227406,28.9,80.2,34.7,,,30,1,
        45583.3,unknown,1,37.212386,127.228452,36.1,35.0,19.1,0.000,101.9331,30,1,
        45583.9,unknown,1,37.212531,127.228927,41.7,14.6,15.0,0.000,101.9332,30,1,
        45585.2,unknown,1,37.212590,127.229000,47.4,8.7,10.5,0.000,101.9331,30,1,
        45589.5,unknown,1,37.212594,127.229023,45.0,3.7,8.5,-0.037,101.9336,30,1,
        45618.7,unknown,1,37.212598,127.229017,48.9,7.0,16.1,-0.069,101.9329,31,1,
        45733.1,unknown,0,37.213267,127.227379,37.1,88.6,47.7,,,32,1,
        45734.2,unknown,1,37.212725,127.228509,33.5,34.8,23.6,,,32,1,
        45734.8,unknown,1,37.212646,127.228864,45.1,15.4,13.9,0.000,101.9259,32,1,
        45737.0,unknown,1,37.212614,127.228994,55.0,3.4,8.8,0.011,101.9257,32,1,
        45766.1,unknown,1,37.212628,127.229005,49.5,6.3,17.2,0.021,101.9232,33,1,
        45785.9,unknown,1,37.212629,127.229000,49.8,10.7,20.4,,,34,1,
        45787.4,unknown,1,37.212604,127.228990,54.1,4.9,7.0,0.000,101.9227,34,1,
        45850.0,unknown,1,37.212668,127.228946,50.9,14.2,11.5,0.100,101.9215,34,1,
        45867.0,unknown,1,37.212639,127.228933,51.0,13.0,9.6,,,35,1,
        45867.0,unknown,1,37.212639,127.228933,51.0,13.0,9.6,,,36,1,
        45944.0,unknown,1,37.212591,127.228951,52.4,14.2,10.5,0.460,101.9163,35,1,10
        45946.0,unknown,1,37.212547,127.228930,51.8,14.2,11.7,0.481,101.9160,35,1,14
        45950.0,unknown,1,37.212500,127.228926,50.5,14.2,15.4,0.481,101.9160,35,1,14
        45954.0,unknown,1,37.212456,127.228869,49.5,14.2,21.1,0.343,101.9177,35,1,24
        45961.0,walking,1,37.212415,127.228862,50.6,14.2,20.3,-0.169,101.9207,37,1,10
        46016.5,unknown,1,37.212386,127.228954,32.5,24.6,34.7,-16.842,102.1221,37,1,10
        46032.5,unknown,1,37.212360,127.229344,56.7,19.9,30.0,-20.393,102.1650,37,1,10
        46035.7,unknown,1,37.212328,127.229417,55.6,13.9,30.0,-21.339,102.1765,37,1,10
        46042.0,unknown,1,37.212358,127.229261,32.7,19.8,12.3,-21.530,102.1788,37,1,10
        46058.6,unknown,1,37.212329,127.229371,56.6,12.3,30.0,-25.329,102.2247,37,1,10
        46084.0,unknown,1,37.212312,127.229432,22.8,20.7,18.9,-33.695,102.3260,37,1,18
        46110.0,walking,1,37.212270,127.229460,34.6,15.8,19.1,-33.848,102.3279,37,1,61
        46119.0,walking,1,37.212298,127.229504,43.6,15.2,18.6,-34.023,102.3299,37,1,75
        46144.0,walking,1,37.212310,127.229448,47.1,14.5,14.7,-34.530,102.3361,37,1,75
        """
    static let actuals = """
        42000,42456,location,work,근무,work,0,1,classifier-v1/context,90분 이상 체류|자주가는 곳: 회사|평일 09–18시
        42000,46500,manual,work,업무(집 - 회사),work,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        42000,42480,manual,work,업무(집 - 회사),work,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        42480,42900,manual,movement,걷기,walking,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        42575,42884,motion,movement,걷기,walking,0,1,classifier-v1/motion,iPhone Core Motion
        42824,44710,location,work,근무,work,0,1,classifier-v1/context,자주가는 곳: 식당
        42900,43620,manual,work,업무(집 - 회사),work,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        43600,43655,motion,movement,걷기,walking,0,1,classifier-v1/motion,iPhone Core Motion
        43620,43680,manual,movement,걷기,walking,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        43680,44700,manual,work,업무(집 - 회사),work,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        44700,45600,manual,movement,걷기,walking,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        45210,45384,motion,movement,걷기,walking,0,1,classifier-v1/motion,iPhone Core Motion
        45583,46500,location,work,근무,work,0,1,classifier-v1/context,자주가는 곳: 회사|평일 09–18시
        45600,45960,manual,work,업무(집 - 회사),work,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        45960,46500,manual,movement,걷기,,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        45961,46500,location,activity,걷기,,0,1,,
        """
    static let travel = """
        42456,42824,walking,124
        44710,45583,walking,80
        """
    static let places = """
        42000,42456,0,회사,37.212341,127.229448
        42824,44710,1,사용자 지점,37.213026,127.228334
        45583,46500,0,회사,37.212477,127.229171
        """
    static let registry = """
        0,company,회사,37.212341,127.229448,120
        1,restaurant,사용자 지점,37.213026,127.228334,40
        """
}

/// 11-04 회사 오후 15:30–19:50. 회사 안 수동 걷기, 저녁 식당, 퇴근 차. 표본은 쓰지 않는다.
private enum Office {
    static let actuals = """
        55800,55859,motion,movement,걷기,walking,0,1,classifier-v1/motion,iPhone Core Motion
        55800,64247,location,work,근무,work,0,1,classifier-v1/context,90분 이상 체류|자주가는 곳: 회사|평일 09–18시
        55800,56040,manual,movement,걷기,walking,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        55859,55968,motion,movement,걷기,walking,0,1,classifier-v1/gap,
        55968,56050,motion,movement,걷기,walking,0,1,classifier-v1/motion,iPhone Core Motion
        56040,57240,manual,work,근무,work,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        57223,60297,location,activity,걷기,,0,1,,
        57240,60300,manual,movement,걷기,,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        59522,59604,motion,movement,걷기,walking,0,1,classifier-v1/motion,iPhone Core Motion
        60139,60193,motion,movement,걷기,walking,0,1,classifier-v1/motion,iPhone Core Motion
        60300,64020,manual,work,근무,work,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        64020,64260,manual,movement,걷기,,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        64042,64247,location,activity,걷기,,0,1,,
        64100,64205,motion,movement,걷기,walking,0,1,classifier-v1/motion,iPhone Core Motion
        64247,65524,location,eating,식사 · 식당,meal,0,1,classifier-v1/meal,
        64248,64254,motion,movement,걷기,walking,0,1,classifier-v1/gap,
        64260,64560,manual,movement,걷기,walking,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        64345,64406,motion,movement,걷기,walking,0,1,classifier-v1/motion,iPhone Core Motion
        64406,64470,motion,movement,걷기,walking,0,1,classifier-v1/gap,
        64470,64503,motion,movement,걷기,walking,0,1,classifier-v1/motion,iPhone Core Motion
        65391,65570,motion,movement,걷기,walking,0,1,classifier-v1/motion,iPhone Core Motion
        65520,65580,manual,movement,걷기,walking,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        65524,71213,location,work,근무,work,0,1,classifier-v1/context,90분 이상 체류|자주가는 곳: 회사|평일 09–18시
        65524,68112,location,activity,걷기,,0,1,,
        65570,65735,motion,movement,걷기,walking,0,1,classifier-v1/gap,
        65580,68100,manual,movement,걷기,,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        65735,65793,motion,movement,걷기,walking,0,1,classifier-v1/motion,iPhone Core Motion
        68100,68340,manual,work,근무,work,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        68328,68355,motion,movement,걷기,walking,0,1,classifier-v1/gap,
        68340,68400,manual,movement,걷기,walking,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        68355,68429,motion,movement,걷기,walking,0,1,classifier-v1/motion,iPhone Core Motion
        68400,68760,manual,work,근무,work,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        68760,68820,manual,movement,걷기,walking,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        68761,68837,motion,movement,걷기,walking,0,1,classifier-v1/motion,iPhone Core Motion
        68820,69840,manual,work,근무,work,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        69837,69901,motion,movement,걷기,walking,0,1,classifier-v1/motion,iPhone Core Motion
        69840,69900,manual,movement,걷기,walking,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        69900,70140,manual,work,근무,work,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        70140,70200,manual,movement,걷기,walking,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        70162,70220,motion,movement,걷기,walking,0,1,classifier-v1/motion,iPhone Core Motion
        70200,70260,manual,work,근무,work,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        70260,70320,manual,movement,걷기,walking,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        70279,70340,motion,movement,걷기,walking,0,1,classifier-v1/motion,iPhone Core Motion
        70320,71160,manual,work,근무,work,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        71160,71220,manual,movement,걷기,walking,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        71213,71232,motion,movement,자동차,automotive,0,1,classifier-v1/gap,
        71220,71400,manual,movement,자동차 탑승,car,1,0,manual-activity-section-v2,사용자가 행동 구간을 편집함
        71232,71400,motion,activity,정지·휴식,stationary,0,1,classifier-v1/motion,iPhone Core Motion
        """
    static let travel = """
        55800,56050,walking,266
        59522,59604,walking,144
        64248,64406,walking,108
        65518,65524,walking,0
        68355,68429,walking,131
        68761,68837,walking,135
        69837,69901,walking,113
        70279,70340,walking,108
        71213,71400,car,19418
        """
    static let places = """
        56209,64248,0,회사,37.212381,127.229281
        64254,65518,1,사용자 지점,37.212992,127.228336
        65524,69859,0,회사,37.212403,127.229284
        69908,71213,0,회사,37.212403,127.229284
        """
    static let registry = """
        0,company,회사,37.212381,127.229281,120
        1,restaurant,사용자 지점,37.212992,127.228336,40
        """
}
