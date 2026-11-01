import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

enum MapHomeRouteReadingsPolicy {
    static func dayKey(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        calendar.startOfDay(for: date)
    }

    static func merging(
        existing: [SensorReading],
        loaded: [SensorReading],
        in span: TimeSpan
    ) -> [SensorReading] {
        var readingsByID: [UUID: SensorReading] = [:]
        for reading in existing where RouteTimelineTimestamp.isValid(reading.timestamp)
            && span.contains(reading.timestamp) {
            readingsByID[reading.id] = reading
        }
        for reading in loaded where RouteTimelineTimestamp.isValid(reading.timestamp)
            && span.contains(reading.timestamp) {
            readingsByID[reading.id] = reading
        }
        return readingsByID.values.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.timestamp < $1.timestamp
        }
    }

    static func clampedTimelineDate(
        selectedDate: Date,
        timelineDate: Date,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        calendar.isDate(selectedDate, inSameDayAs: now)
            ? min(timelineDate, now)
            : timelineDate
    }
}

struct MapHomePredictedRouteCoordinate: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
}

struct MapHomePredictedGPSGap {
    let start: SensorReading
    let end: SensorReading
    let coordinates: [MapHomePredictedRouteCoordinate]
}

enum MapHomeGPSGapPredictionPolicy {
    static let minimumGap: TimeInterval = 45
    static let maximumGap: TimeInterval = 5 * 60
    static let maximumDistanceMeters = 600.0
    static let maximumEndpointAccuracyMeters = 50.0
    static let maximumAverageSpeedMetersPerSecond = 3.0
    static let sampleSpacingMeters = 25.0
    static let maximumSamplesPerGap = 24

    static func predictedRailCoordinates(
        from overlays: [MapHomeSubwayRouteOverlay]
    ) -> [[MapHomePredictedRouteCoordinate]] {
        let paths = overlays.map { predictedRailCoordinates(along: $0.coordinates) }
            .filter { !$0.isEmpty }
        guard !paths.isEmpty else { return [] }
        let budget = 96
        let samplesPerPath = budget / paths.count
        let remainder = budget % paths.count
        return paths.enumerated().compactMap { index, points in
            let count = min(points.count, samplesPerPath + (index < remainder ? 1 : 0))
            guard count > 0 else { return nil }
            if count == 1 { return [points[points.count / 2]] }
            return (0..<count).map { sample in
                points[sample * (points.count - 1) / (count - 1)]
            }
        }
    }

    static func predictedCoordinates(
        from readings: [SensorReading],
        through cutoff: Date? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [[MapHomePredictedRouteCoordinate]] {
        predictedGaps(from: readings, through: cutoff, calendar: calendar).map(\.coordinates)
    }

    static func predictedGaps(
        from readings: [SensorReading],
        through cutoff: Date? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MapHomePredictedGPSGap] {
        let ordered = readings.filter { reading in
            RouteTimelineTimestamp.isValid(reading.timestamp)
                && (cutoff.map { reading.timestamp <= $0 } ?? true)
        }.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.timestamp < $1.timestamp
        }

        var pairs: [(SensorReading, SensorReading)] = []
        var previousFix: SensorReading?
        for reading in ordered {
            if reading.trackingSessionEnded == true || reading.sourceDevice == .appleWatch {
                previousFix = nil
                continue
            }
            guard isEligibleFix(reading) else { continue }
            if let previousFix { pairs.append((previousFix, reading)) }
            previousFix = reading
        }
        return pairs.compactMap { pair in
            let (start, end) = pair
            guard Self.isEligibleFix(start), Self.isEligibleFix(end),
                  let startPoint = start.point,
                  let endPoint = end.point else { return nil }
            let duration = end.timestamp.timeIntervalSince(start.timestamp)
            guard duration >= minimumGap,
                  duration <= maximumGap,
                  calendar.isDate(start.timestamp, inSameDayAs: end.timestamp) else {
                return nil
            }
            let distance = CLLocation(
                latitude: startPoint.latitude,
                longitude: startPoint.longitude
            ).distance(from: CLLocation(
                latitude: endPoint.latitude,
                longitude: endPoint.longitude
            ))
            guard distance >= sampleSpacingMeters,
                  distance <= maximumDistanceMeters,
                  distance / duration <= maximumAverageSpeedMetersPerSecond else {
                return nil
            }
            let sampleCount = min(
                maximumSamplesPerGap,
                max(1, Int(ceil(distance / sampleSpacingMeters)) - 1)
            )
            let coordinates = (1...sampleCount).map { index in
                let fraction = Double(index) / Double(sampleCount + 1)
                return MapHomePredictedRouteCoordinate(
                    latitude: startPoint.latitude
                        + (endPoint.latitude - startPoint.latitude) * fraction,
                    longitude: startPoint.longitude
                        + (endPoint.longitude - startPoint.longitude) * fraction
                )
            }
            return MapHomePredictedGPSGap(start: start, end: end, coordinates: coordinates)
        }
    }

    static func predictedRailCoordinates(
        along coordinates: [CLLocationCoordinate2D]
    ) -> [MapHomePredictedRouteCoordinate] {
        guard coordinates.count >= 2,
              coordinates.allSatisfy({ CLLocationCoordinate2DIsValid($0) }) else { return [] }
        let lengths = MapHomeExpectedRoutePlaybackMath.segmentLengths(for: coordinates)
        let distance = lengths.reduce(0, +)
        guard distance.isFinite, distance >= sampleSpacingMeters else { return [] }
        let count = min(maximumSamplesPerGap, max(2, Int(ceil(distance / sampleSpacingMeters))))
        return (0..<count).compactMap { index in
            guard let point = MapHomeExpectedRoutePlaybackMath.coordinate(
                atProgress: Double(index) / Double(count - 1),
                coordinates: coordinates, segmentLengths: lengths
            ) else { return nil }
            return MapHomePredictedRouteCoordinate(latitude: point.latitude, longitude: point.longitude)
        }
    }

    private static func isEligibleFix(_ reading: SensorReading) -> Bool {
        guard reading.gpsAvailable,
              reading.locationFixQuality != .approximate,
              reading.sourceDevice != .appleWatch,
              reading.trackingSessionEnded != true,
              let point = reading.point,
              point.latitude.isFinite, (-90...90).contains(point.latitude),
              point.longitude.isFinite, (-180...180).contains(point.longitude),
              point.horizontalAccuracy.isFinite,
              point.horizontalAccuracy >= 0,
              point.horizontalAccuracy <= maximumEndpointAccuracyMeters else {
            return false
        }
        return true
    }
}

enum MapHomeRouteReadingsLoadState: Equatable {
    case idle
    case loading(Date)
    case loaded(Date)
    case failed(Date)

    func isLoaded(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        guard case .loaded(let loadedDay) = self else { return false }
        return calendar.isDate(loadedDay, inSameDayAs: date)
    }

    func isResolved(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        let resolvedDay: Date
        switch self {
        case .loaded(let day), .failed(let day):
            resolvedDay = day
        case .idle, .loading:
            return false
        }
        return calendar.isDate(resolvedDay, inSameDayAs: date)
    }
}

struct MapHomeRouteReadingsTaskKey: Hashable {
    let day: Date
    let isBootstrapped: Bool
    let rawDataRevision: UInt64
    let isSceneActive: Bool

    init(
        date: Date,
        isBootstrapped: Bool,
        rawDataRevision: UInt64 = 0,
        isSceneActive: Bool = true,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        day = calendar.startOfDay(for: date)
        self.isBootstrapped = isBootstrapped
        self.rawDataRevision = rawDataRevision
        self.isSceneActive = isSceneActive
    }
}

struct MapHomeDaySourceTaskKey: Hashable {
    let day: Date
    let revision: UInt64
    let isReady: Bool
    let isActive: Bool
}

struct MapHomePreparedRouteReadings: Sendable {
    let normalized: [SensorReading]
    let display: [SensorReading]
    let latestTrustedReading: SensorReading?
    let impossibleLocationCount: Int
    let innovationOutlierCount: Int
    let sourceCount: Int
    let filteredCount: Int
    let watchSourceCount: Int
    let readingsWithPointCount: Int
    let railMatchCount: Int
    let stationNameCount: Int
}

enum MapHomeRouteReadingsPreparation {
    static func latestRouteInputSignature(
        _ reading: SensorReading?
    ) -> String {
        guard let reading else { return "none" }
        let point = reading.point.map {
            [
                String($0.latitude),
                String($0.longitude),
                String($0.altitude),
                String($0.horizontalAccuracy),
                String($0.verticalAccuracy),
            ].joined(separator: ",")
        } ?? "none"
        return [
            reading.id.uuidString,
            String(reading.timestamp.timeIntervalSinceReferenceDate),
            point,
            reading.gpsAvailable ? "gps" : "approximate",
            reading.locationFixQuality?.rawValue ?? "unspecified",
            reading.speedMetersPerSecond.map { String($0) } ?? "none",
            reading.speedAccuracyMetersPerSecond.map { String($0) } ?? "none",
            reading.courseDegrees.map { String($0) } ?? "none",
            reading.courseAccuracyDegrees.map { String($0) } ?? "none",
            reading.motion.rawValue,
            reading.sequence.map { String($0) } ?? "none",
            reading.sourceDevice?.rawValue ?? "none",
            reading.trackingSessionEnded == true
                ? "session-ended"
                : "session-open",
        ].joined(separator: "|")
    }

    static func prepare(
        routeReadings: [SensorReading],
        liveReadings: [SensorReading],
        latestReading: SensorReading?,
        dayStart: Date,
        dayEnd: Date,
        cancellationCheck: () throws -> Void
    ) throws -> MapHomePreparedRouteReadings {
        try cancellationCheck()
        let sourceCount = routeReadings.count + liveReadings.count
            + (latestReading == nil ? 0 : 1)
        var dayReadings: [SensorReading] = []
        dayReadings.reserveCapacity(sourceCount)
        var watchSourceCount = 0
        for readings in [routeReadings, liveReadings] {
            for (index, reading) in readings.enumerated() {
                if index.isMultiple(of: 256) { try cancellationCheck() }
                if reading.sourceDevice == .appleWatch {
                    watchSourceCount += 1
                }
                guard RouteTimelineTimestamp.isValid(reading.timestamp),
                      reading.timestamp >= dayStart,
                      reading.timestamp < dayEnd else { continue }
                dayReadings.append(reading)
            }
        }
        if let latestReading {
            if latestReading.sourceDevice == .appleWatch {
                watchSourceCount += 1
            }
            if RouteTimelineTimestamp.isValid(latestReading.timestamp),
               latestReading.timestamp >= dayStart,
               latestReading.timestamp < dayEnd {
                dayReadings.append(latestReading)
            }
        }
        let filteredRoute = try TaptionRouteEngineAdapter.prepareFilteredReadings(
            from: dayReadings,
            cancellationCheck: cancellationCheck
        )
        let filtered = filteredRoute.readings
        try cancellationCheck()
        let normalized = try RouteTimelineDataEngine
            .normalizedDisplayReadings(
                filtered,
                cancellationCheck: cancellationCheck
            )
        try cancellationCheck()
        let display = try RouteTimelineDataEngine.displayReadings(
            from: normalized,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()

        var readingsWithPointCount = 0
        var railMatchCount = 0
        var stationNames = Set<String>()
        for (index, reading) in normalized.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            if reading.point != nil { readingsWithPointCount += 1 }
            if reading.matchesRailRoute { railMatchCount += 1 }
            if let name = reading.nearbyStationName { stationNames.insert(name) }
        }
        try cancellationCheck()
        return MapHomePreparedRouteReadings(
            normalized: normalized,
            display: display,
            latestTrustedReading: filteredRoute.latestTrustedReading,
            impossibleLocationCount: filteredRoute.impossibleLocationCount,
            innovationOutlierCount: filteredRoute.innovationOutlierCount,
            sourceCount: sourceCount,
            filteredCount: filtered.count,
            watchSourceCount: watchSourceCount,
            readingsWithPointCount: readingsWithPointCount,
            railMatchCount: railMatchCount,
            stationNameCount: stationNames.count
        )
    }
}

struct MapHomeRouteReadingsPreparationGeneration: Sendable {
    private(set) var currentID = UUID()

    @discardableResult
    mutating func advance() -> UUID {
        currentID = UUID()
        return currentID
    }

    func accepts(_ preparationID: UUID) -> Bool {
        currentID == preparationID
    }
}
