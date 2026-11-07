import CoreLocation
import Foundation

/// 머문 자리 영역을 실제로 멈춘 뒤에만 건다(GPS1105A01).
///
/// 위치마다 영역을 다시 걸던 때에는 움직이는 40분 동안 `startMonitoring`·`startUpdatingLocation`이
/// 109번 불렸다. 한 자리(영역 반경 안)에 머문 근거가 있을 때만 건다.
/// - 속도가 0.5m/s 이상인 위치는 움직이는 중으로 보고 기준점을 옮긴다. 천천히 걷기(약 1m/s)보다 느리고,
///   멈춘 GPS의 속도 흔들림(대개 0.3m/s 아래)보다 크다.
/// - 기준점에서 반경 안의 위치가 2분 이상 이어지거나, 동작 센서(CMMotionActivity)가 멈춤이라고 하면
///   머문 것으로 본다. 동작 센서는 신호 대기처럼 짧은 멈춤에는 멈춤으로 바뀌지 않는다.
///   2분은 신호 대기·잠깐 멈춤보다 길고, iOS가 수집을 자동으로 멈추기(수 분 정지 뒤)보다 짧다.
struct StayRegionArmingPolicy: Equatable {
    static let movingSpeed = 0.5
    static let dwellDuration: TimeInterval = 120

    private(set) var anchor: CLLocation?

    /// 이번 위치에서 영역을 걸어야 하면 그 중심(기준점)을 돌려준다.
    mutating func observe(_ location: CLLocation, motionIsStationary: Bool) -> CLLocation? {
        if Self.isMoving(location) {
            anchor = location
            return nil
        }
        if !isNearAnchor(location) { anchor = location }
        guard let anchor else { return nil }
        let dwelled = location.timestamp.timeIntervalSince(anchor.timestamp) >= Self.dwellDuration
        return dwelled || motionIsStationary ? anchor : nil
    }

    mutating func reset() { anchor = nil }

    static func isMoving(_ location: CLLocation) -> Bool {
        location.speed.isFinite && location.speedAccuracy >= 0 && location.speed >= movingSpeed
    }

    private func isNearAnchor(_ location: CLLocation) -> Bool {
        guard let anchor else { return false }
        let radius = LocationPauseRegionPolicy.radius(horizontalAccuracy: anchor.horizontalAccuracy)
        return !LocationPauseRegionPolicy.hasLeft(distanceMeters: location.distance(from: anchor), radius: radius)
    }
}

extension LocationPauseRegionPolicy {
    enum ResumeTrigger: String { case region, wake }

    /// 영역을 나온 위치로는 수집이 이미 돌고 있다. iOS가 멈춘 경우와 영역 이벤트(그 자리에서 다시 시작)만 다시 켠다.
    static func restartsUpdates(trigger: ResumeTrigger, updatesPausedBySystem: Bool) -> Bool {
        trigger == .region || updatesPausedBySystem
    }
}
