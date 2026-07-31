import Foundation

actor SensorReadingArchive {
    private let fileURL: URL
    private let retentionInterval: TimeInterval
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var lastCompactionAt: Date?

    init(
        fileURL: URL,
        retentionInterval: TimeInterval = 7 * 86_400
    ) {
        self.fileURL = fileURL
        self.retentionInterval = max(86_400, retentionInterval)
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
            fileURL: directory.appendingPathComponent("sensor-readings-v1.jsonl")
        )
    }

    func append(_ reading: SensorReading, now: Date = .now) throws {
        if lastCompactionAt.map({ now.timeIntervalSince($0) >= 86_400 }) ?? true {
            try compact(now: now)
            lastCompactionAt = now
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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
                options: [.atomic, .completeFileProtection]
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
            options: [.atomic, .completeFileProtection]
        )
    }

    func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
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
}

@MainActor
final class AppleSensorDataService {
    private let collector: AppleSensorCollector
    private let archive: SensorReadingArchive
    private let history: AppleMotionHistoryService
    private var collectionTask: Task<Void, Never>?

    private(set) var lastPersistenceErrorDescription: String?

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

    func requestLocationPermission(always: Bool = false) {
        collector.requestLocationPermission(always: always)
    }

    func startCollection(
        configuration: SensorCollectionConfiguration = .standard
    ) {
        guard collectionTask == nil else { return }
        lastPersistenceErrorDescription = nil
        let stream = collector.readings(configuration: configuration)
        collectionTask = Task { [weak self] in
            for await reading in stream {
                guard !Task.isCancelled, let self else { break }
                do {
                    try await self.archive.append(reading)
                } catch {
                    self.lastPersistenceErrorDescription = error.localizedDescription
                }
            }
        }
    }

    func stopCollection() {
        collectionTask?.cancel()
        collectionTask = nil
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

    func deleteArchivedReadings() async throws {
        try await archive.deleteAll()
    }
}
