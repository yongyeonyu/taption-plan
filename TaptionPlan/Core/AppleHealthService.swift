import CoreLocation
import Foundation
import HealthKit
import TaptionPlanCore

// MARK: - Health and Apple Watch data mirrored to iPhone

actor HealthBackgroundRefreshCoordinator {
    typealias Handler = @Sendable () async -> Bool

    static let shared = HealthBackgroundRefreshCoordinator()

    private var handler: Handler?
    private var pendingHandlerWaiters: [CheckedContinuation<Void, Never>] = []
    private var isDispatching = false
    private var dispatchWaiters: [CheckedContinuation<Bool, Never>] = []

    func register(_ handler: @escaping Handler) {
        self.handler = handler
        let waiters = pendingHandlerWaiters
        pendingHandlerWaiters.removeAll()
        guard !waiters.isEmpty else { return }
        Task {
            _ = await dispatchIfRegistered()
            waiters.forEach { $0.resume() }
        }
    }

    func receiveUpdate() async {
        guard handler != nil else {
            await withCheckedContinuation { continuation in
                pendingHandlerWaiters.append(continuation)
            }
            return
        }
        _ = await dispatchIfRegistered()
    }

    func dispatchIfRegistered() async -> Bool {
        guard let handler else { return false }
        if isDispatching {
            return await withCheckedContinuation { continuation in
                dispatchWaiters.append(continuation)
            }
        }
        isDispatching = true
        let result = await handler()
        isDispatching = false
        let waiters = dispatchWaiters
        dispatchWaiters.removeAll()
        waiters.forEach { $0.resume(returning: result) }
        return result
    }
}

private final class HealthObserverCompletion: @unchecked Sendable {
    private let callback: () -> Void
    private let lock = NSLock()
    private var hasCompleted = false

    init(_ callback: @escaping () -> Void) {
        self.callback = callback
    }

    /// HealthKit accepts one completion per delivery, so a deadline and the
    /// finished work can both call this safely.
    func callAsFunction() {
        lock.lock()
        let isFirst = !hasCompleted
        hasCompleted = true
        lock.unlock()
        if isFirst { callback() }
    }
}

struct HealthKitObservedChangeQueue: Sendable, Equatable {
    private var pending: Set<String> = []

    var isEmpty: Bool { pending.isEmpty }

    mutating func mark(_ identifier: String) {
        pending.insert(identifier)
    }

    mutating func take() -> Set<String>? {
        guard !pending.isEmpty else { return nil }
        let identifiers = pending
        pending.removeAll()
        return identifiers
    }

    mutating func requeue(_ identifiers: Set<String>) {
        pending.formUnion(identifiers)
    }

    mutating func removeAll() {
        pending.removeAll()
    }
}

final class AppleHealthService: @unchecked Sendable {
    static let shared = AppleHealthService()
    private static let maximumRouteLocations = 20_000

    private final class RouteLocationsAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private let maximumCount: Int
        private var values: [CLLocation] = []

        init(maximumCount: Int) {
            self.maximumCount = maximumCount
        }

        func append(_ locations: [CLLocation]) {
            lock.lock()
            let remaining = maximumCount - values.count
            if remaining > 0 {
                values.append(contentsOf: locations.prefix(remaining))
            }
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
    private var observedChangeQueue = HealthKitObservedChangeQueue()
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

    /// 건강 앱의 날짜별 걸음 수 합계(그 달). 읽기 권한이 없거나 기록이 없으면 빈 딕셔너리.
    /// 아이폰·애플워치가 같은 걸음을 두 번 세지 않도록 HealthKit 통계(합산·중복 제거)를 쓴다.
    func dailyStepCounts(from start: Date, to end: Date, calendar: Calendar) async throws -> [Date: Double] {
        guard HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.quantityType(forIdentifier: .stepCount) else { return [:] }
        let anchor = calendar.startOfDay(for: start)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchor,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var result: [Date: Double] = [:]
                collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    let steps = statistics.sumQuantity()?.doubleValue(for: .count()) ?? 0
                    if steps > 0 { result[calendar.startOfDay(for: statistics.startDate)] = steps }
                }
                continuation.resume(returning: result)
            }
            store.execute(query)
        }
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
                    guard error == nil else {
                        completion()
                        return
                    }
                    // Release HealthKit even if the refresh outlives the wake
                    // window, so delivery is not throttled for slow work.
                    let deadline = Task {
                        try await Task.sleep(for: .seconds(20))
                        completion()
                    }
                    #if os(iOS) && !TAPTION_WIDGET
                    let assertion = await MainActor.run {
                        let assertion = BackgroundTaskAssertion()
                        assertion.begin(name: "TaptionPlan.healthObserver") {}
                        return assertion
                    }
                    #endif
                    self?.markObservedChange(typeIdentifier)
                    await onUpdate()
                    deadline.cancel()
                    completion()
                    #if os(iOS) && !TAPTION_WIDGET
                    await assertion.end()
                    #endif
                }
            }
        }
        observerQueries = queries
        observerLock.unlock()

        queries.forEach(store.execute)
    }

    func enableBackgroundDelivery() async throws {
        var firstError: Error?
        for sampleType in observedSampleTypes() {
            do {
                try await setBackgroundDelivery(
                    enabled: true,
                    for: sampleType
                )
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
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
        async let sessions = sleepSessions(in: span)
        return try await workouts + sleepActuals(from: sessions)
    }

    func nonSleepActuals(in span: TimeSpan) async throws -> [ActualRecord] {
        try await workoutActuals(in: span)
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

    func synchronizeChanges(force: Bool = false) async throws -> HealthKitSyncOverview {
        if force { setLastBroadSynchronizationAt(nil) }
        let firstScope = force ? ChangeSyncScope.broad : nextChangeSyncScope()
        var overview: HealthKitSyncOverview
        switch firstScope {
        case let .types(identifiers):
            do {
                overview = try await importCoordinator.synchronizeChanges(
                    typeIdentifiers: identifiers
                )
            } catch {
                requeueObservedTypeIdentifiers(identifiers)
                throw error
            }
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
            do {
                overview = try await importCoordinator.synchronizeChanges(
                    typeIdentifiers: identifiers
                )
            } catch {
                requeueObservedTypeIdentifiers(identifiers)
                throw error
            }
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

    func deleteImportedData(generation: UInt64? = nil) async throws {
        try await importCoordinator.deleteAll(generation: generation)
        clearPendingObservedChanges()
        setLastBroadSynchronizationAt(nil)
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

    func sleepActuals(from sessions: [SleepSession]) -> [ActualRecord] {
        sessions.map { session in
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

    static func isTrustedWorkoutSource(_ bundleIdentifier: String) -> Bool {
        if ["com.apple.Health", "com.apple.health", "com.taption.plan",
            "com.taption.plan.watchkitapp"].contains(bundleIdentifier) {
            return true
        }
        // Apple Watch 운동 앱이 기록한 운동의 출처는 `com.apple.health.<기기 UUID>` 형태다. UUID가 맞는 것만 받고
        // `com.apple.health.fake` 같은 임의 접미사는 계속 거른다(HLT1020A01: 이전에는 Watch 운동이 모두 버려졌다).
        let prefix = "com.apple.health."
        guard bundleIdentifier.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(bundleIdentifier.dropFirst(prefix.count))) != nil
    }

    private static func trustedWorkout(_ sample: HKSample) -> HKWorkout? {
        guard let workout = sample as? HKWorkout,
              isTrustedWorkoutSource(
                workout.sourceRevision.source.bundleIdentifier
              ) else { return nil }
        return workout
    }

    private func workoutDetails(in span: TimeSpan) async throws -> [HealthActual] {
        let type = HKObjectType.workoutType()
        let samples = try await samples(type: type, span: span)
        return samples.compactMap { sample in
            guard let workout = Self.trustedWorkout(sample) else { return nil }
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

    /// 신뢰하는 Apple·Taption 소스의 운동 경로를 읽어
    /// 표본으로 되돌린다. 우리 앱이 듀티사이클 때문에 남기지 못한 구간의
    /// 실제 궤적을 사후에 채우는 유일한 정식 경로다.
    func workoutRouteReadings(
        in span: TimeSpan
    ) async throws -> [SensorReading] {
        let workouts = try await samples(
            type: HKObjectType.workoutType(),
            span: span
        ).compactMap(Self.trustedWorkout)
        guard !workouts.isEmpty else { return [] }

        var result: [SensorReading] = []
        for workout in workouts {
            let mode = workout.workoutActivityType.movementTravelMode
            for route in try await routeSamples(for: workout) {
                let locations = try await locations(in: route)
                for location in locations
                where result.count < Self.maximumRouteLocations
                    && location.horizontalAccuracy >= 0
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
            let collected = RouteLocationsAccumulator(
                maximumCount: Self.maximumRouteLocations
            )
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
            guard let workout = Self.trustedWorkout(sample),
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
        return try await HKSampleQueryDescriptor(
            predicates: [.sample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\HKSample.startDate)]
        ).result(for: store)
    }

    private func readTypes() -> [HKObjectType] {
        HealthKitTypeCatalog.all.filter {
            TaptionHealthReadScope.identifiers.contains($0.identifier)
        }.compactMap(HealthKitTypeCatalog.readObjectType(for:))
    }

    private func observedSampleTypes() -> [HKSampleType] {
        HealthKitTypeCatalog.observableDescriptors.filter {
            TaptionHealthReadScope.identifiers.contains($0.identifier)
                && $0.backgroundEligible
        }.compactMap(HealthKitTypeCatalog.observableSampleType(for:))
    }

    private enum ChangeSyncScope {
        case types(Set<String>)
        case broad
        case cached
    }

    private func markObservedChange(_ typeIdentifier: String) {
        observerLock.lock()
        observedChangeQueue.mark(typeIdentifier)
        observerLock.unlock()
    }

    private func clearPendingObservedChanges() {
        observerLock.lock()
        observedChangeQueue.removeAll()
        observerLock.unlock()
    }

    private func requeueObservedTypeIdentifiers(_ identifiers: Set<String>) {
        guard !identifiers.isEmpty else { return }
        observerLock.lock()
        observedChangeQueue.requeue(identifiers)
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
        if let identifiers = observedChangeQueue.take() {
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
        return observedChangeQueue.take()
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
                    frequency: HealthRefreshPolicy.backgroundFrequency(for: sampleType.identifier),
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
        AppLanguagePreference.text(
            korean: "HealthKit 백그라운드 전달을 등록하지 못했습니다.",
            english: "Could not register HealthKit background delivery."
        )
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
