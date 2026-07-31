import Foundation
import OSLog

enum RawDeviceDataSource: String, Codable, Sendable {
    case gps
    case iPhoneSensor
    case iPhoneMotion
    case iPhonePedometer
    case healthKit
    case appleWatch
}

struct RawDeviceDataEnvelope: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var capturedAt: Date
    var source: RawDeviceDataSource
    var kind: String
    var schemaVersion: Int
    var payloadJSON: String

    init<T: Encodable>(
        id: UUID = UUID(),
        capturedAt: Date = .now,
        source: RawDeviceDataSource,
        kind: String,
        schemaVersion: Int = 1,
        payload: T,
        encoder: JSONEncoder = RawDeviceDataMonthlyArchive.payloadEncoder()
    ) throws {
        self.id = id
        self.capturedAt = capturedAt
        self.source = source
        self.kind = kind
        self.schemaVersion = schemaVersion
        let data = try encoder.encode(payload)
        self.payloadJSON = String(decoding: data, as: UTF8.self)
    }
}

final class RawDeviceDataMonthlyArchive: @unchecked Sendable {
    private let rootDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let calendar: Calendar
    private let lock = NSLock()

    init(rootDirectory: URL, calendar: Calendar = .autoupdatingCurrent) {
        self.rootDirectory = rootDirectory
        self.calendar = calendar
        self.encoder = Self.payloadEncoder()
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> RawDeviceDataMonthlyArchive {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return RawDeviceDataMonthlyArchive(
            rootDirectory: root.appendingPathComponent(
                "TaptionPlan/RawData",
                isDirectory: true
            )
        )
    }

    static func payloadEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    func append<T: Encodable>(
        source: RawDeviceDataSource,
        kind: String,
        payload: T,
        capturedAt: Date = .now
    ) throws {
        let envelope = try RawDeviceDataEnvelope(
            capturedAt: capturedAt,
            source: source,
            kind: kind,
            payload: payload,
            encoder: encoder
        )
        try append(envelopes: [envelope])
    }

    func append(envelopes: [RawDeviceDataEnvelope]) throws {
        guard !envelopes.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let grouped = Dictionary(grouping: envelopes) {
            monthKey(for: $0.capturedAt)
        }
        for (monthKey, values) in grouped {
            let fileURL = try compressedFileURL(for: monthKey)
            var payload = try existingPayload(at: fileURL)
            for envelope in values.sorted(by: { $0.capturedAt < $1.capturedAt }) {
                payload.append(try encoder.encode(envelope))
                payload.append(0x0A)
            }
            try compress(payload).write(
                to: fileURL,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication,
                ]
            )
        }
    }

    func envelopes(inMonthContaining date: Date) throws
        -> [RawDeviceDataEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        let fileURL = try compressedFileURL(for: monthKey(for: date))
        let payload = try existingPayload(at: fileURL)
        return payload.split(separator: 0x0A).compactMap {
            try? decoder.decode(RawDeviceDataEnvelope.self, from: Data($0))
        }
    }

    private func compressedFileURL(for monthKey: String) throws -> URL {
        let directory = rootDirectory.appendingPathComponent(
            monthKey,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent(
            "taption-raw-\(monthKey).jsonl.zlib"
        )
    }

    private func existingPayload(at fileURL: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Data()
        }
        let compressed = try Data(contentsOf: fileURL)
        guard !compressed.isEmpty else { return Data() }
        return try decompress(compressed)
    }

    private func monthKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        return String(format: "%04d-%02d", year, month)
    }

    private func compress(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .zlib) as Data
    }

    private func decompress(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .zlib) as Data
    }
}

actor SensorReadingArchive {
    private static let logger = Logger(
        subsystem: "com.taption.plan",
        category: "RawDeviceDataArchive"
    )
    private let fileURL: URL
    private let retentionInterval: TimeInterval
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let rawArchive: RawDeviceDataMonthlyArchive?
    private var lastCompactionAt: Date?

    init(
        fileURL: URL,
        retentionInterval: TimeInterval = 7 * 86_400,
        rawArchive: RawDeviceDataMonthlyArchive? = nil
    ) {
        self.fileURL = fileURL
        self.retentionInterval = max(86_400, retentionInterval)
        self.rawArchive = rawArchive
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> SensorReadingArchive {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent(
            "TaptionPlan/Sensors",
            isDirectory: true
        )
        return SensorReadingArchive(
            fileURL: directory.appendingPathComponent("sensor-readings-v1.jsonl"),
            rawArchive: try? RawDeviceDataMonthlyArchive.applicationSupport()
        )
    }

    func append(_ reading: SensorReading, now: Date = .now) throws {
        if let rawArchive {
            do {
                try rawArchive.append(
                    source: reading.point == nil ? .iPhoneSensor : .gps,
                    kind: "sensor-reading",
                    payload: reading,
                    capturedAt: reading.timestamp
                )
            } catch {
                Self.logger.error(
                    "Raw sensor archive failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        if lastCompactionAt.map({ now.timeIntervalSince($0) >= 86_400 }) ?? true {
            try compact(now: now)
            lastCompactionAt = now
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try applyBackgroundFileProtectionIfNeeded()
        var line = try encoder.encode(reading)
        line.append(0x0A)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(
                to: fileURL,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication,
                ]
            )
        }
    }

    func readings(in span: TimeSpan) throws -> [SensorReading] {
        try allReadings()
            .filter { span.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func compact(now: Date = .now) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let cutoff = now.addingTimeInterval(-retentionInterval)
        let retained = try allReadings().filter { $0.timestamp >= cutoff }
        guard !retained.isEmpty else {
            try FileManager.default.removeItem(at: fileURL)
            return
        }
        let payload = try retained.reduce(into: Data()) { data, reading in
            data.append(try encoder.encode(reading))
            data.append(0x0A)
        }
        try payload.write(
            to: fileURL,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
    }

    func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    func rawEnvelopes(inMonthContaining date: Date) throws
        -> [RawDeviceDataEnvelope] {
        guard let rawArchive else { return [] }
        return try rawArchive.envelopes(inMonthContaining: date)
    }

    private func allReadings() throws -> [SensorReading] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return data.split(separator: 0x0A).compactMap {
            try? decoder.decode(SensorReading.self, from: Data($0))
        }
    }

    private func applyBackgroundFileProtectionIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.setAttributes(
            [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: fileURL.path
        )
    }
}

@MainActor
final class AppleSensorDataService {
    private static let logger = Logger(
        subsystem: "com.taption.plan",
        category: "SensorArchive"
    )
    private let collector: AppleSensorCollector
    private let archive: SensorReadingArchive
    private let history: AppleMotionHistoryService
    private var collectionTask: Task<Void, Never>?
    private var activeConfiguration: SensorCollectionConfiguration?

    private(set) var lastPersistenceErrorDescription: String?
    var onReadingPersisted: ((SensorReading) -> Void)?

    init(
        collector: AppleSensorCollector = AppleSensorCollector(),
        archive: SensorReadingArchive,
        history: AppleMotionHistoryService = AppleMotionHistoryService()
    ) {
        self.collector = collector
        self.archive = archive
        self.history = history
    }

    static func applicationSupport() throws -> AppleSensorDataService {
        AppleSensorDataService(
            archive: try SensorReadingArchive.applicationSupport()
        )
    }

    func hardwareAvailability() -> SensorHardwareAvailability {
        collector.hardwareAvailability()
    }

    func locationPermissionState() -> PermissionState {
        collector.permissionState()
    }

    func motionPermissionState() -> PermissionState {
        history.permissionState()
    }

    func hasAlwaysLocationAuthorization() -> Bool {
        collector.hasAlwaysLocationAuthorization()
    }

    func requestLocationPermission(always: Bool = false) {
        collector.requestLocationPermission(always: always)
    }

    func startCollection(
        configuration: SensorCollectionConfiguration = .standard
    ) {
        if collectionTask != nil,
           activeConfiguration == configuration {
            return
        }
        stopCollection()
        lastPersistenceErrorDescription = nil
        activeConfiguration = configuration
        let stream = collector.readings(configuration: configuration)
        collectionTask = Task { [weak self] in
            for await reading in stream {
                guard !Task.isCancelled, let self else { break }
                do {
                    try await self.archive.append(reading)
                    self.onReadingPersisted?(reading)
                } catch {
                    self.lastPersistenceErrorDescription = error.localizedDescription
                    Self.logger.error(
                        "Sensor archive append failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    func stopCollection() {
        collectionTask?.cancel()
        collectionTask = nil
        activeConfiguration = nil
        collector.stop()
    }

    func archivedReadings(in span: TimeSpan) async throws -> [SensorReading] {
        try await archive.readings(in: span)
    }

    func motionActivities(
        in span: TimeSpan
    ) async throws -> [MotionActivityRecord] {
        try await history.activities(in: span)
    }

    func pedometerSummary(
        in span: TimeSpan
    ) async throws -> PedometerSummary? {
        try await history.pedometerSummary(in: span)
    }

    func pedometerEvidence(
        for activities: [MotionActivityRecord]
    ) async -> [AppleMovementEvidence] {
        var result: [AppleMovementEvidence] = []
        let eligible = activities
            .filter {
                $0.span.duration >= 2 * 60
                    && $0.motion != .stationary
                    && $0.motion != .unknown
            }
            .prefix(64)
        for activity in eligible {
            guard let summary = try? await history.pedometerSummary(
                in: activity.span
            ) else {
                continue
            }
            result.append(
                AppleMovementEvidence(
                    span: activity.span,
                    source: .iPhone,
                    kind: .steps,
                    stepCount: summary.stepCount,
                    distanceMeters: summary.distanceMeters,
                    sourceName: "iPhone CMPedometer",
                    deviceName: "iPhone"
                )
            )
        }
        return result
    }

    func deleteArchivedReadings() async throws {
        try await archive.deleteAll()
    }
}
