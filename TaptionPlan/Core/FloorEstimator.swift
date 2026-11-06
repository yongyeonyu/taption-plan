import Foundation
import TaptionPlanEngine

struct FloorEstimator: Sendable {
    var defaultFloorHeightMeters: Double = 3
    /// Timeline segmentation needs a persistent target floor. Two samples
    /// are enough for direct one-off estimates, but three consecutive samples
    /// prevent barometer drift from creating a false floor change.
    var minimumStableSampleCount: Int = 2

    func estimate(
        readings: [SensorReading],
        placeKey: String,
        baselineFloor: Int?,
        floorHeightMeters: Double? = nil
    ) -> FloorTransition? {
        let ordered = readings
            .filter { RouteTimelineTimestamp.isValid($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
        guard let first = ordered.first, let last = ordered.last,
              first.timestamp < last.timestamp else {
            return nil
        }

        let systemReadings = ordered.filter { $0.systemFloor != nil }
        if let firstSystemReading = systemReadings.first,
           let from = firstSystemReading.systemFloor {
            // CLFloor는 실내에서 한두 번 튈 수 있으므로 새 층이 연속해서
            // 확인된 경우에만 전이를 확정한다.
            for index in systemReadings.indices.dropFirst() {
                guard let to = systemReadings[index].systemFloor,
                      to != from else { continue }
                let confirmed = systemReadings[index...].prefix {
                    $0.systemFloor == to
                }.count
                guard confirmed >= minimumStableSampleCount else { continue }
                let previousIndex = systemReadings.index(before: index)
                return FloorTransition(
                    id: UUID(),
                    placeKey: placeKey,
                    fromFloor: from,
                    toFloor: to,
                    relativeAltitudeMeters: Double(to - from)
                        * defaultFloorHeightMeters,
                    span: TimeSpan(
                        start: systemReadings[previousIndex].timestamp,
                        end: systemReadings[index].timestamp
                    ),
                    confidence: .high,
                    evidence: ["시스템 실내 층 정보 \(confirmed)회 연속"]
                )
            }
        }

        let floorHeight = max(
            2.2,
            floorHeightMeters ?? defaultFloorHeightMeters
        )
        let candidates = altitudeGroups(in: ordered).compactMap { group in
            altitudeCandidate(
                from: group,
                floorHeight: floorHeight
            )
        }
        guard let candidate = candidates.max(by: {
            if abs($0.floorDelta) == abs($1.floorDelta) {
                return $0.span.end < $1.span.end
            }
            return abs($0.floorDelta) < abs($1.floorDelta)
        }) else {
            return nil
        }

        let evidence = [
            "기압 고도 센서",
            "상대고도 \(String(format: "%+.1f", candidate.altitudeDelta))m",
            candidate.pedometerDelta == 0
                ? nil
                : "층계 \(candidate.pedometerDelta > 0 ? "+" : "")\(candidate.pedometerDelta)",
        ].compactMap { $0 }
        let confidence: ConfidenceLevel = baselineFloor == nil
            ? .low
            : (candidate.pedometerDelta == candidate.floorDelta
                ? .high
                : .medium)

        return FloorTransition(
            id: UUID(),
            placeKey: placeKey,
            fromFloor: baselineFloor,
            toFloor: baselineFloor.map {
                $0 + candidate.floorDelta
            },
            relativeAltitudeMeters: candidate.altitudeDelta,
            span: candidate.span,
            confidence: confidence,
            evidence: evidence
        )
    }

    private func altitudeGroups(
        in readings: [SensorReading]
    ) -> [[SensorReading]] {
        let altitudeReadings = readings.filter {
            $0.relativeAltitudeMeters != nil
        }
        guard !altitudeReadings.isEmpty else { return [] }

        var groups: [[SensorReading]] = []
        var current: [SensorReading] = []
        for reading in altitudeReadings {
            if let previous = current.last,
               previous.altimeterSessionID != reading.altimeterSessionID
                || reading.timestamp.timeIntervalSince(previous.timestamp)
                    > 30 * 60 {
                groups.append(current)
                current = []
            }
            current.append(reading)
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups.filter { $0.count >= 2 }
    }

    /// 기압 고도는 날씨로 천천히 흐른다(1hPa/시간이면 약 0.002m/s). 처음과 끝의 차이 대신 변화율이
    /// 높은 시간만 수직 이동으로 더하고, 쉬는 동안의 차이는 오차로 버린다(Muralidharan, HotMobile'14).
    private func altitudeCandidate(
        from readings: [SensorReading],
        floorHeight: Double
    ) -> AltitudeFloorCandidate? {
        guard let first = readings.first,
              let last = readings.last else {
            return nil
        }
        let moves = verticalMoves(in: readings, minimumMeters: floorHeight / 2)
        guard let firstMove = moves.first, let lastMove = moves.last else { return nil }
        let altitudeDelta = moves.map(\.meters).reduce(0, +)
        let floorDelta = Int((altitudeDelta / floorHeight).rounded())
        guard floorDelta != 0 else { return nil }

        let firstAscended = first.floorsAscended ?? 0
        let lastAscended = last.floorsAscended ?? firstAscended
        let firstDescended = first.floorsDescended ?? 0
        let lastDescended = last.floorsDescended ?? firstDescended
        let pedometerDelta = (lastAscended - firstAscended)
            - (lastDescended - firstDescended)
        let settled = readings.filter { $0.timestamp >= lastMove.end }
        let settledLevel = settled.first?.relativeAltitudeMeters
        // 멈춘 뒤 이어진 표본만 센다. 그 뒤의 느린 흐름은 오차라서 이 조건을 깨지 않는다.
        let stableSampleCount = settled.prefix { reading in
            guard let meters = reading.relativeAltitudeMeters, let settledLevel else { return false }
            return abs(meters - settledLevel) < floorHeight / 2
        }.count
        guard stableSampleCount >= minimumStableSampleCount
                || pedometerDelta == floorDelta else {
            return nil
        }
        return AltitudeFloorCandidate(
            floorDelta: floorDelta,
            altitudeDelta: altitudeDelta,
            pedometerDelta: pedometerDelta,
            span: TimeSpan(start: firstMove.start, end: lastMove.end)
        )
    }

    private func verticalMoves(
        in readings: [SensorReading],
        minimumMeters: Double
    ) -> [VerticalMove] {
        var moves: [VerticalMove] = []
        var current: VerticalMove?
        func close() {
            if let move = current, abs(move.meters) >= minimumMeters { moves.append(move) }
            current = nil
        }
        var anchorIndex = readings.startIndex
        for (index, reading) in readings.enumerated().dropFirst() {
            let from = readings[anchorIndex]
            guard let start = from.relativeAltitudeMeters,
                  let end = reading.relativeAltitudeMeters else { continue }
            let elapsed = reading.timestamp.timeIntervalSince(from.timestamp)
            guard elapsed >= Self.verticalWindow || index == readings.count - 1, elapsed > 0 else { continue }
            let change = end - start
            let isMove = Self.hasFootEvidence(from: from, to: reading)
                || Self.isStepBetweenLevels(readings, from: anchorIndex, to: index)
            if abs(change) / elapsed >= (isMove ? Self.minimumVerticalRate : Self.minimumQuietVerticalRate) {
                if let move = current, (move.meters >= 0) == (change >= 0) {
                    current = VerticalMove(start: move.start, end: reading.timestamp, meters: move.meters + change)
                } else {
                    close()
                    current = VerticalMove(start: from.timestamp, end: reading.timestamp, meters: change)
                }
            } else {
                close()
            }
            anchorIndex = index
        }
        close()
        return moves
    }

    /// 표본이 촘촘해도 이 길이로 묶어 변화율을 잰다. 짧게 재면 잡음이 이동처럼 보인다.
    private static let verticalWindow: TimeInterval = 30
    /// 날씨 변화의 약 두 배. 이보다 느리면 오차로 본다.
    private static let minimumVerticalRate = 0.004
    /// 걸음 근거 없이 조용한 휴대폰은 밤새 0.02m/s로도 흘렀다(11-01 원본). 엘리베이터만큼 빨라야 이동으로 본다.
    private static let minimumQuietVerticalRate = 0.04

    /// 앞뒤가 평평하고 그 사이만 뛰었으면 층 이동이다. 날씨는 이렇게 계단 모양으로 움직이지 않는다.
    private static func isStepBetweenLevels(_ readings: [SensorReading], from: Int, to: Int) -> Bool {
        guard from > readings.startIndex, to + 1 < readings.endIndex,
              let before = readings[from - 1].relativeAltitudeMeters,
              let start = readings[from].relativeAltitudeMeters,
              let end = readings[to].relativeAltitudeMeters,
              let after = readings[to + 1].relativeAltitudeMeters else { return false }
        return abs(start - before) <= levelTolerance && abs(after - end) <= levelTolerance
    }

    private static let levelTolerance = 0.5

    private static func hasFootEvidence(from: SensorReading, to: SensorReading) -> Bool {
        if to.motion.isOnFoot || from.motion.isOnFoot { return true }
        if let start = from.stepCount, let end = to.stepCount, end != start { return true }
        return (from.floorsAscended ?? 0) != (to.floorsAscended ?? 0)
            || (from.floorsDescended ?? 0) != (to.floorsDescended ?? 0)
    }
}

/// 연속 고도 표본 사이의 급격한 점프를 이상치로 걸러낸다. 실제 층 이동은
/// 다음 표본이 같은 수준을 다시 확인하므로 한 표본 지연 후 수용된다.
struct AltitudeSpikeGate: Sendable {
    static let maximumJumpMeters = 12.0
    static let confirmationCount = 2

    private var lastAcceptedMeters: Double?
    private var pending: (meters: Double, count: Int)?

    mutating func reset() {
        lastAcceptedMeters = nil
        pending = nil
    }

    /// 표본이 사용 가능하면 true. 스파이크로 판정되면 false를 돌려주고
    /// 같은 수준이 연속 확인될 때까지 보류한다.
    mutating func accept(_ meters: Double) -> Bool {
        guard meters.isFinite else { return false }
        guard let last = lastAcceptedMeters else {
            lastAcceptedMeters = meters
            return true
        }
        if abs(meters - last) <= Self.maximumJumpMeters {
            lastAcceptedMeters = meters
            pending = nil
            return true
        }
        if let held = pending,
           abs(held.meters - meters) <= Self.maximumJumpMeters {
            let count = held.count + 1
            if count >= Self.confirmationCount {
                lastAcceptedMeters = meters
                pending = nil
                return true
            }
            pending = (meters, count)
        } else {
            pending = (meters, 1)
        }
        return false
    }
}

private struct VerticalMove {
    var start: Date
    var end: Date
    var meters: Double
}

private struct AltitudeFloorCandidate {
    var floorDelta: Int
    var altitudeDelta: Double
    var pedometerDelta: Int
    var span: TimeSpan
}
