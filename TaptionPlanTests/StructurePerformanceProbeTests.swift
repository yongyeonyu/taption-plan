import Foundation
import Observation
import TaptionPlanCore
import SwiftUI
import UIKit
import XCTest
@testable import TaptionPlan

/// 구조 성능 측정(ARC1103A01). 판정 없이 수치만 남긴다. `ARC-PROBE` 줄을 로그에서 읽는다.
/// 시뮬레이터·Debug 수치라 절대값보다 전후 배율을 본다.
@MainActor
final class StructurePerformanceProbeTests: XCTestCase {
    private func report(_ name: String, _ value: Double, unit: String = "ms") {
        print("ARC-PROBE \(name) \(String(format: "%.3f", value)) \(unit)")
    }

    private func milliseconds(repeating count: Int = 5, _ work: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<count {
            let start = ContinuousClock.now
            work()
            let parts = start.duration(to: .now).components
            best = min(best, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
        }
        return best
    }

    /// 실기기 로그(`repository_local_load`)의 행 수에 맞춘 합성 스냅샷: 장소 27,873·층 이동 3,640·활동 617·이동 342.
    private func largeSnapshot() -> TaptionDataSnapshot {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        var value = TaptionDataSnapshot.empty
        value.actuals = (0..<617).map { index in
            let start = base.addingTimeInterval(Double(index) * 3_600)
            return ActualRecord(
                planID: nil, title: "활동 \(index)", categoryID: "work",
                startedAt: start, endedAt: start.addingTimeInterval(600), source: .manual
            )
        }
        value.places = (0..<27_873).map { index in
            let start = base.addingTimeInterval(Double(index) * 600)
            return PlaceStay(
                placeKey: "place-\(index % 40)", displayName: "장소 \(index % 40)", floor: index % 9,
                span: TimeSpan(start: start, end: start.addingTimeInterval(500)), confidence: .medium,
                point: GeoPoint(latitude: 10 + Double(index) * 1e-5, longitude: 20, altitude: 30, horizontalAccuracy: 12, verticalAccuracy: 8)
            )
        }
        value.floorTransitions = (0..<3_640).map { index in
            let start = base.addingTimeInterval(Double(index) * 4_000)
            return FloorTransition(
                id: UUID(),
                placeKey: "place-\(index % 40)", fromFloor: 1, toFloor: 2, relativeAltitudeMeters: 3,
                span: TimeSpan(start: start, end: start.addingTimeInterval(60)), confidence: .medium, evidence: ["probe"]
            )
        }
        value.travel = (0..<342).map { index in
            let start = base.addingTimeInterval(Double(index) * 30_000)
            return TravelSegment(
                mode: .walking, span: TimeSpan(start: start, end: start.addingTimeInterval(600)),
                distanceMeters: 500, confidence: .medium, evidence: ["probe"]
            )
        }
        return value
    }

    private func makeModel() -> AppModel {
        AppModel(repository: InMemoryPlanRepository(), cloudSyncService: nil, registersHealthBackgroundHandler: false)
    }

    func testProbeValueSizes() {
        report("stride.SensorReading", Double(MemoryLayout<SensorReading>.stride), unit: "bytes")
        report("stride.ActualRecord", Double(MemoryLayout<ActualRecord>.stride), unit: "bytes")
        report("stride.PlaceStay", Double(MemoryLayout<PlaceStay>.stride), unit: "bytes")
        report("stride.TravelSegment", Double(MemoryLayout<TravelSegment>.stride), unit: "bytes")
        report("stride.TaptionDataSnapshot", Double(MemoryLayout<TaptionDataSnapshot>.stride), unit: "bytes")
        report("stride.AppFeatureSettings", Double(MemoryLayout<AppFeatureSettings>.stride), unit: "bytes")
        report("stride.PlanDayDataSnapshot", Double(MemoryLayout<PlanDayDataSnapshot>.stride), unit: "bytes")
    }

    func testProbeSnapshotWriteCostAndInvalidations() {
        let model = makeModel()
        let large = largeSnapshot()
        model.snapshot = large

        let counter = FireCounter()
        func track() {
            withObservationTracking { _ = model.snapshot } onChange: { counter.add() }
        }

        // 저장 뒤 `updatedAt`만 바뀌는 대입과 같은 경로.
        track()
        var stamped = model.snapshot
        stamped.updatedAt = stamped.updatedAt.addingTimeInterval(1)
        model.timestampOnlySnapshotAssignment = true
        model.snapshot = stamped
        report("invalidate.timestampOnly", Double(counter.value), unit: "fires")

        // 내용이 같은 스냅샷을 다시 대입한다(배열 저장 공간은 같다).
        counter.reset()
        track()
        let same = model.snapshot
        model.snapshot = same
        report("invalidate.sameValue", Double(counter.value), unit: "fires")

        // 다시 만든 같은 내용(저장 공간이 달라 요소를 하나씩 비교한다).
        counter.reset()
        track()
        var rebuilt = model.snapshot
        rebuilt.actuals = rebuilt.actuals.map { $0 }
        rebuilt.places = rebuilt.places.map { $0 }
        rebuilt.travel = rebuilt.travel.map { $0 }
        model.snapshot = rebuilt
        report("invalidate.rebuiltSameValue", Double(counter.value), unit: "fires")

        report("write.timestampOnly", milliseconds {
            var value = model.snapshot
            value.updatedAt = value.updatedAt.addingTimeInterval(1)
            model.timestampOnlySnapshotAssignment = true
            model.snapshot = value
        })
        report("write.rebuiltSameValue", milliseconds {
            var value = model.snapshot
            value.actuals = value.actuals.map { $0 }
            value.places = value.places.map { $0 }
            value.travel = value.travel.map { $0 }
            model.snapshot = value
        })
        var toggle = false
        report("write.settingsField", milliseconds {
            toggle.toggle()
            model.snapshot.settings.registeredCarAudioNames = toggle ? ["a"] : []
        })
        var titleIndex = 0
        report("write.oneActualTitle", milliseconds {
            titleIndex += 1
            model.snapshot.actuals[616].title = "변경 \(titleIndex)"
        })
    }

    func testProbeWidgetPayloadCost() {
        let model = makeModel()
        model.snapshot = largeSnapshot()
        report("widget.payloadFactory", milliseconds {
            _ = TaptionWidgetPayloadFactory.make(
                from: model.snapshot, now: .now, calendar: .autoupdatingCurrent, hidesSensitiveContent: false
            )
        })
    }

    func testProbeModelInit() {
        report("model.init", milliseconds { _ = makeModel() })
    }

    // MARK: 저장소

    private func makeRepository() throws -> (TaptionStoreRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arc-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try TaptionStoreV2(url: root.appendingPathComponent("store.sqlite"))
        return (TaptionStoreRepository(store: store), root)
    }

    func testProbeRepositoryLoadAndSave() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        var value = largeSnapshot()
        value.updatedAt = Date(timeIntervalSince1970: 1_790_000_000)
        try await repository.save(value)

        var best = Double.infinity
        for _ in 0..<5 {
            value.updatedAt = value.updatedAt.addingTimeInterval(1)
            let start = ContinuousClock.now
            try await repository.save(value)
            let parts = start.duration(to: .now).components
            best = min(best, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
        }
        report("repository.saveUnchanged", best)

        best = .infinity
        for _ in 0..<3 {
            let start = ContinuousClock.now
            _ = try await repository.load()
            let parts = start.duration(to: .now).components
            best = min(best, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
        }
        report("repository.load", best)
    }

    func testProbePlaceDecodeStrategies() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let places = largeSnapshot().places
        let bodies = try places.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        report("decode.bodyBytes", Double(bodies.reduce(0) { $0 + $1.utf8.count }), unit: "bytes")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        report("decode.perRow", milliseconds(repeating: 2) {
            for body in bodies { _ = try? decoder.decode(PlaceStay.self, from: Data(body.utf8)) }
        })
        report("decode.batched", milliseconds(repeating: 2) {
            var joined = Data()
            joined.reserveCapacity(bodies.reduce(2) { $0 + $1.utf8.count + 1 })
            joined.append(UInt8(ascii: "["))
            for (index, body) in bodies.enumerated() {
                if index > 0 { joined.append(UInt8(ascii: ",")) }
                joined.append(contentsOf: body.utf8)
            }
            joined.append(UInt8(ascii: "]"))
            _ = try? decoder.decode([PlaceStay].self, from: joined)
        })
        report("hash.placesHashValue", milliseconds(repeating: 3) {
            for place in places { _ = place.hashValue }
        })
        report("hash.placesIDString", milliseconds(repeating: 3) {
            for place in places { _ = "\(place.id)" }
        })
    }

    // MARK: 지도 홈 본문 평가

    /// 지도 홈을 창에 올리고 모델 쓰기마다 본문이 몇 번 평가되는지 센다.
    func testProbeMapHomeBodyInvalidations() async throws {
        let model = AppModel(
            repository: InMemoryPlanRepository(snapshot: largeSnapshot()),
            cloudSyncService: nil, registersHealthBackgroundHandler: false
        )
        await model.bootstrap()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let host = UIHostingController(rootView: MapHomeView(model: model, proAccess: TaptionProAccessController()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(6))

        func measure(_ name: String, _ write: (Int) -> Void) async throws {
            MapHomePlaybackProbe.start()
            for index in 0..<10 {
                write(index)
                try await Task.sleep(for: .milliseconds(150))
            }
            let totals = MapHomePlaybackProbe.currentTotals()
            MapHomePlaybackProbe.stop()
            let body = totals["body"]
            report("mapBody.\(name).evals", Double(body?.calls ?? 0), unit: "per10writes")
            report("mapBody.\(name).bodyMs", body?.ms ?? 0)
        }
        try await measure("idle") { _ in }
        try await measure("timestampOnly") { index in
            var value = model.snapshot
            value.updatedAt = value.updatedAt.addingTimeInterval(Double(index + 1))
            model.timestampOnlySnapshotAssignment = true
            model.snapshot = value
        }
        try await measure("sameSnapshot") { _ in
            let value = model.snapshot
            model.snapshot = value
        }
        try await measure("otherDaySettings") { index in
            model.snapshot.settings.recentCarAudioNames = ["probe-\(index)"]
        }
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        try await measure("latestReading") { index in
            model.latestSensorReading = SensorReading(timestamp: base.addingTimeInterval(Double(index)))
        }
        try await measure("saveToken") { index in
            model.sensorSaveToken = index + 100
        }
        try await measure("heartRate") { index in
            model.latestHeartRate = Double(60 + index)
        }
    }
}

private final class FireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
    func reset() { lock.withLock { count = 0 } }
}
