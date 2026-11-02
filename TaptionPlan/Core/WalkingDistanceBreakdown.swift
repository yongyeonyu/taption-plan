import Foundation
import TaptionPlanEngine

/// 걷기 거리를 GPS로 잰 몫과 걸음으로 추정한 몫으로 나눈다(ALG1102A01).
/// 두 값은 출처가 달라 합치지 않고 근거에 따로 남긴다. 저장된 거리·원본은 바꾸지 않는다.
struct WalkingDistanceBreakdown: Equatable, Sendable {
    struct Part: Equatable, Sendable {
        var gpsMeters: Double
        var stepEstimatedMeters: Double
    }

    private static let cleanAccuracy = WalkingStride.maximumAccuracyMeters
    /// 재지 못한 날의 기본 보폭. 추정임을 근거에 함께 적는다.
    static let defaultStride = 0.7

    var stride: Double
    var isStrideCalibrated: Bool
    var parts: [UUID: Part]

    static func make(travel: [TravelSegment], readings: [SensorReading]) -> WalkingDistanceBreakdown {
        let walking = travel.filter { $0.mode == .walking }
        let ordered = readings.sorted { $0.timestamp < $1.timestamp }
        let bouts = walking.map { bout(for: $0.span, readings: ordered) }
        let calibrated = WalkingStride.calibrated(bouts)
        let stride = calibrated ?? defaultStride
        var parts: [UUID: Part] = [:]
        for (segment, bout) in zip(walking, bouts) {
            parts[segment.id] = bout.isCleanOutdoor
                ? Part(gpsMeters: bout.meters, stepEstimatedMeters: 0)
                : Part(gpsMeters: 0, stepEstimatedMeters: Double(bout.steps) * stride)
        }
        return WalkingDistanceBreakdown(stride: stride, isStrideCalibrated: calibrated != nil, parts: parts)
    }

    /// 자동 걷기 구간에 출처별 거리를 근거로 덧붙인다. 사용자가 확정한 구간은 그대로 둔다.
    func annotating(_ travel: [TravelSegment]) -> [TravelSegment] {
        travel.map { segment in
            guard !segment.isConfirmed, let part = parts[segment.id] else { return segment }
            var value = segment
            if part.gpsMeters > 0 {
                value.evidence.append("GPS 걷기 \(Int(part.gpsMeters.rounded()))m")
            } else if part.stepEstimatedMeters > 0 {
                let source = isStrideCalibrated ? "재어 둔 보폭" : "기본 보폭"
                value.evidence.append("걸음 추정 \(Int(part.stepEstimatedMeters.rounded()))m · \(source) \(String(format: "%.2f", stride))m")
            }
            return value
        }
    }

    private static func bout(for span: TimeSpan, readings: [SensorReading]) -> WalkingBout {
        let inside = readings.filter { span.contains($0.timestamp) }
        let fixes = inside.filter { reading in
            guard reading.gpsAvailable, let point = reading.point else { return false }
            return (0...100).contains(point.horizontalAccuracy)
        }
        var meters = 0.0
        for (a, b) in zip(fixes, fixes.dropFirst()) {
            guard let from = a.point, let to = b.point else { continue }
            let x = (from.longitude - to.longitude) * 111_320 * cos(from.latitude * .pi / 180)
            let y = (from.latitude - to.latitude) * 111_320
            meters += (x * x + y * y).squareRoot()
        }
        let accuracy = fixes.isEmpty ? -1 : fixes.compactMap { $0.point?.horizontalAccuracy }.reduce(0, +) / Double(fixes.count)
        return WalkingBout(
            meters: meters,
            steps: DeviceStepCounter.increase(in: inside),
            duration: span.duration,
            meanAccuracyMeters: accuracy
        )
    }
}

/// 아이폰과 워치의 누적 걸음은 서로 다른 계수기다. 한 줄로 이으면 값이 오갈 때마다 가짜 증가가 생긴다.
enum DeviceStepCounter {
    /// 기기별 증가분 중 가장 큰 값. 같은 걸음을 두 기기가 함께 세므로 더하지 않는다.
    static func increase(in readings: [SensorReading]) -> Int {
        increases(in: readings).values.max() ?? 0
    }

    static func increases(in readings: [SensorReading]) -> [TrackingDevice: Int] {
        Dictionary(grouping: readings.filter { $0.stepCount != nil }) { $0.sourceDevice ?? .iPhone }
            .mapValues { group in
                let counts = group.sorted { $0.timestamp < $1.timestamp }.compactMap(\.stepCount)
                return zip(counts, counts.dropFirst()).reduce(0) { total, pair in
                    total + stepIncrease(from: pair.0, to: pair.1)
                }
            }
    }

    /// 걷기·달리기 거리 누적값도 같은 이유로 기기별로 잰다.
    static func distanceIncrease(in readings: [SensorReading]) -> Double {
        Dictionary(grouping: readings.filter { $0.walkingRunningDistanceMeters != nil }) { $0.sourceDevice ?? .iPhone }
            .values.map { group in
                let values = group.sorted { $0.timestamp < $1.timestamp }.compactMap(\.walkingRunningDistanceMeters)
                return zip(values, values.dropFirst()).reduce(0) { $0 + ($1.1 >= $1.0 ? $1.1 - $1.0 : $1.1) }
            }.max() ?? 0
    }

    /// 누적값이 줄면 측정이 다시 시작된 것이므로 새 값 전체가 새 걸음이다.
    static func stepIncrease(from previous: Int, to current: Int) -> Int {
        current >= previous ? current - previous : current
    }
}
