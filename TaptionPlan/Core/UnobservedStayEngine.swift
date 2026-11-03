import Foundation

/// 위치가 끊긴 시간을 "관측 안 된 체류"로 보고, 식사 시간대면 낮은 신뢰도 식사 후보를 만든다(ALG1102A01).
///
/// iOS가 위치 수집을 멈춘 동안에는 어디에 있었는지 모른다. 그래서 장소를 지어내지 않고,
/// 자리를 뜬 걷기와 돌아온 걷기가 끊긴 시간을 감쌀 때만 후보로 둔다.
/// 후보는 확인 전까지 업무를 잘라 내지 않는다(`RestaurantMealActualEngine.carvingMeals`).
enum UnobservedStayEngine {
    struct Stay: Equatable, Sendable {
        var span: TimeSpan
        var displacementMeters: Double
        var leftOnFoot: Bool
        var returnedOnFoot: Bool
    }

    static let modelVersion = AutomaticModelVersion.mealCandidate
    static let minimumDuration: TimeInterval = 20 * 60
    /// 이보다 멀리 옮겨 갔으면 체류가 아니라 빠진 이동이다.
    static let maximumDisplacementMeters = 1_500.0
    /// 끊김 앞뒤로 이 안에서 걸었어야 자리를 뜬 것으로 본다.
    static let footEvidenceWindow: TimeInterval = 15 * 60
    private static let returnedRadiusMeters = 200.0
    private static let maximumAccuracyMeters = 150.0
    private static let minimumMealOverlap: TimeInterval = 15 * 60
    /// 아침은 뺀다. 집에서 위치가 끊긴 시간과 구분할 근거가 약하다.
    private static let mealHours: [ClosedRange<Double>] = [11...14.5, 17.5...20.5]

    /// 위치 표본 사이가 길게 빈 곳. 그사이 걸은 시간은 빼고 가장 긴 머문 조각을 고른다.
    static func stays(readings: [SensorReading], footSpans: [TimeSpan], inside: TimeSpan) -> [Stay] {
        let located = readings
            .filter { reading in
                guard RouteTimelineTimestamp.isValid(reading.timestamp), inside.contains(reading.timestamp),
                      reading.gpsAvailable, let point = reading.point else { return false }
                return (0...maximumAccuracyMeters).contains(point.horizontalAccuracy)
            }
            .sorted { $0.timestamp < $1.timestamp }
        return zip(located, located.dropFirst()).compactMap { before, after in
            guard let from = before.point, let to = after.point else { return nil }
            let silence = TimeSpan(start: before.timestamp, end: after.timestamp)
            guard silence.duration >= minimumDuration else { return nil }
            let displacement = meters(from, to)
            guard displacement <= maximumDisplacementMeters else { return nil }
            guard let still = longestPiece(of: silence, removing: footSpans), still.duration >= minimumDuration else { return nil }
            let window = footEvidenceWindow
            return Stay(
                span: still,
                displacementMeters: displacement,
                leftOnFoot: footSpans.contains { $0.end > still.start.addingTimeInterval(-window) && $0.start <= still.start },
                returnedOnFoot: footSpans.contains { $0.start < still.end.addingTimeInterval(window) && $0.end >= still.end }
            )
        }
    }

    /// 식사 시간대에 걸어 나갔다 돌아온 끊김만 후보가 된다. 이미 식사·수면·사용자 기록이 있으면 만들지 않는다.
    static func mealCandidates(
        readings: [SensorReading],
        footSpans: [TimeSpan],
        actuals: [ActualRecord],
        activityCorrections: [UUID: ActivityCorrection] = [:],
        inside: TimeSpan,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ActualRecord] {
        // 끼니마다 가장 긴 끊김 하나만 후보다. 점심 뒤 자리에 앉아 끊긴 시간까지 식사로 세지 않는다.
        let eligible = stays(readings: readings, footSpans: footSpans, inside: inside).filter { stay in
            stay.leftOnFoot && stay.returnedOnFoot
                && mealOverlap(stay.span, calendar: calendar) >= minimumMealOverlap
        }
        let longestPerMeal = Dictionary(grouping: eligible) { mealIndex($0.span, calendar: calendar) }
            .values.compactMap { $0.max { $0.span.duration < $1.span.duration } }
            .sorted { $0.span.start < $1.span.start }
        return longestPerMeal.compactMap { stay in
            let isOccupied = actuals.contains { actual in
                guard actual.span(asOf: inside.end).intersection(with: stay.span) != nil else { return false }
                if ActualRecord.userOwned(actual, activityCorrections: activityCorrections) { return true }
                return actual.categoryID == "sleep"
                    || (actual.categoryID == "eating" && !AutomaticModelVersion.matches(actual.modelVersion, modelVersion))
            }
            guard !isOccupied else { return nil }
            var evidence = ["관측 안 된 체류 \(Int(stay.span.duration / 60))분", "식사 시간대", "자리를 뜨기 전 걷기", "돌아온 뒤 걷기"]
            if stay.displacementMeters <= returnedRadiusMeters { evidence.append("같은 자리로 돌아옴") }
            return ActualRecord(
                id: stableUUID("meal-candidate|\(Int(stay.span.start.timeIntervalSinceReferenceDate))"),
                planID: nil,
                title: "식사 후보",
                categoryID: "eating",
                startedAt: stay.span.start,
                endedAt: stay.span.end,
                source: .location,
                confidence: .low,
                createdAt: stay.span.start,
                behavior: "meal",
                evidence: evidence,
                modelVersion: modelVersion
            )
        }
    }

    private static func mealOverlap(_ span: TimeSpan, calendar: Calendar) -> TimeInterval {
        mealSpans(of: span, calendar: calendar).map { span.intersection(with: $0)?.duration ?? 0 }.reduce(0, +)
    }

    private static func mealIndex(_ span: TimeSpan, calendar: Calendar) -> Int {
        let overlaps = mealSpans(of: span, calendar: calendar).map { span.intersection(with: $0)?.duration ?? 0 }
        return overlaps.indices.max { overlaps[$0] < overlaps[$1] } ?? 0
    }

    private static func mealSpans(of span: TimeSpan, calendar: Calendar) -> [TimeSpan] {
        let day = calendar.startOfDay(for: span.start)
        return mealHours.map { hours in
            TimeSpan(
                start: day.addingTimeInterval(hours.lowerBound * 3_600),
                end: day.addingTimeInterval(hours.upperBound * 3_600)
            )
        }
    }

    private static func longestPiece(of span: TimeSpan, removing spans: [TimeSpan]) -> TimeSpan? {
        var pieces = [span]
        for removed in spans {
            pieces = pieces.flatMap { piece -> [TimeSpan] in
                guard piece.intersection(with: removed) != nil else { return [piece] }
                var kept: [TimeSpan] = []
                if removed.start > piece.start { kept.append(TimeSpan(start: piece.start, end: removed.start)) }
                if removed.end < piece.end { kept.append(TimeSpan(start: removed.end, end: piece.end)) }
                return kept
            }
        }
        return pieces.max { $0.duration < $1.duration }
    }

    private static func meters(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let x = (a.longitude - b.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        let y = (a.latitude - b.latitude) * 111_320
        return (x * x + y * y).squareRoot()
    }

    private static func stableUUID(_ key: String) -> UUID {
        var hash: UInt64 = 14_695_981_039_346_656_037
        var bytes = [UInt8](repeating: 0, count: 16)
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        for index in bytes.indices {
            hash = (hash ^ UInt64(index + 1)) &* 1_099_511_628_211
            bytes[index] = UInt8(truncatingIfNeeded: hash >> ((index % 8) * 8))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
