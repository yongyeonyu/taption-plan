import Foundation

/// 정지 구간을 하나의 "정지·휴식" 덩어리로 남기지 않고, 이미 모으고 있는
/// 장소·캘린더·시간 신호만으로 문맥 이름을 붙인다. 새 권한이나 새 수집은
/// 쓰지 않으며, 근거가 없으면 "머무름"으로 남긴다.
enum StationaryContextKind: String, Codable, CaseIterable, Sendable {
    case call
    case meeting
    case work
    case study
    case hobby
    case gymFacility
    case mealPlace
    case cafe
    case homeRest
    case housework
    case waiting
    case unknownStay

    var title: String {
        switch self {
        case .call: "통화"
        case .meeting: "회의"
        case .work: "근무"
        case .study: "수업·학습"
        case .hobby: "취미"
        case .gymFacility: "운동시설"
        case .mealPlace: "식사 장소"
        case .cafe: "카페"
        case .homeRest: "집에서 휴식"
        case .housework: "집안일"
        case .waiting: "대기"
        case .unknownStay: "머무름"
        }
    }

    /// CategoryCatalog.builtIn 에 이미 있는 id 만 사용한다. 정지 구간은
    /// 모두 활동 줄에 남아야 하므로 "movement" 는 쓰지 않는다. 이동 종류로
    /// 두면 MovementDisplayEngine 이 앞뒤 이동과 겹친다고 보고 숨긴다.
    var categoryID: String {
        switch self {
        case .work, .meeting: "work"
        case .study: "study"
        case .hobby: "hobby"
        case .mealPlace: "food"
        case .cafe, .homeRest: "rest"
        case .gymFacility: "exercise"
        case .housework: "routine"
        case .call: "relationship"
        case .waiting, .unknownStay: "activity"
        }
    }

    var systemImage: String {
        switch self {
        case .call: "phone.fill"
        case .meeting: "person.3.fill"
        case .work: "briefcase.fill"
        case .study: "book.fill"
        case .hobby: "paintpalette.fill"
        case .gymFacility: "dumbbell.fill"
        case .mealPlace: "fork.knife"
        case .cafe: "cup.and.saucer.fill"
        case .homeRest: "house.fill"
        case .housework: "washer.fill"
        case .waiting: "hourglass"
        case .unknownStay: "questionmark.circle"
        }
    }
}

/// 문맥 종류와 경쟁하지 않고 따로 붙는 부가 신호.
enum StationaryContextModifier: String, Codable, CaseIterable, Sendable {
    case screenUse
    case mediaPlayback
    case onDesk
    case inPocket

    var label: String {
        switch self {
        case .screenUse: "화면 사용"
        case .mediaPlayback: "미디어 재생"
        case .onDesk: "책상 위"
        case .inPocket: "휴대 중"
        }
    }
}

struct StationaryContextInference: Codable, Hashable, Sendable {
    var kind: StationaryContextKind
    var modifiers: Set<StationaryContextModifier>
    var confidence: ConfidenceLevel
    var score: Double
    var evidence: [String]
    var modelVersion: String

    var title: String { kind.title }
}

/// 이미 보관 중이지만 iPhone 쪽에서 한 번도 읽지 않던 중력·가속 요약에서
/// 기기 자세를 파생한다. 새로 수집하는 값은 없다.
struct PhonePlacementSignal: Hashable, Sendable {
    var sampleCount: Int
    var flatRatio: Double
    var uprightRatio: Double
    var stillRatio: Double

    static let empty = PhonePlacementSignal(
        sampleCount: 0,
        flatRatio: 0,
        uprightRatio: 0,
        stillRatio: 0
    )

    static func make(from readings: [SensorReading]) -> PhonePlacementSignal {
        let gravities = readings.compactMap { $0.deviceMotion?.gravity }
        let deviations = readings.compactMap {
            $0.deviceMotionSummary?.userAccelerationStandardDeviationG
        }
        guard !gravities.isEmpty || !deviations.isEmpty else { return .empty }
        return PhonePlacementSignal(
            sampleCount: max(gravities.count, deviations.count),
            flatRatio: share(
                gravities.filter { abs($0.z) >= 0.94 }.count,
                of: gravities.count
            ),
            uprightRatio: share(
                gravities.filter { abs($0.z) <= 0.35 }.count,
                of: gravities.count
            ),
            stillRatio: share(
                deviations.filter { $0 < 0.005 }.count,
                of: deviations.count
            )
        )
    }

    /// 책상 위에 엎어 둔 상태. 회의 가중치와 `onDesk` 표시에 함께 쓴다.
    var isFlatOnDesk: Bool {
        sampleCount >= 3 && flatRatio >= 0.6 && stillRatio >= 0.7
    }

    /// 세워진 자세가 이어지면 몸에 지닌 것으로 본다.
    var isCarried: Bool {
        sampleCount >= 3 && uprightRatio >= 0.6 && flatRatio < 0.2
    }

    private static func share(_ count: Int, of total: Int) -> Double {
        total > 0 ? Double(count) / Double(total) : 0
    }
}

struct StationaryContextInput: Sendable {
    var stay: PlaceStay
    var placeKind: FrequentPlaceKind?
    var readings: [SensorReading] = []
    var calendarEvents: [CalendarRecord] = []
    /// 통화·미디어·화면 사용처럼 이미 만들어진 자동 기록.
    var actuals: [ActualRecord] = []
    var travel: [TravelSegment] = []
    var watchSummaries: [TaptionWatchSensorSummary] = []
    var calendar: Calendar = .autoupdatingCurrent
    var now: Date = .now
}

struct StationaryContextClassifier: Sendable {
    static let modelVersion = "stationary-context-v1"

    func classify(_ input: StationaryContextInput) -> StationaryContextInference {
        let stay = input.stay.span
        let placement = PhonePlacementSignal.make(
            from: input.readings.filter { stay.contains($0.timestamp) }
        )
        var candidates: [StationaryContextKind: (Double, [String])] = [:]
        func add(
            _ kind: StationaryContextKind,
            _ score: Double,
            _ evidence: String
        ) {
            var current = candidates[kind] ?? (0, [])
            current.0 += score
            current.1.append(evidence)
            candidates[kind] = current
        }

        // 1. CallKit 통화 기록만이 .high 까지 올라갈 수 있다.
        let callOverlap = overlap(
            with: stay,
            in: input.actuals.filter { $0.source == .call },
            asOf: input.now
        )
        if callOverlap >= 60, stay.duration > 0,
           callOverlap >= stay.duration * 0.5 {
            add(.call, 0.90, "CallKit 통화 기록")
        }

        // 2. 체류의 절반 이상을 덮는 캘린더 일정. 하루 종일 일정은 모든
        //    체류를 덮어 버리므로 회의 근거로 쓰지 않는다.
        if let event = coveringEvent(in: input.calendarEvents, stay: stay) {
            if containsMealWord(event.title) {
                add(.mealPlace, 0.74, "식사 일정 '\(event.title)'")
            } else {
                add(.meeting, 0.66, "캘린더 일정 '\(event.title)'")
                if (event.attendeeCount ?? 0) >= 2 {
                    add(.meeting, 0.14, "참석자 \(event.attendeeCount ?? 0)명")
                }
                if input.placeKind == .company {
                    add(.meeting, 0.10, "회사에서 진행")
                }
                if placement.isFlatOnDesk {
                    add(.meeting, 0.08, "기기를 책상에 둔 자세")
                }
            }
        }

        let placeName = input.stay.displayName.lowercased()
        if containsMealWord(placeName) {
            add(.mealPlace, 0.58, "장소 이름: 식사")
        } else if ["카페", "cafe", "coffee"].contains(where: placeName.contains) {
            add(.cafe, 0.55, "장소 이름: 카페")
        }

        // 3. 자주가는 곳 종류에서 오는 기본 문맥.
        switch input.placeKind {
        case .company:
            add(.work, 0.62, "자주가는 곳: 회사")
        case .school:
            add(.study, 0.62, "자주가는 곳: 학교")
        case .academy:
            add(.study, 0.62, "자주가는 곳: 학원")
        case .exercise:
            add(.gymFacility, 0.70, "자주가는 곳: 운동")
        case .home:
            add(.homeRest, 0.45, "자주가는 곳: 집")
        case .hobby:
            add(.hobby, 0.62, "자주가는 곳: 취미")
        case .custom:
            add(.unknownStay, 0.30, "자주가는 곳: 사용자 추가")
        case nil:
            break
        }
        // 시간대만으로 근무를 만들어 내지 않는다. 장소나 일정이 이미 근무를
        // 가리킬 때만 힘을 보탠다.
        if candidates[.work] != nil,
           isWeekdayWorkHours(stay: stay, calendar: input.calendar) {
            add(.work, 0.12, "평일 09–18시")
        }
        if stay.duration >= 90 * 60, let leader = leader(of: candidates) {
            add(leader, 0.08, "90분 이상 체류")
        }

        // 4. 집에서의 손목 움직임으로 집안일과 휴식을 가른다.
        if input.placeKind == .home {
            if input.watchSummaries.contains(where: {
                AppleWatchSensorActivityEngine.sustainedMotion($0)
                    && TimeSpan(start: $0.startedAt, end: $0.endedAt)
                        .intersection(with: stay) != nil
            }) {
                add(.housework, 0.40, "집에서 이어지는 손목 움직임")
            } else if isLowMotion(input.readings, stay: stay, placement: placement) {
                add(.homeRest, 0.30, "집에서 움직임 거의 없음")
            }
        }

        // 5. 이동과 이동 사이의 짧은 정지.
        if stay.duration < 15 * 60,
           abuts(input.travel, endingAt: stay.start),
           abuts(input.travel, startingAt: stay.end) {
            add(.waiting, 0.50, "이동 사이 정지")
        }

        // 6. 근거가 없으면 종류를 지어내지 않는다.
        if candidates.isEmpty {
            add(.unknownStay, 0.25, "장소 문맥 근거 부족")
        }

        let ranked = candidates.sorted {
            $0.value.0 == $1.value.0
                ? $0.key.rawValue < $1.key.rawValue
                : $0.value.0 > $1.value.0
        }
        let winner = ranked.first
            ?? (key: .unknownStay, value: (0.25, ["장소 문맥 근거 부족"]))
        let runnerUpScore = ranked.dropFirst().first?.value.0 ?? 0
        let margin = max(0, winner.value.0 - runnerUpScore)
        let score = min(
            1,
            min(1, winner.value.0) * (0.82 + min(0.18, margin))
        )
        // 통화만 .high 를 쓸 수 있다. 회의를 포함한 나머지는 점수와 무관하게
        // .medium 을 넘지 않는다.
        var confidence = ConfidenceLevel(score: score)
        if winner.key != .call, confidence == .high {
            confidence = .medium
        }
        return StationaryContextInference(
            kind: winner.key,
            modifiers: modifiers(for: input, stay: stay, placement: placement),
            confidence: confidence,
            score: score,
            evidence: Array(Set(winner.value.1)).sorted(),
            modelVersion: Self.modelVersion
        )
    }

    // MARK: - Modifiers

    private func modifiers(
        for input: StationaryContextInput,
        stay: TimeSpan,
        placement: PhonePlacementSignal
    ) -> Set<StationaryContextModifier> {
        var values: Set<StationaryContextModifier> = []
        let screenUse = overlap(
            with: stay,
            in: input.actuals.filter { $0.source == .appUsage },
            asOf: input.now
        )
        if stay.duration > 0, screenUse >= stay.duration * 0.35 {
            values.insert(.screenUse)
        }
        let media = overlap(
            with: stay,
            in: input.actuals.filter { $0.source == .media },
            asOf: input.now
        )
        if media >= 60 { values.insert(.mediaPlayback) }
        if placement.isFlatOnDesk { values.insert(.onDesk) }
        if placement.isCarried { values.insert(.inPocket) }
        return values
    }

    // MARK: - Signals

    private func overlap(
        with stay: TimeSpan,
        in actuals: [ActualRecord],
        asOf now: Date
    ) -> TimeInterval {
        actuals.reduce(0) { total, actual in
            total + (
                actual.span(asOf: now).intersection(with: stay)?.duration ?? 0
            )
        }
    }

    private func coveringEvent(
        in events: [CalendarRecord],
        stay: TimeSpan
    ) -> CalendarRecord? {
        guard stay.duration > 0 else { return nil }
        return events
            .filter { !$0.isAllDay && $0.isCancelled != true }
            .filter {
                ($0.span.intersection(with: stay)?.duration ?? 0)
                    >= stay.duration * 0.5
            }
            .max { lhs, rhs in
                (lhs.attendeeCount ?? 0) < (rhs.attendeeCount ?? 0)
            }
    }

    private func isWeekdayWorkHours(stay: TimeSpan, calendar: Calendar) -> Bool {
        let middle = stay.start.addingTimeInterval(stay.duration / 2)
        let weekday = calendar.component(.weekday, from: middle)
        guard weekday != 1, weekday != 7 else { return false }
        let hour = calendar.component(.hour, from: middle)
        return hour >= 9 && hour < 18
    }

    private func containsMealWord(_ value: String) -> Bool {
        let text = value.lowercased()
        return [
            "아침", "점심", "저녁", "식사", "식당", "restaurant", "lunch",
            "dinner", "breakfast",
        ].contains(where: text.contains)
    }

    private func isLowMotion(
        _ readings: [SensorReading],
        stay: TimeSpan,
        placement: PhonePlacementSignal
    ) -> Bool {
        let inside = readings.filter { stay.contains($0.timestamp) }
        guard !inside.isEmpty else { return placement.stillRatio >= 0.7 }
        let stationary = inside.filter { $0.motion == .stationary }.count
        return Double(stationary) / Double(inside.count) >= 0.7
            || placement.stillRatio >= 0.7
    }

    private func abuts(
        _ travel: [TravelSegment],
        endingAt boundary: Date,
        tolerance: TimeInterval = 5 * 60
    ) -> Bool {
        travel.contains {
            abs($0.span.end.timeIntervalSince(boundary)) <= tolerance
        }
    }

    private func abuts(
        _ travel: [TravelSegment],
        startingAt boundary: Date,
        tolerance: TimeInterval = 5 * 60
    ) -> Bool {
        travel.contains {
            abs($0.span.start.timeIntervalSince(boundary)) <= tolerance
        }
    }

    private func leader(
        of candidates: [StationaryContextKind: (Double, [String])]
    ) -> StationaryContextKind? {
        candidates
            .sorted {
                $0.value.0 == $1.value.0
                    ? $0.key.rawValue < $1.key.rawValue
                    : $0.value.0 > $1.value.0
            }
            .first?
            .key
    }
}

/// 사용자가 설정에서 직접 맞춘 자주가는 곳의 중심과 반경.
struct FrequentPlaceAnchor: Hashable, Sendable {
    var point: GeoPoint
    var radiusMeters: Double
}

extension FrequentPlaceResolutionEngine {
    /// `kindsByPlaceKey` 와 짝이다. 체류를 이을지 정할 때 쓰는 중심과 반경은
    /// 사용자가 설정에서 맞춘 값 그대로이고, 여기서 새 거리를 만들지 않는다.
    func anchorsByPlaceKey(
        _ frequentPlaces: [FrequentPlace]
    ) -> [String: FrequentPlaceAnchor] {
        frequentPlaces.reduce(into: [String: FrequentPlaceAnchor]()) {
            values, place in
            guard let point = place.point else { return }
            values[place.stablePlaceKey] = FrequentPlaceAnchor(
                point: point,
                radiusMeters: place.radiusMeters
            )
        }
    }
}

/// 체류 하나를 문맥 기록 하나로 바꾼다. 자동 기록이므로 원본을 보존하고
/// 사용자 편집은 허용하지 않는다.
enum StationaryContextActualEngine {
    /// 장소 체류가 없는 정지 구간에 붙이는 키. 자주가는 곳과 겹치지 않는다.
    static let motionOnlyPlaceKey = "stationary-context-motion"

    /// 등록하지 않은 곳에는 사용자가 맞춘 반경이 없다. 층이 갈려 둘로 나뉜
    /// 자국이나 표본이 잠깐 빈 자국만 메우고, 그보다 벌어지면 잇지 않는다.
    static let unregisteredJoinTolerance: TimeInterval = 5 * 60

    /// 등록한 곳에서 위치가 한 점도 찍히지 않은 시간을 잇는 한계. 실내에서는
    /// GPS가 통째로 끊기므로 머문 것도 벗어난 것도 보이지 않는다. 그때는
    /// 이어 주되, 보이지 않는 하루를 통째로 지어내지는 않는다.
    static let unprovenJoinLimit: TimeInterval = 60 * 60

    static func records(
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        placeAnchors: [String: FrequentPlaceAnchor] = [:],
        stationarySpans: [TimeSpan] = [],
        readings: [SensorReading] = [],
        calendarEvents: [CalendarRecord] = [],
        actuals: [ActualRecord] = [],
        travel: [TravelSegment] = [],
        watchSummaries: [TaptionWatchSensorSummary] = [],
        inside: TimeSpan,
        minimumDuration: TimeInterval = 5 * 60,
        calendar: Calendar = .autoupdatingCurrent,
        now: Date = .now
    ) -> [ActualRecord] {
        let classifier = StationaryContextClassifier()
        return contextStays(
            stays: stays,
            placeAnchors: placeAnchors,
            registeredKeys: Set(placeKinds.keys),
            readings: readings,
            stationarySpans: stationarySpans,
            inside: inside,
            minimumDuration: minimumDuration
        ).map { stay in
            let inference = classifier.classify(
                StationaryContextInput(
                    stay: stay,
                    placeKind: placeKinds[stay.placeKey],
                    readings: readings,
                    calendarEvents: calendarEvents,
                    actuals: actuals,
                    travel: travel,
                    watchSummaries: watchSummaries,
                    calendar: calendar,
                    now: now
                )
            )
            var evidence = inference.evidence
            evidence.append(contentsOf: StationaryContextModifier.allCases
                .filter { inference.modifiers.contains($0) }
                .map(\.label))
            return ActualRecord(
                id: stableID(placeKey: stay.placeKey, span: stay.span),
                planID: nil,
                routineID: nil,
                title: inference.kind.title,
                categoryID: inference.kind.categoryID,
                startedAt: stay.span.start,
                endedAt: stay.span.end,
                source: .location,
                confidence: inference.confidence,
                createdAt: stay.span.start,
                behavior: inference.kind.rawValue,
                evidence: evidence,
                modelVersion: inference.modelVersion
            )
        }
    }

    /// 문맥의 근거는 장소 체류지만, 실내처럼 GPS가 끊긴 시간에는 체류가
    /// 아예 만들어지지 않는다. 그 시간이 "정지·휴식" 한 덩어리로 남지 않게
    /// 체류가 덮지 못한 정지 구간도 후보로 넣는다. 근거가 없으면 분류를
    /// 지어내지 않고 "머무름"으로 남는다.
    private static func contextStays(
        stays: [PlaceStay],
        placeAnchors: [String: FrequentPlaceAnchor],
        registeredKeys: Set<String>,
        readings: [SensorReading],
        stationarySpans: [TimeSpan],
        inside: TimeSpan,
        minimumDuration: TimeInterval
    ) -> [PlaceStay] {
        let clipped = stays.compactMap { stay -> PlaceStay? in
            guard let span = stay.span.intersection(with: inside) else {
                return nil
            }
            var value = stay
            value.span = span
            return value
        }
        .sorted { $0.span.start < $1.span.start }
        // 짧은 체류를 먼저 버리면 이어 붙일 조각까지 사라진다. 잇고 난 뒤에
        // 재어야 한 곳에 오래 있었다는 사실이 그대로 남는다.
        let placed = joiningContinuousStays(
            clipped,
            anchors: placeAnchors,
            registeredKeys: registeredKeys,
            readings: readings
        )
        .filter { $0.span.duration >= minimumDuration }
        let covered = ActualIntervalMergeEngine.union(placed.map(\.span))
        let uncovered = ActualIntervalMergeEngine.union(
            stationarySpans.compactMap { $0.intersection(with: inside) },
            mergeGap: 60
        )
        .flatMap { subtracting(covered, from: $0) }
        .filter { $0.duration >= minimumDuration }
        .map {
            PlaceStay(
                placeKey: motionOnlyPlaceKey,
                displayName: "정지 구간",
                span: $0,
                confidence: .low
            )
        }
        return (placed + uncovered).sorted { $0.span.start < $1.span.start }
    }

    /// 등록해 둔 곳 안에 계속 있었다면 시간표도 한 줄이어야 한다. 층이
    /// 바뀌어도, 자리를 떠나 건물 안을 걸어 다녀도 그 곳을 벗어난 것이 아니다.
    /// 반경 밖에서 찍힌 위치가 하나라도 있으면 그때는 나갔다 온 것이라 잇지
    /// 않는다 — 그래야 출근·퇴근과 일과 고리가 뜻을 잃지 않는다.
    private static func joiningContinuousStays(
        _ stays: [PlaceStay],
        anchors: [String: FrequentPlaceAnchor],
        registeredKeys: Set<String>,
        readings: [SensorReading]
    ) -> [PlaceStay] {
        guard stays.count > 1 else { return stays }
        let located = readings
            .filter { $0.point != nil }
            .sorted { $0.timestamp < $1.timestamp }
        var result: [PlaceStay] = []
        for stay in stays {
            guard let hostIndex = result.lastIndex(where: {
                $0.placeKey == stay.placeKey
            }), stayedThrough(
                between: result[hostIndex],
                and: stay,
                passing: Array(result[(hostIndex + 1)...]),
                anchor: anchors[stay.placeKey],
                registeredKeys: registeredKeys,
                readings: located
            ) else {
                result.append(stay)
                continue
            }
            // 사이에 낀 조각은 이어진 구간이 덮어야 한다. 그 조각이 더 늦게
            // 끝났다면 거기까지 늘려야 시간을 잃지 않는다. 원본 체류는
            // snapshot.places 에 그대로 남아 근거를 잃지 않는다.
            let ends = result[hostIndex...].map(\.span.end) + [stay.span.end]
            result[hostIndex].span = TimeSpan(
                start: result[hostIndex].span.start,
                end: ends.max() ?? stay.span.end
            )
            result.removeSubrange((hostIndex + 1)...)
        }
        return result
    }

    /// 두 체류 사이에 그 곳을 벗어난 자취가 없는지 본다.
    private static func stayedThrough(
        between host: PlaceStay,
        and next: PlaceStay,
        passing: [PlaceStay],
        anchor: FrequentPlaceAnchor?,
        registeredKeys: Set<String>,
        readings: [SensorReading]
    ) -> Bool {
        // 사이에 다른 등록된 곳에 머문 자국이 있으면 그리로 옮겨 간 것이다.
        if passing.contains(where: {
            $0.placeKey != host.placeKey && registeredKeys.contains($0.placeKey)
        }) {
            return false
        }
        let gap = TimeSpan(
            start: host.span.end,
            end: max(host.span.end, next.span.start)
        )
        guard let anchor else {
            return passing.isEmpty
                && gap.duration <= unregisteredJoinTolerance
        }
        // 사이에 낀 체류도 사용자가 맞춘 반경 안이어야 한다.
        if passing.contains(where: { outside($0.point, anchor) }) {
            return false
        }
        let sampled = readings.filter { gap.contains($0.timestamp) }
        if sampled.contains(where: { outside($0.point, anchor) }) {
            return false
        }
        // 반경 안에서 찍힌 위치가 있으면 얼마나 벌어졌든 머문 것이다.
        // 점심을 먹으러 건물 안을 돌아다닌 시간이 여기에 들어온다.
        if !sampled.isEmpty { return true }
        return gap.duration <= unprovenJoinLimit
    }

    private static func outside(
        _ point: GeoPoint?,
        _ anchor: FrequentPlaceAnchor
    ) -> Bool {
        guard let point else { return false }
        return distanceMeters(point, anchor.point) > anchor.radiusMeters
    }

    /// `covered` 는 시작 시각 순으로 정렬되고 서로 겹치지 않는다.
    private static func subtracting(
        _ covered: [TimeSpan],
        from span: TimeSpan
    ) -> [TimeSpan] {
        var remaining: [TimeSpan] = []
        var cursor = span.start
        for block in covered where block.end > span.start
            && block.start < span.end {
            if block.start > cursor {
                remaining.append(
                    TimeSpan(start: cursor, end: min(block.start, span.end))
                )
            }
            cursor = max(cursor, block.end)
            if cursor >= span.end { break }
        }
        if cursor < span.end {
            remaining.append(TimeSpan(start: cursor, end: span.end))
        }
        return remaining.filter { $0.duration > 0 }
    }

    /// 문맥 기록이 덮은 구간의 옛 "정지·휴식" 기록을 같은 갱신에서 걷어낸다.
    static func suppressingStationaryMotion(
        _ actuals: [ActualRecord],
        coveredBy contextRecords: [ActualRecord],
        asOf now: Date
    ) -> [ActualRecord] {
        guard !contextRecords.isEmpty else { return actuals }
        return actuals.filter { actual in
            guard actual.source == .motion,
                  actual.behavior == MotionKind.stationary.rawValue else {
                return true
            }
            let span = actual.span(asOf: now)
            return !contextRecords.contains { context in
                guard let overlap = context.span(asOf: now)
                        .intersection(with: span) else { return false }
                return overlap.duration >= min(span.duration * 0.5, 30)
            }
        }
    }

    /// SensorFusion 의 자동 기록과 같은 방식으로 안정된 식별자를 만든다.
    private static func stableID(placeKey: String, span: TimeSpan) -> UUID {
        let key = [
            placeKey,
            String(Int(span.start.timeIntervalSinceReferenceDate.rounded())),
            String(Int(span.end.timeIntervalSinceReferenceDate.rounded())),
        ].joined(separator: "|")
        var hash: UInt64 = 14_695_981_039_346_656_037
        var bytes = [UInt8](repeating: 0, count: 16)
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        for index in bytes.indices {
            hash ^= UInt64(index + 1) * 0x9E37_79B9
            hash = hash &* 1_099_511_628_211
            bytes[index] = UInt8(truncatingIfNeeded: hash >> ((index % 8) * 8))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
