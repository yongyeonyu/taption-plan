import XCTest
import CoreLocation
import TaptionPlanCore
@testable import TaptionPlan

private final class SensorStreamProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation:
        AsyncStream<SensorReading>.Continuation?

    func makeStream() -> AsyncStream<SensorReading> {
        AsyncStream { [weak self] continuation in
            self?.lock.lock()
            self?.continuation = continuation
            self?.lock.unlock()
        }
    }

    func yield(_ reading: SensorReading) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.yield(reading)
    }
}

private final class SensorAppendProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _attempts = 0

    var attempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return _attempts
    }

    func recordAttempt() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _attempts += 1
        return _attempts
    }
}

private enum SensorAppendError: Error {
    case transient
}

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

    @MainActor
    func testLegacyWatchArchiveKeepsExistingPayloadForRepeatedIdentity()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-archive-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = AppleWatchSensorActivityArchive(
            fileURL: directory.appendingPathComponent("summaries.json")
        )
        let start = Date(timeIntervalSince1970: 2_200_000_000)
        let summary = TaptionWatchSensorSummary(
            sessionID: UUID(),
            sequence: 1,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: start,
            endedAt: start.addingTimeInterval(30),
            isFinal: true,
            accelerometerSampleCount: 1,
            accelerometerAverageG: nil,
            peakAccelerationG: 1,
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
        try await archive.record(summary)
        try await archive.record(summary)
        var conflictingSummary = summary
        conflictingSummary.isFinal = false
        do {
            try await archive.record(conflictingSummary)
            XCTFail("Conflicting Watch summary replaced the stored payload")
        } catch {}
        let storedSummaries = try await archive.allSummaries()
        XCTAssertEqual(storedSummaries, [summary])

        let sample = TaptionWatchAccelerationSample(
            capturedAt: start,
            acceleration: TaptionWatchSensorVector3(x: 0, y: 0, z: 1),
            sequence: 1,
            isAmbient: true
        )
        let chunk = TaptionWatchAccelerationChunk(
            sessionID: summary.sessionID,
            sequence: 1,
            startedAt: start,
            endedAt: start,
            isAmbient: true,
            samples: [sample]
        )
        try await archive.record(chunk)
        try await archive.record(chunk)
        var conflictingChunk = chunk
        conflictingChunk.samples[0].acceleration.x = 1
        do {
            try await archive.record(conflictingChunk)
            XCTFail("Conflicting Watch chunk replaced the stored raw payload")
        } catch {}
        let storedChunks = try await archive.allAccelerationChunks()
        XCTAssertEqual(storedChunks, [chunk])
    }

    @MainActor
    func testCollectorOldStreamTerminationDoesNotStopReplacement() async {
        let collector = AppleSensorCollector()
        let oldStream = collector.readings(configuration: .standard)
        let oldTask = Task {
            var iterator = oldStream.makeAsyncIterator()
            return await iterator.next()
        }
        await Task.yield()

        let replacement = collector.readings(configuration: .standard)
        oldTask.cancel()
        _ = await oldTask.value
        for _ in 0..<3 { await Task.yield() }

        var iterator = replacement.makeAsyncIterator()
        collector.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: 37.5,
                    longitude: 126.8
                ),
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                course: -1,
                speed: -1,
                timestamp: .now
            )]
        )

        let replacementReading = await iterator.next()
        XCTAssertNotNil(replacementReading)
        collector.stop()
    }

    @MainActor
    func testSensorBatchFailureRetriesWithoutDroppingReadings() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try SensorReadingArchive(
            fileURL: directory.appendingPathComponent("readings.jsonl")
        )
        let stream = SensorStreamProbe()
        let appendProbe = SensorAppendProbe()
        let service = AppleSensorDataService(
            archive: archive,
            streamFactory: { _ in stream.makeStream() },
            appendReadings: { readings in
                if appendProbe.recordAttempt() == 1 {
                    throw SensorAppendError.transient
                }
                try await archive.append(readings)
            }
        )
        let reading = makeReading(Date(timeIntervalSince1970: 1_800_000_000))

        service.startCollection()
        stream.yield(reading)
        for _ in 0..<100 where appendProbe.attempts == 0 {
            await Task.yield()
        }
        await service.stopCollectionAndWait()

        XCTAssertEqual(appendProbe.attempts, 2)
        let restored = try await archive.allReadings()
        XCTAssertEqual(restored.map(\.id), [reading.id])
    }

    @MainActor
    func testStopCollectionAndWaitFlushesTrailingReading() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-trailing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try SensorReadingArchive(
            fileURL: directory.appendingPathComponent("readings.jsonl")
        )
        let stream = SensorStreamProbe()
        let service = AppleSensorDataService(
            archive: archive,
            streamFactory: { _ in stream.makeStream() }
        )
        let first = makeReading(Date(timeIntervalSince1970: 1_810_000_000))
        let trailing = makeReading(
            first.timestamp.addingTimeInterval(1),
            sequence: 2
        )

        service.startCollection()
        stream.yield(first)
        let firstPersisted = await service.waitForPersistedReading(
            after: 0,
            timeout: 1
        )
        XCTAssertTrue(firstPersisted)
        stream.yield(trailing)
        for _ in 0..<10 { await Task.yield() }
        await service.stopCollectionAndWait()

        let restored = try await archive.allReadings()
        XCTAssertEqual(restored.map(\.id), [first.id, trailing.id])
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

    func testDuplicateSensorWriteRejectsConflictAndDeleteAllClearsArchive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-unique-delete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("sensor-readings-v1.jsonl")
        let date = Date(timeIntervalSince1970: 1_850_000_000)
        let id = UUID()
        let archive = try SensorReadingArchive(fileURL: fileURL)

        try await archive.append(makeReading(date, id: id, sequence: 1))
        do {
            try await archive.append(
                makeReading(date.addingTimeInterval(10), id: id, sequence: 2)
            )
            XCTFail("Expected immutable sensor conflict")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .eventConflict(id: id.uuidString))
        }
        let span = TimeSpan(
            start: date.addingTimeInterval(-1),
            end: date.addingTimeInterval(11)
        )
        let original = try await archive.readings(in: span)
        XCTAssertEqual(original.map(\.sequence), [1])

        try await archive.deleteAll()
        let deleted = try await archive.allReadings()
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDeleteAllClearsLegacyRawTrackingAndDayArchives() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-complete-delete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawDirectory = directory.appendingPathComponent("RawData")
        let raw = RawDeviceDataMonthlyArchive(rootDirectory: rawDirectory)
        let tracking = TrackingSessionChunkArchive(rootDirectory: rawDirectory)
        let date = Date(timeIntervalSince1970: 1_850_100_000)
        let reading = makeReading(date)
        try raw.append(
            source: .gps,
            kind: "sensor-reading",
            payload: reading,
            capturedAt: date
        )
        try tracking.append(
            SensorReading(
                timestamp: date,
                motion: .walking,
                trackingSessionID: UUID(),
                sequence: 1,
                trackingSessionEnded: true
            )
        )
        let archive = try SensorReadingArchive(
            fileURL: directory.appendingPathComponent("sensor-readings-v1.jsonl"),
            rawArchive: raw,
            trackingChunkArchive: tracking
        )
        let dayArchive = try RawDeviceDataDayArchive(
            databaseURL: directory.appendingPathComponent("raw-day.sqlite")
        )
        let envelope = try RawDeviceDataEnvelope(
            capturedAt: date,
            source: .gps,
            kind: "location",
            payload: ["latitude": 37.5]
        )
        try await dayArchive.append(envelope)

        try await archive.deleteAll()
        try await dayArchive.deleteAll()

        let dayEnvelopes = try await dayArchive.allEnvelopes()
        XCTAssertFalse(FileManager.default.fileExists(atPath: rawDirectory.path))
        XCTAssertTrue(try raw.allEnvelopes().isEmpty)
        XCTAssertTrue(try tracking.allPersistedReadings().isEmpty)
        XCTAssertTrue(dayEnvelopes.isEmpty)
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
        let conflicting = try RawDeviceDataEnvelope(
            id: envelope.id,
            capturedAt: date.addingTimeInterval(1),
            source: .iPhonePedometer,
            kind: "pedometer-summary",
            payload: ["steps": 999]
        )
        do {
            try await archive.append(conflicting)
            XCTFail("Expected immutable raw envelope conflict")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .eventConflict(id: envelope.id.uuidString))
        }
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

    func testRawDeviceEnvelopeRepairsInlineLegacyJSONEvent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-day-inline-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let databaseURL = directory.appendingPathComponent("raw-day.sqlite")
        let date = Date(timeIntervalSince1970: 1_850_000_000)
        var envelope = try RawDeviceDataEnvelope(
            capturedAt: date,
            source: .gps,
            kind: "sensor-reading",
            payload: ["speed": 12]
        )
        envelope.payloadChecksum = nil
        envelope.payloadByteCount = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let store = try TaptionPlanDayStore(url: databaseURL)
        try await store.appendEvents([.init(
            day: TaptionPlanDayKey(date: date),
            timestamp: date,
            sequence: 0,
            id: envelope.id.uuidString,
            domain: "raw-device-data",
            payload: try encoder.encode(envelope)
        )])

        let archive = try RawDeviceDataDayArchive(databaseURL: databaseURL)
        let restoredAll = try await archive.allEnvelopes()
        XCTAssertEqual(restoredAll, [envelope])
        let events = try await store.allEvents(domain: "raw-device-data")
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(events.first).payload.prefix(8), as: UTF8.self),
            "TP-CANON"
        )
        let restoredRange = try await archive.envelopes(
            in: TimeSpan(
                start: date.addingTimeInterval(-1),
                end: date.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(restoredRange, [envelope])
    }

    func testCancelledRawReadReleasesLockAndPreservesEvents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-day-cancelled-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_850_000_000)
        let first = try RawDeviceDataEnvelope(
            capturedAt: date,
            source: .gps,
            kind: "weather-context",
            payload: ["temperature": 21]
        )
        let archive = try RawDeviceDataDayArchive(
            databaseURL: directory.appendingPathComponent("raw-day.sqlite")
        )
        try await archive.append(first)

        let read = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await archive.allEnvelopes()
        }
        do {
            _ = try await read.value
            XCTFail("Cancelled raw read unexpectedly completed")
        } catch is CancellationError {}

        let second = try RawDeviceDataEnvelope(
            capturedAt: date.addingTimeInterval(1),
            source: .gps,
            kind: "weather-context",
            payload: ["temperature": 22]
        )
        try await archive.append(second)
        let restored = try await archive.allEnvelopes()
        XCTAssertEqual(
            restored.map(\.id),
            [first.id, second.id]
        )
    }

    func testRawDeviceEnvelopeBatchRejectsDivergentDuplicate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-day-conflict-batch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_850_000_000)
        let id = UUID()
        let first = try RawDeviceDataEnvelope(
            id: id,
            capturedAt: date,
            source: .iPhonePedometer,
            kind: "pedometer-summary",
            payload: ["steps": 123]
        )
        let conflicting = try RawDeviceDataEnvelope(
            id: id,
            capturedAt: date.addingTimeInterval(1),
            source: .iPhonePedometer,
            kind: "pedometer-summary",
            payload: ["steps": 999]
        )
        let archive = try RawDeviceDataDayArchive(
            databaseURL: directory.appendingPathComponent("raw-day.sqlite")
        )

        do {
            try await archive.append([first, conflicting])
            XCTFail("Expected immutable raw envelope conflict")
        } catch let error as TaptionPlanDayStoreError {
            XCTAssertEqual(error, .eventConflict(id: id.uuidString))
        }
        let persisted = try await archive.allEnvelopes()
        XCTAssertTrue(persisted.isEmpty)
    }

    func testRawDeviceEnvelopeRejectsTamperedInnerPayload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-day-checksum-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("raw-day.sqlite")
        let date = Date(timeIntervalSince1970: 1_850_000_000)
        var envelope = try RawDeviceDataEnvelope(
            capturedAt: date,
            source: .iPhonePedometer,
            kind: "pedometer-summary",
            payload: ["steps": 123]
        )
        envelope.payloadJSON = "{\"steps\":999}"
        let archive = try RawDeviceDataDayArchive(databaseURL: databaseURL)

        do {
            try await archive.append(envelope)
            XCTFail("tampered raw payload was accepted")
        } catch {
            XCTAssertFalse(envelope.hasValidPayload)
        }
    }

    func testRawDeviceEnvelopeUsesStableContentIdentity() throws {
        let date = Date(timeIntervalSince1970: 1_850_000_000)
        let first = try RawDeviceDataEnvelope(
            capturedAt: date,
            source: .iPhonePedometer,
            kind: "pedometer-summary",
            payload: ["steps": 123]
        )
        let duplicate = try RawDeviceDataEnvelope(
            capturedAt: date,
            source: .iPhonePedometer,
            kind: "pedometer-summary",
            payload: ["steps": 123]
        )
        let changed = try RawDeviceDataEnvelope(
            capturedAt: date,
            source: .iPhonePedometer,
            kind: "pedometer-summary",
            payload: ["steps": 124]
        )

        XCTAssertEqual(first.id, duplicate.id)
        XCTAssertNotEqual(first.id, changed.id)
    }

    func testSensorMigrationRejectsDivergentLegacyAndRawDuplicate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-migration-conflict-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("sensor-readings-v1.jsonl")
        let date = Date(timeIntervalSince1970: 1_850_000_000)
        let id = UUID()
        let legacyReading = makeReading(date, id: id, sequence: 1)
        let rawReading = makeReading(date.addingTimeInterval(1), id: id, sequence: 2)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var legacy = try encoder.encode(legacyReading)
        legacy.append(0x0A)
        try legacy.write(to: fileURL)

        let raw = RawDeviceDataMonthlyArchive(
            rootDirectory: directory.appendingPathComponent("RawData")
        )
        try raw.append(
            source: .gps,
            kind: "sensor-reading",
            payload: rawReading,
            capturedAt: rawReading.timestamp
        )
        let archive = try SensorReadingArchive(fileURL: fileURL, rawArchive: raw)

        do {
            _ = try await archive.readings(
                in: TimeSpan(
                    start: date.addingTimeInterval(-1),
                    end: date.addingTimeInterval(2)
                )
            )
            XCTFail("Expected immutable sensor conflict")
        } catch {
            XCTAssertEqual(String(describing: error), "conflictingReading")
        }
    }

    func testDeleteAllBypassesConflictingLegacyMigration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-delete-conflict-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("sensor-readings-v1.jsonl")
        let rawDirectory = directory.appendingPathComponent("RawData")
        let date = Date(timeIntervalSince1970: 1_850_000_000)
        let id = UUID()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var legacy = try encoder.encode(makeReading(date, id: id, sequence: 1))
        legacy.append(0x0A)
        try legacy.write(to: fileURL)
        let raw = RawDeviceDataMonthlyArchive(rootDirectory: rawDirectory)
        try raw.append(
            source: .gps,
            kind: "sensor-reading",
            payload: makeReading(
                date.addingTimeInterval(1),
                id: id,
                sequence: 2
            ),
            capturedAt: date.addingTimeInterval(1)
        )
        let archive = try SensorReadingArchive(
            fileURL: fileURL,
            rawArchive: raw
        )

        try await archive.deleteAll()

        let remaining = try await archive.allReadings()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rawDirectory.path))
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

    func testAllReadingsPreservesUnreadableDayStoreEvent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-invalid-day-event-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_950_000_000)
        let databaseURL = directory.appendingPathComponent("taption-plan-v2.sqlite")
        let archive = try SensorReadingArchive(
            fileURL: directory.appendingPathComponent("sensor-readings-v1.jsonl"),
            dayStoreURL: databaseURL
        )
        let dayStore = try TaptionPlanDayStore(url: databaseURL)
        let reading = makeReading(date, sequence: 1)
        try await dayStore.appendEvents([
            .init(
                day: TaptionPlanDayKey(date: date),
                timestamp: date,
                sequence: 1,
                id: reading.id.uuidString,
                domain: "sensor-reading",
                payload: TaptionPlanCanonicalStorage.envelope(
                    for: try TaptionPlanCanonicalStorage.encode(reading)
                )
            ),
            .init(
                day: TaptionPlanDayKey(date: date),
                timestamp: date.addingTimeInterval(1),
                sequence: 2,
                id: UUID().uuidString,
                domain: "sensor-reading",
                payload: Data([0x00])
            ),
        ])

        let values = try await archive.allReadings()
        XCTAssertEqual(values.map(\.id), [reading.id])
        let ranged = try await archive.routeReadingsLoadResult(
            in: TimeSpan(
                start: date.addingTimeInterval(-1),
                end: date.addingTimeInterval(2)
            )
        )
        XCTAssertEqual(ranged.readings.map(\.id), [reading.id])
        XCTAssertFalse(ranged.isComplete)
        let storedEvents = try await dayStore.allEvents(domain: "sensor-reading")
        XCTAssertEqual(storedEvents.count, 2)
    }

    func testCorruptDayEventsScanLegacyRecoveryOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-recovery-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent(
            "sensor-readings-v1.jsonl"
        )
        let date = Date(timeIntervalSince1970: 1_950_000_000)
        let readings = (0..<4_000).map {
            makeReading(date.addingTimeInterval(Double($0)), sequence: $0)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var legacy = Data()
        for reading in readings {
            legacy.append(try encoder.encode(reading))
            legacy.append(0x0A)
        }
        try legacy.write(to: fileURL)

        let databaseURL = directory.appendingPathComponent(
            "taption-plan-v2.sqlite"
        )
        let dayStore = try TaptionPlanDayStore(url: databaseURL)
        try await dayStore.appendEvents(readings.prefix(100).map {
            .init(
                day: TaptionPlanDayKey(date: $0.timestamp),
                timestamp: $0.timestamp,
                sequence: UInt64($0.sequence ?? 0),
                id: $0.id.uuidString,
                domain: "sensor-reading",
                payload: Data([0x00])
            )
        })
        _ = try await dayStore.markMigrationCompleted(
            "sensor-reading-v1-to-day-store-v2"
        )
        let archive = try SensorReadingArchive(
            fileURL: fileURL,
            dayStoreURL: databaseURL
        )
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = try await archive.routeReadingsLoadResult(
            in: TimeSpan(
                start: date.addingTimeInterval(-1),
                end: date.addingTimeInterval(101)
            )
        )
        let duration = ProcessInfo.processInfo.systemUptime - startedAt
        print("SENSOR_LEGACY_RECOVERY_100_MS=\(duration * 1_000)")

        XCTAssertEqual(result.readings.map(\.id), readings.prefix(100).map(\.id))
        XCTAssertTrue(result.isComplete)
        XCTAssertLessThan(duration, 2)

        try FileManager.default.removeItem(at: fileURL)
        let reopened = try SensorReadingArchive(
            fileURL: fileURL,
            dayStoreURL: databaseURL
        )
        let repaired = try await reopened.routeReadingsLoadResult(
            in: TimeSpan(
                start: date.addingTimeInterval(-1),
                end: date.addingTimeInterval(101)
            )
        )
        XCTAssertEqual(repaired.readings.map(\.id), readings.prefix(100).map(\.id))
        XCTAssertTrue(repaired.isComplete)
    }

    func testInlineLegacySensorEventsRepairWithoutArchiveScan() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-inline-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let date = Date(timeIntervalSince1970: 1_950_000_000)
        let readings = (0..<2_346).map {
            makeReading(date.addingTimeInterval(Double($0)), sequence: $0)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let databaseURL = directory.appendingPathComponent(
            "taption-plan-v2.sqlite"
        )
        let store = try TaptionPlanDayStore(url: databaseURL)
        try await store.appendEvents(try readings.map { reading in
            .init(
                day: TaptionPlanDayKey(date: reading.timestamp),
                timestamp: reading.timestamp,
                sequence: UInt64(reading.sequence ?? 0),
                id: reading.id.uuidString,
                domain: "sensor-reading",
                payload: try encoder.encode(reading)
            )
        })
        _ = try await store.markMigrationCompleted(
            "sensor-reading-v1-to-day-store-v2"
        )
        let archive = try SensorReadingArchive(
            fileURL: directory.appendingPathComponent("missing.jsonl"),
            dayStoreURL: databaseURL
        )

        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = try await archive.routeReadingsLoadResult(
            in: TimeSpan(
                start: date.addingTimeInterval(-1),
                end: date.addingTimeInterval(2_347)
            )
        )
        let duration = ProcessInfo.processInfo.systemUptime - startedAt
        print("SENSOR_INLINE_LEGACY_2346_MS=\(duration * 1_000)")

        XCTAssertEqual(result.readings.count, readings.count)
        XCTAssertTrue(result.isComplete)
        XCTAssertLessThan(duration, 2)
        let events = try await store.allEvents(domain: "sensor-reading")
        XCTAssertTrue(events.allSatisfy {
            String(decoding: $0.payload.prefix(8), as: UTF8.self) == "TP-CANON"
        })
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
        let requiredBeforeImport = try await database.requiresLegacyMigration()
        XCTAssertTrue(requiredBeforeImport)
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
        let requiredAfterImport = try await database.requiresLegacyMigration()
        XCTAssertFalse(requiredAfterImport)
        let restored = try await database.load(day: day, sourceRevision: 7)
        XCTAssertEqual(restored, snapshot)
    }

    @MainActor
    func testLegacyMigrationReplacesAnIncompleteConflictingImport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-migration-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let envelope = try RawDeviceDataEnvelope(
            capturedAt: date,
            source: .iPhoneMotion,
            kind: "motion-activities",
            payload: ["state": "walking"]
        )
        let store = try TaptionPlanV3Store(
            url: directory.appendingPathComponent(
                "taption-plan-iphone-v3.sqlite"
            ),
            device: .iPhone
        )
        try await store.appendRawEvents([
            TaptionPlanRawEvent(
                device: .iPhone,
                day: TaptionPlanDayKey(date: date),
                timestamp: date,
                sequence: 0,
                id: envelope.id.uuidString,
                domain: "raw-device-data",
                provenance: ["incomplete-import"],
                payload: Data([0])
            ),
        ])
        let database = try PlanDayDatabase(directory: directory)

        let report = try await database.migrateLegacyIfNeeded(
            source: .empty,
            sourceRevision: 1,
            readings: [],
            watchSummaries: [],
            rawEnvelopes: [envelope]
        )

        XCTAssertEqual(report?.dayCount, 1)
        XCTAssertEqual(report?.iPhoneEventCount, 1)
        let stillRequiresMigration = try await database.requiresLegacyMigration()
        XCTAssertFalse(stillRequiresMigration)
    }

    @MainActor
    func testLegacyMigrationAcceptsSQLiteTimestampRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-date-round-trip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSinceReferenceDate: 809_404_315.441_151_02)
        let storedDate = Date(
            timeIntervalSince1970: date.timeIntervalSince1970
        )
        XCTAssertNotEqual(date, storedDate)
        let database = try PlanDayDatabase(directory: directory)

        let report = try await database.migrateLegacyIfNeeded(
            source: .empty,
            sourceRevision: 1,
            readings: [makeReading(date)],
            watchSummaries: [],
            rawEnvelopes: []
        )

        XCTAssertEqual(report?.dayCount, 1)
        XCTAssertEqual(report?.iPhoneEventCount, 1)
        let stillRequiresMigration = try await database.requiresLegacyMigration()
        XCTAssertFalse(stillRequiresMigration)
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
    func testPlanDayDatabaseRemovesCorruptMaterializedPayloadForRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "plan-day-corrupt-materialized-\(UUID().uuidString)"
            )
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

        let store = try TaptionPlanV3Store(
            url: directory.appendingPathComponent(
                "taption-plan-iphone-v3.sqlite"
            ),
            device: .iPhone
        )
        let currentRow = try await store.materializedDay(for: dayKey)
        let current = try XCTUnwrap(currentRow)
        try await store.replaceMaterializedDay(
            .init(
                device: .iPhone,
                day: dayKey,
                sourceRevision: current.sourceRevision,
                projectionVersion: current.projectionVersion,
                rawDigest: current.rawDigest,
                rawEventCount: current.rawEventCount,
                firstTimestamp: current.firstTimestamp,
                lastTimestamp: current.lastTimestamp,
                payload: Data([0])
            )
        )

        let recovered = try await database.load(day: day, sourceRevision: 1)
        let removed = try await store.materializedDay(for: dayKey)
        XCTAssertNil(recovered)
        XCTAssertNil(removed)
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
        let watchStore = try TaptionPlanV3Store(
            url: directory.appendingPathComponent("taption-plan-watch-v3.sqlite"),
            device: .appleWatch
        )
        let iPhoneStore = try TaptionPlanV3Store(
            url: directory.appendingPathComponent("taption-plan-iphone-v3.sqlite"),
            device: .iPhone
        )
        try await database.save(PlanDayDataSnapshot(
            day: summary.endedAt,
            sourceRevision: 1,
            sourceUpdatedAt: summary.endedAt,
            actuals: [],
            places: [],
            travel: [],
            readings: [],
            isComplete: true
        ))
        try await database.recordWatchSummary(summary)
        let cachedAfterDuplicate = try await iPhoneStore.materializedDay(for: day)
        XCTAssertNotNil(cachedAfterDuplicate)

        let watchDigest = try await watchStore.rawDigest(for: day)
        let iPhoneDigest = try await iPhoneStore.rawDigest(for: day)
        let watchEvents = try await watchStore.rawEvents(for: day)
        let iPhoneEvents = try await iPhoneStore.rawEvents(for: day)
        XCTAssertEqual(watchDigest.eventCount, 1)
        XCTAssertEqual(iPhoneDigest.eventCount, 1)
        XCTAssertEqual(
            watchEvents.first?.provenance,
            ["source-device:appleWatch", "transport:WatchConnectivity"]
        )
        XCTAssertEqual(
            iPhoneEvents.first?.provenance,
            [
                "source-device:appleWatch",
                "transport:WatchConnectivity",
                "merge:iPhone",
            ]
        )
        XCTAssertFalse(
            watchEvents.first?.provenance.contains("merge:iPhone") ?? true
        )

        try await iPhoneStore.deleteAllData()
        let restoredFromWatchRaw = try await database.watchSummaries(
            in: TimeSpan(
                start: summary.startedAt,
                end: summary.endedAt.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(restoredFromWatchRaw, [summary])

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
    func testLegacyMigrationPreservesWatchAccelerationChunks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-watch-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        let start = Date(timeIntervalSince1970: 2_150_000_000)
        let sessionID = UUID()
        let samples = (0..<3).map { index in
            TaptionWatchAccelerationSample(
                capturedAt: start.addingTimeInterval(Double(index)),
                acceleration: TaptionWatchSensorVector3(x: 0, y: 0, z: 1),
                sessionID: sessionID,
                sequence: index + 1,
                isAmbient: true
            )
        }
        let chunk = TaptionWatchAccelerationChunk(
            sessionID: sessionID,
            sequence: 1,
            startedAt: start,
            endedAt: samples.last!.capturedAt,
            samples: samples
        )

        let report = try await database.migrateLegacyIfNeeded(
            source: .empty,
            sourceRevision: 1,
            readings: [],
            watchSummaries: [],
            watchAccelerationChunks: [chunk],
            rawEnvelopes: []
        )

        XCTAssertEqual(report?.watchEventCount, 1)
        XCTAssertEqual(report?.iPhoneEventCount, 1)
        let restored = try await database.watchAccelerationSamples(
            in: TimeSpan(
                start: start.addingTimeInterval(-1),
                end: start.addingTimeInterval(4)
            )
        )
        XCTAssertEqual(restored.map(\.id), samples.map(\.id))
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

        let day = TaptionPlanDayKey(date: chunk.endedAt)
        let watchStore = try TaptionPlanV3Store(
            url: directory.appendingPathComponent("taption-plan-watch-v3.sqlite"),
            device: .appleWatch
        )
        let iPhoneStore = try TaptionPlanV3Store(
            url: directory.appendingPathComponent("taption-plan-iphone-v3.sqlite"),
            device: .iPhone
        )
        try await database.recordWatchAccelerationChunk(chunk)
        try await database.save(PlanDayDataSnapshot(
            day: chunk.endedAt,
            sourceRevision: 1,
            sourceUpdatedAt: chunk.endedAt,
            actuals: [],
            places: [],
            travel: [],
            readings: [],
            isComplete: true
        ))
        try await database.recordWatchAccelerationChunk(chunk)
        let cachedAfterDuplicate = try await iPhoneStore.materializedDay(for: day)
        XCTAssertNotNil(cachedAfterDuplicate)

        let watchDigest = try await watchStore.rawDigest(for: day)
        let iPhoneDigest = try await iPhoneStore.rawDigest(for: day)
        XCTAssertEqual(watchDigest.eventCount, 1)
        XCTAssertEqual(iPhoneDigest.eventCount, 1)
        try await iPhoneStore.deleteAllData()
        let restored = try await database.watchAccelerationSamples(
            in: TimeSpan(
                start: start.addingTimeInterval(-1),
                end: start.addingTimeInterval(21)
            )
        )
        XCTAssertEqual(restored.map(\.id), samples.map(\.id))
    }

    @MainActor
    func testWatchAccelerationRestoreRollbackKeepsPreexistingChunk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-watch-rollback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        let start = Date(timeIntervalSince1970: 2_200_100_000)
        func chunk(sequence: Int) -> TaptionWatchAccelerationChunk {
            let capturedAt = start.addingTimeInterval(Double(sequence))
            return TaptionWatchAccelerationChunk(
                sessionID: nil,
                sequence: sequence,
                startedAt: capturedAt,
                endedAt: capturedAt,
                samples: [TaptionWatchAccelerationSample(
                    capturedAt: capturedAt,
                    acceleration: TaptionWatchSensorVector3(x: 0, y: 0, z: 1),
                    sequence: sequence,
                    isAmbient: true
                )]
            )
        }
        let existing = chunk(sequence: 1)
        let added = chunk(sequence: 2)
        try await database.recordWatchAccelerationChunk(existing)

        let receipt = try await database
            .recordWatchAccelerationChunksForRestore([existing, added])
        try await database.rollbackWatchAccelerationRestore(receipt)

        let restored = try await database.watchAccelerationChunks(
            in: TimeSpan(
                start: start.addingTimeInterval(-1),
                end: start.addingTimeInterval(3)
            )
        )
        XCTAssertEqual(restored, [existing])
        let day = TaptionPlanDayKey(date: start)
        let watchStore = try TaptionPlanV3Store(
            url: directory.appendingPathComponent("taption-plan-watch-v3.sqlite"),
            device: .appleWatch
        )
        let iPhoneStore = try TaptionPlanV3Store(
            url: directory.appendingPathComponent("taption-plan-iphone-v3.sqlite"),
            device: .iPhone
        )
        let watchIDs = try await watchStore.rawEvents(
            for: day,
            domain: "watch-acceleration"
        ).map(\.id)
        let iPhoneIDs = try await iPhoneStore.rawEvents(
            for: day,
            domain: "watch-acceleration"
        ).map(\.id)
        XCTAssertEqual(watchIDs, [existing.id.uuidString])
        XCTAssertEqual(iPhoneIDs, [existing.id.uuidString])
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
        let reading = makeReading(
            day.addingTimeInterval(90),
            sequence: 1
        )
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
                readings: [reading],
                isComplete: true
            )
        }

        try await database.save(snapshot(title: "근무"))
        try await database.save(snapshot(title: "집안일"))

        let restored = try await database.load(day: day, sourceRevision: 1)
        XCTAssertEqual(restored?.actuals.first?.title, "집안일")
        XCTAssertEqual(restored, snapshot(title: "집안일"))

        let store = try TaptionPlanV3Store(
            url: directory.appendingPathComponent(
                "taption-plan-iphone-v3.sqlite"
            ),
            device: .iPhone
        )
        let dayKey = TaptionPlanDayKey(date: day)
        let actualEvents = try await store.rawEvents(for: dayKey, domain: "plan-actual")
        let sensorEvents = try await store.rawEvents(for: dayKey, domain: "sensor-reading")
        XCTAssertEqual(actualEvents.count, 1)
        XCTAssertEqual(sensorEvents.count, 1)
        #if !targetEnvironment(simulator)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(
                    "taption-plan-iphone-v3.sqlite"
                ).path
            )[.protectionKey] as? FileProtectionType,
            .completeUntilFirstUserAuthentication
        )
        #endif
    }

    @MainActor
    func testPlanDayDatabaseReusesLegacyPayloadWithoutSourceFingerprint() async throws {
        struct LegacyPayload: Encodable {
            let day: Date
            let sourceUpdatedAt: Date
            let actuals: [ActualRecord]
            let places: [PlaceStay]
            let travel: [TravelSegment]
            let readings: [SensorReading]
            let isComplete: Bool
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-legacy-payload-\(UUID().uuidString)")
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

        let store = try TaptionPlanV3Store(
            url: directory.appendingPathComponent(
                "taption-plan-iphone-v3.sqlite"
            ),
            device: .iPhone
        )
        let dayKey = TaptionPlanDayKey(date: day)
        let materialized = try await store.materializedDay(for: dayKey)
        let current = try XCTUnwrap(materialized)
        let legacy = try TaptionPlanCanonicalStorage.encode(LegacyPayload(
            day: snapshot.day,
            sourceUpdatedAt: snapshot.sourceUpdatedAt,
            actuals: snapshot.actuals,
            places: snapshot.places,
            travel: snapshot.travel,
            readings: snapshot.readings,
            isComplete: snapshot.isComplete
        ))
        try await store.replaceMaterializedDay(.init(
            device: current.device,
            day: current.day,
            sourceRevision: current.sourceRevision,
            projectionVersion: current.projectionVersion,
            rawDigest: current.rawDigest,
            rawEventCount: current.rawEventCount,
            firstTimestamp: current.firstTimestamp,
            lastTimestamp: current.lastTimestamp,
            payload: TaptionPlanCanonicalStorage.envelope(for: legacy)
        ))

        let restored = try await database.load(
            day: day,
            sourceRevision: 99,
            sourceFingerprint: snapshot.sourceFingerprint
        )

        XCTAssertEqual(restored?.sourceFingerprint, snapshot.sourceFingerprint)
        XCTAssertEqual(restored?.sourceRevision, 99)
    }

    @MainActor
    func testPlanDayLoadCoordinatorCachedSnapshotDoesNotWriteOrSeedNormalLoad() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-cached-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        _ = try await database.migrateLegacyIfNeeded(
            source: .empty,
            sourceRevision: 1,
            readings: [],
            watchSummaries: [],
            rawEnvelopes: []
        )
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let stored = PlanDayDataSnapshot(
            day: date,
            sourceRevision: 1,
            sourceUpdatedAt: date,
            actuals: [],
            places: [],
            travel: [],
            readings: [makeReading(date)],
            isComplete: true
        )
        try await database.save(stored)
        let store = try TaptionPlanV3Store(
            url: directory.appendingPathComponent(
                "taption-plan-iphone-v3.sqlite"
            ),
            device: .iPhone
        )
        let dayKey = TaptionPlanDayKey(date: date)
        let beforeRow = try await store.materializedDay(for: dayKey)
        let before = try XCTUnwrap(beforeRow)
        let coordinator = PlanDayLoadCoordinator(database: database)

        let preview = await coordinator.cachedSnapshot(
            day: date,
            source: .empty,
            sourceRevision: 99
        )

        XCTAssertEqual(preview?.sourceRevision, 1)
        XCTAssertEqual(coordinator.cachedDayCount, 0)
        let afterPreviewRow = try await store.materializedDay(for: dayKey)
        let afterPreview = try XCTUnwrap(afterPreviewRow)
        XCTAssertEqual(afterPreview, before)

        var sensorLoadCount = 0
        let refreshed = await coordinator.load(
            day: date,
            source: .empty,
            sourceRevision: 99,
            sensorLoader: { _ in
                sensorLoadCount += 1
                return SensorReadingsLoadResult(
                    readings: [],
                    isComplete: true
                )
            }
        )
        XCTAssertEqual(sensorLoadCount, 0)
        XCTAssertEqual(refreshed.sourceRevision, 99)
    }

    @MainActor
    func testPlanDayLoadCoordinatorCachedSnapshotAllowsStaleRawOnlyForPreview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-cached-stale-raw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        _ = try await database.migrateLegacyIfNeeded(
            source: .empty,
            sourceRevision: 1,
            readings: [],
            watchSummaries: [],
            rawEnvelopes: []
        )
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let stored = PlanDayDataSnapshot(
            day: date,
            sourceRevision: 1,
            sourceUpdatedAt: date,
            actuals: [],
            places: [],
            travel: [],
            readings: [makeReading(date)],
            isComplete: true
        )
        try await database.save(stored)
        let store = try TaptionPlanV3Store(
            url: directory.appendingPathComponent(
                "taption-plan-iphone-v3.sqlite"
            ),
            device: .iPhone
        )
        let dayKey = TaptionPlanDayKey(date: date)
        try await store.appendRawEvents([
            TaptionPlanRawEvent(
                device: .iPhone,
                day: dayKey,
                timestamp: date.addingTimeInterval(1),
                sequence: 2,
                id: UUID().uuidString,
                domain: "cached-preview-test",
                provenance: ["test"],
                payload: Data([0x01])
            ),
        ])
        let rowBeforePreviewValue = try await store.materializedDay(for: dayKey)
        let rowBeforePreview = try XCTUnwrap(rowBeforePreviewValue)
        let coordinator = PlanDayLoadCoordinator(database: database)

        let preview = await coordinator.cachedSnapshot(
            day: date,
            source: .empty,
            sourceRevision: 1
        )
        XCTAssertEqual(preview?.readings, stored.readings)
        let afterPreviewRow = try await store.materializedDay(for: dayKey)
        let afterPreview = try XCTUnwrap(afterPreviewRow)
        XCTAssertEqual(afterPreview, rowBeforePreview)

        var sensorLoadCount = 0
        let refreshed = await coordinator.load(
            day: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: { _ in
                sensorLoadCount += 1
                return SensorReadingsLoadResult(
                    readings: [],
                    isComplete: true
                )
            }
        )
        XCTAssertEqual(sensorLoadCount, 1)
        XCTAssertTrue(refreshed.isComplete)
        XCTAssertTrue(refreshed.readings.isEmpty)
        let afterRefreshRow = try await store.materializedDay(for: dayKey)
        let afterRefresh = try XCTUnwrap(afterRefreshRow)
        XCTAssertNotEqual(afterRefresh.payload, rowBeforePreview.payload)
    }

    @MainActor
    func testPlanDayLoadCoordinatorForceReloadBypassesMaterializedCacheWhenPrimaryArchiveAdvances() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-primary-archive-advance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        _ = try await database.migrateLegacyIfNeeded(
            source: .empty,
            sourceRevision: 1,
            readings: [],
            watchSummaries: [],
            rawEnvelopes: []
        )
        let primaryArchive = try SensorReadingArchive(
            fileURL: directory.appendingPathComponent(
                "primary-sensor-readings.jsonl"
            ),
            dayStoreURL: directory.appendingPathComponent(
                "primary-sensor.sqlite"
            )
        )
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let span = TimeSpan(
            start: date.addingTimeInterval(-1),
            end: date.addingTimeInterval(61)
        )
        let first = makeReading(date, sequence: 1)
        let second = makeReading(
            date.addingTimeInterval(60),
            sequence: 2
        )
        try await primaryArchive.append(first)
        try await database.save(PlanDayDataSnapshot(
            day: date,
            sourceRevision: 1,
            sourceUpdatedAt: date,
            actuals: [],
            places: [],
            travel: [],
            readings: [first],
            isComplete: true
        ))

        // The primary archive advances independently; V3 has not received
        // the new reading, so its materialized digest still looks valid.
        try await primaryArchive.append(second)
        let primaryReadings = try await primaryArchive.routeReadings(in: span)
        XCTAssertEqual(primaryReadings, [first, second])

        let coordinator = PlanDayLoadCoordinator(database: database)
        var sensorLoadCount = 0
        let cached = await coordinator.load(
            day: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: { _ in
                sensorLoadCount += 1
                return SensorReadingsLoadResult(
                    readings: primaryReadings,
                    isComplete: true
                )
            }
        )
        XCTAssertEqual(cached.readings, [first])
        XCTAssertEqual(sensorLoadCount, 0)

        let refreshed = await coordinator.load(
            day: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: { _ in
                sensorLoadCount += 1
                return SensorReadingsLoadResult(
                    readings: primaryReadings,
                    isComplete: true
                )
            },
            forceReload: true
        )
        XCTAssertEqual(refreshed.readings, [first, second])
        XCTAssertEqual(sensorLoadCount, 1)
    }

    @MainActor
    func testPlanDayLoadCoordinatorKeepsInvalidatedPreviewUntilMemoryPressure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-cached-invalidation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let coordinator = PlanDayLoadCoordinator(database: database)
        let reading = makeReading(date)

        _ = await coordinator.load(
            day: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: { _ in
                SensorReadingsLoadResult(
                    readings: [reading],
                    isComplete: true
                )
            }
        )
        coordinator.invalidate(day: date)
        try await database.invalidate(day: date)

        let invalidatedPreview = await coordinator.cachedSnapshot(
            day: date,
            source: .empty,
            sourceRevision: 1
        )
        XCTAssertNotNil(invalidatedPreview)
        coordinator.handleMemoryPressure()
        let pressurePreview = await coordinator.cachedSnapshot(
            day: date,
            source: .empty,
            sourceRevision: 1
        )
        XCTAssertNil(pressurePreview)
    }

    @MainActor
    func testPlanDayLoadCoordinatorRejectsCachedSnapshotAcrossDeletionGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-cached-generation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let coordinator = PlanDayLoadCoordinator(database: database)

        _ = await coordinator.load(
            day: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: { _ in
                SensorReadingsLoadResult(readings: [], isComplete: true)
            }
        )
        let beforeGeneration = await coordinator.cachedSnapshot(
            day: date,
            source: .empty,
            sourceRevision: 1
        )
        XCTAssertNotNil(beforeGeneration)

        let generation = TaptionDataDeletionFence.advance()
        defer { TaptionDataDeletionFence.finish(generation: generation) }
        let afterGeneration = await coordinator.cachedSnapshot(
            day: date,
            source: .empty,
            sourceRevision: 1
        )
        XCTAssertNil(afterGeneration)
    }

    @MainActor
    func testPlanDayLoadCoordinatorKeepsInvalidationUntilCanceledLoadSucceeds() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-cached-cancelled-invalidation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        let coordinator = PlanDayLoadCoordinator(database: database)
        let date = Date(timeIntervalSince1970: 2_100_000_000)

        _ = await coordinator.load(
            day: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: { _ in
                SensorReadingsLoadResult(readings: [], isComplete: true)
            }
        )
        coordinator.invalidate(day: date)

        let started = expectation(description: "sensor reload started")
        let canceledLoad = Task { @MainActor in
            await coordinator.load(
                day: date,
                source: .empty,
                sourceRevision: 1,
                sensorLoader: { _ in
                    started.fulfill()
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch {}
                    return SensorReadingsLoadResult(
                        readings: [],
                        isComplete: true
                    )
                }
            )
        }
        await fulfillment(of: [started], timeout: 1)
        canceledLoad.cancel()
        _ = await canceledLoad.value

        var retryCount = 0
        _ = await coordinator.load(
            day: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: { _ in
                retryCount += 1
                return SensorReadingsLoadResult(
                    readings: [],
                    isComplete: true
                )
            }
        )
        XCTAssertEqual(retryCount, 1)
    }

    @MainActor
    func testPlanDayLoadCoordinatorCachedPreviewP95With65853HistoryRecords() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-cached-preview-benchmark-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        let coordinator = PlanDayLoadCoordinator(database: database)
        let date = Date(timeIntervalSince1970: 2_100_000_000)

        var sensorLoadCount = 0
        _ = await coordinator.load(
            day: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: { _ in
                sensorLoadCount += 1
                return SensorReadingsLoadResult(readings: [], isComplete: true)
            }
        )
        sensorLoadCount = 0

        var history = TaptionDataSnapshot.empty
        history.actuals = (0..<65_853).map { index in
            let startedAt = date.addingTimeInterval(Double(index))
            return ActualRecord(
                id: UUID(),
                planID: nil,
                title: "history-\(index)",
                categoryID: "benchmark",
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(1),
                source: .manual,
                confidence: .medium,
                createdAt: startedAt
            )
        }

        var elapsedMilliseconds: [Double] = []
        var returnedCount = 0
        for _ in 0..<30 {
            let started = DispatchTime.now().uptimeNanoseconds
            let preview = await coordinator.cachedSnapshot(
                day: date,
                source: history,
                sourceRevision: 99
            )
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            elapsedMilliseconds.append(Double(elapsed) / 1_000_000)
            if preview != nil { returnedCount += 1 }
        }

        let sorted = elapsedMilliseconds.sorted()
        let p95Index = max(
            0,
            min(
                sorted.count - 1,
                Int(ceil(Double(sorted.count) * 0.95)) - 1
            )
        )
        let p95 = sorted[p95Index]
        let distribution = elapsedMilliseconds
            .map { String(format: "%.3f", $0) }
            .joined(separator: ",")
        let formattedP95 = String(format: "%.3f", p95)
        print("PLAN_DAY_CACHED_PREVIEW_65853_DISTRIBUTION_MS=\(distribution)")
        print("PLAN_DAY_CACHED_PREVIEW_65853_P95_MS=\(formattedP95)")

        XCTAssertEqual(returnedCount, 30)
        XCTAssertEqual(sensorLoadCount, 0)
    }

    @MainActor
    func testPlanDayLoadCoordinatorUsesBoundedCacheAndEvictsOnPressure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-coordinator-\(UUID().uuidString)")
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
    func testPlanDayLoadCoordinatorReusesDayUntilInvalidated() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-reuse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        let coordinator = PlanDayLoadCoordinator(database: database)
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        var loadCount = 0
        let loader: (Date) async -> SensorReadingsLoadResult = { _ in
            loadCount += 1
            return SensorReadingsLoadResult(readings: [], isComplete: true)
        }

        _ = await coordinator.load(
            day: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: loader
        )
        _ = await coordinator.load(
            day: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: loader
        )
        XCTAssertEqual(loadCount, 1)

        coordinator.invalidate(day: date)
        _ = await coordinator.load(
            day: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: loader
        )
        XCTAssertEqual(loadCount, 2)
    }

    @MainActor
    func testPlanDayLoadCoordinatorReloadsForDayContentAndForceReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-revision-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        let coordinator = PlanDayLoadCoordinator(database: database)
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        var loadCount = 0
        let loader: (Date) async -> SensorReadingsLoadResult = { _ in
            loadCount += 1
            return SensorReadingsLoadResult(readings: [], isComplete: true)
        }
        var changedSource = TaptionDataSnapshot.empty
        changedSource.actuals = [
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: date.addingTimeInterval(3_600),
                endedAt: date.addingTimeInterval(7_200),
                source: .manual
            ),
        ]

        _ = await coordinator.load(
            day: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: loader
        )
        _ = await coordinator.load(
            day: date,
            source: changedSource,
            sourceRevision: 2,
            sensorLoader: loader
        )
        _ = await coordinator.load(
            day: date,
            source: changedSource,
            sourceRevision: 2,
            sensorLoader: loader,
            forceReload: true
        )

        XCTAssertEqual(loadCount, 2)
    }

    @MainActor
    func testPlanDayLoadCoordinatorReprojectsPersistedRawWhenSourceChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-reproject-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        _ = try await database.migrateLegacyIfNeeded(
            source: .empty,
            sourceRevision: 1,
            readings: [],
            watchSummaries: [],
            rawEnvelopes: []
        )
        let reading = makeReading(date)
        try await database.save(
            PlanDayDataSnapshot.make(
                date: date,
                sourceRevision: 1,
                source: .empty,
                sensorResult: SensorReadingsLoadResult(
                    readings: [reading],
                    isComplete: true
                )
            )
        )
        let coordinator = PlanDayLoadCoordinator(database: database)
        var sensorLoadCount = 0
        var changedSource = TaptionDataSnapshot.empty
        changedSource.actuals = [
            ActualRecord(
                planID: nil,
                title: "업무",
                categoryID: "work",
                startedAt: date.addingTimeInterval(3_600),
                endedAt: date.addingTimeInterval(7_200),
                source: .manual
            ),
        ]

        _ = await coordinator.load(
            day: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: { _ in
                sensorLoadCount += 1
                return SensorReadingsLoadResult(
                    readings: [],
                    isComplete: false
                )
            }
        )
        let reprojected = await coordinator.load(
            day: date,
            source: changedSource,
            sourceRevision: 2,
            sensorLoader: { _ in
                sensorLoadCount += 1
                return SensorReadingsLoadResult(
                    readings: [],
                    isComplete: false
                )
            }
        )

        XCTAssertEqual(sensorLoadCount, 0)
        XCTAssertEqual(reprojected.readings, [reading])
        XCTAssertEqual(reprojected.actuals.count, 1)
        XCTAssertEqual(reprojected.sourceRevision, 2)
    }

    @MainActor
    func testPlanDayLoadCoordinatorReusesPersistedDayAcrossRuntimeRevision() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-stable-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        _ = try await database.migrateLegacyIfNeeded(
            source: .empty,
            sourceRevision: 1,
            readings: [],
            watchSummaries: [],
            rawEnvelopes: []
        )
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        var sensorLoadCount = 0
        let first = PlanDayLoadCoordinator(database: database)
        _ = await first.load(
            day: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: { _ in
                sensorLoadCount += 1
                return SensorReadingsLoadResult(
                    readings: [],
                    isComplete: true
                )
            }
        )

        let relaunched = PlanDayLoadCoordinator(database: database)
        let restored = await relaunched.load(
            day: date,
            source: .empty,
            sourceRevision: 99,
            sensorLoader: { _ in
                sensorLoadCount += 1
                return SensorReadingsLoadResult(
                    readings: [],
                    isComplete: false
                )
            }
        )

        XCTAssertTrue(restored.isComplete)
        XCTAssertEqual(restored.sourceRevision, 99)
        XCTAssertEqual(sensorLoadCount, 1)
    }

    @MainActor
    func testPlanDayLoadCoordinatorRetriesIncompleteLoads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-incomplete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        let coordinator = PlanDayLoadCoordinator(database: database)
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        var loadCount = 0
        let loader: (Date) async -> SensorReadingsLoadResult = { _ in
            loadCount += 1
            return SensorReadingsLoadResult(
                readings: [],
                isComplete: loadCount > 1
            )
        }

        let incomplete = await coordinator.load(
            day: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: loader
        )
        let complete = await coordinator.load(
            day: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: loader
        )

        XCTAssertFalse(incomplete.isComplete)
        XCTAssertTrue(complete.isComplete)
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(coordinator.cachedDayCount, 1)
    }

    @MainActor
    func testPlanDayLoadCoordinatorIgnoresPersistedIncompleteDay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-persisted-incomplete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let database = try PlanDayDatabase(directory: directory)
        try await database.save(
            PlanDayDataSnapshot.make(
                date: date,
                sourceRevision: 1,
                source: .empty,
                sensorResult: SensorReadingsLoadResult(
                    readings: [],
                    isComplete: false
                )
            )
        )
        let coordinator = PlanDayLoadCoordinator(database: database)
        var loadCount = 0

        let loaded = await coordinator.load(
            day: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: { _ in
                loadCount += 1
                return SensorReadingsLoadResult(
                    readings: [],
                    isComplete: true
                )
            }
        )

        XCTAssertTrue(loaded.isComplete)
        XCTAssertEqual(loadCount, 1)
    }

    @MainActor
    func testPlanDayLoadCoordinatorPreloadsEveryDayInMonth() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-preload-\(UUID().uuidString)")
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

    @MainActor
    func testThirtyDayAppColdAndWarmLoadP95StaysInteractive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-30d-p95-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = Calendar.autoupdatingCurrent
        let base = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 1)
        )!
        let days = (0..<30).compactMap {
            calendar.date(byAdding: .day, value: $0, to: base)
        }
        do {
            let database = try PlanDayDatabase(directory: directory)
            _ = try await database.migrateLegacyIfNeeded(
                source: .empty,
                sourceRevision: 1,
                readings: [],
                watchSummaries: [],
                rawEnvelopes: []
            )
            for day in days {
                let readings = (0..<1_440).map {
                    makeReading(day.addingTimeInterval(Double($0 * 60)))
                }
                try await database.save(PlanDayDataSnapshot(
                    day: day,
                    sourceRevision: 1,
                    sourceUpdatedAt: day,
                    actuals: [],
                    places: [],
                    travel: [],
                    readings: readings,
                    isComplete: true
                ))
            }
        }

        let database = try PlanDayDatabase(directory: directory)
        let coordinator = PlanDayLoadCoordinator(database: database)
        var sensorLoadCount = 0
        func readDurations() async -> [Double] {
            var milliseconds: [Double] = []
            for day in days {
                let started = DispatchTime.now().uptimeNanoseconds
                _ = await coordinator.load(
                    day: day,
                    source: .empty,
                    sourceRevision: 1,
                    sensorLoader: { _ in
                        sensorLoadCount += 1
                        return SensorReadingsLoadResult(
                            readings: [],
                            isComplete: false
                        )
                    }
                )
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                milliseconds.append(Double(elapsed) / 1_000_000)
            }
            return milliseconds
        }
        func p95(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            let index = max(
                0,
                min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
            )
            return sorted[index]
        }

        let coldP95 = p95(await readDurations())
        let warmP95 = p95(await readDurations())
        print("APP_DAY_LOAD_30D_COLD_P95_MS=\(coldP95)")
        print("APP_DAY_LOAD_30D_WARM_P95_MS=\(warmP95)")
        XCTAssertEqual(sensorLoadCount, 0)
        XCTAssertLessThan(coldP95, 100)
        XCTAssertLessThan(warmP95, 5)
    }
}
