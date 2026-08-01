import AVFoundation
import CoreLocation
import CoreMotion
import EventKit
import Foundation
import HealthKit
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
                sourceTitle: event.calendar.source.title
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
    static let periodicLookback: TimeInterval = 2 * 86_400
    static let backgroundFrequency: HKUpdateFrequency = .immediate
}

actor HealthBackgroundRefreshCoordinator {
    typealias Handler = @Sendable () async -> Void

    static let shared = HealthBackgroundRefreshCoordinator()

    private var handler: Handler?
    private var pendingHandlerWaiters: [CheckedContinuation<Void, Never>] = []

    func register(_ handler: @escaping Handler) {
        self.handler = handler
        let waiters = pendingHandlerWaiters
        pendingHandlerWaiters.removeAll()
        guard !waiters.isEmpty else { return }
        Task {
            await handler()
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
        await handler()
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

    private let store: HKHealthStore
    private let sleepEngine: SleepAnalysisEngine
    private let observerLock = NSLock()
    private var observerQueries: [HKObserverQuery] = []

    init(
        store: HKHealthStore = HKHealthStore(),
        sleepEngine: SleepAnalysisEngine = SleepAnalysisEngine()
    ) {
        self.store = store
        self.sleepEngine = sleepEngine
    }

    func permissionState() -> PermissionState {
        HKHealthStore.isHealthDataAvailable() ? .notDetermined : .unavailable
    }

    func requestReadAccess() async throws -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let readTypes = Set(readTypes())
        return try await withCheckedThrowingContinuation { continuation in
            store.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
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
            HKObserverQuery(
                sampleType: sampleType,
                predicate: nil
            ) { _, completion, error in
                let completion = HealthObserverCompletion(completion)
                Task {
                    if error == nil {
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
        for sampleType in observedSampleTypes() {
            try await setBackgroundDelivery(
                enabled: true,
                for: sampleType
            )
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
                source: .healthKit,
                confidence: .high
            )
        }
    }

    private func sleepActuals(in span: TimeSpan) async throws -> [ActualRecord] {
        try await sleepSessions(in: span).map { session in
            ActualRecord(
                id: session.id,
                planID: nil,
                title: "수면",
                categoryID: "sleep",
                startedAt: session.span.start,
                endedAt: session.span.end,
                source: .healthKit,
                confidence: .high
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
        [
            HKObjectType.workoutType(),
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
            HKObjectType.categoryType(forIdentifier: .mindfulSession),
            HKObjectType.quantityType(forIdentifier: .stepCount),
            HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning),
            HKObjectType.quantityType(forIdentifier: .flightsClimbed),
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
            HKObjectType.quantityType(forIdentifier: .heartRate)
        ].compactMap { $0 }
    }

    private func observedSampleTypes() -> [HKSampleType] {
        [
            HKObjectType.workoutType(),
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
            HKObjectType.categoryType(forIdentifier: .mindfulSession),
        ].compactMap { $0 }
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
        @unknown default: nil
        }
    }
}

private extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .running: "러닝"
        case .walking: "걷기"
        case .cycling: "자전거"
        case .swimming: "수영"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "근력운동"
        case .hiking: "하이킹"
        case .rowing: "로잉"
        case .elliptical: "일립티컬"
        case .highIntensityIntervalTraining: "HIIT"
        case .dance: "댄스"
        case .yoga: "요가"
        case .pilates: "필라테스"
        case .coreTraining: "코어 운동"
        case .flexibility: "유연성 운동"
        case .mixedCardio: "유산소 운동"
        case .crossTraining: "크로스 트레이닝"
        case .stairs, .stairClimbing: "계단 오르기"
        case .cooldown: "쿨다운"
        case .mindAndBody: "마음과 몸"
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
                self.cachedContext = CachedWeatherContext(
                    location: cachedContext.location,
                    context: context
                )
                return context
            }
            throw WeatherContextServiceError.temporarilyUnavailable
        }
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
        abs(date.timeIntervalSince(context.observedAt)) < 10 * 60
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

// MARK: - Live sensor collection

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
    private var periodicEmissionTask: Task<Void, Never>?
    private var movementCandidateTask: Task<Void, Never>?
    private var stationaryStopTask: Task<Void, Never>?
    private var configuration: SensorCollectionConfiguration = .standard
    private var isCollecting = false
    private var lastEmissionAt: Date?
    private var latestLocation: CLLocation?
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
    private var deviceMotionAccumulator = DeviceMotionAccumulator()
    private var activeTrackingSession: TrackingSession?
    private var trackingSequence = 0

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
        AsyncStream { continuation in
            self.continuation = continuation
            self.configuration = configuration
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            start()
        }
    }

    func stop() {
        periodicEmissionTask?.cancel()
        periodicEmissionTask = nil
        movementCandidateTask?.cancel()
        movementCandidateTask = nil
        stationaryStopTask?.cancel()
        stationaryStopTask = nil
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringVisits()
        locationManager.stopMonitoringSignificantLocationChanges()
        locationManager.allowsBackgroundLocationUpdates = false
        activityManager.stopActivityUpdates()
        deviceMotionManager.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        pedometer.stopUpdates()
        isCollecting = false
        lastEmissionAt = nil
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
        activeTrackingSession = nil
        trackingSequence = 0
        continuation?.finish()
        continuation = nil
    }

    func beginTracking(
        kind: TrackingKind,
        linkedPlanID: UUID? = nil,
        sessionID: UUID = UUID()
    ) -> TrackingSession {
        let session = TrackingSession(
            id: sessionID,
            kind: kind,
            linkedPlanID: linkedPlanID,
            wasAutomaticallyDetected: false
        )
        activeTrackingSession = session
        trackingSequence = 0
        movementCandidateTask?.cancel()
        stationaryStopTask?.cancel()
        applyLocationPolicy(isMoving: true)
        emit(force: true)
        return session
    }

    @discardableResult
    func endTracking(at date: Date = .now) -> TrackingSession? {
        guard var session = activeTrackingSession else { return nil }
        session.endedAt = date
        activeTrackingSession = nil
        stationaryStopTask?.cancel()
        stationaryStopTask = nil
        applyLocationPolicy(isMoving: latestMotion != .stationary)
        emit(force: true, completedSession: session)
        return session
    }

    private func start() {
        guard !isCollecting else { return }
        isCollecting = true
        applyLocationPolicy(isMoving: false)
        locationManager.allowsBackgroundLocationUpdates =
            configuration.allowsBackgroundLocation
            && locationManager.authorizationStatus == .authorizedAlways
        if CLLocationManager.isMonitoringAvailable(for: CLVisit.self) {
            locationManager.startMonitoringVisits()
        }
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            locationManager.startMonitoringSignificantLocationChanges()
        }
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

        let interval = max(1, configuration.minimumEmissionInterval)
        periodicEmissionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { break }
                self.emit()
            }
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let isFirstLocationFix = latestLocation == nil
        latestLocation = locations.last {
            $0.horizontalAccuracy >= 0
                && abs($0.timestamp.timeIntervalSinceNow) < 5 * 60
        }
        let isUsableTrackingPoint = activeTrackingSession != nil
            && (latestLocation?.horizontalAccuracy ?? .greatestFiniteMagnitude)
                <= TrackingSessionPolicy.activeHorizontalAccuracyLimit
        emit(force: (isFirstLocationFix && latestLocation != nil) || isUsableTrackingPoint)
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
        latestMotion = .stationary
        latestMotionConfidence = .high
        emit()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if permissionState() == .authorized {
            manager.allowsBackgroundLocationUpdates =
                configuration.allowsBackgroundLocation
                && manager.authorizationStatus == .authorizedAlways
            manager.startUpdatingLocation()
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        if (error as? CLError)?.code == .denied {
            stop()
        }
    }

    private func emit(
        force: Bool = false,
        completedSession: TrackingSession? = nil
    ) {
        guard continuation != nil else { return }
        let now = Date.now
        if !force,
           let lastEmissionAt,
           now.timeIntervalSince(lastEmissionAt)
            < max(0.25, configuration.minimumEmissionInterval) {
            return
        }
        lastEmissionAt = now
        let location = latestLocation
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
        if session != nil { trackingSequence += 1 }
        continuation?.yield(
            SensorReading(
                timestamp: now,
                point: point,
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
                gpsAvailable: location != nil,
                trackingSessionID: session?.id,
                trackingKind: session?.kind,
                sourceDevice: .iPhone,
                sequence: session == nil ? nil : trackingSequence,
                trackingSessionEnded: completedSession != nil
            )
        )
        deviceMotionAccumulator.reset()
    }

    private func updateAutomaticTracking(for motion: MotionKind) {
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

        guard activeTrackingSession == nil,
              (motion == .walking || motion == .running),
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
                  self.latestMotion == motion,
                  self.latestMotionConfidence != .low else {
                return
            }
            let kind: TrackingKind = motion == .running ? .running : .walking
            self.activeTrackingSession = TrackingSession(
                kind: kind,
                wasAutomaticallyDetected: true
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
        emit()
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
            locationManager.activityType = .fitness
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
            configuration.profile != .accuracy
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

    func activities(in span: TimeSpan) async throws -> [MotionActivityRecord] {
        guard CMMotionActivityManager.isActivityAvailable() else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            activityManager.queryActivityStarting(
                from: span.start,
                to: span.end,
                to: .main
            ) { activities, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    let ordered = (activities ?? [])
                        .filter { $0.startDate < span.end }
                        .sorted { $0.startDate < $1.startDate }
                    let records = ordered.enumerated().compactMap {
                        index, activity -> MotionActivityRecord? in
                        let start = max(span.start, activity.startDate)
                        let nextStart = ordered.indices.contains(index + 1)
                            ? ordered[index + 1].startDate
                            : span.end
                        let end = min(span.end, max(start, nextStart))
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
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            "memo-\(UUID().uuidString).m4a"
        )
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .spokenAudio)
        try session.setActive(true)
        let recorder = try AVAudioRecorder(
            url: url,
            settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        )
        recorder.delegate = self
        recorder.record()
        self.recorder = recorder
        activeURL = url
        return url
    }

    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        defer { activeURL = nil }
        return activeURL
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
