import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

/// 기기에서 내보낸 「어제·오늘 센서 원본」을 지금 분류기로 다시 판정해 출력한다(SUB1029A01).
/// `TEST_RUNNER_TAPTION_RAW_REPLAY=<json 경로>`로 실행할 때만 돈다. 판정은 출력만 하고 단정하지 않는다.
final class RawSensorReplayTests: XCTestCase {
    func testReplayExportedRawDays() throws {
        guard let path = ProcessInfo.processInfo.environment["TAPTION_RAW_REPLAY"], !path.isEmpty else {
            throw XCTSkip("TAPTION_RAW_REPLAY 없음")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let days: [TodaySensorRawExport]
        if let pair = try? JSONDecoder().decode([TodaySensorRawExport].self, from: data) {
            days = pair
        } else {
            days = [try JSONDecoder().decode(TodaySensorRawExport.self, from: data)]
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        for day in days {
            let readings = day.readings.sorted { $0.timestamp < $1.timestamp }
            let pressure = readings.filter { $0.pressureKilopascals != nil }.count
            print("REPLAY day \(formatter.string(from: day.day)) readings=\(readings.count) pressure=\(pressure) travel=\(day.travel.count) places=\(day.places?.count ?? -1) actuals=\(day.actuals?.count ?? -1)")
            for stay in (day.places ?? []).sorted(by: { $0.span.start < $1.span.start }) {
                print("REPLAY stay \(formatter.string(from: stay.span.start))–\(formatter.string(from: stay.span.end)) key=\(stay.placeKey.prefix(24)) name=\(stay.displayName) confirmed=\(stay.isConfirmed)")
            }
            for actual in (day.actuals ?? []).sorted(by: { $0.startedAt < $1.startedAt }) where actual.source != .healthKit {
                print("REPLAY actual \(formatter.string(from: actual.startedAt))–\(formatter.string(from: actual.endedAt ?? actual.startedAt)) \(actual.categoryID) src=\(actual.source.rawValue) model=\(actual.modelVersion ?? "-") locked=\(actual.isClassificationLocked ?? false) manual=\(actual.manuallyCorrected)")
            }
            for journey in RailJourneyRecognizer.journeys(readings: readings) {
                print("REPLAY rail-journey \(formatter.string(from: journey.span.start))–\(formatter.string(from: journey.span.end)) "
                    + "stations=\(journey.stationNames.joined(separator: ">")) lines=\(journey.route.lineNames.joined(separator: ">"))")
            }
            for line in RailJourneyRecognizer.rejections(readings: readings) {
                print("REPLAY rail-reject \(line)")
            }
            // 원본 표본만으로 역 궤적 엔진이 지하철을 새로 찾는지 본다(EXP1029A02 — 자차 출근에 회색 지하철 경로).
            for detected in SubwayTravelSegmentEngine.segments(from: readings) {
                print("REPLAY detected-subway \(formatter.string(from: detected.span.start))–\(formatter.string(from: detected.span.end)) "
                    + "conf=\(detected.confidence) route=\(detected.subwayRoute?.stops.map(\.stationName).joined(separator: ">") ?? "-") "
                    + "evidence=\(detected.evidence.prefix(6).joined(separator: "|"))")
            }
            for segment in day.travel.sorted(by: { $0.span.start < $1.span.start }) {
                let inside = readings.filter { segment.span.contains($0.timestamp) }
                let around = readings.filter {
                    TravelModeClassifier.altitudeContextSpan(segment.span).contains($0.timestamp)
                }
                let fresh = TravelModeClassifier().classify(readings: inside, inside: segment.span, altitudeContext: around)
                let altitude = TravelModeClassifier.altitudeChangeMeters(around)
                print("REPLAY \(formatter.string(from: segment.span.start))–\(formatter.string(from: segment.span.end)) "
                    + "stored=\(segment.mode.rawValue) fresh=\(fresh.mode.rawValue) altitude=\(Int(altitude.rounded()))m "
                    + "readings=\(inside.count) pressure=\(inside.filter { $0.pressureKilopascals != nil }.count) "
                    + "evidence=\(fresh.evidence.prefix(4).joined(separator: "|"))")
            }
        }
    }

    /// 저장된 체류·표본으로 이동 구간을 새로 만들고 잠긴 예전 구간과 합친 결과를 찍는다(MOV1110A01).
    /// 원본에는 Core Motion 기록이 따로 없어, Core Motion에서 온 자동 기록(걷기·정지·자동차)으로 대신한다.
    func testReplayRebuildsTravelFromStays() throws {
        guard let path = ProcessInfo.processInfo.environment["TAPTION_RAW_REPLAY"], !path.isEmpty else {
            throw XCTSkip("TAPTION_RAW_REPLAY 없음")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let days: [TodaySensorRawExport]
        if let pair = try? JSONDecoder().decode([TodaySensorRawExport].self, from: data) {
            days = pair
        } else {
            days = [try JSONDecoder().decode(TodaySensorRawExport.self, from: data)]
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        for day in days {
            let readings = day.readings.sorted { $0.timestamp < $1.timestamp }
            let actuals: [ActualRecord] = day.actuals ?? []
            let motion = actuals.compactMap { actual -> MotionActivityRecord? in
                guard actual.source == .motion, let end = actual.endedAt,
                      let behavior = actual.behavior, let kind = MotionKind(rawValue: behavior) else { return nil }
                return MotionActivityRecord(span: TimeSpan(start: actual.startedAt, end: end), motion: kind, confidence: actual.confidence)
            }
            let stays = (day.places ?? []).sorted { $0.span.start < $1.span.start }
            let built = MovementRouteBuilder().build(stays: stays, readings: readings, registeredCarAudioNames: ["CarPlay"], motionActivities: motion)
            let span = TimeSpan(start: day.day, end: day.day.addingTimeInterval(86_400))
            let merged = ActivityClassificationLockEngine.mergingLockedTravel(existing: day.travel, fresh: built, inside: span)
            print("REPLAY-BUILD day \(formatter.string(from: day.day)) motion=\(motion.count) stays=\(stays.count) built=\(built.count) merged=\(merged.count)")
            for segment in built { print("REPLAY-BUILD built \(formatter.string(from: segment.span.start))–\(formatter.string(from: segment.span.end)) \(segment.mode.rawValue)") }
            for segment in merged { print("REPLAY-BUILD merged \(formatter.string(from: segment.span.start))–\(formatter.string(from: segment.span.end)) \(segment.mode.rawValue) locked=\(segment.isClassificationLocked)") }
        }
    }

    /// 재생할 때 시각마다 화랑이 위치·동작이 어떻게 정해지는지 찍는다(PLB1103A01). `TAPTION_REPLAY_WINDOW`는 "HH:mm-HH:mm".
    func testDumpPlaybackTimeline() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TAPTION_RAW_REPLAY"], !path.isEmpty,
              let window = environment["TAPTION_REPLAY_WINDOW"] else {
            throw XCTSkip("TAPTION_REPLAY_WINDOW 없음")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let days = try (try? JSONDecoder().decode([TodaySensorRawExport].self, from: data))
            ?? [try JSONDecoder().decode(TodaySensorRawExport.self, from: data)]
        var day = try XCTUnwrap(days.last)
        day = TodaySensorRawExport(day: day.day, isComplete: day.isComplete, readings: day.readings,
            travel: SubwayAlighting.applying(day.travel, readings: day.readings, corrections: []), places: day.places, actuals: day.actuals)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = calendar.timeZone
        let parts = window.split(separator: "-").map { $0.split(separator: ":").compactMap { Int($0) } }
        let minutes = parts.map { $0[0] * 60 + $0[1] }
        let readings = day.readings.sorted { $0.timestamp < $1.timestamp }
        let projection = MapHomeWBSPlaybackProjection.make(
            selectedDate: day.day, places: day.places ?? [], travel: day.travel, readings: readings,
            actuals: day.actuals ?? [], calendar: calendar
        )
        let normalized = readings
        var date = day.day.addingTimeInterval(Double(minutes[0]) * 60)
        let end = day.day.addingTimeInterval(Double(minutes[1]) * 60)
        while date <= end {
            let frame = projection.frame(at: date, preferredForecastLegIDs: [])
            let location = MapHomePlaybackLocation.resolveOrGap(
                at: date, frame: frame, normalizedReadings: normalized, travel: day.travel,
                places: day.places ?? [], calendar: calendar
            )
            let action = MapHomeStickmanActionResolver.action(
                at: date, actuals: day.actuals ?? [], travel: day.travel, places: day.places ?? [],
                frequentPlaces: [], readings: readings, sleepSessions: []
            )
            if let home = readings.first(where: { $0.point != nil })?.point, let here = location?.coordinate {
                let gap = MapHomePlaybackLocation.subwayCoordinate(at: date, travel: day.travel, readings: readings)
                print("REPLAY where \(formatter.string(from: date)) fromFirst=\(Int(MapHomeVectorNavigationMath.metersForTest(home, here))) subway=\(gap.map { Int(MapHomeVectorNavigationMath.metersForTest(home, $0)) } ?? -1)")
            }
            print("REPLAY playback \(formatter.string(from: date)) frame=\(frame.map { "\($0.activity)/\($0.mode?.rawValue ?? "-")/\($0.routePhase)/\($0.legID.prefix(12))" } ?? "nil") location=\(location != nil) fallback=\(action)")
            date = date.addingTimeInterval(30)
        }
    }

    /// 등록 식당 식사와 시간 막대를 다시 계산해 찍는다(MEA1105A01). 원본 판정은 바꾸지 않는다.
    func testDumpRestaurantMealRail() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TAPTION_RAW_REPLAY"], let placesPath = environment["TAPTION_REPLAY_PLACES"] else {
            throw XCTSkip("TAPTION_REPLAY_PLACES 없음")
        }
        let days = try JSONDecoder().decode([TodaySensorRawExport].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let places = try JSONDecoder().decode([FrequentPlace].self, from: Data(contentsOf: URL(fileURLWithPath: placesPath)))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        formatter.timeZone = calendar.timeZone
        for day in days {
            let start = calendar.startOfDay(for: day.day)
            let end = start.addingTimeInterval(86_400)
            let readings = day.readings.sorted { $0.timestamp < $1.timestamp }
            let meals = RestaurantMealActualEngine.records(
                restaurants: places, readings: readings, inside: TimeSpan(start: start, end: end), asOf: end
            )
            for meal in meals {
                print("REPLAY meal \(formatter.string(from: meal.startedAt))–\(formatter.string(from: meal.endedAt ?? end)) \(meal.title)")
            }
            let carved = RestaurantMealActualEngine.carvingMeals(from: (day.actuals ?? []) + meals, asOf: end)
            for segment in MapHomeTimeRailSegmentEngine.segments(from: carved, travel: day.travel, on: start, asOf: end, calendar: calendar) {
                print("REPLAY rail \(formatter.string(from: start)) \(segment.startMinute)–\(segment.endMinute) \(segment.categoryID) \(segment.title)")
            }
        }
    }

    /// 등록 장소로 식사를 다시 만들고 장소 우선 대분류 막대를 찍는다(MEAL1103A1·CLP1105A01).
    /// 저장 기록만 쓴 막대와 식사를 넣은 막대를 함께 찍고, 사용자 기록은 그대로인지 확인한다.
    func testDumpPlaceFirstRailWithRestaurantMeals() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TAPTION_RAW_REPLAY"], let placesPath = environment["TAPTION_REPLAY_PLACES"] else {
            throw XCTSkip("TAPTION_REPLAY_PLACES 없음")
        }
        let days = try JSONDecoder().decode([TodaySensorRawExport].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let places = try JSONDecoder().decode([FrequentPlace].self, from: Data(contentsOf: URL(fileURLWithPath: placesPath)))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        formatter.timeZone = calendar.timeZone
        func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
        for day in days {
            let start = calendar.startOfDay(for: day.day)
            let end = start.addingTimeInterval(86_400)
            let readings = day.readings.sorted { $0.timestamp < $1.timestamp }
            let actuals = day.actuals ?? []
            for stale in actuals where stale.source == .location && stale.categoryID != "eating"
                && stale.evidence.contains(where: { $0.hasPrefix("자주가는 곳: 식당") }) {
                print("REPLAY stale-restaurant \(formatter.string(from: stale.startedAt))–\(formatter.string(from: stale.endedAt ?? end)) \(stale.categoryID) \(stale.title) locked=\(stale.isClassificationLocked)")
            }
            let meals = RestaurantMealActualEngine.records(restaurants: places, readings: readings, inside: TimeSpan(start: start, end: end), asOf: end)
            for meal in meals {
                print("REPLAY meal \(formatter.string(from: meal.startedAt))–\(formatter.string(from: meal.endedAt ?? end)) conf=\(meal.confidence.rawValue)")
            }
            let carved = RestaurantMealActualEngine.carvingMeals(from: actuals + meals, asOf: end)
            XCTAssertEqual(actuals.filter { ActualRecord.userOwned($0) }, carved.filter { ActualRecord.userOwned($0) }, "사용자 기록이 바뀌었다")
            for (label, records) in [("stored", actuals), ("meals", carved)] {
                let rail = MapHomePlaceFirstPolicy.apply(
                    to: MapHomeTimeRailSegmentEngine.segments(from: records, travel: day.travel, on: start, asOf: end, calendar: calendar),
                    stays: day.places ?? [], frequentPlaces: places, on: start, calendar: calendar
                )
                for segment in rail {
                    print("REPLAY rail-\(label) \(formatter.string(from: start).prefix(5)) \(clock(segment.startMinute))–\(clock(segment.endMinute)) "
                        + "\(segment.categoryID) \(segment.title) walk=\(segment.walkSpans.map { "\(clock($0.lowerBound))-\(clock($0.upperBound))" }.joined(separator: ","))")
                }
            }
        }
    }

    /// 등록 장소로 체류와 식사 후보를 다시 계산해 찍는다(PLY1103A01). `TAPTION_REPLAY_PLACES`는 등록 장소 JSON이다.
    func testDumpStaysWithFrequentPlaces() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TAPTION_RAW_REPLAY"], let placesPath = environment["TAPTION_REPLAY_PLACES"] else {
            throw XCTSkip("TAPTION_REPLAY_PLACES 없음")
        }
        let days = try JSONDecoder().decode([TodaySensorRawExport].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let places = try JSONDecoder().decode([FrequentPlace].self, from: Data(contentsOf: URL(fileURLWithPath: placesPath)))
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        for day in days {
            let readings = day.readings.sorted { $0.timestamp < $1.timestamp }
            guard let first = readings.first?.timestamp, let last = readings.last?.timestamp else { continue }
            let detected = PlaceDetectionEngine().detectStays(readings: readings, knownNames: [:])
            for stay in FrequentPlaceResolutionEngine().applying(places, to: detected, readings: readings) {
                print("REPLAY stay \(formatter.string(from: stay.span.start))–\(formatter.string(from: stay.span.end)) \(stay.displayName) confirmed=\(stay.isConfirmed)")
            }
            let walking = readings.filter { $0.motion == .walking }.map { TimeSpan(start: $0.timestamp, end: $0.timestamp.addingTimeInterval(30)) }
            for stay in UnobservedStayEngine.stays(readings: readings, footSpans: walking, inside: TimeSpan(start: first, end: last)) {
                print("REPLAY silence \(formatter.string(from: stay.span.start))–\(formatter.string(from: stay.span.end)) moved=\(Int(stay.displacementMeters)) left=\(stay.leftOnFoot) back=\(stay.returnedOnFoot)")
            }
        }
    }

    /// 저장된 이동 구간(예전 규칙)과 분류 패키지 HMM 구간을 분 단위로 맞댄다(RPL1101A01).
    /// `TAPTION_REPLAY_OUT`이 있으면 요약 JSON을 그 경로에 쓴다. 판정은 기록만 하고 단정하지 않는다.
    func testCompareStoredTravelWithClassifierTimeline() throws {
        guard let path = ProcessInfo.processInfo.environment["TAPTION_RAW_REPLAY"], !path.isEmpty else {
            throw XCTSkip("TAPTION_RAW_REPLAY 없음")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let days = try (try? JSONDecoder().decode([TodaySensorRawExport].self, from: data))
            ?? [try JSONDecoder().decode(TodaySensorRawExport.self, from: data)]
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        var report: [[String: Any]] = []
        for day in days {
            let readings = day.readings.sorted { $0.timestamp < $1.timestamp }
            guard let first = readings.first?.timestamp, let last = readings.last?.timestamp, last > first else { continue }
            let span = TimeSpan(start: first, end: last)
            let timeline = try ClassifierAdapter.travelTimeline(readings: readings, in: span)
            func storedMode(_ date: Date) -> String {
                day.travel.first { $0.span.contains(date) }?.mode.rawValue ?? "stationary"
            }
            func hmmMode(_ date: Date) -> String {
                guard let segment = timeline.first(where: { $0.span.contains(date) }) else { return "none" }
                return segment.mode?.rawValue ?? "stationary"
            }
            var confusion: [String: Int] = [:]
            var agree = 0, total = 0
            var minute = first
            while minute < last {
                let mid = minute.addingTimeInterval(30)
                let pair = "\(storedMode(mid))→\(hmmMode(mid))"
                confusion[pair, default: 0] += 1
                // 원본 창이 없는 분(none)은 HMM이 판단하지 않은 시간이라 일치율에서 뺀다.
                if hmmMode(mid) != "none" {
                    if storedMode(mid) == hmmMode(mid) { agree += 1 }
                    total += 1
                }
                minute = minute.addingTimeInterval(60)
            }
            func majority(_ window: TimeSpan) -> (mode: String, share: Double) {
                var counts: [String: TimeInterval] = [:]
                for segment in timeline {
                    guard let overlap = segment.span.intersection(with: window)?.duration, overlap > 0 else { continue }
                    counts[segment.mode?.rawValue ?? "stationary", default: 0] += overlap
                }
                guard let best = counts.max(by: { $0.value < $1.value }), window.duration > 0 else { return ("none", 0) }
                return (best.key, (best.value / window.duration * 100).rounded() / 100)
            }
            let segments: [[String: Any]] = day.travel.sorted { $0.span.start < $1.span.start }.map { segment in
                let inside = readings.filter { segment.span.contains($0.timestamp) }
                let around = readings.filter { TravelModeClassifier.altitudeContextSpan(segment.span).contains($0.timestamp) }
                let fresh = TravelModeClassifier().classify(readings: inside, inside: segment.span, altitudeContext: around)
                let hmm = majority(segment.span)
                print("RPL seg \(formatter.string(from: segment.span.start))–\(formatter.string(from: segment.span.end)) "
                    + "stored=\(segment.mode.rawValue) rule=\(fresh.mode.rawValue) hmm=\(hmm.mode)(\(hmm.share)) readings=\(inside.count)")
                return ["start": formatter.string(from: segment.span.start), "end": formatter.string(from: segment.span.end),
                        "minutes": Int(segment.span.duration / 60), "stored": segment.mode.rawValue,
                        "rule": fresh.mode.rawValue, "hmm": hmm.mode, "hmmShare": hmm.share]
            }
            // 규칙(새로 판정) + 역 궤적 감지기 + 혼합을 실제 경로 순서로 거친 최종 구간(HMM1101A01).
            let ruleSegments = day.travel.map { segment -> TravelSegment in
                let inside = readings.filter { segment.span.contains($0.timestamp) }
                let around = readings.filter { TravelModeClassifier.altitudeContextSpan(segment.span).contains($0.timestamp) }
                let fresh = TravelModeClassifier().classify(readings: inside, inside: segment.span, altitudeContext: around)
                return TravelSegment(mode: fresh.mode, span: segment.span, distanceMeters: segment.distanceMeters,
                                     confidence: fresh.confidence, evidence: fresh.evidence, subwayRoute: fresh.subwayRoute)
            }
            let merged = AppleDeviceGroundTruthEngine.mergingTravel(gpsSegments: ruleSegments, motionActivities: [], pedometer: nil, readings: readings)
            let hybrid: [[String: Any]] = ClassifierAdapter.resolvingTravelModes(merged, timeline: timeline).map { segment in
                let rule = merged.first { $0.id == segment.id }?.mode.rawValue ?? "-"
                if segment.mode != .walking || rule != "walking" {
                    print("RPL hybrid \(formatter.string(from: segment.span.start))–\(formatter.string(from: segment.span.end)) rule=\(rule) final=\(segment.mode.rawValue) "
                        + "route=\(segment.subwayRoute?.stops.map(\.stationName).joined(separator: ">") ?? "-")")
                }
                return ["start": formatter.string(from: segment.span.start), "end": formatter.string(from: segment.span.end),
                        "rule": rule, "final": segment.mode.rawValue]
            }
            let extra: [[String: Any]] = timeline.filter { segment in
                segment.mode != nil && segment.span.duration >= 180
                    && !day.travel.contains { $0.span.intersection(with: segment.span) != nil }
            }.map { segment in
                print("RPL hmm-only \(formatter.string(from: segment.span.start))–\(formatter.string(from: segment.span.end)) "
                    + "\(segment.mode?.rawValue ?? "-") score=\(segment.score) m=\(Int(segment.meters))")
                return ["start": formatter.string(from: segment.span.start), "end": formatter.string(from: segment.span.end),
                        "mode": segment.mode?.rawValue ?? "-", "score": segment.score, "meters": Int(segment.meters)]
            }
            let userOwned: [[String: Any]] = (day.actuals ?? []).filter { ActualRecord.userOwned($0) }.map { actual in
                let actualSpan = actual.span(asOf: last)
                let hmm = majority(actualSpan)
                return ["start": formatter.string(from: actualSpan.start), "end": formatter.string(from: actualSpan.end),
                        "category": actual.categoryID, "title": actual.title, "hmm": hmm.mode, "hmmShare": hmm.share]
            }
            let agreement = total > 0 ? (Double(agree) / Double(total) * 1000).rounded() / 10 : 0
            print("RPL day \(formatter.string(from: day.day)) minutes=\(total) agree=\(agreement)% segments=\(timeline.count) userOwned=\(userOwned.count)")
            report.append(["day": formatter.string(from: day.day), "isComplete": day.isComplete, "readings": readings.count,
                           "minutes": total, "agreementPercent": agreement, "confusionMinutes": confusion,
                           "storedSegments": segments, "hybridSegments": hybrid, "hmmOnlySegments": extra, "userOwned": userOwned])
        }
        if let out = ProcessInfo.processInfo.environment["TAPTION_REPLAY_OUT"], !out.isEmpty {
            let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: URL(fileURLWithPath: out))
        }
    }
}

private extension MapHomeVectorNavigationMath {
    static func metersForTest(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let y = (a.latitude - b.latitude) * 111_320, x = (a.longitude - b.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        return (x * x + y * y).squareRoot()
    }
}
