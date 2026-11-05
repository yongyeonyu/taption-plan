import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    func sharedZoomLevel(for span: MKCoordinateSpan) -> CGFloat? {
        guard let bounds = mapRenderCache.bounds(
            timeline: timelineRouteOverlays,
            expected: displayedExpectedRouteOverlays,
            generated: displayedWBSGeneratedRouteOverlays,
            subway: subwayRouteOverlays,
            current: currentCoordinate
        ) else { return nil }
        let fitLatitude = max(
            0.025,
            (bounds.maxLatitude - bounds.minLatitude) * 1.8
        )
        let fitLongitude = max(
            0.035,
            (bounds.maxLongitude - bounds.minLongitude) * 1.8
        )
        let scale = max(span.latitudeDelta / fitLatitude, span.longitudeDelta / fitLongitude)
        return min(max((scale - 0.05) / 0.95, 0), 1)
    }

    /// 실시간 따라가기 중 최신 센서 속도. 오래된 값은 쓰지 않는다.
    var liveFollowSpeedMetersPerSecond: Double? {
        guard let reading = model.latestSensorReading else { return nil }
        return MapHomeLiveFollowSpeed.speed(
            latestAge: Date.now.timeIntervalSince(reading.timestamp),
            latestSpeed: reading.speedMetersPerSecond
        )
    }

    /// 멈춰 있어 새 위치가 오지 않아도 기본 거리까지 확대를 이어 간다(2초 간격 한 걸음씩).
    func advanceStationaryZoomIfNeeded() {
        guard scenePhase == .active,
              MapHomeUserTrackingPolicy.focusesLocationUpdates(in: userTrackingMode),
              liveFollowSpeedMetersPerSecond == 0,
              let camera = visibleMapCamera,
              abs(log(camera.distance / MapHomePlaybackZoomPolicy.baselineDistance)) >= MapHomeLiveZoomGovernor.hysteresis
        else { return }
        focusDisplayedLocation(using: nil)
    }

    /// 오늘의 실시간 따라가기에서 속도에 맞춘 거리. 바꾸지 않아야 하면 nil.
    func liveFollowDistance(current: Double) -> Double? {
        // 설정의 "속도에 따라 가변"이 꺼져 있으면 실시간 따라가기에서도 배율을 바꾸지 않는다.
        // 예전에는 이 설정이 재생에만 적용돼 실시간 따라가기는 켜고 꺼도 늘 속도에 따라 줌이 바뀌었다(대표 지적, ARC1030A04).
        guard MapHomePlaybackZoomMode(rawValue: playbackZoomModeRaw) != .fixed,
              !isDayPlaybackRunning,
              selectedTimelineMinute == nil,
              userTrackingMode == .following,
              Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate),
              let next = liveZoomGovernor.nextDistance(
                  current: current,
                  speedMetersPerSecond: liveFollowSpeedMetersPerSecond,
                  uptime: ProcessInfo.processInfo.systemUptime
              ), abs(next - current) >= 1 else { return nil }
        TaptionPlanDiagnosticsLogger.shared.record(
            "live_zoom_sample",
            metrics: [
                "speed_mps": liveFollowSpeedMetersPerSecond ?? -1,
                "current_m": current.rounded(),
                "next_m": next.rounded(),
            ]
        )
        return next
    }

    @discardableResult
    func updateUserCenterState(using proxy: MapProxy?) -> Bool {
        let point: CGPoint?
        if let proxy, let coordinate = displayedLocationCoordinate {
            point = proxy.convert(coordinate, to: .named("mapHomeViewport"))
        } else {
            point = vectorMapViewportStore.viewport?
                .markerPoints[vectorDisplayedMarkerID]
        }
        return updateUserCenterState(locationPoint: point)
    }

    @discardableResult
    func updateUserCenterState(locationPoint: CGPoint?) -> Bool {
        let nextValue = locationPoint.map {
            MapHomeCameraLayoutMath.isCentered(
                locationPoint: $0,
                targetPoint: currentLocationTargetPoint
            )
        } ?? false
        if isMapCenteredOnUser != nextValue {
            isMapCenteredOnUser = nextValue
        }
        return nextValue
    }

    func isValid(_ point: GeoPoint) -> Bool {
        (-90...90).contains(point.latitude)
            && (-180...180).contains(point.longitude)
            && point.horizontalAccuracy >= 0
    }
}
