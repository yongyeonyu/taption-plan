import Foundation
import TaptionPlanEngine
import TaptionPlanStore

/// 병합 엔진의 `FlightCard`와 여행 일정 칸(`TravelTripItem`, kind `flight`)을 오가는 변환(FLT1119A01).
/// 카드가 가진 값 가운데 일정 칸에 칸이 없는 것(항공사 이름·체크인·현장 안내·메모·출처·지연 이력·확신도)은 `flightLog`(JSON 글)에 둔다.
/// 예약번호(`pnrLocal`)와 `flightLog`는 기기 안(백업 파일 안)에만 있고 서버·AI·분석으로 가지 않는다.
enum FlightCardMapping {
    struct Log: Codable, Equatable {
        struct Change: Codable, Equatable {
            var before: String?
            var after: String?
            var delay: Int
            var reason: String?
            var at: Double
        }

        var airlineName: String?
        var checkInOpen: Bool?
        var checkInDeadline: Int?
        var onsiteArrive: Int?
        var notes: [String]?
        var sources: [String: String]?
        var changes: [Change]?
        var confidence: Double?
        var receivedAt: Double?
        /// 출발 시각을 아직 모른다(②에서 만든 카드). 일정 칸에는 낮 12시를 놓았다.
        var timeUnknown: Bool?
    }

    static let maximumLogBytes = 8_000
    /// 시각을 모를 때 일정 칸에 놓는 자리(현지 낮 12시).
    static let placeholderMinute = 12 * 60
    /// 비행 시간을 알 수 없을 때(알려지지 않은 공항) 일정 칸 길이(분).
    static let fallbackMinutes = 120

    static func cardID(tripID: String, itemID: String) -> String { "\(tripID)|\(itemID)" }

    static func split(cardID: String) -> (tripID: String, itemID: String)? {
        let parts = cardID.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty ? (parts[0], parts[1]) : nil
    }

    static func log(of item: TravelTripItem) -> Log {
        guard let text = item.flightLog, text.utf8.count <= maximumLogBytes, let log = try? JSONDecoder().decode(Log.self, from: Data(text.utf8)) else { return Log() }
        return log
    }

    static func encode(_ log: Log) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(log), data.count <= maximumLogBytes else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text == "{}" ? nil : text
    }

    // MARK: 일정 칸 → 카드

    static func card(from item: TravelTripItem) -> FlightCard? {
        guard item.isFlight else { return nil }
        let log = log(of: item)
        let date = TravelTripDay.string(for: item.start, offsetSeconds: item.startOffsetSeconds)
        let local = Int(item.start.timeIntervalSince1970) + item.startOffsetSeconds
        let minute = ((local % 86_400) + 86_400) % 86_400 / 60
        let time = log.timeUnknown == true ? nil : FlightAlertTime(hour: minute / 60, minute: minute % 60)
        let sources = (log.sources ?? [:]).compactMapValues(FlightFieldSource.init(rawValue:))
        let changes = (log.changes ?? []).map { change in
            FlightChange(flight: item.flightNumber ?? "", before: wall(change.before), after: wall(change.after), delayMinutes: change.delay, reason: change.reason,
                         receivedAt: Date(timeIntervalSince1970: change.at))
        }
        return FlightCard(
            id: cardID(tripID: item.tripID, itemID: item.itemID), flight: item.flightNumber, airline: item.flightNumber.map { String($0.prefix(2)) },
            airlineName: log.airlineName, pnr: item.pnrLocal, origin: item.originCode, destination: item.destinationCode, date: date, time: time,
            terminal: item.terminal, gate: item.gate,
            checkIn: log.checkInOpen.map { FlightAlertCheckIn(isOpen: $0, deadlineMinutesBeforeDeparture: log.checkInDeadline) },
            onsiteArriveMinutesBefore: log.onsiteArrive, changes: changes, notes: log.notes ?? [], sources: sources,
            confidence: log.confidence ?? 1, receivedAt: Date(timeIntervalSince1970: log.receivedAt ?? 0)
        )
    }

    /// `2027-03-07T14:20` 꼴 글 → 현지 벽시계.
    private static func wall(_ text: String?) -> FlightLocalTime? {
        guard let text, text.count == 16 else { return nil }
        let parts = text.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        return parts.count == 5 ? FlightLocalTime(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4]) : nil
    }

    private static func text(_ time: FlightLocalTime?) -> String? {
        time.map { String(format: "%04d-%02d-%02dT%02d:%02d", $0.year, $0.month, $0.day, $0.hour, $0.minute) }
    }

    // MARK: 카드 → 일정 칸

    /// 카드의 값을 일정 칸에 쓴다(칸 값·`flightLog`). 시각(start·end·offset)은 `schedule`이 따로 정한다.
    static func apply(_ card: FlightCard, to item: inout TravelTripItem) {
        var fields = TravelFlightFields(
            flightNumber: card.flight, originCode: card.origin, destinationCode: card.destination, terminal: card.terminal, gate: card.gate,
            baggageClaim: item.baggageClaim, legIndex: item.legIndex, itineraryID: item.itineraryID, pnrLocal: card.pnr
        )
        fields.flightNumber = card.flight
        item.apply(fields)
        item.flightLog = encode(Log(
            airlineName: card.airlineName, checkInOpen: card.checkIn?.isOpen, checkInDeadline: card.checkIn?.deadlineMinutesBeforeDeparture,
            onsiteArrive: card.onsiteArriveMinutesBefore, notes: card.notes.isEmpty ? nil : card.notes,
            sources: card.sources.isEmpty ? nil : card.sources.mapValues(\.rawValue),
            changes: card.changes.isEmpty ? nil : card.changes.suffix(20).map { Log.Change(before: text($0.before), after: text($0.after), delay: $0.delayMinutes, reason: $0.reason, at: $0.receivedAt.timeIntervalSince1970) },
            confidence: card.confidence == 1 ? nil : card.confidence, receivedAt: card.receivedAt.timeIntervalSince1970 > 0 ? card.receivedAt.timeIntervalSince1970 : nil,
            timeUnknown: card.time == nil ? true : nil
        ))
    }

    struct Schedule: Equatable {
        var start: Date
        var end: Date
        var startOffsetSeconds: Int
        var endOffsetSeconds: Int
    }

    /// 카드의 날짜·시각·노선으로 일정 칸의 시각을 정한다. 출발 현지 날짜가 없거나 공항을 모르면 nil.
    /// 시각을 모르면 현지 낮 12시를 놓고, 길이는 비행 시간 어림(없으면 2시간)이다.
    static func schedule(for card: FlightCard) -> Schedule? {
        guard let date = card.date, let parts = TravelTripDay.components(date), let year = parts.year, let month = parts.month, let day = parts.day,
              let origin = card.origin, let zoneID = FlightAirportCatalog.airport(origin)?.timeZone, let zone = TimeZone(identifier: zoneID) else { return nil }
        let minute = card.time?.minutes ?? placeholderMinute
        let local = FlightLocalTime(year: year, month: month, day: day, hour: minute / 60, minute: minute % 60)
        guard let start = FlightTimeMath.instant(local, zone: zoneID) else { return nil }
        let duration = card.destination.flatMap { FlightPlacement.estimatedMinutes(origin: origin, destination: $0) } ?? fallbackMinutes
        let end = start.addingTimeInterval(Double(duration) * 60)
        let endZone = card.destination.flatMap { FlightAirportCatalog.airport($0)?.timeZone }.flatMap(TimeZone.init(identifier:)) ?? zone
        return Schedule(start: start, end: end, startOffsetSeconds: zone.secondsFromGMT(for: start), endOffsetSeconds: endZone.secondsFromGMT(for: end))
    }

    /// 카드 제목: `AB123 ICN → BKK`, 편명이 없으면 노선만, 노선도 없으면 「항공편」.
    static func title(for card: FlightCard) -> String {
        let route = [card.origin, card.destination].compactMap { $0 }.joined(separator: " → ")
        return [card.flight, route.isEmpty ? nil : route].compactMap { $0 }.joined(separator: " ")
    }
}
