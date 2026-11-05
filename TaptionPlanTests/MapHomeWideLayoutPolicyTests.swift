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
            XCTAssertEqual(MapHomeWideLayoutPolicy.menuPanelKind(viewportSize: CGSize(width: width, height: 400), hasPermissionCard: true), .standard)
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

    func testMenuUnfoldsSidewaysOnlyWhenOneColumnDoesNotFit() {
        // 세로는 높이와 권한 카드에 상관없이 한 열이다.
        XCTAssertEqual(MapHomeWideLayoutPolicy.menuPanelKind(viewportSize: iPad, hasPermissionCard: true), .standard)
        XCTAssertEqual(MapHomeWideLayoutPolicy.menuPanelKind(viewportSize: duoInner, hasPermissionCard: true), .standard)
        // 가로로 돌리면 높이가 모자라 두 열로 편다.
        let landscape = CGSize(width: iPad.height, height: iPad.width)
        XCTAssertEqual(MapHomeWideLayoutPolicy.menuPanelKind(viewportSize: landscape, hasPermissionCard: false), .columns(width: 680))
        // 듀오 안쪽 가로도 사이드바를 가리지 않는 폭으로 편다.
        let duoLandscape = CGSize(width: duoInner.height, height: duoInner.width)
        XCTAssertEqual(MapHomeWideLayoutPolicy.menuPanelKind(viewportSize: duoLandscape, hasPermissionCard: false), .columns(width: 680))
        // 좁은 분할 화면은 옆으로 펼 자리가 없어 한 열로 두고 스크롤한다.
        XCTAssertEqual(MapHomeWideLayoutPolicy.menuPanelKind(viewportSize: CGSize(width: 600, height: 834), hasPermissionCard: false), .standard)
    }

    func testPanelMatchesTheActionBarAndCalendarUnfoldsOnlyWhenTheMapStillFits() {
        for width in [600, duoInner.width, iPad.width, 1024, 1049] {
            XCTAssertEqual(MapHomeWideLayoutPolicy.panelWidth(viewportWidth: width, kind: .calendar), MapHomeWideLayoutPolicy.actionBarWidth, "\(width)")
            XCTAssertFalse(MapHomeWideLayoutPolicy.usesCalendarColumns(viewportWidth: width), "\(width)")
        }
        for width in [1050, iPad.height, 1366] {
            XCTAssertEqual(MapHomeWideLayoutPolicy.panelWidth(viewportWidth: width, kind: .calendar), 680, "\(width)")
            XCTAssertEqual(MapHomeWideLayoutPolicy.panelWidth(viewportWidth: width, kind: .standard), 402, "\(width)")
            XCTAssertGreaterThanOrEqual(width - MapHomeWideLayoutPolicy.mapLeadingInset(viewportWidth: width, openPanel: .calendar), MapHomeWideLayoutPolicy.minimumMapWidthBesidePanel)
        }
    }

    func testMapShrinksBesideThePanelOnlyWhenEnoughWidthRemains() {
        XCTAssertEqual(MapHomeWideLayoutPolicy.mapLeadingInset(viewportWidth: iPad.width, openPanel: nil), 0)
        XCTAssertEqual(MapHomeWideLayoutPolicy.mapLeadingInset(viewportWidth: iPad.width, openPanel: .standard), 430)
        XCTAssertEqual(MapHomeWideLayoutPolicy.mapLeadingInset(viewportWidth: iPad.height, openPanel: .calendar), 708)
        // 분할 화면·듀오 안쪽은 지도를 줄이지 않고 패널을 위에 띄운다.
        XCTAssertEqual(MapHomeWideLayoutPolicy.mapLeadingInset(viewportWidth: 600, openPanel: .standard), 0)
        XCTAssertEqual(MapHomeWideLayoutPolicy.mapLeadingInset(viewportWidth: duoInner.width, openPanel: .standard), 0)
        // 아이폰 폭은 패널이 없다.
        XCTAssertEqual(MapHomeWideLayoutPolicy.mapLeadingInset(viewportWidth: iPhoneMax.width, openPanel: .standard), 0)
    }

    func testDateStripHidesTopLeftControlsOnlyWhenItReachesThem() {
        for width in [320, iPhonePro.width, iPhoneMax.width, duoOuter.width, 599] {
            XCTAssertTrue(MapHomeWideLayoutPolicy.dateStripOverlapsTopLeftControls(viewportWidth: width), "\(width)")
        }
        for width in [600, duoInner.width, duoInner.height, iPad.width, iPad.height] {
            XCTAssertFalse(MapHomeWideLayoutPolicy.dateStripOverlapsTopLeftControls(viewportWidth: width), "\(width)")
        }
    }

    func testTimeRailWidensOnlyOnWideScreens() {
        XCTAssertEqual(MapHomeWideLayoutPolicy.timeRailWidth(viewportWidth: iPhoneMax.width), 44)
        XCTAssertEqual(MapHomeWideLayoutPolicy.timeRailWidth(viewportWidth: duoOuter.width), 44)
        XCTAssertEqual(MapHomeWideLayoutPolicy.timeRailWidth(viewportWidth: iPad.width), 52)
    }

    func testClipEditorUnfoldsOnlyWhereTheTimelineKeepsItsWidth() {
        XCTAssertFalse(MapHomeWideLayoutPolicy.usesClipColumns(width: iPhoneMax.width))
        XCTAssertFalse(MapHomeWideLayoutPolicy.usesClipColumns(width: duoInner.width))
        XCTAssertTrue(MapHomeWideLayoutPolicy.usesClipColumns(width: iPad.width))
        XCTAssertGreaterThan(iPad.width - MapHomeWideLayoutPolicy.clipInspectorWidth, iPhonePro.width)
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

    func testOnlyLowTwoColumnMenuUsesCompactRows() {
        let duoInner = CGSize(width: 951, height: 669)
        let duoKind = MapHomeWideLayoutPolicy.menuPanelKind(viewportSize: duoInner, hasPermissionCard: true)
        XCTAssertEqual(duoKind.columns, 2)
        XCTAssertTrue(MapHomeWideLayoutPolicy.menuUsesCompactRows(viewportSize: duoInner, kind: duoKind))
        XCTAssertFalse(MapHomeWideLayoutPolicy.menuUsesCompactRows(viewportSize: duoInner, kind: .standard))
        XCTAssertFalse(MapHomeWideLayoutPolicy.menuUsesCompactRows(viewportSize: CGSize(width: 1210, height: 834), kind: .columns(width: 680)))
    }
}
