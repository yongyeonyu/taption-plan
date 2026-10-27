import XCTest
import CoreLocation
import WatchConnectivity
import TaptionPlanCore
@testable import TaptionPlan

private struct WatchSummaryHighWaterFixture: Codable {
    let sequence: Int
    let revision: Int
}

final class DataDeletionFenceTestFixture {
    private static let cutoffKey = "TaptionPlan.dataDeletionCutoff"
    private static let activeKey = "TaptionPlan.dataDeletionActive"

    private let defaults: UserDefaults
    private let previousCutoff: Any?
    private let previousActive: Any?

    init() {
        let defaults = UserDefaults(
            suiteName: TaptionPlanSharedContainer.appGroupIdentifier
        ) ?? .standard
        self.defaults = defaults
        previousCutoff = defaults.object(forKey: Self.cutoffKey)
        previousActive = defaults.object(forKey: Self.activeKey)
        defaults.removeObject(forKey: Self.cutoffKey)
        defaults.removeObject(forKey: Self.activeKey)
        defaults.synchronize()
    }

    func restore() {
        if let previousCutoff {
            defaults.set(previousCutoff, forKey: Self.cutoffKey)
        } else {
            defaults.removeObject(forKey: Self.cutoffKey)
        }
        if let previousActive {
            defaults.set(previousActive, forKey: Self.activeKey)
        } else {
            defaults.removeObject(forKey: Self.activeKey)
        }
        defaults.synchronize()
    }
}

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

@MainActor
private final class SensorReadingBuffer {
    var values: [SensorReading] = []
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

private final class WatchDeliveryAcknowledgementProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return identifiers
    }

    func record(_ identifier: String) {
        lock.lock()
        defer { lock.unlock() }
        identifiers.append(identifier)
    }
}

private actor GatedSQLitePlanRepository: PlanDataRepository {
    private let base: TaptionStoreRepository
    private var blocksNextSave = false
    private var saveIsBlocked = false
    private var blockedSave: CheckedContinuation<Void, Never>?

    init(databaseURL: URL) throws {
        base = try TaptionStoreRepository(store: TaptionStoreV2(url: databaseURL))
    }

    func load() async throws -> TaptionDataSnapshot {
        try await base.load()
    }

    func save(_ snapshot: TaptionDataSnapshot) async throws {
        if blocksNextSave {
            blocksNextSave = false
            saveIsBlocked = true
            await withCheckedContinuation { continuation in
                blockedSave = continuation
            }
            saveIsBlocked = false
        }
        try await base.save(snapshot)
    }

    func deleteAll() async throws {
        try await base.deleteAll()
    }

    func blockNextSave() {
        blocksNextSave = true
    }

    func waitUntilSaveIsBlocked() async -> Bool {
        for _ in 0..<500 {
            if saveIsBlocked { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return saveIsBlocked
    }

    func releaseBlockedSave() {
        blocksNextSave = false
        blockedSave?.resume()
        blockedSave = nil
        saveIsBlocked = false
    }
}

private enum SensorAppendError: Error {
    case transient
}

private actor SensorReadCheckpointGate {
    private var didPause = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var reachedContinuation: CheckedContinuation<Void, Never>?

    func pauseOnce() async {
        guard !didPause else { return }
        didPause = true
        await withCheckedContinuation { continuation in
            pauseContinuation = continuation
            reachedContinuation?.resume()
            reachedContinuation = nil
        }
    }

    func waitUntilPaused() async {
        guard !didPause else { return }
        await withCheckedContinuation { continuation in
            reachedContinuation = continuation
        }
    }

    func resume() {
        let continuation = pauseContinuation
        pauseContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class PlanDaySaveValidity {
    var isCurrent = true
    private let rejectAtCheck: Int?
    private let cancelAtCheck: Int?
    private var checkCount = 0

    init(rejectAtCheck: Int? = nil, cancelAtCheck: Int? = nil) {
        self.rejectAtCheck = rejectAtCheck
        self.cancelAtCheck = cancelAtCheck
    }

    func check() -> Bool {
        checkCount += 1
        if checkCount == cancelAtCheck {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return isCurrent && checkCount != rejectAtCheck
    }
}

final class SensorDayStoreTests: XCTestCase {
    func testDirectSensorStoragePreservesEveryFieldAndPortableCodable() throws {
        var value = makeReading(Date(timeIntervalSinceReferenceDate: 800_000_000.125), sequence: Int.max)
        value.point = GeoPoint(latitude: -0.0, longitude: 179.75, altitude: -400.25, horizontalAccuracy: 3.25, verticalAccuracy: -1)
        value.locationFixQuality = .approximate
        value.speedMetersPerSecond = -0.0
        value.speedAccuracyMetersPerSecond = 2.125
        value.courseDegrees = 359.75
        value.courseAccuracyDegrees = -1
        value.motion = .cycling
        value.motionConfidence = .high
        value.relativeAltitudeMeters = -12.125
        value.pressureKilopascals = 99.5
        value.altimeterSessionID = UUID()
        value.floorsAscended = 10
        value.floorsDescended = 3
        value.stepCount = Int.min
        value.walkingRunningDistanceMeters = 1_234.5
        value.currentPaceSecondsPerMeter = 1.25
        value.currentCadenceStepsPerSecond = 3.5
        value.averageActivePaceSecondsPerMeter = 2.75
        value.deviceMotion = .init(gravity: .init(x: 1, y: 2, z: 3), userAcceleration: .init(x: 4, y: 5, z: 6), rotationRate: .init(x: 7, y: 8, z: 9), attitudeRadians: .init(x: 10, y: 11, z: 12), magneticFieldMicroteslas: .init(x: 13, y: 14, z: 15), magneticFieldAccuracy: 16, headingDegrees: 17.25)
        value.deviceMotionSummary = .init(sampleCount: 240, meanUserAccelerationG: 0.1, userAccelerationStandardDeviationG: 0.2, peakUserAccelerationG: 0.3, meanRotationRateRadiansPerSecond: 0.4, rotationRateStandardDeviationRadiansPerSecond: 0.5, peakRotationRateRadiansPerSecond: 0.6)
        value.watchAccelerationAverageG = .init(x: -1, y: -2, z: -3)
        value.watchAccelerationStandardDeviationG = 0.15
        value.watchAccelerationMeanJerkGPerSecond = 0.25
        value.systemFloor = -4
        value.powerState = .charging
        value.screenBrightness = 0.75
        value.screenIsOn = false
        value.gpsAvailable = false
        value.connectedWiFiSSID = "Cafe\u{0301}\0網"
        value.subwayWiFiObservationStreak = 12
        value.nearbyStation = true
        value.nearbyStationName = "역\0🚉"
        value.matchesRailRoute = true
        value.matchesPublicTransitRoute = true
        value.frequentStops = true
        value.rideHailingHint = true
        value.nearAirport = true
        value.nearPort = true
        value.onWater = true
        value.watchWorkoutKind = "walking"
        value.behavior = "stairs"
        value.behaviorConfidenceScore = 0.875
        value.behaviorEvidence = ["", "Cafe\u{0301}", "Café", String(repeating: "근거\0", count: 3_000)]
        value.behaviorModelVersion = "model-v3"
        value.trackingSessionID = UUID()
        value.trackingKind = .automatic
        value.trackingWasAutomaticallyDetected = true
        value.sourceDevice = .appleWatch
        value.trackingSessionEnded = false
        XCTAssertEqual(Mirror(reflecting: value).children.count, 52, "New model fields require a storage format review")
        for reading in [value, SensorReading(timestamp: .distantPast)] {
            let encoded = try TaptionPlanCanonicalStorage.encode(reading)
            let restored = try TaptionPlanCanonicalStorage.decode(SensorReading.self, from: encoded)
            XCTAssertEqual(restored, reading)
            XCTAssertEqual(try restored.storageBytes(), try reading.storageBytes())
            let json = JSONEncoder()
            json.outputFormatting = [.sortedKeys]
            XCTAssertEqual(try json.encode(restored), try json.encode(reading))
            let portable = try TaptionPlanCanonicalStorage.encode([reading])
            XCTAssertEqual(try TaptionPlanCanonicalStorage.decode([SensorReading].self, from: portable), [reading])
        }
        let encoded = try TaptionPlanCanonicalStorage.encode(value)
        XCTAssertTrue(encoded.isCompressed)
        let restored = try TaptionPlanCanonicalStorage.decode(SensorReading.self, from: encoded)
        XCTAssertEqual(restored.point?.latitude.bitPattern, (-0.0 as Double).bitPattern)
        XCTAssertEqual(restored.speedMetersPerSecond?.bitPattern, (-0.0 as Double).bitPattern)
        XCTAssertEqual(restored.connectedWiFiSSID.map { Array($0.utf8) }, value.connectedWiFiSSID.map { Array($0.utf8) })
        XCTAssertEqual(restored.behaviorEvidence?.map { Array($0.utf8) }, value.behaviorEvidence?.map { Array($0.utf8) })
    }

    func testDirectSensorStorageRejectsTruncationFlagsLengthsAndCorruption() throws {
        let reading = SensorReading(timestamp: Date(timeIntervalSinceReferenceDate: 123.25), connectedWiFiSSID: "x", behaviorEvidence: ["evidence"])
        let raw = try reading.storageBytes()
        for count in 0..<raw.count {
            XCTAssertThrowsError(try SensorReading.fromStorageBytes(Data(raw.prefix(count))))
        }
        var trailing = raw
        trailing.append(0)
        XCTAssertThrowsError(try SensorReading.fromStorageBytes(trailing))
        var version = raw
        version[3] = 0x32
        XCTAssertThrowsError(try SensorReading.fromStorageBytes(version))
        // Header(4), UUID(16), timestamp(8), then the point presence tag.
        var badPresence = raw
        badPresence[28] = 2
        XCTAssertThrowsError(try SensorReading.fromStorageBytes(badPresence))
        var badEnum = raw
        badEnum[34] = 255 // Six absent optional fields precede motion.
        XCTAssertThrowsError(try SensorReading.fromStorageBytes(badEnum))
        let evidenceOffset = try XCTUnwrap(raw.range(of: Data("evidence".utf8)))
        var badLength = raw
        badLength.replaceSubrange((evidenceOffset.lowerBound - 4)..<evidenceOffset.lowerBound, with: [255, 255, 255, 255])
        XCTAssertThrowsError(try SensorReading.fromStorageBytes(badLength))
        var badUTF8 = raw
        badUTF8[evidenceOffset.lowerBound] = 255
        XCTAssertThrowsError(try SensorReading.fromStorageBytes(badUTF8))
        let encoded = try TaptionPlanCanonicalStorage.encode(reading, compress: false)
        var corrupt = encoded.data
        corrupt[20] ^= 1
        XCTAssertThrowsError(try TaptionPlanCanonicalStorage.decode(SensorReading.self, from: .init(data: corrupt, checksum: encoded.checksum, uncompressedSize: encoded.uncompressedSize, isCompressed: false))) { error in
            XCTAssertEqual(error as? TaptionPlanCanonicalStorageError, .checksumMismatch)
        }
        let old = try PropertyListEncoder().encode(reading)
        XCTAssertThrowsError(try SensorReading.fromStorageBytes(old))
    }

    func testDirectSensorStorageKeepsAllEnumCasesAndUnusualDoubleBits() throws {
        for motion in MotionKind.allCases {
            for confidence in ConfidenceLevel.allCases {
                for tracking in TrackingKind.allCases {
                    var reading = SensorReading(timestamp: Date(timeIntervalSinceReferenceDate: -0.0), motion: motion, motionConfidence: confidence, trackingKind: tracking)
                    reading.speedMetersPerSecond = Double(bitPattern: 0x7ff8_0000_0000_0042)
                    for power in [DevicePowerState.unknown, .unplugged, .charging, .full] {
                        reading.powerState = power
                        let decoded = try SensorReading.fromStorageBytes(reading.storageBytes())
                        XCTAssertEqual(decoded.motion, motion)
                        XCTAssertEqual(decoded.motionConfidence, confidence)
                        XCTAssertEqual(decoded.trackingKind, tracking)
                        XCTAssertEqual(decoded.powerState, power)
                        XCTAssertEqual(decoded.timestamp.timeIntervalSinceReferenceDate.bitPattern, reading.timestamp.timeIntervalSinceReferenceDate.bitPattern)
                        XCTAssertEqual(decoded.speedMetersPerSecond?.bitPattern, reading.speedMetersPerSecond?.bitPattern)
                    }
                }
            }
        }
    }

    func testSensorArchiveReadWritePerformanceFixture() async throws {
        let fence = DataDeletionFenceTestFixture()
        defer { fence.restore() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DBP1006A01-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("sensor-readings-v1.jsonl")
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let readings = (0..<5_000).map {
            makeReading(date.addingTimeInterval(Double($0) * 5), sequence: $0)
        }
        let span = TimeSpan(start: date, end: date.addingTimeInterval(25_001))
        let archive = try SensorReadingArchive(fileURL: fileURL)
        _ = try await archive.readings(in: span)
        let writeStart = ProcessInfo.processInfo.systemUptime
        try await archive.append(readings)
        let writeMS = (ProcessInfo.processInfo.systemUptime - writeStart) * 1_000
        let reopened = try SensorReadingArchive(fileURL: fileURL)
        var readMS = 0.0
        for _ in 0..<3 {
            let readStart = ProcessInfo.processInfo.systemUptime
            let loaded = try await reopened.readingsLoadResult(in: span)
            readMS += (ProcessInfo.processInfo.systemUptime - readStart) * 1_000 / 3
            XCTAssertTrue(loaded.isComplete)
            XCTAssertEqual(loaded.readings, readings)
        }
        print("DBP1006A01 sensors records=\(readings.count) append_ms=\(writeMS) read_mean_ms=\(readMS)")
        let narrow = TimeSpan(start: date.addingTimeInterval(10_000), end: date.addingTimeInterval(10_005))
        let rangeStart = ProcessInfo.processInfo.systemUptime
        let result = try await reopened.readingsLoadResult(in: narrow)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.readings, Array(readings[2_000...2_001]))
        print("ARC1019A01 sensor_range rows=\(result.readings.count) query_ms=\((ProcessInfo.processInfo.systemUptime - rangeStart) * 1_000)")
    }

    func testSensorRangeIncludesBothEndpointsAndUsesInstantsAcrossLocalMidnight() async throws {
        let fence = DataDeletionFenceTestFixture()
        defer { fence.restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ARC1019A01-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try SensorReadingArchive(fileURL: directory.appendingPathComponent("sensor-readings-v1.jsonl"))
        let midnight = Date(timeIntervalSince1970: 1_792_335_600)  // 2026-10-19 00:00 KST
        let readings = [-2, -1, 0, 1, 2].map { makeReading(midnight.addingTimeInterval(Double($0))) }
        try await archive.append(readings)
        let result = try await archive.readingsLoadResult(
            in: TimeSpan(start: midnight.addingTimeInterval(-1), end: midnight.addingTimeInterval(1))
        )
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.readings.map(\.id), readings[1...3].map(\.id), "양 끝을 포함하고 현지 날짜와 무관하게 시각으로 고른다")
    }

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

    private func makeWatchSummary(
        sessionID: UUID,
        sequence: Int,
        startedAt: Date,
        endedAt: Date,
        isAmbient: Bool = true,
        ambientWindowStart: Date? = nil,
        ambientRevision: Int? = nil,
        behavior: WatchBehaviorKind? = nil,
        routePoints: [TaptionWatchLocationPoint]? = nil
    ) -> TaptionWatchSensorSummary {
        TaptionWatchSensorSummary(
            sessionID: sessionID,
            sequence: sequence,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: startedAt,
            endedAt: endedAt,
            isFinal: false,
            accelerometerSampleCount: 50,
            accelerometerAverageG: nil,
            peakAccelerationG: 1,
            accelerometerStandardDeviationG: 0.1,
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
            activeEnergyKilocalories: nil,
            routePoints: routePoints,
            behavior: behavior,
            isAmbient: isAmbient,
            ambientWindowStart: ambientWindowStart,
            ambientRevision: ambientRevision
        )
    }

    @MainActor
    private func makeWatchSummaryModel(
        directory: URL,
        database: PlanDayDatabase,
        service: AppleWatchConnectivityService,
        snapshot: TaptionDataSnapshot = .empty,
        readingArchive: SensorReadingArchive? = nil,
        repository: (any PlanDataRepository)? = nil
    ) throws -> AppModel {
        let readings: SensorReadingArchive
        if let readingArchive {
            readings = readingArchive
        } else {
            readings = try SensorReadingArchive(
                fileURL: directory.appendingPathComponent("readings.jsonl")
            )
        }
        let rawData = try RawDeviceDataDayArchive(
            databaseURL: directory.appendingPathComponent("raw.sqlite")
        )
        return AppModel(
            repository: repository
                ?? InMemoryPlanRepository(snapshot: snapshot),
            sensorService: AppleSensorDataService(archive: readings),
            cloudSyncService: nil,
            watchConnectivityService: service,
            rawDeviceDataArchive: rawData,
            registersHealthBackgroundHandler: false,
            dayDatabase: database
        )
    }

    private func deliverWatchSummary(
        _ summary: TaptionWatchSensorSummary,
        through service: AppleWatchConnectivityService
    ) throws {
        service.session(WCSession.default, didReceiveUserInfo: [
            TaptionWatchEnvelope.sensorSummaryKey:
                try JSONEncoder().encode(summary),
            TaptionWatchEnvelope.ambientDeliveryIDKey:
                "summary:\(summary.rawEventID)",
        ])
    }

    @MainActor
    private func waitForWatchSummary(
        _ summary: TaptionWatchSensorSummary,
        in span: TimeSpan,
        model: AppModel
    ) async -> Bool {
        for _ in 0..<100 {
            let loaded = await model.sensorReadingsLoadResult(in: span)
            if loaded.watchSummaries.contains(where: {
                $0.rawEventID == summary.rawEventID
            }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @MainActor
    private func waitForWatchSummaryApplied(
        _ summary: TaptionWatchSensorSummary
    ) async -> Bool {
        let key = "taption.watch-summary-applied-high-water.v1.\(summary.sessionID.uuidString)"
        for _ in 0..<100 {
            if let data = UserDefaults.standard.data(forKey: key),
               let applied = try? PropertyListDecoder().decode(
                   WatchSummaryHighWaterFixture.self,
                   from: data
               ),
               applied.sequence > summary.sequence
                    || (applied.sequence == summary.sequence
                        && applied.revision >= (summary.ambientRevision ?? 0)) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func testLegacyAmbientAdoptionRemovesOnlyPersistedSnapshotValues() {
        let start = Date(timeIntervalSince1970: 2_200_000_000)
        let original = makeWatchSummary(
            sessionID: UUID(),
            sequence: 1,
            startedAt: start,
            endedAt: start.addingTimeInterval(60),
            ambientWindowStart: start,
            ambientRevision: 0
        )
        var newer = original
        newer.ambientRevision = 1
        newer.accelerometerSampleCount += 1
        let added = makeWatchSummary(
            sessionID: UUID(),
            sequence: 2,
            startedAt: start.addingTimeInterval(60),
            endedAt: start.addingTimeInterval(120),
            ambientWindowStart: start.addingTimeInterval(60),
            ambientRevision: 0
        )
        var nonAmbient = original
        nonAmbient.isAmbient = false

        var summaries = [original, newer, added, nonAmbient]
        TaptionWatchAmbientQueueAdoption.removePersistedSummaries(
            from: &summaries,
            snapshot: [original]
        )
        XCTAssertEqual(summaries, [newer, added, nonAmbient])

        let sample = TaptionWatchAccelerationSample(
            capturedAt: start,
            acceleration: TaptionWatchSensorVector3(x: 0, y: 0, z: 1),
            sequence: 1,
            isAmbient: true
        )
        let originalChunk = TaptionWatchAccelerationChunk(
            sessionID: original.sessionID,
            sequence: 1,
            startedAt: start,
            endedAt: start.addingTimeInterval(60),
            isAmbient: true,
            samples: [sample],
            ambientWindowStart: start,
            ambientRevision: 0
        )
        var newerChunk = originalChunk
        newerChunk.ambientRevision = 1
        newerChunk.samples[0].sequence = 2
        let addedChunk = TaptionWatchAccelerationChunk(
            sessionID: UUID(),
            sequence: 2,
            startedAt: start.addingTimeInterval(60),
            endedAt: start.addingTimeInterval(120),
            isAmbient: true,
            samples: [sample]
        )
        var chunks = [originalChunk, newerChunk, addedChunk]
        TaptionWatchAmbientQueueAdoption.removePersistedChunks(
            from: &chunks,
            snapshot: [originalChunk]
        )
        XCTAssertEqual(chunks, [newerChunk, addedChunk])
    }

    func testAmbientOutboxRetryPolicyRequiresFailedActiveDeliveryOutsidePurge() {
        XCTAssertTrue(
            TaptionWatchAmbientOutboxRetryPolicy.shouldRetry(
                transferFailed: true,
                hasDeliveryID: true,
                sessionIsActivated: true,
                isPurging: false
            )
        )
        XCTAssertFalse(
            TaptionWatchAmbientOutboxRetryPolicy.shouldRetry(
                transferFailed: false,
                hasDeliveryID: true,
                sessionIsActivated: true,
                isPurging: false
            )
        )
        XCTAssertFalse(
            TaptionWatchAmbientOutboxRetryPolicy.shouldRetry(
                transferFailed: true,
                hasDeliveryID: false,
                sessionIsActivated: true,
                isPurging: false
            )
        )
        XCTAssertFalse(
            TaptionWatchAmbientOutboxRetryPolicy.shouldRetry(
                transferFailed: true,
                hasDeliveryID: true,
                sessionIsActivated: false,
                isPurging: false
            )
        )
        XCTAssertFalse(
            TaptionWatchAmbientOutboxRetryPolicy.shouldRetry(
                transferFailed: true,
                hasDeliveryID: true,
                sessionIsActivated: true,
                isPurging: true
            )
        )
    }

    @MainActor
    func testForegroundLiveLocationPolicyRequiresActiveEnabledGrantedCollection() {
        XCTAssertTrue(ForegroundLiveLocationPolicy.shouldTrack(
            sceneIsActive: true,
            locationCollectionEnabled: true,
            hasLocationPermission: true
        ))
        XCTAssertFalse(ForegroundLiveLocationPolicy.shouldTrack(
            sceneIsActive: false,
            locationCollectionEnabled: true,
            hasLocationPermission: true
        ))
        XCTAssertFalse(ForegroundLiveLocationPolicy.shouldTrack(
            sceneIsActive: true,
            locationCollectionEnabled: false,
            hasLocationPermission: true
        ))
        XCTAssertFalse(ForegroundLiveLocationPolicy.shouldTrack(
            sceneIsActive: true,
            locationCollectionEnabled: true,
            hasLocationPermission: false
        ))

        let timestamp = Date.now
        XCTAssertTrue(ForegroundLiveLocationPolicy.isNewFix(
            timestamp,
            after: nil
        ))
        XCTAssertFalse(ForegroundLiveLocationPolicy.isNewFix(
            timestamp,
            after: timestamp
        ))
    }

    @MainActor
    func testForegroundLiveLocationEmitsNewFixesInsideNormalSamplingInterval() async {
        let collector = AppleSensorCollector()
        collector.setForegroundLiveLocationTrackingEnabled(true)
        var configuration = SensorCollectionConfiguration.standard
        configuration.minimumEmissionInterval = 300
        let stream = collector.readings(configuration: configuration)
        let received = SensorReadingBuffer()
        let consumer = Task { @MainActor in
            for await reading in stream {
                received.values.append(reading)
            }
        }
        defer {
            consumer.cancel()
            collector.stop()
        }

        func sendFix(latitude: Double, timestamp: Date) {
            collector.locationManager(
                CLLocationManager(),
                didUpdateLocations: [CLLocation(
                    coordinate: CLLocationCoordinate2D(
                        latitude: latitude,
                        longitude: 126.8
                    ),
                    altitude: 0,
                    horizontalAccuracy: 5,
                    verticalAccuracy: 5,
                    course: -1,
                    speed: -1,
                    timestamp: timestamp
                )]
            )
        }

        let firstTimestamp = Date.now
        sendFix(latitude: 37.5, timestamp: firstTimestamp)
        for _ in 0..<20 where received.values.isEmpty {
            await Task.yield()
        }

        try? await Task.sleep(for: .milliseconds(550))
        sendFix(latitude: 37.5001, timestamp: .now)
        for _ in 0..<20 where received.values.filter({
            $0.point?.latitude == 37.5001
        }).isEmpty {
            await Task.yield()
        }

        let fixes = received.values.filter {
            $0.point?.latitude == 37.5 || $0.point?.latitude == 37.5001
        }
        XCTAssertEqual(
            fixes.compactMap { $0.point?.latitude },
            [37.5, 37.5001]
        )
        XCTAssertEqual(fixes.first?.timestamp, firstTimestamp)
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
    func testForegroundLiveLocationPersistsEachRoutePointWithoutBatchDelay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-live-location-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try SensorReadingArchive(
            fileURL: directory.appendingPathComponent("readings.jsonl")
        )
        let stream = SensorStreamProbe()
        let service = AppleSensorDataService(
            archive: archive,
            streamFactory: { _ in stream.makeStream() }
        )
        service.setForegroundLiveLocationTrackingEnabled(true)
        service.startCollection()

        let first = makeReading(Date(timeIntervalSince1970: 1_820_000_000))
        stream.yield(first)
        let firstPersisted = await service.waitForPersistedReading(
            after: 0,
            timeout: 1
        )
        XCTAssertTrue(firstPersisted)

        let persistedCount = service.persistenceToken()
        let second = makeReading(
            first.timestamp.addingTimeInterval(1),
            sequence: 2
        )
        stream.yield(second)
        let secondPersisted = await service.waitForPersistedReading(
            after: persistedCount,
            timeout: 1
        )
        XCTAssertTrue(secondPersisted)
        await service.stopCollectionAndWait()

        let archived = try await archive.allReadings()
        XCTAssertEqual(archived.map(\.id), [first.id, second.id])
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("taption-store.sqlite").path))

        let reopened = try SensorReadingArchive(fileURL: fileURL)
        let reopenedValues = try await reopened.readings(in: span)
        XCTAssertEqual(reopenedValues.map(\.id), values.map(\.id))
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
        } catch let error as TaptionStoreV2Error {
            XCTAssertEqual(error, .readingConflict(id.uuidString))
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

    func testRawDeviceEnvelopeIsStoredImmutablyInTheSingleStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-day-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent(TaptionStoreV2.fileName)
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
        } catch let error as TaptionStoreV2Error {
            XCTAssertEqual(
                error,
                .rawEventConflict(kind: TaptionRawEvent.Kind.deviceEnvelope, id: envelope.id.uuidString)
            )
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
        let store = try TaptionStoreV2(url: databaseURL)
        let events = try await store.rawEvents(kind: TaptionRawEvent.Kind.deviceEnvelope)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.origin, .auto)
        XCTAssertEqual(
            events.first?.provenance,
            ["source:iPhonePedometer", "kind:pedometer-summary", "schema:1"]
        )
        XCTAssertEqual(events.first?.payload.first, "{", "payload is plain JSON that SQL can read")
    }

    func testDeleteAllClearsEverySourceCopyInTheSingleStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-complete-delete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent(TaptionStoreV2.fileName)
        let store = try TaptionStoreV2(url: storeURL)
        let date = Date(timeIntervalSince1970: 1_850_100_000)
        let archive = try SensorReadingArchive(
            fileURL: directory.appendingPathComponent("sensor-readings-v1.jsonl"),
            store: store
        )
        try await archive.append(makeReading(date))
        let rawArchive = try RawDeviceDataDayArchive(store: store)
        try await rawArchive.append(try RawDeviceDataEnvelope(
            capturedAt: date, source: .gps, kind: "location", payload: ["latitude": 37.5]
        ))
        let database = PlanDayDatabase(store: store)
        let start = Date.now.addingTimeInterval(-60)
        try await database.recordWatchAccelerationChunk(TaptionWatchAccelerationChunk(
            sessionID: nil, sequence: 1, startedAt: start, endedAt: start,
            samples: [TaptionWatchAccelerationSample(
                capturedAt: start, acceleration: TaptionWatchSensorVector3(x: 0, y: 0, z: 1),
                sequence: 1, isAmbient: true
            )]
        ))
        let healthKit = try HealthKitImportStore(databaseURL: storeURL)
        try await healthKit.upsert([HealthKitSampleRecord(
            uuid: UUID(), typeIdentifier: "HKQuantityTypeIdentifierStepCount",
            startDate: date, endDate: date.addingTimeInterval(60),
            sourceName: "iPhone", sourceBundleIdentifier: "com.apple.health"
        )])
        let before = try await store.readingCount()
        XCTAssertEqual(before, 1)

        // 사용자가 데이터 삭제를 요청하면 한 파일 안의 모든 사본이 지워진다.
        try await archive.deleteAll()
        let readings = try await store.readingCount()
        let envelopes = try await store.rawEventCount(kind: TaptionRawEvent.Kind.deviceEnvelope)
        let chunks = try await store.rawEventCount(kind: TaptionRawEvent.Kind.watchAcceleration)
        let healthRecords = try await healthKit.allRecords()
        XCTAssertEqual(readings, 0)
        XCTAssertEqual(envelopes, 0)
        XCTAssertEqual(chunks, 0)
        XCTAssertTrue(healthRecords.isEmpty)
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
        let databaseURL = directory.appendingPathComponent("raw-day.sqlite")
        let archive = try RawDeviceDataDayArchive(databaseURL: databaseURL)
        try await archive.append(first)

        let lock = try await TaptionDataFileLock.acquire(
            url: databaseURL.appendingPathExtension("lock")
        )
        defer { lock.unlock() }
        let read = Task {
            return try await archive.allEnvelopes()
        }
        try await Task.sleep(for: .milliseconds(50))
        read.cancel()
        lock.unlock()
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

    func testRawDeviceArchiveDecodesAcrossCooperativeBatches() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-day-cooperative-decode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_850_000_000)
        let envelopes = try (0..<300).map { index in
            try RawDeviceDataEnvelope(
                capturedAt: date.addingTimeInterval(Double(index)),
                source: .gps,
                kind: "cooperative-decode",
                payload: ["sample": index]
            )
        }
        let archive = try RawDeviceDataDayArchive(
            databaseURL: directory.appendingPathComponent("raw-day.sqlite")
        )
        try await archive.append(envelopes)

        let restored = try await archive.allEnvelopes()
        XCTAssertEqual(Set(restored.map(\.id)), Set(envelopes.map(\.id)))
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
        } catch let error as TaptionStoreV2Error {
            XCTAssertEqual(
                error,
                .rawEventConflict(kind: TaptionRawEvent.Kind.deviceEnvelope, id: id.uuidString)
            )
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
                storeURL: databaseDirectory
            )
        )
    }

    @MainActor
    func testWatchSummaryRecordIsIdempotentAndKeepsProvenance() async throws {
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
        let store = try TaptionStoreV2(
            url: directory.appendingPathComponent(TaptionStoreV2.fileName)
        )

        try await database.recordWatchSummary(summary)
        try await database.recordWatchSummary(summary)

        let events = try await store.rawEvents(kind: TaptionRawEvent.Kind.watchSummary)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.id, summary.rawEventID)
        XCTAssertEqual(events.first?.origin, .auto)
        XCTAssertEqual(
            events.first?.provenance,
            ["source-device:appleWatch", "transport:WatchConnectivity"]
        )

        var conflicting = summary
        conflicting.endedAt = summary.endedAt.addingTimeInterval(1)
        do {
            try await database.recordWatchSummary(conflicting)
            XCTFail("a different summary with the same raw event id was accepted")
        } catch let error as TaptionStoreV2Error {
            XCTAssertEqual(
                error,
                .rawEventConflict(kind: TaptionRawEvent.Kind.watchSummary, id: summary.rawEventID)
            )
        }
        let restored = try await database.watchSummaries(
            in: TimeSpan(
                start: summary.startedAt,
                end: summary.endedAt.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(restored, [summary])
    }

    @MainActor
    func testWatchSummaryRevisionSelectsLatestAndAccelerationMergesStableSamples() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-summary-revision-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let startedAt = Date(timeIntervalSince1970: 2_200_000_000)
        let sessionID = UUID()
        let summary = TaptionWatchSensorSummary(
            sessionID: sessionID,
            sequence: 1,
            workoutKind: .walking,
            linkedPlanID: nil,
            linkedPlanTitle: nil,
            linkedCategoryID: nil,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(2),
            isFinal: false,
            accelerometerSampleCount: 1,
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
            activeEnergyKilocalories: nil,
            isAmbient: true,
            ambientWindowStart: startedAt
        )
        let firstSample = TaptionWatchAccelerationSample(
            id: TaptionWatchStableID.ambientAccelerationSample(
                sessionID: sessionID,
                sequence: 1
            ),
            capturedAt: startedAt.addingTimeInterval(1),
            acceleration: TaptionWatchSensorVector3(x: 0.1, y: 0.2, z: 0.3),
            sessionID: sessionID,
            sequence: 1,
            isAmbient: true
        )
        let chunk = TaptionWatchAccelerationChunk(
            id: TaptionWatchStableID.ambientAccelerationChunkID(
                sessionID: sessionID,
                sequence: 1,
                revision: 0
            ),
            sessionID: sessionID,
            sequence: 1,
            startedAt: firstSample.capturedAt,
            endedAt: firstSample.capturedAt,
            isAmbient: true,
            samples: [firstSample],
            ambientWindowStart: startedAt
        )

        let firstSummaryRevision = try XCTUnwrap(
            try TaptionWatchAmbientRevisionPolicy.nextSummaryRevision(
                for: summary,
                existing: []
            )
        )
        XCTAssertEqual(firstSummaryRevision.ambientRevision, 0)
        XCTAssertNil(
            try TaptionWatchAmbientRevisionPolicy.nextSummaryRevision(
                for: summary,
                existing: [firstSummaryRevision]
            )
        )
        let firstChunkRevision = try XCTUnwrap(
            try TaptionWatchAmbientRevisionPolicy.nextChunkRevision(
                for: chunk,
                existing: []
            )
        )
        XCTAssertEqual(firstChunkRevision.ambientRevision, 0)

        var lateSummaryInput = summary
        lateSummaryInput.endedAt = startedAt.addingTimeInterval(4)
        lateSummaryInput.accelerometerSampleCount = 2
        let lateSummary = try XCTUnwrap(
            try TaptionWatchAmbientRevisionPolicy.nextSummaryRevision(
                for: lateSummaryInput,
                existing: [firstSummaryRevision]
            )
        )
        XCTAssertEqual(lateSummary.ambientRevision, 1)
        let secondSample = TaptionWatchAccelerationSample(
            id: TaptionWatchStableID.ambientAccelerationSample(
                sessionID: sessionID,
                sequence: 2
            ),
            capturedAt: startedAt.addingTimeInterval(3),
            acceleration: TaptionWatchSensorVector3(x: 0.4, y: 0.5, z: 0.6),
            sessionID: sessionID,
            sequence: 2,
            isAmbient: true
        )
        var lateChunkInput = chunk
        lateChunkInput.samples.append(secondSample)
        lateChunkInput.endedAt = secondSample.capturedAt
        let lateChunk = try XCTUnwrap(
            try TaptionWatchAmbientRevisionPolicy.nextChunkRevision(
                for: lateChunkInput,
                existing: [firstChunkRevision],
                windowStart: startedAt
            )
        )
        XCTAssertEqual(lateChunk.ambientRevision, 1)
        XCTAssertNotEqual(lateChunk.id, firstChunkRevision.id)

        let phoneDatabase = try PlanDayDatabase(directory: directory)
        try await phoneDatabase.recordWatchSummary(firstSummaryRevision)
        try await phoneDatabase.recordWatchSummary(lateSummary)
        let latestSummaries = try await phoneDatabase.watchSummaries(
            in: TimeSpan(
                start: startedAt,
                end: startedAt.addingTimeInterval(10)
            )
        )
        XCTAssertEqual(latestSummaries, [lateSummary])

        try await phoneDatabase.recordWatchAccelerationChunks([
            firstChunkRevision,
            lateChunk,
        ])
        let samples = try await phoneDatabase.watchAccelerationSamples(
            in: TimeSpan(
                start: startedAt,
                end: startedAt.addingTimeInterval(10)
            )
        )
        XCTAssertEqual(Set(samples.map(\.id)), Set([firstSample.id, secondSample.id]))
    }

    @MainActor
    func testWatchSummaryHighWaterRestoresAcrossAppRestartDespiteStaleCache()
        async throws {
        let deletionFence = DataDeletionFenceTestFixture()
        defer { deletionFence.restore() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-summary-restart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseDirectory = root.appendingPathComponent("database")
        let database = try PlanDayDatabase(directory: databaseDirectory)
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970).addingTimeInterval(-5 * 60)
        let latest = makeWatchSummary(
            sessionID: sessionID,
            sequence: 10,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(100),
            isAmbient: false
        )
        let stale = makeWatchSummary(
            sessionID: sessionID,
            sequence: 9,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(80),
            isAmbient: false
        )
        let previouslyApplied = makeWatchSummary(
            sessionID: sessionID,
            sequence: 8,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            isAmbient: false
        )
        var snapshot = TaptionDataSnapshot.empty
        snapshot.actuals = AppleWatchSensorActivityEngine.upserting(
            previouslyApplied,
            into: [],
            linkedPlan: nil
        )
        let snapshotURL = root.appendingPathComponent("snapshot.sqlite")
        let repository = try GatedSQLitePlanRepository(databaseURL: snapshotURL)
        try await repository.save(snapshot)
        try await database.recordWatchSummary(latest)

        let defaults = UserDefaults.standard
        let highWaterKey =
            "taption.watch-summary-high-water.v1.\(sessionID.uuidString)"
        let appliedHighWaterKey =
            "taption.watch-summary-applied-high-water.v1.\(sessionID.uuidString)"
        let previousHighWater = defaults.data(forKey: highWaterKey)
        let previousAppliedHighWater = defaults.data(
            forKey: appliedHighWaterKey
        )
        defaults.set(
            try PropertyListEncoder().encode(
                WatchSummaryHighWaterFixture(sequence: 8, revision: 0)
            ),
            forKey: highWaterKey
        )
        defaults.removeObject(forKey: appliedHighWaterKey)
        defer {
            if let previousHighWater {
                defaults.set(previousHighWater, forKey: highWaterKey)
            } else {
                defaults.removeObject(forKey: highWaterKey)
            }
            if let previousAppliedHighWater {
                defaults.set(previousAppliedHighWater, forKey: appliedHighWaterKey)
            } else {
                defaults.removeObject(forKey: appliedHighWaterKey)
            }
        }

        let restartedDatabase = try PlanDayDatabase(directory: databaseDirectory)
        let service = AppleWatchConnectivityService()
        let acknowledgements = WatchDeliveryAcknowledgementProbe()
        service.onAmbientAcknowledgementRequested = {
            acknowledgements.record($0)
        }
        let model = try makeWatchSummaryModel(
            directory: root,
            database: restartedDatabase,
            service: service,
            repository: repository
        )
        await model.bootstrap()
        await repository.blockNextSave()
        try deliverWatchSummary(stale, through: service)

        for _ in 0..<100 {
            let stored = try await restartedDatabase.watchSummaries(
                in: TimeSpan(
                    start: startedAt,
                    end: Date.now.addingTimeInterval(1)
                )
            )
            if stored.contains(where: { $0.sequence == stale.sequence }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let saveBlocked = await repository.waitUntilSaveIsBlocked()
        XCTAssertTrue(saveBlocked, "The latest snapshot save should be suspended")
        guard saveBlocked else {
            await repository.releaseBlockedSave()
            return
        }
        XCTAssertTrue(acknowledgements.values.isEmpty)
        let preCommitSnapshot: TaptionDataSnapshot
        do {
            preCommitSnapshot = try await repository.load()
        } catch {
            await repository.releaseBlockedSave()
            throw error
        }
        XCTAssertEqual(
            preCommitSnapshot.actuals.first { $0.id == sessionID }?.endedAt,
            Optional(previouslyApplied.endedAt)
        )
        await repository.releaseBlockedSave()

        let latestSummaryApplied = await waitForWatchSummaryApplied(latest)
        XCTAssertTrue(latestSummaryApplied)
        XCTAssertEqual(
            model.snapshot.actuals.first { $0.id == sessionID }?.endedAt,
            Optional(latest.endedAt)
        )
        for _ in 0..<100 {
            if !acknowledgements.values.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            acknowledgements.values,
            ["summary:\(stale.rawEventID)"]
        )
        let readbackRepository = try TaptionStoreRepository(store: TaptionStoreV2(url: snapshotURL))
        let persistedSnapshot = try await readbackRepository.load()
        XCTAssertEqual(
            persistedSnapshot.actuals.first { $0.id == sessionID }?.endedAt,
            Optional(latest.endedAt)
        )
        XCTAssertEqual(model.activeTrackingSession?.id, sessionID)
    }

    @MainActor
    func testSameVersionWatchRedeliveryCompletesUnappliedSnapshotBeforeAck()
        async throws {
        let deletionFence = DataDeletionFenceTestFixture()
        defer { deletionFence.restore() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-summary-unapplied-redelivery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseDirectory = root.appendingPathComponent("database")
        let database = try PlanDayDatabase(directory: databaseDirectory)
        let repositoryURL = root.appendingPathComponent("snapshot.sqlite")
        let repository = try GatedSQLitePlanRepository(databaseURL: repositoryURL)
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970).addingTimeInterval(-5 * 60)
        let summary = makeWatchSummary(
            sessionID: sessionID,
            sequence: 10,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(100),
            isAmbient: false
        )
        try await database.recordWatchSummary(summary)

        let defaults = UserDefaults.standard
        let highWaterKey =
            "taption.watch-summary-high-water.v1.\(sessionID.uuidString)"
        let appliedHighWaterKey =
            "taption.watch-summary-applied-high-water.v1.\(sessionID.uuidString)"
        let previousHighWater = defaults.data(forKey: highWaterKey)
        let previousAppliedHighWater = defaults.data(
            forKey: appliedHighWaterKey
        )
        defaults.set(
            try PropertyListEncoder().encode(
                WatchSummaryHighWaterFixture(sequence: 10, revision: 0)
            ),
            forKey: highWaterKey
        )
        defaults.removeObject(forKey: appliedHighWaterKey)
        defer {
            if let previousHighWater {
                defaults.set(previousHighWater, forKey: highWaterKey)
            } else {
                defaults.removeObject(forKey: highWaterKey)
            }
            if let previousAppliedHighWater {
                defaults.set(previousAppliedHighWater, forKey: appliedHighWaterKey)
            } else {
                defaults.removeObject(forKey: appliedHighWaterKey)
            }
        }

        let service = AppleWatchConnectivityService()
        let acknowledgements = WatchDeliveryAcknowledgementProbe()
        service.onAmbientAcknowledgementRequested = {
            acknowledgements.record($0)
        }
        let model = try makeWatchSummaryModel(
            directory: root,
            database: database,
            service: service,
            repository: repository
        )
        await repository.blockNextSave()
        try deliverWatchSummary(summary, through: service)

        let saveBlocked = await repository.waitUntilSaveIsBlocked()
        XCTAssertTrue(saveBlocked, "The repository save should be suspended")
        guard saveBlocked else {
            await repository.releaseBlockedSave()
            return
        }
        XCTAssertTrue(acknowledgements.values.isEmpty)
        XCTAssertNil(defaults.data(forKey: appliedHighWaterKey))
        let preCommitSnapshot: TaptionDataSnapshot
        do {
            preCommitSnapshot = try await repository.load()
        } catch {
            await repository.releaseBlockedSave()
            throw error
        }
        XCTAssertFalse(preCommitSnapshot.actuals.contains {
            $0.source == .appleWatch && $0.id == sessionID
        })

        await repository.releaseBlockedSave()
        let summaryApplied = await waitForWatchSummaryApplied(summary)
        XCTAssertTrue(summaryApplied)
        for _ in 0..<100 {
            if !acknowledgements.values.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            acknowledgements.values,
            ["summary:\(summary.rawEventID)"]
        )

        let readbackRepository = try TaptionStoreRepository(store: TaptionStoreV2(url: repositoryURL))
        let persistedSnapshot = try await readbackRepository.load()
        XCTAssertTrue(persistedSnapshot.actuals.contains {
            $0.source == .appleWatch && $0.id == sessionID
        })
        XCTAssertEqual(model.activeTrackingSession?.id, sessionID)
    }

    @MainActor
    func testOlderWatchSummaryArchivesDistinctRoutePointsWithoutRegressingSnapshot()
        async throws {
        let deletionFence = DataDeletionFenceTestFixture()
        defer { deletionFence.restore() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-summary-stale-route-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try PlanDayDatabase(
            directory: root.appendingPathComponent("database")
        )

        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970).addingTimeInterval(-5 * 60)
        let latestPointID = UUID()
        let stalePointID = UUID()
        func routePoint(_ id: UUID, at date: Date) -> TaptionWatchLocationPoint {
            TaptionWatchLocationPoint(
                id: id,
                capturedAt: date,
                latitude: 37.5,
                longitude: 126.8,
                altitude: 10,
                horizontalAccuracy: 5,
                verticalAccuracy: -1,
                speedMetersPerSecond: nil,
                courseDegrees: nil
            )
        }
        let latest = makeWatchSummary(
            sessionID: sessionID,
            sequence: 10,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(100),
            isAmbient: false,
            routePoints: [routePoint(
                latestPointID,
                at: startedAt.addingTimeInterval(90)
            )]
        )
        let stale = makeWatchSummary(
            sessionID: sessionID,
            sequence: 9,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(80),
            isAmbient: false,
            routePoints: [routePoint(
                stalePointID,
                at: startedAt.addingTimeInterval(70)
            )]
        )
        let readingArchive = try SensorReadingArchive(
            fileURL: root.appendingPathComponent("readings.jsonl")
        )
        let service = AppleWatchConnectivityService()
        let model = try makeWatchSummaryModel(
            directory: root,
            database: database,
            service: service,
            readingArchive: readingArchive
        )

        try deliverWatchSummary(latest, through: service)
        let latestApplied = await waitForWatchSummaryApplied(latest)
        XCTAssertTrue(latestApplied)
        let latestActual = try XCTUnwrap(
            model.snapshot.actuals.first { $0.id == sessionID }
        )

        try deliverWatchSummary(stale, through: service)
        let span = TimeSpan(
            start: startedAt,
            end: startedAt.addingTimeInterval(101)
        )
        var archivedIDs = Set<UUID>()
        for _ in 0..<100 {
            archivedIDs = Set(
                try await readingArchive.routeReadings(in: span).map(\.id)
            )
            if archivedIDs.contains(stalePointID) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(archivedIDs, Set([latestPointID, stalePointID]))
        let currentActual = try XCTUnwrap(
            model.snapshot.actuals.first { $0.id == sessionID }
        )
        XCTAssertEqual(currentActual, latestActual)
    }

    @MainActor
    func testAmbientWatchHighWaterRestoresBySessionForMicrosecondSequence()
        async throws {
        let deletionFence = DataDeletionFenceTestFixture()
        defer { deletionFence.restore() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-ambient-high-water-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseDirectory = root.appendingPathComponent("database")
        let database = try PlanDayDatabase(directory: databaseDirectory)

        let sessionID = UUID()
        let now = Date.now
        let sequenceAnchor = now.addingTimeInterval(-24 * 60 * 60)
        let latestStartedAt = now.addingTimeInterval(-60)
        let latestSequence = try XCTUnwrap(
            TaptionWatchStableID.ambientSummarySegmentSequence(
                startedAt: latestStartedAt,
                anchor: sequenceAnchor
            )
        )
        XCTAssertGreaterThan(latestSequence, 80_000_000_000)

        let earlierStartedAt = sequenceAnchor.addingTimeInterval(60)
        let earlierSequence = try XCTUnwrap(
            TaptionWatchStableID.ambientSummarySegmentSequence(
                startedAt: earlierStartedAt,
                anchor: sequenceAnchor
            )
        )
        let earlier = makeWatchSummary(
            sessionID: sessionID,
            sequence: earlierSequence,
            startedAt: earlierStartedAt,
            endedAt: earlierStartedAt.addingTimeInterval(10),
            ambientWindowStart: earlierStartedAt
        )
        let latest = makeWatchSummary(
            sessionID: sessionID,
            sequence: latestSequence,
            startedAt: latestStartedAt,
            endedAt: latestStartedAt.addingTimeInterval(10),
            ambientWindowStart: latestStartedAt,
            ambientRevision: 2
        )
        try await database.recordWatchSummary(earlier)
        try await database.recordWatchSummary(latest)

        let defaults = UserDefaults.standard
        let highWaterKey =
            "taption.watch-summary-high-water.v1.\(sessionID.uuidString)"
        let appliedHighWaterKey =
            "taption.watch-summary-applied-high-water.v1.\(sessionID.uuidString)"
        let previousHighWater = defaults.data(forKey: highWaterKey)
        let previousAppliedHighWater = defaults.data(
            forKey: appliedHighWaterKey
        )
        defaults.set(
            try PropertyListEncoder().encode(
                WatchSummaryHighWaterFixture(
                    sequence: latestSequence - 2_000_000,
                    revision: 0
                )
            ),
            forKey: highWaterKey
        )
        defaults.removeObject(forKey: appliedHighWaterKey)
        defer {
            if let previousHighWater {
                defaults.set(previousHighWater, forKey: highWaterKey)
            } else {
                defaults.removeObject(forKey: highWaterKey)
            }
            if let previousAppliedHighWater {
                defaults.set(previousAppliedHighWater, forKey: appliedHighWaterKey)
            } else {
                defaults.removeObject(forKey: appliedHighWaterKey)
            }
        }

        let restartedDatabase = try PlanDayDatabase(directory: databaseDirectory)
        let service = AppleWatchConnectivityService()
        let model = try makeWatchSummaryModel(
            directory: root,
            database: restartedDatabase,
            service: service
        )
        let stale = makeWatchSummary(
            sessionID: sessionID,
            sequence: latestSequence - 1_000_000,
            startedAt: latestStartedAt.addingTimeInterval(-1),
            endedAt: latestStartedAt.addingTimeInterval(9),
            ambientWindowStart: latestStartedAt.addingTimeInterval(-1)
        )
        try deliverWatchSummary(stale, through: service)

        let staleSpan = TimeSpan(
            start: stale.startedAt.addingTimeInterval(-1),
            end: stale.endedAt.addingTimeInterval(1)
        )
        var staleWasStored = false
        for _ in 0..<100 {
            let summaries = try await restartedDatabase.watchSummaries(in: staleSpan)
            if summaries.contains(where: { $0.sequence == stale.sequence }) {
                staleWasStored = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(staleWasStored)
        let latestSummaryApplied = await waitForWatchSummaryApplied(latest)
        XCTAssertTrue(latestSummaryApplied)
        let restoredLatest = try await restartedDatabase.latestWatchSummary(
            for: sessionID
        )
        XCTAssertEqual(restoredLatest, latest)
        let persistedHighWater = try XCTUnwrap(defaults.data(forKey: highWaterKey))
        let restoredHighWater = try PropertyListDecoder().decode(
            WatchSummaryHighWaterFixture.self,
            from: persistedHighWater
        )
        XCTAssertEqual(restoredHighWater.sequence, latestSequence)
        XCTAssertEqual(restoredHighWater.revision, latest.ambientRevision ?? 0)
        withExtendedLifetime(model) {}
    }

    @MainActor
    func testOutOfOrderSameSequenceWatchRevisionDoesNotReplaceNewerState()
        async throws {
        let deletionFence = DataDeletionFenceTestFixture()
        defer { deletionFence.restore() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-summary-revision-order-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseDirectory = root.appendingPathComponent("database")
        let database = try PlanDayDatabase(directory: databaseDirectory)
        let sessionID = UUID()
        let anchor = Date.now.addingTimeInterval(-2 * 60)
        let windowStart = anchor
        let homePoint = GeoPoint(
            latitude: 37.5,
            longitude: 126.8,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: -1
        )
        let routePoint = TaptionWatchLocationPoint(
            id: UUID(),
            capturedAt: anchor.addingTimeInterval(10),
            latitude: homePoint.latitude,
            longitude: homePoint.longitude,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: -1,
            speedMetersPerSecond: nil,
            courseDegrees: nil
        )
        var source = TaptionDataSnapshot.empty
        source.settings.frequentPlaces = [
            FrequentPlace(kind: .home, point: homePoint),
        ]
        let higher = makeWatchSummary(
            sessionID: sessionID,
            sequence: 1,
            startedAt: anchor,
            endedAt: anchor.addingTimeInterval(45),
            ambientWindowStart: windowStart,
            ambientRevision: 1,
            behavior: .running,
            routePoints: [routePoint]
        )
        let lower = makeWatchSummary(
            sessionID: sessionID,
            sequence: 1,
            startedAt: anchor,
            endedAt: anchor.addingTimeInterval(30),
            ambientWindowStart: windowStart,
            ambientRevision: 0,
            behavior: .running,
            routePoints: [routePoint]
        )
        let service = AppleWatchConnectivityService()
        let model = try makeWatchSummaryModel(
            directory: root,
            database: database,
            service: service,
            snapshot: source
        )
        await model.bootstrap()
        try deliverWatchSummary(higher, through: service)
        try deliverWatchSummary(lower, through: service)

        var retainedEnd: Date?
        for _ in 0..<100 {
            let stored = try await database.watchSummaries(
                in: TimeSpan(
                    start: anchor,
                    end: Date.now.addingTimeInterval(1)
                )
            )
            if stored.first(where: {
                $0.sessionID == sessionID && $0.sequence == 1
            })?.ambientRevision == 1 {
                retainedEnd = model.snapshot.actuals.first {
                    $0.id == sessionID && $0.source == .appleWatch
                }?.endedAt
                if retainedEnd == higher.endedAt { break }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(retainedEnd, higher.endedAt)
        let higherSummaryApplied = await waitForWatchSummaryApplied(higher)
        XCTAssertTrue(higherSummaryApplied)
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

        let store = try TaptionStoreV2(
            url: directory.appendingPathComponent(TaptionStoreV2.fileName)
        )
        try await database.recordWatchAccelerationChunk(chunk)
        try await database.recordWatchAccelerationChunk(chunk)

        let events = try await store.rawEvents(kind: TaptionRawEvent.Kind.watchAcceleration)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.id, chunk.id.uuidString)
        XCTAssertEqual(events.first?.origin, .auto)
        XCTAssertEqual(
            events.first?.provenance,
            [
                "source-device:appleWatch",
                "source:WatchAcceleration",
                "derived:downsampled-accelerometer-v1",
            ]
        )
        let restored = try await database.watchAccelerationSamples(
            in: TimeSpan(
                start: start.addingTimeInterval(-1),
                end: start.addingTimeInterval(21)
            )
        )
        XCTAssertEqual(restored.map(\.id), samples.map(\.id))
    }

    @MainActor
    func testOutOfOrderWatchAccelerationChunksPersistAndReadBack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-acceleration-order-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try PlanDayDatabase(directory: directory)
        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 1_850_100_000)
        func chunk(sequence: Int) -> TaptionWatchAccelerationChunk {
            let capturedAt = start.addingTimeInterval(Double(sequence))
            let sample = TaptionWatchAccelerationSample(
                id: UUID(),
                capturedAt: capturedAt,
                acceleration: TaptionWatchSensorVector3(x: 0, y: 0, z: 1),
                sessionID: sessionID,
                sequence: sequence,
                isAmbient: false
            )
            return TaptionWatchAccelerationChunk(
                sessionID: sessionID,
                sequence: sequence,
                startedAt: capturedAt,
                endedAt: capturedAt,
                samples: [sample]
            )
        }

        try await database.recordWatchAccelerationChunk(chunk(sequence: 2))
        try await database.recordWatchAccelerationChunk(chunk(sequence: 1))

        let restored = try await PlanDayDatabase(directory: directory).watchAccelerationChunks(
            in: TimeSpan(start: start, end: start.addingTimeInterval(3))
        )
        XCTAssertEqual(restored.map(\.sequence), [1, 2])
        XCTAssertEqual(restored.flatMap(\.samples).map(\.sequence), [1, 2])
    }

    func testPlanDaySnapshotMakeStopsBeforeCancelledProjection() {
        let date = Date(timeIntervalSince1970: 2_200_000_000)
        let readings = (0..<1_024).map {
            makeReading(date.addingTimeInterval(TimeInterval($0)))
        }
        var cancellationChecks = 0

        XCTAssertThrowsError(try PlanDayDataSnapshot.make(
            date: date,
            sourceRevision: 1,
            source: .empty,
            sensorResult: SensorReadingsLoadResult(
                readings: readings,
                isComplete: true
            ),
            cancellationCheck: {
                cancellationChecks += 1
                throw CancellationError()
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancellationChecks, 1)
    }

    @MainActor
    func testPlanDayLoadCoordinatorCancelsProjectionAfterSensorLoad() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-projection-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = PlanDayLoadCoordinator()
        let date = Date(timeIntervalSince1970: 2_200_000_000)
        let readings = (0..<1_024).map {
            makeReading(date.addingTimeInterval(TimeInterval($0)))
        }
        let gate = SensorReadCheckpointGate()
        let request = Task { @MainActor in
            await coordinator.load(
                day: date,
                source: .empty,
                sourceRevision: 1,
                sensorLoader: { _ in
                    await gate.pauseOnce()
                    return SensorReadingsLoadResult(
                        readings: readings,
                        isComplete: true
                    )
                }
            )
        }

        await gate.waitUntilPaused()
        request.cancel()
        await gate.resume()
        let result = await request.value

        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.readings.isEmpty)
        XCTAssertEqual(coordinator.cachedDayCount, 0)
    }

    @MainActor
    func testPlanDayLoadCoordinatorKeepsInvalidatedPreviewUntilMemoryPressure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-cached-invalidation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let coordinator = PlanDayLoadCoordinator()
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
        let deletionFence = DataDeletionFenceTestFixture()
        defer { deletionFence.restore() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-cached-generation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let coordinator = PlanDayLoadCoordinator()

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
        let coordinator = PlanDayLoadCoordinator()
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

    /// 오늘은 새 위치가 몇 초마다 저장되어 무효화가 계속 온다. 읽는 중의 무효화가 로드를 취소하면
    /// 지도는 하루치 대신 실시간 몇 점만 그린다(MAP1019F01). 결과는 완전해야 하고, 캐시에는 넣지 않아 다음 요청이 새로 읽는다.
    @MainActor
    func testInvalidationDuringLoadReturnsCompleteDayWithoutCachingIt() async throws {
        let coordinator = PlanDayLoadCoordinator()
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let started = expectation(description: "sensor read started")
        var release: CheckedContinuation<Void, Never>?
        var loadCount = 0
        let loading = Task { @MainActor in
            await coordinator.load(
                day: date,
                source: .empty,
                sourceRevision: 1,
                sensorLoader: { _ in
                    loadCount += 1
                    await withCheckedContinuation { continuation in
                        release = continuation
                        started.fulfill()
                    }
                    return SensorReadingsLoadResult(readings: [], isComplete: true)
                }
            )
        }
        await fulfillment(of: [started], timeout: 1)
        coordinator.invalidate(day: date)
        coordinator.invalidate(day: date)
        release?.resume()
        let result = await loading.value
        XCTAssertTrue(result.isComplete, "무효화가 진행 중인 하루치 로드를 취소하면 안 된다")
        XCTAssertEqual(loadCount, 1, "무효화마다 다시 읽기를 반복하면 계속 들어오는 위치에 밀려 끝나지 않는다")
        XCTAssertEqual(coordinator.cachedDayCount, 0, "무효화 이전 세대의 결과는 캐시에 남기지 않는다")

        let fresh = await coordinator.load(
            day: date,
            source: .empty,
            sourceRevision: 1,
            sensorLoader: { _ in
                loadCount += 1
                return SensorReadingsLoadResult(readings: [], isComplete: true)
            }
        )
        XCTAssertTrue(fresh.isComplete)
        XCTAssertEqual(loadCount, 2, "다음 요청은 새 원본을 읽어야 한다")
    }

    @MainActor
    func testPlanDayLoadCoordinatorCachedPreviewP95With65853HistoryRecords() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-cached-preview-benchmark-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = PlanDayLoadCoordinator()
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
        let coordinator = PlanDayLoadCoordinator(cacheCapacity: 1)
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
        let coordinator = PlanDayLoadCoordinator()
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
        let coordinator = PlanDayLoadCoordinator()
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

    func testDaySnapshotOrderedFastPathAndUnorderedDuplicatesPreserveLastValue() {
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let readings = (0..<1_440).map { makeReading(date.addingTimeInterval(Double($0))) }
        let ordered = PlanDayDataSnapshot.make(date: date, sourceRevision: 1, source: .empty,
            sensorResult: SensorReadingsLoadResult(readings: readings, isComplete: true))
        XCTAssertEqual(ordered.readings, readings)
        var replacement = readings[0]
        replacement.motionConfidence = .low
        var shuffled = Array(readings.reversed())
        shuffled.append(replacement)
        let result = PlanDayDataSnapshot.make(date: date, sourceRevision: 1, source: .empty,
            sensorResult: SensorReadingsLoadResult(readings: shuffled, isComplete: true))
        XCTAssertEqual(result.readings.count, readings.count)
        XCTAssertEqual(result.readings[0], replacement)
        XCTAssertEqual(Array(result.readings.dropFirst()), Array(readings.dropFirst()))
    }

    func testCompleteDaySnapshotSurvivesARevisionBumpButIncompleteDoesNot() {
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let complete = PlanDayDataSnapshot.make(date: date, sourceRevision: 7, source: .empty,
            sensorResult: SensorReadingsLoadResult(readings: [makeReading(date)], isComplete: true))
        // 읽는 동안 다른 날 기록이 바뀌면 전역 개정만 올라간다. 그날 원본은 그대로다.
        XCTAssertTrue(PlanDayDataSnapshot.keepsLoadedSnapshot(complete, currentRevision: 8))
        XCTAssertTrue(PlanDayDataSnapshot.keepsLoadedSnapshot(complete, currentRevision: 7))

        // 끝까지 못 읽은 날은 개정과 무관하게 버린다(빈 하루로 확정하면 안 된다).
        let incomplete = PlanDayDataSnapshot.incomplete(date: date, sourceRevision: 7, source: .empty)
        XCTAssertFalse(PlanDayDataSnapshot.keepsLoadedSnapshot(incomplete, currentRevision: 8))
        XCTAssertTrue(PlanDayDataSnapshot.keepsLoadedSnapshot(incomplete, currentRevision: 7))
    }

    @MainActor
    func testConcurrentDayLoadsDoNotCancelEachOther() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("day-independent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = PlanDayLoadCoordinator()
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let gate = SensorReadCheckpointGate()
        let first = Task { @MainActor in
            await coordinator.load(day: date, source: .empty, sourceRevision: 1,
                sensorLoader: { _ in
                    await gate.pauseOnce()
                    return SensorReadingsLoadResult(readings: [self.makeReading(date)], isComplete: true)
                }, forceReload: true)
        }
        await gate.waitUntilPaused()
        let second = await coordinator.load(day: date.addingTimeInterval(86_400),
            source: .empty, sourceRevision: 1,
            sensorLoader: { _ in SensorReadingsLoadResult(readings: [], isComplete: true) }, forceReload: true)
        await gate.resume()
        let result = await first.value
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.readings.count, 1)
        XCTAssertTrue(second.isComplete)
    }

    @MainActor
    func testChangedSourceProjectionKeepsInFlightSensorRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("day-source-shared-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = PlanDayLoadCoordinator()
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let gate = SensorReadCheckpointGate()
        var loads = 0
        var rawCancelled = false
        let loader: (Date) async -> SensorReadingsLoadResult = { _ in
            loads += 1
            await gate.pauseOnce()
            rawCancelled = Task.isCancelled
            return SensorReadingsLoadResult(readings: [self.makeReading(date)], isComplete: true)
        }
        let first = Task { @MainActor in
            await coordinator.load(day: date, source: .empty, sourceRevision: 1,
                sourceFingerprint: "first-source", sensorLoader: loader, forceReload: true)
        }
        await gate.waitUntilPaused()
        let second = Task { @MainActor in
            await coordinator.load(day: date, source: .empty, sourceRevision: 2,
                sourceFingerprint: "changed-source", sensorLoader: loader, forceReload: true)
        }
        for _ in 0..<20 { await Task.yield() }
        await gate.resume()
        let old = await first.value
        let updated = await second.value
        XCTAssertFalse(old.isComplete)
        XCTAssertTrue(updated.isComplete)
        XCTAssertEqual(updated.sourceRevision, 2)
        XCTAssertEqual(updated.readings.count, 1)
        XCTAssertEqual(loads, 1)
        XCTAssertFalse(rawCancelled)
    }

    @MainActor
    func testPlanDayInvalidateAllCancelsSharedRawReadBeforeReturning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("day-raw-invalidate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = PlanDayLoadCoordinator()
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let gate = SensorReadCheckpointGate()
        var rawCancelled = false
        let request = Task { @MainActor in
            await coordinator.load(day: date, source: .empty, sourceRevision: 1,
                sensorLoader: { _ in
                    await withTaskCancellationHandler(operation: { await gate.pauseOnce() },
                        onCancel: { Task { await gate.resume() } })
                    rawCancelled = Task.isCancelled
                    return SensorReadingsLoadResult(readings: [self.makeReading(date)], isComplete: true)
                }, forceReload: true)
        }
        await gate.waitUntilPaused()
        await coordinator.invalidateAll()
        let result = await request.value
        XCTAssertTrue(rawCancelled)
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.readings.isEmpty)
        XCTAssertEqual(coordinator.cachedDayCount, 0)
    }

    @MainActor
    func testPlanDayMemoryPressureCancelsRawReadWithoutCachingResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("day-raw-pressure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = PlanDayLoadCoordinator()
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let gate = SensorReadCheckpointGate()
        var cancelled = false
        let request = Task { @MainActor in
            await coordinator.load(day: date, source: .empty, sourceRevision: 1,
                sensorLoader: { _ in
                    await gate.pauseOnce()
                    cancelled = Task.isCancelled
                    return SensorReadingsLoadResult(readings: [self.makeReading(date)], isComplete: true)
                }, forceReload: true)
        }
        await gate.waitUntilPaused()
        coordinator.handleMemoryPressure()
        await gate.resume()
        let result = await request.value
        XCTAssertTrue(cancelled)
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.readings.isEmpty)
        XCTAssertEqual(coordinator.cachedDayCount, 0)
        let fresh = await coordinator.load(day: date, source: .empty, sourceRevision: 1,
            sensorLoader: { _ in SensorReadingsLoadResult(readings: [self.makeReading(date)], isComplete: true) },
            forceReload: true)
        XCTAssertTrue(fresh.isComplete)
        XCTAssertEqual(fresh.readings.count, 1)
    }

    @MainActor
    func testBackgroundTransitionCancelsDayLoadAndAllowsFreshForegroundRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("day-background-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = PlanDayLoadCoordinator()
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let gate = SensorReadCheckpointGate()
        var cancelled = false
        coordinator.invalidate(day: date)
        let request = Task { @MainActor in
            await coordinator.load(day: date, source: .empty, sourceRevision: 1,
                sensorLoader: { _ in
                    await gate.pauseOnce()
                    cancelled = Task.isCancelled
                    return SensorReadingsLoadResult(readings: [self.makeReading(date)], isComplete: true)
                })
        }
        await gate.waitUntilPaused()
        coordinator.prepareForBackground()
        await gate.resume()
        let result = await request.value
        XCTAssertTrue(cancelled)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(coordinator.cachedDayCount, 0)
        let fresh = await coordinator.load(day: date, source: .empty, sourceRevision: 1,
            sensorLoader: { _ in SensorReadingsLoadResult(readings: [self.makeReading(date)], isComplete: true) })
        XCTAssertTrue(fresh.isComplete)
        XCTAssertEqual(fresh.readings.count, 1)
    }

    @MainActor
    func testConcurrentForcedDayLoadsShareSensorRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("day-forced-shared-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = PlanDayLoadCoordinator()
        let date = Date(timeIntervalSince1970: 2_100_000_000)
        let gate = SensorReadCheckpointGate()
        var loadCount = 0
        let loader: (Date) async -> SensorReadingsLoadResult = { _ in
            loadCount += 1
            await gate.pauseOnce()
            return SensorReadingsLoadResult(readings: [], isComplete: true)
        }
        let first = Task { @MainActor in
            await coordinator.load(day: date, source: .empty, sourceRevision: 1,
                sourceFingerprint: "shared-forced-load",
                sensorLoader: loader, forceReload: true)
        }
        await gate.waitUntilPaused()
        let secondStarted = expectation(description: "second request joins the pending load")
        let second = Task { @MainActor in
            secondStarted.fulfill()
            return await coordinator.load(day: date, source: .empty, sourceRevision: 1,
                sourceFingerprint: "shared-forced-load",
                sensorLoader: loader, forceReload: true)
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        await gate.resume()
        let a = await first.value
        let b = await second.value
        XCTAssertTrue(a.isComplete)
        XCTAssertTrue(b.isComplete)
        XCTAssertEqual(loadCount, 1)
    }

    @MainActor
    func testPlanDayLoadCoordinatorRetriesIncompleteLoads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-incomplete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = PlanDayLoadCoordinator()
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
    func testPlanDayLoadCoordinatorPreloadsEveryDayInMonth() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-day-preload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = PlanDayLoadCoordinator(cacheCapacity: 42)
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
        let calendar = Calendar.autoupdatingCurrent
        let base = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 1)
        )!
        let days = (0..<30).compactMap {
            calendar.date(byAdding: .day, value: $0, to: base)
        }
        let coordinator = PlanDayLoadCoordinator()
        var sensorLoadCount = 0
        func readDurations() async -> [Double] {
            var milliseconds: [Double] = []
            for day in days {
                let started = DispatchTime.now().uptimeNanoseconds
                _ = await coordinator.load(
                    day: day,
                    source: .empty,
                    sourceRevision: 1,
                    sensorLoader: { [self] day in
                        sensorLoadCount += 1
                        return SensorReadingsLoadResult(
                            readings: (0..<1_440).map {
                                makeReading(day.addingTimeInterval(Double($0 * 60)))
                            },
                            isComplete: true
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
        XCTAssertEqual(sensorLoadCount, 30, "the warm pass is served from memory without reading sensors")
        XCTAssertLessThan(coldP95, 500)
        XCTAssertLessThan(warmP95, 5)
    }
}
