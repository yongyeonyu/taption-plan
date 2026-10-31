import XCTest
@testable import TaptionClassifierEngine

final class ClassifierTaxonomyAndKeywordTests: XCTestCase {
    func testTaxonomyV3HasHealthRunningAndSplitStudy() {
        let taxonomy = ClassifierTaxonomy.current
        XCTAssertEqual(taxonomy.version, 3)
        XCTAssertNotNil(taxonomy.category("health"))
        XCTAssertNotNil(taxonomy.detail(categoryID: "movement", behavior: "running"))
        XCTAssertNotNil(taxonomy.detail(categoryID: "study", behavior: "class"))
        XCTAssertNotNil(taxonomy.detail(categoryID: "study", behavior: "academy"))
        XCTAssertNotNil(taxonomy.detail(categoryID: "movement", behavior: "train"))
    }

    func testShipKeywordDoesNotMatchDeliveryOrBadminton() {
        XCTAssertNil(ClassifierKeywords.mode(in: "배달 음식"))
        XCTAssertNil(ClassifierKeywords.mode(in: "배드민턴"))
        XCTAssertEqual(ClassifierKeywords.categoryID(in: "배드민턴"), "exercise")
        XCTAssertEqual(ClassifierKeywords.mode(in: "배를 타고 제주"), .ship)
        XCTAssertEqual(ClassifierKeywords.mode(in: "선박 이동"), .ship)
        XCTAssertEqual(ClassifierKeywords.mode(in: "배"), .ship)
        XCTAssertNil(ClassifierKeywords.categoryID(in: "배터리 교체"))
    }

    func testEnglishWordsMatchWholeTokensOnly() {
        XCTAssertNil(ClassifierKeywords.categoryID(in: "remote control"))
        XCTAssertEqual(ClassifierKeywords.categoryID(in: "REM sleep"), "sleep")
        XCTAssertEqual(ClassifierKeywords.categoryID(in: "workout"), "exercise")
        XCTAssertEqual(ClassifierKeywords.categoryID(in: "work"), "work")
    }

    func testKoreanParticlesAndCategories() {
        XCTAssertEqual(ClassifierKeywords.categoryID(in: "학원 수업"), "study")
        XCTAssertEqual(ClassifierKeywords.categoryID(in: "점심 식사"), "eating")
        XCTAssertEqual(ClassifierKeywords.categoryID(in: "버스로 출근"), "movement")
        XCTAssertNil(ClassifierKeywords.categoryID(in: "잠깐 메모"))
        XCTAssertEqual(ClassifierKeywords.categoryID(in: "잠을 잤다"), "sleep")
        XCTAssertNil(ClassifierKeywords.mode(in: "버스킹 공연"))
        XCTAssertEqual(ClassifierKeywords.tokens("KTX타고 서울"), ["ktx", "타고", "서울"])
    }
}

/// 합성 궤적: 출발점에서 동쪽으로 일정 속도.
enum Synthetic {
    static let origin = ClassifierPoint(latitude: 37.5, longitude: 127.0)
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    static func point(eastMeters: Double, from base: ClassifierPoint = origin) -> ClassifierPoint {
        ClassifierPoint(latitude: base.latitude, longitude: base.longitude + eastMeters / (111_320 * cos(base.latitude * .pi / 180)))
    }

    static func track(
        seconds: Int, every step: Int = 5, speed: Double, startOffset: TimeInterval = 0, eastStart: Double = 0,
        gps: Bool = true, motion: MotionHint = .unknown, accel: Double? = nil, pressure: ((Int) -> Double)? = nil,
        nearStop: Bool = false, onWater: Bool = false, nearAirport: Bool = false, cadence: Double? = nil, course: Double = 90
    ) -> [ClassifierSample] {
        stride(from: 0, to: seconds, by: step).map { t in
            ClassifierSample(
                timestamp: start.addingTimeInterval(startOffset + Double(t)),
                point: gps ? point(eastMeters: eastStart + speed * Double(t)) : nil,
                horizontalAccuracy: gps ? 10 : nil,
                speed: gps ? speed : nil,
                course: gps ? course : nil,
                pressureKilopascals: pressure?(t),
                accelerationStandardDeviationG: accel,
                motion: motion,
                nearTransitStop: nearStop,
                nearAirport: nearAirport,
                onWater: onWater,
                stepCadence: cadence
            )
        }
    }

    static func dominantMode(_ samples: [ClassifierSample]) -> TransportMode {
        let steps = ModeHMM().decode(WindowFeatureExtractor.windows(samples))
        let counts = steps.reduce(into: [TransportMode: Int]()) { $0[$1.mode, default: 0] += 1 }
        return counts.max { $0.value < $1.value }!.key
    }
}

final class ClassifierModeTests: XCTestCase {
    func testWalkingRunningCar() {
        XCTAssertEqual(Synthetic.dominantMode(Synthetic.track(seconds: 600, speed: 1.3, motion: .walking, cadence: 1.8)), .walking)
        XCTAssertEqual(Synthetic.dominantMode(Synthetic.track(seconds: 600, speed: 3.2, motion: .running, cadence: 2.7)), .running)
        XCTAssertEqual(Synthetic.dominantMode(Synthetic.track(seconds: 900, speed: 14, motion: .automotive)), .car)
    }

    func testFastGPSWithoutStrideIsNotRunning() {
        XCTAssertNotEqual(Synthetic.dominantMode(Synthetic.track(seconds: 600, speed: 3.0)), .running)
    }

    func testBusNearStopsVersusCar() {
        XCTAssertEqual(Synthetic.dominantMode(Synthetic.track(seconds: 900, speed: 7, motion: .automotive, nearStop: true)), .bus)
        XCTAssertEqual(Synthetic.dominantMode(Synthetic.track(seconds: 900, speed: 14, motion: .automotive)), .car)
    }

    func testSubwayWithoutGPS() {
        XCTAssertEqual(Synthetic.dominantMode(Synthetic.track(seconds: 900, speed: 10, gps: false, motion: .automotive, accel: 0.04)), .subway)
    }

    func testFlightNeedsCruiseSpeedAndFlatPressure() {
        let cruise = Synthetic.track(seconds: 1_800, every: 10, speed: 230, nearAirport: false, course: 90).map { sample -> ClassifierSample in
            var value = sample
            value.pressureKilopascals = 78
            return value
        }
        let before = Synthetic.track(seconds: 600, every: 10, speed: 0, startOffset: -600, motion: .stationary, nearAirport: true)
        XCTAssertEqual(Synthetic.dominantMode(before + cruise), .airplane)
        // 공항 근처라도 지상 속도면 비행기가 아니다.
        XCTAssertNotEqual(Synthetic.dominantMode(Synthetic.track(seconds: 900, speed: 12, motion: .automotive, nearAirport: true)), .airplane)
    }

    func testFerryOnWater() {
        XCTAssertEqual(Synthetic.dominantMode(Synthetic.track(seconds: 1_200, speed: 9, onWater: true)), .ship)
        XCTAssertNotEqual(Synthetic.dominantMode(Synthetic.track(seconds: 1_200, speed: 9, motion: .automotive)), .ship)
    }

    func testHMMSuppressesSingleWindowFlicker() {
        var samples = Synthetic.track(seconds: 900, speed: 14, motion: .automotive)
        // 한 창(30초)만 걷기처럼 보인다.
        for index in samples.indices where (300..<330).contains(Int(samples[index].timestamp.timeIntervalSince(Synthetic.start))) {
            samples[index].motion = .walking
            samples[index].speed = 1.4
        }
        let steps = ModeHMM().decode(WindowFeatureExtractor.windows(samples))
        XCTAssertEqual(Set(steps.map(\.mode)), [.car])
    }

    func testGapsAreNotFilled() {
        let morning = Synthetic.track(seconds: 600, speed: 1.3, motion: .walking)
        let evening = Synthetic.track(seconds: 600, speed: 1.3, startOffset: 4 * 3_600, motion: .walking)
        let segments = TravelSegmenter.segments(steps: ModeHMM().decode(WindowFeatureExtractor.windows(morning + evening)), samples: morning + evening)
        XCTAssertEqual(segments.count, 2)
    }

    func testPosteriorIsNumericConfidence() {
        let samples = Synthetic.track(seconds: 900, speed: 14, motion: .automotive)
        let segments = TravelSegmenter.segments(steps: ModeHMM().decode(WindowFeatureExtractor.windows(samples)), samples: samples)
        XCTAssertEqual(segments.count, 1)
        XCTAssertGreaterThan(segments[0].score, 0.5)
        XCTAssertLessThanOrEqual(segments[0].score, 1)
        XCTAssertEqual(segments[0].distanceMeters, 14 * 895, accuracy: 300)
    }
}

final class ClassifierDistanceTests: XCTestCase {
    func testFlightDistanceIsGreatCircle() {
        let seoul = ClassifierSample(timestamp: Synthetic.start, point: ClassifierPoint(latitude: 37.46, longitude: 126.44), horizontalAccuracy: 10)
        let jeju = ClassifierSample(timestamp: Synthetic.start.addingTimeInterval(3_600), point: ClassifierPoint(latitude: 33.51, longitude: 126.49), horizontalAccuracy: 10)
        let meters = TravelDistance.meters(samples: [seoul, jeju], mode: .airplane)
        XCTAssertEqual(meters, 439_000, accuracy: 3_000)
        // 지상 경로는 70m/s 넘는 점프를 튄 점으로 버린다.
        XCTAssertEqual(TravelDistance.meters(samples: [seoul, jeju], mode: .car), 0)
    }

    func testFlightJumpNeedsImpossibleGroundSpeed() {
        XCTAssertTrue(TravelDistance.isFlightJump(distanceMeters: 440_000, duration: 3_600, originNearAirport: false, destinationNearAirport: false))
        XCTAssertFalse(TravelDistance.isFlightJump(distanceMeters: 40_000, duration: 3_600, originNearAirport: true, destinationNearAirport: true))
    }
}

final class ClassifierStayTests: XCTestCase {
    func testStayPointUsesCentroid() {
        // 첫 점이 동쪽으로 60m 튀어 있어도 중심점은 실제 자리 근처다.
        var samples = [ClassifierSample(timestamp: Synthetic.start, point: Synthetic.point(eastMeters: 60), horizontalAccuracy: 30)]
        samples += (1...40).map { i in
            ClassifierSample(timestamp: Synthetic.start.addingTimeInterval(Double(i) * 30), point: Synthetic.point(eastMeters: Double(i % 3) * 5), horizontalAccuracy: 10)
        }
        let stays = StayPointDetector().detect(samples)
        XCTAssertEqual(stays.count, 1)
        XCTAssertLessThan(stays[0].center.distance(to: Synthetic.origin), 10)
    }

    func testClusterKeepsRegisteredKeyAndStabilizesAfterTwoVisits() {
        let stay = { (offset: Double, east: Double) in
            StayPoint(interval: ClassifierInterval(start: Synthetic.start.addingTimeInterval(offset), end: Synthetic.start.addingTimeInterval(offset + 1_800)),
                      center: Synthetic.point(eastMeters: east), sampleCount: 10, meanAccuracy: 10)
        }
        let (clusters, assignment) = PlaceClusterer().cluster(
            [stay(0, 5), stay(86_400, 20), stay(0, 2_000), stay(86_400, 2_030)],
            anchors: ["company": Synthetic.origin]
        )
        XCTAssertEqual(assignment[0], "company")
        XCTAssertEqual(assignment[1], "company")
        XCTAssertEqual(assignment[2], assignment[3])
        XCTAssertTrue(clusters.first { $0.id == assignment[2] }!.isStable)
    }

    func testContextFromRegisteredKindsAndCalendar() {
        let weekdayNoon = ClassifierInterval(start: Date(timeIntervalSince1970: 1_793_419_200), end: Date(timeIntervalSince1970: 1_793_422_800))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        XCTAssertEqual(StayContextClassifier.classify(StayContextInput(interval: weekdayNoon, registeredKind: .company, calendar: calendar)).context, .work)
        XCTAssertEqual(StayContextClassifier.classify(StayContextInput(interval: weekdayNoon, registeredKind: .academy, calendar: calendar)).context, .academy)
        XCTAssertEqual(StayContextClassifier.classify(StayContextInput(interval: weekdayNoon, registeredKind: .restaurant, calendar: calendar)).context, .eating)
        XCTAssertEqual(StayContextClassifier.classify(StayContextInput(interval: weekdayNoon, calendarTitles: ["영어 학원"], calendar: calendar)).context, .academy)
        XCTAssertEqual(StayContextClassifier.classify(StayContextInput(interval: weekdayNoon, calendar: calendar)).context, .unknown)
    }
}

final class ClassifierSleepAndMetricTests: XCTestCase {
    let night = ClassifierInterval(start: Synthetic.start, end: Synthetic.start.addingTimeInterval(20 * 3_600))

    func phoneNight(brightness: Double?, charging: Bool) -> [ClassifierSample] {
        stride(from: 0, to: 8 * 3_600, by: 600).map { t in
            ClassifierSample(timestamp: Synthetic.start.addingTimeInterval(3_600 + Double(t)), motion: .stationary,
                             isCharging: charging, screenIsOn: false, screenBrightness: brightness)
        }
    }

    func testWearableWinsOverPhone() {
        let watch = SleepSource(interval: ClassifierInterval(start: Synthetic.start.addingTimeInterval(7_200), end: Synthetic.start.addingTimeInterval(7 * 3_600)), kind: .appleWatch)
        let sessions = SleepFusion.sessions(health: [watch], phone: phoneNight(brightness: 0, charging: true), night: night)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].origin, .appleWatch)
        XCTAssertEqual(sessions[0].interval, watch.interval)
    }

    func testPhoneFallbackDoesNotTreatMissingBrightnessAsDark() {
        let unknown = SleepFusion.sessions(health: [], phone: phoneNight(brightness: nil, charging: false), night: night)
        let dark = SleepFusion.sessions(health: [], phone: phoneNight(brightness: 0.02, charging: true), night: night)
        XCTAssertEqual(unknown.first?.origin, .phone)
        XCTAssertEqual(unknown.first?.score ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(dark.first?.score ?? 0, 0.8, accuracy: 0.001)
        XCTAssertFalse(unknown.first!.evidence.contains("어두운 화면"))
    }

    func testScreenOnBreaksPhoneSleep() {
        var samples = phoneNight(brightness: 0, charging: true)
        samples[samples.count / 2].screenIsOn = true
        let sessions = SleepFusion.sessions(health: [], phone: samples, night: night)
        XCTAssertLessThan(sessions.first?.interval.duration ?? 0, 5 * 3_600)
    }

    func testStepsPreferWatchAndAddUncoveredPhoneSteps() {
        let day = ClassifierInterval(start: Synthetic.start, end: Synthetic.start.addingTimeInterval(86_400))
        let hour = { (h: Double) in ClassifierInterval(start: Synthetic.start.addingTimeInterval(h * 3_600), end: Synthetic.start.addingTimeInterval((h + 1) * 3_600)) }
        let samples = [
            StepSample(interval: hour(8), count: 3_000, device: .appleWatch),
            StepSample(interval: hour(8), count: 2_800, device: .iPhone),
            StepSample(interval: hour(12), count: 1_000, device: .iPhone),
        ]
        // max(3000, 3800) = 3800이 아니라 3000 + 1000.
        XCTAssertEqual(DayMetrics.steps(samples, in: day), 4_000, accuracy: 0.001)
    }

    func testAwayExcludesRecordingGaps() {
        let day = ClassifierInterval(start: Synthetic.start, end: Synthetic.start.addingTimeInterval(86_400))
        let span = { (a: Double, b: Double) in ClassifierInterval(start: Synthetic.start.addingTimeInterval(a * 3_600), end: Synthetic.start.addingTimeInterval(b * 3_600)) }
        let away = DayMetrics.away(home: [span(0, 8), span(20, 24)], elsewhere: [span(9, 12)], travel: [span(8, 9)], in: day)
        XCTAssertEqual(away.awaySeconds, 4 * 3_600)
        XCTAssertEqual(away.homeSeconds, 12 * 3_600)
        XCTAssertEqual(away.unknownSeconds, 8 * 3_600)
    }

    func testDistanceByModeProratesAcrossDay() {
        let day = ClassifierInterval(start: Synthetic.start, end: Synthetic.start.addingTimeInterval(3_600))
        let segment = ClassifiedSegment(interval: ClassifierInterval(start: Synthetic.start.addingTimeInterval(1_800), end: Synthetic.start.addingTimeInterval(5_400)), mode: .car, score: 0.9, distanceMeters: 10_000, evidence: [])
        XCTAssertEqual(DayMetrics.distanceByMode([segment], in: day)[.car] ?? 0, 5_000, accuracy: 0.001)
    }
}

final class ClassifierFacadeTests: XCTestCase {
    func testClassifyDayProducesVersionedRecordsWithScores() {
        let stay = Synthetic.track(seconds: 1_800, every: 30, speed: 0, motion: .stationary)
        let drive = Synthetic.track(seconds: 900, speed: 14, startOffset: 1_800, motion: .automotive)
        let output = TaptionClassifier.classifyDay(ClassifierDayInput(
            day: ClassifierInterval(start: Synthetic.start, end: Synthetic.start.addingTimeInterval(86_400)),
            samples: stay + drive,
            registeredPlaces: ["company": (Synthetic.origin, .company)]
        ))
        XCTAssertTrue(output.hasEnoughRawData)
        XCTAssertTrue(output.records.contains { $0.categoryID == "movement" && $0.behavior == "automotive" })
        XCTAssertTrue(output.records.contains { $0.categoryID == "work" })
        XCTAssertTrue(output.records.allSatisfy { $0.modelVersion.hasPrefix("classifier-v1/") && (0...1).contains($0.score) })
    }

    func testCancellationStopsWork() {
        struct Stop: Error {}
        let samples = Synthetic.track(seconds: 900, speed: 14, motion: .automotive)
        XCTAssertThrowsError(try TaptionClassifier.classifyDay(
            ClassifierDayInput(day: ClassifierInterval(start: Synthetic.start, end: Synthetic.start.addingTimeInterval(86_400)), samples: samples),
            cancellation: { throw Stop() }
        ))
    }
}
