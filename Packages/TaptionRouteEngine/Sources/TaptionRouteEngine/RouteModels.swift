import Foundation

public struct RouteCoordinate: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum RouteTravelMode: String, Codable, Hashable, Sendable {
    case walking
    case running
    case cycling
    case automotive
    case privateVehicle
    case subway
    case bus
    case train
    case airplane
    case ship
    case unknown

    public var maximumSpeedMetersPerSecond: Double {
        switch self {
        case .walking: 4.5
        case .running: 9
        case .cycling: 25
        case .automotive: 90
        case .privateVehicle: 90
        case .subway: 120
        case .bus: 35
        case .train: 120
        case .airplane: 280
        case .ship: 70
        case .unknown: 55
        }
    }
}

public enum ExpectedRouteSource: String, Codable, CaseIterable, Hashable, Sendable {
    case subwayCatalog
    case busCatalog
    case operatingSystemRoute
    case airportDirect
}

public struct ExpectedRoute: Codable, Hashable, Sendable {
    public let span: DateInterval
    public let mode: RouteTravelMode
    public let coordinates: [RouteCoordinate]
    public let source: ExpectedRouteSource
    public let confidence: Double
    public let provenance: [String]

    public init(span: DateInterval, mode: RouteTravelMode, coordinates: [RouteCoordinate], source: ExpectedRouteSource, confidence: Double, provenance: [String] = []) {
        self.span = span
        self.mode = mode
        self.coordinates = coordinates
        self.source = source
        self.confidence = min(1, max(0, confidence))
        self.provenance = provenance
    }

    public var isHighConfidence: Bool { confidence >= 0.80 }
}

public struct RouteSample: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let coordinate: RouteCoordinate
    public let horizontalAccuracyMeters: Double
    public let speedMetersPerSecond: Double?
    public let speedAccuracyMetersPerSecond: Double?
    public let sequence: Int64?
    public let mode: RouteTravelMode
    public let isApproximate: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        coordinate: RouteCoordinate,
        horizontalAccuracyMeters: Double = -1,
        speedMetersPerSecond: Double? = nil,
        speedAccuracyMetersPerSecond: Double? = nil,
        sequence: Int64? = nil,
        mode: RouteTravelMode = .unknown,
        isApproximate: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.coordinate = coordinate
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.speedMetersPerSecond = speedMetersPerSecond
        self.speedAccuracyMetersPerSecond = speedAccuracyMetersPerSecond
        self.sequence = sequence
        self.mode = mode
        self.isApproximate = isApproximate
    }

    public var isPrecise: Bool {
        horizontalAccuracyMeters >= 0 && horizontalAccuracyMeters <= 150
    }

    public var isUsable: Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite
            && (-90...90).contains(coordinate.latitude)
            && (-180...180).contains(coordinate.longitude)
    }
}

public struct SubwayRouteEvidence: Codable, Hashable, Sendable {
    public let lineName: String
    public let stationNames: [String]
    public let coordinates: [RouteCoordinate]
    public let confidence: Double

    public init(
        lineName: String,
        stationNames: [String],
        coordinates: [RouteCoordinate],
        confidence: Double = 1
    ) {
        self.lineName = lineName
        self.stationNames = stationNames
        self.coordinates = coordinates
        self.confidence = min(1, max(0, confidence))
    }
}

public struct RouteSegment: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let start: Date
    public let end: Date
    public let mode: RouteTravelMode
    public let samples: [RouteSample]
    public let pathSamples: [RouteSample]
    public let boundarySamples: [RouteSample]
    public let isNewSegment: Bool
    public let isLowConfidence: Bool
    public let subwayEvidence: SubwayRouteEvidence?

    public init(
        id: UUID = UUID(),
        start: Date,
        end: Date,
        mode: RouteTravelMode,
        samples: [RouteSample],
        pathSamples: [RouteSample],
        boundarySamples: [RouteSample] = [],
        isNewSegment: Bool = false,
        isLowConfidence: Bool = false,
        subwayEvidence: SubwayRouteEvidence? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.mode = mode
        self.samples = samples
        self.pathSamples = pathSamples
        self.boundarySamples = boundarySamples
        self.isNewSegment = isNewSegment
        self.isLowConfidence = isLowConfidence
        self.subwayEvidence = subwayEvidence
    }

    public var coordinates: [RouteCoordinate] {
        if let subwayEvidence, subwayEvidence.coordinates.count >= 2 {
            return RoutePathSimplifier.simplify(subwayEvidence.coordinates)
        }
        return RoutePathSimplifier.simplify(pathSamples.map(\.coordinate))
    }
}

public struct RouteLog: Codable, Hashable, Sendable {
    public let segments: [RouteSegment]
    public let normalizedSamples: [RouteSample]

    public init(segments: [RouteSegment], normalizedSamples: [RouteSample]) {
        self.segments = segments
        self.normalizedSamples = normalizedSamples
    }

    public var coordinates: [RouteCoordinate] {
        segments.flatMap(\.coordinates)
    }
}
