import Foundation

/// 회사 근무 안에서 폰을 손에 들고 화면을 본 시간을 `휴식`으로 잘라 낸다(BRK1106A01).
/// 사용시간 권한 없이 이미 모은 화면 상태·중력·가속 요약만 쓴다.
enum WorkBreakPattern {
    static let minimumDuration: TimeInterval = 5 * 60
    static let maximumSampleGap: TimeInterval = 3 * 60
    /// `screenIsOn`은 마지막으로 본 값이라 오래 남는다. 손 떨림이 잡힌 표본이 이만큼 있어야 믿는다.
    static let minimumHandheldSamples = 2
    static let handheldAccelerationG = 0.008
    private static let minimumWorkPiece: TimeInterval = 60
    static let evidence = "화면을 켠 채 폰을 손에 듦"

    /// 자동 근무·휴식 경계는 매번 새로 판정한다. 예전 갱신에서 잠긴 `근무`가 새 휴식 조각을 덮지 않게 한다.
    /// 사용자가 고친 기록은 그대로 이긴다.
    static func freshWins(previous: ActualRecord, candidate: ActualRecord) -> Bool {
        previous.source == .location && candidate.source == .location
            && !previous.manuallyCorrected && !ActualRecord.userOwned(previous)
            && (isBreak(previous) || isBreak(candidate))
    }

    static func isBreak(_ actual: ActualRecord) -> Bool { actual.evidence.contains(evidence) }

    private enum Sample { case handheld, screenOn, breaks }

    private static func sample(_ reading: SensorReading) -> Sample {
        guard reading.screenIsOn == true,
              reading.powerState?.isCharging != true,
              !reading.motion.isMovement else { return .breaks }
        let shake = reading.deviceMotionSummary?.userAccelerationStandardDeviationG
        if let z = reading.deviceMotion?.gravity.z, abs(z) >= 0.94, (shake ?? 0) < 0.005 { return .breaks }
        if let shake, shake >= handheldAccelerationG { return .handheld }
        return .screenOn
    }

    /// 손에 든 화면 사용이 짧은 간격으로 5분 넘게 이어진 구간.
    static func spans(in readings: [SensorReading], inside span: TimeSpan) -> [TimeSpan] {
        let ordered = readings.filter { span.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp }
        var result: [TimeSpan] = []
        var start: Date?
        var last: Date?
        var handheld = 0
        func close() {
            if let start, let last, handheld >= minimumHandheldSamples,
               last.timeIntervalSince(start) >= minimumDuration {
                result.append(TimeSpan(start: start, end: last))
            }
            start = nil; last = nil; handheld = 0
        }
        for reading in ordered {
            let kind = sample(reading)
            if let previous = last, reading.timestamp.timeIntervalSince(previous) > maximumSampleGap { close() }
            guard kind != .breaks else { close(); continue }
            if start == nil { start = reading.timestamp }
            last = reading.timestamp
            if kind == .handheld { handheld += 1 }
        }
        close()
        return result
    }

    /// 자동 `근무` 기록을 근무·휴식 조각으로 나눈다. 첫 조각은 원래 id를 지킨다.
    static func splitting(_ records: [ActualRecord], readings: [SensorReading], asOf now: Date) -> [ActualRecord] {
        records.flatMap { record -> [ActualRecord] in
            guard record.source == .location, record.categoryID == "work",
                  record.behavior == StationaryContextKind.work.rawValue else { return [record] }
            let span = record.span(asOf: now)
            let breaks = spans(in: readings, inside: span)
            guard !breaks.isEmpty else { return [record] }
            let work = ActualIntervalMergeEngine.subtracting(breaks, from: span).filter { $0.duration >= minimumWorkPiece }
            let pieces = (work.map { ($0, false) } + breaks.map { ($0, true) }).sorted { $0.0.start < $1.0.start }
            return pieces.enumerated().map { index, piece in
                var value = record
                if index > 0 {
                    value.id = StableRecordID.indexMixedFNV("work-break|\(record.id.uuidString)|\(Int(piece.0.start.timeIntervalSinceReferenceDate))")
                }
                value.startedAt = piece.0.start
                value.endedAt = piece.0.end
                value.createdAt = piece.0.start
                if piece.1 {
                    value.title = "휴식"
                    value.confidence = .medium
                    value.evidence = record.evidence.filter { $0.hasPrefix("자주가는 곳") } + [evidence]
                }
                return value
            }
        }
    }
}
