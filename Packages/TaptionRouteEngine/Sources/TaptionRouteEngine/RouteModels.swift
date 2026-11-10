import CryptoKit
import Foundation

enum RouteTimestamp {
    static func isValid(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
            && date >= .distantPast
            && date <= .distantFuture
    }
}

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
    /// 단순화한 표시 좌표. 접근할 때마다 Douglas-Peucker를 다시 돌지 않게 만들 때 한 번 계산한다 (REV1110A04).
    public let coordinates: [RouteCoordinate]

    private enum CodingKeys: String, CodingKey {
        case id, start, end, mode, samples, pathSamples, boundarySamples
        case isNewSegment, isLowConfidence, subwayEvidence
    }

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
        // 믿을 만한 지하철 근거만 GPS 경로를 대신한다 (REV1110A04).
        if let subwayEvidence, RouteEvidenceGate.isTrusted(subwayEvidence) {
            coordinates = RoutePathSimplifier.simplify(subwayEvidence.coordinates)
        } else {
            coordinates = RoutePathSimplifier.simplify(pathSamples.map(\.coordinate))
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            start: try values.decode(Date.self, forKey: .start),
            end: try values.decode(Date.self, forKey: .end),
            mode: try values.decode(RouteTravelMode.self, forKey: .mode),
            samples: try values.decode([RouteSample].self, forKey: .samples),
            pathSamples: try values.decode([RouteSample].self, forKey: .pathSamples),
            boundarySamples: try values.decode([RouteSample].self, forKey: .boundarySamples),
            isNewSegment: try values.decode(Bool.self, forKey: .isNewSegment),
            isLowConfidence: try values.decode(Bool.self, forKey: .isLowConfidence),
            subwayEvidence: try values.decodeIfPresent(SubwayRouteEvidence.self, forKey: .subwayEvidence)
        )
    }
}

/// 같은 표본에서 나온 구간이 필터를 다시 돌려도 같은 id를 갖게 한다 (REV1110A04).
enum RouteSegmentID {
    static func make(samples: [RouteSample], mode: RouteTravelMode) -> UUID {
        guard let first = samples.first, let last = samples.last else { return UUID() }
        let seed = "route-segment-v1|\(first.id.uuidString)|\(first.timestamp.timeIntervalSince1970.bitPattern)"
            + "|\(last.id.uuidString)|\(last.timestamp.timeIntervalSince1970.bitPattern)|\(mode.rawValue)"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
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
