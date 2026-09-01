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

    func testTrackingChunkArchiveContinuesIndexAfterReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracking-chunk-reopen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = TrackingSessionChunkArchive(rootDirectory: directory)
        try first.append(SensorReading(
            timestamp: start,
            motion: .walking,
            trackingSessionID: sessionID,
            sequence: 1,
            trackingSessionEnded: true
        ))
        let month = Calendar.autoupdatingCurrent.dateComponents(
            [.year, .month],
            from: start
        )
        let monthKey = String(
            format: "%04d-%02d",
            month.year ?? 1970,
            month.month ?? 1
        )
        let sessionDirectory = directory
            .appendingPathComponent(monthKey)
            .appendingPathComponent(sessionID.uuidString)
        let firstURL = sessionDirectory.appendingPathComponent("000001.jsonl.zlib")
        let firstPayload = try Data(contentsOf: firstURL)

        let reopened = TrackingSessionChunkArchive(rootDirectory: directory)
        try reopened.append(SensorReading(
            timestamp: start.addingTimeInterval(10),
            motion: .walking,
            trackingSessionID: sessionID,
            sequence: 2,
            trackingSessionEnded: true
        ))

        XCTAssertEqual(try Data(contentsOf: firstURL), firstPayload)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sessionDirectory
                .appendingPathComponent("000002.jsonl.zlib").path
        ))
        XCTAssertEqual(
            try reopened.allPersistedReadings().map(\.sequence),
            [1, 2]
        )
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

        try await archive.append([envelope, envelope])
        try await archive.append(envelope)
        try await archive.checkpoint()
        let restored = try await archive.envelopes(
            in: TimeSpan(
                start: date.addingTimeInterval(-1),
                end: date.addingTimeInterval(1)
            )
        )

        XCTAssertEqual(restored, [envelope])
        let payloadData = try XCTUnwrap(envelope.payloadJSON.data(using: .utf8))
        XCTAssertEqual(envelope.payloadByteCount, payloadData.count)
        XCTAssertEqual(
            envelope.payloadChecksum,
            TaptionPlanCanonicalStorage.checksum(payloadData)
        )
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
    func testPlanDayDatabaseInvalidatesMaterializationWhenRawDigestChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-stale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        _ = try await database.migrateLegacyIfNeeded(
            source: .empty,
            sourceRevision: 1,
            readings: [],
            watchSummaries: [],
            rawEnvelopes: []
        )
        let day = Date(timeIntervalSince1970: 2_000_000_000)
        let dayKey = TaptionPlanDayKey(date: day)
        let snapshot = PlanDayDataSnapshot(
            day: day,
            sourceRevision: 1,
            sourceUpdatedAt: day,
            actuals: [],
            places: [],
            travel: [],
            readings: [],
            isComplete: true
        )
        try await database.save(snapshot)
        let beforeChange = try await database.load(
            day: day,
            sourceRevision: 1
        )
        XCTAssertEqual(beforeChange, snapshot)

        let store = try TaptionPlanV3Store(
            url: directory.appendingPathComponent(
                "taption-plan-iphone-v3.sqlite"
            ),
            device: .iPhone
        )
        try await store.appendRawEvents([
            TaptionPlanRawEvent(
                device: .iPhone,
                day: dayKey,
                timestamp: day.addingTimeInterval(1),
                sequence: 1,
                id: UUID().uuidString,
                domain: "test-raw-change",
                provenance: ["test"],
                payload: Data([0x01])
            ),
        ])

        let afterChange = try await database.load(
            day: day,
            sourceRevision: 1
        )
        let staleRow = try await store.materializedDay(for: dayKey)
        XCTAssertNil(afterChange)
        XCTAssertNil(staleRow)
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
    func testWatchAccelerationChunkPreservesRawSamplesAcrossDuplicateDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-watch-raw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        let start = Date(timeIntervalSince1970: 2_200_000_000)
        let sessionID = UUID()
        let samples = (0..<4).map { index in
            TaptionWatchAccelerationSample(
                capturedAt: start.addingTimeInterval(Double(index) * 5),
                acceleration: TaptionWatchSensorVector3(
                    x: 0,
                    y: 0,
                    z: index.isMultiple(of: 2) ? 1.08 : 0.92
                ),
                sessionID: sessionID,
                sequence: index + 1,
                isAmbient: false
            )
        }
        let chunk = TaptionWatchAccelerationChunk(
            sessionID: sessionID,
            sequence: 1,
            startedAt: start,
            endedAt: samples.last!.capturedAt,
            samples: samples
        )

        try await database.recordWatchAccelerationChunk(chunk)
        try await database.recordWatchAccelerationChunk(chunk)

        let day = TaptionPlanDayKey(date: chunk.endedAt)
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
        XCTAssertEqual(watchDigest.eventCount, 1)
        XCTAssertEqual(iPhoneDigest.eventCount, 1)
        let restored = try await database.watchAccelerationSamples(
            in: TimeSpan(
                start: start.addingTimeInterval(-1),
                end: start.addingTimeInterval(21)
            )
        )
        XCTAssertEqual(restored.map(\.id), samples.map(\.id))
    }

    @MainActor
    func testPlanDayDatabaseReadsBackTheLatestProjectionAfterRegeneration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-projection-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        _ = try await database.migrateLegacyIfNeeded(
            source: .empty,
            sourceRevision: 1,
            readings: [],
            watchSummaries: [],
            rawEnvelopes: []
        )

        let day = Date(timeIntervalSince1970: 2_200_000_000)
        let actualID = UUID()
        func snapshot(title: String) -> PlanDayDataSnapshot {
            PlanDayDataSnapshot(
                day: day,
                sourceRevision: 1,
                sourceUpdatedAt: day,
                actuals: [
                    ActualRecord(
                        id: actualID,
                        planID: nil,
                        title: title,
                        categoryID: "activity",
                        startedAt: day.addingTimeInterval(60),
                        endedAt: day.addingTimeInterval(120),
                        source: .location,
                        confidence: .medium,
                        createdAt: day
                    ),
                ],
                places: [],
                travel: [],
                readings: [],
                isComplete: true
            )
        }

        try await database.save(snapshot(title: "근무"))
        try await database.save(snapshot(title: "집안일"))

        let restored = try await database.load(day: day, sourceRevision: 1)
        XCTAssertEqual(restored?.actuals.first?.title, "집안일")
        XCTAssertEqual(restored, snapshot(title: "집안일"))
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

    @MainActor
    func testPlanDayLoadCoordinatorPreloadsEveryDayInMonth() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-preload-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        let coordinator = PlanDayLoadCoordinator(
            database: database,
            cacheCapacity: 42
        )
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let calendar = Calendar.autoupdatingCurrent
        let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: date)
        )!
        let expected = calendar.range(
            of: .day,
            in: .month,
            for: monthStart
        )!.count
        var progressValues: [Double] = []

        await coordinator.preloadMonth(
            containing: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: { _ in
                SensorReadingsLoadResult(readings: [], isComplete: true)
            },
            progress: { progressValues.append($0) }
        )

        XCTAssertEqual(coordinator.cachedDayCount, expected)
        XCTAssertEqual(progressValues.count, expected + 1)
        XCTAssertEqual(progressValues.first, 0.0)
        XCTAssertEqual(progressValues.last, 1.0)
        XCTAssertEqual(progressValues, progressValues.sorted())
    }
}
