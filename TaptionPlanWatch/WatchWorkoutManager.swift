import CoreMotion
import CoreLocation
import Foundation
import HealthKit
import WatchKit
import WidgetKit

private final class WatchHealthQueryCancellation<Value: Sendable>: @unchecked Sendable {
    private let healthStore: HKHealthStore
    private let cancellationValue: Value
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var query: HKQuery?
    private var finished = false

    init(healthStore: HKHealthStore, cancellationValue: Value) {
        self.healthStore = healthStore
        self.cancellationValue = cancellationValue
    }

    func setContinuation(
        _ continuation: CheckedContinuation<Value, Never>
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(returning: cancellationValue)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setQuery(_ query: HKQuery) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        self.query = query
        return true
    }

    func execute() {
        lock.lock()
        guard !finished, let query else {
            lock.unlock()
            return
        }
        lock.unlock()
        healthStore.execute(query)
    }

    func finish(_ value: Value) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        query = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func cancel() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let query = query
        self.query = nil
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        if let query {
            healthStore.stop(query)
        }
        continuation?.resume(returning: cancellationValue)
    }
}

private typealias WatchAccelerationArchiveSample = TaptionWatchAccelerationSample

private actor WatchAccelerationArchive {
    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let calendar = Calendar(identifier: .gregorian)
    private let retentionInterval: TimeInterval = 31 * 86_400

    init(fileManager: FileManager = .default) {
        let root = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? URL.temporaryDirectory
        directoryURL = root.appendingPathComponent(
            "TaptionPlan/Acceleration",
            isDirectory: true
        )
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
    }

    func append(_ samples: [WatchAccelerationArchiveSample]) throws {
        guard !samples.isEmpty else { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directoryURL.path
        )
        let grouped = Dictionary(grouping: samples) {
            monthKey(for: $0.capturedAt)
        }
        for (month, values) in grouped {
            let url = directoryURL.appendingPathComponent(
                "watch-acceleration-\(month).jsonl"
            )
            let lines = try values.map { sample in
                var data = try encoder.encode(sample)
                data.append(0x0A)
                return data
            }
            let payload = lines.reduce(into: Data()) { result, line in
                result.append(line)
            }
            if let handle = FileHandle(forWritingAtPath: url.path) {
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: url.path
                )
                handle.seekToEndOfFile()
                handle.write(payload)
                handle.closeFile()
            } else {
                try payload.write(
                    to: url,
                    options: [
                        .atomic,
                        .completeFileProtectionUntilFirstUserAuthentication,
                    ]
                )
            }
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        }
        try prune()
    }

    func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: directoryURL)
    }

    private func monthKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    private func prune() throws {
        let cutoff = Date.now.addingTimeInterval(-retentionInterval)
        let files = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        let parser = DateFormatter()
        parser.calendar = calendar
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        for file in files where file.pathExtension == "jsonl" {
            let name = file.deletingPathExtension().lastPathComponent
            let parts = name.split(separator: "-")
            guard parts.count >= 2 else { continue }
            let month = "\(parts[parts.count - 2])-\(parts[parts.count - 1])"
            guard let date = parser.date(from: "\(month)-01") else {
                continue
            }
            let monthEnd = calendar.date(byAdding: .month, value: 1, to: date) ?? date
            if monthEnd < cutoff {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}

/// 시스템이 지금 무엇을 하고 있다고 보는지. 워치 화면의 확인 카드가 이
/// 값을 그대로 보여주고, 사용자의 정정 결과를 iPhone으로 돌려보낸다.
struct WatchActivityObservation: Hashable, Sendable {
    var behavior: WatchBehaviorKind
    var confidenceScore: Double
    var startedAt: Date
    var endedAt: Date
}

@MainActor
final class WatchWorkoutManager: NSObject, ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var latestObservation: WatchActivityObservation?
    @Published private(set) var startedAt: Date?
    @Published private(set) var heartRate = 0.0
    @Published private(set) var distanceMeters = 0.0
    @Published private(set) var activeEnergyKilocalories = 0.0
    @Published private(set) var sensorSampleCount = 0
    @Published private(set) var latestRelativeAltitudeMeters: Double?
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
    private lazy var healthStore = HKHealthStore()
    private lazy var motionManager = CMMotionManager()
    private lazy var altimeter = CMAltimeter()
    private lazy var pedometer = CMPedometer()
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        return manager
    }()
    private var didStartSensorHardware = false
    private var sensorHardwareGeneration: UInt64 = 0
    // iPhone의 AppleSensorCollector와 동일하게 CoreMotion 콜백을 메인 큐로
    // 받는다. 백그라운드 큐로 받으면 @MainActor 클래스 안에서 선언된 핸들러가
    // 액터 격리 검사에 걸려 프로세스가 즉시 종료된다. 핸들러 본문은 값 하나를
    // 만들어 넘기는 수준이라 메인 큐 부담이 없다.
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private(set) var linkedPlan: TaptionWatchPlanItem?
    private(set) var workoutKind: TaptionWatchWorkoutKind?
    var onSensorSummary: ((TaptionWatchSensorSummary) -> Void)?
    var onAmbientDrain: ((
        [TaptionWatchSensorSummary],
        [TaptionWatchAccelerationChunk]
    ) async -> Bool)?
    var onAccelerationChunk: ((TaptionWatchAccelerationChunk) async -> Void)?

    private var sensorSessionID: UUID?
    private var sensorSequence = 0
    private var sensorSummaryTask: Task<Void, Never>?
    private var accelerometerSum = TaptionWatchSensorVector3.zero
    private var accelerometerCount = 0
    private var peakAccelerationG = 0.0
    private var accelerationMagnitudeMean = 0.0
    private var accelerationMagnitudeM2 = 0.0
    private var accelerationJerkSum = 0.0
    private var previousAccelerationMagnitude: Double?
    private var previousAccelerationSampleTime: TimeInterval?
    private var gyroscopeSum = TaptionWatchSensorVector3.zero
    private var gyroscopeCount = 0
    private var peakRotationRate = 0.0
    private var latestGravity: TaptionWatchSensorVector3?
    private var latestUserAcceleration: TaptionWatchSensorVector3?
    private var latestRotationRate: TaptionWatchSensorVector3?
    private var latestAttitude: TaptionWatchSensorVector3?
    private var latestPressureKilopascals: Double?
    private var latestStepCount: Int?
    private var latestPedometerDistanceMeters: Double?
    private var latestFloorsAscended: Int?
    private var latestFloorsDescended: Int?
    private var averageHeartRate: Double?
    private var maximumHeartRate: Double?
    private var pendingRoutePoints: [TaptionWatchLocationPoint] = []
    private var motionSamples: [WatchMotionSample] = []
    private var nextBehaviorWindowEnd: Date?
    private var lastWindowStepCount = 0
    private var lastWindowFloorsAscended: Int?
    private var lastWindowFloorsDescended: Int?
    private var lastWindowAltitudeMeters: Double?
    private var lastGyroscopeSample: TaptionWatchSensorVector3?
    private var pendingBehaviorSegments: [WatchBehaviorSegment] = []
    private var lastBehaviorKind: WatchBehaviorKind?
    private var lastBehaviorConfidence = 0.0
#if canImport(CoreML)
    private lazy var behaviorModel = WatchBehaviorModel.load()
#endif
    private lazy var accelerationArchive = WatchAccelerationArchive()
    private var pendingAccelerationSamples: [WatchAccelerationArchiveSample] = []
    private var accelerationArchiveStride = 0
    private var accelerationArchiveSequence = 0
    private var accelerationFlushTasks: [UUID: Task<Void, Never>] = [:]
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
    private var healthSyncTask: Task<Void, Never>?
    private var healthSnapshotTask: Task<Void, Never>?
    private var healthSnapshotTaskGeneration: UInt64?
    private var nextHealthSnapshotGeneration: UInt64 = 0
    private var didRequestHealthReadAuthorization = false
    private var cachedSlowHealthSnapshot: (
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
    private func publishMeasurement(now: Date = .now) {
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
        WatchLaunchDiagnostics.mark(
            "manual data sync begin id=\(id) profile=\(dataSyncProfile.rawValue) scene_ready=\(isSceneReadyForCapture)"
        )
        refreshAmbientRecording(allowBeforeSceneReady: true)
        await ambientDrainTask?.value
        WatchLaunchDiagnostics.mark(
            "manual data sync ambient complete id=\(id)"
        )
        cachedSlowHealthSnapshot = nil
        await requestHealthSnapshot()
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
              HKHealthStore.isHealthDataAvailable() else {
            WatchLaunchDiagnostics.mark("workout start rejected active=\(isActive)")
            return false
        }
        WatchLaunchDiagnostics.mark("workout start requested kind=\(kind.rawValue)")
        do {
            try await requestAuthorization()
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

            let start = Date.now
            let sensorSessionID = requestedSessionID ?? UUID()
            session = newSession
            builder = newBuilder
            self.linkedPlan = linkedPlan
            workoutKind = kind
            startedAt = start
            heartRate = 0
            distanceMeters = 0
            activeEnergyKilocalories = 0

            newSession.startActivity(with: start)
            try await newBuilder.beginCollection(at: start)
            var metadata: [String: Any] = [
                TaptionWatchHealthMetadata.sensorSessionID:
                    sensorSessionID.uuidString,
                HKMetadataKeyWorkoutBrandName: "Taption Plan",
            ]
            if let linkedPlan {
                metadata.merge([
                    TaptionWatchHealthMetadata.planID: linkedPlan.id.uuidString,
                    TaptionWatchHealthMetadata.planTitle: linkedPlan.title,
                    TaptionWatchHealthMetadata.categoryID: linkedPlan.categoryID,
                ]) { _, new in new }
            }
            try await newBuilder.addMetadata(metadata)
            isActive = true
            startSensorCollection(
                sessionID: sensorSessionID,
                startedAt: start
            )
            WatchLaunchDiagnostics.mark("workout started kind=\(kind.rawValue)")
            return true
        } catch {
            WatchLaunchDiagnostics.mark("workout start failed")
            await reset(
                with: "운동을 시작하지 못했습니다. \(error.localizedDescription)"
            )
            return false
        }
    }

    func stop() async -> TaptionWatchPlanItem? {
        guard let session, let builder else { return nil }
        WatchLaunchDiagnostics.mark("workout stop requested")
        let linkedPlan = linkedPlan
        let end = Date.now
        if let summary = await stopSensorCollection(at: end, isFinal: true) {
            onSensorSummary?(summary)
        }
        session.end()
        do {
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
            WatchLaunchDiagnostics.mark("workout stopped")
            await reset()
        } catch {
            WatchLaunchDiagnostics.mark("workout stop failed")
            await reset(
                with: "운동 저장을 완료하지 못했습니다. \(error.localizedDescription)"
            )
        }
        return linkedPlan
    }

    func deleteAllLocalData() async -> Bool {
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
        sensorSummaryTask?.cancel()
        sensorSummaryTask = nil
        let accelerationTasks = Array(accelerationFlushTasks.values)
        accelerationTasks.forEach { $0.cancel() }
        for task in accelerationTasks { await task.value }
        accelerationFlushTasks.removeAll(keepingCapacity: false)
        session?.delegate = nil
        builder?.delegate = nil
        session?.end()
        builder?.discardWorkout()
        stopSensorHardware()
        session = nil
        builder = nil
        linkedPlan = nil
        workoutKind = nil
        startedAt = nil
        isActive = false
        pendingAccelerationSamples.removeAll(keepingCapacity: false)
        pendingRoutePoints.removeAll(keepingCapacity: false)
        pendingBehaviorSegments.removeAll(keepingCapacity: false)
        motionSamples.removeAll(keepingCapacity: false)
        latestObservation = nil
        sensorSampleCount = 0
        accelerationSettings = nil
        dataSyncProfile = .off
        measurement = TaptionWatchMeasurementSnapshot()
        do {
            try await accelerationArchive.deleteAll()
            await ambientRecorder.deleteAll()
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
                await self.applyAmbientDrain(result)
            } else {
                self.recorderStatus = await recorder.status()
                WatchLaunchDiagnostics.mark("ambient recording disabled")
                self.publishMeasurement()
            }
            self.ambientDrainTask = nil
        }
    }

    private func applyAmbientDrain(_ result: WatchAmbientDrainResult) async {
        guard !isCommerceLocked, !Task.isCancelled else { return }
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
                        id: Self.ambientChunkID(
                            sessionID: summary.sessionID,
                            sequence: summary.sequence
                        ),
                        sessionID: summary.sessionID,
                        sequence: summary.sequence,
                        startedAt: first.capturedAt,
                        endedAt: last.capturedAt,
                        isAmbient: true,
                        samples: samples
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
    }

    private static func ambientChunkID(
        sessionID: UUID,
        sequence: Int
    ) -> UUID {
        var bytes = withUnsafeBytes(of: sessionID) { Array($0) }
        let value = UInt32(truncatingIfNeeded: sequence)
        bytes[12] = UInt8((value >> 24) & 0xff)
        bytes[13] = UInt8((value >> 16) & 0xff)
        bytes[14] = UInt8((value >> 8) & 0xff)
        bytes[15] = UInt8(value & 0xff)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func restartHealthSync() {
        healthSnapshotTask?.cancel()
        healthSnapshotTask = nil
        healthSnapshotTaskGeneration = nil
        healthSyncTask?.cancel()
        healthSyncTask = nil
        guard !isCommerceLocked, dataSyncProfile.interval > 0 else { return }
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

    private func requestHealthSnapshot() async {
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

    private func requestAuthorization() async throws {
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
            (watchSleepSegments, workouts) = await (sleep, workoutTotal)
            guard !Task.isCancelled else { return }
            cachedSlowHealthSnapshot = (
                dayStart: dayStart,
                capturedAt: now,
                sleep: watchSleepSegments,
                workoutCount: workouts
            )
        }
        guard !Task.isCancelled else { return }
        let watchSleepMinutes = watchSleepSegments
            .filter {
                ["core", "deep", "rem", "asleepUnspecified"]
                    .contains($0.stage)
            }
            .reduce(0) {
                $0 + $1.endDate.timeIntervalSince($1.startDate)
            } / 60
        let snapshot = TaptionWatchHealthSnapshot(
            capturedAt: now,
            dayStart: dayStart,
            activeEnergyKilocalories: await energy,
            exerciseMinutes: await exercise,
            standHours: (await stand).map { $0 / 60 },
            sleepMinutes: watchSleepMinutes > 0 ? watchSleepMinutes : nil,
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

    private func requestHealthReadAuthorization() async throws {
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

    private func sleepSegments(in span: DateInterval) async -> [TaptionWatchSleepSegment] {
        guard let type = HKObjectType.categoryType(
            forIdentifier: .sleepAnalysis
        ) else { return [] }
        let predicate = HKQuery.predicateForSamples(
            withStart: span.start,
            end: span.end,
            options: []
        )
        let handle = WatchHealthQueryCancellation<[TaptionWatchSleepSegment]>(
            healthStore: healthStore,
            cancellationValue: []
        )
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                handle.setContinuation(continuation)
                let query = HKSampleQuery(
                    sampleType: type,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { @Sendable _, samples, _ in
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

    private func workoutCount(in span: DateInterval) async -> Int {
        let predicate = HKQuery.predicateForSamples(
            withStart: span.start,
            end: span.end,
            options: .strictStartDate
        )
        let handle = WatchHealthQueryCancellation<Int>(
            healthStore: healthStore,
            cancellationValue: 0
        )
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                handle.setContinuation(continuation)
                let query = HKSampleQuery(
                    sampleType: HKObjectType.workoutType(),
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { @Sendable _, samples, _ in
                    handle.finish(samples?.count ?? 0)
                }
                guard handle.setQuery(query) else { return }
                handle.execute()
            }
        }, onCancel: {
            handle.cancel()
        })
    }

    private func updateStatistics(for types: Set<HKSampleType>) {
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

    private func reset(with message: String? = nil) async {
        if message != nil {
            WatchLaunchDiagnostics.mark("workout reset with error")
        }
        if let summary = await stopSensorCollection(at: .now, isFinal: true) {
            onSensorSummary?(summary)
        }
        session = nil
        builder = nil
        linkedPlan = nil
        workoutKind = nil
        startedAt = nil
        isActive = false
        sensorSampleCount = 0
        latestRelativeAltitudeMeters = nil
        errorMessage = message
        refreshAmbientRecording()
    }

    private func startSensorCollection(
        sessionID: UUID,
        startedAt: Date
    ) {
        stopSensorHardware()
        sensorSessionID = sessionID
        sensorSequence = 0
        accelerometerSum = .zero
        accelerometerCount = 0
        peakAccelerationG = 0
        accelerationMagnitudeMean = 0
        accelerationMagnitudeM2 = 0
        accelerationJerkSum = 0
        previousAccelerationMagnitude = nil
        previousAccelerationSampleTime = nil
        gyroscopeSum = .zero
        gyroscopeCount = 0
        peakRotationRate = 0
        latestGravity = nil
        latestUserAcceleration = nil
        latestRotationRate = nil
        latestAttitude = nil
        latestRelativeAltitudeMeters = nil
        latestPressureKilopascals = nil
        latestStepCount = nil
        latestPedometerDistanceMeters = nil
        latestFloorsAscended = nil
        latestFloorsDescended = nil
        averageHeartRate = nil
        maximumHeartRate = nil
        pendingRoutePoints = []
        motionSamples = []
        nextBehaviorWindowEnd = nil
        lastWindowStepCount = 0
        lastWindowFloorsAscended = nil
        lastWindowFloorsDescended = nil
        lastWindowAltitudeMeters = nil
        lastGyroscopeSample = nil
        pendingBehaviorSegments = []
        lastBehaviorKind = nil
        lastBehaviorConfidence = 0
        sensorSampleCount = 0
        pendingAccelerationSamples = []
        accelerationArchiveStride = 0
        accelerationArchiveSequence = 0

        // 명시적 운동은 실시간 값이 필요하므로 25Hz 라이브 업데이트를 쓴다.
        // 주변 기록은 CMSensorRecorder가 대신 맡는다.
        let updateInterval: TimeInterval = 0.04
        sensorHardwareGeneration &+= 1
        let generation = sensorHardwareGeneration
        didStartSensorHardware = true
        if motionManager.isAccelerometerAvailable
            && !motionManager.isDeviceMotionAvailable {
            motionManager.accelerometerUpdateInterval = updateInterval
            motionManager.startAccelerometerUpdates(
                to: .main
            ) { @Sendable [weak self] data, _ in
                guard let data else { return }
                let value = TaptionWatchSensorVector3(
                    x: data.acceleration.x,
                    y: data.acceleration.y,
                    z: data.acceleration.z
                )
                let timestamp = data.timestamp
                let capturedAt = Date.now
                MainActor.assumeIsolated {
                    guard let self,
                          self.didStartSensorHardware,
                          self.sensorHardwareGeneration == generation,
                          self.sensorSessionID == sessionID else { return }
                    self.recordAccelerometer(
                        value,
                        timestamp: timestamp,
                        capturedAt: capturedAt
                    )
                }
            }
        }
        if motionManager.isGyroAvailable
            && !motionManager.isDeviceMotionAvailable {
            motionManager.gyroUpdateInterval = updateInterval
            motionManager.startGyroUpdates(
                to: .main
            ) { @Sendable [weak self] data, _ in
                guard let data else { return }
                let value = TaptionWatchSensorVector3(
                    x: data.rotationRate.x,
                    y: data.rotationRate.y,
                    z: data.rotationRate.z
                )
                MainActor.assumeIsolated {
                    guard let self,
                          self.didStartSensorHardware,
                          self.sensorHardwareGeneration == generation,
                          self.sensorSessionID == sessionID else { return }
                    self.recordGyroscope(value)
                }
            }
        }
        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = updateInterval
            motionManager.startDeviceMotionUpdates(
                to: .main
            ) { @Sendable [weak self] data, _ in
                guard let data else { return }
                let gravity = TaptionWatchSensorVector3(
                    x: data.gravity.x,
                    y: data.gravity.y,
                    z: data.gravity.z
                )
                let acceleration = TaptionWatchSensorVector3(
                    x: data.userAcceleration.x,
                    y: data.userAcceleration.y,
                    z: data.userAcceleration.z
                )
                let totalAcceleration = TaptionWatchSensorVector3(
                    x: data.gravity.x + data.userAcceleration.x,
                    y: data.gravity.y + data.userAcceleration.y,
                    z: data.gravity.z + data.userAcceleration.z
                )
                let rotation = TaptionWatchSensorVector3(
                    x: data.rotationRate.x,
                    y: data.rotationRate.y,
                    z: data.rotationRate.z
                )
                let attitude = TaptionWatchSensorVector3(
                    x: data.attitude.roll,
                    y: data.attitude.pitch,
                    z: data.attitude.yaw
                )
                let timestamp = data.timestamp
                let capturedAt = Date.now
                MainActor.assumeIsolated {
                    guard let self,
                          self.didStartSensorHardware,
                          self.sensorHardwareGeneration == generation,
                          self.sensorSessionID == sessionID else { return }
                    self.latestGravity = gravity
                    self.latestUserAcceleration = acceleration
                    self.latestRotationRate = rotation
                    self.latestAttitude = attitude
                    self.recordAccelerometer(
                        totalAcceleration,
                        timestamp: timestamp,
                        capturedAt: capturedAt
                    )
                    self.recordGyroscope(rotation)
                }
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(
                to: .main
            ) { @Sendable [weak self] data, _ in
                let altitude = data?.relativeAltitude.doubleValue
                let pressure = data?.pressure.doubleValue
                MainActor.assumeIsolated {
                    guard let self,
                          self.didStartSensorHardware,
                          self.sensorHardwareGeneration == generation,
                          self.sensorSessionID == sessionID else { return }
                    self.latestRelativeAltitudeMeters = altitude
                    self.latestPressureKilopascals = pressure
                }
            }
        }
        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: startedAt) { @Sendable [weak self] data, _ in
                let steps = data?.numberOfSteps.intValue
                let distance = data?.distance?.doubleValue
                let up = data?.floorsAscended?.intValue
                let down = data?.floorsDescended?.intValue
                Task { @MainActor [weak self] in
                    guard let self,
                          self.didStartSensorHardware,
                          self.sensorHardwareGeneration == generation,
                          self.sensorSessionID == sessionID else { return }
                    self.latestStepCount = steps
                    self.latestPedometerDistanceMeters = distance
                    self.latestFloorsAscended = up
                    self.latestFloorsDescended = down
                }
            }
        }
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        if locationManager.authorizationStatus == .authorizedAlways
            || locationManager.authorizationStatus == .authorizedWhenInUse {
            locationManager.startUpdatingLocation()
        }

        sensorSummaryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { break }
                guard self.sensorSessionID == sessionID else { break }
                self.emitSensorSummary(isFinal: false)
            }
        }
        emitSensorSummary(isFinal: false)
    }

    private func recordAccelerometer(
        _ value: TaptionWatchSensorVector3,
        timestamp: TimeInterval,
        capturedAt: Date
    ) {
        accelerometerSum.add(value)
        accelerometerCount += 1
        if accelerometerCount == 1 || accelerometerCount.isMultiple(of: 25) {
            sensorSampleCount = accelerometerCount
        }
        let magnitude = value.magnitude
        peakAccelerationG = max(peakAccelerationG, magnitude)
        let count = Double(accelerometerCount)
        let delta = magnitude - accelerationMagnitudeMean
        accelerationMagnitudeMean += delta / count
        accelerationMagnitudeM2 += delta * (magnitude - accelerationMagnitudeMean)
        if let previousAccelerationMagnitude,
           let previousAccelerationSampleTime {
            let elapsed = max(0.01, timestamp - previousAccelerationSampleTime)
            accelerationJerkSum += abs(magnitude - previousAccelerationMagnitude)
                / elapsed
        }
        previousAccelerationMagnitude = magnitude
        previousAccelerationSampleTime = timestamp
        accelerationArchiveStride += 1
        if accelerationArchiveStride >= 5 {
            accelerationArchiveStride = 0
            accelerationArchiveSequence += 1
            pendingAccelerationSamples.append(
                WatchAccelerationArchiveSample(
                    id: UUID(),
                    capturedAt: capturedAt,
                    acceleration: value,
                    sessionID: sensorSessionID,
                    sequence: accelerationArchiveSequence,
                    isAmbient: false
                )
            )
        }
        motionSamples.append(
            WatchMotionSample(
                capturedAt: capturedAt,
                acceleration: value,
                rotationRate: lastGyroscopeSample,
                gravity: latestGravity
            )
        )
        analyzeBehaviorWindows(at: capturedAt)
    }

    private func recordGyroscope(_ value: TaptionWatchSensorVector3) {
        gyroscopeSum.add(value)
        gyroscopeCount += 1
        peakRotationRate = max(peakRotationRate, value.magnitude)
        lastGyroscopeSample = value
    }

    private func analyzeBehaviorWindows(at capturedAt: Date) {
        if nextBehaviorWindowEnd == nil {
            nextBehaviorWindowEnd = capturedAt
                .addingTimeInterval(WatchBehaviorWindowAnalyzer.windowDuration)
        }
        var advancedWindow = false
        while let windowEnd = nextBehaviorWindowEnd,
              capturedAt >= windowEnd {
            advancedWindow = true
            let windowStart = windowEnd.addingTimeInterval(
                -WatchBehaviorWindowAnalyzer.windowDuration
            )
            let samples = motionSamples.filter {
                $0.capturedAt >= windowStart && $0.capturedAt <= windowEnd
            }
            if let features = WatchBehaviorWindowAnalyzer.features(
                from: samples
            ) {
                let steps = latestStepCount ?? 0
                let floorsUp = latestFloorsAscended
                let floorsDown = latestFloorsDescended
                let altitude = latestRelativeAltitudeMeters
                let stepDelta = max(0, steps - lastWindowStepCount)
                let floorUpDelta = floorsUp.map {
                    max(0, $0 - (lastWindowFloorsAscended ?? $0))
                }
                let floorDownDelta = floorsDown.map {
                    max(0, $0 - (lastWindowFloorsDescended ?? $0))
                }
                let altitudeDelta = altitude.flatMap { current in
                    lastWindowAltitudeMeters.map { current - $0 }
                }
                let speeds = pendingRoutePoints.compactMap(
                    \.speedMetersPerSecond
                ).filter { $0.isFinite && $0 >= 0 }
                let averageSpeed = speeds.isEmpty
                    ? nil
                    : speeds.reduce(0, +) / Double(speeds.count)
                let context = WatchBehaviorInput(
                    workoutKind: workoutKind,
                    duration: features.duration,
                    accelerometerSampleCount: features.sampleCount,
                    accelerometerStandardDeviationG:
                        features.accelerationStandardDeviationG,
                    accelerometerMeanJerkGPerSecond:
                        features.jerkRMSGPerSecond,
                    steps: stepDelta,
                    floorsAscended: floorUpDelta,
                    floorsDescended: floorDownDelta,
                    averageHeartRate: averageHeartRate,
                    gpsAverageSpeedMetersPerSecond: averageSpeed,
                    gpsAvailable: !pendingRoutePoints.isEmpty,
                    gpsLossRatio: pendingRoutePoints.isEmpty ? 1 : 0,
                    altitudeDeltaMeters: altitudeDelta,
                    accelerationBodyRMSG: features.bodyAccelerationRMSG,
                    accelerationZeroCrossingRateHz:
                        features.zeroCrossingRateHz,
                    dominantMotionFrequencyHz:
                        features.dominantFrequencyHz,
                    gyroscopeRMSG: features.gyroscopeRMSGPerSecond,
                    posturePitchRadians: features.posturePitchRadians,
                    postureRollRadians: features.postureRollRadians
                )
                let modelPrediction: WatchBehaviorInference?
#if canImport(CoreML)
                modelPrediction = behaviorModel?.predict(features: features)
#else
                modelPrediction = nil
#endif
                let inference = WatchBehaviorClassifier.classifyWindow(
                    features,
                    context: context,
                    modelPrediction: modelPrediction
                )
                appendBehaviorSegment(
                    inference,
                    startedAt: features.startedAt,
                    endedAt: features.endedAt
                )
                lastWindowStepCount = steps
                lastWindowFloorsAscended = floorsUp
                lastWindowFloorsDescended = floorsDown
                lastWindowAltitudeMeters = altitude
            }
            nextBehaviorWindowEnd = windowEnd.addingTimeInterval(
                WatchBehaviorWindowAnalyzer.strideDuration
            )
        }
        guard advancedWindow else { return }
        let cutoff = (nextBehaviorWindowEnd ?? capturedAt)
            .addingTimeInterval(-WatchBehaviorWindowAnalyzer.windowDuration * 2)
        motionSamples.removeAll { $0.capturedAt < cutoff }
    }

    private func appendBehaviorSegment(
        _ inference: WatchBehaviorInference,
        startedAt: Date,
        endedAt: Date
    ) {
        var stable = inference
        if let lastBehaviorKind,
           lastBehaviorKind != inference.kind,
           inference.confidenceScore < lastBehaviorConfidence + 0.08 {
            stable = WatchBehaviorInference(
                kind: lastBehaviorKind,
                confidenceScore: lastBehaviorConfidence,
                evidence: inference.evidence + ["시간적 안정화"],
                modelVersion: inference.modelVersion
            )
        }
        lastBehaviorKind = stable.kind
        lastBehaviorConfidence = stable.confidenceScore
        if let index = pendingBehaviorSegments.indices.last,
           pendingBehaviorSegments[index].behavior == stable.kind,
           startedAt.timeIntervalSince(
               pendingBehaviorSegments[index].endedAt
           ) <= WatchBehaviorWindowAnalyzer.strideDuration * 1.5 {
            pendingBehaviorSegments[index].endedAt = max(
                pendingBehaviorSegments[index].endedAt,
                endedAt
            )
            pendingBehaviorSegments[index].confidenceScore = max(
                pendingBehaviorSegments[index].confidenceScore,
                stable.confidenceScore
            )
            pendingBehaviorSegments[index].evidence = Array(
                Set(pendingBehaviorSegments[index].evidence + stable.evidence)
            ).sorted()
            return
        }
        pendingBehaviorSegments.append(
            WatchBehaviorSegment(
                startedAt: startedAt,
                endedAt: endedAt,
                behavior: stable.kind,
                confidenceScore: stable.confidenceScore,
                evidence: stable.evidence,
                modelVersion: stable.modelVersion
            )
        )
    }

    private func emitSensorSummary(isFinal: Bool) {
        guard let summary = makeSensorSummary(
            at: .now,
            isFinal: isFinal
        ) else {
            return
        }
        onSensorSummary?(summary)
        if let behavior = summary.behavior {
            latestObservation = WatchActivityObservation(
                behavior: behavior,
                confidenceScore: summary.behaviorConfidenceScore ?? 0,
                startedAt: summary.startedAt,
                endedAt: summary.endedAt
            )
        }
        publishMeasurement()
        flushAccelerationArchive(summary: summary)
        pendingRoutePoints.removeAll(keepingCapacity: true)
        pendingBehaviorSegments.removeAll(keepingCapacity: true)
    }

    private func stopSensorCollection(
        at endedAt: Date,
        isFinal: Bool
    ) async -> TaptionWatchSensorSummary? {
        guard sensorSessionID != nil else { return nil }
        sensorSummaryTask?.cancel()
        sensorSummaryTask = nil
        stopSensorHardware()
        let summary = makeSensorSummary(at: endedAt, isFinal: isFinal)
        if let summary {
            flushAccelerationArchive(summary: summary)
        } else {
            flushAccelerationArchive(summary: nil)
        }
        let tasks = Array(accelerationFlushTasks.values)
        for task in tasks { await task.value }
        sensorSessionID = nil
        return summary
    }

    private func stopSensorHardware() {
        sensorHardwareGeneration &+= 1
        // 한 번도 시작하지 않았다면 클라이언트를 만들지 않는다.
        guard didStartSensorHardware else { return }
        didStartSensorHardware = false
        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()
        motionManager.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        pedometer.stopUpdates()
        locationManager.stopUpdatingLocation()
    }

    private func flushAccelerationArchive(summary: TaptionWatchSensorSummary?) {
        guard !pendingAccelerationSamples.isEmpty else { return }
        let samples = pendingAccelerationSamples
        pendingAccelerationSamples.removeAll(keepingCapacity: true)
        let archive = accelerationArchive
        guard let first = samples.first, let last = samples.last else { return }
        let chunk = TaptionWatchAccelerationChunk(
            id: first.id,
            sessionID: summary?.sessionID ?? first.sessionID,
            sequence: summary?.sequence ?? last.sequence,
            startedAt: first.capturedAt,
            endedAt: last.capturedAt,
            samples: samples,
            isFinal: summary?.isFinal ?? false
        )
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.accelerationFlushTasks[taskID] = nil }
            do {
                try await archive.append(samples)
            } catch {
                WatchLaunchDiagnostics.mark(
                    "workout archive append failed \(error.localizedDescription)"
                )
            }
            guard !Task.isCancelled else { return }
            guard let self, let onAccelerationChunk = self.onAccelerationChunk
            else { return }
            await onAccelerationChunk(chunk)
        }
        accelerationFlushTasks[taskID] = task
    }

    private func makeSensorSummary(
        at endedAt: Date,
        isFinal: Bool
    ) -> TaptionWatchSensorSummary? {
        guard let sensorSessionID,
              let startedAt,
              let workoutKind else {
            return nil
        }
        sensorSequence += 1
        let routeSpeeds = pendingRoutePoints.compactMap(\.speedMetersPerSecond)
            .filter { $0.isFinite && $0 >= 0 }
        let routeAverageSpeed = routeSpeeds.isEmpty
            ? nil
            : routeSpeeds.reduce(0, +) / Double(routeSpeeds.count)
        let input = WatchBehaviorInput(
            workoutKind: workoutKind,
            duration: endedAt.timeIntervalSince(startedAt),
            accelerometerSampleCount: accelerometerCount,
            accelerometerStandardDeviationG: accelerometerCount > 1
                ? sqrt(
                    max(0, accelerationMagnitudeM2)
                        / Double(accelerometerCount - 1)
                )
                : nil,
            accelerometerMeanJerkGPerSecond: accelerometerCount > 1
                ? accelerationJerkSum / Double(accelerometerCount - 1)
                : nil,
            peakAccelerationG: accelerometerCount > 0
                ? peakAccelerationG
                : nil,
            peakRotationRateRadiansPerSecond: gyroscopeCount > 0
                ? peakRotationRate
                : nil,
            steps: latestStepCount,
            distanceMeters: latestPedometerDistanceMeters
                ?? (distanceMeters > 0 ? distanceMeters : nil),
            floorsAscended: latestFloorsAscended,
            floorsDescended: latestFloorsDescended,
            averageHeartRate: averageHeartRate,
            gpsAverageSpeedMetersPerSecond: routeAverageSpeed,
            gpsAvailable: !pendingRoutePoints.isEmpty,
            gpsLossRatio: pendingRoutePoints.isEmpty ? 1 : 0
        )
        let fallback = WatchBehaviorClassifier.classify(input)
        let behavior = WatchBehaviorClassifier.aggregate(
            pendingBehaviorSegments,
            fallback: fallback
        )
        return TaptionWatchSensorSummary(
            sessionID: sensorSessionID,
            sequence: sensorSequence,
            workoutKind: workoutKind,
            linkedPlanID: linkedPlan?.id,
            linkedPlanTitle: linkedPlan?.title,
            linkedCategoryID: linkedPlan?.categoryID,
            startedAt: startedAt,
            endedAt: max(startedAt, endedAt),
            isFinal: isFinal,
            accelerometerSampleCount: accelerometerCount,
            accelerometerAverageG: accelerometerCount > 0
                ? accelerometerSum.divided(by: Double(accelerometerCount))
                : nil,
            peakAccelerationG: accelerometerCount > 0
                ? peakAccelerationG
                : nil,
            accelerometerStandardDeviationG: accelerometerCount > 1
                ? sqrt(
                    max(0, accelerationMagnitudeM2)
                        / Double(accelerometerCount - 1)
                )
                : nil,
            accelerometerMeanJerkGPerSecond: accelerometerCount > 1
                ? accelerationJerkSum / Double(accelerometerCount - 1)
                : nil,
            gyroscopeSampleCount: gyroscopeCount,
            gyroscopeAverageRadiansPerSecond: gyroscopeCount > 0
                ? gyroscopeSum.divided(by: Double(gyroscopeCount))
                : nil,
            peakRotationRateRadiansPerSecond: gyroscopeCount > 0
                ? peakRotationRate
                : nil,
            gravity: latestGravity,
            userAccelerationG: latestUserAcceleration,
            rotationRateRadiansPerSecond: latestRotationRate,
            attitudeRadians: latestAttitude,
            relativeAltitudeMeters: latestRelativeAltitudeMeters,
            pressureKilopascals: latestPressureKilopascals,
            stepCount: latestStepCount,
            distanceMeters: latestPedometerDistanceMeters
                ?? (distanceMeters > 0 ? distanceMeters : nil),
            floorsAscended: latestFloorsAscended,
            floorsDescended: latestFloorsDescended,
            latestHeartRate: heartRate > 0 ? heartRate : nil,
            averageHeartRate: averageHeartRate,
            maximumHeartRate: maximumHeartRate,
            activeEnergyKilocalories: activeEnergyKilocalories > 0
                ? activeEnergyKilocalories
                : nil,
            routePoints: pendingRoutePoints,
            behavior: behavior.kind,
            behaviorConfidenceScore: behavior.confidenceScore,
            behaviorEvidence: behavior.evidence,
            behaviorModelVersion: behavior.modelVersion,
            behaviorSegments: pendingBehaviorSegments,
            isAmbient: false,
            waterLockEnabled: WKInterfaceDevice.current().isWaterLockEnabled
        )
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
                  self.sensorSessionID != nil else { return }
            for point in points where !self.pendingRoutePoints.contains(
                where: { $0.capturedAt == point.capturedAt }
            ) {
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
            await self?.reset(
                with: "운동 측정이 중단됐습니다. \(error.localizedDescription)"
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

private extension TaptionWatchSensorVector3 {
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
