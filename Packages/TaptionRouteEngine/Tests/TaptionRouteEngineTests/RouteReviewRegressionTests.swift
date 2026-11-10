import Foundation
import Testing
@testable import TaptionRouteEngine

/// 리뷰 지적 회귀 시험 (REV1110A04).
struct RouteReviewRegressionTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func sample(_ seconds: TimeInterval, _ latitude: Double, accuracy: Double = 5) -> RouteSample {
        RouteSample(
            timestamp: base.addingTimeInterval(seconds),
            coordinate: .init(latitude: latitude, longitude: 126),
            horizontalAccuracyMeters: accuracy,
            mode: .walking
        )
    }

    @Test func glitchInsideRejectedRunDoesNotBlockReanchor() {
        var values = [sample(0, 34.2, accuracy: 65)]
        for second in 1...3 { values.append(sample(Double(second), 37.5 + Double(second) * 0.000005)) }
        values.append(sample(4, 30))
        for second in 5...200 { values.append(sample(Double(second), 37.5 + Double(second) * 0.000005)) }

        let report = RouteLoggerRouteFilter().filterWithReport(values)

        #expect(report.log.segments.flatMap(\.pathSamples).contains { $0.id == values.last?.id })
        #expect(report.decisions.contains { $0.id == values[4].id && $0.reason == .impossibleSpeed })
    }

    @Test func segmentIDsAreStableAcrossFilterRuns() {
        let values = (0..<30).map { sample(Double($0) * 5, 37 + Double($0) * 0.0001) }
        let filter = RouteLoggerRouteFilter()
        let first = filter.filter(values).segments.map(\.id)
        let second = filter.filter(values).segments.map(\.id)

        #expect(!first.isEmpty)
        #expect(first == second)
    }

    @Test func lowConfidenceSubwayEvidenceDoesNotReplaceGPSPath() {
        let path = [sample(0, 37), sample(60, 37.01)]
        let subwayCoordinates = [RouteCoordinate(latitude: 36, longitude: 127), .init(latitude: 36.1, longitude: 127)]
        func segment(_ evidence: SubwayRouteEvidence) -> RouteSegment {
            RouteSegment(start: base, end: base.addingTimeInterval(60), mode: .subway, samples: path, pathSamples: path, subwayEvidence: evidence)
        }
        let weak = segment(.init(lineName: "2호선", stationNames: ["시청", "을지로입구"], coordinates: subwayCoordinates, confidence: 0.3))
        let unnamed = segment(.init(lineName: "2호선", stationNames: ["시청"], coordinates: subwayCoordinates, confidence: 0.9))
        let trusted = segment(.init(lineName: "2호선", stationNames: ["시청", "을지로입구"], coordinates: subwayCoordinates, confidence: 0.9))

        #expect(weak.coordinates == path.map(\.coordinate))
        #expect(unnamed.coordinates == path.map(\.coordinate))
        #expect(trusted.coordinates == subwayCoordinates)
    }

    @Test func segmentCodableRoundTripKeepsCoordinates() throws {
        let path = [sample(0, 37), sample(60, 37.01)]
        let segment = RouteSegment(start: base, end: base.addingTimeInterval(60), mode: .walking, samples: path, pathSamples: path)
        let decoded = try JSONDecoder().decode(RouteSegment.self, from: JSONEncoder().encode(segment))

        #expect(decoded == segment)
        #expect(decoded.coordinates == path.map(\.coordinate))
    }

    @Test func zeroGapFarJumpBreaksConnection() {
        #expect(RouteSparseConnectionPolicy.breaksConnection(gapDuration: 0, distanceMeters: 5_000))
        #expect(!RouteSparseConnectionPolicy.breaksConnection(gapDuration: 0, distanceMeters: 30))
    }
}
