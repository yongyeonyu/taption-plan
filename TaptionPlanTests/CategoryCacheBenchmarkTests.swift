import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

/// CRS0925W01 watchdog 강제종료 근본수정(분류/이동모드/화랑이동작 결과 캐시)의
/// 효과를 수치로 증명한다. 캐시 hit 경로가 재계산(miss) 대비 얼마나 빠른지,
/// 뷰 갱신처럼 같은 하루 actuals를 여러 번 재분류할 때 총시간 변화를 측정한다.
final class CategoryCacheBenchmarkTests: XCTestCase {

    private func makeDayActuals(count: Int) -> [ActualRecord] {
        let titles = [
            "지하철 이동", "버스 탑승", "자동차 운전", "걷기", "달리기",
            "업무 집중", "수업 청강", "취미 활동", "식사", "요리",
            "수면", "운동", "집안일", "미확인 활동", "회의",
        ]
        let base = Date(timeIntervalSinceReferenceDate: 780_000_000)
        return (0..<count).map { i in
            ActualRecord(
                planID: nil,
                title: titles[i % titles.count],
                categoryID: "activity",
                startedAt: base.addingTimeInterval(Double(i) * 60),
                endedAt: base.addingTimeInterval(Double(i) * 60 + 300),
                source: .motion
            )
        }
    }

    private func elapsedMs(_ block: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        block()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    }

    func testCategoryClassificationCacheSpeedup() {
        let actuals = makeDayActuals(count: 400)
        let firstPass = elapsedMs {
            for a in actuals { _ = RecordAnalysisCategoryPolicy.categoryID(for: a) }
        }
        let repeatPasses = elapsedMs {
            for _ in 0..<20 {
                for a in actuals { _ = RecordAnalysisCategoryPolicy.categoryID(for: a) }
            }
        }
        let perHitPass = repeatPasses / 20.0
        let speedup = firstPass / max(perHitPass, 0.0001)
        print("[CRS0925W01] categoryID — firstPass(miss) \(String(format: "%.3f", firstPass))ms, "
            + "hitPass avg \(String(format: "%.3f", perHitPass))ms over 20 renders, speedup ×\(String(format: "%.1f", speedup))")
        XCTAssertGreaterThan(speedup, 2.0,
            "categoryID 캐시 speedup ×\(String(format: "%.1f", speedup)) (miss \(String(format: "%.3f", firstPass))ms vs hit \(String(format: "%.3f", perHitPass))ms) — 2배 미만이면 캐시 효과 미흡")
    }

    func testMovementModeCacheSpeedup() {
        let actuals = makeDayActuals(count: 400)
        let firstPass = elapsedMs {
            for a in actuals { _ = MovementPresentation.mode(for: a) }
        }
        let repeatPasses = elapsedMs {
            for _ in 0..<20 {
                for a in actuals { _ = MovementPresentation.mode(for: a) }
            }
        }
        let perHitPass = repeatPasses / 20.0
        let speedup = firstPass / max(perHitPass, 0.0001)
        print("[CRS0925W01] mode — firstPass(miss) \(String(format: "%.3f", firstPass))ms, "
            + "hitPass avg \(String(format: "%.3f", perHitPass))ms over 20 renders, speedup ×\(String(format: "%.1f", speedup))")
        XCTAssertGreaterThan(speedup, 2.0,
            "mode 캐시 speedup ×\(String(format: "%.1f", speedup)) (miss \(String(format: "%.3f", firstPass))ms vs hit \(String(format: "%.3f", perHitPass))ms) — 2배 미만이면 캐시 효과 미흡")
    }

    func testStickmanActionCacheSpeedup() {
        let actuals = makeDayActuals(count: 400)
        let date = actuals[actuals.count / 2].startedAt
        let firstCall = elapsedMs {
            _ = MapHomeStickmanActionResolver.action(
                at: date, actuals: actuals, travel: [], places: [],
                frequentPlaces: [], readings: [], sleepSessions: []
            )
        }
        let repeatCalls = elapsedMs {
            for _ in 0..<200 {
                _ = MapHomeStickmanActionResolver.action(
                    at: date, actuals: actuals, travel: [], places: [],
                    frequentPlaces: [], readings: [], sleepSessions: []
                )
            }
        }
        let perHit = repeatCalls / 200.0
        let speedup = firstCall / max(perHit, 0.00001)
        print("[CRS0925W01] stickman action — firstCall(miss) \(String(format: "%.4f", firstCall))ms, "
            + "hitCall avg \(String(format: "%.4f", perHit))ms over 200 frames, speedup ×\(String(format: "%.1f", speedup))")
        XCTAssertGreaterThan(speedup, 2.0,
            "stickman action 캐시 speedup ×\(String(format: "%.1f", speedup)) (miss \(String(format: "%.4f", firstCall))ms vs hit \(String(format: "%.4f", perHit))ms) — 2배 미만이면 캐시 효과 미흡")
    }

    func testCacheDoesNotChangeClassification() {
        let actuals = makeDayActuals(count: 60)
        let firstResults = actuals.map { RecordAnalysisCategoryPolicy.categoryID(for: $0) }
        let secondResults = actuals.map { RecordAnalysisCategoryPolicy.categoryID(for: $0) }
        XCTAssertEqual(firstResults, secondResults, "캐시 전후 분류 결과 불일치")
        XCTAssertEqual(
            RecordAnalysisCategoryPolicy.categoryID(for: actuals.first { $0.title == "수면" }!),
            "sleep"
        )
        XCTAssertEqual(
            RecordAnalysisCategoryPolicy.categoryID(for: actuals.first { $0.title == "식사" }!),
            "eating"
        )
    }
}
