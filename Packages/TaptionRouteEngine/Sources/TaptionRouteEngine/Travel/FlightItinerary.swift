import Foundation

/// 항공 한 구간(FLT1119A01). 시차·도착 시각·비행 시간은 `FlightTimeMath`만 쓰고, 시간대는 `FlightAirportCatalog`에서 온다.
public struct FlightLeg: Hashable, Sendable {
    /// 편명. 알림에 시각만 오는 경우처럼 없을 수 있다.
    public var flight: String?
    /// 항공사 두 글자 코드.
    public var airline: String?
    public var origin: String
    public var destination: String
    /// 출발 공항의 현지 벽시계.
    public var departure: FlightLocalTime?
    /// 도착 공항의 현지 벽시계. 없으면 비행 시간으로 계산한다.
    public var arrival: FlightLocalTime?
    public var durationMinutes: Int?
    public var terminal: String?
    public var gate: String?
    public var baggage: String?
    /// `publicData`·`message`·`manual`·`calendar`·`pass`.
    public var source: String
    public var confidence: Double

    public init(flight: String? = nil, airline: String? = nil, origin: String, destination: String,
                departure: FlightLocalTime? = nil, arrival: FlightLocalTime? = nil, durationMinutes: Int? = nil,
                terminal: String? = nil, gate: String? = nil, baggage: String? = nil,
                source: String = "manual", confidence: Double = 1) {
        self.flight = flight
        self.airline = airline
        self.origin = origin.uppercased()
        self.destination = destination.uppercased()
        self.departure = departure
        self.arrival = arrival
        self.durationMinutes = durationMinutes
        self.terminal = terminal
        self.gate = gate
        self.baggage = baggage
        self.source = source
        self.confidence = confidence
    }

    public var originZone: String? { FlightAirportCatalog.airport(origin)?.timeZone }
    public var destinationZone: String? { FlightAirportCatalog.airport(destination)?.timeZone }

    /// 같은 나라 안 구간이면 true, 공항을 모르면 nil.
    public var isDomestic: Bool? { FlightAirportCatalog.isDomestic(from: origin, to: destination) }

    public var departureInstant: Date? {
        guard let departure, let zone = originZone else { return nil }
        return FlightTimeMath.instant(departure, zone: zone)
    }

    /// 도착 시각. 도착 현지 시각이 있으면 그것을, 없으면 출발 + 비행 시간을 쓴다.
    public var arrivalInstant: Date? {
        if let arrival, let zone = destinationZone { return FlightTimeMath.instant(arrival, zone: zone) }
        return computedArrival?.instant
    }

    /// 도착 현지 시각(주어졌거나 계산한 값).
    public var resolvedArrival: FlightLocalTime? { arrival ?? computedArrival?.local }

    /// 도착 현지 날짜가 출발 현지 날짜보다 며칠 뒤인가(계산 가능할 때만).
    public var arrivalDayOffset: Int? {
        if arrival == nil { return computedArrival?.dayOffset }
        guard let departure, let end = arrival else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let first = calendar.date(from: DateComponents(year: departure.year, month: departure.month, day: departure.day)),
              let last = calendar.date(from: DateComponents(year: end.year, month: end.month, day: end.day)) else { return nil }
        return calendar.dateComponents([.day], from: first, to: last).day
    }

    /// 도착 시각과 출발 시각의 차(분). 둘 중 하나를 모르면 `durationMinutes`.
    public var resolvedDurationMinutes: Int? {
        if let departure, let arrival, let from = originZone, let to = destinationZone,
           let minutes = FlightTimeMath.durationMinutes(departure: departure, departureZone: from, arrival: arrival, arrivalZone: to) {
            return minutes
        }
        return durationMinutes
    }

    /// 출발 공항 시간대의 UTC 차(초). `TravelTripItem.startOffsetSeconds`에 넣는다.
    public var departureOffsetSeconds: Int? {
        guard let instant = departureInstant, let zone = originZone.flatMap(TimeZone.init(identifier:)) else { return nil }
        return zone.secondsFromGMT(for: instant)
    }

    /// 도착 공항 시간대의 UTC 차(초). `TravelTripItem.endOffsetSeconds`에 넣는다.
    public var arrivalOffsetSeconds: Int? {
        guard let instant = arrivalInstant, let zone = destinationZone.flatMap(TimeZone.init(identifier:)) else { return nil }
        return zone.secondsFromGMT(for: instant)
    }

    private var computedArrival: FlightArrival? {
        guard let departure, let from = originZone, let to = destinationZone, let minutes = durationMinutes else { return nil }
        return FlightTimeMath.arrival(departure: departure, departureZone: from, durationMinutes: minutes, arrivalZone: to)
    }
}

/// 지연·시간 변경 한 건의 이력.
public struct FlightChange: Hashable, Sendable {
    public var flight: String
    /// 바뀌기 전과 후의 출발 현지 시각.
    public var before: FlightLocalTime?
    public var after: FlightLocalTime?
    public var delayMinutes: Int
    public var reason: String?
    public var receivedAt: Date

    public init(flight: String, before: FlightLocalTime? = nil, after: FlightLocalTime? = nil, delayMinutes: Int, reason: String? = nil, receivedAt: Date) {
        self.flight = flight.uppercased()
        self.before = before
        self.after = after
        self.delayMinutes = delayMinutes
        self.reason = reason
        self.receivedAt = receivedAt
    }
}

/// 구간 사이 대기. 앞 구간 도착 → 다음 구간 출발.
public struct FlightLayover: Hashable, Sendable {
    public let fromLegIndex: Int
    public let toLegIndex: Int
    public let airport: String
    /// 시간표 기준 대기(분).
    public let scheduledMinutes: Int
    /// 지연 이력을 반영한 지금의 대기(분). 앞 구간이 늦으면 줄고 다음 구간이 늦으면 는다.
    public let currentMinutes: Int
    /// 이 환승에 필요한 최소 시간(분).
    public let minimumMinutes: Int

    /// 지금 대기가 최소 환승 시간보다 짧으면 촉박.
    public var isTight: Bool { currentMinutes < minimumMinutes }
    /// 지연 때문에 줄어든 여유(분). 줄지 않았으면 0.
    public var lostMinutes: Int { max(0, scheduledMinutes - currentMinutes) }
    /// 최소 환승 시간에서 모자란 분(촉박하지 않으면 0).
    public var shortfallMinutes: Int { max(0, minimumMinutes - currentMinutes) }
}

/// 환승 최소 시간(분). 근거: 같은 터미널 안 환승은 보안·탑승구 이동 60분, 터미널을 옮기면 90분,
/// 국제선에서 내려 국내선으로 갈아타면 입국 심사·수하물 때문에 120분을 잡는다(항공사·공항 평균 안내를 단순화한 보수적 값).
public enum FlightConnectionRules {
    public static let sameTerminalMinutes = 60
    public static let terminalChangeMinutes = 90
    public static let internationalToDomesticMinutes = 120

    static func minimum(arriving leg: FlightLeg, departing next: FlightLeg) -> Int {
        var minutes = terminalChangeMinutes
        if let a = leg.terminal, let b = next.terminal, !a.isEmpty, a == b { minutes = sameTerminalMinutes }
        if leg.isDomestic == false, next.isDomestic == true { minutes = max(minutes, internationalToDomesticMinutes) }
        return minutes
    }
}

/// 여행 하나의 항공 여정(Leg1 + Leg2 + …).
public struct FlightItinerary: Hashable, Sendable {
    public var legs: [FlightLeg]
    public var changes: [FlightChange]

    public init(legs: [FlightLeg], changes: [FlightChange] = []) {
        self.legs = legs
        self.changes = changes
    }

    /// 구간 사이 대기(자동 생성). 시각을 모르는 이음매는 건너뛴다. 앞 구간 도착 공항과 다음 구간 출발 공항이 다르면 환승이 아니라 건너뛴다.
    public var layovers: [FlightLayover] {
        guard legs.count > 1 else { return [] }
        return (1..<legs.count).compactMap { index in
            let previous = legs[index - 1], next = legs[index]
            guard previous.destination == next.origin,
                  let arrived = previous.arrivalInstant, let departs = next.departureInstant else { return nil }
            let scheduled = Int((departs.timeIntervalSince(arrived) / 60).rounded())
            let current = scheduled - delay(of: previous) + delay(of: next)
            return FlightLayover(fromLegIndex: index - 1, toLegIndex: index, airport: previous.destination,
                                 scheduledMinutes: scheduled, currentMinutes: current,
                                 minimumMinutes: FlightConnectionRules.minimum(arriving: previous, departing: next))
        }
    }

    /// 촉박해진 환승.
    public var tightLayovers: [FlightLayover] { layovers.filter(\.isTight) }

    /// 마지막으로 받은 지연(분). 같은 편명의 가장 늦게 받은 변경 이력 기준, 없으면 0.
    public func delay(of leg: FlightLeg) -> Int {
        guard let flight = leg.flight?.uppercased() else { return 0 }
        return changes.filter { $0.flight == flight }.max(by: { $0.receivedAt < $1.receivedAt })?.delayMinutes ?? 0
    }

    /// 전체 여정이 지나가는 공항 순서(출발지 → 환승지들 → 최종 도착지). 이음매가 끊기면 끊긴 곳에서 다시 시작한다.
    public var airportPath: [String] {
        var path: [String] = []
        for leg in legs {
            if path.last != leg.origin { path.append(leg.origin) }
            path.append(leg.destination)
        }
        return path
    }
}

/// 공항 도착 역산(B-3). 국제선 출발 180분 전, 국내선 60분 전. 현장 안내 값이 오면 그 값으로 바꾸고 「현장 안내 기준」으로 표시한다.
public enum FlightAirportArrival {
    public static let internationalLeadMinutes = 180
    public static let domesticLeadMinutes = 60
    /// 국제선 도착 후 입국·수하물에 잡는 기본 시간. 국내선 도착은 잡지 않는다.
    public static let internationalClearanceMinutes = 60

    public enum Basis: Equatable, Sendable {
        case standard
        case onsiteGuidance
    }

    public struct Recommendation: Equatable, Sendable {
        public let leadMinutes: Int
        public let basis: Basis
        /// 공항에 도착해야 하는 시각.
        public let arriveBy: Date
    }

    /// 출발 시각과 나라를 알 수 있을 때만 값이 나온다. 구간이 국내인지 모르면 국제선 기준(더 이른 쪽)으로 잡는다.
    public static func recommendation(for leg: FlightLeg, onsiteGuidanceLeadMinutes: Int? = nil) -> Recommendation? {
        guard let departs = leg.departureInstant else { return nil }
        if let guidance = onsiteGuidanceLeadMinutes, guidance > 0 {
            return Recommendation(leadMinutes: guidance, basis: .onsiteGuidance, arriveBy: departs.addingTimeInterval(-Double(guidance) * 60))
        }
        let lead = leg.isDomestic == true ? domesticLeadMinutes : internationalLeadMinutes
        return Recommendation(leadMinutes: lead, basis: .standard, arriveBy: departs.addingTimeInterval(-Double(lead) * 60))
    }

    /// 「집에서 출발」 후보 시각. 이동 시간을 모르면 nil(제안하지 않는다).
    public static func homeDeparture(arriveBy: Date, travelMinutes: Int?) -> Date? {
        guard let travelMinutes, travelMinutes >= 0 else { return nil }
        return arriveBy.addingTimeInterval(-Double(travelMinutes) * 60)
    }

    /// 도착 후 일정을 놓을 수 있는 가장 이른 시각. 국제선 도착이면 입국·수하물 60분 뒤.
    public static func earliestStart(after leg: FlightLeg) -> Date? {
        guard let arrived = leg.arrivalInstant else { return nil }
        let clearance = leg.isDomestic == true ? 0 : internationalClearanceMinutes
        return arrived.addingTimeInterval(Double(clearance) * 60)
    }
}
