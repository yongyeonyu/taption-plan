import CoreLocation
import Foundation
import OSLog
import TaptionPlanCore

struct PhoneScreenSnapshot: Codable, Hashable, Sendable {
    var brightness: Double
    var isOn: Bool

    init(brightness: Double, isOn: Bool) {
        self.brightness = min(1, max(0, brightness))
        self.isOn = isOn
    }
}

/// Keeps the last display observation available to a background sensor wake.
/// iOS does not provide a general-purpose ambient-light/lux API to apps.
enum PhoneScreenActivityStore {
    private static let brightnessKey = "TaptionPlan.screenBrightness"
    private static let isOnKey = "TaptionPlan.screenIsOn"

    static func update(brightness: Double, isOn: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(min(1, max(0, brightness)), forKey: brightnessKey)
        defaults.set(isOn, forKey: isOnKey)
    }

    static func snapshot() -> PhoneScreenSnapshot {
        let defaults = UserDefaults.standard
        return PhoneScreenSnapshot(
            brightness: defaults.object(forKey: brightnessKey) as? Double ?? 0,
            isOn: defaults.object(forKey: isOnKey) as? Bool ?? false
        )
    }
}

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
    var payloadChecksum: String?
    var payloadByteCount: Int?

    init<T: Encodable>(
        id: UUID? = nil,
        capturedAt: Date = .now,
        source: RawDeviceDataSource,
        kind: String,
        schemaVersion: Int = 1,
        payload: T,
        encoder: JSONEncoder = RawDeviceDataMonthlyArchive.payloadEncoder()
    ) throws {
        self.capturedAt = capturedAt
        self.source = source
        self.kind = kind
        self.schemaVersion = schemaVersion
        let data = try encoder.encode(payload)
        self.payloadJSON = String(decoding: data, as: UTF8.self)
        let checksum = TaptionPlanCanonicalStorage.checksum(data)
        self.payloadChecksum = checksum
        self.payloadByteCount = data.count
        self.id = id ?? Self.stableID(
            capturedAt: capturedAt,
            source: source,
            kind: kind,
            schemaVersion: schemaVersion,
            payloadChecksum: checksum
        )
    }

    var hasValidPayload: Bool {
        guard let data = payloadJSON.data(using: .utf8) else { return false }
        if let payloadByteCount, payloadByteCount != data.count { return false }
        if let payloadChecksum,
           payloadChecksum != TaptionPlanCanonicalStorage.checksum(data) {
            return false
        }
        return true
    }

    private static func stableID(
        capturedAt: Date,
        source: RawDeviceDataSource,
        kind: String,
        schemaVersion: Int,
        payloadChecksum: String
    ) -> UUID {
        let seed = [
            source.rawValue,
            kind,
            String(schemaVersion),
            String(capturedAt.timeIntervalSince1970.bitPattern),
            payloadChecksum,
        ].joined(separator: "|")
        let hex = String(
            TaptionPlanCanonicalStorage.checksum(Data(seed.utf8)).prefix(32)
        )
        let first = String(hex.prefix(8))
        let second = String(hex.dropFirst(8).prefix(4))
        let third = String(hex.dropFirst(12).prefix(4))
        let fourth = String(hex.dropFirst(16).prefix(4))
        let fifth = String(hex.dropFirst(20).prefix(12))
        let value = "\(first)-\(second)-\(third)-\(fourth)-\(fifth)"
        return UUID(uuidString: value)!
    }
}

final class RawDeviceDataMonthlyArchive: @unchecked Sendable {
    private enum ArchiveError: Swift.Error {
        case invalidEnvelope
        case conflictingEnvelope
    }
    private static let logger = Logger(
        subsystem: "com.taption.plan",
        category: "RawDeviceDataArchive"
    )
    private let rootDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let calendar: Calendar
    private let lock = NSLock()
    private let compressionQueue = DispatchQueue(
        label: "com.taption.plan.raw-archive-compression",
        qos: .utility
    )
    private let flushDelay: TimeInterval
    private var archiveGeneration: UInt64 = 0
    private var scheduledMonths = Set<String>()
    private var monthEnvelopeCache: [String: [RawDeviceDataEnvelope]] = [:]
    private var monthEnvelopeCacheOrder: [String] = []
    private static let monthEnvelopeCacheLimit = 2

    init(
        rootDirectory: URL,
        calendar: Calendar = .autoupdatingCurrent,
        flushDelay: TimeInterval = 5 * 60
    ) {
        self.rootDirectory = rootDirectory
        self.calendar = calendar
        self.flushDelay = max(0, flushDelay)
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
        guard envelopes.allSatisfy(\.hasValidPayload) else {
            throw ArchiveError.invalidEnvelope
        }
        var monthsToSchedule: [String] = []
        lock.lock()
        do {
            let grouped = Dictionary(grouping: envelopes) {
                monthKey(for: $0.capturedAt)
            }
            for (monthKey, values) in grouped {
                invalidateCachedMonth(monthKey)
                let journalURL = try journalFileURL(for: monthKey)
                var payload = Data()
                for envelope in values.sorted(by: {
                    $0.capturedAt < $1.capturedAt
                }) {
                    payload.append(try encoder.encode(envelope))
                    payload.append(0x0A)
                }
                try append(payload, to: journalURL)
                if scheduledMonths.insert(monthKey).inserted {
                    monthsToSchedule.append(monthKey)
                }
            }
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        for monthKey in monthsToSchedule {
            compressionQueue.asyncAfter(
                deadline: .now() + flushDelay
            ) { [weak self] in
                do {
                    try self?.flush(monthKey: monthKey)
                } catch {
                    Self.logger.error(
                        "Raw archive chunk flush failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    func envelopes(
        inMonthContaining date: Date,
        strict: Bool = false
    ) throws -> [RawDeviceDataEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        let monthKey = monthKey(for: date)
        if !strict, let cached = cachedEnvelopes(for: monthKey) {
            return cached
        }
        let directory: URL
        if strict {
            directory = rootDirectory.appendingPathComponent(
                monthKey,
                isDirectory: true
            )
            guard FileManager.default.fileExists(atPath: directory.path) else {
                return []
            }
        } else {
            directory = try monthDirectory(for: monthKey)
        }
        var payloads: [Data] = []
        let legacyURL = legacyCompressedFileURL(
            in: directory,
            monthKey: monthKey
        )
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            do {
                payloads.append(try existingPayload(at: legacyURL))
            } catch {
                if strict { throw error }
            }
        }
        let journalURL = journalFileURL(in: directory)
        if FileManager.default.fileExists(atPath: journalURL.path) {
            do {
                payloads.append(try Data(contentsOf: journalURL))
            } catch {
                if strict { throw error }
            }
        }
        let chunks = directory.appendingPathComponent(
            "chunks",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: chunks.path) {
            let files: [URL]
            do {
                files = try FileManager.default.contentsOfDirectory(
                    at: chunks,
                    includingPropertiesForKeys: nil
                )
            } catch {
                if strict { throw error }
                return []
            }
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    let data = try Data(contentsOf: file)
                    if file.pathExtension == "zlib" {
                        payloads.append(try decompress(data))
                    } else if file.lastPathComponent.hasSuffix(".jsonl.pending") {
                        payloads.append(data)
                    }
                } catch {
                    if strict { throw error }
                }
            }
        }
        var decoded: [RawDeviceDataEnvelope] = []
        for payload in payloads {
            var lineStart = payload.startIndex
            while lineStart < payload.endIndex {
                let lineEnd = payload[lineStart...].firstIndex(of: 0x0A)
                    ?? payload.endIndex
                do {
                    guard lineStart < lineEnd else {
                        throw ArchiveError.invalidEnvelope
                    }
                    let envelope = try decoder.decode(
                        RawDeviceDataEnvelope.self,
                        from: Data(payload[lineStart..<lineEnd])
                    )
                    guard envelope.hasValidPayload else {
                        throw ArchiveError.invalidEnvelope
                    }
                    decoded.append(envelope)
                } catch {
                    if strict { throw ArchiveError.invalidEnvelope }
                }
                guard lineEnd < payload.endIndex else { break }
                lineStart = payload.index(after: lineEnd)
            }
        }
        var byID: [UUID: RawDeviceDataEnvelope] = [:]
        for envelope in decoded {
            if let existing = byID[envelope.id] {
                if strict, existing != envelope {
                    throw ArchiveError.conflictingEnvelope
                }
            } else {
                byID[envelope.id] = envelope
            }
        }
        let envelopes = byID.values
            .sorted {
                if $0.capturedAt != $1.capturedAt {
                    return $0.capturedAt < $1.capturedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        cache(envelopes, for: monthKey)
        return envelopes
    }

    private func cachedEnvelopes(
        for monthKey: String
    ) -> [RawDeviceDataEnvelope]? {
        guard let cached = monthEnvelopeCache[monthKey] else { return nil }
        monthEnvelopeCacheOrder.removeAll { $0 == monthKey }
        monthEnvelopeCacheOrder.append(monthKey)
        return cached
    }

    private func cache(
        _ envelopes: [RawDeviceDataEnvelope],
        for monthKey: String
    ) {
        monthEnvelopeCache[monthKey] = envelopes
        monthEnvelopeCacheOrder.removeAll { $0 == monthKey }
        monthEnvelopeCacheOrder.append(monthKey)
        while monthEnvelopeCacheOrder.count > Self.monthEnvelopeCacheLimit {
            monthEnvelopeCache[monthEnvelopeCacheOrder.removeFirst()] = nil
        }
    }

    private func invalidateCachedMonth(_ monthKey: String) {
        monthEnvelopeCache[monthKey] = nil
        monthEnvelopeCacheOrder.removeAll { $0 == monthKey }
    }

    func flushPendingWrites() throws {
        lock.lock()
        let months = Array(scheduledMonths)
        lock.unlock()
        for monthKey in months {
            try flush(monthKey: monthKey)
        }
        compressionQueue.sync {}
    }

    func sensorReadings() throws -> [SensorReading] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        var result: [SensorReading] = []
        var seen = Set<UUID>()
        for directory in directories where directory.lastPathComponent.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil {
            let parts = directory.lastPathComponent.split(separator: "-")
            guard parts.count == 2,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]),
                  let date = Calendar.autoupdatingCurrent.date(from: DateComponents(year: year, month: month, day: 1)) else { continue }
            for envelope in try envelopes(inMonthContaining: date) where envelope.kind == "sensor-reading" {
                guard let payload = envelope.payloadJSON.data(using: .utf8),
                      let reading = try? decoder.decode(SensorReading.self, from: payload),
                      seen.insert(reading.id).inserted else { continue }
                result.append(reading)
            }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    func forEachSensorReadingBatch(
        size: Int,
        visit: @escaping @Sendable ([SensorReading]) async throws -> Bool
    ) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else {
            return true
        }
        let directories = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var batch: [SensorReading] = []
        let batchSize = max(1, size)
        batch.reserveCapacity(batchSize)
        for directory in directories where directory.lastPathComponent.range(
            of: #"^\d{4}-\d{2}$"#,
            options: .regularExpression
        ) != nil {
            let parts = directory.lastPathComponent.split(separator: "-")
            guard parts.count == 2,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]),
                  let date = calendar.date(from: DateComponents(
                    year: year,
                    month: month,
                    day: 1
                  )) else { continue }
            for envelope in try envelopes(inMonthContaining: date, strict: true)
            where envelope.kind == "sensor-reading" {
                try Task.checkCancellation()
                guard let payload = envelope.payloadJSON.data(using: .utf8) else {
                    throw ArchiveError.invalidEnvelope
                }
                batch.append(try decoder.decode(SensorReading.self, from: payload))
                if batch.count == batchSize {
                    guard try await visit(batch) else { return false }
                    batch.removeAll(keepingCapacity: true)
                }
            }
            lock.withLock {
                invalidateCachedMonth(directory.lastPathComponent)
            }
        }
        return batch.isEmpty ? true : try await visit(batch)
    }

    func allEnvelopes() throws -> [RawDeviceDataEnvelope] {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else {
            return []
        }
        let directories = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var byID: [UUID: RawDeviceDataEnvelope] = [:]
        for directory in directories
        where directory.lastPathComponent.range(
            of: #"^\d{4}-\d{2}$"#,
            options: .regularExpression
        ) != nil {
            let parts = directory.lastPathComponent.split(separator: "-")
            guard parts.count == 2,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]),
                  let date = calendar.date(
                    from: DateComponents(year: year, month: month, day: 1)
                  ) else { continue }
            for envelope in try envelopes(inMonthContaining: date, strict: true) {
                if let existing = byID[envelope.id], existing != envelope {
                    throw ArchiveError.conflictingEnvelope
                }
                byID[envelope.id] = envelope
            }
        }
        return byID.values.sorted {
            if $0.capturedAt != $1.capturedAt {
                return $0.capturedAt < $1.capturedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        archiveGeneration &+= 1
        scheduledMonths.removeAll()
        monthEnvelopeCache.removeAll()
        monthEnvelopeCacheOrder.removeAll()
        if FileManager.default.fileExists(atPath: rootDirectory.path) {
            try FileManager.default.removeItem(at: rootDirectory)
        }
    }

    private func monthDirectory(for monthKey: String) throws -> URL {
        let directory = rootDirectory.appendingPathComponent(
            monthKey,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func legacyCompressedFileURL(
        in directory: URL,
        monthKey: String
    ) -> URL {
        directory.appendingPathComponent(
            "taption-raw-\(monthKey).jsonl.zlib"
        )
    }

    private func journalFileURL(for monthKey: String) throws -> URL {
        journalFileURL(in: try monthDirectory(for: monthKey))
    }

    private func journalFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("current.jsonl")
    }

    private func append(_ payload: Data, to fileURL: URL) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
        } else {
            try payload.write(
                to: fileURL,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication,
                ]
            )
        }
    }

    private func flush(monthKey: String) throws {
        let pendingURL: URL?
        let generation: UInt64
        lock.lock()
        do {
            guard scheduledMonths.remove(monthKey) != nil else {
                lock.unlock()
                return
            }
            let directory = try monthDirectory(for: monthKey)
            let journalURL = journalFileURL(in: directory)
            guard FileManager.default.fileExists(atPath: journalURL.path) else {
                lock.unlock()
                return
            }
            let chunks = directory.appendingPathComponent(
                "chunks",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: chunks,
                withIntermediateDirectories: true
            )
            let name = String(
                format: "%013lld-%@.jsonl.pending",
                Int64(Date.now.timeIntervalSince1970 * 1_000),
                UUID().uuidString
            )
            let destination = chunks.appendingPathComponent(name)
            try FileManager.default.moveItem(
                at: journalURL,
                to: destination
            )
            pendingURL = destination
            generation = archiveGeneration
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        guard let pendingURL else { return }
        let payload = try Data(contentsOf: pendingURL)
        let compressed = try compress(payload)
        let destination = pendingURL
            .deletingPathExtension()
            .deletingPathExtension()
            .appendingPathExtension("jsonl.zlib")
        lock.lock()
        defer { lock.unlock() }
        guard generation == archiveGeneration,
              FileManager.default.fileExists(atPath: pendingURL.path) else {
            return
        }
        try compressed.write(
            to: destination,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
        try FileManager.default.removeItem(at: pendingURL)
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

/// Stores active-session samples in small independent compressed files. A
/// damaged or partially transferred chunk therefore never invalidates the
/// rest of the month, while the legacy monthly archive remains readable.
final class TrackingSessionChunkArchive: @unchecked Sendable {
    private enum ArchiveError: Swift.Error {
        case invalidReading
    }

    private struct PendingChunk {
        var startedAt: Date
        var index: Int
        var readings: [SensorReading]
    }

    private let rootDirectory: URL
    private let lock = NSLock()
    private let encoder = RawDeviceDataMonthlyArchive.payloadEncoder()
    private var pending: [UUID: PendingChunk] = [:]
    private let calendar: Calendar

    init(rootDirectory: URL, calendar: Calendar = .autoupdatingCurrent) {
        self.rootDirectory = rootDirectory
        self.calendar = calendar
    }

    static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> TrackingSessionChunkArchive {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return TrackingSessionChunkArchive(
            rootDirectory: root.appendingPathComponent(
                "TaptionPlan/RawData",
                isDirectory: true
            )
        )
    }

    func append(_ reading: SensorReading) throws {
        guard let sessionID = reading.trackingSessionID else { return }
        lock.lock()
        defer { lock.unlock() }
        var chunk: PendingChunk
        if let current = pending[sessionID] {
            chunk = current
        } else {
            chunk = PendingChunk(
                startedAt: reading.timestamp,
                index: try nextChunkIndex(
                    sessionID: sessionID,
                    timestamp: reading.timestamp
                ),
                readings: []
            )
        }
        if reading.timestamp.timeIntervalSince(chunk.startedAt) >= 30,
           !chunk.readings.isEmpty {
            try write(chunk, sessionID: sessionID)
            chunk = PendingChunk(
                startedAt: reading.timestamp,
                index: chunk.index + 1,
                readings: []
            )
        }
        if !chunk.readings.contains(where: { $0.id == reading.id }) {
            chunk.readings.append(reading)
        }
        pending[sessionID] = chunk
        if reading.trackingSessionEnded == true {
            try write(chunk, sessionID: sessionID)
            pending[sessionID] = nil
        }
    }

    func flushAll() throws {
        lock.lock()
        defer { lock.unlock() }
        for (sessionID, chunk) in pending where !chunk.readings.isEmpty {
            try write(chunk, sessionID: sessionID)
        }
        pending.removeAll()
    }

    func readings(in span: TimeSpan) throws -> [SensorReading] {
        lock.lock()
        let pendingReadings = pending.values.flatMap(\.readings)
        lock.unlock()

        var values = pendingReadings.filter {
            span.contains($0.timestamp)
        }
        var seen = Set(values.map(\.id))
        var month = calendar.dateInterval(of: .month, for: span.start)?.start
            ?? span.start
        let lastMonth = calendar.dateInterval(of: .month, for: span.end)?.start
            ?? span.end
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        while month <= lastMonth {
            let components = calendar.dateComponents([.year, .month], from: month)
            let monthKey = String(
                format: "%04d-%02d",
                components.year ?? 1970,
                components.month ?? 1
            )
            let monthDirectory = rootDirectory.appendingPathComponent(
                monthKey,
                isDirectory: true
            )
            let sessionDirectories = (
                try? FileManager.default.contentsOfDirectory(
                    at: monthDirectory,
                    includingPropertiesForKeys: nil
                )
            ) ?? []
            for sessionDirectory in sessionDirectories
            where UUID(uuidString: sessionDirectory.lastPathComponent) != nil {
                let files = (
                    try? FileManager.default.contentsOfDirectory(
                        at: sessionDirectory,
                        includingPropertiesForKeys: nil
                    )
                ) ?? []
                for file in files where file.lastPathComponent.hasSuffix(
                    ".jsonl.zlib"
                ) {
                    guard let compressed = try? Data(contentsOf: file),
                          let data = try? (compressed as NSData).decompressed(
                              using: .zlib
                          ) as Data else { continue }
                    for line in data.split(separator: 0x0A) {
                        guard let reading = try? decoder.decode(
                            SensorReading.self,
                            from: Data(line)
                        ),
                        span.contains(reading.timestamp),
                        seen.insert(reading.id).inserted else { continue }
                        values.append(reading)
                    }
                }
            }
            guard let next = calendar.date(
                byAdding: .month,
                value: 1,
                to: month
            ), next > month else { break }
            month = next
        }
        return values.sorted { $0.timestamp < $1.timestamp }
    }

    func allPersistedReadings() throws -> [SensorReading] {
        let files = persistedReadingFiles() ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var result: [SensorReading] = []
        var seen = Set<UUID>()
        for file in files where file.pathExtension == "zlib" {
            guard let compressed = try? Data(contentsOf: file),
                  let data = try? (compressed as NSData).decompressed(using: .zlib) as Data else { continue }
            for line in data.split(separator: 0x0A) {
                guard let reading = try? decoder.decode(SensorReading.self, from: Data(line)),
                      seen.insert(reading.id).inserted else { continue }
                result.append(reading)
            }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    func forEachPersistedReadingBatch(
        size: Int,
        visit: @escaping @Sendable ([SensorReading]) async throws -> Bool
    ) async throws -> Bool {
        guard let files = persistedReadingFiles() else { return true }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var batch: [SensorReading] = []
        let batchSize = max(1, size)
        batch.reserveCapacity(batchSize)
        for file in files where file.pathExtension == "zlib" {
            let compressed = try Data(contentsOf: file)
            let data = try (compressed as NSData).decompressed(using: .zlib) as Data
            var lineStart = data.startIndex
            while lineStart < data.endIndex {
                try Task.checkCancellation()
                let lineEnd = data[lineStart...].firstIndex(of: 0x0A)
                    ?? data.endIndex
                guard lineStart < lineEnd else {
                    throw ArchiveError.invalidReading
                }
                batch.append(try decoder.decode(
                    SensorReading.self,
                    from: Data(data[lineStart..<lineEnd])
                ))
                if batch.count == batchSize {
                    guard try await visit(batch) else { return false }
                    batch.removeAll(keepingCapacity: true)
                }
                guard lineEnd < data.endIndex else { break }
                lineStart = data.index(after: lineEnd)
            }
        }
        return batch.isEmpty ? true : try await visit(batch)
    }

    private func persistedReadingFiles() -> [URL]? {
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        ) else { return nil }
        var files: [URL] = []
        while let file = enumerator.nextObject() as? URL {
            let sessionDirectory = file.deletingLastPathComponent()
                .lastPathComponent
            let monthDirectory = file.deletingLastPathComponent()
                .deletingLastPathComponent()
                .lastPathComponent
            guard file.pathExtension == "zlib",
                  file.lastPathComponent.hasSuffix(".jsonl.zlib"),
                  UUID(uuidString: sessionDirectory) != nil,
                  Self.isMonthKey(monthDirectory) else { continue }
            files.append(file)
        }
        return files
    }

    private static func isMonthKey(_ value: String) -> Bool {
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0].count == 4,
              components[1].count == 2,
              Int(components[0]) != nil,
              Int(components[1]) != nil else { return false }
        return true
    }

    func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
        if FileManager.default.fileExists(atPath: rootDirectory.path) {
            try FileManager.default.removeItem(at: rootDirectory)
        }
    }

    private func write(_ chunk: PendingChunk, sessionID: UUID) throws {
        guard !chunk.readings.isEmpty else { return }
        let components = calendar.dateComponents(
            [.year, .month],
            from: chunk.startedAt
        )
        let month = String(
            format: "%04d-%02d",
            components.year ?? 1970,
            components.month ?? 1
        )
        let directory = rootDirectory
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent(
            String(format: "%06d.jsonl.zlib", chunk.index)
        )
        var payload = Data()
        for reading in chunk.readings.sorted(by: readingOrder) {
            payload.append(try encoder.encode(reading))
            payload.append(0x0A)
        }
        let compressed = try (payload as NSData).compressed(using: .zlib) as Data
        try compressed.write(
            to: fileURL,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
    }

    private func nextChunkIndex(
        sessionID: UUID,
        timestamp: Date
    ) throws -> Int {
        let components = calendar.dateComponents([.year, .month], from: timestamp)
        let month = String(
            format: "%04d-%02d",
            components.year ?? 1970,
            components.month ?? 1
        )
        let directory = rootDirectory
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        let highest = files.compactMap { file -> Int? in
            guard file.lastPathComponent.hasSuffix(".jsonl.zlib") else {
                return nil
            }
            return Int(file.lastPathComponent.split(separator: ".").first ?? "")
        }.max() ?? 0
        guard highest < Int.max else { throw CocoaError(.fileWriteOutOfSpace) }
        return highest + 1
    }

    private func readingOrder(_ lhs: SensorReading, _ rhs: SensorReading) -> Bool {
        if lhs.sequence != rhs.sequence {
            return (lhs.sequence ?? .max) < (rhs.sequence ?? .max)
        }
        return lhs.timestamp < rhs.timestamp
    }
}

/// Keeps the small piece of state needed to recover an active workout after
/// the iPhone app is terminated or relaunched. Route samples themselves stay
/// in the compressed archive; this store only contains the session envelope.
enum TrackingSessionRecoveryStore {
    private static let key = "active-tracking-session-v1"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: TaptionPlanSharedContainer.appGroupIdentifier) ?? .standard
    }

    static func read() -> TrackingSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TrackingSession.self, from: data)
    }

    static func save(_ session: TrackingSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear() {
        defaults.removeObject(forKey: key)
    }
}

actor RawDeviceDataDayArchive {
    private static let domain = "raw-device-data"
    private static let decodeBatchSize = 128
    private enum Error: Swift.Error {
        case invalidEnvelope
    }
    private let store: TaptionPlanDayStore
    private let legacyDecoder: JSONDecoder
    private let writeLockURL: URL
    private var dataDeletionGeneration: UInt64

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        store = try TaptionPlanDayStore(url: databaseURL)
        legacyDecoder = JSONDecoder()
        legacyDecoder.dateDecodingStrategy = .secondsSince1970
        writeLockURL = databaseURL.appendingPathExtension("lock")
        dataDeletionGeneration = TaptionDataDeletionFence.currentGeneration()
    }

    static func applicationSupport() throws -> RawDeviceDataDayArchive {
        try RawDeviceDataDayArchive(
            databaseURL: TaptionLocalDatabaseLocation
                .sharedOrApplicationSupport()
        )
    }

    func append(_ envelope: RawDeviceDataEnvelope) async throws {
        try await append([envelope])
    }

    func append(_ envelopes: [RawDeviceDataEnvelope]) async throws {
        guard !envelopes.isEmpty else { return }
        let generation = dataDeletionGeneration
        let events = try events(for: envelopes)
        try await withProtectedLock { [self] in
            try await self.checkDataGeneration(generation)
            try await self.store.appendUniqueEvents(events)
        }
    }

    func appendForRestore(
        _ envelopes: [RawDeviceDataEnvelope]
    ) async throws -> [UUID] {
        guard !envelopes.isEmpty else { return [] }
        let generation = dataDeletionGeneration
        let events = try events(for: envelopes)
        return try await withProtectedLock { [self] in
            try await self.checkDataGeneration(generation)
            let inserted = try await self.store.appendUniqueEventIdentifiers(events)
            return inserted.compactMap { UUID(uuidString: $0.rawValue) }
        }
    }

    func rollbackRestore(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let generation = dataDeletionGeneration
        try await withProtectedLock { [self] in
            try await self.checkDataGeneration(generation)
            try await self.store.deleteEvents(
                ids: ids.map(\.uuidString),
                domain: Self.domain
            )
        }
    }

    func validateAppend(_ envelopes: [RawDeviceDataEnvelope]) async throws {
        guard !envelopes.isEmpty else { return }
        let generation = dataDeletionGeneration
        let events = try events(for: envelopes)
        try await withProtectedLock { [self] in
            try await self.checkDataGeneration(generation)
            try await self.store.validateUniqueEvents(events)
        }
    }

    func envelopes(in span: TimeSpan) async throws
        -> [RawDeviceDataEnvelope] {
        let generation = dataDeletionGeneration
        let events = try await withProtectedLock { [self] in
            try await self.checkDataGeneration(generation)
            return try await self.store.events(
                from: TaptionPlanDayKey(date: span.start),
                through: TaptionPlanDayKey(date: span.end),
                domain: Self.domain
            )
        }
        return try await decodedEnvelopes(
            events,
            generation: generation
        ).filter {
            span.contains($0.capturedAt)
        }
    }

    func allEnvelopes() async throws -> [RawDeviceDataEnvelope] {
        let generation = dataDeletionGeneration
        let events = try await withProtectedLock { [self] in
            try await self.checkDataGeneration(generation)
            return try await self.store.allEvents(domain: Self.domain)
        }
        return try await decodedEnvelopes(events, generation: generation)
    }

    private func decodedEnvelopes(
        _ events: [TaptionPlanDayStore.Event],
        generation: UInt64
    ) async throws -> [RawDeviceDataEnvelope] {
        var values: [RawDeviceDataEnvelope] = []
        var repairs: [TaptionPlanDayStore.Event] = []
        for (index, event) in events.enumerated() {
            if index > 0, index.isMultiple(of: Self.decodeBatchSize) {
                _ = await Task.yield()
            }
            if index.isMultiple(of: Self.decodeBatchSize) {
                try Task.checkCancellation()
                try checkDataGeneration(generation)
            }
            if let encoded = try? TaptionPlanCanonicalStorage.encodedPayload(
                from: event.payload
            ), let value = try? TaptionPlanCanonicalStorage.decode(
                RawDeviceDataEnvelope.self,
                from: encoded
            ), value.hasValidPayload {
                values.append(value)
                continue
            }
            guard let value = try? legacyDecoder.decode(
                RawDeviceDataEnvelope.self,
                from: event.payload
            ), value.hasValidPayload,
                  value.id.uuidString == event.id else {
                throw Error.invalidEnvelope
            }
            values.append(value)
            repairs.append(.init(
                day: event.day,
                timestamp: event.timestamp,
                sequence: event.sequence,
                id: event.id,
                domain: event.domain,
                payload: TaptionPlanCanonicalStorage.envelope(
                    for: try TaptionPlanCanonicalStorage.encode(value)
                )
            ))
        }
        if !repairs.isEmpty {
            let repairedEvents = repairs
            let repairIDs = Set(repairedEvents.map(\.id))
            let expectedEvents = events.filter { repairIDs.contains($0.id) }
            do {
                let repairedIDs = try await withProtectedLock { [self] in
                    try await self.checkDataGeneration(generation)
                    return try await self.store.upsertEvents(
                        repairedEvents,
                        onlyIfUnchangedFrom: expectedEvents
                    )
                }
                TaptionPlanDiagnosticsLogger.shared.record(
                    "raw_device_archive_repaired",
                    fields: ["count": String(repairedIDs.count)]
                )
            } catch {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "raw_device_archive_repair_failed",
                    level: .error,
                    fields: TaptionDiagnosticError.compactFields(for: error)
                )
            }
        }
        try Task.checkCancellation()
        try checkDataGeneration(generation)
        return values
    }

    private func withProtectedLock<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let lockURL = writeLockURL
        return try await TaptionRepositoryBackgroundExecution.run {
            let lock = try await TaptionDataFileLock.acquire(url: lockURL)
            defer { lock.unlock() }
            return try await operation()
        }
    }

    private func events(
        for envelopes: [RawDeviceDataEnvelope]
    ) throws -> [TaptionPlanDayStore.Event] {
        guard envelopes.allSatisfy(\.hasValidPayload) else {
            throw Error.invalidEnvelope
        }
        var uniqueByID: [UUID: RawDeviceDataEnvelope] = [:]
        for envelope in envelopes {
            if let existing = uniqueByID[envelope.id], existing != envelope {
                throw TaptionPlanDayStoreError.eventConflict(
                    id: envelope.id.uuidString
                )
            }
            uniqueByID[envelope.id] = envelope
        }
        return try uniqueByID.values.map { envelope in
            TaptionPlanDayStore.Event(
                day: TaptionPlanDayKey(date: envelope.capturedAt),
                timestamp: envelope.capturedAt,
                sequence: 0,
                id: envelope.id.uuidString,
                domain: Self.domain,
                payload: TaptionPlanCanonicalStorage.envelope(
                    for: try TaptionPlanCanonicalStorage.encode(envelope)
                )
            )
        }
    }

    func checkpoint() async throws {
        let generation = dataDeletionGeneration
        try await withProtectedLock { [self] in
            try await self.checkDataGeneration(generation)
            try await self.store.checkpoint()
        }
    }

    func deleteAll(generation: UInt64? = nil) async throws {
        let nextGeneration = generation
            ?? TaptionDataDeletionFence.currentGeneration()
        try await withProtectedLock { [self] in
            try await self.deleteProtected(generation: nextGeneration)
        }
    }

    private func deleteProtected(generation: UInt64) async throws {
        dataDeletionGeneration = generation
        try await store.deleteEvents(domain: Self.domain)
    }

    private func checkDataGeneration(_ generation: UInt64) throws {
        guard generation == dataDeletionGeneration,
              TaptionDataDeletionFence.allows(generation: generation) else {
            throw CancellationError()
        }
    }
}

actor SensorReadingArchive {
    private static let decodeBatchSize = 128
    private static let migrationBatchSize = 256

    private struct RecoveryCache {
        var legacy: [UUID: SensorReading]?
        var raw: [UUID: SensorReading]?
        var tracking: [UUID: SensorReading]?
    }

    private enum Error: Swift.Error {
        case dayStoreUnavailable
        case invalidReading
        case conflictingReading
        case incompleteArchive
    }

    private static let migrationKey = "sensor-reading-v1-to-day-store-v2"
    private let fileURL: URL
    private let dayStore: TaptionPlanDayStore?
    private let retentionInterval: TimeInterval
    private let legacyDecoder: JSONDecoder
    private let rawArchive: RawDeviceDataMonthlyArchive?
    private let trackingChunkArchive: TrackingSessionChunkArchive?
    private let writeLockURL: URL
    private let afterDecodeBatch: @Sendable (Int) async -> Void
    private let beforeRepairWrite: @Sendable () async -> Void
    private let beforeValidateAppend: @Sendable () async throws -> Void
    private var dataDeletionGeneration: UInt64

    init(
        fileURL: URL,
        retentionInterval: TimeInterval = 7 * 86_400,
        rawArchive: RawDeviceDataMonthlyArchive? = nil,
        trackingChunkArchive: TrackingSessionChunkArchive? = nil,
        dayStoreURL: URL? = nil,
        afterDecodeBatch: @escaping @Sendable (Int) async -> Void = { _ in
            _ = await Task.yield()
        },
        beforeRepairWrite: @escaping @Sendable () async -> Void = {},
        beforeValidateAppend: @escaping @Sendable () async throws -> Void = {}
    ) throws {
        self.fileURL = fileURL
        self.retentionInterval = max(86_400, retentionInterval)
        self.rawArchive = rawArchive
        self.trackingChunkArchive = trackingChunkArchive
        self.afterDecodeBatch = afterDecodeBatch
        self.beforeRepairWrite = beforeRepairWrite
        self.beforeValidateAppend = beforeValidateAppend
        let storeURL = dayStoreURL ?? fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("taption-plan-v2.sqlite")
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.dayStore = try TaptionPlanDayStore(url: storeURL)
        self.writeLockURL = storeURL.appendingPathExtension("lock")
        self.dataDeletionGeneration = TaptionDataDeletionFence.currentGeneration()
        self.legacyDecoder = JSONDecoder()
        legacyDecoder.dateDecodingStrategy = .secondsSince1970
    }

    static func applicationSupport(
        fileManager: FileManager = .default,
        rawArchive: RawDeviceDataMonthlyArchive? = nil
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
        let storeRoot = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: TaptionPlanSharedContainer.appGroupIdentifier
        ) ?? root.appendingPathComponent("TaptionPlan", isDirectory: true)
        let storeURL = storeRoot.appendingPathComponent(
            "taption-data-v2.sqlite",
            isDirectory: false
        )
        return try SensorReadingArchive(
            fileURL: directory.appendingPathComponent("sensor-readings-v1.jsonl"),
            rawArchive: rawArchive
                ?? (try? RawDeviceDataMonthlyArchive.applicationSupport()),
            trackingChunkArchive: try? TrackingSessionChunkArchive.applicationSupport(),
            dayStoreURL: storeURL
        )
    }

    func append(_ reading: SensorReading, now: Date = .now) async throws {
        try await append([reading], now: now)
    }

    func append(_ readings: [SensorReading], now: Date = .now) async throws {
        guard !readings.isEmpty else { return }
        let generation = dataDeletionGeneration
        try await ensureMigrated(generation: generation)
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration(generation)
        guard let dayStore else { throw Error.dayStoreUnavailable }
        try await dayStore.appendUniqueEvents(events(for: readings))
        _ = now
    }

    func appendForRestore(_ readings: [SensorReading]) async throws -> [UUID] {
        guard !readings.isEmpty else { return [] }
        let generation = dataDeletionGeneration
        try await ensureMigrated(generation: generation)
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration(generation)
        guard let dayStore else { throw Error.dayStoreUnavailable }
        let inserted = try await dayStore.appendUniqueEventIdentifiers(
            events(for: readings)
        )
        return inserted.compactMap { UUID(uuidString: $0.rawValue) }
    }

    func rollbackRestore(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let generation = dataDeletionGeneration
        try await ensureMigrated(generation: generation)
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration(generation)
        guard let dayStore else { throw Error.dayStoreUnavailable }
        try await dayStore.deleteEvents(
            ids: ids.map(\.uuidString),
            domain: "sensor-reading"
        )
    }

    func validateAppend(_ readings: [SensorReading]) async throws {
        guard !readings.isEmpty else { return }
        let generation = dataDeletionGeneration
        try await ensureMigrated(generation: generation)
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        try checkDataGeneration(generation)
        guard let dayStore else { throw Error.dayStoreUnavailable }
        try await beforeValidateAppend()
        try await dayStore.validateUniqueEvents(events(for: readings))
    }

    private func events(
        for readings: [SensorReading]
    ) throws -> [TaptionPlanDayStore.Event] {
        var readingsByID: [UUID: SensorReading] = [:]
        for reading in readings {
            if let existing = readingsByID[reading.id], existing != reading {
                throw Error.conflictingReading
            }
            readingsByID[reading.id] = reading
        }
        return try readingsByID.values.map { reading in
            TaptionPlanDayStore.Event(
                day: TaptionPlanDayKey(date: reading.timestamp),
                timestamp: reading.timestamp,
                sequence: UInt64(max(0, reading.sequence ?? 0)),
                id: reading.id.uuidString,
                domain: "sensor-reading",
                payload: TaptionPlanCanonicalStorage.envelope(
                    for: try TaptionPlanCanonicalStorage.encode(reading)
                )
            )
        }
    }

    func readings(in span: TimeSpan) async throws -> [SensorReading] {
        try await readingsLoadResult(in: span).readings
    }

    func readingsLoadResult(
        in span: TimeSpan
    ) async throws -> (readings: [SensorReading], isComplete: Bool) {
        let generation = dataDeletionGeneration
        let result = try await loadEvents(in: span, generation: generation)
        return (result.readings.sorted(by: readingOrder), result.isComplete)
    }

    func routeReadings(in span: TimeSpan) async throws -> [SensorReading] {
        try await routeReadingsLoadResult(in: span).readings
    }

    func routeReadingsLoadResult(
        in span: TimeSpan
    ) async throws -> (readings: [SensorReading], isComplete: Bool) {
        let generation = dataDeletionGeneration
        let result = try await loadEvents(in: span, generation: generation)
        return (result.readings.sorted(by: readingOrder), result.isComplete)
    }

    func allReadings() async throws -> [SensorReading] {
        try await allReadingsLoadResult().readings
    }

    func allReadingsForMigration() async throws -> [SensorReading] {
        let result = try await allReadingsLoadResult()
        guard result.isComplete else { throw Error.incompleteArchive }
        return result.readings
    }

    private func allReadingsLoadResult() async throws
        -> (readings: [SensorReading], isComplete: Bool) {
        let generation = dataDeletionGeneration
        guard let dayStore else { throw Error.dayStoreUnavailable }
        try await ensureMigrated(generation: generation)
        let events = try await withProtectedLock { [self] in
            try await self.checkDataGeneration(generation)
            return try await dayStore.allEvents(domain: "sensor-reading")
        }
        let decoded = try await decodeReadings(
            events,
            generation: generation
        )
        try Task.checkCancellation()
        try checkDataGeneration(generation)
        await persistRepairs(
            decoded.repairs,
            expectedEvents: events,
            to: dayStore,
            generation: generation
        )
        try Task.checkCancellation()
        try checkDataGeneration(generation)
        return (
            decoded.readings.sorted(by: readingOrder),
            decoded.isComplete
        )
    }

    func compact(now: Date = .now) async throws {
        _ = now
        let generation = dataDeletionGeneration
        try await ensureMigrated(generation: generation)
        try checkDataGeneration(generation)
    }

    func deleteAll(generation: UInt64? = nil) async throws {
        let lock = try await TaptionDataFileLock.acquire(url: writeLockURL)
        defer { lock.unlock() }
        dataDeletionGeneration = generation
            ?? TaptionDataDeletionFence.currentGeneration()
        guard let dayStore else { throw Error.dayStoreUnavailable }
        try await dayStore.deleteEvents(domain: "sensor-reading")
        try rawArchive?.deleteAll()
        try trackingChunkArchive?.deleteAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func checkDataGeneration(_ generation: UInt64) throws {
        guard generation == dataDeletionGeneration,
              TaptionDataDeletionFence.allows(generation: generation) else {
            throw CancellationError()
        }
    }

    func rawEnvelopes(inMonthContaining date: Date) async throws
        -> [RawDeviceDataEnvelope] {
        guard let rawArchive else { return [] }
        return try rawArchive.envelopes(inMonthContaining: date)
    }

    private func ensureMigrated(generation: UInt64) async throws {
        guard let dayStore else { throw Error.dayStoreUnavailable }
        let isComplete = try await withProtectedLock { [self] in
            try Task.checkCancellation()
            try await self.checkDataGeneration(generation)
            return try await dayStore.migrationCompleted(Self.migrationKey)
        }
        guard !isComplete else { return }
        try Task.checkCancellation()
        try checkDataGeneration(generation)
        guard try await migrateLegacyJSONL(generation: generation) else {
            return
        }
        if let rawArchive {
            guard try await rawArchive.forEachSensorReadingBatch(
                size: Self.migrationBatchSize,
                visit: { [self] batch in
                    try await self.appendMigrationBatch(
                        batch,
                        generation: generation
                    )
                }
            ) else { return }
        }
        if let trackingChunkArchive {
            guard try await trackingChunkArchive.forEachPersistedReadingBatch(
                size: Self.migrationBatchSize,
                visit: { [self] batch in
                    try await self.appendMigrationBatch(
                        batch,
                        generation: generation
                    )
                }
            ) else { return }
        }
        try await withProtectedLock { [self] in
            try Task.checkCancellation()
            try await self.checkDataGeneration(generation)
            if try await dayStore.migrationCompleted(Self.migrationKey) { return }
            _ = try await dayStore.markMigrationCompleted(Self.migrationKey)
        }
    }

    private func migrateLegacyJSONL(generation: UInt64) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return true
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var line = Data()
        var batch: [SensorReading] = []
        batch.reserveCapacity(Self.migrationBatchSize)

        func appendLine() throws {
            batch.append(try legacyDecoder.decode(SensorReading.self, from: line))
            line.removeAll(keepingCapacity: true)
        }

        func flushBatch() async throws -> Bool {
            guard !batch.isEmpty else { return true }
            let shouldContinue = try await appendMigrationBatch(
                batch,
                generation: generation
            )
            batch.removeAll(keepingCapacity: true)
            if shouldContinue { _ = await Task.yield() }
            return shouldContinue
        }

        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            try checkDataGeneration(generation)
            for byte in chunk {
                if byte == 0x0A {
                    try appendLine()
                    if batch.count == Self.migrationBatchSize {
                        guard try await flushBatch() else { return false }
                    }
                } else {
                    line.append(byte)
                }
            }
        }
        if !line.isEmpty {
            try appendLine()
        }
        return try await flushBatch()
    }

    private func appendMigrationBatch(
        _ readings: [SensorReading],
        generation: UInt64
    ) async throws -> Bool {
        guard let dayStore else { throw Error.dayStoreUnavailable }
        guard !readings.isEmpty else { return true }
        let events = try readings.map { reading in
            TaptionPlanDayStore.Event(
                day: TaptionPlanDayKey(date: reading.timestamp),
                timestamp: reading.timestamp,
                sequence: UInt64(max(0, reading.sequence ?? 0)),
                id: reading.id.uuidString,
                domain: "sensor-reading",
                payload: TaptionPlanCanonicalStorage.envelope(
                    for: try TaptionPlanCanonicalStorage.encode(reading)
                )
            )
        }
        return try await withProtectedLock { [self] in
            try Task.checkCancellation()
            try await self.checkDataGeneration(generation)
            if try await dayStore.migrationCompleted(Self.migrationKey) {
                return false
            }
            do {
                try await dayStore.appendUniqueEvents(events)
            } catch let error as TaptionPlanDayStoreError {
                guard case .eventConflict(id: _) = error else { throw error }
                throw Error.conflictingReading
            }
            return true
        }
    }

    private func loadEvents(
        in span: TimeSpan,
        generation: UInt64
    ) async throws -> (readings: [SensorReading], isComplete: Bool) {
        guard let dayStore else { throw Error.dayStoreUnavailable }
        try await ensureMigrated(generation: generation)
        let events = try await withProtectedLock { [self] in
            try await self.checkDataGeneration(generation)
            let loaded = try await dayStore.events(
                from: TaptionPlanDayKey(date: span.start),
                through: TaptionPlanDayKey(date: span.end),
                domain: "sensor-reading"
            )
            return loaded.filter { span.contains($0.timestamp) }
        }
        let decoded = try await decodeReadings(
            events,
            generation: generation
        )
        try Task.checkCancellation()
        try checkDataGeneration(generation)
        await persistRepairs(
            decoded.repairs,
            expectedEvents: events,
            to: dayStore,
            generation: generation
        )
        try Task.checkCancellation()
        try checkDataGeneration(generation)
        return (
            decoded.readings.filter { span.contains($0.timestamp) },
            decoded.isComplete
        )
    }

    private func decodeReadings(
        _ events: [TaptionPlanDayStore.Event],
        generation: UInt64
    ) async throws -> (
        readings: [SensorReading],
        repairs: [TaptionPlanDayStore.Event],
        isComplete: Bool
    ) {
        var readings: [SensorReading] = []
        var repairs: [TaptionPlanDayStore.Event] = []
        var recovery = RecoveryCache()
        var recoveryCounts: [String: Int] = [:]
        var invalidCount = 0
        var firstErrorFields: [String: String] = [:]
        for (index, event) in events.enumerated() {
            if index > 0, index.isMultiple(of: Self.decodeBatchSize) {
                await afterDecodeBatch(index)
            }
            if index.isMultiple(of: Self.decodeBatchSize) {
                try Task.checkCancellation()
                try checkDataGeneration(generation)
            }
            do {
                let encoded = try TaptionPlanCanonicalStorage.encodedPayload(
                    from: event.payload
                )
                readings.append(try TaptionPlanCanonicalStorage.decode(
                    SensorReading.self,
                    from: encoded
                ))
            } catch {
                invalidCount += 1
                if firstErrorFields.isEmpty {
                    firstErrorFields = TaptionDiagnosticError.compactFields(
                        for: error
                    )
                }
                let recovered: (reading: SensorReading, source: String)?
                if let reading = try? legacyDecoder.decode(
                    SensorReading.self,
                    from: event.payload
                ), reading.id.uuidString == event.id {
                    recovered = (reading, "inline_legacy")
                } else {
                    recovered = try recoveryReading(
                        for: event.id,
                        cache: &recovery
                    )
                }
                guard let recovered else {
                    recoveryCounts["unavailable", default: 0] += 1
                    continue
                }
                recoveryCounts[recovered.source, default: 0] += 1
                readings.append(recovered.reading)
                if let encoded = try? TaptionPlanCanonicalStorage.encode(
                    recovered.reading
                ) {
                    repairs.append(.init(
                        day: event.day,
                        timestamp: event.timestamp,
                        sequence: event.sequence,
                        id: event.id,
                        domain: event.domain,
                        payload: TaptionPlanCanonicalStorage.envelope(
                            for: encoded
                        )
                    ))
                }
            }
        }
        try Task.checkCancellation()
        try checkDataGeneration(generation)
        if invalidCount > 0 {
            var fields = firstErrorFields
            fields["invalid_count"] = String(invalidCount)
            fields["raw_preserved"] = "true"
            for (source, count) in recoveryCounts {
                fields["recovered_\(source)"] = String(count)
            }
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_archive_invalid_reading",
                level: recoveryCounts["unavailable", default: 0] > 0
                    ? .error
                    : .notice,
                fields: fields
            )
        }
        return (
            readings,
            repairs,
            recoveryCounts["unavailable", default: 0] == 0
        )
    }

    private func persistRepairs(
        _ events: [TaptionPlanDayStore.Event],
        expectedEvents: [TaptionPlanDayStore.Event],
        to dayStore: TaptionPlanDayStore,
        generation: UInt64
    ) async {
        guard !events.isEmpty else { return }
        let repairIDs = Set(events.map(\.id))
        let repairSourceEvents = expectedEvents.filter {
            repairIDs.contains($0.id)
        }
        do {
            await beforeRepairWrite()
            let repairedIDs = try await withProtectedLock { [self] in
                try await self.checkDataGeneration(generation)
                return try await dayStore.upsertEvents(
                    events,
                    onlyIfUnchangedFrom: repairSourceEvents
                )
            }
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_archive_repaired",
                fields: ["count": String(repairedIDs.count)]
            )
        } catch {
            guard !(error is CancellationError) else { return }
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_archive_repair_failed",
                level: .error,
                fields: TaptionDiagnosticError.compactFields(for: error)
            )
        }
    }

    private func withProtectedLock<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let lockURL = writeLockURL
        return try await TaptionRepositoryBackgroundExecution.run {
            let lock = try await TaptionDataFileLock.acquire(url: lockURL)
            defer { lock.unlock() }
            return try await operation()
        }
    }

    private func recoveryReading(
        for eventID: String,
        cache: inout RecoveryCache
    ) throws -> (reading: SensorReading, source: String)? {
        guard let id = UUID(uuidString: eventID) else { return nil }
        if cache.legacy == nil {
            cache.legacy = try legacyReadingsByID()
        }
        if let reading = cache.legacy?[id] {
            return (reading, "legacy")
        }
        if cache.raw == nil {
            let readings = rawArchive.flatMap { try? $0.sensorReadings() } ?? []
            cache.raw = Dictionary(
                readings.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        if let reading = cache.raw?[id] {
            return (reading, "raw")
        }
        if cache.tracking == nil {
            let readings = trackingChunkArchive.flatMap {
                try? $0.allPersistedReadings()
            } ?? []
            cache.tracking = Dictionary(
                readings.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        if let reading = cache.tracking?[id] {
            return (reading, "tracking")
        }
        return nil
    }

    private func legacyReadingsByID() throws -> [UUID: SensorReading] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var line = Data()
        var readings: [UUID: SensorReading] = [:]
        func inspectLine() {
            if let reading = try? legacyDecoder.decode(
                SensorReading.self,
                from: line
            ) {
                readings[reading.id] = reading
            }
            line.removeAll(keepingCapacity: true)
        }
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            for byte in chunk {
                if byte == 0x0A {
                    inspectLine()
                } else {
                    line.append(byte)
                }
            }
        }
        if !line.isEmpty { inspectLine() }
        return readings
    }

    private func readingOrder(_ lhs: SensorReading, _ rhs: SensorReading) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.sequence != rhs.sequence { return (lhs.sequence ?? .max) < (rhs.sequence ?? .max) }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

@MainActor
final class AppleSensorDataService {
    private static let persistenceBatchSize = 5
    private static let persistenceBatchDelay: Duration = .seconds(5)
    private static let logger = Logger(
        subsystem: "com.taption.plan",
        category: "SensorArchive"
    )
    private let collector: AppleSensorCollector
    private let archive: SensorReadingArchive
    private let history: AppleMotionHistoryService
    private let streamFactory:
        ((SensorCollectionConfiguration) -> AsyncStream<SensorReading>)?
    private let appendReadings: ([SensorReading]) async throws -> Void
    private let archivedReadingsLoader:
        (TimeSpan) async throws -> [SensorReading]
    private var collectionTask: Task<Void, Never>?
    private var activeConfiguration: SensorCollectionConfiguration?
    private var collectionGeneration = 0
    private var isCollectionStreamLive = false
    private var isDataDeletionActive = false
    private var persistedReadingCount = 0
    private var lastPersistedReadingAt: Date?
    private var pendingReadings: [SensorReading] = []
    private var inFlightReadings: [SensorReading] = []
    private var inFlightGeneration: Int?
    private var pendingFlushTask: Task<Void, Never>?
    private var trailingFlushTask: Task<Void, Never>?
    private var lastFlushedCollectionGeneration: Int?

    private(set) var lastPersistenceErrorDescription: String?
    var onReadingsPersisted: (([SensorReading]) -> Void)?
    var onPersistenceFailed: ((String) -> Void)?

    init(
        collector: AppleSensorCollector? = nil,
        archive: SensorReadingArchive,
        history: AppleMotionHistoryService = AppleMotionHistoryService(),
        streamFactory:
            ((SensorCollectionConfiguration) -> AsyncStream<SensorReading>)? = nil,
        appendReadings:
            (([SensorReading]) async throws -> Void)? = nil,
        archivedReadingsLoader:
            ((TimeSpan) async throws -> [SensorReading])? = nil
    ) {
        self.collector = collector ?? AppleSensorCollector()
        self.archive = archive
        self.history = history
        self.streamFactory = streamFactory
        self.appendReadings = appendReadings ?? { readings in
            try await archive.append(readings)
        }
        self.archivedReadingsLoader = archivedReadingsLoader ?? { span in
            try await archive.readings(in: span)
        }
    }

    static func applicationSupport(
        rawArchive: RawDeviceDataMonthlyArchive? = nil
    ) throws -> AppleSensorDataService {
        AppleSensorDataService(
            archive: try SensorReadingArchive.applicationSupport(
                rawArchive: rawArchive
            )
        )
    }

    func hardwareAvailability() async -> SensorHardwareAvailability {
        await collector.hardwareAvailability()
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

    func locationAuthorizationStatus() -> CLAuthorizationStatus {
        collector.locationAuthorizationStatus()
    }

    func hasPreciseLocationAuthorization() -> Bool {
        collector.hasPreciseLocationAuthorization()
    }

    func requestLocationPermission(always: Bool = false) {
        collector.requestLocationPermission(always: always)
    }

    func requestMotionPermission() async -> PermissionState {
        await history.requestAuthorization()
    }

    func requestImmediateSample() {
        collector.requestImmediateSample()
    }

    func startCollection(
        configuration: SensorCollectionConfiguration = .standard
    ) {
        guard !isDataDeletionActive else { return }
        let configuration = configuration.normalized
        // A finished stream leaves a completed task behind. Restart in that
        // case, otherwise recording never resumes after the reading stream
        // ends (for example when location permission was revoked).
        if collectionTask != nil,
           isCollectionStreamLive,
           activeConfiguration == configuration {
            return
        }
        let previousCollectionTask = collectionTask
        stopCollection()
        let previousFlushTask = trailingFlushTask
        activeConfiguration = configuration
        collectionGeneration += 1
        let generation = collectionGeneration
        isCollectionStreamLive = true
        TaptionPlanDiagnosticsLogger.shared.record(
            "sensor_collection_started",
            fields: [
                "generation": String(generation),
                "minimum_interval": String(
                    configuration.minimumEmissionInterval
                ),
                "background_location": String(
                    configuration.allowsBackgroundLocation
                ),
            ]
        )
        let stream = streamFactory?(configuration)
            ?? collector.readings(configuration: configuration)
        collectionTask = Task { [weak self] in
            await previousCollectionTask?.value
            await previousFlushTask?.value
            for await reading in stream {
                guard !Task.isCancelled, let self,
                      self.collectionGeneration == generation else { break }
                guard await self.enqueue(reading, generation: generation) else {
                    return
                }
            }
            guard let self, self.collectionGeneration == generation else {
                return
            }
            self.isCollectionStreamLive = false
            self.collectionTask = nil
            self.activeConfiguration = nil
            TaptionPlanDiagnosticsLogger.shared.record(
                "sensor_collection_stream_ended",
                level: .notice,
                fields: [
                    "generation": String(generation),
                    "last_persisted_at": self.lastPersistedReadingAt.map {
                        String($0.timeIntervalSince1970)
                    } ?? "none",
                ]
            )
        }
    }

    /// Returns a monotonic token for waiting on the next archived sample.
    /// Background refresh uses this instead of assuming that a sampling window
    /// elapsed means the archive consumer finished its write.
    func persistenceToken() -> Int {
        persistedReadingCount
    }

    func latestPersistedReadingDate() -> Date? {
        lastPersistedReadingAt
    }

    func isCollectionLive() -> Bool {
        isCollectionStreamLive
    }

    func waitForPersistedReading(
        after token: Int,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date.now.addingTimeInterval(max(0, timeout))
        while !Task.isCancelled, Date.now < deadline {
            if persistedReadingCount > token {
                return true
            }
            if !isCollectionStreamLive {
                return false
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return persistedReadingCount > token
    }

    func stopCollection() {
        let generation = collectionGeneration
        let activeTask = collectionTask
        let activeFlushTask = pendingFlushTask
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        collectionGeneration += 1
        isCollectionStreamLive = false
        collectionTask?.cancel()
        collectionTask = nil
        activeConfiguration = nil
        collector.stop()
        guard (!pendingReadings.isEmpty || !inFlightReadings.isEmpty),
              !isDataDeletionActive else { return }
        let previous = trailingFlushTask
        trailingFlushTask = Task { [weak self] in
            await previous?.value
            await activeTask?.value
            await activeFlushTask?.value
            guard let self else { return }
            var saved = false
            for attempt in 0..<3 where !Task.isCancelled {
                saved = await self.flushPendingReadings(generation: generation)
                if saved || self.isDataDeletionActive { break }
                if attempt < 2 {
                    try? await Task.sleep(for: .seconds(1 << attempt))
                }
            }
        }
    }

    func stopCollectionAndWait() async {
        let pending = collectionTask
        let pendingFlush = pendingFlushTask
        stopCollection()
        let trailing = trailingFlushTask
        await pending?.value
        await pendingFlush?.value
        await trailing?.value
    }

    func prepareForDataDeletion() async {
        isDataDeletionActive = true
        await stopCollectionAndWait()
        pendingReadings.removeAll(keepingCapacity: true)
    }

    func finishDataDeletion() {
        isDataDeletionActive = false
    }

    private func enqueue(
        _ reading: SensorReading,
        generation: Int
    ) async -> Bool {
        pendingReadings.append(reading)
        guard inFlightReadings.isEmpty else { return true }
        if lastFlushedCollectionGeneration != generation
            || pendingReadings.count >= Self.persistenceBatchSize
            || reading.trackingSessionEnded == true {
            return await flushPendingReadings(generation: generation)
        }
        schedulePendingFlush(generation: generation)
        return true
    }

    private func flushPendingReadings(generation: Int) async -> Bool {
        guard inFlightReadings.isEmpty else { return true }
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        let readings = pendingReadings
        guard !readings.isEmpty else { return true }
        inFlightReadings = readings
        inFlightGeneration = generation
        let saved = await persist(readings, generation: generation)
        if inFlightGeneration == generation {
            if saved {
                pendingReadings.removeFirst(
                    min(readings.count, pendingReadings.count)
                )
            }
            inFlightReadings.removeAll(keepingCapacity: true)
            inFlightGeneration = nil
        }
        if !saved,
           collectionGeneration == generation,
           !isDataDeletionActive {
            stopCollection()
        }
        guard saved,
              collectionGeneration == generation,
              !pendingReadings.isEmpty else { return saved }
        if pendingReadings.count >= Self.persistenceBatchSize
            || pendingReadings.contains(where: { $0.trackingSessionEnded == true }) {
            return await flushPendingReadings(generation: generation)
        }
        schedulePendingFlush(generation: generation)
        return true
    }

    private func schedulePendingFlush(generation: Int) {
        guard pendingFlushTask == nil,
              inFlightReadings.isEmpty,
              !pendingReadings.isEmpty else { return }
        pendingFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.persistenceBatchDelay)
            guard !Task.isCancelled,
                  let self,
                  self.collectionGeneration == generation else { return }
            self.pendingFlushTask = nil
            _ = await self.flushPendingReadings(generation: generation)
        }
    }

    private func persist(
        _ readings: [SensorReading],
        generation: Int
    ) async -> Bool {
        guard !readings.isEmpty else { return true }
        do {
            try await appendReadings(readings)
            guard !isDataDeletionActive else { return false }
            persistedReadingCount += readings.count
            if let latest = readings.map(\.timestamp).max() {
                lastPersistedReadingAt = max(
                    lastPersistedReadingAt ?? latest,
                    latest
                )
            }
            lastPersistenceErrorDescription = nil
            if collectionGeneration == generation {
                lastFlushedCollectionGeneration = generation
            }
            onReadingsPersisted?(readings)
            return true
        } catch {
            guard !isDataDeletionActive else { return false }
            let description = error.localizedDescription
            if lastPersistenceErrorDescription != description {
                TaptionPlanDiagnosticsLogger.shared.record(
                    "sensor_archive_append_failed",
                    level: .error,
                    fields: TaptionDiagnosticError.fields(for: error)
                )
            }
            lastPersistenceErrorDescription = description
            Self.logger.error(
                "Sensor archive append failed: \(error.localizedDescription, privacy: .public)"
            )
            if collectionGeneration == generation {
                onPersistenceFailed?(description)
            }
            return false
        }
    }

    @discardableResult
    func beginTracking(
        kind: TrackingKind,
        linkedPlanID: UUID? = nil,
        sessionID: UUID = UUID(),
        preferences: GPSLoggingPreferences = .standard
    ) -> TrackingSession {
        collector.beginTracking(
            kind: kind,
            linkedPlanID: linkedPlanID,
            sessionID: sessionID,
            preferences: preferences
        )
    }

    @discardableResult
    func resumeTracking(
        _ session: TrackingSession,
        preferences: GPSLoggingPreferences = .standard
    ) -> TrackingSession {
        collector.resumeTracking(session, preferences: preferences)
    }

    func updateTrackingPreferences(_ preferences: GPSLoggingPreferences) {
        collector.updateTrackingPreferences(preferences)
    }

    /// 층 보정용 기압 표본 묶음. 기록 스트림과 달리 듀티사이클을 기다리지
    /// 않고 그 자리에서 잰다.
    func captureAltitudeBurst(
        count: Int = AltitudeBurstReducer.requestedSampleCount,
        timeout: TimeInterval = 20,
        onProgress: @MainActor (Int) -> Void = { _ in }
    ) async -> [AltitudeBurstSample] {
        await collector.captureAltitudeBurst(
            count: count,
            timeout: timeout,
            onProgress: onProgress
        )
    }

    @discardableResult
    func endTracking() -> TrackingSession? {
        collector.endTracking()
    }

    func archivedReadings(in span: TimeSpan) async throws -> [SensorReading] {
        try await archivedReadingsLoader(span)
    }

    func archivedReadingsLoadResult(
        in span: TimeSpan
    ) async throws -> (readings: [SensorReading], isComplete: Bool) {
        try await archive.readingsLoadResult(in: span)
    }

    func archivedRouteReadings(
        in span: TimeSpan
    ) async throws -> [SensorReading] {
        try await archive.routeReadings(in: span)
    }

    func archivedRouteReadingsLoadResult(
        in span: TimeSpan
    ) async throws -> (readings: [SensorReading], isComplete: Bool) {
        try await archive.routeReadingsLoadResult(in: span)
    }

    func allArchivedRouteReadings() async throws -> [SensorReading] {
        try await archive.allReadingsForMigration()
    }

    func archivedReadings(
        for session: TrackingSession,
        through date: Date = .now
    ) async throws -> [SensorReading] {
        let end = max(session.startedAt, session.endedAt ?? date)
        return try await archive.readings(
            in: TimeSpan(start: session.startedAt, end: end)
        ).filter { $0.trackingSessionID == session.id }
    }

    func archivedRouteReadings(
        for session: TrackingSession,
        through date: Date = .now
    ) async throws -> [SensorReading] {
        let end = max(session.startedAt, session.endedAt ?? date)
        return try await archive.routeReadings(
            in: TimeSpan(start: session.startedAt, end: end)
        ).filter { $0.trackingSessionID == session.id }
    }

    func recordExternalReadings(_ readings: [SensorReading]) async throws {
        guard !isDataDeletionActive else { throw CancellationError() }
        guard let first = readings.min(by: { $0.timestamp < $1.timestamp }),
              let last = readings.max(by: { $0.timestamp < $1.timestamp }) else {
            return
        }
        let existingReadings = try await archive.routeReadings(
                in: TimeSpan(
                    start: first.timestamp.addingTimeInterval(-1),
                    end: last.timestamp.addingTimeInterval(1)
                )
            )
        let existingIDs = Set(existingReadings.map(\.id))
        guard !isDataDeletionActive else { throw CancellationError() }
        let ordered = readings.sorted { $0.timestamp < $1.timestamp }
        try await archive.append(ordered)
        guard !isDataDeletionActive else { throw CancellationError() }
        var notified = Set<UUID>()
        let inserted = ordered.filter {
            !existingIDs.contains($0.id)
                && notified.insert($0.id).inserted
        }
        if !inserted.isEmpty {
            onReadingsPersisted?(inserted)
        }
    }

    func recordExternalReadingsForRestore(
        _ readings: [SensorReading]
    ) async throws -> [UUID] {
        guard !isDataDeletionActive else { throw CancellationError() }
        return try await archive.appendForRestore(
            readings.sorted { $0.timestamp < $1.timestamp }
        )
    }

    func rollbackExternalReadingsRestore(ids: [UUID]) async throws {
        try await archive.rollbackRestore(ids: ids)
    }

    func validateExternalReadings(_ readings: [SensorReading]) async throws {
        guard !isDataDeletionActive else { throw CancellationError() }
        try await archive.validateAppend(readings)
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

    func deleteArchivedReadings(generation: UInt64? = nil) async throws {
        try await archive.deleteAll(generation: generation)
    }
}
