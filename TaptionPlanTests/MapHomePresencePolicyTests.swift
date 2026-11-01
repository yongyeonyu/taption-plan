import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

final class MapHomePresencePolicyTests: XCTestCase {
    func testHomePresenceUsesConfiguredRadius() {
        let home = CLLocationCoordinate2D(latitude: 37.5, longitude: 127.0)
        let nearby = CLLocationCoordinate2D(latitude: 37.5005, longitude: 127.0)
        let outside = CLLocationCoordinate2D(latitude: 37.503, longitude: 127.0)

        XCTAssertTrue(
            MapHomePresencePolicy.isAtHome(
                current: nearby,
                home: home,
                radiusMeters: 120
            )
        )
        XCTAssertFalse(
            MapHomePresencePolicy.isAtHome(
                current: outside,
                home: home,
                radiusMeters: 120
            )
        )
    }

    func testHomePresenceRejectsInvalidCoordinatesAndRadius() {
        XCTAssertFalse(
            MapHomePresencePolicy.isAtHome(
                current: CLLocationCoordinate2D(latitude: 91, longitude: 0),
                home: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                radiusMeters: 120
            )
        )
        XCTAssertFalse(
            MapHomePresencePolicy.isAtHome(
                current: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                home: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                radiusMeters: -1
            )
        )
    }
}
