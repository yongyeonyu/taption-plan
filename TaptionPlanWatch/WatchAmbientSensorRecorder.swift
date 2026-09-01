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

    private let defaults: UserDefaults
    private let highWaterKey = "TaptionPlan.watchSensorRecorderHighWater"
    private let armedUntilKey = "TaptionPlan.watchSensorRecorderArmedUntil"
    private let armedAtKey = "TaptionPlan.watchSensorRecorderArmedAt"
    private let failureCountKey = "TaptionPlan.watchSensorRecorderDrainFailures"
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

    /// 앱이 실행될 때마다 API가 허용하는 가장 먼 미래까지 기록을 다시 건다.
    /// 재무장은 12시간 창을 처음부터 다시 시작하므로, 남은 창이 충분하면
    /// 건너뛴다.
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
        if let armedUntil = defaults.object(forKey: armedUntilKey) as? Date,
           armedUntil.timeIntervalSince(now)
            > Self.maximumRecordingDuration - Self.rearmMargin {
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
        let highWater = WatchSensorQueryPlan.sanitizedHighWater(
            defaults.object(forKey: highWaterKey) as? Date,
            now: now
        )
        let windows = WatchSensorQueryPlan.windows(
            now: now,
            armedAt: armedAt(),
            highWater: highWater
        )
        guard !windows.isEmpty else {
            WatchLaunchDiagnostics.mark("ambient drain no-window")
            return WatchAmbientDrainResult()
        }
        WatchLaunchDiagnostics.mark("ambient drain windows=\(windows.count)")

        let recorder = self.recorder
        var pipeline = WatchAmbientBehaviorPipeline(sessionID: UUID())
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
            } catch {
                ledger.failed(window)
                reportDrainFailure(window, error: error)
            }
            if ledger.isExhausted { break }
        }
        if ledger.failureCount == 0 {
            defaults.removeObject(forKey: failureCountKey)
        }
        // 표본이 하나도 없어도 워터마크는 조회한 끝까지 올린다. 그렇지
        // 않으면 손목을 차지 않은 구간을 매번 다시 훑게 된다.
        if let highWater = ledger.highWater {
            defaults.set(highWater, forKey: highWaterKey)
        }
        let result = pipeline.finish()
        WatchLaunchDiagnostics.mark(
            "ambient drain complete summaries=\(result.summaries.count) samples=\(result.archiveSamples.count) failures=\(ledger.failureCount)"
        )
        return result
    }

    /// 기록을 처음 건 시각. 이보다 앞은 표본이 존재할 수 없다.
    private func armedAt() -> Date? {
        if let stored = defaults.object(forKey: armedAtKey) as? Date {
            return stored
        }
        // 이 키가 생기기 전 빌드에서 이미 기록을 걸어둔 기기. 무장 종료
        // 시각에서 창 길이를 빼면 마지막으로 건 시각이 나온다. 첫 무장보다
        // 늦은 값이라 조회 범위가 좁아질 뿐 앞서 나가지 않는다.
        guard let armedUntil = defaults.object(forKey: armedUntilKey) as? Date
        else {
            return nil
        }
        let derived = armedUntil.addingTimeInterval(-Self.maximumRecordingDuration)
        defaults.set(derived, forKey: armedAtKey)
        return derived
    }

    /// 예외는 건너뛰고 넘어가지만 조용히 넘어가지는 않는다. 실행 진단
    /// 파일은 다음 실행 때 iPhone 설정 화면으로 그대로 전달된다.
    private func reportDrainFailure(
        _ window: WatchSensorQueryWindow,
        error: Error
    ) {
        let total = defaults.integer(forKey: failureCountKey) + 1
        defaults.set(total, forKey: failureCountKey)
        let span = Int(window.duration.rounded())
        WatchLaunchDiagnostics.mark(
            "ambient-drain-exception total=\(total)"
                + " from=\(Int(window.start.timeIntervalSince1970))"
                + " span=\(span)s \(error.localizedDescription)"
        )
    }
}

/// 50Hz 원본을 창 분석기가 기대하는 밀도로 낮추고, 기존
/// `WatchBehaviorWindowAnalyzer` / `WatchBehaviorClassifier` 파이프라인을
/// 그대로 태워 `TaptionWatchSensorSummary`를 만든다.
private struct WatchAmbientBehaviorPipeline {
    /// 원본 4개를 평균해 12.5Hz로 낮춘다. 2.56초 창에 32표본이 남아
    /// 분석기의 최소 8표본·자기상관 최소 12표본 조건을 넉넉히 넘기고,
    /// 상자 평균이 값싼 안티에일리어싱 역할을 한다. 12시간치를 통째로
    /// 배열에 담지 않고 창 두 개 분량만 들고 흐르므로 메모리는 킬로바이트
    /// 수준에 머문다.
    private static let downsampleFactor = 4
    /// 요약 하나가 담는 시간. 12시간 배수를 한 번에 비워도 요약 수가
    /// 72개를 넘지 않는다.
    private static let summaryChunkDuration: TimeInterval = 10 * 60
    /// 아카이브는 학습용 참고 자료라 원본 밀도가 필요 없다. 5초 간격이면
    /// 하루 약 1.7만 줄로, 예전 듀티 사이클(균형 기준 하루 4.3만 줄)보다
    /// 오히려 작다.
    private static let archiveInterval: TimeInterval = 5
    private static let maximumSegmentsPerSummary = 240
    /// 손목을 벗었거나 기록이 끊긴 구간을 하나의 창으로 잇지 않는다.
    private static let maximumSampleGap: TimeInterval = 5

    let sessionID: UUID
    private(set) var latestSampleDate: Date?

    private var result = WatchAmbientDrainResult()

    private var blockCount = 0
    private var blockX = 0.0
    private var blockY = 0.0
    private var blockZ = 0.0
    private var blockStart: Date?

    private var samples: [WatchMotionSample] = []
    private var nextWindowEnd: Date?
    private var segments: [WatchBehaviorSegment] = []
    private var lastSegmentKind: WatchBehaviorKind?
    private var lastSegmentConfidence = 0.0
    private var lastArchivedAt: Date?

    private var sequence = 0
    private var chunkStart: Date?
    private var chunkEnd: Date?
    private var count = 0
    private var sumX = 0.0
    private var sumY = 0.0
    private var sumZ = 0.0
    private var peak = 0.0
    private var magnitudeMean = 0.0
    private var magnitudeM2 = 0.0
    private var jerkSum = 0.0
    private var previousMagnitude: Double?
    private var previousMagnitudeAt: Date?

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    mutating func ingest(_ data: CMRecordedAccelerometerData) {
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
        closeChunk(isFinal: true)
        return result
    }

    private mutating func append(
        _ vector: TaptionWatchSensorVector3,
        capturedAt: Date
    ) {
        if let latestSampleDate,
           capturedAt.timeIntervalSince(latestSampleDate) > Self.maximumSampleGap {
            closeChunk(isFinal: false)
            samples.removeAll(keepingCapacity: true)
            nextWindowEnd = nil
        } else if let chunkStart,
                  capturedAt.timeIntervalSince(chunkStart)
                    >= Self.summaryChunkDuration {
            closeChunk(isFinal: false)
        }
        latestSampleDate = capturedAt
        if chunkStart == nil { chunkStart = capturedAt }
        chunkEnd = capturedAt
        accumulate(vector, capturedAt: capturedAt)
        if lastArchivedAt == nil
            || capturedAt.timeIntervalSince(lastArchivedAt ?? capturedAt)
                >= Self.archiveInterval {
            lastArchivedAt = capturedAt
            result.archiveSamples.append(
                WatchAmbientArchiveSample(
                    id: UUID(),
                    sessionID: sessionID,
                    sequence: sequence + 1,
                    capturedAt: capturedAt,
                    acceleration: vector
                )
            )
        }
        samples.append(
            WatchMotionSample(
                capturedAt: capturedAt,
                acceleration: vector,
                rotationRate: nil,
                gravity: nil
            )
        )
        analyzeWindows(at: capturedAt)
    }

    private mutating func accumulate(
        _ vector: TaptionWatchSensorVector3,
        capturedAt: Date
    ) {
        sumX += vector.x
        sumY += vector.y
        sumZ += vector.z
        count += 1
        let magnitude = sqrt(
            vector.x * vector.x + vector.y * vector.y + vector.z * vector.z
        )
        peak = max(peak, magnitude)
        let delta = magnitude - magnitudeMean
        magnitudeMean += delta / Double(count)
        magnitudeM2 += delta * (magnitude - magnitudeMean)
        if let previousMagnitude, let previousMagnitudeAt {
            let elapsed = max(0.01, capturedAt.timeIntervalSince(previousMagnitudeAt))
            jerkSum += abs(magnitude - previousMagnitude) / elapsed
        }
        previousMagnitude = magnitude
        previousMagnitudeAt = capturedAt
    }

    private mutating func analyzeWindows(at capturedAt: Date) {
        if nextWindowEnd == nil {
            nextWindowEnd = capturedAt.addingTimeInterval(
                WatchBehaviorWindowAnalyzer.windowDuration
            )
        }
        while let windowEnd = nextWindowEnd, capturedAt >= windowEnd {
            let windowStart = windowEnd.addingTimeInterval(
                -WatchBehaviorWindowAnalyzer.windowDuration
            )
            let window = samples.filter {
                $0.capturedAt >= windowStart && $0.capturedAt <= windowEnd
            }
            if let features = WatchBehaviorWindowAnalyzer.features(from: window) {
                // 기록기는 가속도만 남기므로 걸음·층수·GPS 근거가 없다.
                // 분류기는 누락 신호를 이미 옵셔널로 다룬다.
                let inference = WatchBehaviorClassifier.classifyWindow(
                    features,
                    context: WatchBehaviorInput(
                        workoutKind: nil,
                        duration: features.duration,
                        accelerometerSampleCount: features.sampleCount,
                        accelerometerStandardDeviationG:
                            features.accelerationStandardDeviationG,
                        accelerometerMeanJerkGPerSecond:
                            features.jerkRMSGPerSecond,
                        gpsAvailable: false,
                        gpsLossRatio: 1,
                        accelerationBodyRMSG: features.bodyAccelerationRMSG,
                        accelerationZeroCrossingRateHz:
                            features.zeroCrossingRateHz,
                        dominantMotionFrequencyHz: features.dominantFrequencyHz,
                        gyroscopeRMSG: features.gyroscopeRMSGPerSecond,
                        posturePitchRadians: features.posturePitchRadians,
                        postureRollRadians: features.postureRollRadians
                    )
                )
                appendSegment(
                    inference,
                    startedAt: features.startedAt,
                    endedAt: features.endedAt
                )
            }
            nextWindowEnd = windowEnd.addingTimeInterval(
                WatchBehaviorWindowAnalyzer.strideDuration
            )
        }
        let cutoff = (nextWindowEnd ?? capturedAt).addingTimeInterval(
            -WatchBehaviorWindowAnalyzer.windowDuration * 2
        )
        samples.removeAll { $0.capturedAt < cutoff }
    }

    private mutating func appendSegment(
        _ inference: WatchBehaviorInference,
        startedAt: Date,
        endedAt: Date
    ) {
        var stable = inference
        if let lastSegmentKind,
           lastSegmentKind != inference.kind,
           inference.confidenceScore < lastSegmentConfidence + 0.08 {
            stable = WatchBehaviorInference(
                kind: lastSegmentKind,
                confidenceScore: lastSegmentConfidence,
                evidence: inference.evidence + ["시간적 안정화"],
                modelVersion: inference.modelVersion
            )
        }
        lastSegmentKind = stable.kind
        lastSegmentConfidence = stable.confidenceScore
        if let index = segments.indices.last,
           segments[index].behavior == stable.kind,
           startedAt.timeIntervalSince(segments[index].endedAt)
            <= WatchBehaviorWindowAnalyzer.strideDuration * 1.5 {
            segments[index].endedAt = max(segments[index].endedAt, endedAt)
            segments[index].confidenceScore = max(
                segments[index].confidenceScore,
                stable.confidenceScore
            )
            segments[index].evidence = Array(
                Set(segments[index].evidence + stable.evidence)
            ).sorted()
            return
        }
        segments.append(
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

    private mutating func closeChunk(isFinal: Bool) {
        defer { resetChunk() }
        guard count > 0, let startedAt = chunkStart, let endedAt = chunkEnd else {
            return
        }
        sequence += 1
        let standardDeviation = count > 1
            ? sqrt(max(0, magnitudeM2) / Double(count - 1))
            : nil
        let meanJerk = count > 1 ? jerkSum / Double(count - 1) : nil
        let input = WatchBehaviorInput(
            workoutKind: nil,
            duration: max(1, endedAt.timeIntervalSince(startedAt)),
            accelerometerSampleCount: count,
            accelerometerStandardDeviationG: standardDeviation,
            accelerometerMeanJerkGPerSecond: meanJerk,
            peakAccelerationG: peak,
            gpsAvailable: false,
            gpsLossRatio: 1
        )
        let behavior = WatchBehaviorClassifier.aggregate(
            trimmedSegments,
            fallback: WatchBehaviorClassifier.classify(input)
        )
        result.summaries.append(
            TaptionWatchSensorSummary(
                sessionID: sessionID,
                sequence: sequence,
                // 주변 기록에는 운동 종류가 없다. 예전 듀티 사이클 경로와
                // 같은 자리표시자를 유지해 iPhone 쪽 해석을 바꾸지 않는다.
                workoutKind: .walking,
                linkedPlanID: nil,
                linkedPlanTitle: nil,
                linkedCategoryID: nil,
                startedAt: startedAt,
                endedAt: max(startedAt, endedAt),
                isFinal: isFinal,
                accelerometerSampleCount: count,
                accelerometerAverageG: TaptionWatchSensorVector3(
                    x: sumX / Double(count),
                    y: sumY / Double(count),
                    z: sumZ / Double(count)
                ),
                peakAccelerationG: peak,
                accelerometerStandardDeviationG: standardDeviation,
                accelerometerMeanJerkGPerSecond: meanJerk,
                gyroscopeSampleCount: 0,
                gyroscopeAverageRadiansPerSecond: nil,
                peakRotationRateRadiansPerSecond: nil,
                gravity: nil,
                userAccelerationG: nil,
                rotationRateRadiansPerSecond: nil,
                attitudeRadians: nil,
                relativeAltitudeMeters: nil,
                pressureKilopascals: nil,
                stepCount: nil,
                distanceMeters: nil,
                floorsAscended: nil,
                floorsDescended: nil,
                latestHeartRate: nil,
                averageHeartRate: nil,
                maximumHeartRate: nil,
                activeEnergyKilocalories: nil,
                routePoints: nil,
                behavior: behavior.kind,
                behaviorConfidenceScore: behavior.confidenceScore,
                behaviorEvidence: behavior.evidence,
                behaviorModelVersion: behavior.modelVersion,
                behaviorSegments: trimmedSegments,
                isAmbient: true
            )
        )
    }

    /// 10분 창이 잘게 흔들리면 세그먼트가 수백 개까지 늘 수 있다.
    /// WatchConnectivity 전송 크기를 지키기 위해 짧은 것부터 버린다.
    private var trimmedSegments: [WatchBehaviorSegment] {
        guard segments.count > Self.maximumSegmentsPerSummary else {
            return segments
        }
        return segments
            .sorted { $0.duration > $1.duration }
            .prefix(Self.maximumSegmentsPerSummary)
            .sorted { $0.startedAt < $1.startedAt }
    }

    private mutating func resetChunk() {
        chunkStart = nil
        chunkEnd = nil
        count = 0
        sumX = 0
        sumY = 0
        sumZ = 0
        peak = 0
        magnitudeMean = 0
        magnitudeM2 = 0
        jerkSum = 0
        previousMagnitude = nil
        previousMagnitudeAt = nil
        segments.removeAll(keepingCapacity: true)
        lastSegmentKind = nil
        lastSegmentConfidence = 0
    }
}
