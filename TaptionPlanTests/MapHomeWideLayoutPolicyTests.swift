import CoreLocation
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

    /// 메뉴는 화면 모양과 상관없이 두 열로 펴지 않고 한 열로 스크롤한다(REV1107A02).
    func testMenuStaysOneColumnOnEveryWideScreen() {
        let landscape = CGSize(width: iPad.height, height: iPad.width)
        let duoLandscape = CGSize(width: duoInner.height, height: duoInner.width)
        for size in [iPad, duoInner, landscape, duoLandscape, CGSize(width: 600, height: 834)] {
            XCTAssertEqual(MapHomeWideLayoutPolicy.menuPanelKind(viewportSize: size, hasPermissionCard: false), .standard, "\(size)")
        }
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

    /// 넓은 화면은 한 열이 높이에 모자랄 때만 줄 간격을 줄인다(REV1107A02).
    func testWideMenuUsesCompactRowsOnlyWhenOneColumnDoesNotFit() {
        let duoInner = CGSize(width: 951, height: 669)
        XCTAssertTrue(MapHomeWideLayoutPolicy.menuUsesCompactRows(viewportSize: duoInner, hasPermissionCard: true))
        XCTAssertFalse(MapHomeWideLayoutPolicy.menuUsesCompactRows(viewportSize: CGSize(width: 1032, height: 1376), hasPermissionCard: false))
        XCTAssertFalse(MapHomeWideLayoutPolicy.menuUsesCompactRows(viewportSize: CGSize(width: 402, height: 500), hasPermissionCard: true), "좁은 화면은 시트")
    }

    func testPlacePinPolicyClampsZoomAndIgnoresJitter() {
        XCTAssertEqual(MapHomePlacePinPolicy.zoom(20, by: 1), 20)
        XCTAssertEqual(MapHomePlacePinPolicy.zoom(3, by: -1), 3)
        XCTAssertEqual(MapHomePlacePinPolicy.zoom(15, by: 1), 16)
        let saved = GeoPoint(latitude: 37.5, longitude: 127, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5)
        XCTAssertFalse(MapHomePlacePinPolicy.needsSave(saved: saved, center: CLLocationCoordinate2D(latitude: 37.5, longitude: 127)))
        XCTAssertTrue(MapHomePlacePinPolicy.needsSave(saved: saved, center: CLLocationCoordinate2D(latitude: 37.501, longitude: 127)))
        XCTAssertTrue(MapHomePlacePinPolicy.needsSave(saved: nil, center: CLLocationCoordinate2D(latitude: 37.5, longitude: 127)))
    }
}
