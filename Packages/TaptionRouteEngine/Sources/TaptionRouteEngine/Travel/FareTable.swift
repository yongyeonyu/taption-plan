import Foundation

public enum FareAgeBand: String, Sendable, CaseIterable {
    case adult, teen, child
}

/// `fares.json`의 꼴. 요금·거리·시간 기준은 모두 이 표에서 온다.
public struct FareTable: Decodable, Sendable {
    public struct AgeBands: Decodable, Sendable {
        public let childMinAge: Int
        public let teenMinAge: Int
        public let adultMinAge: Int
    }

    public struct Amount: Decodable, Sendable {
        public let base: Int
        /// 거리 한 단계마다 더하는 금액. 균일 요금이면 없다.
        public let extra: Int?
    }

    public struct DistanceBand: Decodable, Sendable {
        public let fromKm: Double
        public let toKm: Double?
        public let unitKm: Double
    }

    public struct Mode: Decodable, Sendable {
        public let kind: String
        public let bands: [DistanceBand]?
        public let transferBaseKm: Double?
        public let transfersToSameKind: Bool?
        public let fares: [String: Amount]
        public let verified: Bool?
        public let extraVerified: Bool?
    }

    public struct Transfer: Decodable, Sendable {
        public let windowMinutes: Int
        public let nightWindowMinutes: Int?
        public let nightStartHour: Int?
        public let nightEndHour: Int?
        public let maxBoardings: Int?
        public let unitKm: Double?
        public let verified: Bool?
    }

    public struct Region: Decodable, Sendable {
        public let checkedOn: String?
        public let sources: [String]?
        public let transfer: Transfer?
        public let modes: TravelLossyMap<Mode>
    }

    public let version: String
    public let timeZone: String?
    public let ageBands: AgeBands?
    public let regions: TravelLossyMap<Region>

    public static func decode(_ data: Data) -> FareTable? {
        try? JSONDecoder().decode(FareTable.self, from: data)
    }

    public static let bundled: FareTable? = TravelBundledData.data("fares", "json").flatMap(decode)
}
