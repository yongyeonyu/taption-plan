import UIKit
import XCTest
@testable import TaptionPlan

final class MapHomeWideLayoutPolicyTests: XCTestCase {
    private let duoOuter = CGSize(width: 466, height: 678)
    private let duoInner = CGSize(width: 669, height: 951)
    private let iPhonePro = CGSize(width: 402, height: 874)
    private let iPhoneMax = CGSize(width: 440, height: 956)
    private let iPad = CGSize(width: 834, height: 1210)

    func testPhoneWidthsKeepThePhoneLayout() {
        for width in [320, iPhonePro.width, iPhoneMax.width, duoOuter.width, 599] {
            XCTAssertFalse(MapHomeWideLayoutPolicy.isWide(viewportWidth: width), "\(width)")
            XCTAssertNil(MapHomeWideLayoutPolicy.actionBarWidth(viewportWidth: width))
            XCTAssertNil(MapHomeWideLayoutPolicy.dateStripMaximumWidth(viewportWidth: width))
            XCTAssertNil(MapHomeWideLayoutPolicy.topOverlayMaximumWidth(viewportWidth: width))
            XCTAssertEqual(MapHomeWideLayoutPolicy.searchViewportWidth(width), width)
            XCTAssertEqual(MapHomeWideLayoutPolicy.sidebarBottomReserve(viewportWidth: width, actionBarHeight: 70), 70)
            XCTAssertEqual(MapHomeWideLayoutPolicy.menuTop(viewportWidth: width, viewportHeight: 900, minimumTop: 46), 46)
        }
    }

    func testWideWidthsPinTheMenuAndExtendTheSidebar() {
        for width in [600, duoInner.width, duoInner.height, iPad.width, iPad.height, 1366] {
            XCTAssertTrue(MapHomeWideLayoutPolicy.isWide(viewportWidth: width), "\(width)")
            XCTAssertEqual(MapHomeWideLayoutPolicy.actionBarWidth(viewportWidth: width), 402)
            XCTAssertEqual(MapHomeWideLayoutPolicy.dateStripMaximumWidth(viewportWidth: width), 332)
            XCTAssertEqual(MapHomeWideLayoutPolicy.topOverlayMaximumWidth(viewportWidth: width), 402)
            XCTAssertEqual(MapHomeWideLayoutPolicy.sidebarBottomReserve(viewportWidth: width, actionBarHeight: 70), 0)
        }
    }

    func testWideMenuPanelStaysShortAndNeverPassesTheHeader() {
        XCTAssertEqual(MapHomeWideLayoutPolicy.menuTop(viewportWidth: 834, viewportHeight: 1210, minimumTop: 46), 570)
        XCTAssertEqual(MapHomeWideLayoutPolicy.menuTop(viewportWidth: 951, viewportHeight: 669, minimumTop: 46), 46)
    }

    func testOrientationFollowsTheScreenShortSide() {
        XCTAssertEqual(AppOrientationPolicy.mask(screenSize: iPhonePro), .portrait)
        XCTAssertEqual(AppOrientationPolicy.mask(screenSize: iPhoneMax), .portrait)
        XCTAssertEqual(AppOrientationPolicy.mask(screenSize: duoOuter), .portrait)
        XCTAssertEqual(AppOrientationPolicy.mask(screenSize: .zero), .portrait)
        XCTAssertEqual(AppOrientationPolicy.mask(screenSize: duoInner), .all)
        XCTAssertEqual(AppOrientationPolicy.mask(screenSize: CGSize(width: duoInner.height, height: duoInner.width)), .all)
        XCTAssertEqual(AppOrientationPolicy.mask(screenSize: iPad), .all)
    }
}
