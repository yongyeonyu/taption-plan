import Foundation
import CryptoKit
import TaptionPlanEngine

enum ExpectedRouteTransport: String, Hashable, Sendable {
    case automobile
    case transit
    case walking
    case direct
}

struct ExpectedRouteRequest: Identifiable, Hashable, Sendable {
    let segmentID: UUID
    let mode: TravelMode
    let transport: ExpectedRouteTransport
    let start: GeoPoint
    let end: GeoPoint
    let departureDate: Date
    let arrivalDate: Date
    let provenance: String
    let confidence: Double

    init(
        segmentID: UUID,
        mode: TravelMode,
        transport: ExpectedRouteTransport,
        start: GeoPoint,
        end: GeoPoint,
        departureDate: Date,
        arrivalDate: Date,
        provenance: String = "expected-route",
        confidence: Double = 0
    ) {
        self.segmentID = segmentID
        self.mode = mode
        self.transport = transport
        self.start = start
        self.end = end
        self.departureDate = departureDate
        self.arrivalDate = arrivalDate
        self.provenance = provenance
        self.confidence = min(1, max(0, confidence))
    }

    var id: UUID {
        var seed = Data("expected-route-gap-v1".utf8)
        seed.append(contentsOf: segmentID.uuidString.lowercased().utf8)
        seed.append(0)
        for date in [departureDate, arrivalDate] {
            var bits = date.timeIntervalSince1970.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { seed.append(contentsOf: $0) }
        }
        let digest = Array(SHA256.hash(data: seed).prefix(16))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], (digest[6] & 0x0F) | 0x50, digest[7],
            (digest[8] & 0x3F) | 0x80, digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

}

struct ExpectedRouteRequestReadingIndex {
    private let readings: [SensorReading]

    init(orderedReadings: [SensorReading]) {
        readings = orderedReadings
    }

    func readings(
        in span: TimeSpan,
        operationCount: inout Int
    ) -> ArraySlice<SensorReading> {
        let lower = lowerBound(span.start, operationCount: &operationCount)
        let upper = upperBound(span.end, operationCount: &operationCount)
        return readings[lower..<upper]
    }

    private func lowerBound(
        _ timestamp: Date,
        operationCount: inout Int
    ) -> Int {
        var lower = 0
        var upper = readings.count
        while lower < upper {
            operationCount += 1
            let middle = lower + (upper - lower) / 2
            if readings[middle].timestamp < timestamp {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func upperBound(
        _ timestamp: Date,
        operationCount: inout Int
    ) -> Int {
        var lower = 0
        var upper = readings.count
        while lower < upper {
            operationCount += 1
            let middle = lower + (upper - lower) / 2
            if readings[middle].timestamp <= timestamp {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

struct ExpectedRouteRequestConfirmedSpanIndex {
    private let spans: [TimeSpan]

    init(
        _ source: [TimeSpan],
        operationCount: inout Int,
        cancellationCheck: () throws -> Void
    ) rethrows {
        var valid: [TimeSpan] = []
        valid.reserveCapacity(source.count)
        for (index, span) in source.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            operationCount += 1
            if span.duration > 0 { valid.append(span) }
        }
        let ordered = try RouteTimelineCancellableSort.sorted(
            valid,
            by: { $0.start < $1.start },
            cancellationCheck: cancellationCheck
        )
        var merged: [TimeSpan] = []
        merged.reserveCapacity(ordered.count)
        for (index, span) in ordered.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            operationCount += 1
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1] = TimeSpan(
                    start: last.start,
                    end: max(last.end, span.end)
                )
            } else {
                merged.append(span)
            }
        }
        spans = merged
    }

    func overlapsPositiveDuration(
        _ span: TimeSpan,
        operationCount: inout Int
    ) -> Bool {
        guard span.start < span.end else { return false }
        var lower = 0
        var upper = spans.count
        while lower < upper {
            operationCount += 1
            let middle = lower + (upper - lower) / 2
            if spans[middle].end <= span.start {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < spans.count else { return false }
        operationCount += 1
        return spans[lower].start < span.end
    }
}

private struct ExpectedRouteRequestSessionEndIndex {
    private let timestamps: [Date]

    init(
        orderedReadings: [SensorReading],
        operationCount: inout Int,
        cancellationCheck: () throws -> Void
    ) rethrows {
        var ended: [Date] = []
        for (index, reading) in orderedReadings.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            operationCount += 1
            if reading.trackingSessionEnded == true {
                ended.append(reading.timestamp)
            }
        }
        try cancellationCheck()
        timestamps = ended
    }

    func contains(
        from start: Date,
        before end: Date,
        operationCount: inout Int
    ) -> Bool {
        guard start < end else { return false }
        let lower = lowerBound(start, operationCount: &operationCount)
        let upper = lowerBound(end, operationCount: &operationCount)
        return lower < upper
    }

    private func lowerBound(
        _ timestamp: Date,
        operationCount: inout Int
    ) -> Int {
        var lower = 0
        var upper = timestamps.count
        while lower < upper {
            operationCount += 1
            let middle = lower + (upper - lower) / 2
            if timestamps[middle] < timestamp {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

/// Produces display-only network-route requests. The returned requests never
/// replace archived GPS points or mutate classified travel segments.
enum ExpectedRouteRequestEngine {
    static let minimumRouteDistanceMeters: Double = 20

    private struct RequestCandidate {
        let segment: TravelSegment
        let request: ExpectedRouteRequest
    }

    private struct DuplicateKey: Hashable {
        let fromPlaceID: UUID?
        let toPlaceID: UUID?
        let mode: String
        let start: Date
        let end: Date
    }

    private struct RequestTimeKey: Hashable {
        let departureDate: Date
        let arrivalDate: Date
    }

    private struct RouteGap {
        let start: GeoPoint
        let end: GeoPoint
        let span: TimeSpan
    }

    private struct AdjacentTravelCandidate {
        let id: UUID
        let mode: RouteTravelMode
        let start: Date
        let end: Date
        let order: Int
    }

    private struct AdjacentTravelChoices {
        private(set) var first: AdjacentTravelCandidate?
        private(set) var second: AdjacentTravelCandidate?

        mutating func include(
            _ candidate: AdjacentTravelCandidate,
            precedes: (AdjacentTravelCandidate, AdjacentTravelCandidate) -> Bool
        ) {
            if let first, first.id == candidate.id {
                if precedes(candidate, first) { self.first = candidate }
                return
            }
            if let second, second.id == candidate.id {
                guard precedes(candidate, second) else { return }
                if let first, precedes(candidate, first) {
                    self.second = first
                    self.first = candidate
                } else {
                    self.second = candidate
                }
                return
            }
            if let first, precedes(candidate, first) {
                second = first
                self.first = candidate
            } else if second == nil || precedes(candidate, second!) {
                second = candidate
            }
        }

        func best(excluding id: UUID) -> AdjacentTravelCandidate? {
            guard let first else { return nil }
            return first.id == id ? second : first
        }
    }

    private struct TravelAdjacencyIndex {
        private let previousByEnd: [AdjacentTravelCandidate]
        private let previousChoices: [AdjacentTravelChoices]
        private let followingByStart: [AdjacentTravelCandidate]
        private let followingChoices: [AdjacentTravelChoices]

        init(
            orderedTravel: [TravelSegment],
            operationCount: inout Int,
            cancellationCheck: () throws -> Void
        ) rethrows {
            var candidates: [AdjacentTravelCandidate] = []
            candidates.reserveCapacity(orderedTravel.count)
            for (index, segment) in orderedTravel.enumerated() {
                if index.isMultiple(of: 256) { try cancellationCheck() }
                operationCount += 1
                candidates.append(AdjacentTravelCandidate(
                    id: segment.id,
                    mode: routeMode(for: segment.mode),
                    start: segment.span.start,
                    end: segment.span.end,
                    order: index
                ))
            }
            let previousByEnd = try RouteTimelineCancellableSort.sorted(
                candidates,
                by: {
                    if $0.end != $1.end { return $0.end < $1.end }
                    return $0.order < $1.order
                },
                cancellationCheck: cancellationCheck
            )

            var previous = AdjacentTravelChoices()
            var prefix: [AdjacentTravelChoices] = []
            prefix.reserveCapacity(previousByEnd.count)
            for (index, candidate) in previousByEnd.enumerated() {
                if index.isMultiple(of: 256) { try cancellationCheck() }
                operationCount += 1
                previous.include(candidate, precedes: Self.precedesPrevious)
                prefix.append(previous)
            }

            var following = AdjacentTravelChoices()
            var suffix = Array(
                repeating: AdjacentTravelChoices(),
                count: candidates.count
            )
            for (processed, index) in candidates.indices.reversed().enumerated() {
                if processed.isMultiple(of: 256) { try cancellationCheck() }
                operationCount += 1
                following.include(candidates[index], precedes: Self.precedesFollowing)
                suffix[index] = following
            }
            try cancellationCheck()
            self.previousByEnd = previousByEnd
            self.previousChoices = prefix
            self.followingByStart = candidates
            followingChoices = suffix
        }

        func before(
            _ segment: TravelSegment,
            operationCount: inout Int
        ) -> RouteTravelMode {
            let limit = upperBoundEnd(
                segment.span.start,
                operationCount: &operationCount
            )
            operationCount += 1
            guard limit > 0,
                  let candidate = previousChoices[limit - 1]
                    .best(excluding: segment.id) else { return .unknown }
            return candidate.mode
        }

        func after(
            _ segment: TravelSegment,
            operationCount: inout Int
        ) -> RouteTravelMode {
            let index = lowerBoundStart(
                segment.span.end,
                operationCount: &operationCount
            )
            operationCount += 1
            guard index < followingChoices.count,
                  let candidate = followingChoices[index]
                    .best(excluding: segment.id) else { return .unknown }
            return candidate.mode
        }

        private func upperBoundEnd(
            _ date: Date,
            operationCount: inout Int
        ) -> Int {
            var lower = 0
            var upper = previousByEnd.count
            while lower < upper {
                operationCount += 1
                let middle = lower + (upper - lower) / 2
                if previousByEnd[middle].end <= date {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower
        }

        private func lowerBoundStart(
            _ date: Date,
            operationCount: inout Int
        ) -> Int {
            var lower = 0
            var upper = followingChoices.count
            while lower < upper {
                operationCount += 1
                let middle = lower + (upper - lower) / 2
                if followingByStart[middle].start < date {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower
        }

        private static func precedesPrevious(
            _ lhs: AdjacentTravelCandidate,
            _ rhs: AdjacentTravelCandidate
        ) -> Bool {
            if lhs.end != rhs.end { return lhs.end > rhs.end }
            return lhs.order < rhs.order
        }

        private static func precedesFollowing(
            _ lhs: AdjacentTravelCandidate,
            _ rhs: AdjacentTravelCandidate
        ) -> Bool {
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.order < rhs.order
        }
    }

    static func requests(
        travel: [TravelSegment],
        places _: [PlaceStay],
        readings: [SensorReading],
        in day: TimeSpan,
        through cutoff: Date,
        frequentPlaces _: [FrequentPlace] = [],
        gpsLoggingInterval: TimeInterval = GPSLoggingPreferences.standard.interval
    ) -> [ExpectedRouteRequest] {
        var ignoredOperationCount = 0
        return requests(
            travel: travel,
            places: [],
            readings: readings,
            in: day,
            through: cutoff,
            frequentPlaces: [],
            gpsLoggingInterval: gpsLoggingInterval,
            operationCount: &ignoredOperationCount
        )
    }

    static func requests(
        travel: [TravelSegment],
        places _: [PlaceStay],
        readings: [SensorReading],
        in day: TimeSpan,
        through cutoff: Date,
        frequentPlaces _: [FrequentPlace],
        gpsLoggingInterval: TimeInterval = GPSLoggingPreferences.standard.interval,
        operationCount: inout Int
    ) -> [ExpectedRouteRequest] {
        (try? requests(
            travel: travel,
            places: [],
            readings: readings,
            in: day,
            through: cutoff,
            frequentPlaces: [],
            gpsLoggingInterval: gpsLoggingInterval,
            operationCount: &operationCount,
            cancellationCheck: { try Task.checkCancellation() }
        )) ?? []
    }

    static func requests(
        travel: [TravelSegment],
        places _: [PlaceStay],
        readings: [SensorReading],
        in day: TimeSpan,
        through cutoff: Date,
        frequentPlaces _: [FrequentPlace],
        gpsLoggingInterval: TimeInterval = GPSLoggingPreferences.standard.interval,
        operationCount: inout Int,
        cancellationCheck: () throws -> Void
    ) throws -> [ExpectedRouteRequest] {
        operationCount = 0
        try cancellationCheck()
        var filteredReadings: [SensorReading] = []
        filteredReadings.reserveCapacity(readings.count)
        for (index, reading) in readings.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            operationCount += 1
            guard RouteTimelineTimestamp.isValid(reading.timestamp),
                  reading.timestamp >= day.start,
                  reading.timestamp <= day.end else { continue }
            filteredReadings.append(reading)
        }
        try cancellationCheck()
        let orderedReadings = try RouteTimelineCancellableSort.sorted(
            filteredReadings,
            by: {
                if $0.timestamp != $1.timestamp {
                    return $0.timestamp < $1.timestamp
                }
                return $0.id.uuidString < $1.id.uuidString
            },
            cancellationCheck: cancellationCheck
        )
        let readingIndex = ExpectedRouteRequestReadingIndex(
            orderedReadings: orderedReadings
        )
        let sessionEndIndex = try ExpectedRouteRequestSessionEndIndex(
            orderedReadings: orderedReadings,
            operationCount: &operationCount,
            cancellationCheck: cancellationCheck
        )

        let uniqueTravel = try deduplicated(
            travel,
            operationCount: &operationCount,
            cancellationCheck: cancellationCheck
        )
        let orderedTravel = try RouteTimelineCancellableSort.sorted(
            uniqueTravel,
            by: { $0.span.start < $1.span.start },
            cancellationCheck: cancellationCheck
        )
        var confirmedSourceSpans: [TimeSpan] = []
        confirmedSourceSpans.reserveCapacity(travel.count)
        for (index, segment) in travel.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            operationCount += 1
            if segment.isConfirmed {
                confirmedSourceSpans.append(segment.span)
            }
        }
        let confirmedSpans = try ExpectedRouteRequestConfirmedSpanIndex(
            confirmedSourceSpans,
            operationCount: &operationCount,
            cancellationCheck: cancellationCheck
        )
        let adjacentTravel = try TravelAdjacencyIndex(
            orderedTravel: orderedTravel,
            operationCount: &operationCount,
            cancellationCheck: cancellationCheck
        )
        var candidates: [RequestCandidate] = []

        for (index, segment) in orderedTravel.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            operationCount += 1
            guard segment.span.intersection(with: day) != nil,
                  segment.span.start < cutoff,
                  let transport = transport(for: segment),
                  !segment.isConfirmed else { continue }

            let visibleEnd = min(segment.span.end, cutoff)
            guard segment.span.start < visibleEnd else { continue }
            let visibleSpan = TimeSpan(
                start: max(segment.span.start, day.start),
                end: min(visibleEnd, day.end)
            )
            let readingsInSegment = readingIndex.readings(
                in: visibleSpan,
                operationCount: &operationCount
            )
            let gaps = try missingRouteGaps(
                readings: readingsInSegment,
                sessionEndIndex: sessionEndIndex,
                minimumGap: max(60, 3 * gpsLoggingInterval),
                operationCount: &operationCount,
                cancellationCheck: cancellationCheck
            )
            guard !gaps.isEmpty else { continue }
            let precedingMode = adjacentTravel.before(
                segment,
                operationCount: &operationCount
            )
            let followingMode = adjacentTravel.after(
                segment,
                operationCount: &operationCount
            )

            for gap in gaps {
                try cancellationCheck()
                operationCount += 1
                guard distanceMeters(gap.start, gap.end)
                        >= minimumRouteDistanceMeters,
                      !confirmedSpans.overlapsPositiveDuration(
                        gap.span,
                        operationCount: &operationCount
                      ) else { continue }
                let gapReadings = readingIndex.readings(
                    in: gap.span,
                    operationCount: &operationCount
                )
                var samples: [SensorReading] = []
                samples.reserveCapacity(gapReadings.count)
                for (index, reading) in gapReadings.enumerated() {
                    if index.isMultiple(of: 256) { try cancellationCheck() }
                    operationCount += 1
                    if reliableLocationReading(reading) { samples.append(reading) }
                }
                let inference = RouteGapInferenceEngine().infer(.init(
                    start: gap.span.start,
                    end: gap.span.end,
                    startCoordinate: RouteCoordinate(
                        latitude: gap.start.latitude,
                        longitude: gap.start.longitude
                    ),
                    endCoordinate: RouteCoordinate(
                        latitude: gap.end.latitude,
                        longitude: gap.end.longitude
                    ),
                    samples: try TaptionRouteEngineAdapter.samples(
                        from: samples,
                        cancellationCheck: cancellationCheck
                    ),
                    precedingMode: precedingMode,
                    followingMode: followingMode,
                    explicitMode: routeMode(for: segment.mode),
                    endpointConfidence: min(
                        endpointConfidence(gap.start),
                        endpointConfidence(gap.end)
                    )
                ))
                guard inference.allowsConnection else { continue }
                candidates.append(RequestCandidate(
                    segment: segment,
                    request: ExpectedRouteRequest(
                        segmentID: segment.id,
                        mode: segment.mode,
                        transport: transport,
                        start: gap.start,
                        end: gap.end,
                        departureDate: gap.span.start,
                        arrivalDate: gap.span.end,
                        provenance: inference.provenance,
                        confidence: inference.confidence
                    )
                ))
            }
        }
        let uniqueCandidates = try deduplicatedRequests(
            candidates,
            operationCount: &operationCount,
            cancellationCheck: cancellationCheck
        )
        var requests: [ExpectedRouteRequest] = []
        requests.reserveCapacity(uniqueCandidates.count)
        for (index, candidate) in uniqueCandidates.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            requests.append(candidate.request)
        }
        return try RouteTimelineCancellableSort.sorted(
            requests,
            by: {
                if $0.departureDate != $1.departureDate {
                    return $0.departureDate < $1.departureDate
                }
                return $0.id.uuidString < $1.id.uuidString
            },
            cancellationCheck: cancellationCheck
        )
    }

    private static func transport(
        for segment: TravelSegment
    ) -> ExpectedRouteTransport? {
        switch segment.mode {
        case .car, .taxi:
            .automobile
        case .bus, .subway, .train:
            .transit
        case .walking, .running, .cycling:
            .walking
        case .airplane, .ship:
            .direct
        }
    }

    private static func routeMode(for mode: TravelMode) -> RouteTravelMode {
        switch mode {
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        case .bus: .bus
        case .subway: .subway
        case .taxi, .car: .automotive
        case .train: .train
        case .airplane: .airplane
        case .ship: .ship
        }
    }

    private static func endpointConfidence(_ point: GeoPoint) -> Double {
        let accuracy = point.horizontalAccuracy
        guard accuracy.isFinite, accuracy >= 0 else { return 0.8 }
        if accuracy <= 20 { return 1 }
        if accuracy <= 100 { return 0.9 }
        if accuracy <= 150 { return 0.75 }
        return 0.5
    }

    private static func reliableLocationReading(
        _ reading: SensorReading
    ) -> Bool {
        guard let point = reading.point else { return false }
        return isValid(point)
            && reading.gpsAvailable
            && reading.locationFixQuality != .approximate
            && point.horizontalAccuracy.isFinite
            && point.horizontalAccuracy >= 0
            && point.horizontalAccuracy <= 150
    }

    /// 임시 경로는 GPS 로깅 주기의 3배 넘게 신호가 없는 틈에만 만든다(대표 지시, EXP1029A01).
    /// 전에는 15분 고정(또는 5분 넘고 1km 넘음)이라 로깅 주기를 1분으로 줄여도 틈을 늦게 알아봤다.
    private static func missingRouteGaps(
        readings: ArraySlice<SensorReading>,
        sessionEndIndex: ExpectedRouteRequestSessionEndIndex,
        minimumGap: TimeInterval,
        operationCount: inout Int,
        cancellationCheck: () throws -> Void
    ) rethrows -> [RouteGap] {
        var observed: [SensorReading] = []
        observed.reserveCapacity(readings.count)
        for (index, reading) in readings.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            operationCount += 1
            if RouteTimelineTimestamp.isValid(reading.timestamp),
               reliableLocationReading(reading) {
                observed.append(reading)
            }
        }
        observed = removingIsolatedImpossibleJumps(from: observed)
        guard observed.count >= 2 else { return [] }
        var gaps: [RouteGap] = []
        for index in 0..<(observed.count - 1) {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            let lhs = observed[index]
            let rhs = observed[index + 1]
            operationCount += 1
            guard let lhsPoint = lhs.point, let rhsPoint = rhs.point else {
                continue
            }
            guard !sessionEndIndex.contains(
                from: lhs.timestamp,
                before: rhs.timestamp,
                operationCount: &operationCount
            ) else { continue }
            let duration = rhs.timestamp.timeIntervalSince(lhs.timestamp)
            guard duration >= minimumGap, !TaptionRouteEngineAdapter.isSparseVehicleGap(from: lhs, to: rhs, readings: readings) else { continue }
            // 물리적으로 불가능한 속도의 끊김은 빠진 이동이 아니라 튄 위치다.
            // 이런 구간에 예상 경로를 이으면 회사↔멀리 떨어진 곳 직선이 그려진다.
            guard !isImpossibleJump(
                from: lhsPoint,
                to: rhsPoint,
                duration: duration
            ) else { continue }
            gaps.append(RouteGap(
                start: lhsPoint,
                end: rhsPoint,
                span: TimeSpan(start: lhs.timestamp, end: rhs.timestamp)
            ))
        }
        return gaps
    }

    /// 라우트 필터와 같은 기준: 15분 이내는 지상 이동 한계, 그 이후는 항공기 속도까지 허용한다.
    private static let longGapImpossibleSpeedMetersPerSecond: Double = 280

    private static func isImpossibleJump(
        from start: GeoPoint,
        to end: GeoPoint,
        duration: TimeInterval
    ) -> Bool {
        guard duration > 0 else { return false }
        let limit = duration <= RouteSparseConnectionPolicy.maximumGapDuration
            ? RouteSparseConnectionPolicy.impossibleSpeedMetersPerSecond
            : longGapImpossibleSpeedMetersPerSecond
        return distanceMeters(start, end) / duration > limit
    }

    /// 불가능한 속도로 튀었다가 바로 원래 자리로 돌아오는 점 하나를 제거한다.
    /// 되돌아오지 않는 점(실제 이동일 수 있음)은 그대로 둔다.
    private static func removingIsolatedImpossibleJumps(
        from readings: [SensorReading]
    ) -> [SensorReading] {
        guard readings.count >= 3 else { return readings }
        var kept: [SensorReading] = []
        kept.reserveCapacity(readings.count)
        for index in readings.indices {
            let reading = readings[index]
            guard let previous = kept.last,
                  let previousPoint = previous.point,
                  let point = reading.point,
                  index + 1 < readings.count,
                  let nextPoint = readings[index + 1].point else {
                kept.append(reading)
                continue
            }
            let jumpsAway = isImpossibleJump(
                from: previousPoint,
                to: point,
                duration: reading.timestamp.timeIntervalSince(previous.timestamp)
            )
            let nextDuration = readings[index + 1].timestamp
                .timeIntervalSince(previous.timestamp)
            let nextIsPlausible = !isImpossibleJump(
                from: previousPoint,
                to: nextPoint,
                duration: nextDuration
            )
            if jumpsAway && nextIsPlausible { continue }
            kept.append(reading)
        }
        return kept
    }

    private static func deduplicated(
        _ travel: [TravelSegment],
        operationCount: inout Int,
        cancellationCheck: () throws -> Void
    ) rethrows -> [TravelSegment] {
        var selected: [DuplicateKey: TravelSegment] = [:]
        for (index, segment) in travel.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            operationCount += 1
            let key = DuplicateKey(
                fromPlaceID: segment.fromPlaceID,
                toPlaceID: segment.toPlaceID,
                mode: segment.mode.rawValue,
                start: segment.span.start,
                end: segment.span.end
            )
            guard let current = selected[key] else {
                selected[key] = segment
                continue
            }
            if isRicher(segment, than: current) {
                selected[key] = segment
            }
        }
        var result: [TravelSegment] = []
        result.reserveCapacity(selected.count)
        let ordered = selected.values.sorted {
            if $0.span.start != $1.span.start { return $0.span.start < $1.span.start }
            if $0.span.end != $1.span.end { return $0.span.end < $1.span.end }
            return $0.id.uuidString < $1.id.uuidString
        }
        for (index, segment) in ordered.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            result.append(segment)
        }
        return result
    }

    private static func deduplicatedRequests(
        _ candidates: [RequestCandidate],
        operationCount: inout Int,
        cancellationCheck: () throws -> Void
    ) rethrows -> [RequestCandidate] {
        var selected: [RequestCandidate] = []
        var indicesByTime: [RequestTimeKey: [Int]] = [:]
        for candidate in candidates {
            operationCount += 1
            if operationCount.isMultiple(of: 256) { try cancellationCheck() }
            let key = RequestTimeKey(
                departureDate: candidate.request.departureDate,
                arrivalDate: candidate.request.arrivalDate
            )
            var matchingIndex: Int?
            for index in indicesByTime[key, default: []] {
                operationCount += 1
                if operationCount.isMultiple(of: 256) { try cancellationCheck() }
                if sameRequestEndpoints(
                    selected[index].request,
                    candidate.request
                ) {
                    matchingIndex = index
                    break
                }
            }
            guard let index = matchingIndex else {
                indicesByTime[key, default: []].append(selected.count)
                selected.append(candidate)
                continue
            }
            if isRicher(candidate.segment, than: selected[index].segment) {
                selected[index] = candidate
            }
        }
        return selected
    }

    private static func sameRequestEndpoints(
        _ lhs: ExpectedRouteRequest,
        _ rhs: ExpectedRouteRequest
    ) -> Bool {
        let sameDirection = distanceMeters(lhs.start, rhs.start) <= 100
            && distanceMeters(lhs.end, rhs.end) <= 100
        let reverseDirection = distanceMeters(lhs.start, rhs.end) <= 100
            && distanceMeters(lhs.end, rhs.start) <= 100
        return sameDirection || reverseDirection
    }

    private static func isRicher(
        _ candidate: TravelSegment,
        than current: TravelSegment
    ) -> Bool {
        let candidateValues = richnessValues(candidate)
        let currentValues = richnessValues(current)
        for index in candidateValues.indices {
            if candidateValues[index] != currentValues[index] {
                return candidateValues[index] > currentValues[index]
            }
        }
        return candidate.id.uuidString < current.id.uuidString
    }

    private static func richnessValues(_ segment: TravelSegment) -> [Int] {
        let confidence = switch segment.confidence {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
        return [
            segment.isConfirmed ? 1 : 0,
            segment.subwayRoute.map(SubwayStationCatalog.isValid) == true
                ? 1
                : 0,
            segment.evidence.count,
            confidence,
        ]
    }

    private static func isValid(_ point: GeoPoint) -> Bool {
        point.latitude.isFinite
            && point.longitude.isFinite
            && (-90...90).contains(point.latitude)
            && (-180...180).contains(point.longitude)
    }
}
