import Foundation
import TaptionPlanEngine
import TaptionPlanStore

/// 고른 항공편을 여행 일정 한 칸으로 만든다(FLT1119A01). 시차·도착 시각은 `FlightTimeMath`와 `FlightAirportCatalog`만 쓰고,
/// 서버는 도착 시각을 주지 않으므로 비행 시간을 모르면 거리로 어림하고 그 사실(`isEstimated`)을 남긴다.
enum FlightPlacement {
    /// 일정 칸에 넣을 값. 시각은 그 순간(절대 시각)과 그 공항 시간대의 UTC 차(초)다.
    struct Draft: Equatable, Sendable {
        var title: String
        var start: Date
        var end: Date
        var startOffsetSeconds: Int
        var endOffsetSeconds: Int
        var fields: TravelFlightFields
        /// 도착 시각을 비행 시간이 아니라 거리로 어림했는가.
        var isEstimated: Bool
        /// 도착 현지 날짜가 출발 현지 날짜보다 며칠 뒤인가.
        var arrivalDayOffset: Int
        /// 지도·지구본에 찍을 도착 공항 핀(이름·좌표). 구간이 이어지면 도착 공항끼리 대권 선으로 이어진다.
        var arrivalPlace: TravelItemPlace?
    }

    /// 거리로 어림한 비행 시간(분): 순항 800km/h + 이착륙·활주 30분. 가까운 곳도 최소 45분.
    static func estimatedMinutes(origin: String, destination: String) -> Int? {
        guard let a = FlightAirportCatalog.airport(origin), let b = FlightAirportCatalog.airport(destination) else { return nil }
        let km = GreatCircle.distanceKm(
            from: RouteCoordinate(latitude: a.latitude, longitude: a.longitude), to: RouteCoordinate(latitude: b.latitude, longitude: b.longitude)
        )
        return max(45, Int((km / 800 * 60).rounded()) + 30)
    }

    /// 목록에서 고른 줄 → 한 구간. `day`는 그 공항 달력의 날(`YYYY-MM-DD`).
    /// 출발 조회면 그 시각이 출발 시각이고, 도착 조회면 도착 시각이다(출발은 거꾸로 계산하지 않고 비운다).
    static func leg(from listing: FlightListing, day: String, direction: FlightLookup.Direction, durationMinutes: Int? = nil) -> FlightLeg? {
        guard let parts = TravelTripDay.components(day), let year = parts.year, let month = parts.month, let dayOfMonth = parts.day,
              let minute = FlightLookup.clockMinute(listing.time) else { return nil }
        let local = FlightLocalTime(year: year, month: month, day: dayOfMonth, hour: minute / 60, minute: minute % 60)
        let source = "publicData"
        if direction == .dep {
            return FlightLeg(
                flight: listing.flight, airline: listing.airline, origin: listing.origin, destination: listing.destination, departure: local,
                durationMinutes: durationMinutes ?? estimatedMinutes(origin: listing.origin, destination: listing.destination),
                terminal: listing.status?.terminal ?? listing.terminal, gate: listing.status?.gate ?? listing.gate, baggage: listing.status?.baggage,
                source: source, confidence: durationMinutes == nil ? 0.8 : 1
            )
        }
        return FlightLeg(
            flight: listing.flight, airline: listing.airline, origin: listing.origin, destination: listing.destination, arrival: local,
            durationMinutes: durationMinutes ?? estimatedMinutes(origin: listing.origin, destination: listing.destination),
            terminal: listing.status?.terminal ?? listing.terminal, gate: listing.status?.gate ?? listing.gate, baggage: listing.status?.baggage,
            source: source, confidence: 0.8
        )
    }

    /// 손으로 넣은 한 구간(편명·시각을 직접 적었을 때).
    static func manualLeg(flight: String?, origin: String, destination: String, day: String, minute: Int, durationMinutes: Int?) -> FlightLeg? {
        guard let parts = TravelTripDay.components(day), let year = parts.year, let month = parts.month, let dayOfMonth = parts.day, (0..<1_440).contains(minute) else { return nil }
        let code = flight?.replacingOccurrences(of: " ", with: "").uppercased()
        return FlightLeg(
            flight: code?.isEmpty == false ? code : nil, airline: code.flatMap { $0.count >= 2 ? String($0.prefix(2)) : nil }, origin: origin, destination: destination,
            departure: FlightLocalTime(year: year, month: month, day: dayOfMonth, hour: minute / 60, minute: minute % 60),
            durationMinutes: durationMinutes ?? estimatedMinutes(origin: origin, destination: destination), source: "manual", confidence: durationMinutes == nil ? 0.8 : 1
        )
    }

    /// 일정 칸으로. 도착 조회로 고른 줄은 출발 시각이 없어, 도착 시각에서 비행 시간을 거꾸로 빼 어림한다(`isEstimated`).
    static func draft(for leg: FlightLeg, legIndex: Int? = nil, itineraryID: String? = nil) -> Draft? {
        var start = leg.departureInstant
        var end = leg.arrivalInstant
        // 비행 시간을 직접 받았거나(`confidence` 1) 도착 시각이 글로 주어진 것이 아니면 어림이다.
        var estimated = leg.arrival == nil && leg.confidence < 1
        if start == nil, let arrived = end, let minutes = leg.durationMinutes, minutes > 0 {
            start = arrived.addingTimeInterval(-Double(minutes) * 60)
            estimated = true
        }
        if end == nil, let departed = start, let minutes = leg.durationMinutes, minutes > 0 { end = departed.addingTimeInterval(Double(minutes) * 60) }
        guard let start, let end, end > start,
              let originZone = leg.originZone.flatMap(TimeZone.init(identifier:)), let destinationZone = leg.destinationZone.flatMap(TimeZone.init(identifier:)) else { return nil }
        let startOffset = originZone.secondsFromGMT(for: start), endOffset = destinationZone.secondsFromGMT(for: end)
        return Draft(
            title: title(for: leg), start: start, end: end, startOffsetSeconds: startOffset, endOffsetSeconds: endOffset,
            fields: TravelFlightFields(
                flightNumber: leg.flight, originCode: leg.origin, destinationCode: leg.destination, terminal: leg.terminal.flatMap(nonEmpty),
                gate: leg.gate.flatMap(nonEmpty), baggageClaim: leg.baggage.flatMap(nonEmpty), legIndex: legIndex, itineraryID: itineraryID
            ),
            isEstimated: estimated, arrivalDayOffset: dayOffset(from: start, originZone, to: end, destinationZone), arrivalPlace: arrivalPlace(leg.destination)
        )
    }

    /// 도착 공항의 지도 핀. 카탈로그에 없으면 nil.
    static func arrivalPlace(_ code: String) -> TravelItemPlace? {
        FlightAirportCatalog.airport(code).map { TravelItemPlace(name: "\($0.nameKo) (\($0.code))", latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// 출발 현지 날짜에서 도착 현지 날짜까지 날 수.
    private static func dayOffset(from start: Date, _ originZone: TimeZone, to end: Date, _ destinationZone: TimeZone) -> Int {
        func day(_ date: Date, _ zone: TimeZone) -> String {
            TravelTripDay.string(for: date, offsetSeconds: zone.secondsFromGMT(for: date))
        }
        return TravelTripDay.days(from: day(start, originZone), to: day(end, destinationZone)) ?? 0
    }

    /// `AB123 ICN → BKK`. 편명이 없으면 `ICN → BKK`.
    static func title(for leg: FlightLeg) -> String {
        let route = "\(leg.origin) → \(leg.destination)"
        guard let flight = leg.flight, !flight.isEmpty else { return route }
        return "\(flight) \(route)"
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: 화면용 어댑터(UI는 엔진을 직접 import하지 않는다)

    /// 화면에 보이는 공항 선택지.
    struct AirportChoice: Hashable, Identifiable, Sendable {
        var code: String
        var nameKo: String
        var nameEn: String
        var id: String { code }
    }

    static var koreanAirports: [AirportChoice] {
        FlightAirportCatalog.korea.map { AirportChoice(code: $0.code, nameKo: $0.nameKo, nameEn: $0.nameEn) }
    }

    /// 코드·도시 이름 일부로 찾는다.
    static func searchAirports(_ query: String, limit: Int = 5) -> [AirportChoice] {
        FlightAirportCatalog.search(query, limit: limit).map { AirportChoice(code: $0.code, nameKo: $0.nameKo, nameEn: $0.nameEn) }
    }

    /// 목록에서 고른 줄 → 일정 칸 초안.
    static func draft(from listing: FlightListing, day: String, direction: FlightLookup.Direction) -> Draft? {
        leg(from: listing, day: day, direction: direction).flatMap { draft(for: $0) }
    }

    /// 찾기 화면의 한 줄 → 일정 칸 초안. 국내선 합집합처럼 도착 시각을 알면 비행 분을 넘겨 어림이 아니게 한다(FLT1120A01).
    static func draft(from row: FlightSearch.Row, day: String) -> Draft? {
        let minutes = row.isEstimated ? nil : row.durationMinutes
        return leg(from: row.listing, day: day, direction: row.direction, durationMinutes: minutes).flatMap { draft(for: $0) }
    }

    /// 손으로 적은 값 → 일정 칸 초안.
    static func manualDraft(flight: String?, origin: String, destination: String, day: String, minute: Int, durationMinutes: Int?) -> Draft? {
        manualLeg(flight: flight, origin: origin, destination: destination, day: day, minute: minute, durationMinutes: durationMinutes).flatMap { draft(for: $0) }
    }

    // MARK: 여행에서 날 고르기

    /// 출국편이 놓일 날(여행 첫날)과 귀국편이 놓일 날(마지막 날). 날짜를 정하지 않은 여행은 nil.
    static func defaultDay(for trip: TravelTrip, returning: Bool) -> String? {
        let day = returning ? trip.endDay : trip.startDay
        return TravelTripDay.components(day) == nil ? nil : day
    }

    /// 일정 칸으로 만든 비행을 `TravelTripItem`의 항공 필드에 합쳐 넣을 때 쓰는 종류 이름.
    static let kindName = TripImportItem.Kind.flight.rawValue
}
