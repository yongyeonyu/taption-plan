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
        let archive = SensorReadingArchive(fileURL: fileURL)
        try await archive.append([
            makeReading(first.addingTimeInterval(60), sequence: 2),
            makeReading(first, sequence: 1)
        ])

        let span = TimeSpan(start: first.addingTimeInterval(-1), end: first.addingTimeInterval(61))
        let values = try await archive.readings(in: span)
        XCTAssertEqual(values.map(\.sequence), [1, 2])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("taption-plan-v2.sqlite").path))

        let reopened = SensorReadingArchive(fileURL: fileURL)
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
        let archive = SensorReadingArchive(fileURL: fileURL, rawArchive: raw)
        let span = TimeSpan(start: date.addingTimeInterval(-1), end: date.addingTimeInterval(1))
        let migrated = try await archive.readings(in: span)
        XCTAssertEqual(migrated.map(\.id), [id])

        let second = SensorReadingArchive(fileURL: fileURL, rawArchive: raw)
        let reopened = try await second.routeReadings(in: span)
        XCTAssertEqual(reopened.map(\.id), [id])
    }

    func testNewSensorWriteDoesNotAppendLegacyCompression() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-uncompressed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("sensor-readings-v1.jsonl")
        let archive = SensorReadingArchive(
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

    func testRawDeviceEnvelopeUsesUncompressedDayDatabase() async throws {
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
        XCTAssertEqual(events.first?.payload.first, 0x7B)
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
                payload: try encoder.encode(reading)
            )
        ])
        let archive = SensorReadingArchive(fileURL: fileURL)
        let values = try await archive.readings(in: TimeSpan(start: date.addingTimeInterval(-1), end: date.addingTimeInterval(1)))
        XCTAssertEqual(values.map(\.id), [reading.id])
    }
}
