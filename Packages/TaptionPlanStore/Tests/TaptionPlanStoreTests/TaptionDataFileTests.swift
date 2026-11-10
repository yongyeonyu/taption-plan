import Foundation
import XCTest
import TaptionPlanStore

final class TaptionDataFileTests: XCTestCase {
    func testCompressionRoundTripsLargeAndKeepsSmallPlain() throws {
        let large = Data(repeating: 0x41, count: 16 * 1024)
        let stored = TaptionSnapshotCompression.encode(large)
        XCTAssertLessThan(stored.count, large.count)
        XCTAssertEqual(try TaptionSnapshotCompression.decode(stored), large)

        let small = Data("{}".utf8)
        XCTAssertEqual(TaptionSnapshotCompression.encode(small), small)
        XCTAssertEqual(try TaptionSnapshotCompression.decode(small), small)
    }

    /// 풀리지 않는 TPZ1은 바이트를 그대로 넘기지 않고 던진다(REV1110A04).
    func testCorruptedCompressedPayloadThrowsInsteadOfPassingThrough() {
        var stored = TaptionSnapshotCompression.encode(Data(repeating: 0x41, count: 16 * 1024))
        stored.replaceSubrange(12..<stored.count, with: Data(repeating: 0xFF, count: stored.count - 12))
        XCTAssertThrowsError(try TaptionSnapshotCompression.decode(stored))
        XCTAssertThrowsError(try TaptionSnapshotCompression.decode(Data([0x54, 0x50, 0x5A, 0x31, 0x01])))
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
