import Foundation

struct WatchAmbientSummaryAccumulator {
    private static let summaryChunkDuration: TimeInterval = 10 * 60
    private static let maximumSampleGap: TimeInterval = 5
    private static let maximumSegmentsPerSummary = 240

    private let sessionID: UUID
    private let sequenceAnchor: Date
    private(set) var summaries: [TaptionWatchSensorSummary] = []

    private var samples: [WatchMotionSample] = []
    private var nextWindowEnd: Date?
    private var segments: [WatchBehaviorSegment] = []
    private var lastSegmentKind: WatchBehaviorKind?
    private var lastSegmentConfidence = 0.0
    private var latestSampleDate: Date?
    private var chunkWindowSequence: Int?
    private var chunkSequence: Int?
    private var ambientWindowStart: Date?
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

    init(sessionID: UUID, sequenceAnchor: Date) {
        self.sessionID = sessionID
        self.sequenceAnchor = sequenceAnchor
    }

    static func summaryWindow(
        capturedAt: Date,
        anchor: Date
    ) -> (sequence: Int, start: Date)? {
        guard let sequence = TaptionWatchStableID.ambientSummarySequence(
            capturedAt: capturedAt,
            anchor: anchor,
            windowDuration: Self.summaryChunkDuration
        ), let start = TaptionWatchStableID.ambientSummaryWindowStart(
            sequence: sequence,
            anchor: anchor,
            windowDuration: Self.summaryChunkDuration
        ) else { return nil }
        return (sequence, start)
    }

    mutating func append(
        _ vector: TaptionWatchSensorVector3,
        capturedAt: Date
    ) {
        guard let summaryWindow = Self.summaryWindow(
            capturedAt: capturedAt,
            anchor: sequenceAnchor
        ) else { return }
        append(vector, capturedAt: capturedAt, summaryWindow: summaryWindow)
    }

    mutating func append(
        _ vector: TaptionWatchSensorVector3,
        capturedAt: Date,
        summaryWindow: (sequence: Int, start: Date)
    ) {
        if let chunkWindowSequence,
           chunkWindowSequence != summaryWindow.sequence {
            closeChunk()
        }
        if let latestSampleDate,
           capturedAt.timeIntervalSince(latestSampleDate) > Self.maximumSampleGap {
            resetAfterSampleGap()
        }
        latestSampleDate = capturedAt
        if chunkStart == nil {
            chunkStart = capturedAt
            chunkWindowSequence = summaryWindow.sequence
            chunkSequence = TaptionWatchStableID.ambientSummarySegmentSequence(
                startedAt: capturedAt,
                anchor: sequenceAnchor
            )
            ambientWindowStart = summaryWindow.start
        }
        chunkEnd = capturedAt
        accumulate(vector, capturedAt: capturedAt)
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

    mutating func resetAfterSampleGap() {
        closeChunk()
        samples.removeAll(keepingCapacity: true)
        nextWindowEnd = nil
        latestSampleDate = nil
        lastSegmentKind = nil
        lastSegmentConfidence = 0
    }

    mutating func finish() -> [TaptionWatchSensorSummary] {
        closeChunk()
        return summaries
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
        var advancedWindow = false
        while let windowEnd = nextWindowEnd, capturedAt >= windowEnd {
            advancedWindow = true
            let windowStart = windowEnd.addingTimeInterval(
                -WatchBehaviorWindowAnalyzer.windowDuration
            )
            let window = samples.filter {
                $0.capturedAt >= windowStart && $0.capturedAt <= windowEnd
            }
            if let features = WatchBehaviorWindowAnalyzer.features(from: window) {
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
        guard advancedWindow else { return }
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

    private mutating func closeChunk() {
        defer { resetChunk() }
        guard count > 0,
              let startedAt = chunkStart,
              let endedAt = chunkEnd,
              let chunkSequence,
              let ambientWindowStart else {
            return
        }
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
        summaries.append(
            TaptionWatchSensorSummary(
                sessionID: sessionID,
                sequence: chunkSequence,
                workoutKind: .walking,
                linkedPlanID: nil,
                linkedPlanTitle: nil,
                linkedCategoryID: nil,
                startedAt: startedAt,
                endedAt: max(startedAt, endedAt),
                isFinal: false,
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
                isAmbient: true,
                ambientWindowStart: ambientWindowStart
            )
        )
    }

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
        chunkWindowSequence = nil
        chunkSequence = nil
        ambientWindowStart = nil
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
