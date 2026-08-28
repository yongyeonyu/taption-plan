import Foundation
import HealthKit

@available(iOS 18.0, *)
public enum HealthKitQueryKind: String, CaseIterable, Sendable {
    case quantity
    case category
    case characteristic
    case correlation
    case document
    case clinical
    case scoredAssessment
    case workout
    case activitySummary
    case workoutRoute
    case heartbeatSeries
    case audiogram
    case electrocardiogram
    case visionPrescription
    case stateOfMind
    case medicationDose
    case userAnnotatedMedication

    var isObservableSample: Bool {
        switch self {
        case .quantity, .category, .correlation, .clinical, .scoredAssessment,
             .document, .workout, .workoutRoute, .heartbeatSeries, .audiogram,
             .electrocardiogram, .visionPrescription, .stateOfMind, .medicationDose:
            true
        case .characteristic, .activitySummary, .userAnnotatedMedication:
            false
        }
    }
}

@available(iOS 18.0, *)
public enum HealthKitProjectionHint: String, Sendable {
    case scalar
    case event
    case interval
    case correlation
    case characteristic
    case clinicalRecord
    case assessment
    case workout
    case activitySummary
    case route
    case series
    case audiogram
    case electrocardiogram
    case visionPrescription
    case stateOfMind
    case medication
    /// Use HKDocumentQuery when document payload is needed; generic sample queries return metadata only.
    case document = "HKDocumentQuery"
}

@available(iOS 18.0, *)
public struct HealthKitTypeDescriptor: Identifiable, Hashable, Sendable {
    public let identifier: String
    public let displayName: String
    public let group: String
    public let queryKind: HealthKitQueryKind
    public let canonicalUnit: String
    public let minimumIOS: Double
    public let isSensitive: Bool
    public let isClinical: Bool
    public let backgroundEligible: Bool
    public let projectionHint: HealthKitProjectionHint

    public var id: String { identifier }

    public var isAvailableOnCurrentOS: Bool {
        HealthKitTypeCatalog.isAvailable(self)
    }
}

@available(iOS 18.0, *)
public enum HealthKitTypeCatalog {
    private typealias Raw = (identifier: String, group: String, unit: String, minimumIOS: Double)

    public static let all: [HealthKitTypeDescriptor] =
        quantityData.map { make($0, kind: .quantity) }
        + categoryData.map { make($0, kind: .category) }
        + characteristicData.map { make($0, kind: .characteristic) }
        + correlationData.map { make($0, kind: .correlation) }
        + documentData.map { make($0, kind: .document) }
        + clinicalData.map { make($0, kind: .clinical) }
        + scoredAssessmentData.map { make($0, kind: .scoredAssessment) }
        + specialData.map { make($0.identifier, group: $0.group, unit: $0.unit, minimumIOS: $0.minimumIOS, kind: $0.kind) }

    public static let quantities = all.filter { $0.queryKind == .quantity }
    public static let categories = all.filter { $0.queryKind == .category }
    public static let characteristics = all.filter { $0.queryKind == .characteristic }
    public static let correlations = all.filter { $0.queryKind == .correlation }
    public static let documents = all.filter { $0.queryKind == .document }
    public static let clinicalRecords = all.filter { $0.queryKind == .clinical }
    public static let observableDescriptors = all.filter { $0.queryKind.isObservableSample }

    public static func descriptor(for identifier: String) -> HealthKitTypeDescriptor? {
        all.first { $0.identifier == identifier }
    }

    public static func descriptors(for group: String) -> [HealthKitTypeDescriptor] {
        all.filter { $0.group == group }
    }

    public static func availableDescriptors(
        on version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> [HealthKitTypeDescriptor] {
        all.filter { isAvailable($0, on: version) }
    }

    public static func isAvailable(
        _ descriptor: HealthKitTypeDescriptor,
        on version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Bool {
        let required = descriptor.minimumIOS
        let major = Int(required)
        let minor = Int((required - Double(major)) * 10.0 + 0.01)
        if version.majorVersion != major {
            return version.majorVersion > major
        }
        return version.minorVersion >= minor
    }

    public static func readObjectType(for descriptor: HealthKitTypeDescriptor) -> HKObjectType? {
        guard descriptor.isAvailableOnCurrentOS else { return nil }

        switch descriptor.queryKind {
        case .quantity:
            return HKQuantityType(HKQuantityTypeIdentifier(rawValue: descriptor.identifier))
        case .category:
            return HKCategoryType(HKCategoryTypeIdentifier(rawValue: descriptor.identifier))
        case .characteristic:
            return HKCharacteristicType(HKCharacteristicTypeIdentifier(rawValue: descriptor.identifier))
        case .correlation:
            return HKCorrelationType(HKCorrelationTypeIdentifier(rawValue: descriptor.identifier))
        case .document:
            return HKDocumentType(HKDocumentTypeIdentifier(rawValue: descriptor.identifier))
        case .clinical:
            return HKClinicalType(HKClinicalTypeIdentifier(rawValue: descriptor.identifier))
        case .scoredAssessment:
            return HKScoredAssessmentType(HKScoredAssessmentTypeIdentifier(rawValue: descriptor.identifier))
        case .workout:
            return HKObjectType.workoutType()
        case .activitySummary:
            return HKObjectType.activitySummaryType()
        case .workoutRoute:
            return HKSeriesType.workoutRoute()
        case .heartbeatSeries:
            return HKSeriesType.heartbeat()
        case .audiogram:
            return HKObjectType.audiogramSampleType()
        case .electrocardiogram:
            return HKObjectType.electrocardiogramType()
        case .visionPrescription:
            return HKObjectType.visionPrescriptionType()
        case .stateOfMind:
            return HKObjectType.stateOfMindType()
        case .medicationDose:
            if #available(iOS 26.0, *) {
                return HKObjectType.medicationDoseEventType()
            }
            return nil
        case .userAnnotatedMedication:
            if #available(iOS 26.0, *) {
                return HKObjectType.userAnnotatedMedicationType()
            }
            return nil
        }
    }

    public static func readObjectTypes(
        on version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> [HKObjectType] {
        all.filter { isAvailable($0, on: version) }.compactMap(readObjectType(for:))
    }

    /// The standard authorization sheet rejects correlation types and vision
    /// prescriptions, which use component-type and per-object authorization.
    public static func standardAuthorizationObjectTypes(
        on version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> [HKObjectType] {
        all.filter {
            isAvailable($0, on: version)
                && $0.queryKind != .correlation
                && $0.queryKind != .visionPrescription
        }.compactMap(readObjectType(for:))
    }

    public static func observableSampleType(for descriptor: HealthKitTypeDescriptor) -> HKSampleType? {
        guard descriptor.queryKind.isObservableSample else { return nil }
        return readObjectType(for: descriptor) as? HKSampleType
    }

    public static func observableSampleTypes(
        on version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> [HKSampleType] {
        observableDescriptors
            .filter { isAvailable($0, on: version) }
            .compactMap(observableSampleType(for:))
    }

    private static func make(_ raw: Raw, kind: HealthKitQueryKind) -> HealthKitTypeDescriptor {
        make(
            raw.identifier,
            group: raw.group,
            unit: raw.unit,
            minimumIOS: raw.minimumIOS,
            kind: kind
        )
    }

    private static func make(
        _ identifier: String,
        group: String,
        unit: String,
        minimumIOS: Double,
        kind: HealthKitQueryKind
    ) -> HealthKitTypeDescriptor {
        HealthKitTypeDescriptor(
            identifier: identifier,
            displayName: "\(group) · \(shortName(identifier))",
            group: group,
            queryKind: kind,
            canonicalUnit: unit,
            minimumIOS: minimumIOS,
            isSensitive: true,
            isClinical: kind == .clinical || kind == .scoredAssessment || kind == .medicationDose || kind == .userAnnotatedMedication,
            backgroundEligible: isBackgroundEligible(kind),
            projectionHint: projectionHint(for: identifier, kind: kind)
        )
    }

    private static func shortName(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCharacteristicTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCorrelationTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKClinicalTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKDocumentTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKScoredAssessmentTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKMedicationDoseEventTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKDataTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKWorkoutTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKWorkoutRouteTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKVisionPrescriptionTypeIdentifier", with: "")
    }

    private static func isBackgroundEligible(_ kind: HealthKitQueryKind) -> Bool {
        switch kind {
        case .quantity, .category, .correlation, .clinical, .scoredAssessment,
             .document, .workout, .workoutRoute, .heartbeatSeries, .audiogram,
             .electrocardiogram, .stateOfMind, .medicationDose:
            true
        case .characteristic, .activitySummary, .visionPrescription,
             .userAnnotatedMedication:
            false
        }
    }

    private static func projectionHint(for identifier: String, kind: HealthKitQueryKind) -> HealthKitProjectionHint {
        switch kind {
        case .quantity:
            if identifier.contains("Temperature") || identifier.contains("Pressure") {
                return .scalar
            }
            return .scalar
        case .category:
            return identifier.contains("SleepAnalysis") ? .interval : .event
        case .characteristic:
            return .characteristic
        case .correlation:
            return .correlation
        case .document:
            return .document
        case .clinical:
            return .clinicalRecord
        case .scoredAssessment:
            return .assessment
        case .workout:
            return .workout
        case .activitySummary:
            return .activitySummary
        case .workoutRoute:
            return .route
        case .heartbeatSeries:
            return .series
        case .audiogram:
            return .audiogram
        case .electrocardiogram:
            return .electrocardiogram
        case .visionPrescription:
            return .visionPrescription
        case .stateOfMind:
            return .stateOfMind
        case .medicationDose, .userAnnotatedMedication:
            return .medication
        }
    }

    private static let quantityData: [Raw] = [
        ("HKQuantityTypeIdentifierAppleSleepingWristTemperature", "신체 측정", "degC", 16),
        ("HKQuantityTypeIdentifierBodyFatPercentage", "신체 측정", "%", 8),
        ("HKQuantityTypeIdentifierBodyMass", "신체 측정", "kg", 8),
        ("HKQuantityTypeIdentifierBodyMassIndex", "신체 측정", "count", 8),
        ("HKQuantityTypeIdentifierElectrodermalActivity", "신체 측정", "S", 8),
        ("HKQuantityTypeIdentifierHeight", "신체 측정", "m", 8),
        ("HKQuantityTypeIdentifierLeanBodyMass", "신체 측정", "kg", 8),
        ("HKQuantityTypeIdentifierWaistCircumference", "신체 측정", "m", 11),
        ("HKQuantityTypeIdentifierActiveEnergyBurned", "운동", "kcal", 8),
        ("HKQuantityTypeIdentifierAppleExerciseTime", "운동", "min", 9.3),
        ("HKQuantityTypeIdentifierAppleMoveTime", "운동", "min", 14.5),
        ("HKQuantityTypeIdentifierAppleStandTime", "운동", "min", 13),
        ("HKQuantityTypeIdentifierBasalEnergyBurned", "운동", "kcal", 8),
        ("HKQuantityTypeIdentifierCrossCountrySkiingSpeed", "운동", "m/s", 18),
        ("HKQuantityTypeIdentifierCyclingCadence", "운동", "count/min", 17),
        ("HKQuantityTypeIdentifierCyclingFunctionalThresholdPower", "운동", "W", 17),
        ("HKQuantityTypeIdentifierCyclingPower", "운동", "W", 17),
        ("HKQuantityTypeIdentifierCyclingSpeed", "운동", "m/s", 17),
        ("HKQuantityTypeIdentifierDistanceCrossCountrySkiing", "운동", "m", 18),
        ("HKQuantityTypeIdentifierDistanceCycling", "운동", "m", 8),
        ("HKQuantityTypeIdentifierDistanceDownhillSnowSports", "운동", "m", 11.2),
        ("HKQuantityTypeIdentifierDistancePaddleSports", "운동", "m", 18),
        ("HKQuantityTypeIdentifierDistanceRowing", "운동", "m", 18),
        ("HKQuantityTypeIdentifierDistanceSkatingSports", "운동", "m", 18),
        ("HKQuantityTypeIdentifierDistanceSwimming", "운동", "m", 10),
        ("HKQuantityTypeIdentifierDistanceWalkingRunning", "운동", "m", 8),
        ("HKQuantityTypeIdentifierDistanceWheelchair", "운동", "m", 10),
        ("HKQuantityTypeIdentifierEstimatedWorkoutEffortScore", "운동", "appleEffortScore", 18),
        ("HKQuantityTypeIdentifierFlightsClimbed", "운동", "count", 8),
        ("HKQuantityTypeIdentifierNikeFuel", "운동", "count", 8),
        ("HKQuantityTypeIdentifierPaddleSportsSpeed", "운동", "m/s", 18),
        ("HKQuantityTypeIdentifierPhysicalEffort", "운동", "kcal/(kg*hr)", 17),
        ("HKQuantityTypeIdentifierPushCount", "운동", "count", 10),
        ("HKQuantityTypeIdentifierRowingSpeed", "운동", "m/s", 18),
        ("HKQuantityTypeIdentifierRunningPower", "운동", "W", 16),
        ("HKQuantityTypeIdentifierRunningSpeed", "운동", "m/s", 16),
        ("HKQuantityTypeIdentifierStepCount", "운동", "count", 8),
        ("HKQuantityTypeIdentifierSwimmingStrokeCount", "운동", "count", 10),
        ("HKQuantityTypeIdentifierUnderwaterDepth", "운동", "m", 16),
        ("HKQuantityTypeIdentifierWorkoutEffortScore", "운동", "appleEffortScore", 18),
        ("HKQuantityTypeIdentifierEnvironmentalAudioExposure", "청각 건강", "dBASPL", 13),
        ("HKQuantityTypeIdentifierEnvironmentalSoundReduction", "청각 건강", "dBASPL", 16),
        ("HKQuantityTypeIdentifierHeadphoneAudioExposure", "청각 건강", "dBASPL", 13),
        ("HKQuantityTypeIdentifierAtrialFibrillationBurden", "심장", "%", 16),
        ("HKQuantityTypeIdentifierHeartRate", "심장", "count/min", 8),
        ("HKQuantityTypeIdentifierHeartRateRecoveryOneMinute", "심장", "count/min", 16),
        ("HKQuantityTypeIdentifierHeartRateVariabilitySDNN", "심장", "ms", 11),
        ("HKQuantityTypeIdentifierPeripheralPerfusionIndex", "심장", "%", 8),
        ("HKQuantityTypeIdentifierRestingHeartRate", "심장", "count/min", 11),
        ("HKQuantityTypeIdentifierVO2Max", "심장", "ml/(kg*min)", 11),
        ("HKQuantityTypeIdentifierWalkingHeartRateAverage", "심장", "count/min", 11),
        ("HKQuantityTypeIdentifierAppleWalkingSteadiness", "이동성", "%", 15),
        ("HKQuantityTypeIdentifierRunningGroundContactTime", "이동성", "ms", 16),
        ("HKQuantityTypeIdentifierRunningStrideLength", "이동성", "m", 16),
        ("HKQuantityTypeIdentifierRunningVerticalOscillation", "이동성", "cm", 16),
        ("HKQuantityTypeIdentifierSixMinuteWalkTestDistance", "이동성", "m", 14),
        ("HKQuantityTypeIdentifierStairAscentSpeed", "이동성", "m/s", 14),
        ("HKQuantityTypeIdentifierStairDescentSpeed", "이동성", "m/s", 14),
        ("HKQuantityTypeIdentifierWalkingAsymmetryPercentage", "이동성", "%", 14),
        ("HKQuantityTypeIdentifierWalkingDoubleSupportPercentage", "이동성", "%", 14),
        ("HKQuantityTypeIdentifierWalkingSpeed", "이동성", "m/s", 14),
        ("HKQuantityTypeIdentifierWalkingStepLength", "이동성", "m", 14),
        ("HKQuantityTypeIdentifierDietaryBiotin", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryCaffeine", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryCalcium", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryCarbohydrates", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryChloride", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryCholesterol", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryChromium", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryCopper", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryEnergyConsumed", "영양", "kcal", 8),
        ("HKQuantityTypeIdentifierDietaryFatMonounsaturated", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryFatPolyunsaturated", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryFatSaturated", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryFatTotal", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryFiber", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryFolate", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryIodine", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryIron", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryMagnesium", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryManganese", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryMolybdenum", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryNiacin", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryPantothenicAcid", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryPhosphorus", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryPotassium", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryProtein", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryRiboflavin", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietarySelenium", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietarySodium", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietarySugar", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryThiamin", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryVitaminA", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryVitaminB12", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryVitaminB6", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryVitaminC", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryVitaminD", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryVitaminE", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryVitaminK", "영양", "g", 8),
        ("HKQuantityTypeIdentifierDietaryWater", "영양", "mL", 9),
        ("HKQuantityTypeIdentifierDietaryZinc", "영양", "g", 8),
        ("HKQuantityTypeIdentifierBloodAlcoholContent", "기타", "%", 8),
        ("HKQuantityTypeIdentifierBloodPressureDiastolic", "기타", "mmHg", 8),
        ("HKQuantityTypeIdentifierBloodPressureSystolic", "기타", "mmHg", 8),
        ("HKQuantityTypeIdentifierInsulinDelivery", "기타", "IU", 11),
        ("HKQuantityTypeIdentifierNumberOfAlcoholicBeverages", "기타", "count", 15),
        ("HKQuantityTypeIdentifierNumberOfTimesFallen", "기타", "count", 8),
        ("HKQuantityTypeIdentifierTimeInDaylight", "기타", "min", 17),
        ("HKQuantityTypeIdentifierUVExposure", "기타", "1", 9),
        ("HKQuantityTypeIdentifierWaterTemperature", "기타", "degC", 16),
        ("HKQuantityTypeIdentifierBasalBodyTemperature", "생식 건강", "degC", 9),
        ("HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances", "호흡", "count", 18),
        ("HKQuantityTypeIdentifierForcedExpiratoryVolume1", "호흡", "L", 8),
        ("HKQuantityTypeIdentifierForcedVitalCapacity", "호흡", "L", 8),
        ("HKQuantityTypeIdentifierInhalerUsage", "호흡", "count", 8),
        ("HKQuantityTypeIdentifierOxygenSaturation", "호흡", "%", 8),
        ("HKQuantityTypeIdentifierPeakExpiratoryFlowRate", "호흡", "L/min", 8),
        ("HKQuantityTypeIdentifierRespiratoryRate", "호흡", "count/min", 8),
        ("HKQuantityTypeIdentifierBloodGlucose", "활력 징후", "mg/dL", 8),
        ("HKQuantityTypeIdentifierBodyTemperature", "활력 징후", "degC", 8)
    ]

    private static let categoryData: [Raw] = [
        ("HKCategoryTypeIdentifierAppleStandHour", "운동", "event", 9),
        ("HKCategoryTypeIdentifierAudioExposureEvent", "청각 건강", "event", 14),
        ("HKCategoryTypeIdentifierHeadphoneAudioExposureEvent", "청각 건강", "event", 14.2),
        ("HKCategoryTypeIdentifierHighHeartRateEvent", "심장", "event", 12.2),
        ("HKCategoryTypeIdentifierHypertensionEvent", "심장", "event", 26.2),
        ("HKCategoryTypeIdentifierIrregularHeartRhythmEvent", "심장", "event", 12.2),
        ("HKCategoryTypeIdentifierLowCardioFitnessEvent", "심장", "event", 14.3),
        ("HKCategoryTypeIdentifierLowHeartRateEvent", "심장", "event", 12.2),
        ("HKCategoryTypeIdentifierMindfulSession", "정신 웰빙", "event", 10),
        ("HKCategoryTypeIdentifierAppleWalkingSteadinessEvent", "이동성", "event", 15),
        ("HKCategoryTypeIdentifierHandwashingEvent", "기타", "event", 14),
        ("HKCategoryTypeIdentifierToothbrushingEvent", "기타", "event", 13),
        ("HKCategoryTypeIdentifierBleedingAfterPregnancy", "생식 건강", "event", 18),
        ("HKCategoryTypeIdentifierBleedingDuringPregnancy", "생식 건강", "event", 18),
        ("HKCategoryTypeIdentifierCervicalMucusQuality", "생식 건강", "event", 9),
        ("HKCategoryTypeIdentifierContraceptive", "생식 건강", "event", 14.3),
        ("HKCategoryTypeIdentifierInfrequentMenstrualCycles", "생식 건강", "event", 16),
        ("HKCategoryTypeIdentifierIntermenstrualBleeding", "생식 건강", "event", 9),
        ("HKCategoryTypeIdentifierIrregularMenstrualCycles", "생식 건강", "event", 16),
        ("HKCategoryTypeIdentifierLactation", "생식 건강", "event", 14.3),
        ("HKCategoryTypeIdentifierMenstrualFlow", "생식 건강", "event", 9),
        ("HKCategoryTypeIdentifierOvulationTestResult", "생식 건강", "event", 9),
        ("HKCategoryTypeIdentifierPersistentIntermenstrualBleeding", "생식 건강", "event", 16),
        ("HKCategoryTypeIdentifierPregnancy", "생식 건강", "event", 14.3),
        ("HKCategoryTypeIdentifierPregnancyTestResult", "생식 건강", "event", 15),
        ("HKCategoryTypeIdentifierProgesteroneTestResult", "생식 건강", "event", 15),
        ("HKCategoryTypeIdentifierProlongedMenstrualPeriods", "생식 건강", "event", 16),
        ("HKCategoryTypeIdentifierSexualActivity", "생식 건강", "event", 9),
        ("HKCategoryTypeIdentifierSleepApneaEvent", "호흡", "event", 18),
        ("HKCategoryTypeIdentifierSleepAnalysis", "수면", "event", 8),
        ("HKCategoryTypeIdentifierAbdominalCramps", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierAcne", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierAppetiteChanges", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierBladderIncontinence", "증상", "event", 14),
        ("HKCategoryTypeIdentifierBloating", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierBreastPain", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierChestTightnessOrPain", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierChills", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierConstipation", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierCoughing", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierDiarrhea", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierDizziness", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierDrySkin", "증상", "event", 14),
        ("HKCategoryTypeIdentifierFainting", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierFatigue", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierFever", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierGeneralizedBodyAche", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierHairLoss", "증상", "event", 14),
        ("HKCategoryTypeIdentifierHeadache", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierHeartburn", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierHotFlashes", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierLossOfSmell", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierLossOfTaste", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierLowerBackPain", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierMemoryLapse", "증상", "event", 14),
        ("HKCategoryTypeIdentifierMoodChanges", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierNausea", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierNightSweats", "증상", "event", 14),
        ("HKCategoryTypeIdentifierPelvicPain", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierRapidPoundingOrFlutteringHeartbeat", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierRunnyNose", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierShortnessOfBreath", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierSinusCongestion", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierSkippedHeartbeat", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierSleepChanges", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierSoreThroat", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierVaginalDryness", "증상", "event", 14),
        ("HKCategoryTypeIdentifierVomiting", "증상", "event", 13.6),
        ("HKCategoryTypeIdentifierWheezing", "증상", "event", 13.6)
    ]

    private static let characteristicData: [Raw] = [
        ("HKCharacteristicTypeIdentifierActivityMoveMode", "사용자 특성", "value", 14),
        ("HKCharacteristicTypeIdentifierBiologicalSex", "사용자 특성", "value", 8),
        ("HKCharacteristicTypeIdentifierBloodType", "사용자 특성", "value", 8),
        ("HKCharacteristicTypeIdentifierDateOfBirth", "사용자 특성", "date", 8),
        ("HKCharacteristicTypeIdentifierFitzpatrickSkinType", "사용자 특성", "value", 9),
        ("HKCharacteristicTypeIdentifierWheelchairUse", "사용자 특성", "value", 10)
    ]

    private static let correlationData: [Raw] = [
        ("HKCorrelationTypeIdentifierBloodPressure", "심장", "correlation", 8),
        ("HKCorrelationTypeIdentifierFood", "영양", "correlation", 8)
    ]

    private static let documentData: [Raw] = [
        ("HKDocumentTypeIdentifierCDA", "임상 문서", "document", 10)
    ]

    private static let clinicalData: [Raw] = [
        ("HKClinicalTypeIdentifierAllergyRecord", "임상 기록", "record", 12),
        ("HKClinicalTypeIdentifierClinicalNoteRecord", "임상 기록", "record", 16.4),
        ("HKClinicalTypeIdentifierConditionRecord", "임상 기록", "record", 12),
        ("HKClinicalTypeIdentifierImmunizationRecord", "임상 기록", "record", 12),
        ("HKClinicalTypeIdentifierLabResultRecord", "임상 기록", "record", 12),
        ("HKClinicalTypeIdentifierMedicationRecord", "임상 기록", "record", 12),
        ("HKClinicalTypeIdentifierProcedureRecord", "임상 기록", "record", 12),
        ("HKClinicalTypeIdentifierVitalSignRecord", "임상 기록", "record", 12),
        ("HKClinicalTypeIdentifierCoverageRecord", "임상 기록", "record", 14)
    ]

    private static let scoredAssessmentData: [Raw] = [
        ("HKScoredAssessmentTypeIdentifierGAD7", "정신 웰빙", "score", 18),
        ("HKScoredAssessmentTypeIdentifierPHQ9", "정신 웰빙", "score", 18)
    ]

    private static let specialData: [(identifier: String, group: String, unit: String, minimumIOS: Double, kind: HealthKitQueryKind)] = [
        ("HKWorkoutTypeIdentifier", "운동", "workout", 8, .workout),
        ("HKActivitySummaryTypeIdentifier", "운동", "summary", 9.3, .activitySummary),
        ("HKWorkoutRouteTypeIdentifier", "경로", "route", 11, .workoutRoute),
        ("HKDataTypeIdentifierHeartbeatSeries", "심장", "series", 13, .heartbeatSeries),
        ("HKAudiogramSampleTypeIdentifier", "청각 건강", "audiogram", 13, .audiogram),
        ("HKElectrocardiogramTypeIdentifier", "심장", "ecg", 14, .electrocardiogram),
        ("HKVisionPrescriptionTypeIdentifier", "시력", "prescription", 16, .visionPrescription),
        ("HKDataTypeIdentifierStateOfMind", "정신 웰빙", "stateOfMind", 18, .stateOfMind),
        ("HKMedicationDoseEventTypeIdentifierMedicationDoseEvent", "복약", "dose", 26, .medicationDose),
        ("HKDataTypeIdentifierUserAnnotatedMedicationConcept", "복약", "medication", 26, .userAnnotatedMedication)
    ]
}
