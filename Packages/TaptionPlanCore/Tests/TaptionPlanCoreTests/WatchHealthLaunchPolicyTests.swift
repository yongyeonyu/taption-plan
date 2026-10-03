import XCTest
@testable import TaptionPlanCore

final class WatchHealthLaunchPolicyTests: XCTestCase {
    func testPairedWatchRequestsInitialPermissionWithoutCompanionApp() {
        XCTAssertEqual(TaptionWatchHealthLaunchPolicy.action(isPaired: true, healthEnabled: false, hasRequestedAuthorization: false), .requestAuthorization)
    }
    func testDisabledHealthDoesNotPromptAgain() {
        XCTAssertEqual(TaptionWatchHealthLaunchPolicy.action(isPaired: true, healthEnabled: false, hasRequestedAuthorization: true), .none)
    }
    func testEnabledHealthRefreshesEvenAfterWatchUnpairs() {
        for paired in [true, false] {
            XCTAssertEqual(TaptionWatchHealthLaunchPolicy.action(isPaired: paired, healthEnabled: true, hasRequestedAuthorization: true), .refresh)
        }
    }
    func testNoWatchDoesNotRequestInitialPermission() {
        XCTAssertEqual(TaptionWatchHealthLaunchPolicy.action(isPaired: false, healthEnabled: false, hasRequestedAuthorization: false), .none)
    }
}
