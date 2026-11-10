import XCTest
@testable import TaptionPlan

/// 짧은 정지로 쪼개진 이동 합치기와 유령 체류 빼기 회귀 시험 (CLN1110A01). 합성 자료만 쓴다.
final class MovementFragmentMergeTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)
    private var day: TimeSpan { TimeSpan(start: base.addingTimeInterval(-3_600), end: base.addingTimeInterval(86_400)) }

    private func span(_ start: TimeInterval, _ end: TimeInterval) -> TimeSpan {
        TimeSpan(start: base.addingTimeInterval(start), end: base.addingTimeInterval(end))
    }

    private func motion(_ kind: MotionKind, _ start: TimeInterval, _ end: TimeInterval) -> MotionActivityRecord {
        MotionActivityRecord(span: span(start, end), motion: kind, confidence: .high)
    }

    private func records(_ activities: [MotionActivityRecord], existing: [ActualRecord] = [], protected: Set<UUID> = []) -> [ActualRecord] {
        MotionActivityActualEngine.records(from: activities, existing: existing, inside: day, protectedIDs: protected)
    }

    // MARK: - Core Motion 기록

    func testWalkSignalWaitWalkBecomesOneRecordWithFirstPieceID() {
        let first = motion(.walking, 0, 150)
        let result = records([first, motion(.stationary, 150, 240), motion(.walking, 240, 420)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.behavior, MotionKind.walking.rawValue)
        XCTAssertEqual(result.first?.endedAt, base.addingTimeInterval(420))
        XCTAssertEqual(result.first?.id, MotionActivityActualEngine.stableID(for: first), "첫 조각의 식별자를 이어 쓴다")
        XCTAssertTrue(result.first?.evidence.contains("짧은 멈춤 1곳 합침") == true, "정지 한 곳만 센다")
    }

    func testEvidenceCountsOnlyPausesNotWalkingPieces() {
        let twoPauses = records([
            motion(.walking, 0, 150), motion(.stationary, 150, 240), motion(.walking, 240, 420),
            motion(.stationary, 420, 480), motion(.walking, 480, 700),
        ])
        XCTAssertEqual(twoPauses.count, 1)
        XCTAssertTrue(twoPauses.first?.evidence.contains("짧은 멈춤 2곳 합침") == true)
        let gapOnly = records([motion(.walking, 0, 120), motion(.walking, 200, 400)])
        XCTAssertEqual(gapOnly.first?.evidence.filter { $0.contains("멈춤") }, [])
        XCTAssertTrue(gapOnly.first?.evidence.contains("짧은 끊김 이어 붙임") == true)
        XCTAssertEqual(records([motion(.walking, 0, 150)]).first?.evidence.count, 2, "합치지 않은 기록에는 근거를 더하지 않는다")
    }

    // MARK: - REV1110A06: 합친 기록의 숨김·수정

    private var crossing: [MotionActivityRecord] { [motion(.walking, 0, 150), motion(.stationary, 150, 240), motion(.walking, 240, 420)] }

    func testMergedRecordStaysMergedWhenItsIDIsProtected() throws {
        let mergedID = try XCTUnwrap(records(crossing).first?.id)
        // 사용자가 합친 기록을 숨기거나 고치면 그 식별자가 보호 목록에 들어온다.
        let again = records(crossing, protected: [mergedID])
        XCTAssertEqual(again.map(\.id), [mergedID], "다시 계산해도 쪼개지지 않고 같은 식별자다")
        XCTAssertEqual(again.first?.startedAt, base)
        XCTAssertEqual(again.first?.endedAt, base.addingTimeInterval(420))
    }

    func testHidingMergedRecordHidesTheWholeMergedSpan() throws {
        let mergedID = try XCTUnwrap(records(crossing).first?.id)
        let suppressed: Set<UUID> = [mergedID]
        let visible = records(crossing, protected: suppressed).filter { !suppressed.contains($0.id) }
        XCTAssertTrue(visible.isEmpty, "정지와 뒤 걷기가 새 기록으로 되살아나지 않는다")
    }

    func testProtectedHeadStillStopsAtProtectedLaterPiece() {
        let pieces = crossing + [motion(.stationary, 420, 480), motion(.walking, 480, 700)]
        let head = MotionActivityActualEngine.stableID(for: pieces[0])
        let later = MotionActivityActualEngine.stableID(for: pieces[4])
        let result = records(pieces, protected: [head, later])
        XCTAssertEqual(result.filter { $0.behavior == "walking" }.map(\.id), [head, later])
        XCTAssertEqual(result.first?.endedAt, base.addingTimeInterval(420))
    }

    func testShortGapBetweenSameMovementIsJoined() {
        let result = records([motion(.walking, 0, 120), motion(.walking, 200, 400)])
        XCTAssertEqual(result.map(\.startedAt), [base])
    }

    func testRealStayIsNotBridged() {
        let result = records([motion(.walking, 0, 150), motion(.stationary, 150, 150 + 6 * 60), motion(.walking, 510, 700)])
        XCTAssertEqual(result.count, 3)
    }

    func testWalkToCarIsNotBridged() {
        let result = records([motion(.walking, 0, 150), motion(.stationary, 150, 200), motion(.automotive, 200, 600)])
        XCTAssertEqual(result.map(\.behavior), ["walking", "stationary", "automotive"])
    }

    func testRegisteredPlaceContextBlocksTheBridge() {
        let place = ActualRecord(
            id: UUID(), planID: nil, title: "집", categoryID: "activity",
            startedAt: base.addingTimeInterval(140), endedAt: base.addingTimeInterval(460),
            source: .location, confidence: .high, createdAt: base,
            behavior: StationaryContextKind.homeRest.rawValue
        )
        let result = records([motion(.walking, 0, 150), motion(.stationary, 150, 240), motion(.walking, 240, 420)], existing: [place])
        XCTAssertEqual(result.filter { $0.behavior == "walking" }.count, 2)
    }

    func testCorrectedPieceIsKeptSeparateSoItsCorrectionSurvives() {
        let corrected = motion(.walking, 240, 420)
        let result = records(
            [motion(.walking, 0, 150), motion(.stationary, 150, 240), corrected],
            protected: [MotionActivityActualEngine.stableID(for: corrected)]
        )
        XCTAssertTrue(result.contains { $0.id == MotionActivityActualEngine.stableID(for: corrected) })
        XCTAssertEqual(result.count, 3)
    }

    // MARK: - 이동 구간

    private func travel(_ mode: TravelMode, _ start: TimeInterval, _ end: TimeInterval, confirmed: Bool = false) -> TravelSegment {
        TravelSegment(mode: mode, span: span(start, end), distanceMeters: 100, confidence: .medium, evidence: ["GPS"], isConfirmed: confirmed)
    }

    func testWalkAndRunFragmentsJoinWithLongerMode() {
        let walk = travel(.walking, 0, 120)
        let merged = AppleDeviceGroundTruthEngine.coalescingTravel([walk, travel(.running, 200, 600)], stays: [], maximumGap: 5 * 60)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, walk.id)
        XCTAssertEqual(merged.first?.mode, .running)
        XCTAssertTrue(merged.first?.evidence.contains("짧은 끊김 이어 붙임") == true)
    }

    func testLongWalkThenLongRunStaySeparate() {
        // 20분 걷고 바로 30분 달리면 둘 다 조각이 아니다 (REV1110A06).
        let merged = AppleDeviceGroundTruthEngine.coalescingTravel([travel(.walking, 0, 1_200), travel(.running, 1_200, 3_000)], stays: [], maximumGap: 5 * 60)
        XCTAssertEqual(merged.map(\.mode), [.walking, .running])
        XCTAssertEqual(merged.map(\.distanceMeters), [100, 100])
    }

    func testFragmentLimitAppliesToTheShorterSide() {
        let justUnder = AppleDeviceGroundTruthEngine.coalescingTravel([travel(.running, 0, 1_800), travel(.walking, 1_800, 1_979)], stays: [], maximumGap: 5 * 60)
        XCTAssertEqual(justUnder.map(\.mode), [.running])
        let atLimit = AppleDeviceGroundTruthEngine.coalescingTravel([travel(.running, 0, 1_800), travel(.walking, 1_800, 1_980)], stays: [], maximumGap: 5 * 60)
        XCTAssertEqual(atLimit.map(\.mode), [.running, .walking])
        let sameMode = AppleDeviceGroundTruthEngine.coalescingTravel([travel(.walking, 0, 1_200), travel(.walking, 1_260, 3_000)], stays: [], maximumGap: 5 * 60)
        XCTAssertEqual(sameMode.count, 1, "같은 수단 규칙은 그대로다")
    }

    func testWalkToSubwayIsNotJoined() {
        let merged = AppleDeviceGroundTruthEngine.coalescingTravel([travel(.walking, 0, 120), travel(.subway, 150, 900)], stays: [], maximumGap: 5 * 60)
        XCTAssertEqual(merged.map(\.mode), [.walking, .subway])
    }

    func testConfirmedModeIsNotRewritten() {
        let merged = AppleDeviceGroundTruthEngine.coalescingTravel(
            [travel(.walking, 0, 120, confirmed: true), travel(.running, 200, 600)], stays: [], maximumGap: 5 * 60
        )
        XCTAssertEqual(merged.count, 2)
    }

    func testRegisteredStayInGapBlocksJoin() {
        let home = PlaceStay(placeKey: "frequent-home", displayName: "집", span: span(130, 190), confidence: .high)
        let merged = AppleDeviceGroundTruthEngine.coalescingTravel([travel(.walking, 0, 120), travel(.walking, 200, 400)], stays: [home], maximumGap: 5 * 60)
        XCTAssertEqual(merged.count, 2)
    }

    // MARK: - 유령 체류

    private func reading(_ second: TimeInterval, _ latitude: Double, accuracy: Double = 5) -> SensorReading {
        SensorReading(
            timestamp: base.addingTimeInterval(second),
            point: GeoPoint(latitude: latitude, longitude: 127, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 10)
        )
    }

    func testGhostJumpIsDroppedFromRouteReadingsButRawStays() {
        var raw = stride(from: 0.0, through: 300, by: 10).map { reading($0, 37.5) }
        let ghost = stride(from: 360.0, through: 450, by: 10).map { reading($0, 37.51, accuracy: 65) }
        raw += ghost + stride(from: 510.0, through: 800, by: 10).map { reading($0, 37.5) }
        let prepared = TaptionRouteEngineAdapter.prepareFilteredReadings(from: raw, includeLowConfidenceBoundaries: false)
        XCTAssertEqual(prepared.ghostExcursionCount, ghost.count)
        XCTAssertTrue(Set(prepared.readings.map(\.id)).isDisjoint(with: ghost.map(\.id)))
        XCTAssertEqual(raw.count, 31 + ghost.count + 30, "원본 배열은 건드리지 않는다")
        let projection = TaptionActivityEngineAdapter.qualityProjection(from: raw)
        XCTAssertEqual(projection.rejectionCounts["location.ghostExcursion"], ghost.count)
        XCTAssertEqual(projection.readings.count, raw.count)
    }

    func testPreciseDetourIsKept() {
        var raw = stride(from: 0.0, through: 300, by: 10).map { reading($0, 37.5) }
        let detour = stride(from: 360.0, through: 450, by: 10).map { reading($0, 37.51) }
        raw += detour + stride(from: 510.0, through: 800, by: 10).map { reading($0, 37.5) }
        let prepared = TaptionRouteEngineAdapter.prepareFilteredReadings(from: raw, includeLowConfidenceBoundaries: false)
        XCTAssertEqual(prepared.ghostExcursionCount, 0)
    }
}
