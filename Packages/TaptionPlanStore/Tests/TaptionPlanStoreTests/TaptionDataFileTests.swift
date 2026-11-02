import Foundation
import XCTest
import TaptionPlanStore

final class TaptionDataFileTests: XCTestCase {
    func testCompressionRoundTripsLargeAndKeepsSmallPlain() throws {
        let large = Data(repeating: 0x41, count: 16 * 1024)
        let stored = TaptionSnapshotCompression.encode(large)
        XCTAssertLessThan(stored.count, large.count)
        XCTAssertEqual(TaptionSnapshotCompression.decode(stored), large)

        let small = Data("{}".utf8)
        XCTAssertEqual(TaptionSnapshotCompression.encode(small), small)
        XCTAssertEqual(TaptionSnapshotCompression.decode(small), small)
    }

    func testFileLockIsExclusiveUntilUnlocked() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let lock = try TaptionDataFileLock.acquireIfAvailable(url: url)
        XCTAssertThrowsError(try TaptionDataFileLock.acquireIfAvailable(url: url))
        lock.unlock()
        XCTAssertNoThrow(try TaptionDataFileLock.acquireIfAvailable(url: url).unlock())
    }
}
