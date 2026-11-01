import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

final class MapHomeWeatherRailLayoutTests: XCTestCase {
    func testWeatherRowsKeepSelectedEntryAndAvoidVerticalOverlap() {
        let visible = MapHomeWeatherRailLayout.visibleIndices(
            yPositions: [100, 130, 181],
            candidateIndices: [0, 1, 2],
            priorityIndices: [1]
        )

        XCTAssertEqual(visible, [1, 2])
        XCTAssertTrue(visible.contains(1))
    }

    func testUnboxedWeatherItemsKeepMinimumSpacing() {
        let positions = [100, 130, 166, 203].map(CGFloat.init)
        let visible = MapHomeWeatherRailLayout.visibleIndices(
            yPositions: positions,
            candidateIndices: Array(positions.indices),
            priorityIndices: []
        )
        let visiblePositions = visible.sorted().map { positions[$0] }

        XCTAssertTrue(
            zip(visiblePositions, visiblePositions.dropFirst()).allSatisfy {
                $1 - $0 >= MapHomeWeatherRailLayout.minimumItemSpacing
            }
        )
    }
}
