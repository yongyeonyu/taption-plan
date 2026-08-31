import XCTest
import TaptionPlanEngine

final class TaptionPlanEngineTests: XCTestCase {
    func testUmbrellaExportsAllFrameworkNeutralEngines() {
        XCTAssertEqual(TaptionPlanEngine.version, "1")
        XCTAssertEqual(ActivityTaxonomy.default.major(for: "movement")?.id, "movement")
        XCTAssertTrue(RouteSample(
            timestamp: .now,
            coordinate: .init(latitude: 37, longitude: 126),
            horizontalAccuracyMeters: 5
        ).isPrecise)
        XCTAssertEqual(TaptionPlanSharedContainer.appGroupIdentifier, "group.com.taption.plan")
    }
}
