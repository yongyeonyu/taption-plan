import XCTest
@testable import TaptionPlan

/// STY1116A01: 일상 ↔ 여행 전환의 단계와 원 반지름.
final class TravelModeTransitionTests: XCTestCase {
    private typealias T = TravelModeTransition

    private func run(_ events: [T.Event], from phase: T.Phase = .closed) -> (T.Phase, [T.Effect]) {
        var phase = phase
        let effects = events.map { T.reduce(&phase, $0) }
        return (phase, effects)
    }

    func testOpenThenClose() {
        let (phase, effects) = run([.requestOpen, .revealFinished, .requestClose, .concealFinished])
        XCTAssertEqual(phase, .closed)
        XCTAssertEqual(effects, [.present, .none, .conceal, .remove])
    }

    func testDoubleTapPresentsOnce() {
        let (phase, effects) = run([.requestOpen, .requestOpen, .revealFinished, .requestOpen])
        XCTAssertEqual(phase, .open)
        XCTAssertEqual(effects, [.present, .none, .none, .none])
    }

    func testCloseWhileOpeningTurnsBack() {
        let (phase, effects) = run([.requestOpen, .requestClose, .concealFinished])
        XCTAssertEqual(phase, .closed)
        XCTAssertEqual(effects, [.present, .conceal, .remove])
    }

    func testReopenWhileClosingKeepsTheCover() {
        let (phase, effects) = run([.requestClose, .requestOpen, .revealFinished], from: .open)
        XCTAssertEqual(phase, .open)
        XCTAssertEqual(effects, [.conceal, .reveal, .none])
    }

    func testLateFinishSignalsAreIgnored() {
        XCTAssertEqual(run([.concealFinished], from: .opening).1, [.none])
        XCTAssertEqual(run([.revealFinished], from: .closing).1, [.none])
        XCTAssertEqual(run([.requestClose, .revealFinished, .concealFinished], from: .closed).0, .closed)
    }

    func testRevealRadiusReachesTheFarthestCorner() {
        let size = CGSize(width: 300, height: 400)
        XCTAssertEqual(T.revealRadius(from: .zero, in: size), 500, accuracy: 0.001)
        XCTAssertEqual(T.revealRadius(from: CGPoint(x: 300, y: 400), in: size), 500, accuracy: 0.001)
        XCTAssertEqual(T.revealRadius(from: CGPoint(x: 150, y: 200), in: size), 250, accuracy: 0.001)
        let corner = CGPoint(x: 260, y: 60)
        let radius = T.revealRadius(from: corner, in: size)
        for point in [CGPoint.zero, CGPoint(x: 300, y: 0), CGPoint(x: 0, y: 400), CGPoint(x: 300, y: 400)] {
            XCTAssertGreaterThanOrEqual(radius + 0.001, hypot(point.x - corner.x, point.y - corner.y))
        }
    }

    func testOriginFallsBackToTheCenter() {
        let size = CGSize(width: 300, height: 400)
        XCTAssertEqual(T.origin(buttonFrame: nil, in: size), CGPoint(x: 150, y: 200))
        XCTAssertEqual(T.origin(buttonFrame: CGRect(x: 900, y: 0, width: 40, height: 40), in: size), CGPoint(x: 150, y: 200))
        XCTAssertEqual(T.origin(buttonFrame: CGRect(x: 240, y: 60, width: 40, height: 40), in: size), CGPoint(x: 260, y: 80))
    }
}
