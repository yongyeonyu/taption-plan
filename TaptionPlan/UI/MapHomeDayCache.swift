import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

struct MapHomeCachedCoordinate: Codable, Sendable {
    let latitude: Double
    let longitude: Double
}

struct MapHomeCachedRouteOverlay: Codable, Sendable {
    let id: String
    let categoryID: String
    let opacity: Double
    let speedMetersPerSecond: Double?
    let coordinates: [MapHomeCachedCoordinate]
    let coordinateTimestamps: [Date]
}

struct MapHomeCachedExpectedRouteOverlay: Codable, Sendable {
    let id: UUID
    let segmentID: UUID
    let modeRawValue: String
    let departureDate: Date
    let arrivalDate: Date
    let coordinates: [MapHomeCachedCoordinate]
}

struct MapHomeCachedSubwayRouteOverlay: Codable, Sendable {
    let id: UUID
    let estimated: Bool
    let coordinates: [MapHomeCachedCoordinate]
    var travelID: UUID? = nil
}

struct MapHomeCachedTemporaryLocation: Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let stationName: String
    let latitude: Double
    let longitude: Double
    let reason: String
}

struct MapHomeDayCacheReadingsFingerprint: Codable, Equatable, Sendable {
    let count: Int
    let firstID: UUID?
    let lastID: UUID?
    let firstTimestamp: Date?
    let lastTimestamp: Date?

    init(readings: [SensorReading]) {
        count = readings.count
        firstID = readings.first?.id
        lastID = readings.last?.id
        firstTimestamp = readings.first?.timestamp
        lastTimestamp = readings.last?.timestamp
    }
}

/// 하루 지도 캐시(파생 경로·주석·임시 위치·중심/줌)의 메모리 보관소.
/// 원본에서 다시 계산할 수 있고 Apple 지도 타일은 담지 않으므로 디스크에 저장하지 않는다.
/// 최대 14일까지만 두고 오래 안 쓴 날부터 내보내며, 메모리 경고와 데이터 삭제 때 모두 비운다.
@MainActor
enum MapHomeDayCacheMemory {
    private struct Key: Hashable {
        let day: TaptionPlanDayKey
        let algorithmKey: String
        let styleKey: String
    }

    private struct Entry {
        let generation: UInt64
        let payload: MapHomeDayCachePayload
    }

    private static var cache = TaptionBoundedCache<Key, Entry>(capacity: 14)

    static func payload(
        day: TaptionPlanDayKey, algorithmKey: String, styleKey: String, generation: UInt64
    ) -> MapHomeDayCachePayload? {
        let key = Key(day: day, algorithmKey: algorithmKey, styleKey: styleKey)
        guard let entry = cache.value(for: key) else { return nil }
        guard entry.generation == generation else {
            cache.removeValue(for: key)
            return nil
        }
        return entry.payload
    }

    static func store(
        _ payload: MapHomeDayCachePayload,
        day: TaptionPlanDayKey, algorithmKey: String, styleKey: String, generation: UInt64
    ) {
        cache.insert(
            Entry(generation: generation, payload: payload),
            for: Key(day: day, algorithmKey: algorithmKey, styleKey: styleKey)
        )
    }

    static func removeAll() {
        cache.removeAll()
    }
}

/// 메모리 경고·데이터 삭제 때 앱 모델이 하루 지도 캐시를 비운다.
enum MapHomeDayCacheEviction {
    @MainActor static func removeAll() {
        MapHomeDayCacheMemory.removeAll()
    }
}

struct MapHomeDayCachePayload: Codable, Sendable {
    let sourceUpdatedAt: Date?
    let sourceRevision: UInt64
    let sourceFingerprint: String?
    let readingsFingerprint: MapHomeDayCacheReadingsFingerprint?
    let centerLatitude: Double
    let centerLongitude: Double
    let latitudeDelta: Double
    let longitudeDelta: Double
    let timeline: [MapHomeCachedRouteOverlay]
    let expected: [MapHomeCachedExpectedRouteOverlay]?
    let subway: [MapHomeCachedSubwayRouteOverlay]?
    let subwayMinute: Int?
    let temporaryLocations: [MapHomeCachedTemporaryLocation]?

    private enum CodingKeys: String, CodingKey {
        case sourceUpdatedAt, sourceRevision, sourceFingerprint
        case readingsFingerprint
        case centerLatitude, centerLongitude, latitudeDelta, longitudeDelta
        case timeline, expected, subway, subwayMinute, temporaryLocations
    }

    init(sourceUpdatedAt: Date? = nil, sourceRevision: UInt64,
         sourceFingerprint: String? = nil,
         readingsFingerprint: MapHomeDayCacheReadingsFingerprint? = nil,
         centerLatitude: Double, centerLongitude: Double, latitudeDelta: Double, longitudeDelta: Double,
         timeline: [MapHomeCachedRouteOverlay], expected: [MapHomeCachedExpectedRouteOverlay]?,
         subway: [MapHomeCachedSubwayRouteOverlay]?, subwayMinute: Int?,
         temporaryLocations: [MapHomeCachedTemporaryLocation]? = nil) {
        self.sourceUpdatedAt = sourceUpdatedAt
        self.sourceRevision = sourceRevision
        self.sourceFingerprint = sourceFingerprint
        self.readingsFingerprint = readingsFingerprint
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
        self.timeline = timeline
        self.expected = expected
        self.subway = subway
        self.subwayMinute = subwayMinute
        self.temporaryLocations = temporaryLocations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .sourceUpdatedAt)
        sourceRevision = try container.decode(UInt64.self, forKey: .sourceRevision)
        sourceFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .sourceFingerprint
        )
        readingsFingerprint = try container.decodeIfPresent(
            MapHomeDayCacheReadingsFingerprint.self,
            forKey: .readingsFingerprint
        )
        centerLatitude = try container.decode(Double.self, forKey: .centerLatitude)
        centerLongitude = try container.decode(Double.self, forKey: .centerLongitude)
        latitudeDelta = try container.decode(Double.self, forKey: .latitudeDelta)
        longitudeDelta = try container.decode(Double.self, forKey: .longitudeDelta)
        timeline = try container.decode([MapHomeCachedRouteOverlay].self, forKey: .timeline)
        expected = try container.decodeIfPresent([MapHomeCachedExpectedRouteOverlay].self, forKey: .expected)
        subway = try container.decodeIfPresent([MapHomeCachedSubwayRouteOverlay].self, forKey: .subway)
        subwayMinute = try container.decodeIfPresent(Int.self, forKey: .subwayMinute)
        temporaryLocations = try container.decodeIfPresent([MapHomeCachedTemporaryLocation].self, forKey: .temporaryLocations)
    }
}

struct MapHomeRouteDocumentRefresh: Equatable, Sendable {
    let preparesReadings: Bool
}

/// Keeps source mutations out of the interactive render loop. Any number of
/// sensor or timeline callbacks collapse into one document refresh on commit.
final class MapHomeRouteDocumentProjectionGate {
    private var needsRefresh = false
    private var needsReadingPreparation = false

    func deferRefresh(preparingReadings: Bool) {
        needsRefresh = true
        needsReadingPreparation = needsReadingPreparation || preparingReadings
    }

    func consumeDeferredRefresh() -> MapHomeRouteDocumentRefresh? {
        guard needsRefresh || needsReadingPreparation else { return nil }
        let refresh = MapHomeRouteDocumentRefresh(
            preparesReadings: needsReadingPreparation
        )
        needsRefresh = false
        needsReadingPreparation = false
        return refresh
    }

    func reset() {
        needsRefresh = false
        needsReadingPreparation = false
    }
}
