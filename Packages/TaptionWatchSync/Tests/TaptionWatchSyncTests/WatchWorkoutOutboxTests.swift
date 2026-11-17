import XCTest
import TaptionPlanCore
@testable import TaptionWatchSync

// WSY1117A01: 운동 요약·묶음은 전송을 건 뒤에도 iPhone ack가 올 때까지 outbox에 남아 다시 보낼 수 있어야 한다.
final class WatchWorkoutOutboxTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 816_000_000.123_456)

    private func summary(sessionID: UUID, sequence: Int) -> TaptionWatchSensorSummary {
        TaptionWatchSensorSummary(
            sessionID: sessionID, sequence: sequence, workoutKind: .walking,
            linkedPlanID: nil, linkedPlanTitle: nil, linkedCategoryID: nil,
            startedAt: start, endedAt: start.addingTimeInterval(Double(sequence) * 30),
            isFinal: false, accelerometerSampleCount: 100 * sequence,
            accelerometerAverageG: nil, peakAccelerationG: 1.2,
            gyroscopeSampleCount: 0, gyroscopeAverageRadiansPerSecond: nil,
            peakRotationRateRadiansPerSecond: nil, gravity: nil, userAccelerationG: nil,
            rotationRateRadiansPerSecond: nil, attitudeRadians: nil,
            relativeAltitudeMeters: nil, pressureKilopascals: nil, stepCount: 40 * sequence,
            distanceMeters: nil, floorsAscended: nil, floorsDescended: nil,
            latestHeartRate: 110, averageHeartRate: 105, maximumHeartRate: 120,
            activeEnergyKilocalories: nil, isAmbient: false
        )
    }

    private func chunk(sessionID: UUID, sequence: Int) -> TaptionWatchAccelerationChunk {
        let base = start.addingTimeInterval(Double(sequence - 1) * 30)
        return TaptionWatchAccelerationChunk(
            sessionID: sessionID, sequence: sequence, startedAt: base,
            endedAt: base.addingTimeInterval(3),
            samples: (0..<30).map { index in
                TaptionWatchAccelerationSample(
                    capturedAt: base.addingTimeInterval(Double(index) * 0.1),
                    acceleration: TaptionWatchSensorVector3(x: 0, y: 0.1, z: 1),
                    sessionID: sessionID, sequence: index + 1, isAmbient: false
                )
            }
        )
    }

    private func temporaryStore() throws -> (TaptionPlanV3Store, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WSY1117A01-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try TaptionPlanV3Store(
            url: directory.appendingPathComponent("watch.sqlite"),
            device: .appleWatch
        )
        return (store, directory)
    }

    func testWorkoutItemsStayInOutboxUntilAcknowledged() async throws {
        let (store, directory) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let summary = summary(sessionID: sessionID, sequence: 1)
        let chunk = chunk(sessionID: sessionID, sequence: 1)
        let items = try TaptionWatchWorkoutOutbox.items(summaries: [summary], chunks: [chunk])

        try await store.appendRawEvents([], outboxItems: items)
        // 같은 요약을 다시 넣어도(대기열 재시도) 인코딩이 같아 충돌 없이 한 건씩 남는다.
        try await store.appendRawEvents(
            [],
            outboxItems: try TaptionWatchWorkoutOutbox.items(summaries: [summary], chunks: [chunk])
        )

        let pending = try await store.pendingOutboxItems(limit: 10)
        let summaryID = "summary:\(summary.rawEventID)"
        let chunkID = "chunk:\(chunk.id.uuidString)"
        XCTAssertEqual(Set(pending.map(\.id)), [summaryID, chunkID])
        XCTAssertEqual(
            Set(TaptionWatchAmbientAcknowledgementRetryPolicy.pendingDeliveryIDs(from: pending)),
            [summaryID, chunkID],
            "ack 재시도 대상"
        )

        try await store.deleteOutboxItems(ids: [summaryID])
        let remaining = try await store.pendingOutboxItems(limit: 10)
        XCTAssertEqual(remaining.map(\.id), [chunkID])
    }

    /// 전송 형식은 그대로: 같은 키에 예전과 같이 디코드되는 JSON을 싣고, ID는 지금 iPhone이 ack하는 접두어다.
    func testWorkoutItemsKeepTheExistingEnvelopeFormat() throws {
        let sessionID = UUID()
        let summary = summary(sessionID: sessionID, sequence: 2)
        let chunk = chunk(sessionID: sessionID, sequence: 2)
        let items = try TaptionWatchWorkoutOutbox.items(summaries: [summary], chunks: [chunk])
        let decoder = JSONDecoder()

        let summaryItem = try XCTUnwrap(items.first { $0.id == "summary:\(sessionID.uuidString):2" })
        XCTAssertEqual(summaryItem.kind, TaptionWatchEnvelope.sensorSummaryKey)
        XCTAssertEqual(try decoder.decode(TaptionWatchSensorSummary.self, from: summaryItem.payload), summary)
        let chunkItem = try XCTUnwrap(items.first { $0.id == "chunk:\(chunk.id.uuidString)" })
        XCTAssertEqual(chunkItem.kind, TaptionWatchEnvelope.accelerationChunkKey)
        XCTAssertEqual(try decoder.decode(TaptionWatchAccelerationChunk.self, from: chunkItem.payload), chunk)

        var gate = TaptionWatchAmbientLiveDeliveryGate()
        for item in items {
            XCTAssertTrue(gate.reserve(id: item.id, payloadBytes: item.payload.count, isReachable: true, now: 1))
        }
    }
}
