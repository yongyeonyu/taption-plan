import XCTest
@testable import TaptionPlanCore

final class HealthReadScopeTests: XCTestCase {
    func testOnlyTimelineAndMovementInputsAreRequested() {
        XCTAssertEqual(TaptionHealthReadScope.identifiers, [
            "HKWorkoutTypeIdentifier", "HKCategoryTypeIdentifierSleepAnalysis",
            "HKQuantityTypeIdentifierHeartRate", "HKQuantityTypeIdentifierStepCount",
            "HKQuantityTypeIdentifierDistanceWalkingRunning", "HKQuantityTypeIdentifierDistanceCycling",
            "HKQuantityTypeIdentifierActiveEnergyBurned", "HKWorkoutRouteTypeIdentifier",
        ])
    }
    func testUnrelatedSensitiveRecordsAreExcluded() {
        for identifier in ["HKQuantityTypeIdentifierBloodGlucose", "HKCategoryTypeIdentifierMenstrualFlow",
                           "HKClinicalTypeIdentifierMedicationRecord", "HKVisionPrescriptionTypeIdentifier",
                           "HKCharacteristicTypeIdentifierDateOfBirth", "HKCategoryTypeIdentifierMindfulSession"] {
            XCTAssertFalse(TaptionHealthReadScope.identifiers.contains(identifier))
        }
    }
}
