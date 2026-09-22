import CoreMotion
import Foundation

extension CMSensorDataList: @retroactive Sequence {
    public func makeIterator() -> NSFastEnumerationIterator {
        NSFastEnumerationIterator(self)
    }
}

struct WatchAmbientArchiveSample: Sendable {
    var id: UUID
    var sessionID: UUID
    var sequence: Int
    var capturedAt: Date
    var acceleration: TaptionWatchSensorVector3
}

struct WatchAmbientDrainResult: Sendable {
    var summaries: [TaptionWatchSensorSummary] = []
    var archiveSamples: [WatchAmbientArchiveSample] = []
    var pendingHighWater: Date? = nil
    var pendingSampleDates: [String: Date] = [:]
}

/// 배경 기록이 실제로 살아 있는지. 워치 화면과 위젯이 같은 값을 본다.
struct WatchAmbientRecorderStatus: Sendable {
    var isAvailable: Bool
    var isAccessDenied: Bool
    var drainFailureCount: Int
}

/// 앱이 꺼져 있는 동안에도 손목 가속도를 남기는 주변 기록기.
///
/// watchOS는 손목을 내리면 몇 초 안에 앱을 정지시키고 정지된 앱의
/// `Task.sleep`은 깨어나지 않는다. 그래서 "N분마다 30초" 듀티 사이클은
/// 사실상 첫 30초만 동작했다. `CMSensorRecorder`는 모션 데몬이 대신
/// 기록하므로 앱은 실행될 때마다 기록을 다시 걸고, 지난 실행 이후 쌓인
/// 표본만 읽어오면 된다.
///
/// WatchOS 26.5 SDK(CMSensorRecorder.h)가 못박은 한계:
/// - `recordAccelerometer(forDuration:)`은 50Hz로 최대 12시간 기록한다.
/// - 기록은 최대 3일 보관된다.
/// - `accelerometerData(from:to:)`는 한 번에 최대 12시간을 요청할 수 있다.
/// - 표본은 최대 3분 늦게 조회 가능해진다.
///
/// 한계를 벗어난 요청에 `accelerometerData(from:to:)`는 nil이 아니라
/// Objective-C 예외로 답한다(빌드 29 실기기 크래시). 그래서 범위는
/// `WatchSensorQueryPlan`이 먼저 검사하고, 그래도 남는 위험은
/// `WatchObjCExceptionCatcher`가 받아낸다.
actor WatchAmbientSensorRecorder {
    /// `recordAccelerometer(forDuration:)`가 허용하는 최대 창.
    static let maximumRecordingDuration: TimeInterval = 12 * 3_600
    private static let rearmMargin: TimeInterval = 30 * 60

    /// 남은 창이 30분 이하일 때만 다음 12시간 창을 건다. WC/background
    /// 콜백이 겹쳐도 actor 직렬화와 이 조건으로 중복 시작을 막는다.
    static func shouldArm(now: Date, armedUntil: Date?) -> Bool {
        guard let armedUntil else { return true }
        return armedUntil.timeIntervalSince(now) <= Self.rearmMargin
    }

    private let defaults: UserDefaults
    private let highWaterKey = "TaptionPlan.watchSensorRecorderHighWater"
    private let armedUntilKey = "TaptionPlan.watchSensorRecorderArmedUntil"
    private let armedAtKey = "TaptionPlan.watchSensorRecorderArmedAt"
    private let failureCountKey = "TaptionPlan.watchSensorRecorderDrainFailures"
    private let retryAfterKey = "TaptionPlan.watchSensorRecorderRetryAfter"
    private let pendingSessionKey = "TaptionPlan.watchSensorRecorderPendingSession"
    private let committedSampleDatesKey =
        "TaptionPlan.watchSensorRecorderCommittedSampleDates"
    private let pendingSampleDatesKey =
        "TaptionPlan.watchSensorRecorderPendingSampleDates"
    private lazy var recorder = CMSensorRecorder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isAvailable: Bool {
        CMSensorRecorder.isAccelerometerRecordingAvailable()
    }

    /// 기록기 상태를 한 번에 읽는다. 실패 횟수는 `reportDrainFailure`가
    /// 올려 둔 값이라, 워치를 다시 켜도 유실 구간이 있었다는 사실이 남는다.
    func status() -> WatchAmbientRecorderStatus {
        let authorization = CMSensorRecorder.authorizationStatus()
        return WatchAmbientRecorderStatus(
            isAvailable: CMSensorRecorder.isAccelerometerRecordingAvailable(),
            isAccessDenied: authorization == .denied
                || authorization == .restricted,
            drainFailureCount: defaults.integer(forKey: failureCountKey)
        )
    }

    func deleteAll(now: Date = .now) {
        defaults.set(now, forKey: highWaterKey)
        defaults.set(now, forKey: armedAtKey)
        defaults.removeObject(forKey: armedUntilKey)
        defaults.removeObject(forKey: failureCountKey)
        defaults.removeObject(forKey: retryAfterKey)
        defaults.removeObject(forKey: pendingSessionKey)
        defaults.removeObject(forKey: committedSampleDatesKey)
        defaults.removeObject(forKey: pendingSampleDatesKey)
    }

    /// 앱이 실행될 때마다 API가 허용하는 가장 먼 미래까지 기록을 다시 건다.
    /// 현재 창이 30분보다 더 남아 있으면 기존 기록을 유지한다.
    func arm(now: Date = .now) {
        let authorization = CMSensorRecorder.authorizationStatus()
        guard CMSensorRecorder.isAccelerometerRecordingAvailable(),
              authorization != .denied,
              authorization != .restricted else {
            WatchLaunchDiagnostics.mark(
                "ambient arm unavailable authorization=\(authorization.rawValue)"
            )
            return
        }
        let armedUntil = defaults.object(forKey: armedUntilKey) as? Date
        let storedArmedAt = defaults.object(forKey: armedAtKey) as? Date
        if storedArmedAt == nil,
           let armedAt = WatchSensorQueryPlan.restoredArmedAt(
               stored: nil,
               armedUntil: armedUntil,
               recordingDuration: Self.maximumRecordingDuration
           ) {
            // 구버전 무장 시각은 새 종료 시각으로 덮기 전에 복구한다.
            defaults.set(armedAt, forKey: armedAtKey)
        }
        if !Self.shouldArm(
            now: now,
            armedUntil: armedUntil
        ) {
            WatchLaunchDiagnostics.mark("ambient arm reused")
            return
        }
        recorder.recordAccelerometer(
            forDuration: Self.maximumRecordingDuration
        )
        defaults.set(
            now.addingTimeInterval(Self.maximumRecordingDuration),
            forKey: armedUntilKey
        )
        // 조회 하한선. 처음 건 시각만 남기고 재무장 때는 덮어쓰지 않는다.
        // 이전 창에 쌓인 표본도 보관 기간 안에서는 여전히 읽어야 한다.
        if defaults.object(forKey: armedAtKey) == nil {
            defaults.set(now, forKey: armedAtKey)
        }
        WatchLaunchDiagnostics.mark("ambient arm started")
    }

    /// 마지막으로 처리한 지점 이후의 표본만 읽어 기존 특징 파이프라인에
    /// 통과시킨다.
    func drain(now: Date = .now) -> WatchAmbientDrainResult {
        let authorization = CMSensorRecorder.authorizationStatus()
        guard CMSensorRecorder.isAccelerometerRecordingAvailable(),
              authorization == .authorized else {
            WatchLaunchDiagnostics.mark(
                "ambient drain unavailable authorization=\(authorization.rawValue)"
            )
            return WatchAmbientDrainResult()
        }
        if let retryAfter = defaults.object(forKey: retryAfterKey) as? Date,
           retryAfter > now {
            WatchLaunchDiagnostics.mark("ambient drain deferred after failure")
            return WatchAmbientDrainResult()
        }
        let highWater = WatchSensorQueryPlan.sanitizedHighWater(
            defaults.object(forKey: highWaterKey) as? Date,
            now: now
        )
        let armedAt = armedAt()
        let pendingSessionID = defaults.string(forKey: pendingSessionKey)
            .flatMap(UUID.init(uuidString:))
        let windows = WatchSensorQueryPlan.windows(
            now: now,
            armedAt: armedAt,
            highWater: highWater
        )
        guard !windows.isEmpty else {
            WatchLaunchDiagnostics.mark("ambient drain no-window")
            return WatchAmbientDrainResult()
        }
        WatchLaunchDiagnostics.mark("ambient drain windows=\(windows.count)")

        let recorder = self.recorder
        let sessionID = pendingSessionID ?? UUID()
        if pendingSessionID == nil {
            defaults.set(sessionID.uuidString, forKey: pendingSessionKey)
        }
        let committedSampleDates = defaults.dictionary(
            forKey: committedSampleDatesKey
        ) as? [String: Date] ?? [:]
        var pipeline = WatchAmbientBehaviorPipeline(
            sessionID: sessionID,
            sequenceAnchor: armedAt ?? windows[0].start,
            committedSampleIDs: Set(
                committedSampleDates.keys.compactMap(UUID.init(uuidString:))
            )
        )
        var ledger = WatchSensorDrainLedger(highWater: highWater)

        for window in windows {
            do {
                // 조회와 열거를 한 @try 안에 넣는다. CMSensorDataList는
                // 지연 목록이라 실제 읽기는 열거할 때 일어나고, 예외도
                // 그때 올라올 수 있다.
                try WatchObjCExceptionCatcher.catching {
                    guard let list = recorder.accelerometerData(
                        from: window.start,
                        to: window.end
                    ) else { return }
                    for case let sample as CMRecordedAccelerometerData in list {
                        pipeline.ingest(sample)
                    }
                }
                ledger.succeeded(window)
                pipeline.pruneSampleHistory(
                    keepingFrom: window.end.addingTimeInterval(
                        -(WatchSensorQueryPlan.availabilityLag + 60)
                    )
                )
                defaults.removeObject(forKey: failureCountKey)
                defaults.removeObject(forKey: retryAfterKey)
            } catch {
                ledger.failed(window)
                _ = reportDrainFailure(window, error: error, now: now)
                break
            }
        }
        if ledger.failureCount == 0 {
            defaults.removeObject(forKey: failureCountKey)
            defaults.removeObject(forKey: retryAfterKey)
        }
        // 결과가 WatchDayDatabase와 전송 경로에 저장된 뒤에만 manager가
        // watermark를 커밋한다. 중간 종료 시 같은 session ID로 재시도해
        // SQLite의 idempotent raw event insert가 중복을 막는다.
        var result = pipeline.finish()
        result.pendingHighWater = ledger.highWater
        if result.pendingSampleDates.isEmpty {
            defaults.removeObject(forKey: pendingSampleDatesKey)
        } else {
            defaults.set(result.pendingSampleDates, forKey: pendingSampleDatesKey)
        }
        WatchLaunchDiagnostics.mark(
            "ambient drain complete summaries=\(result.summaries.count) samples=\(result.archiveSamples.count) failures=\(ledger.failureCount)"
        )
        return result
    }

    func commit(highWater: Date?, now: Date = .now) {
        guard let highWater, highWater <= now else { return }
        let current = WatchSensorQueryPlan.sanitizedHighWater(
            defaults.object(forKey: highWaterKey) as? Date,
            now: now
        )
        let committedHighWater = max(current ?? highWater, highWater)
        var committedSamples = defaults.dictionary(
            forKey: committedSampleDatesKey
        ) as? [String: Date] ?? [:]
        let pendingSamples = defaults.dictionary(
            forKey: pendingSampleDatesKey
        ) as? [String: Date] ?? [:]
        pendingSamples.forEach { committedSamples[$0.key] = $0.value }
        let overlapFloor = committedHighWater.addingTimeInterval(
            -(WatchSensorQueryPlan.availabilityLag + 60)
        )
        committedSamples = committedSamples.filter { $0.value >= overlapFloor }
        if committedSamples.isEmpty {
            defaults.removeObject(forKey: committedSampleDatesKey)
        } else {
            defaults.set(committedSamples, forKey: committedSampleDatesKey)
        }
        defaults.removeObject(forKey: pendingSampleDatesKey)
        defaults.set(committedHighWater, forKey: highWaterKey)
    }

    /// 기록을 처음 건 시각. 이보다 앞은 표본이 존재할 수 없다.
    private func armedAt() -> Date? {
        let stored = defaults.object(forKey: armedAtKey) as? Date
        if let stored { return stored }
        // 이 키가 생기기 전 빌드에서 이미 기록을 걸어둔 기기. 무장 종료
        // 시각에서 창 길이를 빼면 마지막으로 건 시각이 나온다. 첫 무장보다
        // 늦은 값이라 조회 범위가 좁아질 뿐 앞서 나가지 않는다.
        guard let armedUntil = defaults.object(forKey: armedUntilKey) as? Date
        else {
            return nil
        }
        guard let derived = WatchSensorQueryPlan.restoredArmedAt(
            stored: nil,
            armedUntil: armedUntil,
            recordingDuration: Self.maximumRecordingDuration
        ) else { return nil }
        defaults.set(derived, forKey: armedAtKey)
        return derived
    }

    /// 예외 구간은 다음 실행에서 재시도하고 진단 파일은 iPhone 설정 화면으로
    /// 그대로 전달한다.
    private func reportDrainFailure(
        _ window: WatchSensorQueryWindow,
        error: Error,
        now: Date
    ) -> Int {
        let total = defaults.integer(forKey: failureCountKey) + 1
        defaults.set(total, forKey: failureCountKey)
        let retryDelay = min(
            6 * 3_600,
            30 * 60 * pow(2, Double(min(total - 1, 4)))
        )
        defaults.set(
            now.addingTimeInterval(retryDelay),
            forKey: retryAfterKey
        )
        let span = Int(window.duration.rounded())
        WatchLaunchDiagnostics.mark(
            "ambient-drain-exception total=\(total)"
                + " from=\(Int(window.start.timeIntervalSince1970))"
                + " span=\(span)s retry=\(Int(retryDelay))s"
                + " \(error.localizedDescription)"
        )
        return total
    }
}

/// 50Hz 원본을 창 분석기가 기대하는 밀도로 낮추고, 기존
/// `WatchBehaviorWindowAnalyzer` / `WatchBehaviorClassifier` 파이프라인을
/// 그대로 태워 `TaptionWatchSensorSummary`를 만든다.
private struct WatchAmbientBehaviorPipeline {
    /// 원본 4개를 평균해 12.5Hz로 낮춘다. 2.56초 창에 32표본이 남아
    /// 분석기의 최소 8표본·자기상관 최소 12표본 조건을 넘고, 상자 평균이
    /// 값싼 안티에일리어싱 역할을 한다. Sample ID 기록은 30분 query 성공
    /// 때마다 4분 재조회 overlap만 남겨 전체 3일 조회에 비례해 커지지 않는다.
    private static let downsampleFactor = 4
    /// 아카이브는 학습용 참고 자료라 원본 밀도가 필요 없다. 5초 간격이면
    /// 하루 약 1.7만 줄로, 예전 듀티 사이클(균형 기준 하루 4.3만 줄)보다
    /// 오히려 작다.
    private static let archiveInterval: TimeInterval = 5
    /// 손목을 벗었거나 기록이 끊긴 구간을 하나의 창으로 잇지 않는다.
    private static let maximumSampleGap: TimeInterval = 5

    let sessionID: UUID
    private let sequenceAnchor: Date
    private let committedSampleIDs: Set<UUID>

    private var result = WatchAmbientDrainResult()
    private var summaryAccumulator: WatchAmbientSummaryAccumulator

    private var blockCount = 0
    private var blockX = 0.0
    private var blockY = 0.0
    private var blockZ = 0.0
    private var blockStart: Date?
    private var latestRawSampleDate: Date?

    private var lastArchivedAt: Date?
    private var seenSampleIDs = Set<UUID>()

    init(
        sessionID: UUID,
        sequenceAnchor: Date,
        committedSampleIDs: Set<UUID>
    ) {
        self.sessionID = sessionID
        self.sequenceAnchor = sequenceAnchor
        self.committedSampleIDs = committedSampleIDs
        self.summaryAccumulator = WatchAmbientSummaryAccumulator(
            sessionID: sessionID,
            sequenceAnchor: sequenceAnchor
        )
    }

    mutating func pruneSampleHistory(keepingFrom cutoff: Date) {
        result.pendingSampleDates =
            TaptionWatchAmbientSampleDeduplicationPolicy.retainingSampleDates(
                result.pendingSampleDates,
                from: cutoff
            )
        seenSampleIDs = committedSampleIDs.union(
            result.pendingSampleDates.keys.compactMap(UUID.init(uuidString:))
        )
    }

    mutating func ingest(_ data: CMRecordedAccelerometerData) {
        if let latestRawSampleDate,
           data.startDate.timeIntervalSince(latestRawSampleDate)
                > Self.maximumSampleGap {
            blockCount = 0
            blockX = 0
            blockY = 0
            blockZ = 0
            blockStart = nil
            summaryAccumulator.resetAfterSampleGap()
        }
        latestRawSampleDate = data.startDate
        if blockStart == nil { blockStart = data.startDate }
        blockX += data.acceleration.x
        blockY += data.acceleration.y
        blockZ += data.acceleration.z
        blockCount += 1
        guard blockCount >= Self.downsampleFactor,
              let capturedAt = blockStart else { return }
        let divisor = Double(blockCount)
        let vector = TaptionWatchSensorVector3(
            x: blockX / divisor,
            y: blockY / divisor,
            z: blockZ / divisor
        )
        blockCount = 0
        blockX = 0
        blockY = 0
        blockZ = 0
        blockStart = nil
        append(vector, capturedAt: capturedAt)
    }

    mutating func finish() -> WatchAmbientDrainResult {
        result.summaries = summaryAccumulator.finish()
        return result
    }

    private mutating func append(
        _ vector: TaptionWatchSensorVector3,
        capturedAt: Date
    ) {
        guard let summaryWindow = WatchAmbientSummaryAccumulator.summaryWindow(
            capturedAt: capturedAt,
            anchor: sequenceAnchor
        ), let sampleID = TaptionWatchStableID.ambientAccelerationSample(
            capturedAt: capturedAt
        ) else { return }
        guard TaptionWatchAmbientSampleDeduplicationPolicy.shouldProcess(
            sampleID,
            committed: committedSampleIDs,
            seen: &seenSampleIDs
        ) else { return }
        result.pendingSampleDates[sampleID.uuidString] = capturedAt
        summaryAccumulator.append(
            vector,
            capturedAt: capturedAt,
            summaryWindow: summaryWindow
        )
        if lastArchivedAt == nil
            || capturedAt.timeIntervalSince(lastArchivedAt ?? capturedAt)
                >= Self.archiveInterval {
            if let archiveSequence = TaptionWatchStableID.ambientAccelerationSequence(
                capturedAt: capturedAt,
                anchor: sequenceAnchor
            ) {
                lastArchivedAt = capturedAt
                result.archiveSamples.append(
                    WatchAmbientArchiveSample(
                        id: sampleID,
                        sessionID: sessionID,
                        sequence: archiveSequence,
                        capturedAt: capturedAt,
                        acceleration: vector
                    )
                )
            }
        }
    }
}
