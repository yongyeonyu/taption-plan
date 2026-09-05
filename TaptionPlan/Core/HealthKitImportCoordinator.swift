import CoreLocation
import Foundation
import HealthKit

struct HealthKitSyncProgress: Hashable, Sendable {
    let completedTypes: Int
    let totalTypes: Int
    let typeName: String
    let importedSamples: Int
}

enum HealthKitImportCoordinatorError: LocalizedError {
    case localStoreUnavailable

    var errorDescription: String? {
        switch self {
        case .localStoreUnavailable:
            "HealthKit 로컬 원본 저장소를 열지 못했습니다."
        }
    }
}

@available(iOS 18.0, *)
actor HealthKitImportCoordinator {
    typealias ProgressHandler = @Sendable (HealthKitSyncProgress) async -> Void

    private struct AnchoredPage: @unchecked Sendable {
        let samples: [HKSample]
        let deleted: [HKDeletedObject]
        let anchor: HKQueryAnchor
    }

    private struct ClinicalCodingPayload: Codable, Sendable {
        let system: String
        let version: String?
        let code: String
    }

    private struct AnnotatedMedicationPayload: Codable, Sendable {
        let displayText: String
        let nickname: String?
        let generalForm: String
        let isArchived: Bool
        let hasSchedule: Bool
        let codings: [ClinicalCodingPayload]
    }

    private struct ECGVoltagePayload: Codable, Sendable {
        let timeSinceSampleStart: TimeInterval
        let microvolts: Double?
    }

    private struct HeartbeatPayload: Codable, Sendable {
        let timeSinceSeriesStart: TimeInterval
        let precededByGap: Bool
    }

    private struct WorkoutRoutePayload: Codable, Sendable {
        let timestamp: Date
        let latitude: Double
        let longitude: Double
        let altitude: Double
        let horizontalAccuracy: Double
        let verticalAccuracy: Double
        let speed: Double
        let course: Double
    }

    private let healthStore: HKHealthStore
    private let importStore: HealthKitImportStore?
    private let calendar: Calendar

    init(
        healthStore: HKHealthStore,
        importStore: HealthKitImportStore? = try? HealthKitImportStore()
    ) {
        self.healthStore = healthStore
        self.importStore = importStore
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        self.calendar = calendar
    }

    func overview() async throws -> HealthKitSyncOverview {
        guard let importStore else {
            throw HealthKitImportCoordinatorError.localStoreUnavailable
        }
        return try await importStore.overview()
    }

    func records(in span: TimeSpan) async throws -> [HealthKitSampleRecord] {
        guard let importStore else {
            throw HealthKitImportCoordinatorError.localStoreUnavailable
        }
        return try await importStore.records(
            from: span.start,
            through: span.end
        )
    }

    func deleteAll(generation: UInt64? = nil) async throws {
        guard let importStore else {
            throw HealthKitImportCoordinatorError.localStoreUnavailable
        }
        try await importStore.deleteAll(generation: generation)
    }

    func synchronizeFullHistory(
        progress: ProgressHandler? = nil
    ) async throws -> HealthKitSyncOverview {
        guard let importStore else {
            throw HealthKitImportCoordinatorError.localStoreUnavailable
        }
        let descriptors = sampleDescriptors()
        var importedSamples = 0

        for (index, descriptor) in descriptors.enumerated() {
            try Task.checkCancellation()
            guard let sampleType = HealthKitTypeCatalog
                .observableSampleType(for: descriptor) else {
                continue
            }
            var state = try await importStore.syncState(
                for: descriptor.identifier
            ) ?? HealthKitTypeSyncState(typeIdentifier: descriptor.identifier)
            do {
                if !state.historyComplete {
                    state = try await importHistory(
                        descriptor: descriptor,
                        sampleType: sampleType,
                        state: state,
                        importedSamples: &importedSamples,
                        progressIndex: index,
                        progressTotal: descriptors.count,
                        progress: progress
                    )
                }
                state = try await importAnchoredChanges(
                    descriptor: descriptor,
                    sampleType: sampleType,
                    state: state,
                    countsAsNew: state.anchor != nil,
                    importedSamples: &importedSamples
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                state = updatedState(
                    state,
                    lastSyncedAt: .now,
                    lastError: error.localizedDescription
                )
                try await importStore.saveSyncState(state)
            }
            await progress?(
                HealthKitSyncProgress(
                    completedTypes: index + 1,
                    totalTypes: descriptors.count,
                    typeName: descriptor.displayName,
                    importedSamples: importedSamples
                )
            )
        }

        try await importWhenAvailable(
            typeIdentifier: HealthKitTypeCatalog.documents.first?.identifier
        ) { try await importDocuments() }
        try await importWhenAvailable(
            typeIdentifier: "HKDataTypeIdentifierUserAnnotatedMedicationConcept"
        ) {
            try await importUserAnnotatedMedications()
        }
        try await importWhenAvailable { try await importCharacteristics() }
        try await importWhenAvailable(
            typeIdentifier: "HKActivitySummaryTypeIdentifier"
        ) {
            try await importActivitySummaries(
                from: healthStore.earliestPermittedSampleDate(),
                through: .now
            )
        }
        try Task.checkCancellation()
        return try await importStore.overview()
    }

    func synchronizeChanges(
        typeIdentifiers: Set<String>? = nil
    ) async throws -> HealthKitSyncOverview {
        guard let importStore else {
            throw HealthKitImportCoordinatorError.localStoreUnavailable
        }
        let descriptors = sampleDescriptors().filter { descriptor in
            typeIdentifiers?.contains(descriptor.identifier) ?? true
        }
        var importedSamples = 0
        for descriptor in descriptors {
            try Task.checkCancellation()
            guard let sampleType = HealthKitTypeCatalog
                .observableSampleType(for: descriptor) else {
                continue
            }
            var state = try await importStore.syncState(
                for: descriptor.identifier
            ) ?? HealthKitTypeSyncState(typeIdentifier: descriptor.identifier)
            do {
                if !state.historyComplete {
                    state = try await importHistory(
                        descriptor: descriptor,
                        sampleType: sampleType,
                        state: state,
                        importedSamples: &importedSamples,
                        progressIndex: 0,
                        progressTotal: descriptors.count,
                        progress: nil
                    )
                }
                _ = try await importAnchoredChanges(
                    descriptor: descriptor,
                    sampleType: sampleType,
                    state: state,
                    countsAsNew: state.anchor != nil,
                    importedSamples: &importedSamples
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                state = updatedState(
                    state,
                    lastSyncedAt: .now,
                    lastError: error.localizedDescription
                )
                try await importStore.saveSyncState(state)
            }
        }
        try await importWhenAvailable(
            typeIdentifier: HealthKitTypeCatalog.documents.first?.identifier
        ) { try await importDocuments() }
        try await importWhenAvailable(
            typeIdentifier: "HKDataTypeIdentifierUserAnnotatedMedicationConcept"
        ) {
            try await importUserAnnotatedMedications()
        }
        try await importWhenAvailable { try await importCharacteristics() }
        try await importWhenAvailable(
            typeIdentifier: "HKActivitySummaryTypeIdentifier"
        ) {
            try await importActivitySummaries(
                from: calendar.date(byAdding: .day, value: -31, to: .now)
                    ?? Date(timeIntervalSinceNow: -31 * 86_400),
                through: .now
            )
        }
        try Task.checkCancellation()
        return try await importStore.overview()
    }

    private func sampleDescriptors() -> [HealthKitTypeDescriptor] {
        HealthKitTypeCatalog.observableDescriptors.filter { descriptor in
            !descriptor.isClinical || healthStore.supportsHealthRecords()
        }
    }

    private func importWhenAvailable(
        typeIdentifier: String? = nil,
        _ operation: () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        do {
            try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let typeIdentifier, let importStore else { return }
            let previous = try await importStore.syncState(for: typeIdentifier)
                ?? HealthKitTypeSyncState(typeIdentifier: typeIdentifier)
            try await importStore.saveSyncState(updatedState(
                previous,
                lastSyncedAt: .now,
                lastError: error.localizedDescription
            ))
        }
    }

    private func importHistory(
        descriptor: HealthKitTypeDescriptor,
        sampleType: HKSampleType,
        state initialState: HealthKitTypeSyncState,
        importedSamples: inout Int,
        progressIndex: Int,
        progressTotal: Int,
        progress: ProgressHandler?
    ) async throws -> HealthKitTypeSyncState {
        guard let importStore else {
            throw HealthKitImportCoordinatorError.localStoreUnavailable
        }
        var state = initialState
        let now = Date.now
        var cursor = state.historyCursor.flatMap(Self.decodeDate)
        if cursor == nil {
            cursor = try await firstSampleDate(for: sampleType)
        }
        guard var pageStart = cursor else {
            let complete = updatedState(
                state,
                historyCursor: Self.encodeDate(now),
                historyComplete: true,
                lastSyncedAt: now,
                lastError: nil
            )
            try await importStore.saveSyncState(complete)
            return complete
        }
        pageStart = max(pageStart, healthStore.earliestPermittedSampleDate())

        while pageStart < now {
            try Task.checkCancellation()
            let nextMonth = calendar.date(
                byAdding: .month,
                value: 1,
                to: pageStart
            ) ?? now
            let pageEnd = min(nextMonth, now)
            let samples = try await samples(
                type: sampleType,
                from: pageStart,
                through: pageEnd
            )
            let records = try await records(
                from: samples,
                descriptor: descriptor
            )
            try Task.checkCancellation()
            importedSamples += records.count
            let nextState = updatedState(
                state,
                historyCursor: Self.encodeDate(pageEnd),
                historyComplete: pageEnd >= now,
                sampleCount: state.sampleCount + records.count,
                addedCount: state.addedCount + records.count,
                lastSampleDate: maxDate(
                    state.lastSampleDate,
                    records.map(\.endDate).max()
                ),
                lastSyncedAt: .now,
                lastError: nil
            )
            try await importStore.apply(
                records: records,
                deletedIDs: [],
                state: nextState
            )
            state = nextState
            pageStart = pageEnd
            await progress?(
                HealthKitSyncProgress(
                    completedTypes: progressIndex,
                    totalTypes: progressTotal,
                    typeName: descriptor.displayName,
                    importedSamples: importedSamples
                )
            )
        }
        return state
    }

    private func importAnchoredChanges(
        descriptor: HealthKitTypeDescriptor,
        sampleType: HKSampleType,
        state initialState: HealthKitTypeSyncState,
        countsAsNew: Bool,
        importedSamples: inout Int
    ) async throws -> HealthKitTypeSyncState {
        guard let importStore else {
            throw HealthKitImportCoordinatorError.localStoreUnavailable
        }
        var state = initialState
        var anchor = state.anchor.flatMap(Self.decodeAnchor)
        while true {
            let page = try await anchoredPage(
                type: sampleType,
                anchor: anchor
            )
            let records = try await records(
                from: page.samples,
                descriptor: descriptor
            )
            try Task.checkCancellation()
            importedSamples += records.count
            let encodedAnchor = try Self.encodeAnchor(page.anchor)
            let added = countsAsNew ? records.count : 0
            let nextState = updatedState(
                state,
                anchor: encodedAnchor,
                historyComplete: true,
                sampleCount: state.sampleCount + added - page.deleted.count,
                addedCount: state.addedCount + added,
                deletedCount: state.deletedCount + page.deleted.count,
                lastSampleDate: maxDate(
                    state.lastSampleDate,
                    records.map(\.endDate).max()
                ),
                lastDeletionDate: page.deleted.isEmpty ? state.lastDeletionDate : .now,
                lastSyncedAt: .now,
                lastError: nil
            )
            try await importStore.apply(
                records: records,
                deletedIDs: page.deleted.map(\.uuid),
                state: nextState
            )
            state = nextState
            anchor = page.anchor
            if records.isEmpty && page.deleted.isEmpty {
                return state
            }
        }
    }

    private func firstSampleDate(for type: HKSampleType) async throws -> Date? {
        let values = try await HKSampleQueryDescriptor(
            predicates: [.sample(type: type)],
            sortDescriptors: [SortDescriptor(\HKSample.startDate)],
            limit: 1
        ).result(for: healthStore)
        return values.first?.startDate
    }

    private func samples(
        type: HKSampleType,
        from start: Date,
        through end: Date
    ) async throws -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: .strictStartDate
        )
        return try await HKSampleQueryDescriptor(
            predicates: [.sample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\HKSample.startDate)]
        ).result(for: healthStore)
    }

    private func anchoredPage(
        type: HKSampleType,
        anchor: HKQueryAnchor?
    ) async throws -> AnchoredPage {
        let result = try await HKAnchoredObjectQueryDescriptor(
            predicates: [.sample(type: type)],
            anchor: anchor,
            limit: 500
        ).result(for: healthStore)
        return AnchoredPage(
            samples: result.addedSamples,
            deleted: result.deletedObjects,
            anchor: result.newAnchor
        )
    }

    private func records(
        from samples: [HKSample],
        descriptor: HealthKitTypeDescriptor
    ) async throws -> [HealthKitSampleRecord] {
        try Task.checkCancellation()
        var result: [HealthKitSampleRecord] = []
        result.reserveCapacity(samples.count)
        for sample in samples {
            let payload: Data?
            do {
                payload = try await specializedPayload(for: sample)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                payload = nil
            }
            result.append(
                record(
                    from: sample,
                    descriptor: descriptor,
                    specializedBinaryData: payload
                )
            )
        }
        try Task.checkCancellation()
        return result
    }

    private func specializedPayload(for sample: HKSample) async throws -> Data? {
        if let electrocardiogram = sample as? HKElectrocardiogram {
            var values: [ECGVoltagePayload] = []
            for try await measurement in HKElectrocardiogramQueryDescriptor(
                electrocardiogram
            ).results(for: healthStore) {
                try Task.checkCancellation()
                values.append(ECGVoltagePayload(
                    timeSinceSampleStart: measurement.timeSinceSampleStart,
                    microvolts: measurement.quantity(
                        for: .appleWatchSimilarToLeadI
                    )?.doubleValue(for: .voltUnit(with: .micro))
                ))
            }
            return try Self.encodePayload(values)
        }
        if let heartbeat = sample as? HKHeartbeatSeriesSample {
            var values: [HeartbeatPayload] = []
            for try await value in HKHeartbeatSeriesQueryDescriptor(
                heartbeat
            ).results(for: healthStore) {
                try Task.checkCancellation()
                values.append(HeartbeatPayload(
                    timeSinceSeriesStart: value.timeIntervalSinceStart,
                    precededByGap: value.precededByGap
                ))
            }
            return try Self.encodePayload(values)
        }
        if let route = sample as? HKWorkoutRoute {
            var values: [WorkoutRoutePayload] = []
            for try await location in HKWorkoutRouteQueryDescriptor(route)
                .results(for: healthStore) {
                try Task.checkCancellation()
                values.append(WorkoutRoutePayload(
                    timestamp: location.timestamp,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    altitude: location.altitude,
                    horizontalAccuracy: location.horizontalAccuracy,
                    verticalAccuracy: location.verticalAccuracy,
                    speed: location.speed,
                    course: location.course
                ))
            }
            return try Self.encodePayload(values)
        }
        return nil
    }

    private func record(
        from sample: HKSample,
        descriptor: HealthKitTypeDescriptor,
        specializedBinaryData: Data? = nil
    ) -> HealthKitSampleRecord {
        var numericValue: Double?
        var unitName: String?
        var categoryValue: Int?
        var textValue: String?
        var binaryData = specializedBinaryData
        var childIDs: [UUID] = []

        if let quantity = sample as? HKQuantitySample {
            if let unit = Self.unit(named: descriptor.canonicalUnit) {
                numericValue = quantity.quantity.doubleValue(for: unit)
                unitName = descriptor.canonicalUnit
            }
            textValue = quantity.quantity.description
        } else if let category = sample as? HKCategorySample {
            categoryValue = category.value
        } else if let correlation = sample as? HKCorrelation {
            childIDs = correlation.objects.map(\.uuid).sorted {
                $0.uuidString < $1.uuidString
            }
        } else if let workout = sample as? HKWorkout {
            numericValue = workout.duration
            unitName = "s"
            textValue = String(workout.workoutActivityType.rawValue)
        } else if let clinical = sample as? HKClinicalRecord {
            textValue = clinical.displayName
            binaryData = clinical.fhirResource?.data
        } else if let document = sample as? HKCDADocumentSample {
            textValue = document.document?.title
            binaryData = document.document?.documentData
        } else if let audiogram = sample as? HKAudiogramSample {
            textValue = "points=\(audiogram.sensitivityPoints.count)"
            binaryData = binaryData ?? Self.secureArchive(audiogram)
        } else if let prescription = sample as? HKVisionPrescription {
            textValue = "prescriptionType=\(prescription.prescriptionType.rawValue)"
            binaryData = binaryData ?? Self.secureArchive(prescription)
        } else if let assessment = sample as? HKScoredAssessment {
            numericValue = Double(assessment.score)
            unitName = "score"
        } else if let state = sample as? HKStateOfMind {
            numericValue = state.valence
            unitName = "valence"
            textValue = "kind=\(state.kind.rawValue);labels=\(state.labels);associations=\(state.associations)"
        } else if let ecg = sample as? HKElectrocardiogram {
            numericValue = ecg.averageHeartRate?.doubleValue(
                for: .count().unitDivided(by: .minute())
            )
            unitName = numericValue == nil ? nil : "count/min"
            textValue = "classification=\(ecg.classification.rawValue);measurements=\(ecg.numberOfVoltageMeasurements)"
            binaryData = binaryData ?? Self.secureArchive(ecg)
        } else if #available(iOS 26.0, *),
                  let medication = sample as? HKMedicationDoseEvent {
            textValue = "status=\(medication.logStatus.rawValue);schedule=\(medication.scheduleType.rawValue);unit=\(medication.unit)"
            binaryData = binaryData ?? Self.secureArchive(medication)
        } else if sample is HKHeartbeatSeriesSample {
            textValue = "heartbeat-series"
        } else if sample is HKWorkoutRoute {
            textValue = "workout-route"
        } else {
            textValue = String(describing: type(of: sample))
        }

        var metadata = (sample.metadata ?? [:]).reduce(
            into: [String: String]()
        ) { result, pair in
            result[pair.key] = String(describing: pair.value)
        }
        if let document = sample as? HKCDADocumentSample,
           let contents = document.document {
            metadata["cdaTitle"] = contents.title
            metadata["cdaPatientName"] = contents.patientName
            metadata["cdaAuthorName"] = contents.authorName
            metadata["cdaCustodianName"] = contents.custodianName
        }
        let device = sample.device
        return HealthKitSampleRecord(
            uuid: sample.uuid,
            typeIdentifier: descriptor.identifier,
            startDate: sample.startDate,
            endDate: max(sample.startDate, sample.endDate),
            numericValue: numericValue,
            unit: unitName,
            categoryValue: categoryValue,
            textValue: textValue,
            binaryData: binaryData,
            childIDs: childIDs,
            sourceName: sample.sourceRevision.source.name,
            sourceBundleIdentifier: sample.sourceRevision.source.bundleIdentifier,
            sourceVersion: sample.sourceRevision.version,
            sourceProductType: sample.sourceRevision.productType,
            deviceName: device?.name,
            deviceManufacturer: device?.manufacturer,
            deviceModel: device?.model,
            deviceHardwareVersion: device?.hardwareVersion,
            deviceFirmwareVersion: device?.firmwareVersion,
            deviceSoftwareVersion: device?.softwareVersion,
            deviceLocalIdentifier: device?.localIdentifier,
            deviceUDI: device?.udiDeviceIdentifier,
            userEntered: sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool
                ?? false,
            timeZoneIdentifier: sample.metadata?[HKMetadataKeyTimeZone]
                as? String,
            metadata: metadata
        )
    }

    private func importDocuments() async throws {
        guard let importStore,
              let descriptor = HealthKitTypeCatalog.documents.first,
              let type = HealthKitTypeCatalog.readObjectType(for: descriptor)
                as? HKDocumentType else {
            return
        }
        let documents = try await documents(type: type)
        try Task.checkCancellation()
        _ = try await importStore.upsert(
            documents.map { record(from: $0, descriptor: descriptor) }
        )
        let previous = try await importStore.syncState(for: descriptor.identifier)
            ?? HealthKitTypeSyncState(typeIdentifier: descriptor.identifier)
        try await importStore.saveSyncState(updatedState(
            previous,
            historyComplete: true,
            lastSyncedAt: .now,
            lastError: nil
        ))
    }

    private func documents(type: HKDocumentType) async throws
        -> [HKDocumentSample]
    {
        var result: [HKDocumentSample] = []
        let stream = AsyncThrowingStream<[HKDocumentSample], Error> {
            continuation in
            let query = HKDocumentQuery(
                documentType: type,
                predicate: nil,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil,
                includeDocumentData: true
            ) { _, documents, done, error in
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                continuation.yield(documents ?? [])
                if done {
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in
                self.healthStore.stop(query)
            }
            healthStore.execute(query)
        }
        for try await batch in stream {
            result.append(contentsOf: batch)
        }
        return result
    }

    private func importUserAnnotatedMedications() async throws {
        guard #available(iOS 26.0, *), let importStore else { return }
        let identifier = "HKDataTypeIdentifierUserAnnotatedMedicationConcept"
        let medications = try await userAnnotatedMedications()
        try Task.checkCancellation()
        let now = Date.now
        let records = try medications.map { medication in
            let codings = medication.medication.relatedCodings.map {
                ClinicalCodingPayload(
                    system: $0.system,
                    version: $0.version,
                    code: $0.code
                )
            }.sorted {
                if $0.system != $1.system { return $0.system < $1.system }
                return $0.code < $1.code
            }
            let identity = codings.isEmpty
                ? "\(medication.medication.displayText)|\(medication.medication.generalForm)"
                : codings.map { "\($0.system)|\($0.version ?? "")|\($0.code)" }
                    .joined(separator: ";")
            let payload = AnnotatedMedicationPayload(
                displayText: medication.medication.displayText,
                nickname: medication.nickname,
                generalForm: String(describing: medication.medication.generalForm),
                isArchived: medication.isArchived,
                hasSchedule: medication.hasSchedule,
                codings: codings
            )
            return HealthKitSampleRecord(
                uuid: Self.stableUUID("\(identifier)|\(identity)"),
                typeIdentifier: identifier,
                startDate: now,
                endDate: now,
                textValue: medication.medication.displayText,
                binaryData: try Self.encodePayload(payload),
                sourceName: "Apple Health",
                sourceBundleIdentifier: "com.apple.Health",
                userEntered: true,
                metadata: [
                    "archived": String(medication.isArchived),
                    "hasSchedule": String(medication.hasSchedule),
                    "nickname": medication.nickname ?? "",
                ]
            )
        }
        let previousState = try await importStore.syncState(for: identifier)
            ?? HealthKitTypeSyncState(typeIdentifier: identifier)
        let previousIDs = previousState.historyCursor.flatMap {
            try? PropertyListDecoder().decode([UUID].self, from: $0)
        } ?? []
        let currentIDs = records.map(\.uuid).sorted {
            $0.uuidString < $1.uuidString
        }
        let previousSet = Set(previousIDs)
        let currentSet = Set(currentIDs)
        let deletedIDs = previousSet.subtracting(currentSet)
        try Task.checkCancellation()
        let state = updatedState(
            previousState,
            historyCursor: try PropertyListEncoder().encode(currentIDs),
            historyComplete: true,
            sampleCount: currentIDs.count,
            addedCount: previousState.addedCount
                + currentSet.subtracting(previousSet).count,
            updatedCount: previousState.updatedCount
                + currentSet.intersection(previousSet).count,
            deletedCount: previousState.deletedCount + deletedIDs.count,
            lastSampleDate: records.isEmpty ? previousState.lastSampleDate : now,
            lastDeletionDate: deletedIDs.isEmpty
                ? previousState.lastDeletionDate
                : now,
            lastSyncedAt: now,
            lastError: nil
        )
        try await importStore.apply(
            records: records,
            deletedIDs: Array(deletedIDs),
            state: state
        )
    }

    @available(iOS 26.0, *)
    private func userAnnotatedMedications() async throws
        -> [HKUserAnnotatedMedication]
    {
        try await HKUserAnnotatedMedicationQueryDescriptor()
            .result(for: healthStore)
    }

    private func importCharacteristics() async throws {
        guard let importStore else { return }
        try Task.checkCancellation()
        let now = Date.now
        let values: [(String, String?)] = [
            (
                "HKCharacteristicTypeIdentifierDateOfBirth",
                try? healthStore.dateOfBirthComponents().date.map {
                    ISO8601DateFormatter().string(from: $0)
                }
            ),
            (
                "HKCharacteristicTypeIdentifierBiologicalSex",
                try? String(healthStore.biologicalSex().biologicalSex.rawValue)
            ),
            (
                "HKCharacteristicTypeIdentifierBloodType",
                try? String(healthStore.bloodType().bloodType.rawValue)
            ),
            (
                "HKCharacteristicTypeIdentifierFitzpatrickSkinType",
                try? String(
                    healthStore.fitzpatrickSkinType().skinType.rawValue
                )
            ),
            (
                "HKCharacteristicTypeIdentifierWheelchairUse",
                try? String(healthStore.wheelchairUse().wheelchairUse.rawValue)
            ),
            (
                "HKCharacteristicTypeIdentifierActivityMoveMode",
                try? String(
                    healthStore.activityMoveMode().activityMoveMode.rawValue
                )
            ),
        ]
        for (identifier, value) in values {
            try Task.checkCancellation()
            let previous = try await importStore.syncState(for: identifier)
                ?? HealthKitTypeSyncState(typeIdentifier: identifier)
            let records = value.map {
                [HealthKitSampleRecord(
                    uuid: Self.stableUUID(identifier),
                    typeIdentifier: identifier,
                    startDate: now,
                    endDate: now,
                    textValue: $0,
                    sourceName: "Apple Health",
                    sourceBundleIdentifier: "com.apple.Health"
                )]
            } ?? []
            let state = updatedState(
                previous,
                historyComplete: true,
                sampleCount: max(previous.sampleCount, records.count),
                addedCount: previous.addedCount
                    + (previous.sampleCount == 0 ? records.count : 0),
                updatedCount: previous.updatedCount
                    + (previous.sampleCount > 0 ? records.count : 0),
                lastSampleDate: records.isEmpty
                    ? previous.lastSampleDate
                    : now,
                lastSyncedAt: now,
                lastError: nil
            )
            try await importStore.apply(
                records: records,
                deletedIDs: [],
                state: state
            )
        }
    }

    private func importActivitySummaries(
        from start: Date,
        through end: Date
    ) async throws {
        guard let importStore else { return }
        let summaries = try await activitySummaries(from: start, through: end)
        try Task.checkCancellation()
        let records = summaries.compactMap { summary -> HealthKitSampleRecord? in
            let components = summary.dateComponents(for: calendar)
            guard let day = calendar.date(from: components),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: day)
            else { return nil }
            let energy = summary.activeEnergyBurned.doubleValue(
                for: .kilocalorie()
            )
            return HealthKitSampleRecord(
                uuid: Self.stableUUID(
                    "HKActivitySummaryTypeIdentifier.\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
                ),
                typeIdentifier: "HKActivitySummaryTypeIdentifier",
                startDate: day,
                endDate: dayEnd,
                numericValue: energy,
                unit: "kcal",
                textValue: "activity-summary",
                sourceName: "Apple Health",
                sourceBundleIdentifier: "com.apple.Health",
                metadata: [
                    "exerciseMinutes": String(
                        summary.appleExerciseTime.doubleValue(for: .minute())
                    ),
                    "standHours": String(
                        summary.appleStandHours.doubleValue(for: .count())
                    ),
                    "moveGoalKilocalories": String(
                        summary.activeEnergyBurnedGoal.doubleValue(
                            for: .kilocalorie()
                        )
                    ),
                    "paused": String(summary.isPaused),
                ]
            )
        }
        try Task.checkCancellation()
        let identifier = "HKActivitySummaryTypeIdentifier"
        let previous = try await importStore.syncState(for: identifier)
            ?? HealthKitTypeSyncState(typeIdentifier: identifier)
        let state = updatedState(
            previous,
            historyComplete: true,
            sampleCount: max(previous.sampleCount, records.count),
            addedCount: previous.addedCount
                + (previous.lastSyncedAt == nil ? records.count : 0),
            updatedCount: previous.updatedCount
                + (previous.lastSyncedAt == nil ? 0 : records.count),
            lastSampleDate: maxDate(
                previous.lastSampleDate,
                records.map(\.endDate).max()
            ),
            lastSyncedAt: .now,
            lastError: nil
        )
        try await importStore.apply(
            records: records,
            deletedIDs: [],
            state: state
        )
    }

    private func activitySummaries(
        from start: Date,
        through end: Date
    ) async throws -> [HKActivitySummary] {
        let startComponents = calendar.dateComponents(
            [.era, .year, .month, .day],
            from: start
        )
        let endComponents = calendar.dateComponents(
            [.era, .year, .month, .day],
            from: end
        )
        let predicate = HKQuery.predicate(
            forActivitySummariesBetweenStart: startComponents,
            end: endComponents
        )
        return try await HKActivitySummaryQueryDescriptor(
            predicate: predicate
        ).result(for: healthStore)
    }

    private func updatedState(
        _ state: HealthKitTypeSyncState,
        anchor: Data? = nil,
        historyCursor: Data? = nil,
        historyComplete: Bool? = nil,
        sampleCount: Int? = nil,
        addedCount: Int? = nil,
        updatedCount: Int? = nil,
        deletedCount: Int? = nil,
        lastSampleDate: Date? = nil,
        lastDeletionDate: Date? = nil,
        lastSyncedAt: Date? = nil,
        lastError: String? = nil
    ) -> HealthKitTypeSyncState {
        HealthKitTypeSyncState(
            typeIdentifier: state.typeIdentifier,
            anchor: anchor ?? state.anchor,
            historyCursor: historyCursor ?? state.historyCursor,
            historyComplete: historyComplete ?? state.historyComplete,
            sampleCount: max(0, sampleCount ?? state.sampleCount),
            addedCount: addedCount ?? state.addedCount,
            updatedCount: updatedCount ?? state.updatedCount,
            deletedCount: deletedCount ?? state.deletedCount,
            lastSampleDate: lastSampleDate ?? state.lastSampleDate,
            lastDeletionDate: lastDeletionDate ?? state.lastDeletionDate,
            lastSyncedAt: lastSyncedAt ?? state.lastSyncedAt,
            lastError: lastError,
            modelVersion: state.modelVersion
        )
    }

    static func unit(named name: String) -> HKUnit? {
        switch name {
        case "%": return .percent()
        case "count": return .count()
        case "count/s": return .count().unitDivided(by: .second())
        case "count/min": return .count().unitDivided(by: .minute())
        case "degC": return .degreeCelsius()
        case "kg": return .gramUnit(with: .kilo)
        case "g": return .gram()
        case "m": return .meter()
        case "cm": return .meterUnit(with: .centi)
        case "m/s": return .meter().unitDivided(by: .second())
        case "ms": return .secondUnit(with: .milli)
        case "s": return .second()
        case "min": return .minute()
        case "kcal": return .kilocalorie()
        case "mL": return .literUnit(with: .milli)
        case "L": return .liter()
        case "L/min": return .liter().unitDivided(by: .minute())
        case "mmHg": return .millimeterOfMercury()
        case "mg/dL":
            return .gramUnit(with: .milli).unitDivided(
                by: .literUnit(with: .deci)
            )
        case "IU": return .internationalUnit()
        case "W": return .watt()
        case "dBASPL": return .decibelAWeightedSoundPressureLevel()
        case "S": return .siemen()
        case "appleEffortScore": return .appleEffortScore()
        case "kcal/(kg*hr)":
            return .kilocalorie().unitDivided(
                by: .gramUnit(with: .kilo).unitMultiplied(by: .hour())
            )
        case "ml/(kg*min)":
            return .literUnit(with: .milli).unitDivided(
                by: .gramUnit(with: .kilo).unitMultiplied(by: .minute())
            )
        case "1": return .count()
        default: return nil
        }
    }

    private static func encodeAnchor(_ anchor: HKQueryAnchor) throws -> Data {
        try NSKeyedArchiver.archivedData(
            withRootObject: anchor,
            requiringSecureCoding: true
        )
    }

    private static func decodeAnchor(_ data: Data) -> HKQueryAnchor? {
        try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: HKQueryAnchor.self,
            from: data
        )
    }

    private static func encodeDate(_ date: Date) -> Data? {
        try? PropertyListEncoder().encode(date)
    }

    private static func encodePayload<T: Encodable>(_ payload: T) throws
        -> Data
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    private static func secureArchive(_ object: Any) -> Data? {
        try? NSKeyedArchiver.archivedData(
            withRootObject: object,
            requiringSecureCoding: true
        )
    }

    private static func decodeDate(_ data: Data) -> Date? {
        try? PropertyListDecoder().decode(Date.self, from: data)
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    private static func stableUUID(_ seed: String) -> UUID {
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x9e3779b185ebca87
        for byte in seed.utf8 {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second = (second ^ UInt64(byte)) &* 0x9e3779b185ebca87
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8((first >> UInt64(index * 8)) & 0xff)
            bytes[index + 8] = UInt8(
                (second >> UInt64(index * 8)) & 0xff
            )
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
