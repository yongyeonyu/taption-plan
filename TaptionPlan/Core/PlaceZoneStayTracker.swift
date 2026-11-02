import Foundation

/// 등록 지점의 진입·이탈을 지도의 세 원과 같은 값으로 판정한다(대표 요청, ALG1102A01).
///
/// 안쪽 원에 들어오면 "들어왔다", 바깥 원을 벗어나면 "벗어났다", 그 사이는 이전 상태를 유지한다.
/// 빨간 원(등록 반경) 안에 `settleDuration` 넘게 머물면 안쪽 원에 닿지 않아도 "이 영역에 있다"로 본다.
/// 반경이 작은 장소는 실내 위치 오차로 안쪽 원에 잘 닿지 않기 때문이다.
enum PlaceZoneStayTracker {
    struct Stay: Equatable, Sendable {
        enum ExitBasis: String, Sendable {
            /// 빨간 원을 마지막으로 벗어난 표본.
            case radiusCircle
            /// 빨간 원 밖 표본 없이 바로 바깥 원 밖에서 잡힌 표본.
            case outerCircle
            /// 표본이 끝났거나 오래 끊겨 벗어난 것을 보지 못했다. 마지막으로 빨간 원 안에서 잡힌 표본까지다.
            case notObserved
        }

        var span: TimeSpan
        var exitBasis: ExitBasis
        /// 표본 없이 지나간 시간. 머문 것으로 단정하지 않고 따로 둔다.
        var unobserved: [TimeSpan]

        var observedDuration: TimeInterval {
            span.duration - unobserved.reduce(0) { $0 + $1.duration }
        }
    }

    /// 지도에 그리는 것과 같은 띠. 값을 따로 두지 않는다.
    static let band = MapHomePlaceZone.band
    static let settleDuration: TimeInterval = 5 * 60
    /// 이보다 오래 빈 곳은 관측 안 됨이다. 체류는 이어 주되 근거로 세지 않는다.
    static let unobservedGap: TimeInterval = 5 * 60
    /// 이보다 오래 비면 같은 체류로 잇지 않는다.
    static let maximumSampleGap: TimeInterval = 90 * 60
    /// 이보다 부정확한 표본은 자리를 말해 주지 못한다.
    private static let maximumAccuracyMeters = 100.0

    static func innerRadius(_ radius: Double) -> Double { radius * (1 - band) }
    static func outerRadius(_ radius: Double) -> Double { radius * (1 + band) }

    /// 정확한 표본 하나면 상태를 바꾸고, 오차가 반경보다 큰 표본은 같은 쪽이 두 번 이어져야 바꾼다.
    static func isDecisive(accuracy: Double, radius: Double) -> Bool {
        accuracy >= 0 && accuracy <= max(20, radius)
    }

    static func stays(readings: [SensorReading], center: GeoPoint, radius: Double) -> [Stay] {
        guard radius > 0 else { return [] }
        let inner = innerRadius(radius), outer = outerRadius(radius)
        let samples = readings
            .compactMap { reading -> (time: Date, distance: Double, accuracy: Double)? in
                guard RouteTimelineTimestamp.isValid(reading.timestamp), reading.gpsAvailable, let point = reading.point,
                      (0...maximumAccuracyMeters).contains(point.horizontalAccuracy) else { return nil }
                return (reading.timestamp, meters(point, center), point.horizontalAccuracy)
            }
            .sorted { $0.time < $1.time }

        var result: [Stay] = []
        var entered: Date?
        var lastInRadius: Date?
        var leftRadius: Date?
        var unobserved: [TimeSpan] = []
        var pendingEntry: Date?
        var pendingExit: Date?
        var radiusRunStart: Date?
        var previous: Date?

        func close(end: Date, basis: Stay.ExitBasis) {
            if let start = entered, end > start {
                let inside = TimeSpan(start: start, end: end)
                result.append(Stay(
                    span: inside,
                    exitBasis: basis,
                    unobserved: unobserved.compactMap { $0.intersection(with: inside) }
                ))
            }
            entered = nil
            lastInRadius = nil
            leftRadius = nil
            unobserved = []
            pendingEntry = nil
            pendingExit = nil
            radiusRunStart = nil
        }

        for sample in samples {
            if let last = previous {
                let gap = sample.time.timeIntervalSince(last)
                if gap > maximumSampleGap {
                    if entered != nil { close(end: lastInRadius ?? last, basis: .notObserved) }
                    radiusRunStart = nil
                    pendingEntry = nil
                } else if gap > unobservedGap {
                    if entered != nil { unobserved.append(TimeSpan(start: last, end: sample.time)) }
                    radiusRunStart = nil
                }
            }
            previous = sample.time
            let decisive = isDecisive(accuracy: sample.accuracy, radius: radius)
            let inRadius = sample.distance <= radius

            if entered == nil {
                if sample.distance <= inner {
                    if decisive {
                        entered = pendingEntry ?? radiusRunStart ?? sample.time
                    } else if let first = pendingEntry {
                        entered = first
                    } else {
                        pendingEntry = sample.time
                    }
                } else {
                    pendingEntry = nil
                }
                if entered == nil {
                    if inRadius {
                        let start = radiusRunStart ?? sample.time
                        radiusRunStart = start
                        if sample.time.timeIntervalSince(start) >= settleDuration { entered = start }
                    } else {
                        radiusRunStart = nil
                    }
                }
                if entered != nil {
                    lastInRadius = sample.time
                    pendingEntry = nil
                    radiusRunStart = nil
                }
                continue
            }

            if inRadius {
                lastInRadius = sample.time
                leftRadius = nil
            } else if leftRadius == nil {
                leftRadius = sample.time
            }
            if sample.distance >= outer {
                if decisive || pendingExit != nil {
                    let crossed = leftRadius ?? sample.time
                    close(end: crossed, basis: crossed < sample.time ? .radiusCircle : .outerCircle)
                } else {
                    pendingExit = sample.time
                }
            } else {
                pendingExit = nil
            }
        }
        if entered != nil, let end = lastInRadius { close(end: end, basis: .notObserved) }
        return result
    }

    static func centerDistance(_ a: GeoPoint, _ b: GeoPoint) -> Double { meters(a, b) }

    private static func meters(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let x = (a.longitude - b.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        let y = (a.latitude - b.latitude) * 111_320
        return (x * x + y * y).squareRoot()
    }
}
