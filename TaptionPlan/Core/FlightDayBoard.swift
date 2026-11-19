import Foundation
import TaptionPlanStore

/// 출발 당일 여행 모드 상단 배너가 보여 줄 줄(FLT1119A01): 지연·결항, 터미널, 탑승구, 수하물 수취대, 「정기 스케줄 기준 / 실시간」.
/// 저장된 일정 칸 값에 공공데이터 운항현황(`live`)을 덮어 보인다. 운항현황은 저장하지 않고 화면에만 쓴다.
struct FlightDayRow: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    /// 출발 공항 현지 시각 `HH:mm`(지연이면 새 시각).
    var timeText: String
    var delayMinutes: Int
    var isCancelled: Bool
    var terminal: String?
    var gate: String?
    var baggage: String?
    /// 공공데이터 운항현황이 반영된 줄인가(아니면 정기 스케줄·알림 기준).
    var isLive: Bool
}

enum FlightDayBoard {
    /// 출발 이만큼 전부터(이미 떠난 비행도 잠깐) 이만큼 뒤까지 보인다.
    static let showsAfterDeparture: TimeInterval = 3 * 3_600
    static let showsBeforeDeparture: TimeInterval = 24 * 3_600

    static func rows(items: [TravelTripItem], live: [String: FlightListing], now: Date) -> [FlightDayRow] {
        items.filter { $0.isFlight && $0.start > now.addingTimeInterval(-showsAfterDeparture) && $0.start < now.addingTimeInterval(showsBeforeDeparture) }
            .sorted { $0.start < $1.start }
            .map { item in
                let status = item.flightNumber.flatMap { live[$0] }?.status
                let stored = FlightCardMapping.card(from: item)?.currentDelayMinutes ?? 0
                let delay = status?.state == "delayed" ? max(status?.delayMinutes ?? 0, 0) : stored
                let local = Int(item.start.timeIntervalSince1970) + item.startOffsetSeconds
                let minute = ((local % 86_400) + 86_400) % 86_400 / 60
                return FlightDayRow(
                    id: "\(item.tripID)|\(item.itemID)", title: item.title, timeText: String(format: "%02d:%02d", minute / 60, minute % 60), delayMinutes: delay,
                    isCancelled: status?.state == "cancelled", terminal: clean(status?.terminal) ?? clean(item.terminal), gate: clean(status?.gate) ?? clean(item.gate),
                    baggage: clean(status?.baggage) ?? clean(item.baggageClaim), isLive: status != nil
                )
            }
    }

    /// 운항현황을 물을 비행: 인천 출발은 출발 조회, 인천 도착은 도착 조회. 그날(출발 현지 날짜)과 편명만 서버로 보낸다.
    static func lookups(items: [TravelTripItem], now: Date) -> [(flight: String, day: String, direction: FlightLookup.Direction)] {
        items.filter { $0.isFlight && $0.start > now.addingTimeInterval(-showsAfterDeparture) && $0.start < now.addingTimeInterval(showsBeforeDeparture) }.compactMap { item in
            guard let flight = item.flightNumber else { return nil }
            let day = TravelTripDay.string(for: item.start, offsetSeconds: item.startOffsetSeconds)
            if item.originCode == "ICN" { return (flight, day, .dep) }
            if item.destinationCode == "ICN" { return (flight, TravelTripDay.string(for: item.end, offsetSeconds: item.endOffsetSeconds), .arr) }
            return nil
        }
    }

    private static func clean(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespaces)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
