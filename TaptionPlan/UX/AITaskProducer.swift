import Foundation

/// AI 확인 목록 2단계(AIQ1111A02). 하루 기록(`/activity`)을 올린 직후 같은 자료에서 앱이 정하지 못한 것을 골라
/// AI 목록에 올린다. AI는 `get_activity`로 그날을 읽고 기존 쓰기 도구(update_activity·merge_records·add_expense)로 고친다.
/// 끝난 지 30분 지난 것만, 하루 5건까지, 같은 것은 한 번만 올린다.
@MainActor
enum AITaskProducer {
    struct Candidate: Equatable {
        var key: String
        var kind: AITaskQueue.Kind
        var text: String
        var context: [String: String]
    }

    static let producedKey = "aiTaskProducedKeys"
    static let perDayLimit = 5
    static let settleDelay: TimeInterval = 30 * 60
    private static let producedLimit = 300
    private static let transitModes: Set<String> = ["subway", "bus"]

    /// 고른 것을 AI 목록에 넣는다. 넣은 것만 기억해, 연결이 없을 때 고른 것은 다음에 다시 본다.
    @discardableResult
    static func enqueue(_ days: [AssistantActivityDay], language: MapHomeLanguage, now: Date,
                        defaults: UserDefaults = .standard) -> Int {
        var produced = defaults.stringArray(forKey: producedKey) ?? []
        let seen = Set(produced)
        var count = 0
        days: for day in days {
            // 목록은 기기 시간대로 날짜를 적으니, 그 날짜의 기기 낮 12시로 넘긴다.
            let date = dayFormatter.date(from: day.date)?.addingTimeInterval(12 * 3_600)
            for candidate in candidates(day, language: language, now: now) where !seen.contains(candidate.key) {
                guard AITaskQueue.enqueue(candidate.kind, text: candidate.text, day: date, context: candidate.context, defaults: defaults)
                else { break days }
                produced.append(candidate.key)
                count += 1
            }
        }
        if produced.count > producedLimit { produced.removeFirst(produced.count - producedLimit) }
        defaults.set(produced, forKey: producedKey)
        return count
    }

    /// 하루에서 확인 거리를 고른다. 순서: 머문 곳 → 교통비 → 조각 합침 → 경로.
    static func candidates(_ day: AssistantActivityDay, language: MapHomeLanguage, now: Date) -> [Candidate] {
        let cutoff = now.addingTimeInterval(-settleDelay)
        let moves = (day.moves ?? []).compactMap { move -> Span<AssistantActivityDay.Move>? in
            span(move, start: move.start, end: move.end)
        }.filter { $0.end <= cutoff }
        let records = day.records.compactMap { span($0, start: $0.start, end: $0.end) }
        func recordIDs(_ start: Date, _ end: Date) -> String {
            records.filter { $0.start < end && $0.end > start }.map(\.value.id).joined(separator: ",")
        }
        func clock(_ start: Date, _ end: Date) -> String { "\(clockFormatter.string(from: start))–\(clockFormatter.string(from: end))" }
        func key(_ kind: AITaskQueue.Kind, _ start: Date) -> String { "\(kind.rawValue)|\(day.date)|\(Int(start.timeIntervalSince1970))" }
        var result: [Candidate] = []

        let unnamed = [language.text("머문 곳", "Place"), "머문 곳", "Place"]
        for visit in (day.visits ?? []).compactMap({ span($0, start: $0.start, end: $0.end) })
        where unnamed.contains(visit.value.place) && visit.value.minutes >= 30 && visit.end <= cutoff {
            result.append(Candidate(
                key: key(.stayPlace, visit.start), kind: .stayPlace,
                text: "\(clock(visit.start, visit.end)) · \(visit.value.place) · \(language.text("\(visit.value.minutes)분", "\(visit.value.minutes) min"))",
                context: ["start": visit.value.start, "end": visit.value.end, "recordIds": recordIDs(visit.start, visit.end)]
            ))
        }

        let expenses = (day.expenses ?? []).filter { $0.category == LedgerCategory.transport.rawValue }.compactMap { parser.date(from: $0.time) }
        for trip in transitTrips(moves) {
            let start = trip.first!.start, end = trip.last!.end
            let paid = expenses.contains { $0 >= start.addingTimeInterval(-settleDelay) && $0 <= end.addingTimeInterval(settleDelay) }
            guard !paid else { continue }
            let modes = trip.map { title($0.value.mode, language) }
            let from = trip.first!.value.from ?? "?", to = trip.last!.value.to ?? "?"
            result.append(Candidate(
                key: key(.fareCheck, start), kind: .fareCheck,
                text: "\(clock(start, end)) · \(from) → \(to) · \(modes.joined(separator: " → "))",
                context: ["start": trip.first!.value.start, "end": trip.last!.value.end, "modes": trip.map(\.value.mode).joined(separator: ","),
                          "from": from, "to": to]
            ))
        }

        for run in fragmentRuns(moves) {
            let start = run.first!.start, end = run.last!.end
            result.append(Candidate(
                key: key(.mergeReview, start), kind: .mergeReview,
                text: "\(clock(start, end)) · \(title(run[0].value.mode, language)) × \(run.count)",
                context: ["start": run.first!.value.start, "end": run.last!.value.end, "mode": run[0].value.mode,
                          "recordIds": recordIDs(start, end)]
            ))
        }

        for move in moves where isUnclear(move.value) {
            result.append(Candidate(
                key: key(.routeCheck, move.start), kind: .routeCheck,
                text: "\(clock(move.start, move.end)) · \(move.value.from ?? "?") → \(move.value.to ?? "?") · \(title(move.value.mode, language))",
                context: ["start": move.value.start, "end": move.value.end, "mode": move.value.mode,
                          "recordIds": recordIDs(move.start, move.end)]
            ))
        }
        return Array(result.prefix(perDayLimit))
    }

    // MARK: 고르는 규칙

    struct Span<Value> {
        var value: Value
        var start: Date
        var end: Date
    }

    /// 지하철·버스 구간을 한 번의 승차로 묶는다. 사이에 걷기만 있고 30분 안이면 환승으로 본다.
    static func transitTrips(_ moves: [Span<AssistantActivityDay.Move>]) -> [[Span<AssistantActivityDay.Move>]] {
        var trips: [[Span<AssistantActivityDay.Move>]] = []
        var current: [Span<AssistantActivityDay.Move>] = []
        var lastTransitEnd: Date?
        for move in moves {
            if transitModes.contains(move.value.mode) {
                guard move.value.minutes >= 3 else { continue }
                if let lastTransitEnd, move.start.timeIntervalSince(lastTransitEnd) <= settleDelay, !current.isEmpty {
                    current.append(move)
                } else {
                    if !current.isEmpty { trips.append(current) }
                    current = [move]
                }
                lastTransitEnd = move.end
            } else if move.value.mode != "walk" {
                if !current.isEmpty { trips.append(current) }
                current = []
                lastTransitEnd = nil
            }
        }
        if !current.isEmpty { trips.append(current) }
        return trips
    }

    /// 같은 수단의 10분 안 조각이 3분 안 틈으로 이어진 묶음(신호 대기·엘리베이터로 쪼개진 이동).
    static func fragmentRuns(_ moves: [Span<AssistantActivityDay.Move>]) -> [[Span<AssistantActivityDay.Move>]] {
        var runs: [[Span<AssistantActivityDay.Move>]] = []
        var current: [Span<AssistantActivityDay.Move>] = []
        for move in moves {
            let short = move.value.minutes < 10
            if short, let last = current.last, last.value.mode == move.value.mode, move.start.timeIntervalSince(last.end) <= 3 * 60 {
                current.append(move)
                continue
            }
            if current.count >= 2 { runs.append(current) }
            current = short ? [move] : []
        }
        if current.count >= 2 { runs.append(current) }
        return runs
    }

    /// 수단이 「기타」로 5분 넘거나, 출발·도착을 모두 모르는 15분 넘는 이동.
    static func isUnclear(_ move: AssistantActivityDay.Move) -> Bool {
        (move.mode == "other" && move.minutes >= 5) || (move.from == nil && move.to == nil && move.minutes >= 15)
    }

    private static func title(_ mode: String, _ language: MapHomeLanguage) -> String {
        TravelMapMode(rawValue: mode)?.title(language) ?? language.text("기타", "Other")
    }

    private static func span<Value>(_ value: Value, start: String, end: String) -> Span<Value>? {
        guard let from = parser.date(from: start), let to = parser.date(from: end), to > from else { return nil }
        return Span(value: value, start: from, end: to)
    }

    /// 하루 기록 시각 글자(`yyyy-MM-dd'T'HH:mmxxx`)를 읽는다.
    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mmxxx"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 보이는 시각은 기기 시간대로.
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
