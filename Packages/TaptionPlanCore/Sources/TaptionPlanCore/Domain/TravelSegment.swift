import Foundation

public enum TravelMode: String, Codable, CaseIterable, Sendable {
    case walking
    case running
    case cycling
    case bus
    case subway
    case taxi
    case car
    case train
    case airplane
    case ship
}

public struct TravelSegment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var fromPlaceID: UUID?
    public var toPlaceID: UUID?
    public var mode: TravelMode
    public var span: TimeSpan
    public var distanceMeters: Double
    public var confidence: ConfidenceLevel
    public var evidence: [String]
    public var isConfirmed: Bool
    public var subwayRoute: SubwayRoutePath?
    /// Persisted automatic mode classification. User confirmation is still
    /// represented by `isConfirmed`; this flag protects inferred modes from
    /// changing during a later archive refresh.
    public var isClassificationLocked: Bool

    private enum CodingKeys: String, CodingKey {
        case id, fromPlaceID, toPlaceID, mode, span, distanceMeters,
             confidence, evidence, isConfirmed, subwayRoute,
             isClassificationLocked
    }

    public init(
        id: UUID = UUID(),
        fromPlaceID: UUID? = nil,
        toPlaceID: UUID? = nil,
        mode: TravelMode,
        span: TimeSpan,
        distanceMeters: Double,
        confidence: ConfidenceLevel,
        evidence: [String],
        isConfirmed: Bool = false,
        subwayRoute: SubwayRoutePath? = nil,
        isClassificationLocked: Bool = false
    ) {
        self.id = id
        self.fromPlaceID = fromPlaceID
        self.toPlaceID = toPlaceID
        self.mode = mode
        self.span = span
        self.distanceMeters = max(0, distanceMeters)
        self.confidence = confidence
        self.evidence = evidence
        self.isConfirmed = isConfirmed
        self.subwayRoute = subwayRoute
        self.isClassificationLocked = isClassificationLocked
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        fromPlaceID = try values.decodeIfPresent(UUID.self, forKey: .fromPlaceID)
        toPlaceID = try values.decodeIfPresent(UUID.self, forKey: .toPlaceID)
        mode = try values.decode(TravelMode.self, forKey: .mode)
        span = try values.decode(TimeSpan.self, forKey: .span)
        distanceMeters = max(
            0,
            try values.decodeIfPresent(Double.self, forKey: .distanceMeters) ?? 0
        )
        confidence = try values.decode(ConfidenceLevel.self, forKey: .confidence)
        evidence = try values.decodeIfPresent([String].self, forKey: .evidence) ?? []
        isConfirmed = try values.decodeIfPresent(Bool.self, forKey: .isConfirmed) ?? false
        subwayRoute = try values.decodeIfPresent(SubwayRoutePath.self, forKey: .subwayRoute)
        isClassificationLocked = try values.decodeIfPresent(
            Bool.self,
            forKey: .isClassificationLocked
        ) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(fromPlaceID, forKey: .fromPlaceID)
        try values.encodeIfPresent(toPlaceID, forKey: .toPlaceID)
        try values.encode(mode, forKey: .mode)
        try values.encode(span, forKey: .span)
        try values.encode(distanceMeters, forKey: .distanceMeters)
        try values.encode(confidence, forKey: .confidence)
        try values.encode(evidence, forKey: .evidence)
        try values.encode(isConfirmed, forKey: .isConfirmed)
        try values.encodeIfPresent(subwayRoute, forKey: .subwayRoute)
        try values.encode(isClassificationLocked, forKey: .isClassificationLocked)
    }
}

public struct SubwayRouteStop: Codable, Hashable, Sendable {
    public var lineName: String
    public var order: Int
    public var stationName: String
    public var latitude: Double?
    public var longitude: Double?

    public init(lineName: String, order: Int, stationName: String, latitude: Double?, longitude: Double?) {
        self.lineName = lineName
        self.order = order
        self.stationName = stationName
        self.latitude = latitude
        self.longitude = longitude
    }

    public var coordinate: GeoPoint? {
        guard let latitude, let longitude else { return nil }
        return GeoPoint(
            latitude: latitude,
            longitude: longitude,
            altitude: 0,
            horizontalAccuracy: -1,
            verticalAccuracy: -1
        )
    }
}

public struct SubwayRoutePath: Codable, Hashable, Sendable {
    public var stops: [SubwayRouteStop]
    public var lineNames: [String]
    public var transferStationNames: [String]

    public init(stops: [SubwayRouteStop], lineNames: [String], transferStationNames: [String]) {
        self.stops = stops
        self.lineNames = lineNames
        self.transferStationNames = transferStationNames
    }

    public var coordinates: [GeoPoint] {
        stops.compactMap(\.coordinate)
    }
}
