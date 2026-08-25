import Foundation
import XCTest
@testable import TaptionPlanCore

final class CoreEngineContractsTests: XCTestCase {
    func testDayKeySortsChronologically() {
        let earlier = TaptionPlanDayKey(year: 2026, month: 8, day: 24)
        let later = TaptionPlanDayKey(year: 2026, month: 8, day: 25)

        XCTAssertLessThan(earlier, later)
    }

    func testTimestampIndexUsesBoundsForDayQueries() {
        let start = Date(timeIntervalSince1970: 100)
        let index = TaptionPlanTimestampIndex(
            timestamps: [start.addingTimeInterval(20), start, start.addingTimeInterval(10)]
        )

        XCTAssertEqual(index.timestamps, [start, start.addingTimeInterval(10), start.addingTimeInterval(20)])
        XCTAssertEqual(index.prefixCount(through: start.addingTimeInterval(10)), 2)
        XCTAssertEqual(index.range(from: start.addingTimeInterval(5), through: start.addingTimeInterval(20)), 1..<3)
    }

    func testSnapshotRevisionIsImmutableAndComparable() {
        let first = TaptionPlanDayDataSnapshot(
            day: .init(year: 2026, month: 8, day: 25),
            revision: 1,
            generation: 2,
            timestamps: []
        )
        let second = TaptionPlanDayDataSnapshot(
            day: first.day,
            revision: 2,
            generation: 1,
            timestamps: []
        )

        XCTAssertTrue(second.isNewer(than: first))
        XCTAssertFalse(first.isNewer(than: second))
    }

    func testBudgetPublishesAtMostSixtyHertzAndFinalImmediately() {
        var engine = TaptionPlanNLEInputBudgetEngine(publishInterval: 1.0 / 60.0)
        let generation = engine.activeGeneration

        XCTAssertTrue(engine.submit(at: 0, generation: generation).shouldPublish)
        XCTAssertFalse(engine.submit(at: 0.001, generation: generation).shouldPublish)
        XCTAssertTrue(engine.submit(at: 1.0 / 60.0, generation: generation).shouldPublish)
        XCTAssertTrue(engine.submit(at: 1.0 / 60.0, generation: generation, isFinal: true).shouldPublish)
    }

    func testCancelledGenerationDoesNotPublishLateEvents() {
        var engine = TaptionPlanNLEInputBudgetEngine()
        let cancelled = engine.activeGeneration
        engine.cancelGeneration(cancelled)

        XCTAssertFalse(engine.submit(at: 1, generation: cancelled).shouldPublish)
        XCTAssertEqual(engine.activeGeneration, cancelled + 1)
        XCTAssertTrue(engine.submit(at: 1, generation: engine.activeGeneration).shouldPublish)
    }

    func testSynthetic240HzInputPublishesAtDisplayRateAndFlushesFinal() {
        var engine = TaptionPlanNLEInputBudgetEngine()
        let generation = engine.activeGeneration
        var publishCount = 0
        let sampleCount = 2_400

        for index in 0..<sampleCount {
            let decision = engine.submit(
                at: Double(index) / 240,
                generation: generation
            )
            if decision.shouldPublish { publishCount += 1 }
        }
        let final = engine.submit(
            at: Double(sampleCount) / 240,
            generation: generation,
            isFinal: true
        )

        XCTAssertGreaterThan(publishCount, 500)
        XCTAssertLessThanOrEqual(publishCount, 601)
        XCTAssertTrue(final.shouldPublish)
        XCTAssertTrue(final.isFinal)
    }

    func testSynthetic240HzInputBenchmark() {
        measure {
            var engine = TaptionPlanNLEInputBudgetEngine()
            for index in 0..<24_000 {
                _ = engine.submit(at: Double(index) / 240)
            }
        }
    }

    func testSynthetic240HzHandlerP95StaysWithinInputBudget() {
        var engine = TaptionPlanNLEInputBudgetEngine()
        var durations = [UInt64]()
        durations.reserveCapacity(24_000)
        for index in 0..<24_000 {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            _ = engine.submit(at: Double(index) / 240)
            durations.append(
                DispatchTime.now().uptimeNanoseconds - startedAt
            )
        }
        durations.sort()
        let p95 = durations[Int(Double(durations.count - 1) * 0.95)]
        let p95Milliseconds = Double(p95) / 1_000_000
        print("NLE_240HZ_P95_MS=\(p95Milliseconds)")
        XCTAssertLessThanOrEqual(p95Milliseconds, 4.17)
    }
}
