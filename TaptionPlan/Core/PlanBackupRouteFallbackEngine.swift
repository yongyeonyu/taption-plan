import Foundation

/// 백업에 원본 경로 점이 없을 때 장소·이동에서 경로 점을 되살린다.
///
/// 이동 구간마다 양 끝 장소를 잇는 점을 `fallbackSampleInterval`(10분) 간격으로 만들고,
/// 이미 경로 점이 있는 구간은 건너뛴다(`RouteCoverageIndex`). 장소는 끝 시각·시작 시각
/// 순으로 정렬해 이분 탐색하므로(`RouteEndpointIndex`) 구간이 많아도 선형으로 훑지 않는다.
///
/// 원래 `AppModel.swift` 안에 있었는데, 그 파일이 동결 예산(14,641줄)에 정확히 붙어
/// 다른 작업이 들어갈 자리가 없어 계산만 하는 이 엔진을 떼어 냈다(2026-10-26, LCH1026A05).
enum PlanBackupRouteFallbackEngine {
    static let maximumPlaceGap: TimeInterval = 2 * 60 * 60
    static let maximumRouteGap: TimeInterval = 15 * 60
    static let fallbackSampleInterval: TimeInterval = 10 * 60

    static func readings(
        travel: [TravelSegment],
        places: [PlaceStay],
        in span: TimeSpan,
        supplementing archivedReadings: [SensorReading] = []
    ) -> [SensorReading] {
        var inspectionCount: Int? = nil
        return readings(
            travel: travel,
            places: places,
            in: span,
            supplementing: archivedReadings,
            endpointInspectionCount: &inspectionCount
        )
    }

    static func readings(
        travel: [TravelSegment],
        places: [PlaceStay],
        in span: TimeSpan,
        supplementing archivedReadings: [SensorReading] = [],
        endpointInspectionCount: inout Int
    ) -> [SensorReading] {
        var inspectionCount: Int? = endpointInspectionCount
        let result = readings(
            travel: travel,
            places: places,
            in: span,
            supplementing: archivedReadings,
            endpointInspectionCount: &inspectionCount
        )
        endpointInspectionCount = inspectionCount ?? endpointInspectionCount
        return result
    }

    private static func readings(
        travel: [TravelSegment],
        places: [PlaceStay],
        in span: TimeSpan,
        supplementing archivedReadings: [SensorReading],
        endpointInspectionCount: inout Int?
    ) -> [SensorReading] {
        let placesByID = Dictionary(places.map {
            ($0.id, $0)
        }, uniquingKeysWith: { first, _ in first })
        let endpointIndex = RouteEndpointIndex(places: places)
        let routeCoverage = RouteCoverageIndex(readings: archivedReadings)
        let segments = travel
            .filter {
                guard let visibleSpan = $0.span.intersection(with: span) else {
                    return false
                }
                return routeCoverage.needsFallback(in: visibleSpan)
            }
            .sorted { $0.span.start < $1.span.start }
        var readings: [SensorReading] = []
        for segment in segments {
            let samples = routeSamples(
                for: segment,
                placesByID: placesByID,
                endpointIndex: endpointIndex,
                in: span,
                endpointInspectionCount: &endpointInspectionCount
            )
            readings.append(contentsOf: samples.map { sample in
                SensorReading(
                    timestamp: sample.date,
                    point: sample.point,
                    locationFixQuality: .precise,
                    motion: motion(for: segment.mode),
                    motionConfidence: segment.confidence,
                    gpsAvailable: true,
                    behavior: segment.mode.rawValue
                )
            })
        }
        return readings
    }

    private struct RouteEndpointIndex {
        private struct Entry {
            let inputOrder: Int
            let start: Date
            let end: Date
            let point: GeoPoint
        }

        private let orderedByEnd: [Entry]
        private let orderedByStart: [Entry]

        init(places: [PlaceStay]) {
            let entries = places.enumerated().compactMap { inputOrder, place in
                place.point.map {
                    Entry(
                        inputOrder: inputOrder,
                        start: place.span.start,
                        end: place.span.end,
                        point: $0
                    )
                }
            }
            orderedByEnd = entries.sorted {
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.inputOrder > $1.inputOrder
            }
            orderedByStart = entries.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.inputOrder < $1.inputOrder
            }
        }

        func previousPoint(
            before date: Date,
            inspectionCount: inout Int?
        ) -> GeoPoint? {
            var lower = 0
            var upper = orderedByEnd.count
            while lower < upper {
                inspectionCount? += 1
                let middle = lower + (upper - lower) / 2
                if orderedByEnd[middle].end <= date {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            guard lower > 0 else { return nil }
            let entry = orderedByEnd[lower - 1]
            guard date.timeIntervalSince(entry.end) <= maximumPlaceGap else {
                return nil
            }
            return entry.point
        }

        func nextPoint(
            after date: Date,
            inspectionCount: inout Int?
        ) -> GeoPoint? {
            var lower = 0
            var upper = orderedByStart.count
            while lower < upper {
                inspectionCount? += 1
                let middle = lower + (upper - lower) / 2
                if orderedByStart[middle].start < date {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            guard lower < orderedByStart.count else { return nil }
            let entry = orderedByStart[lower]
            guard entry.start.timeIntervalSince(date) <= maximumPlaceGap else {
                return nil
            }
            return entry.point
        }
    }

    private struct RouteCoverageIndex {
        private let timestamps: [Date]

        init(readings: [SensorReading]) {
            timestamps = readings.compactMap { reading -> Date? in
                guard reading.gpsAvailable,
                      RouteTimelineTimestamp.isValid(reading.timestamp),
                      let point = reading.point,
                      point.latitude.isFinite,
                      point.longitude.isFinite,
                      (-90...90).contains(point.latitude),
                      (-180...180).contains(point.longitude) else { return nil }
                return reading.timestamp
            }.sorted()
        }

        func needsFallback(in span: TimeSpan) -> Bool {
            let startIndex = lowerBound(for: span.start)
            let endIndex = upperBound(for: span.end)
            guard endIndex - startIndex >= 2 else { return true }
            let first = timestamps[startIndex]
            let last = timestamps[endIndex - 1]
            guard first.timeIntervalSince(span.start)
                    <= PlanBackupRouteFallbackEngine.maximumRouteGap,
                  span.end.timeIntervalSince(last)
                    <= PlanBackupRouteFallbackEngine.maximumRouteGap else {
                return true
            }
            guard startIndex + 1 < endIndex else { return false }
            for index in (startIndex + 1)..<endIndex
            where timestamps[index].timeIntervalSince(timestamps[index - 1])
                > PlanBackupRouteFallbackEngine.maximumRouteGap {
                return true
            }
            return false
        }

        private func lowerBound(for date: Date) -> Int {
            var lower = 0
            var upper = timestamps.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if timestamps[middle] < date {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower
        }

        private func upperBound(for date: Date) -> Int {
            var lower = 0
            var upper = timestamps.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if timestamps[middle] <= date {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower
        }
    }

    private struct RouteSample {
        let date: Date
        let point: GeoPoint
    }

    private static func routeSamples(
        for segment: TravelSegment,
        placesByID: [UUID: PlaceStay],
        endpointIndex: RouteEndpointIndex,
        in requestedSpan: TimeSpan,
        endpointInspectionCount: inout Int?
    ) -> [RouteSample] {
        let coordinates = routeCoordinates(
            for: segment,
            placesByID: placesByID,
            endpointIndex: endpointIndex,
            endpointInspectionCount: &endpointInspectionCount
        )
        guard coordinates.count >= 2,
              segment.span.duration > 0,
              let visibleSpan = segment.span.intersection(with: requestedSpan)
        else { return [] }
        let startProgress = visibleSpan.start.timeIntervalSince(
            segment.span.start
        ) / segment.span.duration
        let endProgress = visibleSpan.end.timeIntervalSince(
            segment.span.start
        ) / segment.span.duration
        var progressValues = Set([startProgress, endProgress])
        if coordinates.count > 2 {
            for index in 1..<(coordinates.count - 1) {
                let progress = Double(index) / Double(coordinates.count - 1)
                guard progress > startProgress, progress < endProgress else {
                    continue
                }
                progressValues.insert(progress)
            }
        }
        var elapsed = (
            floor(
                visibleSpan.start.timeIntervalSince(segment.span.start)
                    / fallbackSampleInterval
            ) + 1
        ) * fallbackSampleInterval
        let visibleEndElapsed = visibleSpan.end.timeIntervalSince(segment.span.start)
        while elapsed < visibleEndElapsed {
            progressValues.insert(elapsed / segment.span.duration)
            elapsed += fallbackSampleInterval
        }
        return progressValues.sorted().map { progress in
            RouteSample(
                date: segment.span.start.addingTimeInterval(
                    segment.span.duration * progress
                ),
                point: coordinate(in: coordinates, progress: progress)
            )
        }
    }

    private static func coordinate(
        in coordinates: [GeoPoint],
        progress: Double
    ) -> GeoPoint {
        let clamped = min(max(progress, 0), 1)
        let position = clamped * Double(coordinates.count - 1)
        let lowerIndex = min(Int(position.rounded(.down)), coordinates.count - 1)
        let upperIndex = min(lowerIndex + 1, coordinates.count - 1)
        let fraction = position - Double(lowerIndex)
        let lower = coordinates[lowerIndex]
        let upper = coordinates[upperIndex]
        return GeoPoint(
            latitude: lower.latitude
                + (upper.latitude - lower.latitude) * fraction,
            longitude: RouteTimelineLongitude.interpolate(
                from: lower.longitude,
                to: upper.longitude,
                fraction: fraction
            ),
            altitude: lower.altitude
                + (upper.altitude - lower.altitude) * fraction,
            horizontalAccuracy: max(
                lower.horizontalAccuracy,
                upper.horizontalAccuracy
            ),
            verticalAccuracy: max(
                lower.verticalAccuracy,
                upper.verticalAccuracy
            )
        )
    }

    private static func routeCoordinates(
        for segment: TravelSegment,
        placesByID: [UUID: PlaceStay],
        endpointIndex: RouteEndpointIndex,
        endpointInspectionCount: inout Int?
    ) -> [GeoPoint] {
        if let subway = segment.subwayRoute?.coordinates,
           subway.count >= 2 {
            return subway
        }
        let from: GeoPoint?
        if let fromPlaceID = segment.fromPlaceID {
            from = placesByID[fromPlaceID]?.point
        } else {
            from = endpointIndex.previousPoint(
                before: segment.span.start,
                inspectionCount: &endpointInspectionCount
            )
        }
        let to: GeoPoint?
        if let toPlaceID = segment.toPlaceID {
            to = placesByID[toPlaceID]?.point
        } else {
            to = endpointIndex.nextPoint(
                after: segment.span.end,
                inspectionCount: &endpointInspectionCount
            )
        }
        return [from, to].compactMap { $0 }
    }

    private static func motion(for mode: TravelMode) -> MotionKind {
        switch mode {
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        case .bus, .subway, .taxi, .car, .train, .airplane, .ship:
            .automotive
        }
    }
}
