import XCTest
import TaptionPlanCore
@testable import TaptionPlan

final class SensorDayStoreTests: XCTestCase {
    private func makeReading(_ date: Date, id: UUID = UUID(), sequence: Int? = nil) -> SensorReading {
        SensorReading(
            id: id,
            timestamp: date,
            point: GeoPoint(
                latitude: 37.5,
                longitude: 126.8,
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: -1
            ),
            motion: .walking,
            sequence: sequence
        )
    }

    func testBatchAppendOrdersOutOfOrderAndReopensFromSQLite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-day-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("sensor-readings-v1.jsonl")
        let first = Date(timeIntervalSince1970: 1_000)
        let archive = try SensorReadingArchive(fileURL: fileURL)
        try await archive.append([
            makeReading(first.addingTimeInterval(60), sequence: 2),
            makeReading(first, sequence: 1)
        ])

        let span = TimeSpan(start: first.addingTimeInterval(-1), end: first.addingTimeInterval(61))
        let values = try await archive.readings(in: span)
        XCTAssertEqual(values.map(\.sequence), [1, 2])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("taption-plan-v2.sqlite").path))

        let reopened = try SensorReadingArchive(fileURL: fileURL)
        let reopenedValues = try await reopened.readings(in: span)
        XCTAssertEqual(reopenedValues.map(\.id), values.map(\.id))
    }

    func testLegacyJSONAndRawArchiveMigrateOnceWithIDDeduplication() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("sensor-readings-v1.jsonl")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let id = UUID()
        let reading = makeReading(date, id: id, sequence: 7)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var legacy = try encoder.encode(reading)
        legacy.append(0x0A)
        try legacy.write(to: fileURL)

        let raw = RawDeviceDataMonthlyArchive(rootDirectory: directory.appendingPathComponent("RawData"))
        try raw.append(source: .gps, kind: "sensor-reading", payload: reading, capturedAt: date)
        let archive = try SensorReadingArchive(fileURL: fileURL, rawArchive: raw)
        let span = TimeSpan(start: date.addingTimeInterval(-1), end: date.addingTimeInterval(1))
        let migrated = try await archive.readings(in: span)
        XCTAssertEqual(migrated.map(\.id), [id])

        let second = try SensorReadingArchive(fileURL: fileURL, rawArchive: raw)
        let reopened = try await second.routeReadings(in: span)
        XCTAssertEqual(reopened.map(\.id), [id])
    }

    func testNewSensorWriteDoesNotAppendLegacyCompression() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-uncompressed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("sensor-readings-v1.jsonl")
        let archive = try SensorReadingArchive(
            fileURL: fileURL,
            rawArchive: RawDeviceDataMonthlyArchive(rootDirectory: directory.appendingPathComponent("RawData")),
            trackingChunkArchive: TrackingSessionChunkArchive(rootDirectory: directory.appendingPathComponent("RawData"))
        )
        try await archive.append(makeReading(Date(timeIntervalSince1970: 1_800_000_000)))
        let files = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL } ?? []
        XCTAssertFalse(files.contains { $0.pathExtension == "zlib" })
        XCTAssertTrue(files.contains { $0.lastPathComponent == "taption-plan-v2.sqlite" })
    }

    func testRawDeviceEnvelopeUsesCanonicalDayDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-day-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("taption-data-v2.sqlite")
        let date = Date(timeIntervalSince1970: 1_850_000_000)
        let envelope = try RawDeviceDataEnvelope(
            capturedAt: date,
            source: .iPhonePedometer,
            kind: "pedometer-summary",
            payload: ["steps": 123]
        )
        let archive = try RawDeviceDataDayArchive(databaseURL: databaseURL)

        try await archive.append(envelope)
        try await archive.checkpoint()
        let restored = try await archive.envelopes(
            in: TimeSpan(
                start: date.addingTimeInterval(-1),
                end: date.addingTimeInterval(1)
            )
        )

        XCTAssertEqual(restored, [envelope])
        let store = try TaptionPlanDayStore(url: databaseURL)
        let events = try await store.events(
            from: TaptionPlanDayKey(date: date),
            through: TaptionPlanDayKey(date: date),
            domain: "raw-device-data"
        )
        XCTAssertEqual(
            String(decoding: events.first?.payload.prefix(8) ?? Data(), as: UTF8.self),
            "TP-CANON"
        )
        XCTAssertFalse(events.first?.payload.starts(with: [0x54, 0x50, 0x5A, 0x31]) == true)
    }

    func testMigrationRetrySkipsEventsWrittenBeforeMarker() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-migration-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("sensor-readings-v1.jsonl")
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let reading = makeReading(date, sequence: 11)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var legacy = try encoder.encode(reading)
        legacy.append(0x0A)
        try legacy.write(to: fileURL)

        let dayStore = try TaptionPlanDayStore(url: directory.appendingPathComponent("taption-plan-v2.sqlite"))
        try await dayStore.appendEvents([
            .init(
                day: TaptionPlanDayKey(date: date),
                timestamp: date,
                sequence: 11,
                id: reading.id.uuidString,
                domain: "sensor-reading",
                payload: TaptionPlanCanonicalStorage.envelope(
                    for: try TaptionPlanCanonicalStorage.encode(reading)
                )
            )
        ])
        let archive = try SensorReadingArchive(fileURL: fileURL)
        let values = try await archive.readings(in: TimeSpan(start: date.addingTimeInterval(-1), end: date.addingTimeInterval(1)))
        XCTAssertEqual(values.map(\.id), [reading.id])
    }

    func testSensorArchiveInitializationReportsInvalidDatabasePath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-invalid-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let databaseDirectory = directory.appendingPathComponent(
            "database-directory"
        )
        try FileManager.default.createDirectory(
            at: databaseDirectory,
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try SensorReadingArchive(
                fileURL: directory.appendingPathComponent("readings.jsonl"),
                dayStoreURL: databaseDirectory
            )
        )
    }

    @MainActor
    func testPlanDayDatabaseKeepsMaterializedRowsInactiveUntilMigrationCompletes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-database-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        let day = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = PlanDayDataSnapshot(
            day: day,
            sourceRevision: 7,
            sourceUpdatedAt: day,
            actuals: [],
            places: [],
            travel: [],
            readings: [],
            isComplete: true
        )

        try await database.save(snapshot)
        let beforeMigration = try await database.load(
            day: day,
            sourceRevision: 7
        )
        XCTAssertNil(beforeMigration)

        let report = try await database.migrateLegacyIfNeeded(
            source: .empty,
            sourceRevision: 7,
            readings: [],
            watchSummaries: [],
            rawEnvelopes: []
        )
        XCTAssertEqual(report?.dayCount, 0)
        let restored = try await database.load(day: day, sourceRevision: 7)
        XCTAssertEqual(restored, snapshot)
    }

    @MainActor
    func testWatchSummaryRecordAndLegacyMigrationShareIdempotentProvenance() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-watch-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        let startedAt = Date(timeIntervalSince1970: 2_200_000_000)
        let summary = TaptionWatchSensorSummary(
            sessionID: UUID(),
            sequence: 1,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(30),
            isFinal: true,
            accelerometerSampleCount: 0,
            accelerometerAverageG: nil,
            peakAccelerationG: nil,
            gyroscopeSampleCount: 0,
            gyroscopeAverageRadiansPerSecond: nil,
            peakRotationRateRadiansPerSecond: nil,
            gravity: nil,
            userAccelerationG: nil,
            rotationRateRadiansPerSecond: nil,
            attitudeRadians: nil,
            relativeAltitudeMeters: nil,
            pressureKilopascals: nil,
            stepCount: nil,
            distanceMeters: nil,
            floorsAscended: nil,
            floorsDescended: nil,
            latestHeartRate: nil,
            averageHeartRate: nil,
            maximumHeartRate: nil,
            activeEnergyKilocalories: nil
        )
        let day = TaptionPlanDayKey(date: summary.endedAt)

        try await database.recordWatchSummary(summary)
        try await database.recordWatchSummary(summary)

        let watchStore = try TaptionPlanV3Store(
            url: directory.appendingPathComponent("taption-plan-watch-v3.sqlite"),
            device: .appleWatch
        )
        let iPhoneStore = try TaptionPlanV3Store(
            url: directory.appendingPathComponent("taption-plan-iphone-v3.sqlite"),
            device: .iPhone
        )
        let watchDigest = try await watchStore.rawDigest(for: day)
        let iPhoneDigest = try await iPhoneStore.rawDigest(for: day)
        let watchEvents = try await watchStore.rawEvents(for: day)
        XCTAssertEqual(watchDigest.eventCount, 1)
        XCTAssertEqual(iPhoneDigest.eventCount, 1)
        XCTAssertEqual(
            watchEvents.first?.provenance,
            ["source-device:appleWatch", "transport:WatchConnectivity"]
        )

        let report = try await database.migrateLegacyIfNeeded(
            source: .empty,
            sourceRevision: 1,
            readings: [],
            watchSummaries: [summary],
            rawEnvelopes: []
        )
        XCTAssertEqual(report?.watchEventCount, 1)
        XCTAssertEqual(report?.iPhoneEventCount, 1)
        let migratedWatchDigest = try await watchStore.rawDigest(for: day)
        let migratedIPhoneDigest = try await iPhoneStore.rawDigest(for: day)
        XCTAssertEqual(migratedWatchDigest.eventCount, 1)
        XCTAssertEqual(migratedIPhoneDigest.eventCount, 1)
    }

    @MainActor
    func testPlanDayLoadCoordinatorUsesBoundedCacheAndEvictsOnPressure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-coordinator-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        let coordinator = PlanDayLoadCoordinator(database: database, cacheCapacity: 1)
        let first = Date(timeIntervalSince1970: 2_100_000_000)
        let second = first.addingTimeInterval(86_400)

        _ = await coordinator.load(
            day: first,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: { _ in
                SensorReadingsLoadResult(readings: [], isComplete: true)
            }
        )
        _ = await coordinator.load(
            day: second,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: { _ in
                SensorReadingsLoadResult(readings: [], isComplete: true)
            }
        )
        XCTAssertEqual(coordinator.cachedDayCount, 1)

        coordinator.handleMemoryPressure()
        XCTAssertEqual(coordinator.cachedDayCount, 0)
    }
}
