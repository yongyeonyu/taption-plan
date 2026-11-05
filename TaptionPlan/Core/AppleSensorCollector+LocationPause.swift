import CoreLocation
import Foundation

/// iOS가 자동으로 멈춘 위치 수집을 다시 켠다(ALG1102A01).
///
/// `pausesLocationUpdatesAutomatically`로 멈춘 수집은 iOS가 스스로 잇지 않는다. 앱이 돌아오기 전까지 기록이 비어
/// 점심처럼 오래 머문 시간이 통째로 사라졌다. 멈춘 자리에 영역을 걸어 벗어나면 다시 시작한다.
/// 앱이 깨어나지 못하면 멈춤 알림도 오지 않으므로(GPS1105A01) 머문 자리에 미리 걸어 둔다.
enum LocationPauseRegionPolicy {
    static let identifier = "com.taption.plan.location-pause"
    /// 대표 지시 30m. iOS가 이 거리에서 바로 깨운다는 보장은 없다.
    static let minimumRadius = 30.0
    static let maximumRadius = 300.0

    /// 위치가 부정확할수록 넓혀서 제자리에서 흔들려 다시 켜지지 않게 한다.
    static func radius(horizontalAccuracy: Double) -> Double {
        guard horizontalAccuracy.isFinite, horizontalAccuracy >= 0 else { return maximumRadius }
        return min(maximumRadius, max(minimumRadius, horizontalAccuracy * 2))
    }

    static func hasLeft(distanceMeters: Double, radius: Double) -> Bool {
        distanceMeters > radius
    }

    /// 걸린 영역이 없거나 그 밖에 있을 때만 새로 건다. 위치마다 다시 걸면 iOS 감시가 매번 초기화된다.
    static func needsNewRegion(distanceFromCenter: Double?, radius: Double) -> Bool {
        guard let distanceFromCenter else { return true }
        return hasLeft(distanceMeters: distanceFromCenter, radius: radius)
    }
}

extension AppleSensorCollector {
    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        guard isCollecting, manager.authorizationStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self),
              let location = latestLocation else {
            TaptionPlanDiagnosticsLogger.shared.record("sensor_location_paused", fields: ["region": "false"])
            return
        }
        startPauseRegion(manager, at: location)
        TaptionPlanDiagnosticsLogger.shared.record("sensor_location_paused", fields: ["region": "true"])
    }

    /// 머문 자리에 영역을 미리 건다. 포그라운드 실시간 추적 중에는 위치가 계속 오므로 걸지 않는다.
    func armStayRegionIfNeeded(_ manager: CLLocationManager, at location: CLLocation) {
        guard isCollecting, !isForegroundLiveLocationTrackingEnabled,
              manager.authorizationStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let existing = manager.monitoredRegions
            .first { $0.identifier == LocationPauseRegionPolicy.identifier } as? CLCircularRegion
        let distance = existing.map {
            location.distance(from: CLLocation(latitude: $0.center.latitude, longitude: $0.center.longitude))
        }
        guard LocationPauseRegionPolicy.needsNewRegion(distanceFromCenter: distance, radius: existing?.radius ?? 0) else { return }
        startPauseRegion(manager, at: location)
    }

    private func startPauseRegion(_ manager: CLLocationManager, at location: CLLocation) {
        let radius = min(
            manager.maximumRegionMonitoringDistance,
            LocationPauseRegionPolicy.radius(horizontalAccuracy: location.horizontalAccuracy)
        )
        let region = CLCircularRegion(center: location.coordinate, radius: radius, identifier: LocationPauseRegionPolicy.identifier)
        region.notifyOnEntry = false
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
        TaptionPlanDiagnosticsLogger.shared.record("sensor_stay_region_armed", metrics: ["radius": radius])
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        stopLocationPauseRegion(manager)
        TaptionPlanDiagnosticsLogger.shared.record("sensor_location_resumed", fields: ["trigger": "system"])
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == LocationPauseRegionPolicy.identifier else { return }
        // 거리 필터 안쪽이어도 이번 위치는 남기도록 다시 시작한다.
        pendingStayRegionExitEmission = true
        manager.stopUpdatingLocation()
        resumeLocationUpdates(manager, trigger: "region")
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        guard region?.identifier == LocationPauseRegionPolicy.identifier else { return }
        stopLocationPauseRegion(manager)
        TaptionPlanDiagnosticsLogger.shared.record("sensor_location_pause_region_failed", fields: [:])
    }

    /// 큰 위치 변화·방문으로 깨어났을 때 멈춘 자리를 벗어났으면 영역 이벤트를 기다리지 않고 켠다.
    func resumeLocationUpdatesIfLeftPauseRegion(_ manager: CLLocationManager, location: CLLocation) {
        guard let region = manager.monitoredRegions
            .first(where: { $0.identifier == LocationPauseRegionPolicy.identifier }) as? CLCircularRegion else { return }
        let center = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
        guard LocationPauseRegionPolicy.hasLeft(distanceMeters: location.distance(from: center), radius: region.radius) else { return }
        resumeLocationUpdates(manager, trigger: "wake")
    }

    private func resumeLocationUpdates(_ manager: CLLocationManager, trigger: String) {
        stopLocationPauseRegion(manager)
        guard isCollecting else { return }
        manager.startUpdatingLocation()
        TaptionPlanDiagnosticsLogger.shared.record("sensor_location_resumed", fields: ["trigger": trigger])
    }

    private func stopLocationPauseRegion(_ manager: CLLocationManager) {
        for region in manager.monitoredRegions where region.identifier == LocationPauseRegionPolicy.identifier {
            manager.stopMonitoring(for: region)
        }
    }
}
