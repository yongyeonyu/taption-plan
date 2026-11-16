import CoreMotion
import CoreLocation
import HealthKit
import TaptionWatchBehaviorML
import WatchKit
import WidgetKit

@MainActor
final class WatchWorkoutManager: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published var latestObservation: WatchActivityObservation?
    @Published private(set) var startedAt: Date?
    @Published var heartRate = 0.0
    @Published var distanceMeters = 0.0
    @Published var activeEnergyKilocalories = 0.0
    @Published var sensorSampleCount = 0
    @Published var latestRelativeAltitudeMeters: Double?
    @Published private(set) var errorMessage: String?
    @Published private(set) var accelerationSettings:
        TaptionWatchAccelerationSettings?
    @Published private(set) var dataSyncProfile: TaptionWatchDataSyncProfile = .off
    @Published private(set) var isCommerceLocked = false
    /// 지금 재고 있는 것. 화면과 위젯이 같은 값을 본다.
    @Published private(set) var measurement = TaptionWatchMeasurementSnapshot()

    // 이 클라이언트들은 각각 시스템 데몬과 연결을 열고 권한을 평가한다.
    // 앱 시작 경로에서 한꺼번에 만들면 첫 프레임 전에 실기기에서만 실패할 수
    // 있으므로, 실제로 필요할 때까지 만들지 않는다.
    lazy var healthStore = HKHealthStore()
    lazy var motionManager = CMMotionManager()
    lazy var altimeter = CMAltimeter()
    lazy var pedometer = CMPedometer()
    lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        return manager
    }()
    var didStartSensorHardware = false
    var sensorHardwareGeneration: UInt64 = 0
    private var isStartingWorkout = false
    var workoutStartGate = TaptionWatchWorkoutStartGate()
    private let workoutLifecycleBarrier = TaptionWatchWorkoutLifecycleBarrier()
    private var pendingWorkoutFailureMessage: String?
    var workoutAwaitingPurgeDeletion: HKWorkout?
    var workoutAwaitingPurgeDeletionID: UUID?
    var workoutPurgeIdentifier: UUID?
    var workoutFinishState: TaptionWatchWorkoutFinishState = .idle
    var purgeWorkoutDeletionTask: Task<Void, Error>?
    // iPhone의 AppleSensorCollector와 동일하게 CoreMotion 콜백을 메인 큐로
    // 받는다. 백그라운드 큐로 받으면 @MainActor 클래스 안에서 선언된 핸들러가
    // 액터 격리 검사에 걸려 프로세스가 즉시 종료된다. 핸들러 본문은 값 하나를
    // 만들어 넘기는 수준이라 메인 큐 부담이 없다.
    private var session: HKWorkoutSession?
    var builder: HKLiveWorkoutBuilder?
    private(set) var linkedPlan: TaptionWatchPlanItem?
    private(set) var workoutKind: TaptionWatchWorkoutKind?
    var onSensorSummary: ((TaptionWatchSensorSummary) -> Void)?
    var onAmbientDrain: ((
        [TaptionWatchSensorSummary],
        [TaptionWatchAccelerationChunk]
    ) async -> Bool)?
    var onAccelerationChunk: ((TaptionWatchAccelerationChunk) async -> Void)?

    var sensorSessionID: UUID?
    var sensorSequence = 0
    var sensorSummaryTask: Task<Void, Never>?
    var accelerometerSum = TaptionWatchSensorVector3.zero
    var accelerometerCount = 0
    var peakAccelerationG = 0.0
    var accelerationMagnitudeMean = 0.0
    var accelerationMagnitudeM2 = 0.0
    var accelerationJerkSum = 0.0
    var previousAccelerationMagnitude: Double?
    var previousAccelerationSampleTime: TimeInterval?
    var gyroscopeSum = TaptionWatchSensorVector3.zero
    var gyroscopeCount = 0
    var peakRotationRate = 0.0
    var latestGravity: TaptionWatchSensorVector3?
    var latestUserAcceleration: TaptionWatchSensorVector3?
    var latestRotationRate: TaptionWatchSensorVector3?
    var latestAttitude: TaptionWatchSensorVector3?
    var latestPressureKilopascals: Double?
    var latestStepCount: Int?
    var latestPedometerDistanceMeters: Double?
    var latestFloorsAscended: Int?
    var latestFloorsDescended: Int?
    var averageHeartRate: Double?
    var maximumHeartRate: Double?
    var pendingRoutePoints: [TaptionWatchLocationPoint] = [] { didSet { if pendingRoutePoints.isEmpty { pendingRoutePointTimes.removeAll(keepingCapacity: true) } } }
    private var pendingRoutePointTimes = Set<Date>() // 같은 시각 점을 거른다(WCH1110A01)
    var motionSamples: [WatchMotionSample] = []
    var nextBehaviorWindowEnd: Date?
    var lastWindowStepCount = 0
    var lastWindowFloorsAscended: Int?
    var lastWindowFloorsDescended: Int?
    var lastWindowAltitudeMeters: Double?
    var lastGyroscopeSample: TaptionWatchSensorVector3?
    var pendingBehaviorSegments: [WatchBehaviorSegment] = []
    var behaviorStabilizer = WatchBehaviorStabilizer()
#if canImport(CoreML)
    lazy var behaviorModel = WatchBehaviorModel.load()
#endif
    lazy var accelerationArchive = WatchAccelerationArchive()
    var pendingAccelerationSamples: [WatchAccelerationArchiveSample] = []
    var accelerationArchiveStride = 0
    var accelerationArchiveSequence = 0
    var accelerationFlushTasks: [UUID: Task<Void, Never>] = [:]
    var lastAccelerationFlushTaskID: UUID?
    private let ambientRecorder = WatchAmbientSensorRecorder()
    private var ambientDrainTask: Task<Void, Never>?
    private var ambientArchiveSequence = 0
    private var recorderStatus = WatchAmbientRecorderStatus(
        isAvailable: false,
        isAccessDenied: false,
        drainFailureCount: 0
    )
    private var lastPublishedMeasurement: TaptionWatchMeasurementSnapshot?
    private var lastWidgetReloadAt: Date?
    var healthSyncTask: Task<Void, Never>?
    var healthSnapshotTask: Task<Void, Never>?
    var healthSnapshotTaskGeneration: UInt64?
    var nextHealthSnapshotGeneration: UInt64 = 0
    var didRequestHealthReadAuthorization = false
    var cachedSlowHealthSnapshot: (
        dayStart: Date,
        capturedAt: Date,
        sleep: [TaptionWatchSleepSegment],
        workoutCount: Int
    )?
    var onHealthSnapshot: ((TaptionWatchHealthSnapshot) -> Void)?

    override init() {
        super.init()
    }

    func dismissError() {
        errorMessage = nil
        publishMeasurement()
    }

    private var measurementSource: TaptionWatchMeasurementSource {
        if isActive { return .workout }
        guard accelerationSettings?.isEnabled == true,
              recorderStatus.isAvailable,
              !recorderStatus.isAccessDenied else {
            return .idle
        }
        return .ambient
    }

    /// 화면과 위젯이 같은 사실을 보게 만든다. 위젯 새로고침은 시스템 예산을
    /// 쓰므로, 보이는 값이 바뀌었을 때만 태운다.
    func publishMeasurement(now: Date = .now) {
        // 앱 그룹 쓰기와 위젯 새로고침도 첫 화면이 그려진 뒤로 미룬다.
        // 실행 경로에서 앱그룹·위젯 데몬을 먼저 건드리면 실기기에서만
        // 실패하는 종류의 문제가 되살아난다.
        guard isSceneReadyForCapture else { return }
        let snapshot = TaptionWatchMeasurementSnapshot(
            updatedAt: now,
            source: measurementSource,
            behavior: latestObservation?.behavior,
            confidenceScore: latestObservation?.confidenceScore ?? 0,
            measuredAt: latestObservation?.endedAt,
            isRecordingRequested: accelerationSettings?.isEnabled == true,
            isRecorderAvailable: recorderStatus.isAvailable,
            isMotionAccessDenied: recorderStatus.isAccessDenied,
            drainFailureCount: recorderStatus.drainFailureCount,
            failureMessage: errorMessage
        )
        measurement = snapshot
        guard (try? TaptionWatchMeasurementStore.write(snapshot)) != nil else {
            return
        }
        let shouldReload = TaptionWatchWidgetRefreshPolicy.shouldReload(
            previous: lastPublishedMeasurement,
            next: snapshot,
            lastReloadedAt: lastWidgetReloadAt,
            now: now
        )
        lastPublishedMeasurement = snapshot
        guard shouldReload else { return }
        lastWidgetReloadAt = now
        WidgetCenter.shared.reloadTimelines(
            ofKind: TaptionWatchWidgetKind.status
        )
    }

    func applySettings(
        acceleration: TaptionWatchAccelerationSettings?,
        dataSyncProfile: TaptionWatchDataSyncProfile?,
        commerceLocked: Bool
    ) async {
        let nextAcceleration = commerceLocked
            ? TaptionWatchAccelerationSettings(profile: .off)
            : acceleration ?? accelerationSettings
        let nextDataSyncProfile = commerceLocked
            ? .off
            : dataSyncProfile ?? self.dataSyncProfile
        guard accelerationSettings != nextAcceleration
            || self.dataSyncProfile != nextDataSyncProfile
            || isCommerceLocked != commerceLocked else {
            // 동일한 설정 payload도 12시간 창 만료 뒤 재수신될 수 있다.
            // 이때도 scene 없이 arm 정책을 다시 평가한다.
            refreshAmbientRecording(allowBeforeSceneReady: true)
            return
        }
        accelerationSettings = nextAcceleration
        self.dataSyncProfile = nextDataSyncProfile
        isCommerceLocked = commerceLocked
        workoutStartGate.setCommerceLocked(commerceLocked)
        if commerceLocked {
            ambientDrainTask?.cancel()
            await ambientDrainTask?.value
            ambientDrainTask = nil
        }
        let accelerationName = nextAcceleration?.profile.rawValue.description
            ?? "pending"
        WatchLaunchDiagnostics.mark(
            "iPhone settings acceleration=\(accelerationName) sync=\(nextDataSyncProfile.rawValue)"
        )
        // WC/background 설정 수신은 첫 scene 렌더링보다 먼저 올 수 있다.
        // CMSensorRecorder는 UI가 아니라 모션 데몬에 기록을 위임하므로
        // 이 경로에서는 scene 준비를 기다리지 않는다.
        refreshAmbientRecording(allowBeforeSceneReady: true)
        restartHealthSync()
        if commerceLocked, isActive {
            _ = await stop()
        }
    }

    func syncNow(requestID: String? = nil) async {
        let id = requestID ?? "none"
        guard !isCommerceLocked else {
            WatchLaunchDiagnostics.mark(
                "manual data sync skipped id=\(id) reason=commerce_locked"
            )
            return
        }
        guard let syncGeneration = workoutStartGate.beginHealthSync() else {
            WatchLaunchDiagnostics.mark(
                "manual data sync skipped id=\(id) reason=purge_in_progress"
            )
            return
        }
        WatchLaunchDiagnostics.mark(
            "manual data sync begin id=\(id) profile=\(dataSyncProfile.rawValue) scene_ready=\(isSceneReadyForCapture)"
        )
        cachedSlowHealthSnapshot = nil
        async let healthSync: Void = requestHealthSnapshot(
            expectedGeneration: syncGeneration
        )
        refreshAmbientRecording(allowBeforeSceneReady: true)
        await ambientDrainTask?.value
        guard workoutStartGate.accepts(syncGeneration) else {
            WatchLaunchDiagnostics.mark(
                "manual data sync skipped id=\(id) reason=workout_generation_changed"
            )
            return
        }
        WatchLaunchDiagnostics.mark(
            "manual data sync ambient complete id=\(id)"
        )
        await healthSync
        WatchLaunchDiagnostics.mark(
            "manual data sync end id=\(id)"
        )
    }

    func prepareHealthDataAccess() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            WatchLaunchDiagnostics.mark(
                "health authorization skipped reason=health_unavailable"
            )
            return
        }
        guard !didRequestHealthReadAuthorization else {
            WatchLaunchDiagnostics.mark(
                "health authorization already requested"
            )
            return
        }
        do {
            try await requestHealthReadAuthorization()
            didRequestHealthReadAuthorization = true
            WatchLaunchDiagnostics.mark("health read authorization ready")
        } catch {
            WatchLaunchDiagnostics.mark("health read authorization unavailable")
        }
    }

    func start(
        kind: TaptionWatchWorkoutKind,
        linkedPlan: TaptionWatchPlanItem?,
        sessionID requestedSessionID: UUID? = nil
    ) async -> Bool {
        guard !isCommerceLocked,
              !isActive,
              !isStartingWorkout,
              HKHealthStore.isHealthDataAvailable(),
              let startGeneration = workoutStartGate.beginStart() else {
            WatchLaunchDiagnostics.mark("workout start rejected active=\(isActive)")
            return false
        }
        workoutLifecycleBarrier.beginOperation()
        isStartingWorkout = true
        pendingWorkoutFailureMessage = nil
        defer {
            isStartingWorkout = false
            workoutLifecycleBarrier.finishOperation()
        }
        var pendingSession: HKWorkoutSession?
        var pendingBuilder: HKLiveWorkoutBuilder?
        WatchLaunchDiagnostics.mark("workout start requested kind=\(kind.rawValue)")
        do {
            try await requestAuthorization()
            guard workoutStartGate.accepts(startGeneration) else { return false }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = kind.healthKitActivityType
            configuration.locationType = .outdoor

            let newSession = try HKWorkoutSession(
                healthStore: healthStore,
                configuration: configuration
            )
            let newBuilder = newSession.associatedWorkoutBuilder()
            newBuilder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )
            newSession.delegate = self
            newBuilder.delegate = self
            pendingSession = newSession
            pendingBuilder = newBuilder

            let start = Date.now
            let sensorSessionID = requestedSessionID ?? UUID()
            let workoutPurgeIdentifier = UUID()
            session = newSession
            builder = newBuilder
            self.workoutPurgeIdentifier = workoutPurgeIdentifier
            workoutFinishState = .idle
            self.linkedPlan = linkedPlan
            workoutKind = kind
            startedAt = start
            heartRate = 0
            distanceMeters = 0
            activeEnergyKilocalories = 0

            newSession.startActivity(with: start)
            try await newBuilder.beginCollection(at: start)
            guard workoutStartGate.accepts(startGeneration) else {
                discardPendingWorkout(newSession, builder: newBuilder)
                return false
            }
            var metadata: [String: Any] = [
                TaptionWatchHealthMetadata.sensorSessionID:
                    sensorSessionID.uuidString,
                TaptionWatchHealthMetadata.workoutPurgeIdentifier:
                    workoutPurgeIdentifier.uuidString,
                HKMetadataKeyWorkoutBrandName: "BOKKI Plan",
            ]
            if let linkedPlan {
                metadata.merge([
                    TaptionWatchHealthMetadata.planID: linkedPlan.id.uuidString,
                    TaptionWatchHealthMetadata.planTitle: linkedPlan.title,
                    TaptionWatchHealthMetadata.categoryID: linkedPlan.categoryID,
                ]) { _, new in new }
            }
            try await newBuilder.addMetadata(metadata)
            guard workoutStartGate.accepts(startGeneration) else {
                discardPendingWorkout(newSession, builder: newBuilder)
                return false
            }
            isActive = true
            startSensorCollection(
                sessionID: sensorSessionID,
                startedAt: start
            )
            WatchLaunchDiagnostics.mark("workout started kind=\(kind.rawValue)")
            return true
        } catch {
            guard workoutStartGate.accepts(startGeneration) else {
                if let pendingSession, let pendingBuilder {
                    discardPendingWorkout(
                        pendingSession,
                        builder: pendingBuilder
                    )
                }
                return false
            }
            WatchLaunchDiagnostics.mark("workout start failed")
            if let pendingSession, let pendingBuilder {
                discardPendingWorkout(
                    pendingSession,
                    builder: pendingBuilder
                )
            }
            await reset(
                with: AppLanguagePreference.text("운동을 시작하지 못했습니다. \(error.localizedDescription)", "Couldn't start the workout. \(error.localizedDescription)")
            )
            return false
        }
    }

    private func discardPendingWorkout(
        _ pendingSession: HKWorkoutSession,
        builder pendingBuilder: HKLiveWorkoutBuilder
    ) {
        pendingSession.delegate = nil
        pendingBuilder.delegate = nil
        pendingSession.end()
        pendingBuilder.discardWorkout()
        if let workoutPurgeIdentifier {
            if workoutFinishState.mayHavePersistedWorkout {
                TaptionWatchWorkoutPurgeIntentStore.enqueue(
                    workoutPurgeIdentifier
                )
            } else {
                TaptionWatchWorkoutPurgeIntentStore.remove(
                    workoutPurgeIdentifier
                )
            }
        }
        clearWorkoutPurgeTracking()
        clearPendingWorkoutReferences(pendingSession, builder: pendingBuilder)
    }

    func clearWorkoutPurgeTracking() {
        workoutAwaitingPurgeDeletion = nil
        workoutAwaitingPurgeDeletionID = nil
        workoutPurgeIdentifier = nil
        workoutFinishState = .idle
    }

    private func clearPendingWorkoutReferences(
        _ pendingSession: HKWorkoutSession,
        builder pendingBuilder: HKLiveWorkoutBuilder
    ) {
        if session === pendingSession { session = nil }
        if builder === pendingBuilder { builder = nil }
        if session == nil, builder == nil {
            linkedPlan = nil
            workoutKind = nil
            startedAt = nil
            isActive = false
        }
    }

    func stop() async -> TaptionWatchPlanItem? {
        guard let session, let builder,
              let resetToken = workoutStartGate.beginReset() else { return nil }
        workoutLifecycleBarrier.beginOperation()
        defer { workoutLifecycleBarrier.finishOperation() }
        WatchLaunchDiagnostics.mark("workout stop requested")
        let linkedPlan = linkedPlan
        let end = Date.now
        let summary = await stopSensorCollection(at: end, isFinal: true)
        guard workoutStartGate.accepts(resetToken) else {
            discardPendingWorkout(session, builder: builder)
            _ = workoutStartGate.finishReset(resetToken)
            return nil
        }
        if let summary {
            onSensorSummary?(summary)
        }
        session.end()
        do {
            try await builder.endCollection(at: end)
            guard workoutStartGate.accepts(resetToken) else {
                discardPendingWorkout(session, builder: builder)
                _ = workoutStartGate.finishReset(resetToken)
                return nil
            }
            workoutFinishState = .finishing
            let finishedWorkout = try await builder.finishWorkout()
            workoutFinishState = TaptionWatchWorkoutFinishState.successfulFinish(
                sampleAvailable: finishedWorkout != nil
            )
            workoutAwaitingPurgeDeletion = finishedWorkout
            workoutAwaitingPurgeDeletionID = finishedWorkout == nil
                ? nil
                : workoutPurgeIdentifier
            guard workoutStartGate.accepts(resetToken) else {
                if workoutStartGate.isPurging,
                   workoutFinishState.mayHavePersistedWorkout,
                   let workoutPurgeIdentifier {
                    TaptionWatchWorkoutPurgeIntentStore.enqueue(
                        workoutPurgeIdentifier
                    )
                    do {
                        try await deletePendingWorkoutForPurge()
                    } catch {
                        WatchLaunchDiagnostics.mark(
                            "purge workout deletion deferred error=\(error.localizedDescription)"
                        )
                    }
                } else {
                    clearWorkoutPurgeTracking()
                }
                session.delegate = nil
                builder.delegate = nil
                clearPendingWorkoutReferences(session, builder: builder)
                _ = workoutStartGate.finishReset(resetToken)
                return nil
            }
            WatchLaunchDiagnostics.mark("workout stopped")
            return await reset(using: resetToken) ? linkedPlan : nil
        } catch {
            if workoutFinishState == .finishing {
                workoutFinishState = .failedMayHavePersisted
                if let workoutPurgeIdentifier {
                    TaptionWatchWorkoutPurgeIntentStore.enqueue(
                        workoutPurgeIdentifier
                    )
                }
            } else {
                builder.discardWorkout() // 수집을 끝내지 못했으면 폐기한다(WCH1110A01)
            }
            guard workoutStartGate.accepts(resetToken) else {
                discardPendingWorkout(session, builder: builder)
                _ = workoutStartGate.finishReset(resetToken)
                return nil
            }
            WatchLaunchDiagnostics.mark("workout stop failed")
            let didReset = await reset(
                with: AppLanguagePreference.text("운동 저장을 완료하지 못했습니다. \(error.localizedDescription)", "Couldn't finish saving the workout. \(error.localizedDescription)"),
                using: resetToken
            )
            return didReset ? linkedPlan : nil
        }
    }

    func deleteAllLocalData(
        deleteWatchDatabase: @MainActor () async throws -> Void
    ) async -> Bool {
        let purgeID = workoutStartGate.beginPurge()
        defer { workoutStartGate.endPurge(purgeID) }
        if workoutFinishState.mayHavePersistedWorkout,
           let workoutPurgeIdentifier {
            TaptionWatchWorkoutPurgeIntentStore.enqueue(workoutPurgeIdentifier)
        }
        await workoutLifecycleBarrier.waitUntilIdle()
        do {
            try await deletePendingWorkoutForPurge()
        } catch {
            WatchLaunchDiagnostics.mark(
                "local purge failed workout deletion error=\(error.localizedDescription)"
            )
            return false
        }
        stopSensorHardware()
        ambientDrainTask?.cancel()
        await ambientDrainTask?.value
        ambientDrainTask = nil
        let periodicHealthTask = healthSyncTask
        periodicHealthTask?.cancel()
        healthSyncTask = nil
        healthSnapshotTask?.cancel()
        await healthSnapshotTask?.value
        healthSnapshotTask = nil
        healthSnapshotTaskGeneration = nil
        await periodicHealthTask?.value
        let summaryTask = sensorSummaryTask
        summaryTask?.cancel()
        await summaryTask?.value
        sensorSummaryTask = nil
        let accelerationTasks = Array(accelerationFlushTasks.values)
        accelerationTasks.forEach { $0.cancel() }
        for task in accelerationTasks { await task.value }
        accelerationFlushTasks.removeAll(keepingCapacity: false)
        lastAccelerationFlushTaskID = nil
        session?.delegate = nil
        builder?.delegate = nil
        session?.end()
        builder?.discardWorkout()
        session = nil
        builder = nil
        do {
            try await TaptionWatchPurgeSequence.run(
                deleteDatabase: deleteWatchDatabase,
                deleteManagerStores: {
                    try await accelerationArchive.deleteAll()
                    await ambientRecorder.deleteAll()
                }
            )
            linkedPlan = nil
            workoutKind = nil
            startedAt = nil
            isActive = false
            pendingWorkoutFailureMessage = nil
            clearWorkoutPurgeTracking()
            pendingAccelerationSamples.removeAll(keepingCapacity: false)
            pendingRoutePoints.removeAll(keepingCapacity: false)
            pendingBehaviorSegments.removeAll(keepingCapacity: false)
            motionSamples.removeAll(keepingCapacity: false)
            latestObservation = nil
            sensorSampleCount = 0
            accelerationSettings = nil
            dataSyncProfile = .off
            measurement = TaptionWatchMeasurementSnapshot()
            return true
        } catch {
            WatchLaunchDiagnostics.mark(
                "local purge failed error=\(error.localizedDescription)"
            )
            return false
        }
    }

    /// Sensor hardware must never start before the first scene transaction
    /// commits; the dispatch precondition trap it triggers kills the app at
    /// launch on real hardware. The first view flips this from its .task.
    private var isSceneReadyForCapture = false

    func beginCaptureAfterFirstRender() {
        guard !isSceneReadyForCapture else { return }
        isSceneReadyForCapture = true
        refreshAmbientRecording()
    }

    /// 앱이 실행되는 모든 경로에서 호출한다. 기록 자체는 모션 데몬이 계속
    /// 이어가므로 앱이 할 일은 (1) 기록을 다시 걸고 (2) 지난 실행 이후
    /// 쌓인 표본을 비우는 것뿐이다.
    private func refreshAmbientRecording(allowBeforeSceneReady: Bool = false) {
        guard workoutStartGate.allowsAmbientRecording else {
            WatchLaunchDiagnostics.mark(
                "ambient refresh skipped reason=workout_transition"
            )
            return
        }
        guard !isCommerceLocked else {
            publishMeasurement()
            return
        }
        guard isSceneReadyForCapture || allowBeforeSceneReady else {
            WatchLaunchDiagnostics.mark(
                "ambient refresh skipped reason=scene_not_ready"
            )
            publishMeasurement()
            return
        }
        guard ambientDrainTask == nil else {
            WatchLaunchDiagnostics.mark(
                "ambient refresh skipped reason=drain_in_progress"
            )
            publishMeasurement()
            return
        }
        // 기록이 꺼져 있어도 기록기 상태는 읽는다. 상태 조회는 클래스
        // 메서드라 기록을 시작하지 않는다. 화면과 위젯이 "왜 안 재는지"를
        // 말할 수 있어야 한다.
        let isEnabled = accelerationSettings?.isEnabled == true
        WatchLaunchDiagnostics.mark(
            "ambient refresh enabled=\(isEnabled)"
        )
        ambientDrainTask = Task { [weak self] in
            guard let self else { return }
            let recorder = self.ambientRecorder
            if isEnabled {
                await recorder.arm()
                let result = await recorder.drain()
                guard !Task.isCancelled, !self.isCommerceLocked else {
                    self.ambientDrainTask = nil
                    return
                }
                self.recorderStatus = await recorder.status()
                WatchLaunchDiagnostics.mark(
                    "ambient drain summaries=\(result.summaries.count) samples=\(result.archiveSamples.count)"
                )
                // 남은 창은 화면이 켜져 있을 때만 이어서 비운다(백그라운드는 다음 실행에).
                if await self.applyAmbientDrain(result), result.hasMoreWindows, self.isSceneReadyForCapture, !Task.isCancelled { self.ambientDrainTask = nil; self.refreshAmbientRecording(); return }
            } else {
                self.recorderStatus = await recorder.status()
                WatchLaunchDiagnostics.mark("ambient recording disabled")
                self.publishMeasurement()
            }
            self.ambientDrainTask = nil
        }
    }

    private func applyAmbientDrain(_ result: WatchAmbientDrainResult) async -> Bool { // 처리 위치를 커밋했으면 true
        guard !isCommerceLocked, !Task.isCancelled else { return false }
        var canCommitWatermark = onAmbientDrain != nil
        if !result.archiveSamples.isEmpty {
            let archive = accelerationArchive
            let samples = result.archiveSamples.enumerated().map { index, value in
                WatchAccelerationArchiveSample(
                    id: value.id,
                    capturedAt: value.capturedAt,
                    acceleration: value.acceleration,
                    sessionID: value.sessionID,
                    sequence: value.sequence == 0
                        ? ambientArchiveSequence + index + 1
                        : value.sequence,
                    isAmbient: true
                )
            }
            ambientArchiveSequence += samples.count
            do {
                try await archive.append(samples)
            } catch {
                canCommitWatermark = false
                WatchLaunchDiagnostics.mark(
                    "ambient archive append failed \(error.localizedDescription)"
                )
            }
        }
        let waterLockEnabled = WKInterfaceDevice.current().isWaterLockEnabled
        let now = Date.now
        var sampleCursor = 0
        var summaries: [TaptionWatchSensorSummary] = []
        var chunks: [TaptionWatchAccelerationChunk] = []
        summaries.reserveCapacity(result.summaries.count)
        chunks.reserveCapacity(result.summaries.count)
        for var summary in result.summaries {
            // CMSensorRecorder의 과거 표본에는 당시 Water Lock 값이 없다.
            // 방금 끝난 창에만 현재 상태를 결합해 과거 샤워를 오인하지 않는다.
            if abs(now.timeIntervalSince(summary.endedAt)) <= 3 * 60 {
                summary.waterLockEnabled = waterLockEnabled
            }
            while sampleCursor < result.archiveSamples.count,
                  result.archiveSamples[sampleCursor].capturedAt
                    < summary.startedAt {
                sampleCursor += 1
            }
            let firstSample = sampleCursor
            while sampleCursor < result.archiveSamples.count,
                  result.archiveSamples[sampleCursor].capturedAt
                    <= summary.endedAt {
                sampleCursor += 1
            }
            let samples = result.archiveSamples[firstSample..<sampleCursor]
                .enumerated()
                .map { index, value in
                    WatchAccelerationArchiveSample(
                        id: value.id,
                        capturedAt: value.capturedAt,
                        acceleration: value.acceleration,
                        sessionID: summary.sessionID,
                        sequence: value.sequence == 0 ? index + 1 : value.sequence,
                        isAmbient: true
                    )
            }
            if let first = samples.first, let last = samples.last {
                chunks.append(
                    TaptionWatchAccelerationChunk(
                        id: TaptionWatchStableID.ambientAccelerationChunkID(
                            sessionID: summary.sessionID,
                            sequence: summary.sequence,
                            revision: 0
                        ),
                        sessionID: summary.sessionID,
                        sequence: summary.sequence,
                        startedAt: first.capturedAt,
                        endedAt: last.capturedAt,
                        isAmbient: true,
                        samples: samples,
                        ambientWindowStart: summary.ambientWindowStart
                    )
                )
            }
            summaries.append(summary)
        }
        if let onAmbientDrain {
            canCommitWatermark = await onAmbientDrain(summaries, chunks)
                && canCommitWatermark
        } else {
            canCommitWatermark = false
            for chunk in chunks {
                await onAccelerationChunk?(chunk)
            }
            summaries.forEach { onSensorSummary?($0) }
        }
        if canCommitWatermark {
            await ambientRecorder.commit(highWater: result.pendingHighWater)
        }
        if let latest = summaries.last, let behavior = latest.behavior {
            latestObservation = WatchActivityObservation(
                behavior: behavior,
                confidenceScore: latest.behaviorConfidenceScore ?? 0,
                startedAt: latest.startedAt,
                endedAt: latest.endedAt
            )
        }
        publishMeasurement()
        return canCommitWatermark
    }

    @discardableResult
    private func reset(
        with message: String? = nil,
        using existingToken: TaptionWatchWorkoutStartGate.ResetToken? = nil
    ) async -> Bool {
        let resetToken: TaptionWatchWorkoutStartGate.ResetToken
        if let existingToken {
            resetToken = existingToken
        } else {
            guard let token = workoutStartGate.beginReset() else {
                if let message, !workoutStartGate.isPurging {
                    pendingWorkoutFailureMessage = message
                }
                return false
            }
            resetToken = token
        }
        guard workoutStartGate.accepts(resetToken) else {
            _ = workoutStartGate.finishReset(resetToken)
            return false
        }
        workoutLifecycleBarrier.beginOperation()
        defer { workoutLifecycleBarrier.finishOperation() }
        let summary = await stopSensorCollection(at: .now, isFinal: true)
        guard workoutStartGate.accepts(resetToken) else {
            _ = workoutStartGate.finishReset(resetToken)
            return false
        }
        let resetMessage = pendingWorkoutFailureMessage ?? message
        pendingWorkoutFailureMessage = nil
        if resetMessage != nil {
            WatchLaunchDiagnostics.mark("workout reset with error")
        }
        if let summary {
            onSensorSummary?(summary)
        }
        session?.delegate = nil
        builder?.delegate = nil
        session = nil
        builder = nil
        linkedPlan = nil
        workoutKind = nil
        startedAt = nil
        isActive = false
        sensorSampleCount = 0
        latestRelativeAltitudeMeters = nil
        errorMessage = resetMessage
        let shouldResumeAmbient = workoutStartGate.finishReset(resetToken)
        if shouldResumeAmbient {
            clearWorkoutPurgeTracking()
            refreshAmbientRecording()
        }
        return true
    }
}

extension WatchWorkoutManager: CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let points = locations
            .filter {
                let age = Date.now.timeIntervalSince($0.timestamp)
                return CLLocationCoordinate2DIsValid($0.coordinate)
                    && $0.horizontalAccuracy.isFinite
                    && $0.horizontalAccuracy >= 0
                    && $0.horizontalAccuracy <= 50
                    && age >= -5
                    && age < 5 * 60
            }
            .sorted { $0.timestamp < $1.timestamp }
            .map {
                TaptionWatchLocationPoint(
                    id: UUID(),
                    capturedAt: $0.timestamp,
                    latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude,
                    altitude: $0.altitude,
                    horizontalAccuracy: $0.horizontalAccuracy,
                    verticalAccuracy: $0.verticalAccuracy,
                    speedMetersPerSecond: $0.speed >= 0 ? $0.speed : nil,
                    courseDegrees: $0.course >= 0 ? $0.course : nil
                )
            }
        Task { @MainActor [weak self] in
            guard let self,
                  self.didStartSensorHardware,
                  self.sensorSessionID != nil,
                  let workoutStartedAt = self.startedAt else { return }
            for point in points where point.belongs(
                toWorkoutStartingAt: workoutStartedAt
            ) && self.pendingRoutePointTimes.insert(point.capturedAt).inserted {
                self.pendingRoutePoints.append(point)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.isActive else { return }
            if self.locationManager.authorizationStatus == .authorizedAlways
                || self.locationManager.authorizationStatus == .authorizedWhenInUse {
                self.locationManager.startUpdatingLocation()
            }
        }
    }
}

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {}

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: any Error
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let currentSession = self.session,
                  currentSession === workoutSession else {
                workoutSession.delegate = nil
                return
            }
            await self.salvageWorkoutAfterFailure() // 그때까지 잰 운동을 저장하거나 폐기한다(WCH1110A01)
            await self.reset(
                with: AppLanguagePreference.text("운동 측정이 중단됐습니다. \(error.localizedDescription)", "Workout tracking stopped. \(error.localizedDescription)")
            )
        }
    }
}

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(
        _ workoutBuilder: HKLiveWorkoutBuilder
    ) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        Task { @MainActor [weak self] in
            self?.updateStatistics(for: collectedTypes)
        }
    }
}

private extension TaptionWatchWorkoutKind {
    var healthKitActivityType: HKWorkoutActivityType {
        switch self {
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        }
    }
}

extension TaptionWatchSensorVector3 {
    static let zero = TaptionWatchSensorVector3(x: 0, y: 0, z: 0)

    mutating func add(_ other: TaptionWatchSensorVector3) {
        x += other.x
        y += other.y
        z += other.z
    }

    func divided(by divisor: Double) -> TaptionWatchSensorVector3 {
        guard divisor != 0 else { return .zero }
        return TaptionWatchSensorVector3(
            x: x / divisor,
            y: y / divisor,
            z: z / divisor
        )
    }
}
