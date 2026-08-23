import XCTest
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
}
