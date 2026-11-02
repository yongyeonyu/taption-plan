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

    private func altitudeCandidate(
        from readings: [SensorReading],
        floorHeight: Double
    ) -> AltitudeFloorCandidate? {
        guard let first = readings.first,
              let last = readings.last,
              let altitudeStart = first.relativeAltitudeMeters,
              let altitudeEnd = last.relativeAltitudeMeters else {
            return nil
        }
        let altitudeDelta = altitudeEnd - altitudeStart
        let floorDelta = Int((altitudeDelta / floorHeight).rounded())
        guard floorDelta != 0 else { return nil }

        let offsets = readings.map {
            Int(
                (
                    (($0.relativeAltitudeMeters ?? altitudeStart)
                        - altitudeStart)
                    / floorHeight
                ).rounded()
            )
        }
        let firstAscended = first.floorsAscended ?? 0
        let lastAscended = last.floorsAscended ?? firstAscended
        let firstDescended = first.floorsDescended ?? 0
        let lastDescended = last.floorsDescended ?? firstDescended
        let pedometerDelta = (lastAscended - firstAscended)
            - (lastDescended - firstDescended)
        let stableSampleCount = offsets.reversed().prefix {
            $0 == floorDelta
        }.count
        guard stableSampleCount >= minimumStableSampleCount
                || pedometerDelta == floorDelta else {
            return nil
        }

        let crossingIndex = offsets.firstIndex {
            $0 == floorDelta
        } ?? offsets.index(before: offsets.endIndex)
        let transitionStart = crossingIndex > offsets.startIndex
            ? readings[crossingIndex - 1].timestamp
            : first.timestamp
        return AltitudeFloorCandidate(
            floorDelta: floorDelta,
            altitudeDelta: altitudeDelta,
            pedometerDelta: pedometerDelta,
            span: TimeSpan(
                start: transitionStart,
                end: readings[crossingIndex].timestamp
            )
        )
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

private struct AltitudeFloorCandidate {
    var floorDelta: Int
    var altitudeDelta: Double
    var pedometerDelta: Int
    var span: TimeSpan
}
