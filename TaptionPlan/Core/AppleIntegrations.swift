import AVFoundation
import CallKit
import CoreLocation
import CoreMotion
import EventKit
import Foundation
import HealthKit
import MediaPlayer
import MapKit
import NetworkExtension
import Photos
import UIKit
import UserNotifications
import WeatherKit

// MARK: - Calendar

@MainActor
final class AppleCalendarService {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func permissionState() -> PermissionState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted, .writeOnly:
            return .denied
        case .fullAccess, .authorized:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func requestFullAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToEvents()
    }

    func calendars() -> [(id: String, title: String)] {
        eventStore.calendars(for: .event)
            .map { ($0.calendarIdentifier, $0.title) }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    func events(
        in span: TimeSpan,
        selectedCalendarIDs: Set<String>
    ) -> [CalendarRecord] {
        let calendars = eventStore.calendars(for: .event).filter {
            selectedCalendarIDs.isEmpty
                || selectedCalendarIDs.contains($0.calendarIdentifier)
        }
        let predicate = eventStore.predicateForEvents(
            withStart: span.start,
            end: span.end,
            calendars: calendars
        )
        return eventStore.events(matching: predicate).map { event in
            CalendarRecord(
                id: event.eventIdentifier ?? UUID().uuidString,
                calendarID: event.calendar.calendarIdentifier,
                title: event.title ?? "제목 없는 일정",
                span: TimeSpan(start: event.startDate, end: event.endDate),
                isAllDay: event.isAllDay,
                calendarTitle: event.calendar.title,
                calendarColorHex: Self.hex(event.calendar.cgColor),
                sourceTitle: event.calendar.source.title,
                attendeeCount: event.attendees?.count,
                isCancelled: event.status == .canceled
            )
        }
    }

    func addPlan(
        _ plan: PlanRecord,
        to calendarID: String? = nil
    ) throws -> String {
        let event = EKEvent(eventStore: eventStore)
        event.title = plan.title
        event.startDate = plan.span.start
        event.endDate = plan.span.end
        event.calendar = calendarID.flatMap { id in
            eventStore.calendars(for: .event).first {
                $0.calendarIdentifier == id
            }
        } ?? eventStore.defaultCalendarForNewEvents
        try eventStore.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier
    }

    private static func hex(_ color: CGColor) -> String? {
        guard let components = color.components else { return nil }
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        if components.count >= 3 {
            red = components[0]
            green = components[1]
            blue = components[2]
        } else if let gray = components.first {
            red = gray
            green = gray
            blue = gray
        } else {
            return nil
        }
        return String(
            format: "#%02X%02X%02X",
            Int(red * 255),
            Int(green * 255),
            Int(blue * 255)
        )
    }
}

// MARK: - Photos

enum PhotoServiceError: Error {
    case imageUnavailable
    case requestCancelled
}

final class ApplePhotoLibraryService: @unchecked Sendable {
    private let imageManager: PHImageManager

    init(imageManager: PHImageManager = .default()) {
        self.imageManager = imageManager
    }

    func permissionState() -> PermissionState {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        case .limited:
            return .limited
        case .authorized:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func requestAccess() async -> PermissionState {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        case .limited:
            return .limited
        case .authorized:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func moments(in span: TimeSpan) -> [PhotoMoment] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@",
            span.start as NSDate,
            span.end as NSDate
        )
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: true)
        ]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var moments: [PhotoMoment] = []
        result.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            let point = asset.location.map {
                GeoPoint(
                    latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude,
                    altitude: $0.altitude,
                    horizontalAccuracy: $0.horizontalAccuracy,
                    verticalAccuracy: $0.verticalAccuracy
                )
            }
            moments.append(
                PhotoMoment(
                    id: asset.localIdentifier,
                    capturedAt: date,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    isFavorite: asset.isFavorite,
                    isHiddenFromTimeline: asset.isHidden,
                    location: point,
                    linkedPlanID: nil,
                    linkedPlaceID: nil
                )
            )
        }
        return moments
    }

    func thumbnailJPEG(
        localIdentifier: String,
        size: CGSize,
        quality: CGFloat = 0.8
    ) async throws -> Data {
        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        )
        guard let asset = assets.firstObject else {
            throw PhotoServiceError.imageUnavailable
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        return try await withCheckedThrowingContinuation { continuation in
            imageManager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: PhotoServiceError.requestCancelled)
                    return
                }
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                    return
                }
                guard let data = image?.jpegData(compressionQuality: quality) else {
                    continuation.resume(throwing: PhotoServiceError.imageUnavailable)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }
}

// MARK: - Health and Apple Watch data mirrored to iPhone

enum HealthRefreshPolicy {
    static let foregroundInterval: TimeInterval = 5 * 60
    static let broadRawSyncInterval: TimeInterval = 15 * 60
    static let periodicLookback: TimeInterval = 2 * 86_400
    static let backgroundFrequency: HKUpdateFrequency = .immediate
}

actor HealthBackgroundRefreshCoordinator {
    typealias Handler = @Sendable () async -> Bool

    static let shared = HealthBackgroundRefreshCoordinator()

    private var handler: Handler?
    private var pendingHandlerWaiters: [CheckedContinuation<Void, Never>] = []

    func register(_ handler: @escaping Handler) {
        self.handler = handler
        let waiters = pendingHandlerWaiters
        pendingHandlerWaiters.removeAll()
        guard !waiters.isEmpty else { return }
        Task {
            _ = await handler()
            waiters.forEach { $0.resume() }
        }
    }

    func receiveUpdate() async {
        guard let handler else {
            await withCheckedContinuation { continuation in
                pendingHandlerWaiters.append(continuation)
            }
            return
        }
        _ = await handler()
    }

    func dispatchIfRegistered() async -> Bool {
        guard let handler else { return false }
        return await handler()
    }
}

private final class HealthObserverCompletion: @unchecked Sendable {
    private let callback: () -> Void

    init(_ callback: @escaping () -> Void) {
        self.callback = callback
    }

    func callAsFunction() {
        callback()
    }
}

final class AppleHealthService: @unchecked Sendable {
    static let shared = AppleHealthService()

    private final class RouteLocationsAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [CLLocation] = []

        func append(_ locations: [CLLocation]) {
            lock.lock()
            values.append(contentsOf: locations)
            lock.unlock()
        }

        func snapshot() -> [CLLocation] {
            lock.lock()
            let result = values
            lock.unlock()
            return result
        }
    }

    private final class RouteLocationsReplyGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation:
            CheckedContinuation<[CLLocation], Never>?

        init(_ continuation: CheckedContinuation<[CLLocation], Never>) {
            self.continuation = continuation
        }

        func finish(_ value: [CLLocation]) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    private let store: HKHealthStore
    private let sleepEngine: SleepAnalysisEngine
    private let importCoordinator: HealthKitImportCoordinator
    private let observerLock = NSLock()
    private var observerQueries: [HKObserverQuery] = []
    private var pendingObservedTypeIdentifiers = Set<String>()
    private var lastBroadSynchronizationAt: Date?

    init(
        store: HKHealthStore = HKHealthStore(),
        sleepEngine: SleepAnalysisEngine = SleepAnalysisEngine(),
        importStore: HealthKitImportStore? = try? HealthKitImportStore()
    ) {
        self.store = store
        self.sleepEngine = sleepEngine
        self.importCoordinator = HealthKitImportCoordinator(
            healthStore: store,
            importStore: importStore
        )
    }

    func permissionState() -> PermissionState {
        HKHealthStore.isHealthDataAvailable() ? .notDetermined : .unavailable
    }

    func requestReadAccess() async throws -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let readTypes = Set(readTypes())
        let completed: Bool = try await withCheckedThrowingContinuation { continuation in
            store.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
        if completed {
            _ = try? await requestVisionPrescriptionReadAccess()
        }
        return completed
    }

    func startWatchWorkout(kind: TrackingKind) async throws -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = kind == .running ? .running : .walking
        configuration.locationType = .outdoor
        return try await withCheckedThrowingContinuation { continuation in
            store.startWatchApp(with: configuration) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    func startObservingChanges(
        onUpdate: @escaping @Sendable () async -> Void
    ) {
        observerLock.lock()
        guard observerQueries.isEmpty else {
            observerLock.unlock()
            return
        }
        let queries = observedSampleTypes().map { sampleType in
            let typeIdentifier = sampleType.identifier
            return HKObserverQuery(
                sampleType: sampleType,
                predicate: nil
            ) { [weak self] _, completion, error in
                let completion = HealthObserverCompletion(completion)
                Task {
                    if error == nil {
                        self?.markObservedChange(typeIdentifier)
                        await onUpdate()
                    }
                    completion()
                }
            }
        }
        observerQueries = queries
        observerLock.unlock()

        queries.forEach(store.execute)
    }

    func enableBackgroundDelivery() async throws {
        var successCount = 0
        var firstError: Error?
        for sampleType in observedSampleTypes() {
            do {
                try await setBackgroundDelivery(
                    enabled: true,
                    for: sampleType
                )
                successCount += 1
            } catch {
                firstError = firstError ?? error
            }
        }
        if successCount == 0, let firstError {
            throw firstError
        }
    }

    func disableBackgroundDelivery() async {
        for sampleType in observedSampleTypes() {
            try? await setBackgroundDelivery(
                enabled: false,
                for: sampleType
            )
        }
    }

    func authorizationRequestState() async throws -> PermissionState {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let readTypes = Set(readTypes())
        return try await withCheckedThrowingContinuation { continuation in
            store.getRequestStatusForAuthorization(
                toShare: [],
                read: readTypes
            ) { status, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                switch status {
                case .shouldRequest:
                    continuation.resume(returning: .notDetermined)
                case .unnecessary:
                    continuation.resume(returning: .authorized)
                case .unknown:
                    continuation.resume(returning: .notDetermined)
                @unknown default:
                    continuation.resume(returning: .unavailable)
                }
            }
        }
    }

    func actuals(in span: TimeSpan) async throws -> [ActualRecord] {
        async let workouts = workoutActuals(in: span)
        async let sleeps = sleepActuals(in: span)
        async let mindful = mindfulSessionActuals(in: span)
        return try await workouts + sleeps + mindful
    }

    func synchronizeFullHistory(
        progress: HealthKitImportCoordinator.ProgressHandler? = nil
    ) async throws -> HealthKitSyncOverview {
        let overview = try await importCoordinator.synchronizeFullHistory(
            progress: progress
        )
        setLastBroadSynchronizationAt(.now)
        return overview
    }

    func synchronizeChanges() async throws -> HealthKitSyncOverview {
        let firstScope = nextChangeSyncScope()
        var overview: HealthKitSyncOverview
        switch firstScope {
        case let .types(identifiers):
            overview = try await importCoordinator.synchronizeChanges(
                typeIdentifiers: identifiers
            )
        case .broad:
            do {
                overview = try await importCoordinator.synchronizeChanges()
            } catch {
                setLastBroadSynchronizationAt(nil)
                throw error
            }
        case .cached:
            overview = try await importCoordinator.overview()
        }
        while let identifiers = takePendingObservedTypeIdentifiers() {
            overview = try await importCoordinator.synchronizeChanges(
                typeIdentifiers: identifiers
            )
        }
        return overview
    }

    func importedActuals(in span: TimeSpan) async throws -> [ActualRecord] {
        let baselineSpan = TimeSpan(
            start: span.start.addingTimeInterval(-28 * 86_400),
            end: span.end
        )
        let records = try await importCoordinator.records(in: baselineSpan)
        return HealthKitBehaviorProjectionEngine.actuals(
            from: records,
            in: span
        )
    }

    func importOverview() async throws -> HealthKitSyncOverview {
        try await importCoordinator.overview()
    }

    func sleepSegments(in span: TimeSpan) async throws -> [SleepSegment] {
        guard let type = HKObjectType.categoryType(
            forIdentifier: .sleepAnalysis
        ) else {
            return []
        }
        let samples = try await samples(type: type, span: span)
        return samples.compactMap { sample in
            guard let category = sample as? HKCategorySample,
                  let healthStage = HKCategoryValueSleepAnalysis(
                    rawValue: category.value
                  ),
                  let stage = healthStage.taptionStage,
                  let overlap = TimeSpan(
                    start: category.startDate,
                    end: category.endDate
                  ).intersection(with: span) else {
                return nil
            }
            return SleepSegment(
                id: category.uuid,
                stage: stage,
                span: overlap,
                sourceName: category.sourceRevision.source.name,
                sourceBundleIdentifier: category.sourceRevision.source.bundleIdentifier,
                deviceName: category.device?.name,
                timeZoneIdentifier: category.metadata?[HKMetadataKeyTimeZone] as? String,
                isUserEntered: category.metadata?[HKMetadataKeyWasUserEntered] as? Bool ?? false
            )
        }
    }

    func sleepSessions(in span: TimeSpan) async throws -> [SleepSession] {
        sleepEngine.sessions(
            from: try await sleepSegments(in: span),
            inside: span
        )
    }

    func healthDetails(in span: TimeSpan) async throws -> [HealthActual] {
        async let workouts = workoutDetails(in: span)
        async let sleeps = sleepDetails(in: span)
        return try await workouts + sleeps
    }

    func movementEvidence(
        in span: TimeSpan
    ) async throws -> [AppleMovementEvidence] {
        async let workouts = workoutMovementEvidence(in: span)
        async let steps = stepMovementEvidence(in: span)
        return try await (workouts + steps)
            .sorted { $0.span.start < $1.span.start }
    }

    private func workoutActuals(in span: TimeSpan) async throws -> [ActualRecord] {
        try await workoutDetails(in: span).map { detail in
            ActualRecord(
                id: detail.id,
                planID: detail.linkedPlanID,
                title: detail.linkedTitle ?? detail.kind,
                categoryID: detail.linkedCategoryID ?? "exercise",
                startedAt: detail.span.start,
                endedAt: detail.span.end,
                source: detail.sourceName.localizedCaseInsensitiveContains("watch")
                    ? .appleWatch
                    : .healthKit,
                confidence: .high,
                behavior: WatchBehaviorKind.exercise.rawValue,
                evidence: [
                    AutomaticRecordTimelineEngine.healthWorkoutEvidence,
                    detail.sourceName,
                ],
                modelVersion: "healthkit-workout-v1"
            )
        }
    }

    private func sleepActuals(in span: TimeSpan) async throws -> [ActualRecord] {
        try await sleepSessions(in: span).map { session in
            let evidence = Array(
                Set(["HealthKit 수면 기록"] + session.sourceNames)
            ).sorted()
            return ActualRecord(
                id: session.id,
                planID: nil,
                title: "수면",
                categoryID: "sleep",
                startedAt: session.span.start,
                endedAt: session.span.end,
                source: session.isAppleWatchConfirmed ? .appleWatch : .healthKit,
                confidence: .high,
                evidence: evidence,
                modelVersion: "healthkit-sleep-v1"
            )
        }
    }

    private func mindfulSessionActuals(
        in span: TimeSpan
    ) async throws -> [ActualRecord] {
        guard let type = HKObjectType.categoryType(
            forIdentifier: .mindfulSession
        ) else {
            return []
        }
        let values = try await samples(type: type, span: span)
        return values.compactMap { sample in
            guard let overlap = TimeSpan(
                start: sample.startDate,
                end: sample.endDate
            ).intersection(with: span) else {
                return nil
            }
            return ActualRecord(
                id: sample.uuid,
                planID: nil,
                title: "마음챙김",
                categoryID: "health",
                startedAt: overlap.start,
                endedAt: overlap.end,
                source: .healthKit,
                confidence: .high
            )
        }
    }

    private func workoutDetails(in span: TimeSpan) async throws -> [HealthActual] {
        let type = HKObjectType.workoutType()
        let samples = try await samples(type: type, span: span)
        return samples.compactMap { sample in
            guard let workout = sample as? HKWorkout else { return nil }
            let distanceType = HKQuantityType.quantityType(
                forIdentifier: workout.workoutActivityType == .cycling
                    ? .distanceCycling
                    : .distanceWalkingRunning
            )
            let energyType = HKQuantityType.quantityType(
                forIdentifier: .activeEnergyBurned
            )
            let taptionID = (workout.metadata?[
                TaptionWatchHealthMetadata.sensorSessionID
            ] as? String).flatMap(UUID.init(uuidString:))
                ?? workout.uuid
            return HealthActual(
                id: taptionID,
                kind: workout.workoutActivityType.displayName,
                span: TimeSpan(start: workout.startDate, end: workout.endDate),
                duration: workout.duration,
                distanceMeters: distanceType
                    .flatMap { workout.statistics(for: $0)?.sumQuantity() }
                    .map { $0.doubleValue(for: .meter()) },
                energyKilocalories: energyType
                    .flatMap { workout.statistics(for: $0)?.sumQuantity() }
                    .map { $0.doubleValue(for: .kilocalorie()) },
                sourceName: workout.sourceRevision.source.name,
                linkedPlanID: (workout.metadata?[
                    TaptionWatchHealthMetadata.planID
                ] as? String).flatMap(UUID.init(uuidString:)),
                linkedTitle: workout.metadata?[
                    TaptionWatchHealthMetadata.planTitle
                ] as? String,
                linkedCategoryID: workout.metadata?[
                    TaptionWatchHealthMetadata.categoryID
                ] as? String
            )
        }
    }

    /// 다른 앱과 Apple Watch가 HealthKit에 저장한 운동 경로를 읽어
    /// 표본으로 되돌린다. 우리 앱이 듀티사이클 때문에 남기지 못한 구간의
    /// 실제 궤적을 사후에 채우는 유일한 정식 경로다.
    func workoutRouteReadings(
        in span: TimeSpan
    ) async throws -> [SensorReading] {
        let workouts = try await samples(
            type: HKObjectType.workoutType(),
            span: span
        ).compactMap { $0 as? HKWorkout }
        guard !workouts.isEmpty else { return [] }

        var result: [SensorReading] = []
        for workout in workouts {
            let mode = workout.workoutActivityType.movementTravelMode
            for route in try await routeSamples(for: workout) {
                let locations = try await locations(in: route)
                for location in locations
                where location.horizontalAccuracy >= 0
                    && span.contains(location.timestamp) {
                    result.append(
                        SensorReading(
                            timestamp: location.timestamp,
                            point: GeoPoint(
                                latitude: location.coordinate.latitude,
                                longitude: location.coordinate.longitude,
                                altitude: location.altitude,
                                horizontalAccuracy: location.horizontalAccuracy,
                                verticalAccuracy: location.verticalAccuracy
                            ),
                            speedMetersPerSecond: location.speed >= 0
                                ? location.speed
                                : nil,
                            courseDegrees: location.course >= 0
                                ? location.course
                                : nil,
                            motion: Self.motionKind(for: mode),
                            motionConfidence: .high
                        )
                    )
                }
            }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    private static func motionKind(for mode: TravelMode?) -> MotionKind {
        switch mode {
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        case .car, .bus, .taxi, .subway, .train: .automotive
        default: .unknown
        }
    }

    private func routeSamples(
        for workout: HKWorkout
    ) async throws -> [HKWorkoutRoute] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: HKQuery.predicateForObjects(from: workout),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if error != nil {
                    // 권한이 없거나 경로가 없는 운동은 조용히 건너뛴다.
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(
                    returning: (samples as? [HKWorkoutRoute]) ?? []
                )
            }
            store.execute(query)
        }
    }

    private func locations(
        in route: HKWorkoutRoute
    ) async throws -> [CLLocation] {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<[CLLocation], Never>) in
            let collected = RouteLocationsAccumulator()
            let gate = RouteLocationsReplyGate(continuation)
            let query = HKWorkoutRouteQuery(
                route: route
            ) { _, locations, done, error in
                if error != nil {
                    gate.finish([])
                    return
                }
                collected.append(locations ?? [])
                if done {
                    gate.finish(collected.snapshot())
                }
            }
            store.execute(query)
        }
    }

    private func workoutMovementEvidence(
        in span: TimeSpan
    ) async throws -> [AppleMovementEvidence] {
        let samples = try await samples(
            type: HKObjectType.workoutType(),
            span: span
        )
        return samples.compactMap { sample in
            guard let workout = sample as? HKWorkout,
                  let mode = workout.workoutActivityType.movementTravelMode,
                  let overlap = TimeSpan(
                    start: workout.startDate,
                    end: workout.endDate
                  ).intersection(with: span) else {
                return nil
            }
            let overlapFraction = min(
                1,
                overlap.duration / max(1, workout.duration)
            )
            let distanceType = HKQuantityType.quantityType(
                forIdentifier: workout.workoutActivityType == .cycling
                    ? .distanceCycling
                    : .distanceWalkingRunning
            )
            return AppleMovementEvidence(
                id: (workout.metadata?[
                    TaptionWatchHealthMetadata.sensorSessionID
                ] as? String).flatMap(UUID.init(uuidString:))
                    ?? workout.uuid,
                span: overlap,
                source: Self.movementSource(for: workout),
                kind: .workout,
                workoutMode: mode,
                distanceMeters: distanceType
                    .flatMap { workout.statistics(for: $0)?.sumQuantity() }
                    .map {
                        $0.doubleValue(for: .meter()) * overlapFraction
                    },
                sourceName: workout.sourceRevision.source.name,
                deviceName: Self.deviceName(for: workout)
            )
        }
    }

    private func stepMovementEvidence(
        in span: TimeSpan
    ) async throws -> [AppleMovementEvidence] {
        guard let type = HKObjectType.quantityType(
            forIdentifier: .stepCount
        ) else {
            return []
        }
        let samples = try await samples(type: type, span: span)
        return samples.compactMap { sample in
            guard let quantity = sample as? HKQuantitySample else {
                return nil
            }
            let originalSpan = TimeSpan(
                start: quantity.startDate,
                end: quantity.endDate
            )
            guard let overlap = originalSpan.intersection(with: span) else {
                return nil
            }
            let overlapFraction = min(
                1,
                overlap.duration / max(1, originalSpan.duration)
            )
            let steps = Int(
                (
                    quantity.quantity.doubleValue(for: .count())
                        * overlapFraction
                ).rounded()
            )
            guard steps > 0 else { return nil }
            return AppleMovementEvidence(
                id: quantity.uuid,
                span: overlap,
                source: Self.movementSource(for: quantity),
                kind: .steps,
                stepCount: steps,
                sourceName: quantity.sourceRevision.source.name,
                deviceName: Self.deviceName(for: quantity)
            )
        }
    }

    private static func movementSource(
        for sample: HKSample
    ) -> AppleMovementEvidenceSource {
        let signature = [
            sample.device?.name,
            sample.device?.model,
            sample.sourceRevision.productType,
            sample.sourceRevision.source.name,
        ]
        .compactMap { $0?.localizedLowercase }
        .joined(separator: " ")
        if signature.contains("watch") {
            return .appleWatch
        }
        if signature.contains("iphone") {
            return .iPhone
        }
        return .other
    }

    private static func deviceName(for sample: HKSample) -> String? {
        sample.device?.name
            ?? sample.device?.model
            ?? sample.sourceRevision.productType
    }

    private func sleepDetails(in span: TimeSpan) async throws -> [HealthActual] {
        try await sleepSessions(in: span).map { session in
            return HealthActual(
                id: session.id,
                kind: "수면",
                span: session.span,
                duration: session.asleepDuration,
                distanceMeters: nil,
                energyKilocalories: nil,
                sourceName: session.sourceNames.joined(separator: ", ")
            )
        }
    }

    private func samples(
        type: HKSampleType,
        span: TimeSpan
    ) async throws -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(
            withStart: span.start,
            end: span.end,
            options: []
        )
        let sort = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate,
            ascending: true
        )
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }

    private func readTypes() -> [HKObjectType] {
        HealthKitTypeCatalog.standardAuthorizationObjectTypes().filter { type in
            guard let descriptor = HealthKitTypeCatalog.descriptor(
                for: type.identifier
            ) else {
                return false
            }
            return !descriptor.isClinical || store.supportsHealthRecords()
        }
    }

    private func requestVisionPrescriptionReadAccess() async throws -> Bool {
        let type = HKObjectType.visionPrescriptionType()
        return try await withCheckedThrowingContinuation { continuation in
            store.requestPerObjectReadAuthorization(
                for: type,
                predicate: nil
            ) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    private func observedSampleTypes() -> [HKSampleType] {
        HealthKitTypeCatalog.observableDescriptors.filter { descriptor in
            descriptor.backgroundEligible
                && (!descriptor.isClinical
                    || store.supportsHealthRecords())
        }.compactMap(HealthKitTypeCatalog.observableSampleType(for:))
    }

    private enum ChangeSyncScope {
        case types(Set<String>)
        case broad
        case cached
    }

    private func markObservedChange(_ typeIdentifier: String) {
        observerLock.lock()
        pendingObservedTypeIdentifiers.insert(typeIdentifier)
        observerLock.unlock()
    }

    private func setLastBroadSynchronizationAt(_ date: Date?) {
        observerLock.lock()
        lastBroadSynchronizationAt = date
        observerLock.unlock()
    }

    private func nextChangeSyncScope(now: Date = .now) -> ChangeSyncScope {
        observerLock.lock()
        defer { observerLock.unlock() }
        if !pendingObservedTypeIdentifiers.isEmpty {
            let identifiers = pendingObservedTypeIdentifiers
            pendingObservedTypeIdentifiers.removeAll()
            return .types(identifiers)
        }
        if let lastBroadSynchronizationAt,
           now.timeIntervalSince(lastBroadSynchronizationAt)
                < HealthRefreshPolicy.broadRawSyncInterval {
            return .cached
        }
        lastBroadSynchronizationAt = now
        return .broad
    }

    private func takePendingObservedTypeIdentifiers() -> Set<String>? {
        observerLock.lock()
        defer { observerLock.unlock() }
        guard !pendingObservedTypeIdentifiers.isEmpty else { return nil }
        let identifiers = pendingObservedTypeIdentifiers
        pendingObservedTypeIdentifiers.removeAll()
        return identifiers
    }

    private func setBackgroundDelivery(
        enabled: Bool,
        for sampleType: HKObjectType
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let completion: @Sendable (Bool, Error?) -> Void = {
                success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(
                        throwing: HealthBackgroundDeliveryError.registrationFailed
                    )
                }
            }
            if enabled {
                store.enableBackgroundDelivery(
                    for: sampleType,
                    frequency: HealthRefreshPolicy.backgroundFrequency,
                    withCompletion: completion
                )
            } else {
                store.disableBackgroundDelivery(
                    for: sampleType,
                    withCompletion: completion
                )
            }
        }
    }
}

private enum HealthBackgroundDeliveryError: LocalizedError {
    case registrationFailed

    var errorDescription: String? {
        "HealthKit 백그라운드 전달을 등록하지 못했습니다."
    }
}

private extension HKCategoryValueSleepAnalysis {
    var taptionStage: SleepStage? {
        switch self {
        case .inBed: .inBed
        case .awake: .awake
        case .asleepCore: .core
        case .asleepDeep: .deep
        case .asleepREM: .rem
        case .asleepUnspecified: .asleepUnspecified
        case .asleep: .asleepUnspecified
        @unknown default: nil
        }
    }
}

private extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .americanFootball: "미식축구"
        case .archery: "양궁"
        case .australianFootball: "호주식 축구"
        case .badminton: "배드민턴"
        case .baseball: "야구"
        case .basketball: "농구"
        case .bowling: "볼링"
        case .boxing: "복싱"
        case .climbing: "클라이밍"
        case .cricket: "크리켓"
        case .crossTraining: "크로스 트레이닝"
        case .curling: "컬링"
        case .running: "러닝"
        case .walking: "걷기"
        case .cycling: "자전거"
        case .danceInspiredTraining: "댄스 트레이닝"
        case .dance: "댄스"
        case .equestrianSports: "승마"
        case .fencing: "펜싱"
        case .fishing: "낚시"
        case .golf: "골프"
        case .gymnastics: "체조"
        case .handball: "핸드볼"
        case .hockey: "하키"
        case .hunting: "사냥"
        case .lacrosse: "라크로스"
        case .martialArts: "무술"
        case .paddleSports: "패들 스포츠"
        case .play: "놀이"
        case .racquetball: "라켓볼"
        case .rugby: "럭비"
        case .sailing: "요트"
        case .skatingSports: "스케이트"
        case .snowSports: "설상 스포츠"
        case .soccer: "축구"
        case .softball: "소프트볼"
        case .squash: "스쿼시"
        case .surfingSports: "서핑"
        case .swimming: "수영"
        case .tableTennis: "탁구"
        case .tennis: "테니스"
        case .trackAndField: "육상"
        case .volleyball: "배구"
        case .waterFitness: "수중 피트니스"
        case .waterPolo: "수구"
        case .waterSports: "수상 스포츠"
        case .wrestling: "레슬링"
        case .mindAndBody: "마음챙김"
        case .mixedMetabolicCardioTraining: "복합 유산소"
        case .preparationAndRecovery: "회복 운동"
        case .elliptical: "일립티컬"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "근력운동"
        case .hiking: "하이킹"
        case .rowing: "로잉"
        case .highIntensityIntervalTraining: "HIIT"
        case .yoga: "요가"
        case .pilates: "필라테스"
        case .barre: "바레"
        case .coreTraining: "코어 운동"
        case .flexibility: "유연성 운동"
        case .crossCountrySkiing: "크로스컨트리 스키"
        case .downhillSkiing: "알파인 스키"
        case .jumpRope: "줄넘기"
        case .kickboxing: "킥복싱"
        case .snowboarding: "스노보드"
        case .stairs, .stairClimbing: "계단 오르기"
        case .stepTraining: "스텝 운동"
        case .wheelchairWalkPace: "휠체어 걷기"
        case .wheelchairRunPace: "휠체어 달리기"
        case .taiChi: "태극권"
        case .mixedCardio: "유산소 운동"
        case .handCycling: "핸드 사이클"
        case .discSports: "디스크 스포츠"
        case .fitnessGaming: "피트니스 게임"
        case .cardioDance: "카디오 댄스"
        case .socialDance: "소셜 댄스"
        case .pickleball: "피클볼"
        case .cooldown: "쿨다운"
        case .swimBikeRun: "수영·자전거·달리기"
        case .transition: "트라이애슬론 전환"
        case .underwaterDiving: "스쿠버 다이빙"
        case .other: "기타 운동"
        default: "운동"
        }
    }

    var movementTravelMode: TravelMode? {
        switch self {
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        default: nil
        }
    }
}

// MARK: - Weather

actor AppleWeatherContextService {
    private let service = WeatherKit.WeatherService.shared
    private let fallbackService: OpenMeteoWeatherContextService
    private var cachedContext: CachedWeatherContext?
    private var appleAuthenticationRetryAfter: Date?

    init(
        fallbackService: OpenMeteoWeatherContextService =
            OpenMeteoWeatherContextService()
    ) {
        self.fallbackService = fallbackService
    }

    func context(
        latitude: Double,
        longitude: Double,
        at date: Date = .now
    ) async throws -> WeatherContext {
        let point = CLLocation(latitude: latitude, longitude: longitude)
        if let cachedContext,
           cachedContext.isReusable(for: point, at: date) {
            // Keep the cached observation usable while the app is receiving
            // frequent workout locations.  Refreshing the observation time
            // prevents the UI from dropping an otherwise valid context just
            // because the provider was not queried again yet.
            var context = cachedContext.context
            context.observedAt = date
            context.isStale = false
            self.cachedContext = CachedWeatherContext(
                location: cachedContext.location,
                context: context
            )
            return context
        }

        if appleAuthenticationRetryAfter.map({ date >= $0 }) ?? true {
            do {
                let context = try await appleContext(
                    at: point,
                    observedAt: date
                )
                cachedContext = CachedWeatherContext(
                    location: point,
                    context: context
                )
                appleAuthenticationRetryAfter = nil
                return context
            } catch {
                if Self.isWeatherKitAuthenticationFailure(error) {
                    appleAuthenticationRetryAfter = date.addingTimeInterval(
                        6 * 60 * 60
                    )
                }
            }
        }

        do {
            let context = try await fallbackService.context(
                latitude: latitude,
                longitude: longitude,
                at: date
            )
            cachedContext = CachedWeatherContext(
                location: point,
                context: context
            )
            return context
        } catch {
            // A short network interruption should not erase the last usable
            // weather during an active workout. Keep the cached observation
            // as a graceful stale fallback and let the next refresh retry.
            if let cachedContext {
                var context = cachedContext.context
                context.observedAt = date
                context.isStale = true
                self.cachedContext = CachedWeatherContext(
                    location: cachedContext.location,
                    context: context
                )
                return context
            }
            throw WeatherContextServiceError.temporarilyUnavailable
        }
    }

    func hourlyContexts(
        latitude: Double,
        longitude: Double,
        from start: Date,
        through end: Date
    ) async throws -> [WeatherContext] {
        let point = CLLocation(latitude: latitude, longitude: longitude)
        let now = Date.now
        var contexts: [WeatherContext] = []

        if start < now {
            let historicalEnd = min(end, now)
            if start < historicalEnd {
                do {
                    let historical = try await service.weather(
                        for: point,
                        including: .hourly(
                            startDate: start,
                            endDate: historicalEnd
                        )
                    )
                    contexts.append(contentsOf: historical.map(Self.weatherContext))
                } catch {
                    // Preserve stored observations when historical WeatherKit
                    // data is unavailable for this location.
                }
            }
        }

        if end > now {
            let forecastStart = max(start, now)
            if forecastStart < end {
                do {
                    let forecast = try await service.weather(
                        for: point,
                        including: .hourly(
                            startDate: forecastStart,
                            endDate: end
                        )
                    )
                    contexts.append(contentsOf: forecast.map(Self.weatherContext))
                } catch {
                    // Fall through to the existing provider fallback below.
                }
            }
        }

        if !contexts.isEmpty {
            return contexts
        }

        do {
            let hourly = try await service.weather(
                for: point,
                including: .hourly
            )
            let values = hourly.forecast.filter {
                $0.date >= start && $0.date < end
            }
            guard !values.isEmpty else {
                throw WeatherContextServiceError.temporarilyUnavailable
            }
            return values.map(Self.weatherContext)
        } catch {
            return try await fallbackService.hourlyContexts(
                latitude: latitude,
                longitude: longitude,
                from: start,
                through: end
            )
        }
    }

    private static func weatherContext(
        _ value: WeatherKit.HourWeather
    ) -> WeatherContext {
        WeatherContext(
            observedAt: value.date,
            fetchedAt: .now,
            isStale: false,
            condition: String(describing: value.condition),
            symbolName: value.symbolName,
            temperatureCelsius: value.temperature.converted(to: .celsius).value,
            precipitationChance: value.precipitationChance,
            isContextOnly: true
        )
    }

    private func appleContext(
        at location: CLLocation,
        observedAt date: Date
    ) async throws -> WeatherContext {
        let (current, hourly) = try await service.weather(
            for: location,
            including: .current,
            .hourly
        )
        let closestHour = hourly.forecast.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
        return WeatherContext(
            observedAt: date,
            fetchedAt: date,
            isStale: false,
            condition: String(describing: current.condition),
            symbolName: current.symbolName,
            temperatureCelsius: current.temperature.converted(to: .celsius).value,
            precipitationChance: closestHour?.precipitationChance
        )
    }

    private static func isWeatherKitAuthenticationFailure(
        _ error: Error
    ) -> Bool {
        let nsError = error as NSError
        if nsError.domain.contains(
            "WDSJWTAuthenticatorServiceListener.Errors"
        ), nsError.code == 2 {
            return true
        }
        if let underlying = nsError.userInfo[
            NSUnderlyingErrorKey
        ] as? Error {
            return isWeatherKitAuthenticationFailure(underlying)
        }
        return false
    }
}

private struct CachedWeatherContext {
    let location: CLLocation
    let context: WeatherContext

    func isReusable(
        for newLocation: CLLocation,
        at date: Date
    ) -> Bool {
        context.isStale != true
            && abs(
                date.timeIntervalSince(
                    context.fetchedAt ?? context.observedAt
                )
            ) < 10 * 60
            && newLocation.distance(from: location) < 1_000
    }
}

enum WeatherContextServiceError: LocalizedError {
    case temporarilyUnavailable

    var errorDescription: String? {
        "날씨 서비스에 잠시 연결할 수 없습니다. 잠시 후 다시 시도해 주세요."
    }
}

actor OpenMeteoWeatherContextService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func context(
        latitude: Double,
        longitude: Double,
        at date: Date = .now
    ) async throws -> WeatherContext {
        var components = URLComponents(
            string: "https://api.open-meteo.com/v1/forecast"
        )
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(
                name: "current",
                value:
                    "temperature_2m,weather_code,"
                    + "precipitation_probability,is_day"
            ),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        guard let url = components?.url else {
            throw OpenMeteoWeatherError.invalidRequest
        }

        var lastError: Error?
        for attempt in 0..<2 {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 12
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode) else {
                    throw OpenMeteoWeatherError.invalidResponse
                }
                let payload = try JSONDecoder().decode(
                    OpenMeteoWeatherResponse.self,
                    from: data
                )
                let presentation = OpenMeteoWeatherCodePresentation(
                    code: payload.current.weatherCode,
                    isDay: payload.current.isDay != 0
                )
                return WeatherContext(
                    observedAt: date,
                    fetchedAt: date,
                    isStale: false,
                    condition: presentation.condition,
                    symbolName: presentation.symbolName,
                    temperatureCelsius: payload.current.temperatureCelsius,
                    precipitationChance:
                        payload.current.precipitationProbability.map {
                            $0 / 100
                        }
                )
            } catch {
                lastError = error
                if attempt == 0 {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        throw lastError ?? OpenMeteoWeatherError.invalidResponse
    }

    func hourlyContexts(
        latitude: Double,
        longitude: Double,
        from start: Date,
        through end: Date
    ) async throws -> [WeatherContext] {
        var components = URLComponents(
            string: "https://api.open-meteo.com/v1/forecast"
        )
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(
                name: "hourly",
                value: "temperature_2m,weather_code,precipitation_probability,is_day"
            ),
            URLQueryItem(
                name: "current",
                value: "temperature_2m,weather_code,precipitation_probability,is_day"
            ),
            URLQueryItem(
                name: "timezone",
                value: TimeZone.autoupdatingCurrent.identifier
            ),
            URLQueryItem(name: "forecast_days", value: "2"),
        ]
        guard let url = components?.url else {
            throw OpenMeteoWeatherError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw OpenMeteoWeatherError.invalidResponse
        }
        let payload = try JSONDecoder().decode(
            OpenMeteoWeatherResponse.self,
            from: data
        )
        guard let hourly = payload.hourly else {
            throw OpenMeteoWeatherError.invalidResponse
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let fetchedAt = Date.now
        return zip(hourly.time, zip(hourly.temperatureCelsius, zip(hourly.weatherCode, zip(hourly.precipitationProbability, hourly.isDay))))
            .compactMap { value -> WeatherContext? in
                guard let observedAt = formatter.date(from: value.0),
                      observedAt >= start,
                      observedAt < end else { return nil }
                let presentation = OpenMeteoWeatherCodePresentation(
                    code: value.1.1.0,
                    isDay: value.1.1.1.1 != 0
                )
                return WeatherContext(
                    observedAt: observedAt,
                    fetchedAt: fetchedAt,
                    isStale: false,
                    condition: presentation.condition,
                    symbolName: presentation.symbolName,
                    temperatureCelsius: value.1.0,
                    precipitationChance: value.1.1.1.0.map { $0 / 100 }
                )
            }
    }
}

private enum OpenMeteoWeatherError: Error {
    case invalidRequest
    case invalidResponse
}

private struct OpenMeteoWeatherResponse: Decodable {
    struct Current: Decodable {
        let temperatureCelsius: Double
        let weatherCode: Int
        let precipitationProbability: Double?
        let isDay: Int

        enum CodingKeys: String, CodingKey {
            case temperatureCelsius = "temperature_2m"
            case weatherCode = "weather_code"
            case precipitationProbability = "precipitation_probability"
            case isDay = "is_day"
        }
    }

    let current: Current
    let hourly: Hourly?

    struct Hourly: Decodable {
        let time: [String]
        let temperatureCelsius: [Double]
        let weatherCode: [Int]
        let precipitationProbability: [Double?]
        let isDay: [Int]

        enum CodingKeys: String, CodingKey {
            case time
            case temperatureCelsius = "temperature_2m"
            case weatherCode = "weather_code"
            case precipitationProbability = "precipitation_probability"
            case isDay = "is_day"
        }
    }
}

struct OpenMeteoWeatherCodePresentation: Equatable {
    let condition: String
    let symbolName: String

    init(code: Int, isDay: Bool) {
        switch code {
        case 0:
            condition = "맑음"
            symbolName = isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1:
            condition = "대체로 맑음"
            symbolName = isDay ? "sun.min.fill" : "moon.fill"
        case 2:
            condition = "구름 조금"
            symbolName = isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3:
            condition = "흐림"
            symbolName = "cloud.fill"
        case 45, 48:
            condition = "안개"
            symbolName = "cloud.fog.fill"
        case 51, 53, 55:
            condition = "이슬비"
            symbolName = "cloud.drizzle.fill"
        case 56, 57, 66, 67:
            condition = "진눈깨비"
            symbolName = "cloud.sleet.fill"
        case 61, 63:
            condition = "비"
            symbolName = "cloud.rain.fill"
        case 65, 80, 81, 82:
            condition = "강한 비"
            symbolName = "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86:
            condition = "눈"
            symbolName = "cloud.snow.fill"
        case 95, 96, 99:
            condition = "뇌우"
            symbolName = "cloud.bolt.rain.fill"
        default:
            condition = "날씨 정보"
            symbolName = "cloud.fill"
        }
    }
}

actor AirQualityContextService {
    private struct CachedContext {
        var location: CLLocation
        var context: AirQualityContext
    }

    private let session: URLSession
    private let serviceKey: String?
    private var stations: [AirKoreaStation] = []
    private var stationsLoadedAt: Date?
    private var cachedContext: CachedContext?

    init(
        session: URLSession = .shared,
        serviceKey: String? = AirQualityContextService.configuredServiceKey()
    ) {
        self.session = session
        self.serviceKey = serviceKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func context(
        latitude: Double,
        longitude: Double,
        at date: Date = .now
    ) async throws -> AirQualityContext {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        if let cachedContext,
           date.timeIntervalSince(cachedContext.context.observedAt) < 30 * 60,
           location.distance(from: cachedContext.location) < 3_000 {
            return cachedContext.context
        }

        if isInSouthKorea(latitude: latitude, longitude: longitude),
           let key = serviceKey,
           !key.isEmpty,
           let context = try? await airKoreaContext(
                latitude: latitude,
                longitude: longitude,
                serviceKey: key,
                at: date
           ) {
            cachedContext = CachedContext(location: location, context: context)
            return context
        }

        let context = try await openMeteoContext(
            latitude: latitude,
            longitude: longitude,
            at: date
        )
        cachedContext = CachedContext(location: location, context: context)
        return context
    }

    static func configuredServiceKey() -> String? {
        if let environment = ProcessInfo.processInfo.environment[
            "AIRKOREA_SERVICE_KEY"
        ], !environment.isEmpty {
            return environment
        }
        guard let bundled = Bundle.main.object(
            forInfoDictionaryKey: "AIRKOREA_SERVICE_KEY"
        ) as? String,
        !bundled.isEmpty,
        !bundled.hasPrefix("$(") else {
            return nil
        }
        return bundled
    }

    private func airKoreaContext(
        latitude: Double,
        longitude: Double,
        serviceKey: String,
        at date: Date
    ) async throws -> AirQualityContext {
        if stations.isEmpty
            || stationsLoadedAt.map({ date.timeIntervalSince($0) > 30 * 86_400 }) == true {
            stations = try await loadStations(serviceKey: serviceKey)
            stationsLoadedAt = date
        }
        let origin = CLLocation(latitude: latitude, longitude: longitude)
        guard let station = stations.min(by: {
            origin.distance(from: $0.location)
                < origin.distance(from: $1.location)
        }) else {
            throw AirQualityServiceError.noStation
        }

        var components = URLComponents(
            string: "https://apis.data.go.kr/B552584/ArpltnInforInqireSvc/getMsrstnAcctoRltmMesureDnsty"
        )
        components?.queryItems = [
            URLQueryItem(name: "serviceKey", value: serviceKey),
            URLQueryItem(name: "returnType", value: "json"),
            URLQueryItem(name: "numOfRows", value: "1"),
            URLQueryItem(name: "pageNo", value: "1"),
            URLQueryItem(name: "stationName", value: station.name),
            URLQueryItem(name: "dataTerm", value: "DAILY"),
            URLQueryItem(name: "ver", value: "1.3"),
        ]
        guard let url = components?.url else {
            throw AirQualityServiceError.invalidRequest
        }
        let payload: AirKoreaEnvelope<AirKoreaMeasurement> = try await fetch(url)
        guard let item = payload.response.body.items.first,
              let pm10 = Double(item.pm10Value),
              let pm25 = Double(item.pm25Value) else {
            throw AirQualityServiceError.invalidResponse
        }
        return AirQualityContext(
            pm10MicrogramsPerCubicMeter: pm10,
            pm25MicrogramsPerCubicMeter: pm25,
            observedAt: AirKoreaDateParser.date(item.dataTime) ?? date,
            stationName: station.name,
            providerName: "에어코리아",
            isFallback: false
        )
    }

    private func loadStations(serviceKey: String) async throws -> [AirKoreaStation] {
        var components = URLComponents(
            string: "https://apis.data.go.kr/B552584/MsrstnInfoInqireSvc/getMsrstnList"
        )
        components?.queryItems = [
            URLQueryItem(name: "serviceKey", value: serviceKey),
            URLQueryItem(name: "returnType", value: "json"),
            URLQueryItem(name: "numOfRows", value: "1000"),
            URLQueryItem(name: "pageNo", value: "1"),
        ]
        guard let url = components?.url else {
            throw AirQualityServiceError.invalidRequest
        }
        let payload: AirKoreaEnvelope<AirKoreaStationPayload> = try await fetch(url)
        return payload.response.body.items.compactMap { item in
            guard let latitude = Double(item.dmX),
                  let longitude = Double(item.dmY) else { return nil }
            return AirKoreaStation(
                name: item.stationName,
                latitude: latitude,
                longitude: longitude
            )
        }
    }

    private func openMeteoContext(
        latitude: Double,
        longitude: Double,
        at date: Date
    ) async throws -> AirQualityContext {
        var components = URLComponents(
            string: "https://air-quality-api.open-meteo.com/v1/air-quality"
        )
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "pm10,pm2_5"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = components?.url else {
            throw AirQualityServiceError.invalidRequest
        }
        let payload: OpenMeteoAirQualityResponse = try await fetch(url)
        return AirQualityContext(
            pm10MicrogramsPerCubicMeter: payload.current.pm10,
            pm25MicrogramsPerCubicMeter: payload.current.pm25,
            observedAt: date,
            providerName: "Open-Meteo",
            isFallback: true
        )
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw AirQualityServiceError.invalidResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func isInSouthKorea(latitude: Double, longitude: Double) -> Bool {
        (32...39.5).contains(latitude) && (124...132).contains(longitude)
    }
}

private enum AirQualityServiceError: Error {
    case invalidRequest
    case invalidResponse
    case noStation
}

private struct AirKoreaEnvelope<Item: Decodable>: Decodable {
    struct Response: Decodable {
        struct Body: Decodable {
            var items: [Item]
        }
        var body: Body
    }
    var response: Response
}

private struct AirKoreaStationPayload: Decodable {
    var stationName: String
    var dmX: String
    var dmY: String
}

private struct AirKoreaStation {
    var name: String
    var latitude: Double
    var longitude: Double

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

private struct AirKoreaMeasurement: Decodable {
    var dataTime: String
    var pm10Value: String
    var pm25Value: String
}

private enum AirKoreaDateParser {
    static func date(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: value)
    }
}

private struct OpenMeteoAirQualityResponse: Decodable {
    struct Current: Decodable {
        var pm10: Double
        var pm25: Double

        enum CodingKeys: String, CodingKey {
            case pm10
            case pm25 = "pm2_5"
        }
    }
    var current: Current
}

// MARK: - AirPods playback and call observations

enum AirPodsActivityKind: Sendable {
    case music
    case call
}

struct AirPodsActivityObservation: Equatable, Sendable {
    var id: UUID
    var kind: AirPodsActivityKind
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var routeName: String
}

/// Observes only short-lived, device-local activity. iOS does not expose a
/// call-history API, so call records are created while CallKit reports an
/// active call and an AirPods route is connected.
final class AirPodsActivityService: NSObject, CXCallObserverDelegate, @unchecked Sendable {
    private let callObserver = CXCallObserver()
    private var routeObservers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var handler: (@MainActor @Sendable (AirPodsActivityObservation) -> Void)?
    private var musicObservation: AirPodsActivityObservation?
    private var callObservation: AirPodsActivityObservation?
    private var activeCallID: UUID?
    private var isStarted = false

    deinit {
        stopObservers()
    }

    func start(
        onObservation: @escaping @MainActor @Sendable (AirPodsActivityObservation) -> Void
    ) {
        handler = onObservation
        guard !isStarted else {
            refresh()
            return
        }
        isStarted = true
        callObserver.setDelegate(self, queue: .main)
        let center = NotificationCenter.default
        routeObservers = [
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            },
            center.addObserver(
                forName: .MPMusicPlayerControllerPlaybackStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            },
            center.addObserver(
                forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            },
        ]
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: 15,
            repeats: true
        ) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    @discardableResult
    func stop(at date: Date = .now) -> [AirPodsActivityObservation] {
        let finished: [AirPodsActivityObservation] = [
            musicObservation,
            callObservation,
        ].compactMap { observation in
            guard let observation, observation.endedAt == nil else { return nil }
            var value = observation
            value.endedAt = max(observation.startedAt, date)
            return value
        }
        musicObservation = nil
        callObservation = nil
        activeCallID = nil
        stopObservers()
        return finished
    }

    func callObserver(
        _ callObserver: CXCallObserver,
        callChanged call: CXCall
    ) {
        refresh()
    }

    private func refresh(at date: Date = .now) {
        guard isStarted else { return }
        let output = AVAudioSession.sharedInstance().currentRoute.outputs
            .first(where: Self.isAirPodsOutput)
        guard let output else {
            finish(&musicObservation, at: date)
            finish(&callObservation, at: date)
            activeCallID = nil
            return
        }

        let routeName = output.portName
        let nowPlaying = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let playbackRate = (nowPlaying?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue ?? 0
        let isPlaying = playbackRate > 0
            || MPMusicPlayerController.systemMusicPlayer.playbackState == .playing
        if isPlaying {
            let title = Self.nowPlayingTitle(from: nowPlaying)
            if musicObservation?.title != title
                || musicObservation?.routeName != routeName {
                finish(&musicObservation, at: date)
                musicObservation = AirPodsActivityObservation(
                    id: UUID(),
                    kind: .music,
                    title: title,
                    startedAt: date,
                    endedAt: nil,
                    routeName: routeName
                )
                emit(musicObservation)
            }
        } else {
            finish(&musicObservation, at: date)
        }

        let activeCall = callObserver.calls.first { !$0.hasEnded }
        if let activeCall, activeCallID != activeCall.uuid {
            finish(&callObservation, at: date)
            activeCallID = activeCall.uuid
            callObservation = AirPodsActivityObservation(
                id: UUID(),
                kind: .call,
                title: "통화",
                startedAt: date,
                endedAt: nil,
                routeName: routeName
            )
            emit(callObservation)
        } else if activeCall == nil {
            finish(&callObservation, at: date)
            activeCallID = nil
        }
    }

    private func finish(
        _ observation: inout AirPodsActivityObservation?,
        at date: Date
    ) {
        guard let current = observation, current.endedAt == nil else {
            return
        }
        var value = current
        value.endedAt = max(current.startedAt, date)
        emit(value)
        observation = nil
    }

    private func emit(_ observation: AirPodsActivityObservation?) {
        guard let observation, let handler else { return }
        Task { @MainActor in
            handler(observation)
        }
    }

    private func stopObservers() {
        pollTimer?.invalidate()
        pollTimer = nil
        let center = NotificationCenter.default
        routeObservers.forEach(center.removeObserver)
        routeObservers.removeAll()
        isStarted = false
    }

    private static func isAirPodsOutput(_ output: AVAudioSessionPortDescription) -> Bool {
        let name = output.portName.localizedCaseInsensitiveContains("airpods")
        let bluetooth = output.portType == .bluetoothA2DP
            || output.portType == .bluetoothHFP
            || output.portType == .bluetoothLE
        return name && bluetooth
    }

    private static func nowPlayingTitle(
        from info: [String: Any]?
    ) -> String {
        let title = info?[MPMediaItemPropertyTitle] as? String
        let artist = info?[MPMediaItemPropertyArtist] as? String
        let values: [String] = [title, artist].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return values.isEmpty ? "음악 재생" : values.joined(separator: " · ")
    }
}

// MARK: - Live sensor collection

/// Reads only the network the device is currently joined to. iOS does not
/// expose a surrounding-network scan to third-party apps. Access requires
/// the Wi-Fi information entitlement and an authorized location status.
@MainActor
enum CurrentConnectedWiFiService {
    static func fetchSSID(
        authorizationStatus: CLAuthorizationStatus,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        guard authorizationStatus == .authorizedAlways
                || authorizationStatus == .authorizedWhenInUse else {
            completion(nil)
            return
        }
        guard #available(iOS 14.0, *) else {
            completion(nil)
            return
        }
        NEHotspotNetwork.fetchCurrent { network in
            let ssid = network?.ssid
            Task { @MainActor in
                completion(ssid)
            }
        }
    }
}

private struct AltimeterSensorUpdate: Sendable {
    var relativeAltitudeMeters: Double?
    var pressureKilopascals: Double?
    var sessionID: UUID
}

private struct PedometerSensorUpdate: Sendable {
    var floorsAscended: Int?
    var floorsDescended: Int?
    var stepCount: Int?
    var walkingRunningDistanceMeters: Double?
    var currentPaceSecondsPerMeter: Double?
    var currentCadenceStepsPerSecond: Double?
    var averageActivePaceSecondsPerMeter: Double?
}

private struct DeviceMotionAccumulator {
    private(set) var sampleCount = 0
    private var accelerationMean = 0.0
    private var accelerationM2 = 0.0
    private var accelerationPeak = 0.0
    private var rotationMean = 0.0
    private var rotationM2 = 0.0
    private var rotationPeak = 0.0

    mutating func append(_ snapshot: DeviceMotionSnapshot) {
        let acceleration = Self.magnitude(snapshot.userAcceleration)
        let rotation = Self.magnitude(snapshot.rotationRate)
        sampleCount += 1
        let count = Double(sampleCount)

        let accelerationDelta = acceleration - accelerationMean
        accelerationMean += accelerationDelta / count
        accelerationM2 += accelerationDelta * (acceleration - accelerationMean)
        accelerationPeak = max(accelerationPeak, acceleration)

        let rotationDelta = rotation - rotationMean
        rotationMean += rotationDelta / count
        rotationM2 += rotationDelta * (rotation - rotationMean)
        rotationPeak = max(rotationPeak, rotation)
    }

    var summary: DeviceMotionSummary? {
        guard sampleCount > 0 else { return nil }
        let divisor = Double(max(1, sampleCount - 1))
        return DeviceMotionSummary(
            sampleCount: sampleCount,
            meanUserAccelerationG: accelerationMean,
            userAccelerationStandardDeviationG:
                sqrt(max(0, accelerationM2 / divisor)),
            peakUserAccelerationG: accelerationPeak,
            meanRotationRateRadiansPerSecond: rotationMean,
            rotationRateStandardDeviationRadiansPerSecond:
                sqrt(max(0, rotationM2 / divisor)),
            peakRotationRateRadiansPerSecond: rotationPeak
        )
    }

    mutating func reset() {
        self = DeviceMotionAccumulator()
    }

    private static func magnitude(_ vector: SensorVector3) -> Double {
        sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
    }
}

@MainActor
final class AppleSensorCollector: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private let activityManager = CMMotionActivityManager()
    private let deviceMotionManager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let pedometer = CMPedometer()

    private var continuation: AsyncStream<SensorReading>.Continuation?
    private var samplingTask: Task<Void, Never>?
    private var movementCandidateTask: Task<Void, Never>?
    private var stationaryStopTask: Task<Void, Never>?
    private var backgroundWakeTask: Task<Void, Never>?
    private var configuration: SensorCollectionConfiguration = .standard
    private var isCollecting = false
    private var isLocationDenied = false
    private var sensorStreamsRunning = false
    private var lastEmissionAt: Date?
    private var lastPersistedLocationTimestamp: Date?
    private var latestLocation: CLLocation?
    private var latestPreciseLocation: CLLocation?
    private var lastBackgroundWakeLocation: CLLocation?
    private var latestMotion: MotionKind = .unknown
    private var latestMotionConfidence: ConfidenceLevel = .low
    private var latestRelativeAltitude: Double?
    private var latestPressureKilopascals: Double?
    private var altimeterSessionID: UUID?
    private var latestFloorsAscended: Int?
    private var latestFloorsDescended: Int?
    private var latestStepCount: Int?
    private var latestWalkingRunningDistance: Double?
    private var latestCurrentPace: Double?
    private var latestCurrentCadence: Double?
    private var latestAverageActivePace: Double?
    private var latestDeviceMotion: DeviceMotionSnapshot?
    private var latestConnectedWiFiSSID: String?
    private var subwayWiFiObservationStreak = 0
    private var currentWiFiFetchInFlight = false
    private var lastWiFiFetchAt: Date?
    private var deviceMotionAccumulator = DeviceMotionAccumulator()
    private var activeTrackingSession: TrackingSession?
    private var activeTrackingPreferences = GPSLoggingPreferences.standard
    private var trackingStreamsAreContinuous = false
    private var trackingSequence = 0
    /// nil이 아니면 층 보정용 표본을 모으는 중이다.
    private var altitudeBurstSamples: [AltitudeBurstSample]?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.activityType = .other
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50
        locationManager.pausesLocationUpdatesAutomatically = true
    }

    func hardwareAvailability() -> SensorHardwareAvailability {
        SensorHardwareAvailability(
            location: CLLocationManager.locationServicesEnabled(),
            motionActivity: CMMotionActivityManager.isActivityAvailable(),
            deviceMotion: deviceMotionManager.isDeviceMotionAvailable,
            magnetometer: deviceMotionManager.isMagnetometerAvailable,
            relativeAltitude: CMAltimeter.isRelativeAltitudeAvailable(),
            stepCounting: CMPedometer.isStepCountingAvailable(),
            distance: CMPedometer.isDistanceAvailable(),
            floorCounting: CMPedometer.isFloorCountingAvailable(),
            pace: CMPedometer.isPaceAvailable(),
            cadence: CMPedometer.isCadenceAvailable()
        )
    }

    func permissionState() -> PermissionState {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .restricted, .denied:
            return .denied
        case .authorizedAlways, .authorizedWhenInUse:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func motionPermissionState() -> PermissionState {
        switch CMMotionActivityManager.authorizationStatus() {
        case .notDetermined:
            return .notDetermined
        case .restricted, .denied:
            return .denied
        case .authorized:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func hasAlwaysLocationAuthorization() -> Bool {
        locationManager.authorizationStatus == .authorizedAlways
    }

    func locationAuthorizationStatus() -> CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    func hasPreciseLocationAuthorization() -> Bool {
        locationManager.accuracyAuthorization == .fullAccuracy
    }

    func requestLocationPermission(always: Bool = false) {
        if always {
            locationManager.requestAlwaysAuthorization()
        } else {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func readings(highAccuracyDuringMovement: Bool = true) -> AsyncStream<SensorReading> {
        var configuration = SensorCollectionConfiguration.standard
        configuration.highAccuracyDuringMovement = highAccuracyDuringMovement
        return readings(configuration: configuration)
    }

    func readings(
        configuration: SensorCollectionConfiguration
    ) -> AsyncStream<SensorReading> {
        let configuration = configuration.normalized
        return AsyncStream { continuation in
            self.continuation = continuation
            self.configuration = configuration
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            start()
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        movementCandidateTask?.cancel()
        movementCandidateTask = nil
        stationaryStopTask?.cancel()
        stationaryStopTask = nil
        backgroundWakeTask?.cancel()
        backgroundWakeTask = nil
        stopHardwareStreams()
        locationManager.stopMonitoringVisits()
        locationManager.stopMonitoringSignificantLocationChanges()
        locationManager.allowsBackgroundLocationUpdates = false
        isCollecting = false
        isLocationDenied = false
        lastPersistedLocationTimestamp = nil
        lastEmissionAt = nil
        latestPreciseLocation = nil
        latestRelativeAltitude = nil
        latestPressureKilopascals = nil
        altimeterSessionID = nil
        latestFloorsAscended = nil
        latestFloorsDescended = nil
        latestStepCount = nil
        latestWalkingRunningDistance = nil
        latestCurrentPace = nil
        latestCurrentCadence = nil
        latestAverageActivePace = nil
        latestDeviceMotion = nil
        latestConnectedWiFiSSID = nil
        subwayWiFiObservationStreak = 0
        currentWiFiFetchInFlight = false
        lastWiFiFetchAt = nil
        lastBackgroundWakeLocation = nil
        deviceMotionAccumulator.reset()
        activeTrackingSession = nil
        activeTrackingPreferences = .standard
        trackingStreamsAreContinuous = false
        trackingSequence = 0
        continuation?.finish()
        continuation = nil
    }

    func beginTracking(
        kind: TrackingKind,
        linkedPlanID: UUID? = nil,
        sessionID: UUID = UUID(),
        preferences: GPSLoggingPreferences = .standard
    ) -> TrackingSession {
        let session = TrackingSession(
            id: sessionID,
            kind: kind,
            linkedPlanID: linkedPlanID,
            wasAutomaticallyDetected: false
        )
        activeTrackingSession = session
        activeTrackingPreferences = preferences
        trackingStreamsAreContinuous = true
        trackingSequence = 0
        lastEmissionAt = nil
        lastPersistedLocationTimestamp = nil
        movementCandidateTask?.cancel()
        stationaryStopTask?.cancel()
        applyLocationPolicy(isMoving: true)
        if sensorStreamsRunning {
            stopHardwareStreams()
        }
        updateBackgroundWakeMonitoring()
        restartSamplingTask()
        return session
    }

    @discardableResult
    func resumeTracking(
        _ session: TrackingSession,
        preferences: GPSLoggingPreferences = .standard
    ) -> TrackingSession {
        activeTrackingSession = session
        activeTrackingPreferences = preferences
        trackingStreamsAreContinuous = true
        trackingSequence = 0
        lastEmissionAt = nil
        lastPersistedLocationTimestamp = nil
        movementCandidateTask?.cancel()
        stationaryStopTask?.cancel()
        applyLocationPolicy(isMoving: true)
        if sensorStreamsRunning {
            stopHardwareStreams()
        }
        updateBackgroundWakeMonitoring()
        restartSamplingTask()
        return session
    }

    func updateTrackingPreferences(_ preferences: GPSLoggingPreferences) {
        guard activeTrackingSession != nil else { return }
        if activeTrackingSession?.wasAutomaticallyDetected == true,
           activeTrackingPreferences != preferences {
            endTracking()
            return
        }
        activeTrackingPreferences = preferences
        applyLocationPolicy(isMoving: true)
        if sensorStreamsRunning { stopHardwareStreams() }
        updateBackgroundWakeMonitoring()
        restartSamplingTask()
    }

    @discardableResult
    func endTracking(at date: Date = .now) -> TrackingSession? {
        guard var session = activeTrackingSession else { return nil }
        session.endedAt = date
        let preferences = activeTrackingPreferences
        activeTrackingSession = nil
        trackingStreamsAreContinuous = false
        stationaryStopTask?.cancel()
        stationaryStopTask = nil
        if session.wasAutomaticallyDetected {
            emit(force: true, completedSession: session)
        } else if let location = preferredTrackingLocation(
            batteryMinimal: preferences.isBatteryMinimal
        ) {
            latestLocation = location
            emit(force: true, completedSession: session)
        }
        activeTrackingPreferences = .standard
        stopHardwareStreams()
        applyLocationPolicy(isMoving: latestMotion != .stationary)
        restartSamplingTask()
        return session
    }

    private func start() {
        guard !isCollecting else { return }
        isCollecting = true
        isLocationDenied = false
        applyLocationPolicy(isMoving: false)
        locationManager.allowsBackgroundLocationUpdates =
            configuration.allowsBackgroundLocation
            && locationManager.authorizationStatus == .authorizedAlways
        updateBackgroundWakeMonitoring()
        restartSamplingTask()
    }

    /// 듀티사이클 사이에 앱이 suspend되어도 위치 이벤트로 다시 깨어나
    /// 표본을 남길 수 있도록 저전력 모니터링을 켠다. 이것이 없으면
    /// 예약된 간격 기록이 포그라운드에서만 동작한다.
    private func updateBackgroundWakeMonitoring() {
        guard isCollecting,
              configuration.allowsBackgroundLocation,
              locationManager.authorizationStatus == .authorizedAlways else {
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.stopMonitoringVisits()
            return
        }
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            locationManager.startMonitoringSignificantLocationChanges()
        }
        locationManager.startMonitoringVisits()
    }

    private func restartSamplingTask() {
        samplingTask?.cancel()
        samplingTask = nil
        guard isCollecting,
              !isLocationDenied else {
            return
        }
        if configuration.minimumEmissionInterval <= 1
            || (activeTrackingSession != nil
                && trackingStreamsAreContinuous) {
            startHardwareStreams()
            return
        }
        samplingTask = Task { [weak self] in
            await self?.runSamplingLoop()
        }
    }

    private func runSamplingLoop() async {
        while !Task.isCancelled, isCollecting {
            let startedAt = Date.now
            await sampleOnce()
            guard !Task.isCancelled, isCollecting else { break }
            let interval = max(1, activeEmissionInterval)
            let nextStart = startedAt.addingTimeInterval(interval)
            let delay = max(0, nextStart.timeIntervalSinceNow)
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func sampleOnce() async {
        guard isCollecting else { return }
        let session = activeTrackingSession
        if session?.wasAutomaticallyDetected == false {
            // A cached location from the previous window must not win over a
            // fresh fix (or become a stale fallback) for this sample.
            clearSampleState()
        }

        startHardwareStreams()
        try? await Task.sleep(
            for: .seconds(configuration.profile.samplingWindowDuration)
        )
        guard !Task.isCancelled else { return }

        if let activeSession = activeTrackingSession,
           !activeSession.wasAutomaticallyDetected {
            if let location = preferredTrackingLocation(
                batteryMinimal: activeTrackingPreferences.isBatteryMinimal
            ) {
                latestLocation = location
                emit(force: true, allowManualTrackingSample: true)
            }
            stopHardwareStreams()
            clearSampleState()
            return
        }

        // A manual session may have ended while its sampling window was
        // asleep. Its final record was handled by endTracking; do not emit a
        // blank baseline record from this now-obsolete window.
        if session?.wasAutomaticallyDetected == false {
            stopHardwareStreams()
            clearSampleState()
            return
        }

        // Motion can promote this window to a tracking session. In that case
        // the streams stay on and the route continues without a duty-cycle
        // gap until the session ends.
        if let movementCandidateTask {
            await movementCandidateTask.value
            guard !Task.isCancelled else { return }
        }
        guard activeTrackingSession == nil else { return }
        emit(force: true)
        // 층 보정 표본을 모으는 중이면 이 창을 끄지 않는다. 끄면 사용자가
        // 기다리는 동안 표본이 끊긴다.
        guard altitudeBurstSamples == nil else { return }
        stopHardwareStreams()
        clearSampleState()
    }

    private func preferredTrackingLocation(
        batteryMinimal: Bool
    ) -> CLLocation? {
        let freshness = max(90, activeTrackingPreferences.interval * 1.5)
        let candidates = [
            latestPreciseLocation,
            latestLocation,
            locationManager.location,
        ].compactMap { location -> CLLocation? in
            guard let location,
                  abs(location.timestamp.timeIntervalSinceNow) <= freshness,
                  TrackingSessionPolicy.allowsPersistingLocation(
                      horizontalAccuracy: location.horizontalAccuracy,
                      batteryMinimal: batteryMinimal
                  ) else {
                return nil
            }
            return location
        }
        guard !candidates.isEmpty else { return nil }
        if let precise = candidates.first(where: {
            $0.horizontalAccuracy
                <= TrackingSessionPolicy.activeHorizontalAccuracyLimit
        }) {
            return precise
        }
        return candidates.max(by: { $0.timestamp < $1.timestamp })
    }

    private func startHardwareStreams() {
        guard !sensorStreamsRunning else { return }
        sensorStreamsRunning = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshConnectedWiFiIfNeeded(force: true)
        locationManager.allowsBackgroundLocationUpdates =
            configuration.allowsBackgroundLocation
            && locationManager.authorizationStatus == .authorizedAlways
        locationManager.showsBackgroundLocationIndicator =
            locationManager.allowsBackgroundLocationUpdates
        applyLocationPolicy(
            isMoving: activeTrackingSession != nil
                || configuration.minimumEmissionInterval <= 1
        )
        if permissionState() == .authorized {
            locationManager.startUpdatingLocation()
        }

        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: .main) { [weak self] activity in
                guard let activity else { return }
                Task { @MainActor in
                    guard let self else { return }
                    self.latestMotion = Self.motionKind(activity)
                    self.latestMotionConfidence = Self.confidence(activity.confidence)
                    self.updateAutomaticTracking(for: self.latestMotion)
                    if self.configuration.highAccuracyDuringMovement {
                        self.applyLocationPolicy(
                            isMoving: !activity.stationary
                        )
                    }
                    self.emit()
                }
            }
        }

        if configuration.collectsDeviceMotion,
           deviceMotionManager.isDeviceMotionAvailable {
            deviceMotionManager.deviceMotionUpdateInterval =
                configuration.profile == .accuracy ? 0.25 : 2
            let availableFrames =
                CMMotionManager.availableAttitudeReferenceFrames()
            let referenceFrame: CMAttitudeReferenceFrame =
                availableFrames.contains(.xArbitraryCorrectedZVertical)
                    ? .xArbitraryCorrectedZVertical
                    : .xArbitraryZVertical
            deviceMotionManager.startDeviceMotionUpdates(
                using: referenceFrame,
                to: .main
            ) { [weak self] motion, _ in
                guard let motion else { return }
                let snapshot = DeviceMotionSnapshot(
                    gravity: SensorVector3(
                        x: motion.gravity.x,
                        y: motion.gravity.y,
                        z: motion.gravity.z
                    ),
                    userAcceleration: SensorVector3(
                        x: motion.userAcceleration.x,
                        y: motion.userAcceleration.y,
                        z: motion.userAcceleration.z
                    ),
                    rotationRate: SensorVector3(
                        x: motion.rotationRate.x,
                        y: motion.rotationRate.y,
                        z: motion.rotationRate.z
                    ),
                    attitudeRadians: SensorVector3(
                        x: motion.attitude.roll,
                        y: motion.attitude.pitch,
                        z: motion.attitude.yaw
                    ),
                    magneticFieldMicroteslas: SensorVector3(
                        x: motion.magneticField.field.x,
                        y: motion.magneticField.field.y,
                        z: motion.magneticField.field.z
                    ),
                    magneticFieldAccuracy:
                        Int(motion.magneticField.accuracy.rawValue),
                    headingDegrees: motion.heading >= 0
                        ? motion.heading
                        : nil
                )
                Task { @MainActor in
                    guard let self else { return }
                    self.latestDeviceMotion = snapshot
                    self.deviceMotionAccumulator.append(snapshot)
                    self.emit()
                }
            }
        }

        if CMAltimeter.isRelativeAltitudeAvailable() {
            let sessionID = UUID()
            altimeterSessionID = sessionID
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                let update = AltimeterSensorUpdate(
                    relativeAltitudeMeters:
                        data?.relativeAltitude.doubleValue,
                    pressureKilopascals: data?.pressure.doubleValue,
                    sessionID: sessionID
                )
                Task { @MainActor in
                    self?.apply(update)
                }
            }
        }

        if CMPedometer.isStepCountingAvailable() {
            let handler:
                @Sendable (CMPedometerData?, Error?) -> Void = {
                    [weak self] data, _ in
                    let update = PedometerSensorUpdate(
                        floorsAscended: data?.floorsAscended?.intValue,
                        floorsDescended: data?.floorsDescended?.intValue,
                        stepCount: data?.numberOfSteps.intValue,
                        walkingRunningDistanceMeters:
                            data?.distance?.doubleValue,
                        currentPaceSecondsPerMeter:
                            data?.currentPace?.doubleValue,
                        currentCadenceStepsPerSecond:
                            data?.currentCadence?.doubleValue,
                        averageActivePaceSecondsPerMeter:
                            data?.averageActivePace?.doubleValue
                    )
                    Task { @MainActor in
                        self?.apply(update)
                    }
                }
            pedometer.startUpdates(from: .now, withHandler: handler)
        }
    }

    private func stopHardwareStreams() {
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.showsBackgroundLocationIndicator = false
        activityManager.stopActivityUpdates()
        deviceMotionManager.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        pedometer.stopUpdates()
        UIDevice.current.isBatteryMonitoringEnabled = false
        sensorStreamsRunning = false
        if activeTrackingSession == nil {
            movementCandidateTask?.cancel()
            movementCandidateTask = nil
        }
    }

    private func clearSampleState() {
        latestLocation = nil
        latestPreciseLocation = nil
        latestMotion = .unknown
        latestMotionConfidence = .low
        latestRelativeAltitude = nil
        latestPressureKilopascals = nil
        altimeterSessionID = nil
        latestFloorsAscended = nil
        latestFloorsDescended = nil
        latestStepCount = nil
        latestWalkingRunningDistance = nil
        latestCurrentPace = nil
        latestCurrentCadence = nil
        latestAverageActivePace = nil
        latestDeviceMotion = nil
        deviceMotionAccumulator.reset()
    }

    private func refreshConnectedWiFiIfNeeded(force: Bool = false) {
        guard permissionState() == .authorized,
              !currentWiFiFetchInFlight else { return }
        if !force,
           let lastWiFiFetchAt,
           Date.now.timeIntervalSince(lastWiFiFetchAt) < 30 {
            return
        }
        currentWiFiFetchInFlight = true
        lastWiFiFetchAt = .now
        CurrentConnectedWiFiService.fetchSSID(
            authorizationStatus: locationManager.authorizationStatus
        ) { [weak self] ssid in
            Task { @MainActor in
                guard let self else { return }
                self.currentWiFiFetchInFlight = false
                self.latestConnectedWiFiSSID = ssid
                if SubwayWiFiSSID.isAllowed(ssid) {
                    self.subwayWiFiObservationStreak += 1
                } else {
                    self.subwayWiFiObservationStreak = 0
                }
            }
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let previousWakeLocation = lastBackgroundWakeLocation
        let isFirstLocationFix = latestLocation == nil
        let validLocations = locations.filter {
            $0.horizontalAccuracy >= 0
                && abs($0.timestamp.timeIntervalSinceNow) < 5 * 60
        }
        latestLocation = validLocations.last
        if let precise = validLocations.last(where: {
            $0.horizontalAccuracy
                <= TrackingSessionPolicy.activeHorizontalAccuracyLimit
        }) {
            latestPreciseLocation = precise
        }
        if let latestLocation {
            lastBackgroundWakeLocation = latestLocation
            promoteBackgroundMovementIfNeeded(
                latestLocation,
                previous: previousWakeLocation,
                batch: locations
            )
        }
        if activeTrackingSession?.wasAutomaticallyDetected == true {
            emit(force: true)
        } else if activeTrackingSession?.wasAutomaticallyDetected == false,
                  trackingStreamsAreContinuous {
            emit(force: true, allowManualTrackingSample: true)
        } else if activeTrackingSession == nil,
                  latestLocation != nil {
            if configuration.minimumEmissionInterval <= 1 {
                emit()
            } else if isFirstLocationFix {
                emit(force: true)
            }
        }
    }

    private func promoteBackgroundMovementIfNeeded(
        _ location: CLLocation,
        previous: CLLocation?,
        batch: [CLLocation]
    ) {
        guard isCollecting,
              configuration.allowsBackgroundLocation,
              TrackingSessionPolicy.allowsAutomaticTracking(
                interval: configuration.minimumEmissionInterval
              ),
              !sensorStreamsRunning,
              activeTrackingSession == nil else { return }
        let batchStart = batch.first { $0.horizontalAccuracy >= 0 }
        let distance = previous.map(location.distance)
            ?? batchStart.map(location.distance)
            ?? 0
        let elapsed = previous.map {
            location.timestamp.timeIntervalSince($0.timestamp)
        } ?? batchStart.map {
            location.timestamp.timeIntervalSince($0.timestamp)
        } ?? .greatestFiniteMagnitude
        guard TrackingSessionPolicy.shouldPromoteBackgroundMovement(
            speedMetersPerSecond: location.speed,
            displacementMeters: distance,
            elapsed: elapsed
        ) else {
            return
        }

        activeTrackingSession = TrackingSession(
            kind: .automatic,
            wasAutomaticallyDetected: true
        )
        trackingStreamsAreContinuous = true
        activeTrackingPreferences = GPSLoggingPreferences(
            intervalSeconds: max(1, Int(configuration.minimumEmissionInterval))
        )
        trackingSequence = 0
        startHardwareStreams()
        applyLocationPolicy(isMoving: true)

        backgroundWakeTask?.cancel()
        backgroundWakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self,
                  self.activeTrackingSession?.wasAutomaticallyDetected == true,
                  self.latestMotion == .stationary
                    || self.latestMotion == .unknown else { return }
            self.endTracking()
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didVisit visit: CLVisit
    ) {
        let date = visit.departureDate == .distantFuture
            ? visit.arrivalDate
            : visit.departureDate
        let location = CLLocation(
            coordinate: visit.coordinate,
            altitude: 0,
            horizontalAccuracy: visit.horizontalAccuracy,
            verticalAccuracy: -1,
            timestamp: date
        )
        latestLocation = location
        latestPreciseLocation = location.horizontalAccuracy
            <= TrackingSessionPolicy.activeHorizontalAccuracyLimit
            ? location
            : nil
        latestMotion = .stationary
        latestMotionConfidence = .high
        // 방문 이벤트는 백그라운드 웨이크업으로 드물게 도착하므로
        // 발행 간격 제한 없이 즉시 기록한다.
        if activeTrackingSession?.wasAutomaticallyDetected == true
            || activeTrackingSession == nil {
            emit(force: true)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if permissionState() == .authorized {
            isLocationDenied = false
            manager.allowsBackgroundLocationUpdates =
                configuration.allowsBackgroundLocation
                && manager.authorizationStatus == .authorizedAlways
            updateBackgroundWakeMonitoring()
            if sensorStreamsRunning {
                manager.startUpdatingLocation()
            } else {
                manager.stopUpdatingLocation()
                restartSamplingTask()
            }
        } else if activeTrackingSession != nil {
            endTracking()
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        guard (error as? CLError)?.code == .denied else { return }
        // 스트림을 끝내면 권한을 다시 허용해도 수집이 재개되지 않는다.
        // 하드웨어만 멈추고 권한 변경 콜백에서 다시 시작한다.
        isLocationDenied = true
        samplingTask?.cancel()
        samplingTask = nil
        stopHardwareStreams()
        if activeTrackingSession != nil {
            endTracking()
        }
        locationManager.stopMonitoringSignificantLocationChanges()
        locationManager.stopMonitoringVisits()
    }

    private func emit(
        force: Bool = false,
        completedSession: TrackingSession? = nil,
        allowManualTrackingSample: Bool = false
    ) {
        guard continuation != nil else { return }
        refreshConnectedWiFiIfNeeded()
        if activeTrackingSession?.wasAutomaticallyDetected == false,
           completedSession == nil,
           !allowManualTrackingSample {
            return
        }
        let now = Date.now
        if force,
           completedSession == nil,
           activeTrackingSession?.wasAutomaticallyDetected == true,
           let lastEmissionAt,
           now.timeIntervalSince(lastEmissionAt)
                < max(
                    TrackingSessionPolicy.automaticEmissionThrottleInterval,
                    activeEmissionInterval
                ) {
            return
        }
        if !force,
           let lastEmissionAt,
           now.timeIntervalSince(lastEmissionAt)
                < max(0.25, activeEmissionInterval) {
            return
        }
        if force,
           completedSession == nil,
           activeTrackingSession?.wasAutomaticallyDetected == false,
           let lastEmissionAt,
           now.timeIntervalSince(lastEmissionAt) < activeEmissionInterval {
            return
        }
        let location = latestLocation
        if activeTrackingSession != nil,
           completedSession == nil,
           trackingStreamsAreContinuous {
            guard let location,
                  lastPersistedLocationTimestamp.map({
                      location.timestamp > $0
                  }) ?? true else {
                return
            }
        }
        lastEmissionAt = now
        if activeTrackingSession != nil,
           completedSession == nil {
            lastPersistedLocationTimestamp = location?.timestamp
        }
        let locationFixQuality = Self.locationFixQuality(
            for: location,
            hasFullAccuracyAuthorization:
                locationManager.accuracyAuthorization == .fullAccuracy
        )
        let capturedAt = location?.timestamp ?? now
        let point = location.map {
            GeoPoint(
                latitude: $0.coordinate.latitude,
                longitude: $0.coordinate.longitude,
                altitude: $0.altitude,
                horizontalAccuracy: $0.horizontalAccuracy,
                verticalAccuracy: $0.verticalAccuracy
            )
        }
        let session = completedSession ?? activeTrackingSession
        let screen = screenSnapshot()
        if session != nil { trackingSequence += 1 }
        continuation?.yield(
            SensorReading(
                timestamp: capturedAt,
                point: point,
                locationFixQuality: locationFixQuality,
                speedMetersPerSecond: location.flatMap { $0.speed >= 0 ? $0.speed : nil },
                speedAccuracyMetersPerSecond: location.flatMap {
                    $0.speedAccuracy >= 0 ? $0.speedAccuracy : nil
                },
                courseDegrees: location.flatMap { $0.course >= 0 ? $0.course : nil },
                courseAccuracyDegrees: location.flatMap {
                    $0.courseAccuracy >= 0 ? $0.courseAccuracy : nil
                },
                motion: latestMotion,
                motionConfidence: latestMotionConfidence,
                relativeAltitudeMeters: latestRelativeAltitude,
                pressureKilopascals: latestPressureKilopascals,
                altimeterSessionID: altimeterSessionID,
                floorsAscended: latestFloorsAscended,
                floorsDescended: latestFloorsDescended,
                stepCount: latestStepCount,
                walkingRunningDistanceMeters: latestWalkingRunningDistance,
                currentPaceSecondsPerMeter: latestCurrentPace,
                currentCadenceStepsPerSecond: latestCurrentCadence,
                averageActivePaceSecondsPerMeter: latestAverageActivePace,
                deviceMotion: latestDeviceMotion,
                deviceMotionSummary: deviceMotionAccumulator.summary,
                systemFloor: location?.floor?.level,
                powerState: Self.powerState(UIDevice.current.batteryState),
                screenBrightness: screen.brightness,
                screenIsOn: screen.isOn,
                gpsAvailable: locationFixQuality == .precise,
                connectedWiFiSSID: latestConnectedWiFiSSID,
                subwayWiFiObservationStreak: subwayWiFiObservationStreak,
                trackingSessionID: session?.id,
                trackingKind: session?.kind,
                sourceDevice: .iPhone,
                sequence: session == nil ? nil : trackingSequence,
                trackingSessionEnded: completedSession != nil
            )
        )
        deviceMotionAccumulator.reset()
    }

    private func screenSnapshot() -> PhoneScreenSnapshot {
        if UIApplication.shared.applicationState == .active {
            let snapshot = PhoneScreenSnapshot(
                brightness: Double(UIScreen.main.brightness),
                isOn: true
            )
            PhoneScreenActivityStore.update(
                brightness: snapshot.brightness,
                isOn: snapshot.isOn
            )
            return snapshot
        }
        return PhoneScreenActivityStore.snapshot()
    }

    private static func powerState(
        _ value: UIDevice.BatteryState
    ) -> DevicePowerState {
        switch value {
        case .unplugged: .unplugged
        case .charging: .charging
        case .full: .full
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }

    private func updateAutomaticTracking(for motion: MotionKind) {
        guard sensorStreamsRunning else {
            movementCandidateTask?.cancel()
            movementCandidateTask = nil
            return
        }
        if let session = activeTrackingSession,
           session.wasAutomaticallyDetected {
            if motion == .stationary {
                guard stationaryStopTask == nil else { return }
                stationaryStopTask = Task { [weak self] in
                    try? await Task.sleep(
                        for: .seconds(
                            TrackingSessionPolicy.automaticStopStationaryDuration
                        )
                    )
                    guard !Task.isCancelled, let self,
                          self.latestMotion == .stationary,
                          self.activeTrackingSession?.wasAutomaticallyDetected == true else {
                        return
                    }
                    self.endTracking()
                }
            } else {
                stationaryStopTask?.cancel()
                stationaryStopTask = nil
            }
            return
        }

        // 차량·자전거 이동도 연속 추적으로 승격한다. 듀티사이클 표본만으로는
        // 경로가 출발·도착을 잇는 직선으로만 남는다.
        guard activeTrackingSession == nil,
              TrackingSessionPolicy.allowsAutomaticTracking(
                interval: configuration.minimumEmissionInterval
              ),
              motion == .walking
                || motion == .running
                || motion == .cycling
                || motion == .automotive,
              latestMotionConfidence != .low else {
            movementCandidateTask?.cancel()
            movementCandidateTask = nil
            return
        }
        guard movementCandidateTask == nil else { return }
        movementCandidateTask = Task { [weak self] in
            try? await Task.sleep(
                for: .seconds(TrackingSessionPolicy.automaticStartDuration)
            )
            guard !Task.isCancelled, let self,
                  self.activeTrackingSession == nil,
                  self.sensorStreamsRunning,
                  self.latestMotion == motion,
                  self.latestMotionConfidence != .low else {
                return
            }
            let kind: TrackingKind = switch motion {
            case .running: .running
            case .walking: .walking
            default: .automatic
            }
            self.activeTrackingSession = TrackingSession(
                kind: kind,
                wasAutomaticallyDetected: true
            )
            self.trackingStreamsAreContinuous = true
            self.activeTrackingPreferences = GPSLoggingPreferences(
                intervalSeconds: max(
                    1,
                    Int(self.configuration.minimumEmissionInterval)
                )
            )
            self.trackingSequence = 0
            self.applyLocationPolicy(isMoving: true)
            self.emit(force: true)
            self.movementCandidateTask = nil
        }
    }

    private func apply(_ update: AltimeterSensorUpdate) {
        latestRelativeAltitude = update.relativeAltitudeMeters
        latestPressureKilopascals = update.pressureKilopascals
        altimeterSessionID = update.sessionID
        if altitudeBurstSamples != nil {
            altitudeBurstSamples?.append(
                AltitudeBurstSample(
                    relativeAltitudeMeters: update.relativeAltitudeMeters,
                    pressureKilopascals: update.pressureKilopascals,
                    altimeterSessionID: update.sessionID,
                    timestamp: .now
                )
            )
        }
        emit()
    }

    /// 층 보정은 한 표본이 아니라 짧은 묶음으로 잰다. 기압 갱신은 약 1초에
    /// 한 번 오므로 듀티사이클로 꺼져 있던 센서를 이 동안만 켜고, 끝나면
    /// 원래 주기로 돌려준다.
    func captureAltitudeBurst(
        count: Int,
        timeout: TimeInterval,
        onProgress: @MainActor (Int) -> Void = { _ in }
    ) async -> [AltitudeBurstSample] {
        guard CMAltimeter.isRelativeAltitudeAvailable(),
              altitudeBurstSamples == nil else {
            return []
        }
        let wasRunning = sensorStreamsRunning
        altitudeBurstSamples = []
        if !wasRunning { startHardwareStreams() }
        let deadline = Date.now.addingTimeInterval(timeout)
        var reported = 0
        while !Task.isCancelled, Date.now < deadline {
            let collected = altitudeBurstSamples?.count ?? 0
            if collected != reported {
                reported = collected
                onProgress(collected)
            }
            if collected >= count { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let samples = altitudeBurstSamples ?? []
        altitudeBurstSamples = nil
        if !wasRunning, activeTrackingSession == nil {
            stopHardwareStreams()
            clearSampleState()
        }
        return samples
    }

    private func apply(_ update: PedometerSensorUpdate) {
        latestFloorsAscended = update.floorsAscended
        latestFloorsDescended = update.floorsDescended
        latestStepCount = update.stepCount
        latestWalkingRunningDistance =
            update.walkingRunningDistanceMeters
        latestCurrentPace = update.currentPaceSecondsPerMeter
        latestCurrentCadence = update.currentCadenceStepsPerSecond
        latestAverageActivePace = update.averageActivePaceSecondsPerMeter
        emit()
    }

    private func applyLocationPolicy(isMoving: Bool) {
        if activeTrackingSession != nil {
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter =
                TrackingSessionPolicy.activeDistanceFilterMeters
            locationManager.activityType = latestMotion == .automotive
                || (latestLocation?.speed ?? 0) >= 5
                ? .automotiveNavigation
                : .fitness
            locationManager.pausesLocationUpdatesAutomatically = false
            return
        }
        locationManager.activityType = .other
        switch configuration.profile {
        case .batterySaver:
            locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
            locationManager.distanceFilter = 500
        case .balanced:
            locationManager.desiredAccuracy = isMoving
                ? kCLLocationAccuracyBest
                : kCLLocationAccuracyHundredMeters
            locationManager.distanceFilter = isMoving ? 10 : 50
        case .accuracy:
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter = 5
        }
        locationManager.pausesLocationUpdatesAutomatically =
            configuration.minimumEmissionInterval > 1
                && configuration.profile != .accuracy
    }

    private var activeEmissionInterval: TimeInterval {
        if activeTrackingSession != nil, trackingStreamsAreContinuous {
            return TrackingSessionPolicy.automaticEmissionThrottleInterval
        }
        return activeTrackingSession == nil
            ? configuration.minimumEmissionInterval
            : activeTrackingPreferences.interval
    }

    private static func locationFixQuality(
        for location: CLLocation?,
        hasFullAccuracyAuthorization: Bool
    ) -> LocationFixQuality? {
        guard let location, location.horizontalAccuracy >= 0 else {
            return nil
        }
        guard hasFullAccuracyAuthorization else { return .approximate }
        return location.horizontalAccuracy
            <= TrackingSessionPolicy.activeHorizontalAccuracyLimit
            ? .precise
            : .approximate
    }

    private static func motionKind(_ activity: CMMotionActivity) -> MotionKind {
        MotionKindResolver.resolve(
            stationary: activity.stationary,
            walking: activity.walking,
            running: activity.running,
            cycling: activity.cycling,
            automotive: activity.automotive
        )
    }

    private static func confidence(
        _ confidence: CMMotionActivityConfidence
    ) -> ConfidenceLevel {
        switch confidence {
        case .high: .high
        case .medium: .medium
        case .low: .low
        @unknown default: .low
        }
    }
}

// MARK: - Historical iPhone motion data

final class AppleMotionHistoryService: @unchecked Sendable {
    private let activityManager: CMMotionActivityManager
    private let pedometer: CMPedometer

    init(
        activityManager: CMMotionActivityManager = CMMotionActivityManager(),
        pedometer: CMPedometer = CMPedometer()
    ) {
        self.activityManager = activityManager
        self.pedometer = pedometer
    }

    func permissionState() -> PermissionState {
        switch CMMotionActivityManager.authorizationStatus() {
        case .notDetermined:
            return .notDetermined
        case .restricted, .denied:
            return .denied
        case .authorized:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func requestAuthorization() async -> PermissionState {
        guard CMMotionActivityManager.isActivityAvailable() else {
            return .unavailable
        }
        let end = Date.now
        return await withCheckedContinuation { continuation in
            activityManager.queryActivityStarting(
                from: end.addingTimeInterval(-1),
                to: end,
                to: .main
            ) { [weak self] _, _ in
                continuation.resume(
                    returning: self?.permissionState() ?? .unavailable
                )
            }
        }
    }

    func activities(in span: TimeSpan) async throws -> [MotionActivityRecord] {
        guard CMMotionActivityManager.isActivityAvailable() else { return [] }
        // Core Motion returns the last activity up to the requested end date.
        // For today's query that would incorrectly project walking/rest into
        // the future and inflate the review totals. Historical days retain
        // their original boundary.
        let queryEnd = min(span.end, Date.now)
        guard span.start < queryEnd else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            activityManager.queryActivityStarting(
                from: span.start,
                to: queryEnd,
                to: .main
            ) { activities, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    let ordered = (activities ?? [])
                        .filter { $0.startDate < queryEnd }
                        .sorted { $0.startDate < $1.startDate }
                    let records = ordered.enumerated().compactMap {
                        index, activity -> MotionActivityRecord? in
                        let start = max(span.start, activity.startDate)
                        let nextStart = ordered.indices.contains(index + 1)
                            ? ordered[index + 1].startDate
                            : queryEnd
                        let end = min(queryEnd, max(start, nextStart))
                        guard start < end else { return nil }
                        return MotionActivityRecord(
                            span: TimeSpan(start: start, end: end),
                            motion: Self.motionKind(activity),
                            confidence: Self.confidence(activity.confidence)
                        )
                    }
                    continuation.resume(returning: records)
                }
            }
        }
    }

    func pedometerSummary(in span: TimeSpan) async throws -> PedometerSummary? {
        guard CMPedometer.isStepCountingAvailable() else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            pedometer.queryPedometerData(
                from: span.start,
                to: span.end
            ) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(
                        returning: PedometerSummary(
                            span: TimeSpan(
                                start: data.startDate,
                                end: data.endDate
                            ),
                            stepCount: data.numberOfSteps.intValue,
                            distanceMeters: data.distance?.doubleValue,
                            floorsAscended: data.floorsAscended?.intValue,
                            floorsDescended: data.floorsDescended?.intValue,
                            averageActivePaceSecondsPerMeter:
                                data.averageActivePace?.doubleValue
                        )
                    )
                } else {
                    continuation.resume(
                        throwing: CocoaError(.fileReadUnknown)
                    )
                }
            }
        }
    }

    private static func motionKind(_ activity: CMMotionActivity) -> MotionKind {
        MotionKindResolver.resolve(
            stationary: activity.stationary,
            walking: activity.walking,
            running: activity.running,
            cycling: activity.cycling,
            automotive: activity.automotive
        )
    }

    private static func confidence(
        _ confidence: CMMotionActivityConfidence
    ) -> ConfidenceLevel {
        switch confidence {
        case .high: .high
        case .medium: .medium
        case .low: .low
        @unknown default: .low
        }
    }
}

actor PlaceNameResolver {
    func displayName(
        latitude: Double,
        longitude: Double
    ) async -> String? {
        await withCheckedContinuation { continuation in
            CLGeocoder().reverseGeocodeLocation(
                CLLocation(latitude: latitude, longitude: longitude)
            ) { placemarks, _ in
                let place = placemarks?.first
                let name = place?.areasOfInterest?.first
                    ?? place?.name
                    ?? place?.locality
                continuation.resume(returning: name)
            }
        }
    }
}

struct AppleTransportContext: Hashable, Sendable {
    var subwayStationName: String?
    var busStopName: String?
    var isOnRoad = false

    var isNearSubwayStation: Bool { subwayStationName != nil }
    var isNearBusStop: Bool { busStopName != nil }
}

@MainActor
final class AppleTransportContextService {
    /// Bump when persisted raw sensor readings need a fresh transport
    /// enrichment pass even if their archive fingerprint is unchanged.
    static let enrichmentModelVersion = 4

    private struct CacheEntry {
        let context: AppleTransportContext
        let storedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]

    func enriching(
        _ readings: [SensorReading],
        userTransitLocations: [UserTransitLocation] = []
    ) async -> [SensorReading] {
        let userEnriched = readings.map {
            applyingUserTransitLocations($0, locations: userTransitLocations)
        }
        let staticOnly = readings.indices.filter { index in
            guard let point = userEnriched[index].point,
                  SubwayStationCatalog.nearest(
                      to: point,
                      maximumDistanceMeters: 220
                  ) != nil else { return false }
            let reading = userEnriched[index]
            return reading.motion != .stationary
                || (reading.speedMetersPerSecond ?? 0) >= 1
                || !reading.gpsAvailable
                || reading.nearbyStation
        }
        let candidates = readings.indices.filter { index in
            guard userEnriched[index].point != nil else { return false }
            return userEnriched[index].motion == .automotive
                || (userEnriched[index].speedMetersPerSecond ?? 0) >= 3
        }
        guard candidates.count >= 2 || staticOnly.count >= 2 else {
            return deterministicStationJourneyEnrichment(
                userEnriched.map(refiningStaticStation)
            )
        }

        let anchors = sampledIndices(
            candidates.isEmpty ? staticOnly : candidates,
            maximumCount: 4
        )
        var resolved: [(GeoPoint, AppleTransportContext)] = []
        for index in anchors {
            guard let point = readings[index].point else { continue }
            resolved.append((point, await context(at: point)))
        }
        guard !resolved.isEmpty else {
            return deterministicStationJourneyEnrichment(
                userEnriched.map(refiningStaticStation)
            )
        }

        let enriched = userEnriched.map { reading in
            let reading = refiningStaticStation(reading)
            guard let point = reading.point,
                  let match = resolved.min(by: {
                      distanceMeters(point, $0.0) < distanceMeters(point, $1.0)
                  }),
                  distanceMeters(point, match.0) <= 1_500 else {
                return reading
            }
            var value = reading
            value.nearbyStation = value.nearbyStation
                || match.1.isNearSubwayStation
                || match.1.isNearBusStop
            if let stationName = match.1.subwayStationName
                ?? match.1.busStopName {
                value.nearbyStationName = stationName
            }
            value.matchesPublicTransitRoute =
                value.matchesPublicTransitRoute || match.1.isNearBusStop
            // MapKit 검색이 누락되거나 역 이름을 잘못 붙여도, 공식 역
            // 카탈로그의 좌표를 마지막 보정으로 사용한다. 버스 정류장
            // 표본은 철도 역으로 승격하지 않는다.
            if value.matchesRailRoute,
               let station = SubwayStationCatalog.nearest(
                   to: point,
                   maximumDistanceMeters: 450
               ) {
                value.nearbyStation = true
                value.nearbyStationName = station.stationName
                value.matchesRailRoute = true
            }
            if match.1.isOnRoad {
                var evidence = value.behaviorEvidence ?? []
                if !evidence.contains("Apple 지도 도로 인접") {
                    evidence.append("Apple 지도 도로 인접")
                }
                value.behaviorEvidence = evidence
            }
            return value
        }
        return deterministicStationJourneyEnrichment(enriched)
    }

    private func applyingUserTransitLocations(
        _ reading: SensorReading,
        locations: [UserTransitLocation]
    ) -> SensorReading {
        guard let point = reading.point,
              let location = locations.first(where: {
                  distanceMeters(point, $0.point) <= 100
              }) else {
            return reading
        }
        var value = reading
        value.nearbyStation = true
        value.nearbyStationName = location.name
        switch location.kind {
        case .subwayStation:
            value.matchesRailRoute = true
            value.matchesPublicTransitRoute = true
        case .busStop:
            value.matchesPublicTransitRoute = true
        case .trainStation:
            break
        case .airport:
            value.nearAirport = true
        case .harbor:
            value.nearPort = true
        }
        var evidence = value.behaviorEvidence ?? []
        let marker = "사용자 등록 (\(location.kind.title)): \(location.name)"
        if !evidence.contains(marker) { evidence.append(marker) }
        value.behaviorEvidence = evidence
        return value
    }

    /// Apple의 일시적인 교통 컨텍스트에 의존하지 않고, 보관된 좌표에서
    /// 역 체류(5분)와 역 이탈(50m 이상 2회)을 먼저 확인한 뒤에만 철도
    /// 컨텍스트를 저장한다. 두 도로 끝점만 있는 기록은 이 단계에서
    /// 승격되지 않는다.
    private func deterministicStationJourneyEnrichment(
        _ readings: [SensorReading]
    ) -> [SensorReading] {
        guard let journey = SubwayStationCatalog.stationJourney(
            from: readings
        ), journey.isConfirmed else {
            return readings
        }
        let journeyStops = journey.stays.compactMap { stay in
            journey.route.stops.first {
                $0.stationName.compare(
                    stay.stationName,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: nil,
                    locale: .current
                ) == .orderedSame
            }
        }
        return readings.map { reading in
            guard let point = reading.point,
                  let stop = journeyStops.min(by: {
                      guard let lhs = $0.coordinate,
                            let rhs = $1.coordinate else { return false }
                      return distanceMeters(point, lhs)
                          < distanceMeters(point, rhs)
                  }),
                  let coordinate = stop.coordinate,
                  distanceMeters(point, coordinate) <= 450 else {
                return reading
            }
            var value = reading
            value.nearbyStation = true
            value.nearbyStationName = stop.stationName
            value.matchesRailRoute = true
            var evidence = value.behaviorEvidence ?? []
            if !evidence.contains("역 체류·50m 이탈 경로 보강") {
                evidence.append("역 체류·50m 이탈 경로 보강")
            }
            value.behaviorEvidence = evidence
            return value
        }
    }

    private func refiningStaticStation(_ reading: SensorReading) -> SensorReading {
        guard let point = reading.point,
              let station = SubwayStationCatalog.nearest(
                  to: point,
                  maximumDistanceMeters: 220
              ) else { return reading }
        guard reading.motion != .stationary
            || (reading.speedMetersPerSecond ?? 0) >= 1
            || !reading.gpsAvailable
            || reading.nearbyStation else { return reading }
        var value = reading
        value.nearbyStation = true
        value.nearbyStationName = station.stationName
        return value
    }

    private func context(at point: GeoPoint) async -> AppleTransportContext {
        let key = cacheKey(point)
        if let cached = cache[key],
           Date.now.timeIntervalSince(cached.storedAt) < 6 * 60 * 60 {
            return cached.context
        }

        async let subway = nearbyName(
            query: "지하철역",
            point: point,
            radius: 450
        )
        async let bus = nearbyName(
            query: "버스정류장",
            point: point,
            radius: 140
        )
        async let road = isOnRoad(point)
        let value = await AppleTransportContext(
            subwayStationName: subway,
            busStopName: bus,
            isOnRoad: road
        )
        cache[key] = CacheEntry(context: value, storedAt: .now)
        return value
    }

    private func nearbyName(
        query: String,
        point: GeoPoint,
        radius: Double
    ) async -> String? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            ),
            latitudinalMeters: max(300, radius * 2),
            longitudinalMeters: max(300, radius * 2)
        )
        guard let response = try? await MKLocalSearch(request: request).start()
        else { return nil }
        let origin = CLLocation(
            latitude: point.latitude,
            longitude: point.longitude
        )
        return response.mapItems
            .compactMap { item -> (Double, String)? in
                let distance = origin.distance(from: CLLocation(
                    latitude: item.placemark.coordinate.latitude,
                    longitude: item.placemark.coordinate.longitude
                ))
                guard distance <= radius else { return nil }
                return (distance, item.name ?? item.placemark.name ?? query)
            }
            .min(by: { $0.0 < $1.0 })?.1
    }

    private func isOnRoad(_ point: GeoPoint) async -> Bool {
        let location = CLLocation(
            latitude: point.latitude,
            longitude: point.longitude
        )
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location)
            .first
        return placemark?.thoroughfare != nil
            || placemark?.subThoroughfare != nil
    }

    private func sampledIndices(
        _ indices: [Int],
        maximumCount: Int
    ) -> [Int] {
        guard indices.count > maximumCount else { return indices }
        return (0..<maximumCount).map { offset in
            indices[offset * (indices.count - 1) / (maximumCount - 1)]
        }
    }

    private func cacheKey(_ point: GeoPoint) -> String {
        "\(Int((point.latitude * 1_000).rounded())):"
            + "\(Int((point.longitude * 1_000).rounded()))"
    }
}

@MainActor
final class AppleTransitBoardingPOIResolver {
    static let shared = AppleTransitBoardingPOIResolver()

    private struct CacheEntry {
        let place: TransitBoardingPlace?
        let storedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]

    func resolving(
        readings: [SensorReading]
    ) async -> [TransitBoardingPlace] {
        let points = sampledPoints(from: readings)
        guard !points.isEmpty else { return [] }

        var places: [TransitBoardingPlace] = []
        for point in points {
            for kind in UserTransitLocationKind.allCases {
                for query in kind.mapKitQueries {
                    let place = await nearbyPlace(
                        query: query,
                        kind: kind,
                        point: point
                    )
                    if let place {
                        places.append(place)
                        break
                    }
                }
            }
        }

        var unique: [String: TransitBoardingPlace] = [:]
        for place in places {
            unique[place.id] = place
        }
        return unique.values.sorted {
            if $0.kind == $1.kind { return $0.name < $1.name }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    private func nearbyPlace(
        query: String,
        kind: UserTransitLocationKind,
        point: GeoPoint
    ) async -> TransitBoardingPlace? {
        let key = "\(kind.rawValue):\(query):"
            + "\(Int((point.latitude * 1_000).rounded())):"
            + "\(Int((point.longitude * 1_000).rounded()))"
        if let cached = cache[key],
           Date.now.timeIntervalSince(cached.storedAt) < 6 * 60 * 60 {
            return cached.place
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            ),
            latitudinalMeters: max(300, kind.mapKitSearchRadiusMeters * 2),
            longitudinalMeters: max(300, kind.mapKitSearchRadiusMeters * 2)
        )
        let response = try? await MKLocalSearch(request: request).start()
        let origin = CLLocation(latitude: point.latitude, longitude: point.longitude)
        let place = response?.mapItems
            .compactMap { item -> (Double, TransitBoardingPlace)? in
                let coordinate = item.placemark.coordinate
                guard CLLocationCoordinate2DIsValid(coordinate),
                      let name = item.name ?? item.placemark.name,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                let distance = origin.distance(
                    from: CLLocation(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    )
                )
                guard distance <= kind.mapKitSearchRadiusMeters else {
                    return nil
                }
                let place = TransitBoardingPlace(
                    mapKitIdentifier: item.identifier?.rawValue,
                    mapKitName: name,
                    kind: kind,
                    point: GeoPoint(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        altitude: 0,
                        horizontalAccuracy: 0,
                        verticalAccuracy: 0
                    )
                )
                return (distance, place)
            }
            .min(by: { $0.0 < $1.0 })?.1
        cache[key] = CacheEntry(place: place, storedAt: .now)
        if cache.count > 512 {
            cache.removeAll(keepingCapacity: true)
        }
        return place
    }

    private func sampledPoints(from readings: [SensorReading]) -> [GeoPoint] {
        let valid = readings
            .filter { $0.gpsAvailable && $0.locationFixQuality != .approximate }
            .compactMap(\.point)
            .filter {
                $0.latitude.isFinite && $0.longitude.isFinite
                    && (-90...90).contains($0.latitude)
                    && (-180...180).contains($0.longitude)
            }
            .sorted { lhs, rhs in
                lhs.latitude == rhs.latitude
                    ? lhs.longitude < rhs.longitude
                    : lhs.latitude < rhs.latitude
            }
        guard !valid.isEmpty else { return [] }

        var unique: [GeoPoint] = []
        var keys = Set<String>()
        for point in valid {
            let key = "\(Int((point.latitude * 1_000).rounded())):\(Int((point.longitude * 1_000).rounded()))"
            if keys.insert(key).inserted { unique.append(point) }
        }
        guard unique.count > 4 else { return unique }
        return (0..<4).map { index in
            unique[index * (unique.count - 1) / 3]
        }
    }
}

// MARK: - Voice memo and notifications

@MainActor
final class VoiceMemoRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var activeURL: URL?

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission {
                continuation.resume(returning: $0)
            }
        }
    }

    func start(in directory: URL) throws -> URL {
        _ = stop()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            "memo-\(UUID().uuidString).m4a"
        )
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(
                true,
                options: .notifyOthersOnDeactivation
            )
            guard session.isInputAvailable,
                  !session.currentRoute.inputs.isEmpty else {
                throw VoiceMemoRecordingError.inputUnavailable
            }

            let sampleRate = session.sampleRate
            let channelCount = session.inputNumberOfChannels
            guard sampleRate > 0, channelCount > 0 else {
                throw VoiceMemoRecordingError.invalidInputFormat
            }

            let recorder = try AVAudioRecorder(
                url: url,
                settings: [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: Int(channelCount),
                    AVEncoderBitRateKey: 128_000,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
            )
            recorder.delegate = self
            guard recorder.prepareToRecord(), recorder.record() else {
                throw VoiceMemoRecordingError.couldNotStart
            }
            self.recorder = recorder
            activeURL = url
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            try? session.setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            throw error
        }
    }

    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        defer { activeURL = nil }
        return activeURL
    }
}

enum VoiceMemoRecordingError: LocalizedError {
    case inputUnavailable
    case invalidInputFormat
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .inputUnavailable:
            "마이크 입력 장치를 사용할 수 없습니다."
        case .invalidInputFormat:
            "현재 오디오 입력 형식을 확인할 수 없습니다."
        case .couldNotStart:
            "녹음 준비를 완료하지 못했습니다."
        }
    }
}

@MainActor
final class VoiceMemoPlayer: NSObject, @preconcurrency AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    var onFinish: (() -> Void)?

    var isPlaying: Bool {
        player?.isPlaying == true
    }

    func play(filePath: String) throws {
        stop()
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VoiceMemoPlaybackError.fileMissing
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else {
            throw VoiceMemoPlaybackError.couldNotStart
        }
        self.player = player
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        onFinish?()
    }
}

enum VoiceMemoPlaybackError: LocalizedError {
    case fileMissing
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            "음성 메모 파일을 찾지 못했습니다."
        case .couldNotStart:
            "음성 메모 재생을 시작하지 못했습니다."
        }
    }
}

actor PlanNotificationScheduler {
    static let identifierPrefix = "plan-start-"

    private let center = UNUserNotificationCenter.current()

    func authorizationState() async -> PermissionState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized
        @unknown default:
            return .unavailable
        }
    }

    func requestPermission() async throws -> PermissionState {
        _ = try await center.requestAuthorization(
            options: [.alert, .badge, .sound]
        )
        return await authorizationState()
    }

    func scheduleStartReminder(for plan: PlanRecord) async throws {
        guard plan.span.start > .now, plan.status == .planned else { return }
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.body = "계획 시작 시간입니다."
        content.sound = .default
        content.userInfo = ["planID": plan.id.uuidString]
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: plan.span.start
        )
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components,
            repeats: false
        )
        try await center.add(
            UNNotificationRequest(
                identifier: Self.identifier(for: plan.id),
                content: content,
                trigger: trigger
            )
        )
    }

    func synchronize(
        plans: [PlanRecord],
        now: Date = .now
    ) async throws {
        guard await authorizationState().isGranted else { return }

        let desired = PlanNotificationPolicy.reminderPlans(
            from: plans,
            now: now
        )
        let desiredIDs = Set(desired.map { Self.identifier(for: $0.id) })
        let current = await center.pendingNotificationRequests()
        let managed = current.filter {
            $0.identifier.hasPrefix(Self.identifierPrefix)
        }
        let obsolete = managed
            .map(\.identifier)
            .filter { !desiredIDs.contains($0) }
        if !obsolete.isEmpty {
            center.removePendingNotificationRequests(
                withIdentifiers: obsolete
            )
        }

        let existingByID = Dictionary(
            uniqueKeysWithValues: managed.map { ($0.identifier, $0) }
        )
        for plan in desired {
            let identifier = Self.identifier(for: plan.id)
            let existingDate = (
                existingByID[identifier]?.trigger
                    as? UNCalendarNotificationTrigger
            )?.nextTriggerDate()
            if let existingDate,
               abs(existingDate.timeIntervalSince(plan.span.start)) < 1 {
                continue
            }
            if existingByID[identifier] != nil {
                center.removePendingNotificationRequests(
                    withIdentifiers: [identifier]
                )
            }
            try await scheduleStartReminder(for: plan)
        }
    }

    func cancel(for planID: UUID) {
        center.removePendingNotificationRequests(
            withIdentifiers: [Self.identifier(for: planID)]
        )
    }

    func cancelAllPlanReminders() async {
        let requests = await center.pendingNotificationRequests()
        let identifiers = requests
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    nonisolated static func identifier(for planID: UUID) -> String {
        "\(identifierPrefix)\(planID.uuidString)"
    }
}

enum PlanNotificationPolicy {
    static let maximumPendingPlanReminders = 60

    static func reminderPlans(
        from plans: [PlanRecord],
        now: Date,
        limit: Int = maximumPendingPlanReminders
    ) -> [PlanRecord] {
        plans
            .filter {
                $0.status == .planned
                    && $0.span.start > now
            }
            .sorted { lhs, rhs in
                if lhs.span.start == rhs.span.start {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.span.start < rhs.span.start
            }
            .prefix(max(0, limit))
            .map { $0 }
    }
}
