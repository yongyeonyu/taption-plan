import CoreLocation
import Foundation
import HealthKit

struct HealthKitImportDeltaCounts: Equatable {
    let added: Int
    let updated: Int
    let deleted: Int

    static func classify(
        incoming: Set<UUID>,
        deleted: Set<UUID>,
        existing: Set<UUID>,
        countsExistingAsUpdated: Bool
    ) -> Self {
        let survivingIncoming = incoming.subtracting(deleted)
        return Self(
            added: survivingIncoming.subtracting(existing).count,
            updated: countsExistingAsUpdated
                ? survivingIncoming.intersection(existing).count
                : 0,
            deleted: deleted.intersection(existing).count
        )
    }
}

struct HealthKitSnapshotReconciliation: Equatable {
    let currentIDs: [UUID]
    let deletedIDs: [UUID]
    let counts: HealthKitImportDeltaCounts
    let cursor: Data

    static func make(
        previousCursor: Data?,
        currentIDs: [UUID]
    ) throws -> Self {
        let previousIDs = try previousCursor.map {
            try PropertyListDecoder().decode([UUID].self, from: $0)
        } ?? []
        let previous = Set(previousIDs)
        let current = Set(currentIDs)
        let orderedCurrent = current.sorted {
            $0.uuidString < $1.uuidString
        }
        let deleted = previous.subtracting(current).sorted {
            $0.uuidString < $1.uuidString
        }
        return Self(
            currentIDs: orderedCurrent,
            deletedIDs: deleted,
            counts: HealthKitImportDeltaCounts.classify(
                incoming: current,
                deleted: Set(deleted),
                existing: previous,
                countsExistingAsUpdated: true
            ),
            cursor: try PropertyListEncoder().encode(orderedCurrent)
        )
    }
}

struct HealthKitSyncProgress: Hashable, Sendable {
    let completedTypes: Int
    let totalTypes: Int
    let typeName: String
    let importedSamples: Int
}

enum HealthKitImportCoordinatorError: LocalizedError, Equatable {
    case localStoreUnavailable
    case invalidHistoryCursor
    case invalidAnchorCursor

    var errorDescription: String? {
        switch self {
        case .localStoreUnavailable:
            "HealthKit 로컬 원본 저장소를 열지 못했습니다."
        case .invalidHistoryCursor:
            "HealthKit 전체 기록 동기화 지점을 읽지 못했습니다."
        case .invalidAnchorCursor:
            "HealthKit 변경 동기화 지점을 읽지 못했습니다."
        }
    }
}

actor HealthKitSynchronizationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var occupied = false
    private var waiters: [Waiter] = []

    func withPermit<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard occupied else {
            occupied = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        guard !waiters.isEmpty else {
            occupied = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }
}

@available(iOS 18.0, *)
actor HealthKitImportCoordinator {
    typealias ProgressHandler = @Sendable (HealthKitSyncProgress) async -> Void
    typealias FirstSampleDateLoader = @Sendable (HKSampleType) async throws -> Date?
    typealias EarliestPermittedDateLoader = @Sendable () -> Date
    typealias HistoryRecordLoader = @Sendable (
        HKSampleType,
        Date,
        Date
    ) async throws -> [HealthKitSampleRecord]

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

    private struct HistoryDateCursor: Codable, Sendable {
        let date: Date
    }

    private let healthStore: HKHealthStore
    private let importStore: HealthKitImportStore?
    private let calendar: Calendar
    private let synchronizationGate = HealthKitSynchronizationGate()
    private let firstSampleDateLoader: FirstSampleDateLoader?
    private let earliestPermittedDateLoader: EarliestPermittedDateLoader?
    private let historyRecordLoader: HistoryRecordLoader?
    private let payloadLoader: (@Sendable (HKSample) async throws -> Data?)?
    private let characteristicValueLoader: (@Sendable (String) throws -> String?)?

    init(
        healthStore: HKHealthStore,
        importStore: HealthKitImportStore? = try? HealthKitImportStore(),
        firstSampleDateLoader: FirstSampleDateLoader? = nil,
        earliestPermittedDateLoader: EarliestPermittedDateLoader? = nil,
        historyRecordLoader: HistoryRecordLoader? = nil,
        payloadLoader: (@Sendable (HKSample) async throws -> Data?)? = nil,
        characteristicValueLoader: (@Sendable (String) throws -> String?)? = nil
    ) {
        self.healthStore = healthStore
        self.importStore = importStore
        self.firstSampleDateLoader = firstSampleDateLoader
        self.earliestPermittedDateLoader = earliestPermittedDateLoader
        self.historyRecordLoader = historyRecordLoader
        self.payloadLoader = payloadLoader
        self.characteristicValueLoader = characteristicValueLoader
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
        try await synchronizationGate.withPermit {
            try await importStore.deleteAll(generation: generation)
        }
    }

    func synchronizeFullHistory(
        progress: ProgressHandler? = nil
    ) async throws -> HealthKitSyncOverview {
        try await synchronizationGate.withPermit {
            try await self.synchronizeFullHistorySerially(progress: progress)
        }
    }

    private func synchronizeFullHistorySerially(
        progress: ProgressHandler?
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
                state = try await importStore.syncState(
                    for: descriptor.identifier
                ) ?? state
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
                from: earliestPermittedSampleDate(),
                through: .now
            )
        }
        try Task.checkCancellation()
        return try await importStore.overview()
    }

    func synchronizeChanges(
        typeIdentifiers: Set<String>? = nil
    ) async throws -> HealthKitSyncOverview {
        try await synchronizationGate.withPermit {
            try await self.synchronizeChangesSerially(
                typeIdentifiers: typeIdentifiers,
                includeAncillary: true
            )
        }
    }

    func synchronizeSampleChanges(
        typeIdentifiers: Set<String>? = nil
    ) async throws -> HealthKitSyncOverview {
        try await synchronizationGate.withPermit {
            try await self.synchronizeChangesSerially(
                typeIdentifiers: typeIdentifiers,
                includeAncillary: false
            )
        }
    }

    private func synchronizeChangesSerially(
        typeIdentifiers: Set<String>?,
        includeAncillary: Bool
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
                state = try await importStore.syncState(
                    for: descriptor.identifier
                ) ?? state
                state = updatedState(
                    state,
                    lastSyncedAt: .now,
                    lastError: error.localizedDescription
                )
                try await importStore.saveSyncState(state)
            }
        }
        if includeAncillary {
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
            guard let typeIdentifier, let importStore else { throw error }
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
        let cursor: Date?
        if let historyCursor = state.historyCursor {
            cursor = try Self.decodeHistoryDate(historyCursor)
        } else {
            cursor = try await firstSampleDate(for: sampleType)
        }
        guard var pageStart = cursor else {
            let complete = updatedState(
                state,
                historyCursor: try Self.encodeDate(now),
                historyComplete: true,
                lastSyncedAt: now,
                lastError: nil
            )
            try await importStore.saveSyncState(complete)
            return complete
        }
        pageStart = max(pageStart, earliestPermittedSampleDate())

        while pageStart < now {
            try Task.checkCancellation()
            let nextMonth = calendar.date(
                byAdding: .month,
                value: 1,
                to: pageStart
            ) ?? now
            let pageEnd = min(nextMonth, now)
            let pageRecords: [HealthKitSampleRecord]
            if let historyRecordLoader {
                pageRecords = try await historyRecordLoader(
                    sampleType,
                    pageStart,
                    pageEnd
                )
            } else {
                let samples = try await samples(
                    type: sampleType,
                    from: pageStart,
                    through: pageEnd
                )
                pageRecords = try await records(
                    from: samples,
                    descriptor: descriptor
                )
            }
            try Task.checkCancellation()
            importedSamples += pageRecords.count
            let nextState = updatedState(
                state,
                historyCursor: try Self.encodeDate(pageEnd),
                historyComplete: pageEnd >= now,
                sampleCount: state.sampleCount + pageRecords.count,
                addedCount: state.addedCount + pageRecords.count,
                lastSampleDate: maxDate(
                    state.lastSampleDate,
                    pageRecords.map(\.endDate).max()
                ),
                lastSyncedAt: .now,
                lastError: nil
            )
            try await importStore.apply(
                records: pageRecords,
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
        var anchor = try state.anchor.map(Self.decodeAnchor)
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
            let incomingIDs = Set(records.map(\.uuid))
            let deletedIDs = Set(page.deleted.map(\.uuid))
            let existingIDs = try await importStore.existingRecordIDs(
                Array(incomingIDs.union(deletedIDs))
            )
            let delta = HealthKitImportDeltaCounts.classify(
                incoming: incomingIDs,
                deleted: deletedIDs,
                existing: existingIDs,
                countsExistingAsUpdated: countsAsNew
            )
            let nextState = updatedState(
                state,
                anchor: encodedAnchor,
                historyComplete: true,
                sampleCount: max(
                    0,
                    state.sampleCount + delta.added - delta.deleted
                ),
                addedCount: state.addedCount + delta.added,
                updatedCount: state.updatedCount + delta.updated,
                deletedCount: state.deletedCount + delta.deleted,
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
        if let firstSampleDateLoader {
            return try await firstSampleDateLoader(type)
        }
        let values = try await HKSampleQueryDescriptor(
            predicates: [.sample(type: type)],
            sortDescriptors: [SortDescriptor(\HKSample.startDate)],
            limit: 1
        ).result(for: healthStore)
        return values.first?.startDate
    }

    private func earliestPermittedSampleDate() -> Date {
        earliestPermittedDateLoader?() ?? healthStore.earliestPermittedSampleDate()
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

    func records(
        from samples: [HKSample],
        descriptor: HealthKitTypeDescriptor
    ) async throws -> [HealthKitSampleRecord] {
        try Task.checkCancellation()
        var result: [HealthKitSampleRecord] = []
        result.reserveCapacity(samples.count)
        for sample in samples {
            let payload: Data?
            if let payloadLoader {
                payload = try await payloadLoader(sample)
            } else {
                payload = try await specializedPayload(for: sample)
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
        let records = documents.map {
            record(from: $0, descriptor: descriptor)
        }
        let previous = try await importStore.syncState(for: descriptor.identifier)
            ?? HealthKitTypeSyncState(typeIdentifier: descriptor.identifier)
        let reconciliation = try HealthKitSnapshotReconciliation.make(
            previousCursor: previous.historyCursor,
            currentIDs: records.map(\.uuid)
        )
        let state = updatedState(
            previous,
            historyCursor: reconciliation.cursor,
            historyComplete: true,
            sampleCount: reconciliation.currentIDs.count,
            addedCount: previous.addedCount + reconciliation.counts.added,
            updatedCount: previous.updatedCount + reconciliation.counts.updated,
            deletedCount: previous.deletedCount + reconciliation.counts.deleted,
            lastSampleDate: maxDate(
                previous.lastSampleDate,
                records.map(\.endDate).max()
            ),
            lastDeletionDate: reconciliation.deletedIDs.isEmpty
                ? previous.lastDeletionDate
                : .now,
            lastSyncedAt: .now,
            lastError: nil
        )
        try await importStore.apply(
            records: records,
            deletedIDs: reconciliation.deletedIDs,
            state: state
        )
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
        let reconciliation = try HealthKitSnapshotReconciliation.make(
            previousCursor: previousState.historyCursor,
            currentIDs: records.map(\.uuid)
        )
        try Task.checkCancellation()
        let state = updatedState(
            previousState,
            historyCursor: reconciliation.cursor,
            historyComplete: true,
            sampleCount: reconciliation.currentIDs.count,
            addedCount: previousState.addedCount + reconciliation.counts.added,
            updatedCount: previousState.updatedCount
                + reconciliation.counts.updated,
            deletedCount: previousState.deletedCount
                + reconciliation.counts.deleted,
            lastSampleDate: records.isEmpty ? previousState.lastSampleDate : now,
            lastDeletionDate: reconciliation.deletedIDs.isEmpty
                ? previousState.lastDeletionDate
                : now,
            lastSyncedAt: now,
            lastError: nil
        )
        try await importStore.apply(
            records: records,
            deletedIDs: reconciliation.deletedIDs,
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

    func importCharacteristics() async throws {
        guard let importStore else { return }
        try Task.checkCancellation()
        let now = Date.now
        let readers: [(String, () throws -> String?)] = [
            (
                "HKCharacteristicTypeIdentifierDateOfBirth",
                {
                    try self.healthStore.dateOfBirthComponents().date.map {
                        ISO8601DateFormatter().string(from: $0)
                    }
                }
            ),
            (
                "HKCharacteristicTypeIdentifierBiologicalSex",
                {
                    try String(
                        self.healthStore.biologicalSex().biologicalSex.rawValue
                    )
                }
            ),
            (
                "HKCharacteristicTypeIdentifierBloodType",
                {
                    try String(self.healthStore.bloodType().bloodType.rawValue)
                }
            ),
            (
                "HKCharacteristicTypeIdentifierFitzpatrickSkinType",
                {
                    try String(
                        self.healthStore.fitzpatrickSkinType().skinType.rawValue
                    )
                }
            ),
            (
                "HKCharacteristicTypeIdentifierWheelchairUse",
                {
                    try String(
                        self.healthStore.wheelchairUse().wheelchairUse.rawValue
                    )
                }
            ),
            (
                "HKCharacteristicTypeIdentifierActivityMoveMode",
                {
                    try String(
                        self.healthStore.activityMoveMode().activityMoveMode.rawValue
                    )
                }
            ),
        ]
        for (identifier, readValue) in readers {
            try Task.checkCancellation()
            let previous = try await importStore.syncState(for: identifier)
                ?? HealthKitTypeSyncState(typeIdentifier: identifier)
            let value: String?
            do {
                if let characteristicValueLoader {
                    value = try characteristicValueLoader(identifier)
                } else {
                    value = try readValue()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await importStore.saveSyncState(updatedState(
                    previous,
                    lastSyncedAt: .now,
                    lastError: error.localizedDescription
                ))
                continue
            }
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
        // 유효하지 않은 범위(역전/비유한/미래 시작)를 예측 가능한 Swift
        // 오류로 걸러 HealthKit 이 NSException 을 던지기 전에 차단한다.
        guard start.timeIntervalSince1970.isFinite,
              end.timeIntervalSince1970.isFinite,
              start <= end else {
            return []
        }
        let predicate = Self.activitySummaryPredicate(
            from: start,
            through: end,
            calendar: calendar
        )
        return try await HKActivitySummaryQueryDescriptor(
            predicate: predicate
        ).result(for: healthStore)
    }

    static func activitySummaryPredicate(
        from start: Date,
        through end: Date,
        calendar: Calendar
    ) -> NSPredicate {
        // HKQuery.predicateForActivitySummaries 는 넘긴 DateComponents 의
        // calendar 가 명시적 timeZone 을 가져야 하고, era 등 과도한 필드가
        // 들어가면 특정 로캘에서 NSInvalidArgumentException 을 던져 앱을
        // abort 시킨다(백그라운드 임포트 중 크래시). 고정 timeZone 의
        // 그레고리력 + year/month/day 만으로 구성해 예외를 피한다.
        var safeCalendar = Calendar(identifier: .gregorian)
        safeCalendar.timeZone = calendar.timeZone
        var startComponents = safeCalendar.dateComponents(
            [.year, .month, .day],
            from: start
        )
        startComponents.calendar = safeCalendar
        startComponents.timeZone = calendar.timeZone
        var endComponents = safeCalendar.dateComponents(
            [.year, .month, .day],
            from: end
        )
        endComponents.calendar = safeCalendar
        endComponents.timeZone = calendar.timeZone
        return HKQuery.predicate(
            forActivitySummariesBetweenStart: startComponents,
            end: endComponents
        )
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

    static func decodeAnchor(_ data: Data) throws -> HKQueryAnchor {
        do {
            guard let anchor = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: HKQueryAnchor.self,
                from: data
            ) else {
                throw HealthKitImportCoordinatorError.invalidAnchorCursor
            }
            return anchor
        } catch {
            throw HealthKitImportCoordinatorError.invalidAnchorCursor
        }
    }

    static func encodeDate(_ date: Date) throws -> Data {
        try PropertyListEncoder().encode(HistoryDateCursor(date: date))
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

    static func decodeDate(_ data: Data) -> Date? {
        try? decodeHistoryDate(data)
    }

    private static func decodeHistoryDate(_ data: Data) throws -> Date {
        let decoder = PropertyListDecoder()
        if let cursor = try? decoder.decode(HistoryDateCursor.self, from: data) {
            return cursor.date
        }
        if let legacy = try? decoder.decode(Date.self, from: data) {
            return legacy
        }
        throw HealthKitImportCoordinatorError.invalidHistoryCursor
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
