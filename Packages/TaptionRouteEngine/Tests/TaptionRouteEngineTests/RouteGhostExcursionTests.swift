import Foundation
import Testing
@testable import TaptionRouteEngine

/// 짧게 튄 유령 체류 회귀 시험 (CLN1110A01). 합성 좌표만 쓴다.
struct RouteGhostExcursionTests {
    private let base = Date(timeIntervalSince1970: 2_000_000)
    private let home = 37.5

    private func sample(_ seconds: TimeInterval, _ latitude: Double, accuracy: Double = 5, mode: RouteTravelMode = .unknown) -> RouteSample {
        RouteSample(
            timestamp: base.addingTimeInterval(seconds),
            coordinate: .init(latitude: latitude, longitude: 127),
            horizontalAccuracyMeters: accuracy,
            mode: mode
        )
    }

    /// 집에 있다가 `ghostStart`부터 `ghostEnd`까지 1.1km 떨어진 곳으로 튀었다 `returnAt`에 돌아온다.
    private func day(
        ghostStart: TimeInterval, ghostEnd: TimeInterval, returnAt: TimeInterval,
        accuracy: Double, mode: RouteTravelMode = .unknown
    ) -> (values: [RouteSample], ghost: [UUID]) {
        var values = stride(from: 0.0, through: 300, by: 10).map { sample($0, home) }
        let ghost = stride(from: ghostStart, through: ghostEnd, by: 10).map { sample($0, home + 0.01, accuracy: accuracy, mode: mode) }
        values += ghost
        values += stride(from: returnAt, through: returnAt + 300, by: 10).map { sample($0, home) }
        return (values, ghost.map(\.id))
    }

    private func pathIDs(_ report: RouteFilterResult) -> Set<UUID> {
        Set(report.log.segments.flatMap { $0.pathSamples + $0.boundarySamples }.map(\.id))
    }

    @Test func impossibleJumpAndBackIsSuppressedWithEvidence() {
        let (values, ghost) = day(ghostStart: 310, ghostEnd: 420, returnAt: 430, accuracy: 5)
        let report = RouteLoggerRouteFilter().filterWithReport(values)
        let ghostSet = Set(ghost)
        let reasons = Dictionary(grouping: report.decisions.filter { ghostSet.contains($0.id) }, by: \.reason)
        // 튄 첫 점은 원래대로 불가능한 속도로 빠지고, 재기준으로 들어온 나머지는 유령 체류로 빠진다.
        #expect(reasons[.ghostExcursion]?.count == ghost.count - 1)
        #expect(Set(reasons.keys).isSubset(of: [.ghostExcursion, .impossibleSpeed]))
        #expect(pathIDs(report).isDisjoint(with: ghostSet))
        #expect(report.log.normalizedSamples.count == values.count, "원본 표본은 그대로 남는다")
        #expect(report.log.segments.count == 1, "돌아온 점이 경로를 새로 끊지 않는다")
    }

    @Test func poorAccuracyJumpIsSuppressedEvenAtCarSpeed() {
        // 앞뒤 60초 틈: 왕복 2.2km/120초 = 18m/s라 속도로는 가능하지만 정확도가 나쁘다.
        let (values, ghost) = day(ghostStart: 360, ghostEnd: 450, returnAt: 510, accuracy: 65)
        let report = RouteLoggerRouteFilter().filterWithReport(values)
        #expect(Set(report.decisions.filter { $0.reason == .ghostExcursion }.map(\.id)) == Set(ghost))
    }

    @Test func preciseDetourAtPlausibleSpeedIsKept() {
        let (values, ghost) = day(ghostStart: 360, ghostEnd: 450, returnAt: 510, accuracy: 5)
        let report = RouteLoggerRouteFilter().filterWithReport(values)
        #expect(!report.decisions.contains { $0.reason == .ghostExcursion })
        #expect(!pathIDs(report).isDisjoint(with: Set(ghost)))
    }

    @Test func walkingEvidenceKeepsTheExcursion() {
        let (values, _) = day(ghostStart: 310, ghostEnd: 420, returnAt: 430, accuracy: 65, mode: .walking)
        let report = RouteLoggerRouteFilter().filterWithReport(values)
        #expect(!report.decisions.contains { $0.reason == .ghostExcursion })
    }

    @Test func stayLongerThanThreeMinutesIsKept() {
        let (values, _) = day(ghostStart: 310, ghostEnd: 550, returnAt: 560, accuracy: 65)
        let report = RouteLoggerRouteFilter().filterWithReport(values)
        #expect(!report.decisions.contains { $0.reason == .ghostExcursion })
    }

    @Test func pointOnTheWayBetweenNeighboursIsKept() {
        // 앞뒤가 서로 먼 진짜 이동: 가운데 점은 직선 경로 위라 돌아간 거리가 없다.
        let values = [sample(0, 37.50), sample(30, 37.51, accuracy: 65), sample(60, 37.52)]
        #expect(RouteGhostExcursion.ranges(in: values).isEmpty)
    }

    @Test func excursionWithoutReturnIsKept() {
        let values = [sample(0, home), sample(10, home + 0.01, accuracy: 65), sample(20, home + 0.01, accuracy: 65)]
        #expect(RouteGhostExcursion.ranges(in: values).isEmpty)
    }

    // MARK: - REV1110A06: 실제 이동을 지우지 않는다

    private func point(_ seconds: TimeInterval, north: Double, east: Double = 0, accuracy: Double = 5, mode: RouteTravelMode = .unknown) -> RouteSample {
        RouteSample(
            timestamp: base.addingTimeInterval(seconds),
            coordinate: .init(latitude: home + north / 111_320, longitude: 127 + east / (111_320 * cos(home * .pi / 180))),
            horizontalAccuracyMeters: accuracy,
            mode: mode
        )
    }

    @Test func fastTrainBendIsKept() {
        // 80m/s 기차, 30초 간격, 40도 굽은 선로.
        let turn = 40.0 * Double.pi / 180
        var values = (0..<3).map { point(Double($0) * 30, north: Double($0) * 2_400, mode: .train) }
        values += (1...2).map { point(60 + Double($0) * 30, north: 4_800 + Double($0) * 2_400 * cos(turn), east: Double($0) * 2_400 * sin(turn), mode: .train) }
        #expect(RouteGhostExcursion.ranges(in: values).isEmpty)
        let report = RouteLoggerRouteFilter().filterWithReport(values)
        #expect(!report.decisions.contains { $0.reason == .ghostExcursion })
        #expect(pathIDs(report).count == values.count)
    }

    @Test func sparseVisitHoursApartIsKept() {
        let values = [point(0, north: 0), point(3 * 3_600, north: 1_100, accuracy: 65), point(6 * 3_600, north: 0)]
        #expect(RouteGhostExcursion.ranges(in: values).isEmpty)
    }

    @Test func roundTripLongerThanSixMinutesIsKept() {
        // 묶음 자체는 짧아도 떠나서 돌아오기까지 7분이면 실제로 다녀올 수 있다.
        let values = [point(0, north: 0), point(200, north: 1_100, accuracy: 65), point(420, north: 0)]
        #expect(RouteGhostExcursion.ranges(in: values).isEmpty)
    }

    @Test func coarseCarOutAndBackKeepsItsTurnaround() {
        // 정확도 65m 차량이 20m/s로 막다른 길까지 갔다 돌아온다.
        let values = [0.0, 300, 600, 300, 0].enumerated().map { point(Double($0.offset) * 15, north: $0.element, accuracy: 65, mode: .automotive) }
        #expect(RouteGhostExcursion.ranges(in: values).isEmpty)
        let coarseUnknown = [0.0, 300, 600, 300, 0].enumerated().map { point(Double($0.offset) * 15, north: $0.element, accuracy: 65) }
        #expect(RouteGhostExcursion.ranges(in: coarseUnknown).isEmpty, "앞뒤도 거칠면 추정 위치로 단정하지 않는다")
    }

    @Test func trainSpeedOutAndBackIsNotCalledImpossible() {
        // 100m/s는 도로로는 불가능하지만 기차 표본이면 가능하다.
        let values = [point(0, north: 0, mode: .train), point(30, north: 3_000, mode: .train), point(60, north: 0, mode: .train)]
        #expect(RouteGhostExcursion.ranges(in: values).isEmpty)
        let unknown = [point(0, north: 0), point(30, north: 3_000), point(60, north: 0)]
        #expect(RouteGhostExcursion.ranges(in: unknown) == [1..<2])
    }

    @Test func sampleAfterGhostIsJudgedAgainstLastKeptSample() {
        // 기지국 핑퐁 R1 G1 R2 G2 R3: 유령만 빠지고 제자리 표본은 모두 남는다.
        let values = [
            point(0, north: 0), point(10, north: 1_100, accuracy: 65), point(20, north: 0),
            point(30, north: -1_100, accuracy: 65), point(40, north: 0),
        ]
        #expect(RouteGhostExcursion.ranges(in: values) == [1..<2, 3..<4])
    }

    @Test func ghostSamplesStayInNormalizedSamples() {
        let (values, ghost) = day(ghostStart: 360, ghostEnd: 450, returnAt: 510, accuracy: 65)
        let report = RouteLoggerRouteFilter().filterWithReport(values)
        #expect(Set(ghost).isSubset(of: Set(report.log.normalizedSamples.map(\.id))), "원본 표본은 지우지 않는다")
        #expect(pathIDs(report).isDisjoint(with: Set(ghost)))
    }
}
