import Foundation
import XCTest
@testable import TaptionPlanCore

final class RuntimeEfficiencyTests: XCTestCase {
    func testByteUUIDOrderingMatchesCanonicalStringOrdering() {
        let fixed = ["00000000-0000-0000-0000-000000000000", "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
            "00000001-0000-0000-0000-000000000000", "00000000-0001-0000-0000-000000000000"]
            .map { UUID(uuidString: $0)! }
        let values = fixed + (0..<1_024).map { _ in UUID() }
        XCTAssertEqual(values.sorted(by: TaptionCanonicalUUIDOrder.precedes),
            values.sorted { $0.uuidString < $1.uuidString })
        XCTAssertFalse(TaptionCanonicalUUIDOrder.precedes(fixed[0], fixed[0]))
    }

    func testCacheProtectsRecentlyReadEntryAndUpdatesWithoutEviction() {
        var cache = TaptionBoundedCache<Int, String>(capacity: 3)
        for key in 1...3 { cache.insert(String(key), for: key) }
        XCTAssertEqual(cache.value(for: 1), "1")
        cache.insert("4", for: 4)
        XCTAssertNil(cache.peek(2))
        XCTAssertEqual(cache.peek(3), "3")
        cache.insert("updated", for: 1)
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache.peek(1), "updated")
        XCTAssertEqual(cache.removeValue(for: 4), "4")
        cache.removeAll(keepingCapacity: true)
        XCTAssertEqual(cache.count, 0)
        cache.insert("new", for: 2)
        XCTAssertEqual(cache.value(for: 2), "new")
    }

    func testCacheClockRolloverRetainsRecencyAndBound() {
        var cache = TaptionBoundedCache<Int, String>(capacity: 2)
        cache.insert("a", for: 1)
        cache.insert("b", for: 2)
        cache.clock = .max
        XCTAssertEqual(cache.value(for: 1), "a")
        XCTAssertEqual(cache.mostRecentKey(where: { _ in true }), 1)
        cache.insert("c", for: 3)
        XCTAssertNil(cache.peek(2))
        XCTAssertEqual(cache.count, 2)
    }

    func testCacheCopiesDoNotChangeOriginalValuesOrEvictionOrder() {
        var original = TaptionBoundedCache<Int, Int>(capacity: 2)
        original.insert(10, for: 1)
        original.insert(20, for: 2)
        var copy = original
        _ = copy.value(for: 1)
        copy.insert(30, for: 3)
        XCTAssertNil(copy.peek(2))
        XCTAssertEqual(original.peek(2), 20)
        original.insert(40, for: 4)
        XCTAssertNil(original.peek(1))
        XCTAssertEqual(copy.peek(1), 10)
    }

    func testDuplicateInputDoesNotDelayNextChangedValue() {
        var projection = TaptionLatestValueProjection<Int>()
        XCTAssertEqual(projection.submit(1, at: 1), 1)
        XCTAssertNil(projection.submit(1, at: 1.02))
        XCTAssertEqual(projection.submit(2, at: 1.024), 2)
    }

    func test240HzInputKeepsLatestAndFlushesLastSampleImmediately() {
        var projection = TaptionLatestValueProjection<Int>()
        projection.begin(with: -1)
        var published = 0
        for index in 0..<240 {
            if projection.submit(index, at: Double(index) / 240) != nil { published += 1 }
        }
        XCTAssertLessThanOrEqual(published, 60)
        XCTAssertGreaterThanOrEqual(published, 59)
        XCTAssertEqual(projection.latestValue, 239)
        XCTAssertEqual(projection.finish(at: 239.0 / 240), 239)
        XCTAssertEqual(projection.renderedValue, 239)
        XCTAssertNil(projection.finish(at: 1))
        projection.reset()
        XCTAssertNil(projection.finish(at: 1))
        XCTAssertEqual(projection.submit(5, at: 1), 5)
        projection.synchronize(with: 7)
        XCTAssertEqual(projection.latestValue, 7)
        XCTAssertEqual(projection.renderedValue, 7)
    }

    func testInvalidClockCannotPoisonFutureInput() {
        var projection = TaptionLatestValueProjection<Int>()
        XCTAssertNil(projection.submit(3, at: .nan))
        XCTAssertEqual(projection.finish(at: 1), 3)
    }

    func testBoundedCacheHitBenchmarkAgainstArrayRecency() {
        let capacity = 64
        let samples = 100_000
        var legacy: [Int: Int] = [:]
        var recency: [Int] = []
        var cache = TaptionBoundedCache<Int, Int>(capacity: capacity)
        for key in 0..<capacity {
            legacy[key] = key
            recency.append(key)
            cache.insert(key, for: key)
        }
        var legacyChecksum = 0
        let oldStart = DispatchTime.now().uptimeNanoseconds
        for index in 0..<samples {
            let key = index % capacity
            legacyChecksum += legacy[key] ?? 0
            recency.removeAll { $0 == key }
            recency.append(key)
        }
        let oldDuration = DispatchTime.now().uptimeNanoseconds - oldStart
        var checksum = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<samples { checksum += cache.value(for: index % capacity) ?? 0 }
        let duration = DispatchTime.now().uptimeNanoseconds - start
        XCTAssertEqual(checksum, legacyChecksum)
        XCTAssertEqual(cache.count, capacity)
        print("CACHE_100K_HITS_LEGACY_MS=\(Double(oldDuration) / 1_000_000)")
        print("CACHE_100K_HITS_BOUNDED_MS=\(Double(duration) / 1_000_000)")
    }
}
