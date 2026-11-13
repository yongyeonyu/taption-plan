import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    func userFrequentPlaceRow(_ place: FrequentPlace) -> some View {
        Button {
            if let point = place.point {
                focusMap(on: point)
                isMenuOpen = false
            } else {
                selectedUserLocation = .frequentPlace(place.id)
                isMenuOpen = false
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: place.kind.systemImage)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                    .foregroundStyle(
                        MapHomeLocationDestination(placeKind: place.kind)?.tint
                            ?? MapHomeLocationDestination.user.tint
                    )
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(place.displayName)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12.5)), weight: .semibold))
                        .lineLimit(1)
                    Text(
                        place.point == nil
                            ? language.text("위치 미지정", "Location not set")
                            : place.kind == .restaurant
                                ? language.text("등록 식당", "Restaurant")
                                : language.text("사용자 위치", "User location")
                    )
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(9.5)), weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: place.point == nil ? "pencil" : "location.fill")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    var placeAnnotations: [MapHomePlaceAnnotation] {
        let probe = MapHomePlaybackProbe.begin("placeAnnotations"); defer { MapHomePlaybackProbe.end(probe) }
        // 날씨는 분 단위로만 본다. 매 호출마다 날씨 전체를 훑지 않는다(ARC1030A01).
        // 지난 날을 보거나 재생할 때는 그 시각에 저장된 날씨를 쓴다(WTH1114A01, 대표 신고: 과거 재생인데 집에 오늘 날씨).
        // 오늘을 그냥 보고 있을 때만 지금 날씨다. 재생 중 계산이 잦지 않게 10분 칸으로 묶는다.
        let weatherDate = MapHomeHomeWeatherBadgePolicy.displayDate(
            playback: displayedPlaybackDate, selectedDay: model.selectedDate, selection: timelineSelectionDate, now: .now)
        let homeWeather = homeWeatherBadgeMemo.value(for: MapHomeHomeWeatherKey(
            minute: Int(weatherDate.timeIntervalSinceReferenceDate / 600),
            weatherCount: model.snapshot.weather.count,
            lastObservedAt: model.snapshot.weather.last?.observedAt
        )) {
            MapHomeHomeWeatherBadgePolicy.badge(from: model.snapshot.weather, now: weatherDate)
        }
        let stampedKeys = placeStampedKeys
        return model.settings.frequentPlaces.compactMap { place in
            guard let destination = MapHomeLocationDestination(placeKind: place.kind),
                  let point = place.point,
                  isValid(point) else { return nil }
            return MapHomePlaceAnnotation(
                id: place.id,
                name: place.displayName,
                floor: place.floor,
                destination: destination,
                growthLevel: destination == .home
                    ? MapHomeGrowthPolicy.dailyLevel(for: model.selectedDate)
                    : nil,
                isLeapDay: MapHomeGrowthPolicy.isLeapDay(
                    model.selectedDate,
                    calendar: MapHomeGrowthPolicy.localCalendar
                ),
                growthStatus: destination == .home
                    ? homeGrowthMarkerStatus
                    : nil,
                isGrowthQualifiedToday: destination == .home
                    && isHomeGrowthQualifiedToday,
                growthStreak: destination == .home
                    ? homeGrowthHistory.season.streak
                    : 0,
                pendingWeeklyRewards: destination == .home
                    ? homeGrowthHistory.season.pendingWeeklyRewards
                    : 0,
                isCatAtHome: destination == .home && isDisplayedCatAtHome,
                catAction: displayedStickmanAction,
                equippedAccessoryID: homeGrowthHistory.season.equippedAccessory,
                coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                weatherBadge: destination == .home ? homeWeather : nil,
                homeSky: destination == .home ? MapHomeHomeSkyInput(
                    coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                    selectedDay: model.selectedDate,
                    progress: playbackProgress,
                    isPlaybackRunning: isDayPlaybackRunning
                ) : nil,
                stamp: stampedKeys.map { MapHomePlaceStampPolicy.mark(for: place, stampedKeys: $0) }
            )
        }
    }

    /// 위치 버튼·따라가기가 맞출 좌표: 확정 현재 위치, 없으면 가장 최근 위치.
    var liveFocusCoordinate: CLLocationCoordinate2D? {
        currentCoordinate ?? lastKnownCoordinate
    }

    func resetDayScopedMapState(for date: Date) {
        routeReadingsPreparationTask?.cancel()
        routeReadingsPreparationTask = nil
        routeReadingsPreparationGeneration.advance()
        dayDataSnapshot = nil
        routeActualIndex = nil
        routeReadings = []
        normalizedRouteReadings = []
        currentMapLocationReading = nil
        historicalPlaybackReadings = []
        displayRouteReadings = []
        lastPreparedRouteReadingsSignature = nil
        selectedPawprintTimestamp = nil
        highlightedPawprintTimestamp = nil
        selectedPawprintCoordinate = nil
        routeProjection = nil
        wbsPlaybackProjection = nil
        timelineRouteOverlays = []
        cachedTemporaryLocations = []
        expectedRouteOverlays = []
        wbsGeneratedRouteOverlays = []
        pendingForecastRouteState = nil
        expectedRouteCache.removeAll(keepingCapacity: true)
        expectedRouteRefreshTask?.cancel()
        expectedRouteRefreshTask = nil
        expectedRouteRefreshGeneration &+= 1
        wbsExpectedRouteRequests = []
        wbsExpectedRouteRequestsInputKey = nil
        liveRouteProjectionRefreshTask?.cancel()
        liveRouteProjectionRefreshTask = nil
        nearbyTransitPlaces = []
        hasDeferredWBSPlaybackRefresh = false
        timeRailSegments = []
        timeSidebarVisibleStartMinute = 0
        timeSidebarVisibleDurationMinutes = MapHomeTimeSidebarMath.fullDayMinutes
        zoomResetToken += 1
        hasAppliedInitialMapFocus = false
        routeDocumentProjectionGate.reset()
        mapRenderCache.invalidateRouteData()
    }

    func loadMapDayCache(
        for date: Date
    ) async -> MapHomeDayCachePayload? {
        let generation = TaptionDataDeletionFence.currentGeneration()
        guard TaptionDataDeletionFence.allows(generation: generation) else {
            return nil
        }
        let styleKey = MapDisplayStyle.mapLibreRPG.runtimeStyle.rawValue
        guard let payload = MapHomeDayCacheMemory.payload(
            day: TaptionPlanDayKey(date: date),
            algorithmKey: Self.mapCacheAlgorithmKey,
            styleKey: styleKey,
            generation: generation
        ), Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: model.selectedDate)
            && TaptionDataDeletionFence.allows(generation: generation)
        else { return nil }
        guard payload.centerLatitude.isFinite,
              payload.centerLongitude.isFinite,
              (-90...90).contains(payload.centerLatitude),
              (-180...180).contains(payload.centerLongitude),
              payload.latitudeDelta.isFinite,
              payload.longitudeDelta.isFinite else { return nil }
        return payload
    }

    func persistMapDayCache() {
        guard let dayData = currentDayDataSnapshot,
              dayData.isComplete,
              visibleMapCenter.latitude.isFinite,
              visibleMapCenter.longitude.isFinite,
              visibleMapSpan.latitudeDelta.isFinite,
              visibleMapSpan.longitudeDelta.isFinite else { return }
        let generation = TaptionDataDeletionFence.currentGeneration()
        guard TaptionDataDeletionFence.allows(generation: generation) else {
            return
        }
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let subwayMinute = calendar.dateComponents(
            [.minute],
            from: dayStart,
            to: routeOverlayCutoff
        ).minute ?? effectiveTimelineMinute
        let readingsFingerprint = MapHomeDayCacheReadingsFingerprint(
            readings: dayData.readings
        )
        let styleKey = MapDisplayStyle.mapLibreRPG.runtimeStyle.rawValue
        var signature = Hasher()
        signature.combine(generation)
        signature.combine(dayStart.timeIntervalSinceReferenceDate.bitPattern)
        signature.combine(dayData.sourceFingerprint)
        signature.combine(readingsFingerprint.count)
        signature.combine(readingsFingerprint.firstID)
        signature.combine(readingsFingerprint.lastID)
        signature.combine(
            readingsFingerprint.firstTimestamp?
                .timeIntervalSinceReferenceDate.bitPattern
        )
        signature.combine(
            readingsFingerprint.lastTimestamp?
                .timeIntervalSinceReferenceDate.bitPattern
        )
        signature.combine(visibleMapCenter.latitude.bitPattern)
        signature.combine(visibleMapCenter.longitude.bitPattern)
        signature.combine(visibleMapSpan.latitudeDelta.bitPattern)
        signature.combine(visibleMapSpan.longitudeDelta.bitPattern)
        signature.combine(styleKey)
        signature.combine(subwayMinute)
        for overlay in timelineRouteOverlays {
            signature.combine(overlay.id)
            signature.combine(overlay.geometrySignature)
            signature.combine(overlay.categoryID)
            signature.combine(overlay.opacity.bitPattern)
            signature.combine(overlay.speedMetersPerSecond?.bitPattern)
        }
        for overlay in expectedRouteOverlays {
            signature.combine(overlay.id)
            signature.combine(overlay.geometrySignature)
            signature.combine(overlay.mode.rawValue)
            signature.combine(
                overlay.departureDate.timeIntervalSinceReferenceDate.bitPattern
            )
            signature.combine(
                overlay.arrivalDate.timeIntervalSinceReferenceDate.bitPattern
            )
        }
        for overlay in subwayRouteOverlays {
            signature.combine(overlay.id)
            signature.combine(overlay.geometrySignature)
            signature.combine(overlay.estimated)
        }
        for location in temporaryLocationAnnotations {
            signature.combine(location.id)
            signature.combine(
                location.timestamp.timeIntervalSinceReferenceDate.bitPattern
            )
            signature.combine(location.stationName)
            signature.combine(location.point.latitude.bitPattern)
            signature.combine(location.point.longitude.bitPattern)
            signature.combine(location.reason)
        }
        let writeSignature = signature.finalize()
        guard writeSignature != mapDayCacheWriteSignature else { return }
        mapDayCacheWriteSignature = writeSignature
        let cachedSubwayRoutes = subwayRouteOverlays
        let payload = MapHomeDayCachePayload(
            sourceUpdatedAt: dayData.sourceUpdatedAt,
            sourceRevision: dayData.sourceRevision,
            sourceFingerprint: dayData.sourceFingerprint,
            readingsFingerprint: readingsFingerprint,
            centerLatitude: visibleMapCenter.latitude,
            centerLongitude: visibleMapCenter.longitude,
            latitudeDelta: visibleMapSpan.latitudeDelta,
            longitudeDelta: visibleMapSpan.longitudeDelta,
            timeline: timelineRouteOverlays.map { overlay in
                MapHomeCachedRouteOverlay(
                    id: overlay.id,
                    categoryID: overlay.categoryID,
                    opacity: overlay.opacity,
                    speedMetersPerSecond: overlay.speedMetersPerSecond,
                    coordinates: overlay.coordinates.map {
                        MapHomeCachedCoordinate(
                            latitude: $0.latitude,
                            longitude: $0.longitude
                        )
                    },
                    coordinateTimestamps: overlay.coordinateTimestamps
                )
            },
            expected: expectedRouteOverlays.map { overlay in
                MapHomeCachedExpectedRouteOverlay(
                    id: overlay.id,
                    segmentID: overlay.segmentID,
                    modeRawValue: overlay.mode.rawValue,
                    departureDate: overlay.departureDate,
                    arrivalDate: overlay.arrivalDate,
                    coordinates: overlay.coordinates.map {
                        MapHomeCachedCoordinate(
                            latitude: $0.latitude,
                            longitude: $0.longitude
                        )
                    }
                )
            },
            subway: cachedSubwayRoutes.map { overlay in
                MapHomeCachedSubwayRouteOverlay(
                    id: overlay.id,
                    estimated: overlay.estimated,
                    coordinates: overlay.coordinates.map {
                        MapHomeCachedCoordinate(
                            latitude: $0.latitude,
                            longitude: $0.longitude
                        )
                    },
                    travelID: overlay.travelID
                )
            },
            subwayMinute: subwayMinute,
            temporaryLocations: temporaryLocationAnnotations.map { location in
                MapHomeCachedTemporaryLocation(
                    id: location.id, timestamp: location.timestamp,
                    stationName: location.stationName,
                    latitude: location.point.latitude, longitude: location.point.longitude,
                    reason: location.reason
                )
            }
        )
        MapHomeDayCacheMemory.store(
            payload,
            day: TaptionPlanDayKey(date: model.selectedDate),
            algorithmKey: Self.mapCacheAlgorithmKey,
            styleKey: styleKey,
            generation: generation
        )
    }

    func reportInitialMapShellReadyIfNeeded(for date: Date) {
        // 홈은 전체 DB 로드와 오늘 경로(하루 데이터)가 준비된 뒤에 띄운다. 너무 오래 걸리면 시간 제한으로 연다.
        guard !hasReportedInitialDataReady,
              (model.isBootstrapped && dayDataSnapshot?.isComplete == true) || initialReadyForced,
              Calendar.autoupdatingCurrent.isDate(
                  date,
                  inSameDayAs: model.selectedDate
              ) else { return }
        hasReportedInitialDataReady = true
        TaptionPlanDiagnosticsLogger.shared.record("map_initial_shell_ready")
        onInitialDataReady()
    }

    func jumpToTodayAndCurrentMapPosition() {
        shouldFitRoutesAfterDateChange = true
        hasUserAdjustedMap = false
        model.selectedDate = Date()
        selectedTimelineMinute = nil
        isTimelineSelectionPinned = false
        sharedZoomLevel = 1
        zoomResetToken += 1
        focusMapOnAllRoutes()
    }

    func setMapPosition(_ position: MapCameraPosition, caller: String = #function) {
        mapPosition = position
        mapCameraRevision &+= 1
        // 재생 중에는 초당 한 번만 기록해 로그 양을 줄인다.
        if isDayPlaybackRunning,
           !MapHomeCameraLogThrottle.shouldLog(nowUptime: ProcessInfo.processInfo.systemUptime) { return }
        TaptionPlanDiagnosticsLogger.shared.record(
            "map_camera_command",
            fields: [
                "caller": caller,
                "tracking": String(describing: userTrackingMode),
                "playing": isDayPlaybackRunning ? "true" : "false",
            ],
            metrics: [
                "revision": Double(mapCameraRevision),
                "distance_m": position.camera?.distance.rounded() ?? -1,
            ]
        )
    }

    func restoreInitialMapZoom() {
        let camera = MapHomeStartupCameraPolicy.camera(
            restoring: visibleMapCamera,
            fallbackCenter: displayedLocationCoordinate ?? currentCoordinate
                ?? homeCoordinate ?? MapHomeStartupCameraPolicy.fallbackCenter
        )
        mapCameraFrameProjection.reset()
        if visibleMapCamera != camera { visibleMapCamera = camera }
        setMapPosition(.camera(camera))
    }

    func focusMapIfNeeded() {
        applyInitialMapFocusIfNeeded()
    }

    func applyInitialMapFocusIfNeeded() {
        guard !isDayPlaybackRunning, !hasUserAdjustedMap,
              !hasAppliedInitialMapFocus,
              let coordinate = displayedLocationCoordinate ?? currentCoordinate else { return }
        hasAppliedInitialMapFocus = true
        hasAppliedInitialLocation = true
        setMapPosition(.camera(MapCamera(centerCoordinate: coordinate, distance: MapHomeStartupCameraPolicy.distance)))
    }

    func focusMap(
        on point: GeoPoint,
        using proxy: MapProxy? = nil,
        followsTracking: Bool = false
    ) {
        let coordinate = CLLocationCoordinate2D(
            latitude: point.latitude,
            longitude: point.longitude
        )
        if followsTracking,
           let proxy,
           let camera = visibleMapCamera,
           let locationPoint = proxy.convert(
               coordinate,
               to: .named("mapHomeViewport")
           ),
           let center = proxy.convert(
               MapHomeCameraLayoutMath.cameraCenterSourcePoint(
                   currentLocationPoint: locationPoint,
                   targetPoint: currentLocationTargetPoint,
                   viewportSize: mapViewportSize
               ),
               from: .named("mapHomeViewport")
           ) {
            setMapPosition(.camera(
                MapCamera(
                    centerCoordinate: center,
                    distance: playbackAwareDistance(current: camera.distance),
                    heading: camera.heading,
                    pitch: camera.pitch
                )
            ))
        } else if let camera = visibleMapCamera {
            setMapPosition(.camera(
                MapCamera(
                    centerCoordinate: coordinate,
                    distance: playbackAwareDistance(current: camera.distance),
                    heading: camera.heading,
                    pitch: camera.pitch
                )
            ))
        } else {
            setMapPosition(.region(
                MKCoordinateRegion(center: coordinate, span: visibleMapSpan)
            ))
        }
        if followsTracking {
            requestAppleMapCenter(coordinate)
        }
        if followsTracking {
            setUserTrackingMode(.following)
            isMapCenteredOnUser = true
        } else {
            setUserTrackingMode(.idle)
            isMapCenteredOnUser = false
        }
    }

    func requestAppleMapCenter(
        _ coordinate: CLLocationCoordinate2D,
        distance: CLLocationDistance? = nil
    ) {
        appleViewportCommand = MapHomeAppleViewportCommand(
            revision: (appleViewportCommand?.revision ?? 0) &+ 1,
            centerCoordinate: coordinate,
            heading: nil,
            targetPoint: currentLocationTargetPoint,
            distance: distance
        )
    }

    func requestAppleMapHeading(
        _ heading: CLLocationDirection,
        centeredAt coordinate: CLLocationCoordinate2D?,
        distance: CLLocationDistance? = nil
    ) {
        appleViewportCommand = MapHomeAppleViewportCommand(
            revision: (appleViewportCommand?.revision ?? 0) &+ 1,
            centerCoordinate: coordinate,
            heading: heading,
            targetPoint: coordinate == nil ? nil : currentLocationTargetPoint,
            distance: distance
        )
    }

    func toggleMapHeadingMode(using proxy: MapProxy? = nil) {
        compassControlState = compassControlState.toggled
        if compassControlState.followsHeading {
            headingMonitor.start()
            applyMapHeading(using: proxy)
        } else {
            headingMonitor.stop()
            focusUserLocation(
                using: proxy,
                heading: compassControlState.mapCameraHeading,
                preservesCamera: true
            )
        }
    }

    func applyMapHeading(using proxy: MapProxy?) {
        guard isHeadingMode else { return }
        let heading = headingMonitor.headingDegrees
            ?? visibleMapCamera?.heading
            ?? 0
        if currentCoordinate != nil {
            focusUserLocation(
                using: proxy,
                heading: heading,
                preservesCamera: true
            )
            setUserTrackingMode(.following)
        } else {
            requestAppleMapHeading(heading, centeredAt: nil)
        }
    }

    func setUserTrackingMode(_ mode: MapHomeUserTrackingMode) {
        guard userTrackingModeRawValue != mode.rawValue else { return }
        userTrackingModeRawValue = mode.rawValue
    }

    func handleUserMapPan() {
        MapHomeInteractionMonitor.shared.begin("map_gesture", idleTimeout: 0.5)
        // 재생 중 지도를 직접 끌면 재생을 취소하고 시작 전 시각으로 되돌린다.
        cancelDayPlaybackIfRunning()
        recordUserMapAdjustment()
        setUserTrackingMode(.idle)
        isMapCenteredOnUser = false
    }

    func handleUserCameraGesture() {
        MapHomeInteractionMonitor.shared.begin("map_gesture", idleTimeout: 0.5)
        // 확대·축소·회전도 지도를 옮기는 손짓이라 재생을 취소한다(대표 요청).
        cancelDayPlaybackIfRunning()
        recordUserMapAdjustment()
    }

    func updateVisibleMapSpan(_ span: MKCoordinateSpan) {
        let next = MKCoordinateSpan(
            latitudeDelta: min(max(span.latitudeDelta, 0.000_001), 180),
            longitudeDelta: min(max(span.longitudeDelta, 0.000_001), 360)
        )
        guard abs(visibleMapSpan.latitudeDelta - next.latitudeDelta) > 0.000_1
            || abs(visibleMapSpan.longitudeDelta - next.longitudeDelta) > 0.000_1
        else { return }
        visibleMapSpan = next
    }

    func applyMapCameraFrame(
        _ frame: MapHomeCameraFrame,
        using proxy: MapProxy
    ) {
        let locationPoint = displayedLocationCoordinate.flatMap {
            proxy.convert($0, to: .named("mapHomeViewport"))
        }
        applyMapCameraFrame(frame, locationPoint: locationPoint)
    }

    func applyMapCameraFrame(
        _ frame: MapHomeCameraFrame,
        locationPoint: CGPoint?
    ) {
        if let locationPoint {
            submitDisplayedStickmanViewportPoint(locationPoint)
        } else if displayedLocationCoordinate == nil {
            displayedStickmanViewportPoint = nil
        }
        if visibleMapCamera != frame.camera {
            visibleMapCamera = frame.camera
        }
        if visibleMapCenter.latitude != frame.centerLatitude
            || visibleMapCenter.longitude != frame.centerLongitude {
            visibleMapCenter = frame.center
        }
        updateVisibleMapSpan(frame.span)
        let isCentered = updateUserCenterState(locationPoint: locationPoint)
        if userTrackingMode == .locating, isCentered {
            setUserTrackingMode(.following)
        }
        if let level = sharedZoomLevel(for: frame.span),
           abs(level - sharedZoomLevel) > 0.02 {
            sharedZoomLevel = level
        }
    }

    func flushMapCameraFrame(using proxy: MapProxy) {
        guard let frame = mapCameraFrameProjection.finish(
            nowUptime: ProcessInfo.processInfo.systemUptime
        ) else { return }
        applyMapCameraFrame(frame, using: proxy)
    }
}
