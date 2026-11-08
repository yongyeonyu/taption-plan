import CryptoKit
import TaptionPlanEngine
import XCTest
@testable import TaptionPlan

/// 기기 원본을 손으로 붙인 라벨과 맞대어 판정한다(ALG1102A01).
/// `TEST_RUNNER_TAPTION_RAW_REPLAY`와 `TEST_RUNNER_TAPTION_REPLAY_LABELS`가 있을 때만 돈다.
/// 원본·좌표·라벨은 공개 저장소 밖에 둔다. 라벨은 `{"days":[{"day":"MM-dd","rail":[["HH:mm","HH:mm"]],"notRail":[...],...}]}`이다.
final class RawSensorReplayVerdictTests: XCTestCase {
    private struct Labels: Decodable {
        struct Day: Decodable {
            var day: String
            var rail: [[String]]?
            var notRail: [[String]]?
            var meal: [[String]]?
            var notMeal: [[String]]?
        }
        var days: [Day]
    }

    private lazy var formatter: DateFormatter = {
        let value = DateFormatter()
        value.dateFormat = "MM-dd HH:mm"
        value.timeZone = TimeZone(identifier: "Asia/Seoul")
        return value
    }()

    private func load() throws -> (days: [TodaySensorRawExport], labels: Labels) {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["TAPTION_RAW_REPLAY"], !raw.isEmpty,
              let labelPath = environment["TAPTION_REPLAY_LABELS"], FileManager.default.fileExists(atPath: labelPath) else {
            throw XCTSkip("원본 또는 라벨 없음")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: raw))
        let days = try (try? JSONDecoder().decode([TodaySensorRawExport].self, from: data))
            ?? [JSONDecoder().decode(TodaySensorRawExport.self, from: data)]
        let labels = try JSONDecoder().decode(Labels.self, from: Data(contentsOf: URL(fileURLWithPath: labelPath)))
        return (days, labels)
    }

    private func spans(_ pairs: [[String]]?, day: String) -> [TimeSpan] {
        (pairs ?? []).compactMap { pair in
            guard pair.count == 2,
                  let start = formatter.date(from: "\(day) \(pair[0])"),
                  let end = formatter.date(from: "\(day) \(pair[1])"), end > start else { return nil }
            return TimeSpan(start: start, end: end)
        }
    }

    /// 라벨은 월·일만 있으므로 원본 연도로 옮겨 맞춘다.
    private func shifted(_ spans: [TimeSpan], toYearOf date: Date) -> [TimeSpan] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        let year = calendar.component(.year, from: date)
        return spans.compactMap { span in
            var start = calendar.dateComponents([.month, .day, .hour, .minute], from: span.start)
            var end = calendar.dateComponents([.month, .day, .hour, .minute], from: span.end)
            start.year = year
            end.year = year
            guard let from = calendar.date(from: start), let to = calendar.date(from: end) else { return nil }
            return TimeSpan(start: from, end: to)
        }
    }

    private func covered(_ labels: [TimeSpan], by found: [TimeSpan]) -> (minutes: Double, total: Double) {
        var minutes = 0.0, total = 0.0
        for label in labels {
            total += label.duration / 60
            minutes += found.compactMap { $0.intersection(with: label)?.duration }.reduce(0, +) / 60
        }
        return (minutes, total)
    }

    private func digest(_ days: [TodaySensorRawExport]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = try days.map { try encoder.encode($0.readings) }.reduce(Data(), +)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func testRailJudgementMatchesLabelsAndKeepsRawAndUserRecords() throws {
        let (days, labels) = try load()
        let before = try digest(days)
        for day in days {
            let key = String(formatter.string(from: day.day).prefix(5))
            let readings = day.readings.sorted { $0.timestamp < $1.timestamp }
            let journeys = RailJourneyRecognizer.journeys(readings: readings)
            for journey in journeys {
                print("ALG rail \(formatter.string(from: journey.span.start))–\(formatter.string(from: journey.span.end)) "
                    + "stations=\(journey.stationNames.count) llr=\(String(format: "%.1f", journey.likelihood.logLikelihoodRatio)) "
                    + "\(journey.likelihood.evidence.joined(separator: "|"))")
            }
            for reason in RailJourneyRecognizer.rejections(readings: readings) { print("ALG rail-rejected \(reason)") }
            // 사용자 기록은 판정이 바꾸지 않는다.
            let actuals = day.actuals ?? []
            let retitled = RailJourneyRecognizer.retitling(actuals, subwaySpans: journeys.map(\.span), asOf: day.day.addingTimeInterval(86_400))
            let owned = actuals.filter { ActualRecord.userOwned($0) }
            let ownedAfter = retitled.filter { ActualRecord.userOwned($0) }
            XCTAssertEqual(owned, ownedAfter, "사용자 기록이 바뀌었다 \(key)")

            guard let label = labels.days.first(where: { $0.day == key }) else { continue }
            let found = journeys.map(\.span)
            let rail = covered(shifted(spans(label.rail, day: key), toYearOf: day.day), by: found)
            let wrong = covered(shifted(spans(label.notRail, day: key), toYearOf: day.day), by: found)
            print("ALG rail-verdict \(key) recall=\(Int(rail.minutes))/\(Int(rail.total))분 falsePositive=\(Int(wrong.minutes))/\(Int(wrong.total))분")
            if rail.total > 0 { XCTAssertGreaterThanOrEqual(rail.minutes / rail.total, 0.8, "철도 라벨을 놓쳤다 \(key)") }
            XCTAssertEqual(wrong.minutes, 0, accuracy: 1, "철도 아닌 시간을 철도로 봤다 \(key)")
        }
        XCTAssertEqual(before, try digest(days), "원본이 바뀌었다")
    }

    /// 영역별 수치를 낸다. "전"은 기기에 저장된 옛 결과이거나 옛 계산을 그대로 옮긴 값이다.
    func testAreaNumbersAndMealLabels() throws {
        let (days, labels) = try load()
        for day in days {
            let key = String(formatter.string(from: day.day).prefix(5))
            let readings = day.readings.sorted { $0.timestamp < $1.timestamp }
            guard let first = readings.first?.timestamp, let last = readings.last?.timestamp else { continue }
            let span = TimeSpan(start: first, end: last)
            let actuals = day.actuals ?? []

            // 식사·공백
            let foot = actuals.filter { $0.categoryID == "movement" && $0.title == "걷기" }.map { $0.span(asOf: last) }
            let stays = UnobservedStayEngine.stays(readings: readings, footSpans: foot, inside: span)
            let meals = UnobservedStayEngine.mealCandidates(readings: readings, footSpans: foot, actuals: actuals, inside: span)
            print("ALG gap \(key) unobserved=\(stays.count) minutes=\(Int(stays.map(\.span.duration).reduce(0, +) / 60)) candidates=\(meals.count)")
            for meal in meals {
                print("ALG meal \(formatter.string(from: meal.startedAt))–\(formatter.string(from: meal.endedAt ?? meal.startedAt)) \(meal.evidence.joined(separator: "|"))")
            }
            if let label = labels.days.first(where: { $0.day == key }) {
                let found = meals.map { $0.span(asOf: last) }
                let right = covered(shifted(spans(label.meal, day: key), toYearOf: day.day), by: found)
                let wrong = covered(shifted(spans(label.notMeal, day: key), toYearOf: day.day), by: found)
                print("ALG meal-verdict \(key) recall=\(Int(right.minutes))/\(Int(right.total))분 falsePositive=\(Int(wrong.minutes))/\(Int(wrong.total))분")
                if right.total > 0 { XCTAssertGreaterThanOrEqual(right.minutes / right.total, 0.7, "점심을 놓쳤다 \(key)") }
                XCTAssertEqual(wrong.minutes, 0, accuracy: 1, "식사 아닌 시간을 후보로 봤다 \(key)")
            }
            XCTAssertTrue(meals.allSatisfy { $0.confidence == .low })

            // 임시 경로
            let requests = ExpectedRouteRequestEngine.requests(travel: day.travel, places: [], readings: readings, in: span, through: last)
            let fixes = readings.filter { $0.gpsAvailable && ($0.point?.horizontalAccuracy ?? 999) <= 150 }
            let sparse = zip(fixes, fixes.dropFirst()).filter { lhs, rhs in
                guard let a = lhs.point, let b = rhs.point else { return false }
                let gap = rhs.timestamp.timeIntervalSince(lhs.timestamp)
                let meters = ((a.latitude - b.latitude) * 111_320).magnitude + ((a.longitude - b.longitude) * 88_000).magnitude
                return gap >= 60 && lhs.motion == .automotive && rhs.motion == .automotive
                    && RouteGapKind.classify(duration: gap, distanceMeters: meters, before: .automotive, after: .automotive) == .sparse
            }.count
            print("ALG route \(key) temporaryRequests=\(requests.count) sparseGaps=\(sparse)")

            // 체류
            let detected = PlaceDetectionEngine().detectStays(readings: readings)
            print("ALG stay \(key) storedPlaces=\(day.places?.count ?? 0) fresh=\(detected.count) freshKeys=\(Set(detected.map(\.placeKey)).count)")

            // 3개 원: 하루에 가장 오래 머문 저장 체류의 중심을 등록 지점으로 보고 반경을 줄여 가며 옛 판정과 견준다.
            if let anchor = day.places?.filter({ $0.point != nil }).max(by: { $0.span.duration < $1.span.duration })?.point {
                for radius in [120.0, 60, 30] {
                    var oldRuns: [TimeSpan] = []
                    var runStart: Date?, runLast: Date?
                    for reading in readings where reading.gpsAvailable {
                        guard let point = reading.point else { continue }
                        let inside = PlaceZoneStayTracker.centerDistance(point, anchor) <= radius
                        if inside, let last = runLast, reading.timestamp.timeIntervalSince(last) <= RestaurantMealActualEngine.maximumSampleGap {
                            runLast = reading.timestamp
                        } else {
                            if let begin = runStart, let end = runLast { oldRuns.append(TimeSpan(start: begin, end: end)) }
                            runStart = inside ? reading.timestamp : nil
                            runLast = inside ? reading.timestamp : nil
                        }
                    }
                    if let begin = runStart, let end = runLast { oldRuns.append(TimeSpan(start: begin, end: end)) }
                    let fresh = PlaceZoneStayTracker.stays(readings: readings, center: anchor, radius: radius)
                    func summary(_ spans: [TimeSpan]) -> String {
                        let kept = spans.filter { $0.duration >= RestaurantMealActualEngine.minimumDuration }
                        return "pieces=\(spans.count) over15=\(kept.count) minutes=\(Int(kept.map(\.duration).reduce(0, +) / 60))"
                    }
                    print("ALG zone \(key) r=\(Int(radius)) old[\(summary(oldRuns))] new[\(summary(fresh.map(\.span)))] "
                        + "unobservedMin=\(Int(fresh.flatMap(\.unobserved).map(\.duration).reduce(0, +) / 60))")
                }
            }

            // 층: 옛 계산(처음과 끝의 차이)과 변화율
            var naive = 0, rated = 0
            for stay in detected {
                let inside = readings.filter { stay.span.contains($0.timestamp) && $0.relativeAltitudeMeters != nil }
                for group in Dictionary(grouping: inside, by: { $0.altimeterSessionID }).values {
                    let ordered = group.sorted { $0.timestamp < $1.timestamp }
                    if let a = ordered.first?.relativeAltitudeMeters, let b = ordered.last?.relativeAltitudeMeters,
                       Int(((b - a) / 3).rounded()) != 0 { naive += 1 }
                }
                if FloorEstimator(minimumStableSampleCount: 3).estimate(readings: inside, placeKey: stay.placeKey, baselineFloor: 1) != nil { rated += 1 }
            }
            print("ALG floor \(key) firstLastChanges=\(naive) rateChanges=\(rated)")

            // 수면
            let stored = actuals.filter { $0.categoryID == "sleep" && $0.source == .motion }
            let sleep = PhoneSleepWakeEngine.records(readings: readings, actuals: [], inside: span, watchAvailable: false, maximumSampleGap: 75 * 60, asOf: last)
            print("ALG sleep \(key) storedPhone=\(stored.count) fresh=\(sleep.count) "
                + sleep.map { "\(formatter.string(from: $0.startedAt))–\(formatter.string(from: $0.endedAt ?? $0.startedAt))" }.joined(separator: ","))

            // 걸음·거리
            let oneLine = readings.compactMap(\.stepCount)
            let naiveSteps = zip(oneLine, oneLine.dropFirst()).reduce(0) { $0 + ($1.1 >= $1.0 ? $1.1 - $1.0 : $1.1) }
            let breakdown = WalkingDistanceBreakdown.make(travel: day.travel, readings: readings)
            let gps = breakdown.parts.values.map(\.gpsMeters).reduce(0, +)
            let estimated = breakdown.parts.values.map(\.stepEstimatedMeters).reduce(0, +)
            let stored2 = day.travel.filter { $0.mode == .walking }.map(\.distanceMeters).reduce(0, +)
            print("ALG steps \(key) oneLine=\(naiveSteps) byDevice=\(DeviceStepCounter.increases(in: readings).map { "\($0.key.rawValue):\($0.value)" }.joined(separator: ",")) "
                + "storedWalkM=\(Int(stored2)) gpsM=\(Int(gps)) stepEstM=\(Int(estimated)) stride=\(String(format: "%.2f", breakdown.stride)) calibrated=\(breakdown.isStrideCalibrated)")
        }
    }

    /// 휴대폰 수면 판정을 하루 갱신과 같은 순서(엄격 규칙 → `PhoneSleepFusion`)로 원본에서 다시 낸다(ALG1102A01 SleepFusion 일원화 전후 비교).
    /// `TEST_RUNNER_TAPTION_RAW_REPLAY_DIR`(원본 json 폴더)이 있을 때만 돈다. 시각과 길이만 찍고 좌표는 찍지 않는다.
    func testReplayPhoneSleepDecision() throws {
        guard let folder = ProcessInfo.processInfo.environment["TAPTION_RAW_REPLAY_DIR"], !folder.isEmpty else {
            throw XCTSkip("원본 폴더 없음")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".json") }.sorted()
        var nights = 0, phoneNights = 0, phoneMinutes = 0.0, daytimeMinutes = 0.0
        for file in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent(file))
            let days = try (try? JSONDecoder().decode([TodaySensorRawExport].self, from: data))
                ?? [JSONDecoder().decode(TodaySensorRawExport.self, from: data)]
            let readings = days.flatMap(\.readings).sorted { $0.timestamp < $1.timestamp }
            var seen = Set<UUID>()
            let actuals = days.flatMap { $0.actuals ?? [] }.filter { seen.insert($0.id).inserted }
            let derived = actuals.filter {
                AutomaticModelVersion.matches($0.modelVersion, AutomaticModelVersion.phoneSleep)
                    || AutomaticModelVersion.matches($0.modelVersion, AutomaticModelVersion.strictSleep)
            }
            let kept = actuals.filter { !derived.contains($0) }
            for day in days {
                let span = SleepAnalysisEngine.overnightSpan(containing: Calendar.autoupdatingCurrent.startOfDay(for: day.day))
                let inside = readings.filter { span.contains($0.timestamp) }
                guard let last = inside.last?.timestamp else { continue }
                let wearable = kept.compactMap { actual -> TimeSpan? in
                    guard actual.source == .healthKit || actual.source == .appleWatch,
                          AutomaticRecordTimelineEngine.isSleep(actual) else { return nil }
                    return actual.span(asOf: last).intersection(with: span)
                }
                let strict = TaptionActivityEngineAdapter.strictSleepActuals(
                    readings: inside, actuals: kept, inside: span, homePoint: nil, maximumSampleGap: 20 * 60,
                    authoritativeSleepSpans: wearable, asOf: last
                )
                let records = PhoneSleepFusion.records(
                    readings: inside, actuals: kept, inside: span, nominalMaximumSampleGap: 20 * 60,
                    authoritativeSleepSpans: wearable, strict: strict, asOf: last
                )
                let describe: ([ActualRecord]) -> String = { values in
                    values.map { "\(self.formatter.string(from: $0.startedAt))–\(self.formatter.string(from: $0.endedAt ?? last))(\($0.behavior ?? "-"))" }
                        .joined(separator: ",")
                }
                let minutes = records.map { $0.span(asOf: last).duration / 60 }.reduce(0, +)
                let daytime = records.filter {
                    let hour = Calendar.autoupdatingCurrent.component(.hour, from: $0.startedAt)
                    let endHour = Calendar.autoupdatingCurrent.component(.hour, from: $0.endedAt ?? last)
                    return hour >= 9 && endHour < 21 && Calendar.autoupdatingCurrent.isDate($0.startedAt, inSameDayAs: $0.endedAt ?? last)
                }.map { $0.span(asOf: last).duration / 60 }.reduce(0, +)
                nights += 1
                phoneNights += records.isEmpty ? 0 : 1
                phoneMinutes += minutes
                daytimeMinutes += daytime
                print("SLEEPFUSION \(file.dropFirst(18).prefix(8)) night=\(formatter.string(from: span.end).prefix(5)) wearable=\(wearable.count) "
                    + "strict=\(strict.count) phone=\(records.count) minutes=\(Int(minutes)) daytimeMinutes=\(Int(daytime)) "
                    + "fresh=[\(describe(records))] stored=[\(describe(derived.filter { $0.span(asOf: last).intersection(with: span) != nil }))]")
            }
        }
        print("SLEEPFUSION total nights=\(nights) phoneNights=\(phoneNights) phoneMinutes=\(Int(phoneMinutes)) daytimeMinutes=\(Int(daytimeMinutes))")
    }
}
