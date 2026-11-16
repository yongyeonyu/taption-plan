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
        guard let reading = homeLatestReading else { return nil }
        return MapHomeLiveFollowSpeed.speed(
            latestAge: Date.now.timeIntervalSince(reading.timestamp),
            latestSpeed: reading.speedMetersPerSecond
        )
    }

    /// 멈춰 있어 새 위치가 오지 않아도 기본 거리까지 확대를 이어 간다(2초 간격 한 걸음씩).
    func advanceStationaryZoomIfNeeded() {
        guard isHomeLive,
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
        MapHomeLastKnownLocationPolicy.isValid(point)
    }
}

extension MapHomeView {
    /// 고른 날의 자료를 다 읽었는데 기록·머문 곳·이동·센서가 모두 비었다(HUX1116A02).
    var selectedDayIsEmpty: Bool {
        guard !isDayDataLoading, let day = currentDayDataSnapshot, day.isComplete else { return false }
        return day.actuals.isEmpty && day.places.isEmpty && day.travel.isEmpty && day.readings.isEmpty
    }

    /// 안내 띠를 올릴 수 있는 화면 상태. 사진링이 같은 자리를 쓰므로 사진이 있는 날은 띠를 띄우지 않는다.
    var showsStatusBandLayer: Bool {
        !isScreenRecording && (!isMenuOpen || isWideLayout) && layoutStyle.movesActionsToBottom
            && !isTravelMode && !isDayPlaybackRunning && !isSearchExpanded
            && photoBrowserSelection == nil && browsablePhotos.isEmpty
    }

    /// 기록 없는 날·권한 꺼짐 안내 띠. 아래 메뉴 바로 위, 왼쪽 정렬.
    var statusBandLayer: some View {
        MapHomeStatusBand(
            language: language,
            dayKey: MapHomeStatusBandPolicy.dayKey(model.selectedDate),
            isToday: Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate),
            dayIsEmpty: selectedDayIsEmpty,
            isHomeLive: isHomeLive,
            permissionsReady: { sensorCollectionPermissionGate.sensorCollectionReady },
            onCalendar: { isCalendarPresented = true },
            onPermissions: { openMenu() },
            onGuide: { isHomeGuidePresented = true }
        )
        .equatable()
        .padding(.leading, MapHomeBottomBarMetrics.edgeMargin)
        .padding(.trailing, isSidebarVisible ? timeRailWidth + 22 : MapHomeBottomBarMetrics.edgeMargin)
        .padding(.bottom, MapHomeBottomBarMetrics.reservedHeight + 8)
        .frame(maxWidth: MapHomeWideLayoutPolicy.actionBarWidth(viewportWidth: mapViewportSize.width).map { $0 + MapHomeBottomBarMetrics.edgeMargin * 2 } ?? .infinity, maxHeight: .infinity, alignment: .bottom)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 달력에서 날짜를 고르면 그날 경로가 지도에 맞춰지게 한다(HUX1116A03).
    var calendarSelectedDateBinding: Binding<Date> {
        Binding(
            get: { model.selectedDate },
            set: { day in
                guard day != model.selectedDate else { return }
                shouldFitRoutesAfterDateChange = true
                model.selectedDate = day
            }
        )
    }
}
