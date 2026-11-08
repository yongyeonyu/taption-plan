import SwiftUI
import XCTest
@testable import TaptionPlan

final class ReviewClockGeometryTests: XCTestCase {
    func testAngleStartsAtTwelveAndTurnsClockwise() {
        XCTAssertEqual(ReviewClockGeometry.angle(0).degrees, -90, accuracy: 1e-9)
        XCTAssertEqual(ReviewClockGeometry.angle(0.25).degrees, 0, accuracy: 1e-9)
        XCTAssertEqual(ReviewClockGeometry.angle(0.5).degrees, 90, accuracy: 1e-9)
    }

    func testPointAndClockFractionRoundTrip() {
        let center = CGPoint(x: 100, y: 100)
        for fraction in [0.0, 0.125, 0.25, 0.5, 0.75, 0.99] {
            let tip = ReviewClockGeometry.point(
                center: center,
                radius: 50,
                angle: ReviewClockGeometry.angle(fraction)
            )
            let back = ReviewClockGeometry.clockFraction(
                dx: tip.x - center.x,
                dy: tip.y - center.y
            )
            XCTAssertEqual(back, fraction, accuracy: 1e-9)
        }
        // 12시 방향은 위쪽(y가 작은 쪽)이다.
        let top = ReviewClockGeometry.point(
            center: center,
            radius: 50,
            angle: ReviewClockGeometry.angle(0)
        )
        XCTAssertEqual(top.x, 100, accuracy: 1e-9)
        XCTAssertEqual(top.y, 50, accuracy: 1e-9)
    }

    func testClockFractionStaysInsideDay() {
        // 9시 방향 바로 위는 하루 끝 쪽(0.75 이상 1 미만)이다.
        let fraction = ReviewClockGeometry.clockFraction(dx: -10, dy: -0.001)
        XCTAssertGreaterThanOrEqual(fraction, 0.75)
        XCTAssertLessThan(fraction, 1)
        XCTAssertEqual(ReviewClockGeometry.outerRadius(side: 300), 126)
    }

    func testCornerLabelAnchorSitsOnInnerEdge() {
        let size = CGSize(width: 320, height: 240)
        let topLeft = ReviewClockGeometry.cornerLabelAnchor(
            quadrant: .topLeft,
            in: size,
            labelWidth: 108,
            labelHeight: 40
        )
        XCTAssertEqual(topLeft, CGPoint(x: 111, y: 24))
        let bottomRight = ReviewClockGeometry.cornerLabelAnchor(
            quadrant: .bottomRight,
            in: size,
            labelWidth: 108,
            labelHeight: 40
        )
        XCTAssertEqual(bottomRight, CGPoint(x: 209, y: 216))
    }

    func testLinearBarAndTapFraction() {
        let rect = CGRect(x: 10, y: 44, width: 200, height: 30)
        let bar = ReviewClockGeometry.linearBar(
            in: rect,
            startFraction: 0.25,
            endFraction: 0.5
        )
        XCTAssertEqual(bar, CGRect(x: 60, y: 44, width: 50, height: 30))
        let thin = ReviewClockGeometry.linearBar(
            in: rect,
            startFraction: 0.5,
            endFraction: 0.5
        )
        XCTAssertEqual(thin.width, 1)

        XCTAssertEqual(
            ReviewClockGeometry.linearFraction(x: 110, timelineStart: 10, timelineWidth: 200),
            0.5,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            ReviewClockGeometry.linearFraction(x: 0, timelineStart: 10, timelineWidth: 200),
            0
        )
        XCTAssertLessThan(
            ReviewClockGeometry.linearFraction(x: 999, timelineStart: 10, timelineWidth: 200),
            1
        )
    }

    func testHourStrideZoomAndWrap() {
        XCTAssertEqual(ReviewClockGeometry.hourLabelStride(width: 400), 3)
        XCTAssertEqual(ReviewClockGeometry.hourLabelStride(width: 560), 2)
        XCTAssertEqual(ReviewClockGeometry.hourLabelStride(width: 900), 1)

        XCTAssertEqual(ReviewClockGeometry.zoomScale(origin: 1, factor: 2), 2)
        XCTAssertEqual(ReviewClockGeometry.zoomScale(origin: 2, factor: 3), 4)
        XCTAssertEqual(ReviewClockGeometry.zoomScale(origin: 1, factor: 0), 1)

        XCTAssertEqual(ReviewClockGeometry.wrappedFraction(-0.01), 0.99, accuracy: 1e-12)
        XCTAssertEqual(ReviewClockGeometry.wrappedFraction(1.01), 0.01, accuracy: 1e-12)
        XCTAssertEqual(ReviewClockGeometry.wrappedFraction(1), 1)
        XCTAssertEqual(ReviewClockGeometry.wrappedFraction(0.4), 0.4)
    }

    func testOpacityFollowsHighlight() {
        let sleep = TimelineRowKind.sleep.rawValue
        XCTAssertEqual(ReviewClockOpacity.activityCategoryID(for: .sleepStage), sleep)
        XCTAssertNil(ReviewClockOpacity.activityCategoryID(for: .weather))

        XCTAssertEqual(
            ReviewClockOpacity.activity(
                categoryID: sleep,
                highlight: nil,
                isPlaybackActive: true,
                isUnderPlayhead: false
            ),
            0.4
        )
        XCTAssertEqual(
            ReviewClockOpacity.activity(
                categoryID: sleep,
                highlight: .detail(ReviewDetailSelection(kind: .sleepStage, token: "deep")),
                isPlaybackActive: false,
                isUnderPlayhead: false
            ),
            0.22
        )
        XCTAssertEqual(
            ReviewClockOpacity.activityDetail(
                kind: .sleepStage,
                token: "deep",
                highlight: .category(sleep)
            ),
            1
        )
        XCTAssertEqual(
            ReviewClockOpacity.phase(
                token: "work",
                focusedToken: "rest",
                highlight: nil,
                isPlaying: true
            ),
            0.3
        )
        XCTAssertEqual(
            ReviewClockOpacity.phase(
                token: "work",
                focusedToken: nil,
                highlight: .phase(arcID: "a", token: "work"),
                isPlaying: false
            ),
            1
        )
    }
}
