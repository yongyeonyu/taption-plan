import Foundation
import TaptionPlanCore

struct SensorReadingsLoadResult: Equatable, Sendable {
    let readings: [SensorReading]
    let isComplete: Bool
    let watchSummaries: [TaptionWatchSensorSummary]
    let watchAccelerationChunks: [TaptionWatchAccelerationChunk]

    init(
        readings: [SensorReading],
        isComplete: Bool,
        watchSummaries: [TaptionWatchSensorSummary] = [],
        watchAccelerationChunks: [TaptionWatchAccelerationChunk] = []
    ) {
        self.readings = readings
        self.isComplete = isComplete
        self.watchSummaries = watchSummaries
        self.watchAccelerationChunks = watchAccelerationChunks
    }

    var watchAccelerationSamples: [TaptionWatchAccelerationSample] {
        Dictionary(
            watchAccelerationChunks
                .flatMap(\.samples)
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted {
            if $0.capturedAt == $1.capturedAt {
                return $0.sequence < $1.sequence
            }
            return $0.capturedAt < $1.capturedAt
        }
    }
}


struct PlanDayDataSnapshot: Equatable, Sendable {
    private struct SourceFingerprintPayload: Encodable {
        let actuals: [ActualRecord]
        let places: [PlaceStay]
        let travel: [TravelSegment]
    }

    let day: Date
    let sourceRevision: UInt64
    let projectionVersion: UInt64
    let sourceUpdatedAt: Date
    let sourceFingerprint: String?
    let actuals: [ActualRecord]
    let places: [PlaceStay]
    let travel: [TravelSegment]
    let readings: [SensorReading]
    let isComplete: Bool

    var dataTrustProjection: TaptionDataTrustProjection {
        TaptionActivityEngineAdapter.dataTrustProjection(
            readings: readings,
            actuals: actuals,
            places: places,
            travel: travel
        )
    }

    init(
        day: Date,
        sourceRevision: UInt64,
        sourceUpdatedAt: Date,
        sourceFingerprint: String? = nil,
        projectionVersion: UInt64 = TaptionPlanV3Store.projectionVersion,
        actuals: [ActualRecord],
        places: [PlaceStay],
        travel: [TravelSegment],
        readings: [SensorReading],
        isComplete: Bool
    ) {
        self.day = day
        self.sourceRevision = sourceRevision
        self.projectionVersion = projectionVersion
        self.sourceUpdatedAt = sourceUpdatedAt
        self.sourceFingerprint = sourceFingerprint ?? Self.sourceFingerprint(
            actuals: actuals,
            places: places,
            travel: travel
        )
        self.actuals = actuals
        self.places = places
        self.travel = travel
        self.readings = Self.uniqueReadings(readings)
        self.isComplete = isComplete
    }

    private init(
        preparedDay day: Date,
        sourceRevision: UInt64,
        sourceUpdatedAt: Date,
        sourceFingerprint: String?,
        projectionVersion: UInt64,
        actuals: [ActualRecord],
        places: [PlaceStay],
        travel: [TravelSegment],
        readings: [SensorReading],
        isComplete: Bool
    ) {
        self.day = day
        self.sourceRevision = sourceRevision
        self.projectionVersion = projectionVersion
        self.sourceUpdatedAt = sourceUpdatedAt
        self.sourceFingerprint = sourceFingerprint
        self.actuals = actuals
        self.places = places
        self.travel = travel
        self.readings = readings
        self.isComplete = isComplete
    }

    func matchesCurrentSource(
        revision: UInt64,
        fingerprint: @autoclosure () -> String?
    ) -> Bool {
        if sourceRevision == revision { return true }
        guard let sourceFingerprint, let fingerprint = fingerprint() else { return false }
        return sourceFingerprint == fingerprint
    }

    static func make(
        date: Date,
        sourceRevision: UInt64,
        source: TaptionDataSnapshot,
        sensorResult: SensorReadingsLoadResult,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Self {
        make(
            date: date,
            sourceRevision: sourceRevision,
            source: source,
            sensorResult: sensorResult,
            calendar: calendar,
            cancellationCheck: {}
        )
    }

    static func make(
        date: Date,
        sourceRevision: UInt64,
        source: TaptionDataSnapshot,
        sensorResult: SensorReadingsLoadResult,
        calendar: Calendar = .autoupdatingCurrent,
        cancellationCheck: () throws -> Void
    ) rethrows -> Self {
        try cancellationCheck()
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let day = TimeSpan(start: dayStart, end: dayEnd)
        let records = try sourceRecords(
            in: day,
            source: source,
            dayEnd: dayEnd,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        var readings: [SensorReading] = []
        readings.reserveCapacity(sensorResult.readings.count)
        for (index, reading) in sensorResult.readings.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard reading.timestamp >= dayStart,
                  reading.timestamp < dayEnd else { continue }
            readings.append(reading)
        }
        let fingerprint = try sourceFingerprint(
            actuals: records.actuals,
            places: records.places,
            travel: records.travel,
            cancellationCheck: cancellationCheck
        )
        let uniqueReadings = try uniqueReadings(
            readings,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        return Self(
            preparedDay: dayStart,
            sourceRevision: sourceRevision,
            sourceUpdatedAt: source.updatedAt,
            sourceFingerprint: fingerprint,
            projectionVersion: TaptionPlanV3Store.projectionVersion,
            actuals: records.actuals,
            places: records.places,
            travel: records.travel,
            readings: uniqueReadings,
            isComplete: sensorResult.isComplete
        )
    }

    static func incomplete(
        date: Date,
        sourceRevision: UInt64,
        source: TaptionDataSnapshot,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Self {
        Self(
            preparedDay: calendar.startOfDay(for: date),
            sourceRevision: sourceRevision,
            sourceUpdatedAt: source.updatedAt,
            sourceFingerprint: nil,
            projectionVersion: TaptionPlanV3Store.projectionVersion,
            actuals: [],
            places: [],
            travel: [],
            readings: [],
            isComplete: false
        )
    }

    static func rebase(
        from previous: Self,
        date: Date,
        sourceRevision: UInt64,
        source: TaptionDataSnapshot,
        calendar: Calendar = .autoupdatingCurrent,
        cancellationCheck: () throws -> Void
    ) rethrows -> Self {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let records = try sourceRecords(
            in: TimeSpan(start: dayStart, end: dayEnd),
            source: source,
            dayEnd: dayEnd,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        var readings: [SensorReading] = []
        readings.reserveCapacity(previous.readings.count)
        for (index, reading) in previous.readings.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard reading.timestamp >= dayStart,
                  reading.timestamp < dayEnd else { continue }
            readings.append(reading)
        }
        let fingerprint = try sourceFingerprint(
            actuals: records.actuals,
            places: records.places,
            travel: records.travel,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        return Self(
            preparedDay: dayStart,
            sourceRevision: sourceRevision,
            sourceUpdatedAt: source.updatedAt,
            sourceFingerprint: fingerprint,
            projectionVersion: TaptionPlanV3Store.projectionVersion,
            actuals: records.actuals,
            places: records.places,
            travel: records.travel,
            readings: readings,
            isComplete: previous.isComplete
        )
    }

    static func sourceFingerprint(
        date: Date,
        source: TaptionDataSnapshot,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String? {
        sourceFingerprint(
            date: date,
            source: source,
            calendar: calendar,
            cancellationCheck: {}
        )
    }

    static func sourceFingerprint(
        date: Date,
        source: TaptionDataSnapshot,
        calendar: Calendar = .autoupdatingCurrent,
        cancellationCheck: () throws -> Void
    ) rethrows -> String? {
        try cancellationCheck()
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let records = try sourceRecords(
            in: TimeSpan(start: dayStart, end: dayEnd),
            source: source,
            dayEnd: dayEnd,
            cancellationCheck: cancellationCheck
        )
        return try sourceFingerprint(
            actuals: records.actuals,
            places: records.places,
            travel: records.travel,
            cancellationCheck: cancellationCheck
        )
    }

    private static func sourceRecords(
        in day: TimeSpan,
        source: TaptionDataSnapshot,
        dayEnd: Date
    ) -> (
        actuals: [ActualRecord],
        places: [PlaceStay],
        travel: [TravelSegment]
    ) {
        (
            source.actuals.filter {
                TimeSpan(
                    start: $0.startedAt,
                    end: max($0.startedAt, $0.endedAt ?? dayEnd)
                ).intersection(with: day) != nil
            },
            source.places.filter { $0.span.intersection(with: day) != nil },
            source.travel.filter { $0.span.intersection(with: day) != nil }
        )
    }

    private static func sourceRecords(
        in day: TimeSpan,
        source: TaptionDataSnapshot,
        dayEnd: Date,
        cancellationCheck: () throws -> Void
    ) rethrows -> (
        actuals: [ActualRecord],
        places: [PlaceStay],
        travel: [TravelSegment]
    ) {
        try cancellationCheck()
        var actuals: [ActualRecord] = []
        actuals.reserveCapacity(min(source.actuals.count, 1_024))
        for (index, actual) in source.actuals.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard TimeSpan(
                start: actual.startedAt,
                end: max(actual.startedAt, actual.endedAt ?? dayEnd)
            ).intersection(with: day) != nil else { continue }
            actuals.append(actual)
        }

        try cancellationCheck()
        var places: [PlaceStay] = []
        places.reserveCapacity(min(source.places.count, 256))
        for (index, place) in source.places.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard place.span.intersection(with: day) != nil else { continue }
            places.append(place)
        }

        try cancellationCheck()
        var travel: [TravelSegment] = []
        travel.reserveCapacity(min(source.travel.count, 256))
        for (index, segment) in source.travel.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            guard segment.span.intersection(with: day) != nil else { continue }
            travel.append(segment)
        }
        return (actuals, places, travel)
    }

    private static func sourceFingerprint(
        actuals: [ActualRecord],
        places: [PlaceStay],
        travel: [TravelSegment]
    ) -> String? {
        try? TaptionPlanCanonicalStorage.encode(
            SourceFingerprintPayload(
                actuals: actuals.sorted { TaptionCanonicalUUIDOrder.precedes($0.id, $1.id) },
                places: places.sorted { TaptionCanonicalUUIDOrder.precedes($0.id, $1.id) },
                travel: travel.sorted { TaptionCanonicalUUIDOrder.precedes($0.id, $1.id) }
            ),
            compress: false
        ).checksum
    }

    private static func sourceFingerprint(
        actuals: [ActualRecord],
        places: [PlaceStay],
        travel: [TravelSegment],
        cancellationCheck: () throws -> Void
    ) rethrows -> String? {
        let orderedActuals = try RouteTimelineCancellableSort.sorted(
            actuals,
            by: { TaptionCanonicalUUIDOrder.precedes($0.id, $1.id) },
            cancellationCheck: cancellationCheck
        )
        let orderedPlaces = try RouteTimelineCancellableSort.sorted(
            places,
            by: { TaptionCanonicalUUIDOrder.precedes($0.id, $1.id) },
            cancellationCheck: cancellationCheck
        )
        let orderedTravel = try RouteTimelineCancellableSort.sorted(
            travel,
            by: { TaptionCanonicalUUIDOrder.precedes($0.id, $1.id) },
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        let fingerprint = try? TaptionPlanCanonicalStorage.encode(
            SourceFingerprintPayload(
                actuals: orderedActuals,
                places: orderedPlaces,
                travel: orderedTravel
            ),
            compress: false
        ).checksum
        try cancellationCheck()
        return fingerprint
    }

    private static func uniqueReadings(
        _ readings: [SensorReading]
    ) -> [SensorReading] {
        uniqueReadings(readings, cancellationCheck: {})
    }

    private static func uniqueReadings(
        _ readings: [SensorReading],
        cancellationCheck: () throws -> Void
    ) rethrows -> [SensorReading] {
        try cancellationCheck()
        var byID: [UUID: SensorReading] = [:]
        var isOrdered = true
        var previous: SensorReading?
        byID.reserveCapacity(readings.count)
        for (index, reading) in readings.enumerated() {
            if index.isMultiple(of: 256) { try cancellationCheck() }
            if let previous, readingPrecedes(reading, previous) { isOrdered = false }
            previous = reading
            byID[reading.id] = reading
        }
        try cancellationCheck()
        if isOrdered, byID.count == readings.count { return readings }
        return try RouteTimelineCancellableSort.sorted(
            Array(byID.values),
            by: readingPrecedes,
            cancellationCheck: cancellationCheck
        )
    }
    private static func readingPrecedes(_ lhs: SensorReading, _ rhs: SensorReading) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.sequence != rhs.sequence {
            return (lhs.sequence ?? .max) < (rhs.sequence ?? .max)
        }
        return TaptionCanonicalUUIDOrder.precedes(lhs.id, rhs.id)
    }

}
