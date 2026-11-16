import CoreMotion
import CoreLocation
import HealthKit
import TaptionWatchBehaviorML
import WatchKit
import WidgetKit

extension WatchWorkoutManager {
    func restartHealthSync() {
        healthSnapshotTask?.cancel()
        healthSnapshotTask = nil
        healthSnapshotTaskGeneration = nil
        healthSyncTask?.cancel()
        healthSyncTask = nil
        guard !isCommerceLocked,
              workoutStartGate.beginHealthSync() != nil,
              dataSyncProfile.interval > 0 else { return }
        healthSyncTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.requestHealthSnapshot()
                let interval = self.dataSyncProfile.interval
                guard interval > 0 else { return }
                try? await Task.sleep(
                    nanoseconds: UInt64(interval * 1_000_000_000)
                )
            }
        }
    }

    func requestHealthSnapshot(expectedGeneration: UInt64? = nil) async {
        guard !Task.isCancelled else { return }
        if let expectedGeneration,
           !workoutStartGate.accepts(expectedGeneration) { return }
        let task: Task<Void, Never>
        let generation: UInt64
        if let healthSnapshotTask {
            task = healthSnapshotTask
            generation = healthSnapshotTaskGeneration ?? 0
        } else {
            nextHealthSnapshotGeneration &+= 1
            generation = nextHealthSnapshotGeneration
            task = Task { @MainActor [weak self] in
                await self?.emitHealthSnapshot()
            }
            healthSnapshotTask = task
            healthSnapshotTaskGeneration = generation
        }
        await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
        })
        if healthSnapshotTaskGeneration == generation {
            healthSnapshotTask = nil
            healthSnapshotTaskGeneration = nil
        }
    }

    func requestAuthorization() async throws {
        guard let heartRate = HKQuantityType.quantityType(
            forIdentifier: .heartRate
        ),
        let walkingRunningDistance = HKQuantityType.quantityType(
            forIdentifier: .distanceWalkingRunning
        ),
        let cyclingDistance = HKQuantityType.quantityType(
            forIdentifier: .distanceCycling
        ),
        let activeEnergy = HKQuantityType.quantityType(
            forIdentifier: .activeEnergyBurned
        ) else {
            return
        }
        let workout = HKObjectType.workoutType()
        var readTypes: Set<HKObjectType> = [
            workout,
            heartRate,
            walkingRunningDistance,
            cyclingDistance,
            activeEnergy,
        ]
        if let stepCount = HKQuantityType.quantityType(
            forIdentifier: .stepCount
        ) {
            readTypes.insert(stepCount)
        }
        if let flightsClimbed = HKQuantityType.quantityType(
            forIdentifier: .flightsClimbed
        ) {
            readTypes.insert(flightsClimbed)
        }
        try await healthStore.requestAuthorization(
            toShare: [workout],
            read: readTypes
        )
    }

    private func emitHealthSnapshot() async {
        WatchLaunchDiagnostics.mark("health snapshot begin")
        guard !Task.isCancelled else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            WatchLaunchDiagnostics.mark(
                "health snapshot skipped reason=health_unavailable"
            )
            return
        }
        if !didRequestHealthReadAuthorization {
            await prepareHealthDataAccess()
            guard !Task.isCancelled else { return }
            guard didRequestHealthReadAuthorization else {
                WatchLaunchDiagnostics.mark(
                    "health snapshot skipped reason=authorization_unavailable"
                )
                return
            }
        }
        let calendar = Calendar.current
        let now = Date.now
        let dayStart = calendar.startOfDay(for: now)
        let span = DateInterval(start: dayStart, end: now)
        let sleepStart = calendar.date(
            byAdding: .hour,
            value: -6,
            to: dayStart
        ) ?? dayStart.addingTimeInterval(-6 * 3_600)
        let sleepSpan = DateInterval(start: sleepStart, end: now)
        async let energy = quantityTotal(
            identifier: .activeEnergyBurned,
            unit: .kilocalorie(),
            span: span
        )
        async let exercise = quantityTotal(
            identifier: .appleExerciseTime,
            unit: .minute(),
            span: span
        )
        async let stand = quantityTotal(
            identifier: .appleStandTime,
            unit: .minute(),
            span: span
        )
        let watchSleepSegments: [TaptionWatchSleepSegment]
        let workouts: Int
        let slowRefreshInterval = max(5 * 60, dataSyncProfile.interval)
        if let cachedSlowHealthSnapshot,
           cachedSlowHealthSnapshot.dayStart == dayStart,
           now.timeIntervalSince(cachedSlowHealthSnapshot.capturedAt)
                < slowRefreshInterval {
            watchSleepSegments = cachedSlowHealthSnapshot.sleep
            workouts = cachedSlowHealthSnapshot.workoutCount
        } else {
            async let sleep = sleepSegments(in: sleepSpan)
            async let workoutTotal = workoutCount(in: span)
            let (queriedSleep, queriedWorkouts) = await (sleep, workoutTotal)
            guard !Task.isCancelled else { return }
            guard let queriedSleep, let queriedWorkouts else {
                WatchLaunchDiagnostics.mark(
                    "health snapshot skipped reason=slow query failed"
                )
                return
            }
            watchSleepSegments = queriedSleep
            workouts = queriedWorkouts
            cachedSlowHealthSnapshot = (
                dayStart: dayStart,
                capturedAt: now,
                sleep: watchSleepSegments,
                workoutCount: workouts
            )
        }
        guard !Task.isCancelled else { return }
        let watchSleepMinutes = TaptionWatchSleepDuration.minutes(
            for: watchSleepSegments
        )
        let snapshot = TaptionWatchHealthSnapshot(
            capturedAt: now,
            dayStart: dayStart,
            activeEnergyKilocalories: await energy,
            exerciseMinutes: await exercise,
            standHours: (await stand).map { $0 / 60 },
            sleepMinutes: watchSleepMinutes,
            sleepSegments: watchSleepSegments,
            workoutCount: workouts,
            source: "Apple Watch HealthKit"
        )
        WatchLaunchDiagnostics.mark(
            "health snapshot ready workouts=\(snapshot.workoutCount)"
        )
        guard !Task.isCancelled else { return }
        onHealthSnapshot?(snapshot)
        WatchLaunchDiagnostics.mark("health snapshot handed off")
    }

    func requestHealthReadAuthorization() async throws {
        var readTypes: Set<HKObjectType> = [
            HKObjectType.workoutType(),
        ]
        for identifier in [
            HKQuantityTypeIdentifier.activeEnergyBurned,
            .appleExerciseTime,
            .appleStandTime,
        ] {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                readTypes.insert(type)
            }
        }
        if let sleep = HKObjectType.categoryType(
            forIdentifier: .sleepAnalysis
        ) {
            readTypes.insert(sleep)
        }
        try await healthStore.requestAuthorization(toShare: [], read: readTypes)
    }

    private func quantityTotal(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        span: DateInterval
    ) async -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else {
            return nil
        }
        let predicate = HKQuery.predicateForSamples(
            withStart: span.start,
            end: span.end,
            options: .strictStartDate
        )
        let handle = WatchHealthQueryCancellation<Double?>(
            healthStore: healthStore,
            cancellationValue: nil
        )
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                handle.setContinuation(continuation)
                let query = HKStatisticsQuery(
                    quantityType: type,
                    quantitySamplePredicate: predicate,
                    options: .cumulativeSum
                ) { @Sendable _, statistics, _ in
                    handle.finish(
                        statistics?.sumQuantity()?.doubleValue(for: unit)
                    )
                }
                guard handle.setQuery(query) else { return }
                handle.execute()
            }
        }, onCancel: {
            handle.cancel()
        })
    }

    private func sleepSegments(
        in span: DateInterval
    ) async -> [TaptionWatchSleepSegment]? {
        guard let type = HKObjectType.categoryType(
            forIdentifier: .sleepAnalysis
        ) else { return nil }
        let predicate = HKQuery.predicateForSamples(
            withStart: span.start,
            end: span.end,
            options: []
        )
        let handle = WatchHealthQueryCancellation<[TaptionWatchSleepSegment]?>(
            healthStore: healthStore,
            cancellationValue: nil
        )
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                handle.setContinuation(continuation)
                let query = HKSampleQuery(
                    sampleType: type,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { @Sendable _, samples, error in
                    guard error == nil else {
                        handle.finish(nil)
                        return
                    }
                    let segments = (samples ?? []).compactMap { sample -> TaptionWatchSleepSegment? in
                        guard let category = sample as? HKCategorySample else {
                            return nil
                        }
                        let stage: String
                        switch category.value {
                        case 0: stage = "inBed"
                        case 1: stage = "asleepUnspecified"
                        case 2: stage = "awake"
                        case 3: stage = "core"
                        case 4: stage = "deep"
                        case 5: stage = "rem"
                        default: return nil
                        }
                        let start = max(category.startDate, span.start)
                        let end = min(category.endDate, span.end)
                        guard end > start else {
                            return nil
                        }
                        return TaptionWatchSleepSegment(
                            id: category.uuid,
                            stage: stage,
                            startDate: start,
                            endDate: end,
                            sourceName: category.sourceRevision.source.name,
                            sourceBundleIdentifier: category.sourceRevision.source.bundleIdentifier,
                            deviceName: category.device?.name,
                            timeZoneIdentifier: (category.metadata?[HKMetadataKeyTimeZone] as? String),
                            isUserEntered: (category.metadata?[HKMetadataKeyWasUserEntered] as? Bool) ?? false
                        )
                    }
                    handle.finish(segments)
                }
                guard handle.setQuery(query) else { return }
                handle.execute()
            }
        }, onCancel: {
            handle.cancel()
        })
    }

    private func workoutCount(in span: DateInterval) async -> Int? {
        let predicate = HKQuery.predicateForSamples(
            withStart: span.start,
            end: span.end,
            options: .strictStartDate
        )
        let handle = WatchHealthQueryCancellation<Int?>(
            healthStore: healthStore,
            cancellationValue: nil
        )
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                handle.setContinuation(continuation)
                let query = HKSampleQuery(
                    sampleType: HKObjectType.workoutType(),
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { @Sendable _, samples, error in
                    handle.finish(error == nil ? samples?.count ?? 0 : nil)
                }
                guard handle.setQuery(query) else { return }
                handle.execute()
            }
        }, onCancel: {
            handle.cancel()
        })
    }

    func updateStatistics(for types: Set<HKSampleType>) {
        guard let builder else { return }
        for type in types {
            guard let quantityType = type as? HKQuantityType,
                  let statistics = builder.statistics(for: quantityType) else {
                continue
            }
            switch quantityType.identifier {
            case HKQuantityTypeIdentifier.heartRate.rawValue:
                let unit = HKUnit.count().unitDivided(by: .minute())
                heartRate = statistics.mostRecentQuantity()?.doubleValue(
                    for: unit
                ) ?? heartRate
                averageHeartRate = statistics.averageQuantity()?.doubleValue(
                    for: unit
                ) ?? averageHeartRate
                maximumHeartRate = statistics.maximumQuantity()?.doubleValue(
                    for: unit
                ) ?? maximumHeartRate
            case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
                 HKQuantityTypeIdentifier.distanceCycling.rawValue:
                distanceMeters = statistics.sumQuantity()?.doubleValue(
                    for: .meter()
                ) ?? distanceMeters
            case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
                activeEnergyKilocalories = statistics.sumQuantity()?.doubleValue(
                    for: .kilocalorie()
                ) ?? activeEnergyKilocalories
            default:
                break
            }
        }
    }
}
