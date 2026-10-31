import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

final class MapHomeTimeRailCardTests: XCTestCase {
    func testSideRailsShareTopAndBottomAcrossViewportSizes() {
        let compactFrame = MapHomeOverlayLayoutMath.alignedRailFrame(
            viewportHeight: 812,
            topInset: 90,
            bottomInset: 76
        )
        let tallFrame = MapHomeOverlayLayoutMath.alignedRailFrame(
            viewportHeight: 1_024,
            topInset: 90,
            bottomInset: 76
        )

        XCTAssertEqual(compactFrame.minY, 90, accuracy: 0.1)
        XCTAssertEqual(compactFrame.maxY, 736, accuracy: 0.1)
        XCTAssertEqual(tallFrame.height, 680, accuracy: 0.1)
        XCTAssertEqual(tallFrame.minY, 268, accuracy: 0.1)
        XCTAssertEqual(tallFrame.maxY, 948, accuracy: 0.1)
    }

    func testSideRailsMoveDownTogetherWithoutChangingTheirHeight() {
        let previous = MapHomeOverlayLayoutMath.alignedRailFrame(
            viewportHeight: 812,
            topInset: 90,
            bottomInset: 76
        )
        let lowered = MapHomeOverlayLayoutMath.alignedRailFrame(
            viewportHeight: 812,
            topInset: 118,
            bottomInset: 48
        )

        XCTAssertEqual(lowered.height, previous.height, accuracy: 0.1)
        XCTAssertEqual(lowered.minY, previous.minY + 28, accuracy: 0.1)
        XCTAssertEqual(lowered.maxY, previous.maxY + 28, accuracy: 0.1)
    }

    /// 트랙 높이는 1,000에서 위·아래 여백(MapHomeTimeSidebarMath.verticalInset)을 뺀 값이다.
    /// 선택 카드는 2시간(120분)이라 트랙의 1/12을 차지한다.
    func testSelectedCardHighlightsTwoHoursOnFullDayRail() {
        let frame = MapHomeTimeSidebarMath.selectedTimeCardFrame(
            availableHeight: 1_000,
            selectedMinute: 720,
            visibleStartMinute: 0,
            visibleDurationMinutes: 1_440
        )

        let track = 1_000 - 2 * MapHomeTimeSidebarMath.verticalInset
        XCTAssertEqual(frame.height, track / 12, accuracy: 0.1)
        XCTAssertEqual(frame.midY, 500, accuracy: 0.1)
    }

    /// 자정에 붙은 카드는 잘려서 1시간(트랙의 1/24)만 남고,
    /// 60분 창으로 확대하면 카드가 창 전체(트랙 높이)를 덮는다.
    func testSelectedCardClipsAtDayBoundaryAndVisibleWindow() {
        let dayBoundaryFrame = MapHomeTimeSidebarMath.selectedTimeCardFrame(
            availableHeight: 1_000,
            selectedMinute: 0,
            visibleStartMinute: 0,
            visibleDurationMinutes: 1_440
        )
        let zoomedFrame = MapHomeTimeSidebarMath.selectedTimeCardFrame(
            availableHeight: 1_000,
            selectedMinute: 600,
            visibleStartMinute: 570,
            visibleDurationMinutes: 60
        )

        let track = 1_000 - 2 * MapHomeTimeSidebarMath.verticalInset
        XCTAssertEqual(dayBoundaryFrame.height, track / 24, accuracy: 0.1)
        XCTAssertEqual(zoomedFrame.height, track, accuracy: 0.1)
    }
}
