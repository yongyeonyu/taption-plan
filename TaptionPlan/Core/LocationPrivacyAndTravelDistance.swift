import Foundation
import TaptionPlanEngine

enum LocationPrivacyFilter {
    static func timelineSafe(_ place: PlaceStay) -> PlaceStay {
        var value = place
        value.point = nil
        return value
    }

    static func widgetSafe(
        places: [PlaceStay],
        travel: [TravelSegment]
    ) -> (places: [PlaceStay], travel: [TravelSegment]) {
        (
            places.map(timelineSafe),
            travel.map { segment in
                var value = segment
                value.evidence = []
                return value
            }
        )
    }
}

/// 이동 거리 계산(대표 지적 "거리 이상함", 거리 카운터가 356km, ARC1030A08).
///
/// 예전에는 구간 안 모든 GPS 점의 연속 거리를 그대로 더했다. 회사처럼 가만히 있어도 GPS가 20~30m씩 흔들리면
/// 그 흔들림이 전부 거리로 쌓여 몇 시간에 수백 km가 됐다. 여기서는 마지막으로 센 점(기준점)에서 위치 오차
/// 반경을 벗어났을 때만 거리를 더하고, 정지 모션 점과 비현실적인 순간이동은 세지 않는다.
enum TravelDistanceMath {
    /// 기준점에서 이만큼은 벗어나야 움직인 것으로 센다(m). 위치 오차가 크면 오차의 2배를 쓴다.
    static let jitterFloorMeters = 20.0
    static let accuracyMultiplier = 2.0
    /// 이보다 부정확한 점은 거리에 쓰지 않는다(m).
    static let maximumAccuracyMeters = 150.0
    /// 이 속도(m/s, 약 250km/h)를 넘는 점프는 튄 점으로 보고 세지 않는다.
    static let maximumSpeedMetersPerSecond = 70.0
    /// 앞뒤 이 시간 안의 점을 평균 내어 위치 흔들림을 상쇄한다(초).
    static let smoothingSeconds = 5.0

    private struct Sample {
        var latitude: Double
        var longitude: Double
        let time: Date
        let accuracy: Double
    }

    static func pathMeters(readings: [SensorReading]) -> Double {
        let raw: [Sample] = readings
            .sorted(by: { $0.timestamp < $1.timestamp })
            .compactMap { reading in
                guard let point = reading.point,
                      point.latitude.isFinite, point.longitude.isFinite,
                      point.horizontalAccuracy >= 0, point.horizontalAccuracy <= maximumAccuracyMeters,
                      reading.motion != .stationary else { return nil }
                return Sample(latitude: point.latitude, longitude: point.longitude, time: reading.timestamp, accuracy: point.horizontalAccuracy)
            }
        guard raw.count >= 2 else { return 0 }

        // 앞뒤 5초 안의 점을 평균 낸다. 1초 간격으로 20~30m씩 튀는 점이 서로 상쇄되고, 15초 간격 같은 성긴 기록은 그대로다.
        var smoothed = raw
        var lower = 0
        var upper = 0
        for index in raw.indices {
            while raw[lower].time.timeIntervalSince(raw[index].time) < -smoothingSeconds { lower += 1 }
            while upper + 1 < raw.count, raw[upper + 1].time.timeIntervalSince(raw[index].time) <= smoothingSeconds { upper += 1 }
            let window = raw[lower...max(lower, upper)]
            smoothed[index].latitude = window.reduce(0) { $0 + $1.latitude } / Double(window.count)
            smoothed[index].longitude = window.reduce(0) { $0 + $1.longitude } / Double(window.count)
        }

        var total = 0.0
        var anchor = smoothed[0]
        for sample in smoothed.dropFirst() {
            let meters = distanceMeters(
                GeoPoint(latitude: anchor.latitude, longitude: anchor.longitude, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: 0),
                GeoPoint(latitude: sample.latitude, longitude: sample.longitude, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: 0)
            )
            let threshold = max(jitterFloorMeters, accuracyMultiplier * max(anchor.accuracy, sample.accuracy))
            guard meters >= threshold else { continue }
            let seconds = sample.time.timeIntervalSince(anchor.time)
            if seconds > 0, meters / seconds > maximumSpeedMetersPerSecond { continue }
            total += meters
            anchor = sample
        }
        return total
    }
}
