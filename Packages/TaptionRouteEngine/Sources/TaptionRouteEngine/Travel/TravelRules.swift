import Foundation

/// `travel_rules.json`의 꼴. 숫자는 여기서만 읽고, 이유는 `travel_rules.md`에 있다.
public struct TravelRules: Decodable, Sendable {
    public struct Transit: Decodable, Sendable {
        public let marginRatio: Double
    }

    public struct Airport: Decodable, Sendable {
        public let arrivalBufferMinutes: [String: Int]?
        public let checkinBeforeDomestic: Int?
        public let checkinBeforeInternational: Int?
        public let minimumConnectionMinutes: [String: Int]?
    }

    public struct Hotel: Decodable, Sendable {
        public let checkinBufferMinutes: Int
    }

    public struct TaxRefund: Decodable, Sendable {
        public let minimizeQueueMinutes: Int
    }

    /// 착륙 뒤 일정. 공항 대기와 이동은 따로 놓는 블록이다.
    public struct ArrivalBlocks: Hashable, Sendable {
        public let airportBufferMinutes: Int
        public let travelMinutes: Int
        public var totalMinutes: Int { airportBufferMinutes + travelMinutes }
    }

    public let version: String
    public let transit: Transit?
    public let airport: Airport?
    public let hotel: Hotel?
    public let taxRefund: TaxRefund?

    public static func decode(_ data: Data) -> TravelRules? {
        try? JSONDecoder().decode(TravelRules.self, from: data)
    }

    public static let bundled: TravelRules? = TravelBundledData.data("travel_rules", "json").flatMap(decode)

    /// AI가 읽는 판단 근거(마크다운).
    public static let bundledGuide: String? = TravelBundledData.data("travel_rules", "md").flatMap { String(data: $0, encoding: .utf8) }

    /// 이동 예상 시간에 마진을 더해 분 단위로 올림한다.
    public func travelMinutes(withMargin minutes: Double) -> Int? {
        guard let ratio = transit?.marginRatio, ratio.isFinite, ratio >= 0, minutes.isFinite, minutes >= 0, minutes < 1_000_000 else { return nil }
        // 1.2배 같은 곱셈의 소수 오차로 1분이 더 붙지 않게 한다.
        return Int((minutes * (1 + ratio) - 1e-9).rounded(.up))
    }

    /// 입국심사·수하물 대기. 이동 마진을 곱하지 않는다.
    public func airportArrivalBufferMinutes(country: String? = nil) -> Int? {
        Self.value(airport?.arrivalBufferMinutes, country: country)
    }

    /// 출발 시각보다 얼마나 먼저 공항에 도착해야 하는가.
    public func checkinLeadMinutes(isInternational: Bool) -> Int? {
        isInternational ? airport?.checkinBeforeInternational : airport?.checkinBeforeDomestic
    }

    public func minimumConnectionMinutes(country: String? = nil) -> Int? {
        Self.value(airport?.minimumConnectionMinutes, country: country)
    }

    /// 환승 시간이 최소 기준을 채우는가.
    public func allowsConnection(layoverMinutes: Double, country: String? = nil) -> Bool? {
        minimumConnectionMinutes(country: country).map { layoverMinutes >= Double($0) }
    }

    public func arrivalBlocks(onwardTravelMinutes: Double, country: String? = nil) -> ArrivalBlocks? {
        guard let buffer = airportArrivalBufferMinutes(country: country),
              let travel = travelMinutes(withMargin: onwardTravelMinutes) else { return nil }
        return ArrivalBlocks(airportBufferMinutes: buffer, travelMinutes: travel)
    }

    /// 나라 값이 없으면 `default`를 쓴다.
    private static func value(_ table: [String: Int]?, country: String?) -> Int? {
        guard let table else { return nil }
        return country.flatMap { table[$0.uppercased()] } ?? table["default"]
    }
}
