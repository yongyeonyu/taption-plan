import Foundation
import HealthKit
import XCTest
@testable import TaptionPlan

final class HealthKitIntegrationTests: XCTestCase {
    func testCatalogCoversEveryPublicHealthKitFamily() {
        let identifiers = HealthKitTypeCatalog.all.map(\.identifier)

        XCTAssertGreaterThanOrEqual(identifiers.count, 215)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertEqual(HealthKitTypeCatalog.quantities.count, 120)
        XCTAssertEqual(HealthKitTypeCatalog.categories.count, 69)
        XCTAssertEqual(HealthKitTypeCatalog.characteristics.count, 6)
        XCTAssertEqual(HealthKitTypeCatalog.clinicalRecords.count, 9)
        XCTAssertTrue(identifiers.contains("HKDataTypeIdentifierStateOfMind"))
        XCTAssertTrue(identifiers.contains("HKScoredAssessmentTypeIdentifierPHQ9"))
        XCTAssertTrue(identifiers.contains("HKMedicationDoseEventTypeIdentifierMedicationDoseEvent"))
        XCTAssertTrue(identifiers.contains("HKCategoryTypeIdentifierAudioExposureEvent"))
    }

    func testEveryAvailableCatalogDescriptorResolvesToAHealthKitObjectType() {
        let descriptors = HealthKitTypeCatalog.availableDescriptors()
        let resolved = descriptors.compactMap(
            HealthKitTypeCatalog.readObjectType(for:)
        )

        XCTAssertEqual(resolved.count, descriptors.count)
        XCTAssertFalse(
            HealthKitTypeCatalog.descriptor(
                for: "HKVisionPrescriptionTypeIdentifier"
            )?.backgroundEligible ?? true
        )
    }

    func testStandardAuthorizationExcludesTypesThatNeedAnotherAuthorizationPath() {
        let identifiers = Set(
            HealthKitTypeCatalog.standardAuthorizationObjectTypes().map(\.identifier)
        )

        XCTAssertFalse(identifiers.contains("HKVisionPrescriptionTypeIdentifier"))
        XCTAssertFalse(identifiers.contains("HKCorrelationTypeIdentifierBloodPressure"))
        XCTAssertFalse(identifiers.contains("HKCorrelationTypeIdentifierFood"))
        XCTAssertTrue(identifiers.contains("HKQuantityTypeIdentifierBloodPressureSystolic"))
        XCTAssertTrue(identifiers.contains("HKQuantityTypeIdentifierDietaryEnergyConsumed"))
    }

    func testEveryQuantityHasACanonicalUnitConversion() {
        for descriptor in HealthKitTypeCatalog.quantities where
            descriptor.isAvailableOnCurrentOS {
            guard HealthKitImportCoordinator.unit(
                named: descriptor.canonicalUnit
            ) != nil else {
                return XCTFail("Missing unit: \(descriptor.canonicalUnit)")
            }
        }
        XCTAssertEqual(
            HealthKitTypeCatalog.descriptor(
                for: "HKQuantityTypeIdentifierHeartRate"
            )?.canonicalUnit,
            "count/min"
        )
        XCTAssertEqual(
            HealthKitTypeCatalog.descriptor(
                for: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
            )?.canonicalUnit,
            "ms"
        )
        XCTAssertEqual(
            HealthKitTypeCatalog.descriptor(
                for: "HKQuantityTypeIdentifierRespiratoryRate"
            )?.canonicalUnit,
            "count/min"
        )
    }

    func testHealthKitRawDeltaAndAnchorRoundTripAtomically() async throws {
        let url = temporaryDatabaseURL()
        defer { removeDatabase(at: url) }
        let store = try HealthKitImportStore(databaseURL: url)
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        let sample = HealthKitSampleRecord(
            uuid: UUID(),
            typeIdentifier: "HKQuantityTypeIdentifierHeartRate",
            startDate: start,
            endDate: start.addingTimeInterval(60),
            numericValue: 72,
            unit: "count/min",
            sourceName: "Apple Watch",
            sourceBundleIdentifier: "com.apple.health",
            sourceProductType: "Watch",
            deviceName: "Apple Watch",
            userEntered: false,
            timeZoneIdentifier: "Asia/Seoul"
        )
        let firstState = HealthKitTypeSyncState(
            typeIdentifier: sample.typeIdentifier,
            anchor: Data("anchor-1".utf8),
            historyComplete: true,
            sampleCount: 1,
            addedCount: 1,
            lastSampleDate: sample.endDate,
            lastSyncedAt: start
        )

        try await store.apply(
            records: [sample],
            deletedIDs: [],
            state: firstState
        )
        let records = try await store.records(
            from: start.addingTimeInterval(-1),
            through: start.addingTimeInterval(61)
        )
        let savedState = try await store.syncState(
            for: sample.typeIdentifier
        )
        XCTAssertEqual(records, [sample])
        XCTAssertEqual(savedState, firstState)

        let deletedState = HealthKitTypeSyncState(
            typeIdentifier: sample.typeIdentifier,
            anchor: Data("anchor-2".utf8),
            historyComplete: true,
            sampleCount: 0,
            addedCount: 1,
            deletedCount: 1,
            lastSampleDate: sample.endDate,
            lastDeletionDate: start.addingTimeInterval(120),
            lastSyncedAt: start.addingTimeInterval(120)
        )
        try await store.apply(
            records: [],
            deletedIDs: [sample.uuid],
            state: deletedState
        )
        let remaining = try await store.records(
            from: start.addingTimeInterval(-1),
            through: start.addingTimeInterval(121)
        )
        let finalState = try await store.syncState(
            for: sample.typeIdentifier
        )
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(finalState, deletedState)
    }

    func testHealthCategoryIsAvailableForNonDiagnosticProjection() {
        let health = RecordClassificationCatalog.categories.first {
            $0.id == "health"
        }
        XCTAssertEqual(health?.title, "건강관리")
        XCTAssertEqual(
            Set(health?.details.map(\.id) ?? []),
            [
                "health.wellness",
                "health.vitals",
                "health.recovery",
                "health.medication",
            ]
        )
    }

    func testExplicitMedicationAndClinicalRecordsUseNonDiagnosticHealthTitles() {
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        let span = TimeSpan(
            start: start.addingTimeInterval(-60),
            end: start.addingTimeInterval(3_600)
        )
        let records = [
            HealthKitSampleRecord(
                uuid: UUID(),
                typeIdentifier:
                    "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent",
                startDate: start,
                endDate: start,
                categoryValue: 4,
                sourceName: "Health",
                userEntered: true
            ),
            HealthKitSampleRecord(
                uuid: UUID(),
                typeIdentifier: "HKClinicalTypeIdentifierConditionRecord",
                startDate: start.addingTimeInterval(1_200),
                endDate: start.addingTimeInterval(1_200),
                textValue: "private diagnosis text",
                sourceName: "Hospital"
            ),
        ]

        let actuals = HealthKitBehaviorProjectionEngine.actuals(
            from: records,
            in: span
        )

        XCTAssertEqual(actuals.map(\.categoryID), ["health", "health"])
        XCTAssertEqual(actuals.map(\.title), ["투약", "건강 기록"])
        XCTAssertFalse(actuals.map(\.title).contains("private diagnosis text"))
        XCTAssertTrue(actuals.allSatisfy {
            $0.evidence.contains { $0.contains("sampleUUIDs=") }
        })
    }

    func testSustainedHeartRateDeviationCreatesActivityEstimateWithWarmBaseline() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(
            for: Date(timeIntervalSince1970: 1_788_000_000)
        )
        var records: [HealthKitSampleRecord] = []
        for dayOffset in -8 ... -1 {
            for sampleOffset in 0..<4 {
                let date = calendar.date(
                    byAdding: .day,
                    value: dayOffset,
                    to: day
                )!.addingTimeInterval(TimeInterval(sampleOffset * 15 * 60))
                records.append(heartRateRecord(at: date, value: 60))
            }
        }
        let elevatedStart = day.addingTimeInterval(9 * 3_600)
        for minute in [0, 3, 6, 9, 12] {
            records.append(
                heartRateRecord(
                    at: elevatedStart.addingTimeInterval(
                        TimeInterval(minute * 60)
                    ),
                    value: 105
                )
            )
        }
        let span = TimeSpan(
            start: day,
            end: day.addingTimeInterval(86_400)
        )

        let actuals = HealthKitBehaviorProjectionEngine.actuals(
            from: records,
            in: span
        )

        let estimate = actuals.first { $0.title == "활동 추정" }
        XCTAssertEqual(estimate?.categoryID, "activity")
        XCTAssertEqual(estimate?.behavior, "activity-estimate")
        XCTAssertEqual(estimate?.confidence, .medium)
        XCTAssertTrue(estimate?.evidence.contains {
            $0.contains("baseline median=")
        } == true)
    }

    func testContinuousBiometricDoesNotProjectWithoutSevenDayBaseline() {
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        let records = [0, 4, 8, 12].map {
            heartRateRecord(
                at: start.addingTimeInterval(TimeInterval($0 * 60)),
                value: 120
            )
        }
        let actuals = HealthKitBehaviorProjectionEngine.actuals(
            from: records,
            in: TimeSpan(
                start: start,
                end: start.addingTimeInterval(3_600)
            )
        )
        XCTAssertTrue(actuals.isEmpty)
    }

    func testTargetDayDoesNotCompleteSevenDayBaseline() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(
            for: Date(timeIntervalSince1970: 1_788_000_000)
        )
        var records: [HealthKitSampleRecord] = []
        for dayOffset in -6 ... -1 {
            for sampleOffset in 0..<4 {
                let date = calendar.date(
                    byAdding: .day,
                    value: dayOffset,
                    to: day
                )!.addingTimeInterval(TimeInterval(sampleOffset * 15 * 60))
                records.append(heartRateRecord(at: date, value: 60))
            }
        }
        let elevatedStart = day.addingTimeInterval(9 * 3_600)
        for minute in [0, 3, 6, 9, 12] {
            records.append(heartRateRecord(
                at: elevatedStart.addingTimeInterval(TimeInterval(minute * 60)),
                value: 105
            ))
        }

        let actuals = HealthKitBehaviorProjectionEngine.actuals(
            from: records,
            in: TimeSpan(
                start: day,
                end: day.addingTimeInterval(86_400)
            )
        )

        XCTAssertFalse(actuals.contains { $0.title == "활동 추정" })
    }

    func testHeartRateVariabilityProjectsAsVitalsInsteadOfActivity() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(
            for: Date(timeIntervalSince1970: 1_788_000_000)
        )
        var records: [HealthKitSampleRecord] = []
        for dayOffset in -8 ... -1 {
            for sampleOffset in 0..<4 {
                records.append(biometricRecord(
                    identifier:
                        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
                    at: calendar.date(
                        byAdding: .day,
                        value: dayOffset,
                        to: day
                    )!.addingTimeInterval(TimeInterval(sampleOffset * 15 * 60)),
                    value: 50,
                    unit: "ms"
                ))
            }
        }
        let changedStart = day.addingTimeInterval(9 * 3_600)
        for minute in [0, 3, 6, 9, 12] {
            records.append(biometricRecord(
                identifier: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
                at: changedStart.addingTimeInterval(TimeInterval(minute * 60)),
                value: 80,
                unit: "ms"
            ))
        }

        let actuals = HealthKitBehaviorProjectionEngine.actuals(
            from: records,
            in: TimeSpan(
                start: day,
                end: day.addingTimeInterval(86_400)
            )
        )

        XCTAssertTrue(actuals.contains {
            $0.title == "생체 변화" && $0.categoryID == "health"
        })
        XCTAssertFalse(actuals.contains { $0.title == "활동 추정" })
    }

    func testMedicationInventoryDoesNotCreateAFakeDoseEvent() {
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        let record = HealthKitSampleRecord(
            uuid: UUID(),
            typeIdentifier:
                "HKDataTypeIdentifierUserAnnotatedMedicationConcept",
            startDate: start,
            endDate: start,
            textValue: "Medication inventory",
            sourceName: "Apple Health",
            userEntered: true
        )

        XCTAssertTrue(
            HealthKitBehaviorProjectionEngine.actuals(
                from: [record],
                in: TimeSpan(
                    start: start.addingTimeInterval(-60),
                    end: start.addingTimeInterval(600)
                )
            ).isEmpty
        )
    }

    func testNutrientSamplesAtOneMealMergeIntoOneTimelineCandidate() {
        let start = Date(timeIntervalSince1970: 1_788_000_000)
        let identifiers = [
            "HKQuantityTypeIdentifierDietaryCarbohydrates",
            "HKQuantityTypeIdentifierDietaryProtein",
            "HKQuantityTypeIdentifierDietaryFatTotal",
        ]
        let records = identifiers.enumerated().map { index, identifier in
            HealthKitSampleRecord(
                uuid: UUID(),
                typeIdentifier: identifier,
                startDate: start.addingTimeInterval(TimeInterval(index * 60)),
                endDate: start.addingTimeInterval(TimeInterval(index * 60)),
                numericValue: 10,
                unit: "g",
                sourceName: "Nutrition App",
                userEntered: true
            )
        }

        let actuals = HealthKitBehaviorProjectionEngine.actuals(
            from: records,
            in: TimeSpan(
                start: start.addingTimeInterval(-60),
                end: start.addingTimeInterval(30 * 60)
            )
        )

        XCTAssertEqual(actuals.count, 1)
        XCTAssertEqual(actuals.first?.categoryID, "eating")
        XCTAssertEqual(
            actuals.first?.evidence.filter { $0.contains("sampleUUIDs=") }.count,
            3
        )
    }

    private func heartRateRecord(
        at date: Date,
        value: Double
    ) -> HealthKitSampleRecord {
        biometricRecord(
            identifier: "HKQuantityTypeIdentifierHeartRate",
            at: date,
            value: value,
            unit: "count/min"
        )
    }

    private func biometricRecord(
        identifier: String,
        at date: Date,
        value: Double,
        unit: String
    ) -> HealthKitSampleRecord {
        HealthKitSampleRecord(
            uuid: UUID(),
            typeIdentifier: identifier,
            startDate: date,
            endDate: date,
            numericValue: value,
            unit: unit,
            sourceName: "Apple Watch",
            sourceProductType: "Watch"
        )
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("healthkit-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
