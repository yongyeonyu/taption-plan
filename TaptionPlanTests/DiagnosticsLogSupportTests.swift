import XCTest
import zlib
@testable import TaptionPlan

final class DiagnosticsLogSupportTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TaptionPlanDiagnosticsLoggerTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try super.tearDownWithError()
    }

    func testDiagnosticsSessionMarksUnfinishedPreviousLaunch() throws {
        let suite = "TaptionPlanDiagnosticsSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = TaptionPlanDiagnosticsSession.begin(defaults: defaults)
        XCTAssertNil(first.previousSessionWasUnfinished)

        let second = TaptionPlanDiagnosticsSession.begin(defaults: defaults)
        XCTAssertEqual(second.previousSessionWasUnfinished, true)
        XCTAssertNotNil(second.previousSessionStartedAt)
        XCTAssertEqual(
            TaptionPlanDiagnosticsSession.latestSummary(defaults: defaults)[
                "previous_session_unfinished"
            ],
            "true"
        )
    }

    func testDiagnosticsSessionMarksCleanTermination() throws {
        let suite = "TaptionPlanDiagnosticsSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        _ = TaptionPlanDiagnosticsSession.begin(defaults: defaults)
        TaptionPlanDiagnosticsSession.markCleanTermination(defaults: defaults)
        let next = TaptionPlanDiagnosticsSession.begin(defaults: defaults)
        XCTAssertEqual(next.previousSessionWasUnfinished, false)
    }

    func testBackgroundSessionWithoutTerminationCallbackRetainsItsLastPhase() throws {
        let suite = "TaptionPlanDiagnosticsSessionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = TaptionPlanDiagnosticsSession.begin(defaults: defaults)
        let backgroundDate = Date(timeIntervalSince1970: 1_000)
        TaptionPlanDiagnosticsSession.recordPhase(.background, at: backgroundDate, defaults: defaults)
        _ = TaptionPlanDiagnosticsSession.begin(defaults: defaults)
        let summary = TaptionPlanDiagnosticsSession.latestSummary(defaults: defaults)
        XCTAssertEqual(summary["previous_session_unfinished"], "true")
        XCTAssertEqual(summary["previous_session_last_phase"], "background")
        XCTAssertEqual(summary["previous_session_last_phase_at"], "1000.0")
    }

    func testSystemTerminationFieldsExcludeFreeformExceptionAndPersonalData() {
        let fields = TaptionTerminationDiagnosticFields.make(
            reason: "Namespace FRONTBOARD, Code 0x8badf00d; private-location private-secret",
            exceptionType: 1, exceptionCode: 2, signal: 9
        )
        XCTAssertEqual(fields["termination_namespace"], "FRONTBOARD")
        XCTAssertEqual(fields["termination_code"], "0x8badf00d")
        XCTAssertEqual(fields["signal"], "9")
        XCTAssertFalse(fields.values.contains { $0.contains("private") })
        let unavailable = TaptionTerminationDiagnosticFields.make(reason: nil, exceptionType: nil, exceptionCode: nil, signal: nil)
        XCTAssertEqual(unavailable["termination_namespace"], "unknown")
        XCTAssertEqual(unavailable["termination_code"], "unknown")
    }

    func testSystemTerminationRecognizesRunningBoardWatchdogReason() {
        let fields = TaptionTerminationDiagnosticFields.make(
            reason: "<RBSTerminateContext| domain:10 code:0x8BADF00D explanation:scene-update watchdog transgression private-location>",
            exceptionType: 10, exceptionCode: 0, signal: 9)
        XCTAssertEqual(fields["termination_domain"], "10")
        XCTAssertEqual(fields["termination_code"], "0x8badf00d")
        XCTAssertEqual(fields["termination_category"], "watchdog")
        XCTAssertFalse(fields.values.contains { $0.contains("private") })
        let decimal = TaptionTerminationDiagnosticFields.make(reason: "namespace:FRONTBOARD code:2343432205",
            exceptionType: 10, exceptionCode: 0, signal: 9)
        XCTAssertEqual(decimal["termination_namespace"], "FRONTBOARD")
        XCTAssertEqual(decimal["termination_category"], "watchdog")
        let unknown = TaptionTerminationDiagnosticFields.make(reason: "Namespace private_secret Code 9",
            exceptionType: nil, exceptionCode: nil, signal: nil)
        XCTAssertEqual(unknown["termination_namespace"], "unknown")
        XCTAssertEqual(unknown["termination_category"], "unknown")
    }

    func testPrimaryWriteReportsPrimarySuccess() throws {
        let primary = rootURL.appendingPathComponent("primary")
        let fallback = rootURL.appendingPathComponent("fallback")
        let logger = TaptionPlanDiagnosticsLogger(
            directoryURL: primary,
            fallbackDirectoryURL: fallback
        )

        logger.record("primary_event")

        XCTAssertEqual(logger.lastWriteStatus, .primarySucceeded)
        XCTAssertTrue(
            try String(
                contentsOf: primary.appendingPathComponent("iphone.jsonl"),
                encoding: .utf8
            )
                .contains("primary_event")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.path))
    }

    func testPrimaryFailureFallsBackToApplicationSupportDirectory() throws {
        let primary = rootURL.appendingPathComponent("primary")
        let fallback = rootURL.appendingPathComponent("fallback")
        try Data("not a directory".utf8).write(to: primary)
        let logger = TaptionPlanDiagnosticsLogger(
            directoryURL: primary,
            fallbackDirectoryURL: fallback
        )

        logger.record("fallback_event")

        XCTAssertEqual(logger.lastWriteStatus, .fallbackSucceeded)
        XCTAssertTrue(
            try String(
                contentsOf: fallback.appendingPathComponent("iphone.jsonl"),
                encoding: .utf8
            )
                .contains("fallback_event")
        )
    }

    func testPrimaryAndFallbackFailureReportFailedStatus() throws {
        let primary = rootURL.appendingPathComponent("primary")
        let fallback = rootURL.appendingPathComponent("fallback")
        try Data("not a directory".utf8).write(to: primary)
        try Data("not a directory".utf8).write(to: fallback)
        let logger = TaptionPlanDiagnosticsLogger(
            directoryURL: primary,
            fallbackDirectoryURL: fallback
        )

        logger.record("lost_event")

        XCTAssertEqual(logger.lastWriteStatus, .failed)
    }

    func testOperationWritesCorrelationAndDurationFields() throws {
        let logger = TaptionPlanDiagnosticsLogger(
            directoryURL: rootURL.appendingPathComponent("primary"),
            fallbackDirectoryURL: nil
        )

        let operation = logger.beginOperation(
            "automatic_backup",
            fields: ["reason": "foreground"]
        )
        logger.finishOperation(
            operation,
            outcome: "success",
            fields: ["app_log_bytes": "42"]
        )

        let log = logger.combinedLog()
        XCTAssertTrue(log.contains("operation_started"))
        XCTAssertTrue(log.contains("operation_finished"))
        XCTAssertTrue(log.contains(operation.id.uuidString))
        XCTAssertTrue(log.contains("\"duration_ms\":"))
        XCTAssertTrue(log.contains("\"outcome\":\"success\""))
    }

    func testCombinedLogPreservesEventVersionsAcrossAppUpdates() throws {
        let directory = rootURL.appendingPathComponent("primary")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("{\"event\":\"legacy_event\",\"fields\":{}}\n".utf8)
            .write(to: directory.appendingPathComponent("iphone.jsonl"))
        let previousLogger = TaptionPlanDiagnosticsLogger(
            directoryURL: directory,
            appVersion: "1.0",
            buildNumber: "170"
        )
        previousLogger.record("previous_event")
        _ = previousLogger.lastWriteStatus

        let currentLogger = TaptionPlanDiagnosticsLogger(
            directoryURL: directory,
            appVersion: "1.1",
            buildNumber: "171"
        )
        currentLogger.record(
            "health_refresh_failed",
            level: .error,
            fields: ["heart_rate": "72", "error_code": "3"]
        )

        let entries = try currentLogger.combinedLog().split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(entries.count, 3)
        XCTAssertNil(entries[0]["app_version"])
        XCTAssertNil(entries[0]["build"])
        XCTAssertEqual(entries[1]["app_version"] as? String, "1.0")
        XCTAssertEqual(entries[1]["build"] as? String, "170")
        XCTAssertEqual(entries[2]["app_version"] as? String, "1.1")
        XCTAssertEqual(entries[2]["build"] as? String, "171")
        let fields = try XCTUnwrap(entries[2]["fields"] as? [String: String])
        XCTAssertEqual(fields["error_code"], "3")
        XCTAssertNil(fields["heart_rate"])
    }

    func testExportedLogRemovesPersonalHealthFields() throws {
        let logger = TaptionPlanDiagnosticsLogger(
            directoryURL: rootURL.appendingPathComponent("primary"),
            fallbackDirectoryURL: nil
        )

        logger.record(
            "watch_health_snapshot_applied",
            fields: [
                "sleep_minutes": "420",
                "workout_count": "2",
                "reason": "received",
            ]
        )
        logger.record(
            "route_inference",
            fields: [
                "subway_route": "2호선",
                "step_count": "9000",
            ]
        )

        let log = logger.combinedLog()
        XCTAssertTrue(log.contains("watch_health_snapshot_applied"))
        XCTAssertTrue(log.contains("\"reason\":\"received\""))
        XCTAssertTrue(log.contains("\"subway_route\":\"2호선\""))
        XCTAssertFalse(log.contains("\"sleep_minutes\":\"420\""))
        XCTAssertFalse(log.contains("workout_count"))
        XCTAssertFalse(log.contains("step_count"))
    }

    func testCachedWatchLogRemovesPersonalHealthLines() throws {
        let suite = "TaptionPlanTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        WatchDiagnosticsLogStore.save(
            "health snapshot ready workouts=2\nconnectivity activated",
            defaults: defaults
        )

        XCTAssertEqual(
            WatchDiagnosticsLogStore.read(defaults: defaults),
            "connectivity activated"
        )
    }

    func testLegacyICloudDiagnosticsAreRemovedOnce() throws {
        let cloud = rootURL.appendingPathComponent("iCloud")
        let logs = cloud
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("TaptionLogs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        try Data("sleep_minutes=420".utf8).write(
            to: logs.appendingPathComponent("TaptionLogs-old.txt")
        )
        let suite = "TaptionPlanTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let exporter = TaptionPlanDiagnosticsICloudExporter(
            ubiquityContainerURL: { cloud },
            transferItem: { _, _ in }
        )

        try exporter.removeLegacyPersonalHealthLogsIfNeeded(
            defaults: defaults
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: logs.path))

        try FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true
        )
        try exporter.removeLegacyPersonalHealthLogsIfNeeded(
            defaults: defaults
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: logs.path))
    }

    func testBoundedLogKeepsCompleteNewestLinesWithinLimit() {
        let log = (0..<20).map { "line_\($0)\n" }.joined()

        let bounded = TaptionPlanDiagnosticsLogPolicy.bounded(
            log,
            maximumBytes: 40
        )

        XCTAssertLessThanOrEqual(Data(bounded.utf8).count, 40)
        XCTAssertFalse(bounded.contains("line_0"))
        XCTAssertTrue(bounded.split(separator: "\n").allSatisfy {
            $0.hasPrefix("line_")
        })
    }
}

func gunzipLogForTest(_ data: Data) throws -> Data {
    var stream = z_stream()
    guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        throw TaptionLogGzip.Failure.compressionFailed
    }
    defer { inflateEnd(&stream) }
    var result = Data()
    var output = [UInt8](repeating: 0, count: 16_384)
    try data.withUnsafeBytes { input in
        stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(data.count)
        var status = Z_OK
        repeat {
            status = output.withUnsafeMutableBytes { buffer in
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = 16_384
                return inflate(&stream, Z_NO_FLUSH)
            }
            guard status == Z_OK || status == Z_STREAM_END, result.count < 64 * 1_024 * 1_024 else {
                throw TaptionLogGzip.Failure.compressionFailed
            }
            result.append(contentsOf: output.prefix(16_384 - Int(stream.avail_out)))
        } while status != Z_STREAM_END
        guard stream.avail_in == 0 else { throw TaptionLogGzip.Failure.compressionFailed }
    }
    return result
}

extension DiagnosticsLogSupportTests {
    func testGzipRoundTripsEmptyUnicodeAndLargeLogs() throws {
        for text in ["", "백업 완료 🐾\n", String(repeating: "2026-10-15 diagnostic stage=complete rows=100\n", count: 30_000)] {
            let original = Data(text.utf8)
            let encoded = try TaptionLogGzip.compress(original)
            XCTAssertEqual(Array(encoded.prefix(3)), [0x1f, 0x8b, 0x08])
            XCTAssertEqual(try gunzipLogForTest(encoded), original)
            if original.count > 1_000_000 { XCTAssertLessThan(encoded.count, original.count / 20) }
        }
    }

    func testGzipChecksumDetectsCorruption() throws {
        var encoded = try TaptionLogGzip.compress(Data("diagnostic fixture".utf8))
        encoded[encoded.count - 8] ^= 0xff
        XCTAssertThrowsError(try gunzipLogForTest(encoded))
    }

    func testCompressedLogUploadManifestAndRetryKeepExactBytes() throws {
        let builder = TaptionPlanDiagnosticsLogPackageBuilder(packageDirectoryURL: rootURL.appendingPathComponent("packages"))
        let package = try builder.makePackage(summary: ["build": "fixture"], iphoneLog: "backup_finished", watchLog: nil)
        XCTAssertTrue(package.lastPathComponent.hasSuffix(".txt.gz"))
        let original = try Data(contentsOf: package)
        var reject = true
        let exporter = TaptionPlanDiagnosticsICloudExporter(ubiquityContainerURL: { self.rootURL }, transferItem: { from, to in
            if reject { throw TaptionLogGzip.Failure.compressionFailed }
            try FileManager.default.copyItem(at: from, to: to)
        })
        XCTAssertThrowsError(try exporter.export(package))
        XCTAssertEqual(try Data(contentsOf: package), original)
        reject = false
        let uploaded = try exporter.export(package)
        XCTAssertEqual(try Data(contentsOf: uploaded), original)
        let manifestURL = uploaded.deletingLastPathComponent().appendingPathComponent("latest.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(TaptionDiagnosticsLatestLogManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(manifest.fileName, uploaded.lastPathComponent)
        XCTAssertEqual(manifest.byteCount, original.count)
        XCTAssertTrue(String(decoding: try gunzipLogForTest(original), as: UTF8.self).contains("backup_finished"))
    }
}
