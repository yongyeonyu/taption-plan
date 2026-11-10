import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    var userTrackingMode: MapHomeUserTrackingMode {
        MapHomeUserTrackingMode(rawValue: userTrackingModeRawValue) ?? .idle
    }

    /// 왼쪽 패널이 열려 있으면 지도를 그만큼 줄여 가리지 않는다.
    var mapLeadingInset: CGFloat {
        // 좁은 화면은 쓰지 않는 값이다. 시트 표시 상태를 읽으면 열 때마다 지도까지 다시 계산된다.
        guard isWideLayout else { return 0 }
        let panel: MapHomeWidePanelKind? = isCalendarPresented ? .calendar : isMenuOpen ? menuPanelKind
            : isDaySummaryPresented || isDailyCardPresented ? .standard : nil
        return MapHomeWideLayoutPolicy.mapLeadingInset(viewportWidth: mapViewportSize.width, openPanel: panel)
    }

    var mapSearchWidth: CGFloat {
        MapHomeSearchLayoutMath.searchWidth(
            viewportWidth: MapHomeWideLayoutPolicy.searchViewportWidth(mapViewportSize.width > 0 ? mapViewportSize.width : UIScreen.main.bounds.width),
            horizontalInset: Layout.horizontalInset,
            trailingControlCount: 1
        )
    }

    /// 검색 오버레이가 실제로 열려 있어 지도 탭으로 닫아야 하는 상태.
    /// 이게 아닐 때는 지도에 탭 제스처를 붙이지 않아 지도 팬·핀치와 경합하지 않는다.
    var isSearchDismissable: Bool {
        isSearchExpanded
            || isMapSearchFocused
            || hasMapSearchResults
            || !mapSearchText.isEmpty
            || selectedSearchPin != nil
    }

    var hasMapSearchResults: Bool {
        !mapSearchResults.isEmpty || !mapSearchCompleter.results.isEmpty || !mapSearchCompleter.kakaoResults.isEmpty
            || mapSearchNotice != nil || !localSearchMatches.isEmpty
    }

    var mapSearchResultCount: Int {
        mapSearchResults.isEmpty
            ? mapSearchCompleter.results.count + mapSearchCompleter.kakaoResults.count + localSearchMatches.count + (mapSearchNotice == nil ? 0 : 1)
            : mapSearchResults.count
    }

    /// 입력하는 동안 Apple 추천 위에 보일 등록 장소·지하철역.
    var localSearchMatches: [MapHomeSearchResult] {
        guard isMapSearchFocused, mapSearchResults.isEmpty else { return [] }
        return mapLocalMatches(mapSearchText)
    }

    var mapSearchSurfaceHeight: CGFloat {
        guard hasMapSearchResults else { return 42 }
        return 42 + 5 + MapHomeSearchLayoutMath.searchResultsHeight(
            resultCount: mapSearchResultCount
        )
    }

    @ViewBuilder
    var searchPinSheet: some View {
        if let selectedSearchPin = self.selectedSearchPin {
            MapHomeSearchPinLocationSheet(
                model: model,
                result: selectedSearchPin,
                language: language,
                onSaved: { createdSelection in
                    pendingUserLocationSelection = createdSelection
                    isSearchPinMenuPresented = false
                    self.selectedSearchPin = nil
                }
            )
            .presentationDragIndicator(.visible)
        }
    }

    /// 재생 중에는 초당 한 번만 다시 그리는 영역. 정지 중에는 늘 다시 그린다.
    func coarseRegion<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        EquatableView(content: MapHomeCoarseView(
            progress: playbackProgress,
            isFrozen: isDayPlaybackRunning,
            content: content
        ))
    }

    @ViewBuilder
    var map: some View {
        // 지도 provider가 OpenFreeMap(벡터, RPG 등)이면 무료 벡터 렌더러를 쓰고,
        // Apple 스타일이면 기존 MapKit 경로를 유지한다. 경로 재생·마커는 벡터
        // 렌더러도 지원한다(MapHomeVectorRoute/Marker).
        if let vectorStyle = model.settings.mapDisplayStyle.runtimeStyle.mapHomeVectorStyle {
            vectorMap(style: vectorStyle)
        } else {
            mapKitMap
                .overlay { appleSalaryOverlay }
        }
    }

    var mapCenterPoint: GeoPoint? {
        let candidate = visibleMapCenter
        if candidate.latitude.isFinite,
           candidate.longitude.isFinite,
           (-90...90).contains(candidate.latitude),
           (-180...180).contains(candidate.longitude),
           candidate.latitude != 0 || candidate.longitude != 0 {
            return GeoPoint(
                latitude: candidate.latitude,
                longitude: candidate.longitude,
                altitude: 0,
                horizontalAccuracy: 0,
                verticalAccuracy: 0
            )
        }
        guard let currentCoordinate else { return nil }
        return GeoPoint(
            latitude: currentCoordinate.latitude,
            longitude: currentCoordinate.longitude,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
    }

    /// 검색(돋보기) 원형 버튼. 누르면 상단 입력창이 펼쳐진다.
    var searchCircleButton: some View {
        Button {
            // 검색창이 열려 있으면 한 번 더 눌러 닫는다. 다른 곳을 눌러 닫히는 동작은 그대로다.
            if isSearchDismissable {
                withAnimation(.easeInOut(duration: 0.2)) {
                    dismissMapSearchOverlay()
                    isMapSearchFocused = false
                    isSearchExpanded = false
                }
                return
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                isSearchExpanded = true
            }
            // 창이 마운트된 다음 런루프에 포커스를 줘야 @FocusState가 무시되지 않는다.
            DispatchQueue.main.async {
                isMapSearchFocused = true
            }
        } label: {
            TaptionBarIcon(systemImage: "magnifyingglass", size: 25)
                .frame(width: 40, height: 40)
                .background { TaptionStickerDisc() }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.text("장소 검색", "Search places"))
    }

    /// Map Home이 실제로 MapLibre 벡터 렌더러로 그려지는지(= Apple 스타일이 아님).
    /// 카메라 이동 명령 경로를 실제 렌더 엔진에 맞춰 고르는 데 쓴다.
    var rendersVectorMap: Bool {
        model.settings.mapDisplayStyle.runtimeStyle.mapHomeVectorStyle != nil
    }

    var vectorMapContentInsets: UIEdgeInsets {
        .zero
    }

    func vectorMap(style: MapHomeVectorStyle) -> some View {
        let cameraRevision = mapCameraRevision
        let waypoints = pawprintWaypoints
        // 재생 분과 무관한 고정 레이어. 내용이 같으면 정렬·색 계산을 다시 하지 않는다(OPT1102A01).
        let statics = playbackStaticLayers(waypoints: waypoints)
        let inputs = mapOverlayInputs()
        let places = inputs.places
        let playback = appleMapPlayback
        let displayedSpeed = displayedSpeedMetersPerSecond
        let activeSegments = vectorActiveRouteSegments
        return MapHomeVectorMap(
            style: style,
            cameraPosition: mapPosition,
            cameraRevision: mapCameraRevision,
            historicalRoutes: recordingShows(\.routes) ? vectorHistoricalRoutes : [],
            activeRoute: recordingShows(\.routes) && activeSegments.isEmpty ? vectorActiveRoute : nil,
            expectedRoutes: recordingShows(\.routes) ? vectorExpectedRoutes + vectorTravelRoutes : [],
            subwayRoutes: recordingShows(\.routes) ? vectorSubwayRoutes + vectorUserSelectedRoutes : [],
            markers: vectorMapMarkers(waypoints: waypoints, inputs: inputs),
            contentInsets: vectorMapContentInsets,
            longPressExclusionFrame: isMenuOpen ? .zero : mapControlsFrame,
            followsHeading: isHeadingMode && userTrackingMode.keepsCameraLocked,
            headingDegrees: -compassRotationDegrees,
            displayedCoordinate: displayedLocationCoordinate,
            easesCamera: isDayPlaybackRunning,
            playbackDriver: playbackDriver,
            onPlaybackStickmanPoint: { point in
                vectorMapViewportStore.publishPlaybackPoint(point, nowUptime: ProcessInfo.processInfo.systemUptime)
            },
            onPlaybackViewport: { viewport in
                vectorMapViewportStore.livePlaybackViewport = viewport
            },
            onViewportChange: { viewport, isFinal in
                guard cameraRevision == mapCameraRevision else { return }
                applyVectorMapViewport(viewport, isFinal: isFinal)
            },
            onSingleFingerPanBegan: handleUserMapPan,
            onSingleFingerPanEnded: finishDisplayedStickmanViewportProjection,
            onUserCameraGesture: handleUserCameraGesture,
            onLongPress: presentMapLongPressMenu,
            onSingleTap: { point, positions in
                handleMapTap(atLocal: point, waypoints: waypoints, positions: positions)
            },
            activeRouteSegments: recordingShows(\.routes) ? activeSegments : [],
            layerPawprints: playbackLayerPawprints(statics),
            languageKey: languageRawValue
        )
        .id(style.rawValue)
        .overlay {
            if !Self.benchHidden("overlay") {
            MapHomeVectorViewportOverlay(store: vectorMapViewportStore, isLive: playbackDriver != nil) {
                viewport, stickmanPoint in
                vectorMapAnnotationOverlay(
                    style: style,
                    viewport: viewport,
                    stickmanPoint: stickmanPoint,
                    statics: statics,
                    inputs: inputs,
                    playback: playback,
                    displayedSpeed: displayedSpeed
                )
            }
            }
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("mapHomeViewport")) }) { frame in
            if mapFrameInViewport != frame { mapFrameInViewport = frame }
        }
        .task {
            applyInitialLocationIfAvailable(using: nil)
            beginInitialLocationRequest(using: nil)
        }
        .onChange(of: mapViewportSize) { _, size in
            guard size.width > 0, size.height > 0 else { return }
            applyInitialLocationIfAvailable(using: nil)
            beginInitialLocationRequest(using: nil)
        }
        .onChange(of: selectedTimelineMinute) { _, minute in
            if isTimelineInteractionActive || isDayPlaybackRunning {
                let interval = isDayPlaybackRunning
                    ? MapHomeDayPlaybackMath.mapFocusInterval
                    : TimelineInteractionFrameGate.minimumInterval
                let now = ProcessInfo.processInfo.systemUptime
                let shouldFocus: Bool
                if isDayPlaybackRunning {
                    shouldFocus = !isPlaybackIntroActive && TimelineInteractionFrameGate.shouldRender(
                        lastUptime: &lastPlaybackMapFocusUptime,
                        nowUptime: now,
                        minimumInterval: interval
                    )
                } else {
                    shouldFocus = TimelineInteractionFrameGate.shouldRender(
                        lastUptime: &lastTimelineMapFocusUptime,
                        nowUptime: now,
                        minimumInterval: interval
                    )
                }
                guard shouldFocus, playbackDriver == nil else { return }
                guard let point = displayedPlaybackFocusPoint else { return }
                focusMap(on: point, using: nil, followsTracking: true)
            } else {
                refreshSelectedTimelineMapPosition(minute: minute, using: nil)
            }
        }
        .onChange(of: dayPlaybackCurrentMinute) { _, _ in
            // 벡터 지도에서는 구동기가 프레임마다 카메라를 놓는다(PLY1029A03). 여기는 Apple 지도 재생용이다.
            guard isDayPlaybackRunning, playbackDriver == nil,
                  TimelineInteractionFrameGate.shouldRender(
                      lastUptime: &lastPlaybackMapFocusUptime,
                      nowUptime: ProcessInfo.processInfo.systemUptime,
                      minimumInterval: MapHomeDayPlaybackMath.mapFocusInterval
                  ) else { return }
            recordPlaybackFocusSample()
            guard let point = displayedPlaybackFocusPoint else { return }
            focusMap(on: point, using: nil, followsTracking: true)
        }
        .onChange(of: isTimelineInteractionActive) { _, isInteracting in
            guard !isInteracting, !isDayPlaybackRunning,
                  selectedTimelineMinute != nil else { return }
            refreshSelectedTimelineMapPosition(
                minute: selectedTimelineMinute,
                using: nil
            )
            finishDisplayedStickmanViewportProjection()
        }
        .onChange(of: model.latestSensorReading?.id) { _, _ in
            applyInitialLocationIfAvailable(using: nil)
            guard MapHomeUserTrackingPolicy.focusesLocationUpdates(
                in: userTrackingMode
            ) else { return }
            focusDisplayedLocation(using: nil)
        }
        .onChange(of: model.liveRouteState.readings.last?.id) { _, _ in
            guard MapHomeUserTrackingPolicy.focusesLocationUpdates(
                in: userTrackingMode
            ) else { return }
            focusDisplayedLocation(using: nil)
        }
    }

    var mapKitMap: some View {
        MapHomeAppleMap(
            style: model.settings.mapDisplayStyle.runtimeStyle,
            accessibilityLabel: language.text("Apple 지도", "Apple map"),
            cameraPosition: mapPosition,
            cameraRevision: mapCameraRevision,
            viewportCommand: appleViewportCommand,
            routes: recordingShows(\.routes) ? appleMapRoutes + appleTravelRoutes : [],
            annotations: appleMapAnnotations,
            playback: appleMapPlayback,
            centersPlayback: selectedTimelineMinute != nil
                || isTimelineInteractionActive
                || userTrackingMode.keepsCameraLocked,
            playbackTargetPoint: currentLocationTargetPoint,
            playbackDriver: playbackDriver,
            contentInsets: vectorMapContentInsets,
            longPressExclusionFrame: isMenuOpen ? .zero : mapControlsFrame,
            fogReveals: appleFogReveals,
            fogOpacity: CGFloat(fogStrength.opacity),
            onLiveStickmanPoint: { appleStickmanLivePoint.point = $0 },
            counterAttachment: appleStickmanLivePoint.markerAttachment,
            onCameraFrame: { frame, locationPoint, isFinal in
                MapHomeHomeSkyHeading.current = frame.camera.heading
                MapHomeInteractionMonitor.shared.touch("map_gesture")
                let now = ProcessInfo.processInfo.systemUptime
                let moving = !isFinal || playbackDriver != nil
                if isAppleCameraMoving != moving { isAppleCameraMoving = moving }
                if let rendered = mapCameraFrameProjection.submit(
                    frame,
                    nowUptime: now,
                    force: isFinal
                ), mapCameraFrameProjection.shouldPublishParentReadback(
                    nowUptime: now,
                    isFinal: isFinal
                ) {
                    applyMapCameraFrame(rendered, locationPoint: locationPoint)
                }
                // 손을 뗀 마지막 점은 입력 예산에 걸려도 버리지 않는다(탭 판정·안개 기준).
                if isFinal, playbackDriver == nil {
                    finishDisplayedStickmanViewportProjection()
                }
            },
            onSingleFingerPanBegan: handleUserMapPan,
            onUserCameraGesture: handleUserCameraGesture,
            onLongPress: presentMapLongPressMenu,
            onAnnotationSelected: handleAppleMapAnnotation,
            onMapTap: { local, hitsWalker in
                if hitsWalker {
                    // 벡터 지도 탭 경로(handleMapTap)와 같이 검색 결과도 닫는다(REV1107A01).
                    if isSearchDismissable { dismissMapSearchOverlay() }
                    foldPhotoRingOnMapTap()
                    toggleCounterFromCat()
                    return
                }
                handleMapTap(atLocal: local, waypoints: pawprintWaypoints, positions: nil)
            }
        )
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("mapHomeViewport")) }) { frame in
            if mapFrameInViewport != frame { mapFrameInViewport = frame }
        }
        .task {
            applyInitialLocationIfAvailable(using: nil)
            beginInitialLocationRequest(using: nil)
        }
        .onChange(of: mapViewportSize) { _, size in
            guard size.width > 0, size.height > 0 else { return }
            applyInitialLocationIfAvailable(using: nil)
            beginInitialLocationRequest(using: nil)
        }
        .onChange(of: headingMonitor.headingDegrees) { _, _ in
            applyMapHeading(using: nil)
        }
        .onChange(of: dayPlaybackCurrentMinute) { _, _ in
            advanceApplePlaybackZoom()
        }
        .onChange(of: isTimelineInteractionActive) { _, isInteracting in
            guard !isInteracting else { return }
            flushDeferredWBSPlaybackProjection()
            finishDisplayedStickmanViewportProjection()
        }
        .onChange(of: model.latestSensorReading?.id) { _, _ in
            applyInitialLocationIfAvailable(using: nil)
            guard MapHomeUserTrackingPolicy.focusesLocationUpdates(
                in: userTrackingMode
            ) else { return }
            focusDisplayedLocation(using: nil)
        }
        .onChange(of: model.liveRouteState.readings.last?.id) { _, _ in
            guard MapHomeUserTrackingPolicy.focusesLocationUpdates(
                in: userTrackingMode
            ) else { return }
            focusDisplayedLocation(using: nil)
        }
    }

    var appleMapAnnotations: [MapHomeAppleAnnotation] {
        let probe = MapHomePlaybackProbe.begin("apple.annotationsBuild"); defer { MapHomePlaybackProbe.end(probe) }
        var annotations = temporaryLocationAnnotations.map { location in
            MapHomeAppleAnnotation(
                id: "temporary-\(location.id.uuidString)",
                coordinate: location.coordinate,
                kind: .temporary(
                    stationName: location.stationName,
                    title: language.text("임시 위치", "Temporary")
                ),
                accessibilityLabel: language.text(
                    "\(location.stationName) 지하철 임시 위치",
                    "\(location.stationName) temporary subway location"
                ),
                isInteractive: false
            )
        }
        annotations += (recordingShows(\.placeIcons) ? placeAnnotations : []).map { place in
            MapHomeAppleAnnotation(
                id: "place-\(place.id.uuidString)",
                coordinate: place.coordinate,
                kind: .place(place),
                accessibilityLabel: language.text(
                    "\(place.name) 사용자 위치 메뉴",
                    "\(place.name) user location menu"
                ),
                isInteractive: place.destination != .home
            )
        }
        annotations += transitAnnotations.map { place in
            MapHomeAppleAnnotation(
                id: "transit-\(place.id.uuidString)",
                coordinate: place.coordinate,
                kind: .transit(place),
                accessibilityLabel: language.text(
                    "\(place.name) 사용자 위치 메뉴",
                    "\(place.name) user location menu"
                ),
                isInteractive: true
            )
        }
        annotations += transitBoardingCandidates.map { candidate in
            MapHomeAppleAnnotation(
                id: "boarding-\(candidate.id)",
                coordinate: CLLocationCoordinate2D(
                    latitude: candidate.point.latitude,
                    longitude: candidate.point.longitude
                ),
                kind: .boarding(candidate),
                accessibilityLabel: language.text(
                    "\(candidate.name) \(candidate.kind.title) 탑승 확인",
                    "Confirm boarding at \(candidate.name) \(candidate.kind.englishTitle)"
                ),
                isInteractive: true
            )
        }
        annotations += mapStickersOnMap.compactMap { sticker in
            guard let point = sticker.point else { return nil }
            return MapHomeAppleAnnotation(
                id: "sticker-\(sticker.id.uuidString)",
                coordinate: CLLocationCoordinate2D(
                    latitude: point.latitude,
                    longitude: point.longitude
                ),
                kind: .sticker(sticker),
                accessibilityLabel: language.text(
                    "\(sticker.title) 메모 스티커",
                    "\(sticker.title) memo sticker"
                ),
                isInteractive: isStickerMode
            )
        }
        annotations += photoClusters.compactMap { cluster in
            guard let info = photoPinInfo(for: cluster) else { return nil }
            return MapHomeAppleAnnotation(
                id: "photo-\(cluster.id)",
                coordinate: cluster.coordinate,
                kind: .photo(cluster, coverID: info.coverID, isHighlighted: info.highlighted),
                accessibilityLabel: language.text("사진 \(cluster.count)장", "\(cluster.count) photos"),
                isInteractive: true
            )
        }
        annotations += mapMemosOnMap.compactMap { memo in
            guard let point = memo.mapPoint else { return nil }
            return MapHomeAppleAnnotation(
                id: "memo-\(memo.id.uuidString)",
                coordinate: CLLocationCoordinate2D(
                    latitude: point.latitude,
                    longitude: point.longitude
                ),
                kind: .memo(memo),
                accessibilityLabel: language.text(
                    "\(memo.text) 지도 메모, \(memo.occurredAt.formatted(date: .omitted, time: .shortened))",
                    "\(memo.text) map memo, \(memo.occurredAt.formatted(date: .omitted, time: .shortened))"
                ),
                isInteractive: true
            )
        }
        for (index, stop) in travelStopsOnSelectedDay.enumerated() {
            annotations.append(
                MapHomeAppleAnnotation(
                    id: travelStopMarkerID(stop),
                    coordinate: stop.coordinate,
                    kind: .travelStop(number: index + 1),
                    accessibilityLabel: stop.title,
                    isInteractive: false
                )
            )
        }
        if let selectedSearchPin {
            annotations.append(
                MapHomeAppleAnnotation(
                    id: "search-pin",
                    coordinate: selectedSearchPin.coordinate,
                    kind: .search(selectedSearchPin),
                    accessibilityLabel: language.text(
                        "\(selectedSearchPin.title) 위치 추가",
                        "Add \(selectedSearchPin.title) location"
                    ),
                    isInteractive: true
                )
            )
        }
        for waypoint in playbackVisibleWaypoints(recordingShows(\.footprints) ? pawprintWaypoints : []).suffix(300) {
            let isSelectedRoute = waypoint.isPredicted && waypoint.predictedRoute != nil
                && waypoint.predictedRoute?.id == selectedPredictedRoute?.id
            let isInteractive = waypoint.predictedRoute != nil
                || (waypoint.timestamp != nil && !waypoint.isPredicted)
            annotations.append(
                MapHomeAppleAnnotation(
                    id: vectorPawprintMarkerID(waypoint.index),
                    coordinate: waypoint.coordinate,
                    kind: .pawprint(MapHomeApplePawprint(
                        index: waypoint.index, angle: waypoint.angle,
                        isPredicted: waypoint.isPredicted, isSelectedRoute: isSelectedRoute,
                        speedMetersPerSecond: waypoint.speedMetersPerSecond
                    )),
                    accessibilityLabel: waypoint.predictedRoute != nil
                        ? language.text("예상 경로 선택", "Select predicted route")
                        : waypoint.timestamp.map {
                            language.text("기록 발자국 ", "Recorded paw ")
                                + $0.formatted(date: .omitted, time: .shortened)
                        } ?? "",
                    isInteractive: isInteractive
                )
            )
        }
        return annotations
    }

    func handleAppleMapAnnotation(_ kind: MapHomeAppleAnnotationKind) {
        switch kind {
        case .temporary:
            break
        case .place(let place):
            if place.destination == .home {
                isDaySummaryPresented = true
                return
            }
            selectedUserLocation = .frequentPlace(place.id)
        case .photo(let cluster, _, _):
            photoBrowserSelection = MapHomePhotoBrowserSelection(startID: cluster.moments.first?.id)
        case .transit(let place):
            selectedUserLocation = .transit(place.id)
        case .boarding(let candidate):
            selectedTransitBoardingCandidate = candidate
        case .sticker(let sticker):
            selectedMapStickerEditor = .sticker(sticker.id)
        case .memo(let memo):
            selectedMapStickerEditor = .memo(memo.id)
        case .search:
            isSearchPinMenuPresented = true
        case .travelStop:
            break
        case .pawprint(let paw):
            if let waypoint = pawprintWaypoints.first(where: { $0.index == paw.index }) {
                selectPawprint(waypoint)
            }
        }
    }

    func vectorMapMarkers(waypoints: [PawprintWaypoint], inputs: MapHomeOverlayInputs) -> [MapHomeVectorMarker] {
        let probe = MapHomePlaybackProbe.begin("vectorMapMarkers"); defer { MapHomePlaybackProbe.end(probe) }
        var markers = inputs.temporaryLocations.map {
            MapHomeVectorMarker(
                id: vectorTemporaryMarkerID($0.id),
                coordinate: $0.coordinate
            )
        }
        markers += inputs.places.map {
            MapHomeVectorMarker(
                id: vectorPlaceMarkerID($0.id),
                coordinate: $0.coordinate
            )
        }
        markers += inputs.transit.map {
            MapHomeVectorMarker(
                id: vectorTransitMarkerID($0.id),
                coordinate: $0.coordinate
            )
        }
        markers += inputs.boarding.map {
            MapHomeVectorMarker(
                id: vectorBoardingCandidateMarkerID($0.id),
                coordinate: CLLocationCoordinate2D(
                    latitude: $0.point.latitude,
                    longitude: $0.point.longitude
                )
            )
        }
        markers += inputs.stickers.compactMap { sticker in
            guard let point = sticker.point else { return nil }
            return MapHomeVectorMarker(
                id: vectorMapStickerMarkerID(sticker.id),
                coordinate: CLLocationCoordinate2D(
                    latitude: point.latitude,
                    longitude: point.longitude
                )
            )
        }
        markers += inputs.photos.map {
            MapHomeVectorMarker(id: vectorPhotoMarkerID($0.id), coordinate: $0.coordinate)
        }
        markers += inputs.memos.compactMap { memo in
            guard let point = memo.mapPoint else { return nil }
            return MapHomeVectorMarker(
                id: vectorMapMemoMarkerID(memo.id),
                coordinate: CLLocationCoordinate2D(
                    latitude: point.latitude,
                    longitude: point.longitude
                )
            )
        }
        if let displayedLocationCoordinate {
            markers.append(
                MapHomeVectorMarker(
                    id: vectorDisplayedMarkerID,
                    coordinate: displayedLocationCoordinate
                )
            )
        }
        for stop in travelStopsOnSelectedDay {
            markers.append(MapHomeVectorMarker(id: travelStopMarkerID(stop), coordinate: stop.coordinate))
        }
        if let selectedSearchPin {
            markers.append(
                MapHomeVectorMarker(
                    id: vectorSearchMarkerID,
                    coordinate: selectedSearchPin.coordinate
                )
            )
        }
        for waypoint in waypoints {
            markers.append(
                MapHomeVectorMarker(
                    id: vectorPawprintMarkerID(waypoint.index),
                    coordinate: waypoint.coordinate
                )
            )
        }
        return markers
    }

    /// 화랑이를 누르면 카운터 창을 보이거나 숨긴다(CTR1107A01). 발자국·집 아이콘보다 먼저 판정한다.
    /// 지도 탭 한 경로(UIKit 탭이 부른다). 좌표는 지도 로컬 하나만 쓴다. 예전에는 SwiftUI 탭(뷰포트 좌표)과
    /// UIKit 탭(지도 로컬 좌표)이 같은 손짓을 두 번 판정했고, 카운터 창 판정에 서로 다른 좌표가 섞였다(PRF1101A01).
    func handleMapTap(atLocal local: CGPoint, waypoints: [PawprintWaypoint], positions: [String: CGPoint]?) {
        foldPhotoRingOnMapTap()
        defer { if isSearchDismissable { dismissMapSearchOverlay() } }
        if isCounterWindowTapped(at: local) {
            openCounterDetail(at: local)
            return
        }
        if isStickmanTapped(at: local) {
            toggleCounterFromCat()
            return
        }
        if handleMapMarkerTap(at: local) { return }
        if let waypoint = pawprintTarget(at: local, waypoints: waypoints, positions: positions) {
            selectPawprint(waypoint)
            return
        }
        if isHomeSummaryTapped(at: local) { isDaySummaryPresented = true }
    }

    func viewportPoint(fromMapLocal point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + mapFrameInViewport.minX, y: point.y + mapFrameInViewport.minY)
    }

    /// 지도 위 핀(메모·사진·탑승 후보·대중교통·장소)은 터치를 받지 않고 여기서 위치로 판정한다.
    /// 핀이 두 손가락 핀치를 가로채지 않게 하려는 것이다(대표 지시). 위에 그려진 것부터 본다.
    func handleMapMarkerTap(at tapPoint: CGPoint) -> Bool {
        guard let viewport = vectorMapViewportStore.viewport else { return false }
        func hit(_ id: String, width: CGFloat = 56, height: CGFloat = 64) -> Bool {
            guard let point = vectorPoint(in: viewport, for: id) else { return false }
            return CGRect(x: point.x - width / 2, y: point.y - height, width: width, height: height + 10).contains(tapPoint)
        }
        if recordingShows(\.mapMemos), let memo = mapMemosOnMap.last(where: { hit(vectorMapMemoMarkerID($0.id)) }) {
            selectedMapStickerEditor = .memo(memo.id)
            return true
        }
        if !isScreenRecording,
           let cluster = photoClusters.last(where: { cluster in
               photoPinPoint(cluster, in: viewport, places: placeAnnotations).map {
                   CGRect(x: $0.x - 28, y: $0.y - 64, width: 56, height: 74).contains(tapPoint)
               } ?? false
           }) {
            photoBrowserSelection = MapHomePhotoBrowserSelection(startID: cluster.moments.first?.id)
            return true
        }
        if let candidate = transitBoardingCandidates.last(where: { hit(vectorBoardingCandidateMarkerID($0.id)) }) {
            selectedTransitBoardingCandidate = candidate
            return true
        }
        if let place = transitAnnotations.last(where: { hit(vectorTransitMarkerID($0.id)) }) {
            selectedUserLocation = .transit(place.id)
            return true
        }
        // 집 핀은 아래 `isHomeSummaryTapped`가 맡는다.
        if let place = placeAnnotations.last(where: {
            $0.destination != .home && hit(vectorPlaceMarkerID($0.id), width: 80, height: 90)
        }) {
            selectedUserLocation = .frequentPlace(place.id)
            return true
        }
        return false
    }

    func vectorTemporaryMarkerID(_ id: UUID) -> String {
        "temporary-\(id.uuidString)"
    }

    func vectorPawprintMarkerID(_ index: Int) -> String {
        Self.pawprintMarkerID(index)
    }

    func placeLandFromMap(x: Int, y: Int) {
        guard canWriteHomeGrowth else { return }
        var history = homeGrowthHistory
        guard let plotID = history.season.landPlots.first(where: { id in
            !(history.season.landPlotPlacements ?? []).contains { $0.plotID == id }
        }), MapHomeGrowthPolicy.placeLandPlot(plotID, atX: x, y: y, in: &history.season),
              let encoded = try? JSONEncoder().encode(history) else { return }
        homeGrowthData = encoded
    }

    func vectorPlaceMarkerID(_ id: UUID) -> String {
        "place-\(id.uuidString)"
    }

    func vectorBoardingCandidateMarkerID(_ id: String) -> String {
        "boarding-candidate-\(id)"
    }

    func applyVectorMapViewport(
        _ viewport: MapHomeVectorViewport,
        isFinal: Bool
    ) {
        guard scenePhase == .active else { return }
        MapHomeHomeSkyHeading.current = viewport.heading
        MapHomeInteractionMonitor.shared.touch("map_gesture")
        let now = ProcessInfo.processInfo.systemUptime
        // 구동기 재생 중에는 화면 값을 간격마다만 관찰 값으로 올리고, 화랑이 점은 구동기가 맡는다(PLY1029A03·PLY1029A05).
        // "이동 완료"(isFinal)도 예외가 아니다: 애니메이션 없이 놓은 카메라는 매 프레임 이동 완료를 알려,
        // 예전에는 여기서 매 프레임 화면 전체를 다시 그렸다(틱 하나에 오버레이 4번, PLY1029A09).
        if playbackDriver != nil {
            vectorMapViewportStore.updateViewportThrottled(viewport, nowUptime: now)
            return
        }
        vectorMapViewportStore.update(viewport)
        let displayedPoint = viewport.markerPoints[vectorDisplayedMarkerID]
        if let displayedPoint {
            vectorMapViewportStore.updateStickmanPoint(
                displayedPoint,
                nowUptime: now
            )
        }
        let frame = MapHomeCameraFrame(
            camera: viewport.camera,
            region: viewport.region
        )
        _ = mapCameraFrameProjection.submit(
            frame,
            nowUptime: now,
            force: isFinal
        )
        if vectorMapViewportStore.shouldPublishParentReadback(
            nowUptime: now,
            isFinal: isFinal
        ), let latestFrame = mapCameraFrameProjection.latestFrame {
            applyMapCameraFrame(latestFrame, locationPoint: displayedPoint)
        }
        if isFinal {
            vectorMapViewportStore.finishStickmanPoint(nowUptime: now)
        }
    }

    var mapSearchBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    language.text("장소·주소 검색", "Search places or addresses"),
                    text: $mapSearchText
                )
                .focused($isMapSearchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { searchMap() }
                .onChange(of: mapSearchText) { _, value in
                    guard isMapSearchFocused else { return }
                    mapSearchResults = []
                    mapSearchNotice = nil
                    mapSearchCompleter.update(
                        query: value,
                        region: mapSearchRegion
                    )
                }
                .onChange(of: isMapSearchFocused) { _, focused in
                    if focused {
                        isSearchExpanded = true
                        mapSearchCompleter.update(
                            query: mapSearchText,
                            region: mapSearchRegion
                        )
                    } else if mapSearchText.isEmpty
                        && mapSearchResults.isEmpty
                        && selectedSearchPin == nil {
                        isSearchExpanded = false
                    }
                }
                if !mapSearchText.isEmpty || !mapSearchResults.isEmpty || selectedSearchPin != nil {
                    Button {
                        clearMapSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            // 그림은 17pt라 그대로 두면 손가락이 닿지 않는다. 누름 영역만 넓힌다.
                            .taptionHitOutset(horizontal: 14, vertical: 14)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(language.text("검색 지우기", "Clear search"))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .taptionRaised(.rounded(14), fill: Color.tpSurface)
            .onGeometryChange(
                for: CGRect.self,
                of: { proxy in
                    proxy.frame(in: .named("mapHomeViewport"))
                },
                action: { frame in
                    guard searchFieldFrame != frame else { return }
                    searchFieldFrame = frame
                }
            )

            if hasMapSearchResults {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if mapSearchResults.isEmpty {
                            if let mapSearchNotice {
                                Text(mapSearchNotice)
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                            }
                            ForEach(localSearchMatches) { result in
                                mapSearchRow(title: result.title, subtitle: result.subtitle) { selectSearchResult(result) }
                            }
                            ForEach(mapSearchCompleter.kakaoResults) { result in
                                mapSearchRow(title: result.title, subtitle: result.subtitle) { selectSearchResult(result) }
                            }
                            ForEach(
                                Array(mapSearchCompleter.results.enumerated()),
                                id: \.offset
                            ) { _, completion in
                                mapSearchRow(
                                    title: completion.title,
                                    subtitle: completion.subtitle
                                ) {
                                    searchMap(completion: completion)
                                }
                            }
                        } else {
                            ForEach(mapSearchResults) { result in
                                mapSearchRow(
                                    title: result.title,
                                    subtitle: result.subtitle
                                ) {
                                    selectSearchResult(result)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(
                    height: MapHomeSearchLayoutMath.searchResultsHeight(
                        resultCount: mapSearchResultCount
                    ),
                    alignment: .top
                )
                .background(Color.tpSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.tpLine.opacity(0.7), lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
        }
        .frame(
            width: mapSearchWidth,
            height: mapSearchSurfaceHeight,
            alignment: .top
        )
    }

    func mapStyleTitle(_ style: MapDisplayStyle) -> String {
        switch style {
        case .standard: language.text("애플맵", "Apple Maps")
        case .hybrid: language.text("위성", "Satellite")
        // 스타일 이름은 재질이 아니라 상황으로 적는다. "벡터 야간"을 고르려는 사람은 없다.
        case .mapLibreNight: language.text("야간", "Night")
        case .mapLibreContrast: language.text("실외(고대비)", "Outdoor (high contrast)")
        case .mapLibreCasual: language.text("계절", "Seasons")
        case .mapLibreRPG: language.text("판타지 지도", "Fantasy Map")
        case .mapLibreInk: language.text("수묵", "Ink Wash")
        }
    }

    func mapStyleSystemImage(_ style: MapDisplayStyle) -> String {
        switch style {
        case .standard: "map"
        case .hybrid: "globe.asia.australia.fill"
        case .mapLibreNight: "moon.stars.fill"
        case .mapLibreContrast: "circle.lefthalf.filled"
        case .mapLibreCasual: "leaf.fill"
        case .mapLibreRPG: "map.circle.fill"
        case .mapLibreInk: "paintbrush.pointed.fill"
        }
    }

    func mapSearchRow(
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    .foregroundStyle(Color.tpReferenceBlue)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: MapHomeSearchLayoutMath.searchRowHeight)
        }
        .buttonStyle(.plain)
    }

    /// 등록 장소·다녀온 곳·지하철역에서 이름 중간 글자로도 찾는다(SRC1108A01).
    func mapLocalMatches(_ query: String) -> [MapHomeSearchResult] {
        MapHomeSearchPolicy.localMatches(
            query,
            places: model.settings.frequentPlaces,
            visited: model.snapshot.places,
            origin: currentCoordinate,
            language: language
        )
    }

    var mapSearchRegion: MKCoordinateRegion {
        MapHomeSearchPolicy.region(visibleCenter: visibleMapCenter, visibleSpan: visibleMapSpan, current: currentCoordinate)
    }

    func clearMapSearch() {
        mapSearchTask?.cancel()
        mapSearchTask = nil
        mapSearchRequestID = UUID()
        mapSearchCompleter.clear()
        mapSearchText = ""
        mapSearchResults = []
        mapSearchNotice = nil
        selectedSearchPin = nil
        isSearchPinMenuPresented = false
        isMapSearchFocused = false
        isSearchExpanded = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    func searchMap() {
        let query = mapSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            mapSearchResults = []
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = mapSearchRegion
        runMapSearch(request, fallbackTitle: query, showsList: true)
    }

    func searchMap(completion: MKLocalSearchCompletion) {
        let request = MKLocalSearch.Request(completion: completion)
        request.region = mapSearchRegion
        runMapSearch(request, fallbackTitle: completion.title)
    }

    /// 검색 단추로 찾으면 결과 목록을 보여 고르게 하고(하나면 바로 간다), 추천을 눌렀으면 그 곳으로 간다.
    /// 결과가 없거나 실패하면 목록 자리에 알린다. 예전에는 첫 결과로 곧장 옮기고 실패는 조용히 지웠다(SRC1107A01).
    func runMapSearch(
        _ request: MKLocalSearch.Request,
        fallbackTitle: String,
        showsList: Bool = false
    ) {
        mapSearchTask?.cancel()
        let requestID = UUID()
        mapSearchRequestID = requestID
        let local = showsList ? mapLocalMatches(fallbackTitle) : []
        let origin = currentCoordinate
        let center = mapSearchRegion.center
        mapSearchTask = Task { @MainActor in
            // 국내는 카카오만 쓰고, 카카오가 비었을 때만 Apple로 넘어간다(대표 지시).
            let kakao = showsList ? await MapHomeKakaoSearch.search(query: fallbackTitle, center: center) : []
            let (items, failed) = kakao.isEmpty ? await MapHomeSearchRunner.items(for: request) : ([], false)
            guard !Task.isCancelled, requestID == mapSearchRequestID else { return }
            let found = MapHomeSearchPolicy.sortedByDistance(items.prefix(8).map { item in
                MapHomeSearchResult(
                    title: item.name ?? fallbackTitle,
                    subtitle: item.placemark.title ?? "",
                    coordinate: item.placemark.coordinate
                )
            }, from: origin)
            let results = MapHomeSearchPolicy.merged([local, kakao, found])
            // Apple 전체 검색은 「사이언스」처럼 이름 일부로는 비어 오는데, 추천 목록에는 근처 결과가 있다. 그때는 추천 목록을 그대로 둔다.
            if results.isEmpty, !failed, !mapSearchCompleter.results.isEmpty || !mapSearchCompleter.kakaoResults.isEmpty { return }
            mapSearchCompleter.clear()
            if results.count == 1 || (!showsList && !results.isEmpty) {
                selectSearchResult(results[0])
            } else if results.isEmpty {
                mapSearchResults = []
                mapSearchNotice = failed
                    ? language.text("검색하지 못했습니다. 연결을 확인해 주세요.", "Search failed. Check your connection.")
                    : language.text("검색 결과가 없습니다.", "No results.")
            } else {
                mapSearchResults = results
            }
        }
    }

    /// 장소 도감 카드를 지도에 표시한다. 해외 도시는 고른 직항 공항 자리다(PLB1109A01).
    func showPlaceBookEntryOnMap(_ pin: MapHomePlaceBookPin) {
        isPlaceBookPresented = false
        isMenuOpen = false
        // 시트와 메뉴가 다 닫힌 뒤 지도를 옮긴다. 닫히는 동안 옮기면 카메라 이동이 적용되지 않는다.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            selectSearchResult(MapHomeSearchResult(
                title: pin.title,
                subtitle: pin.subtitle,
                coordinate: CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
            ))
        }
    }

    func selectSearchResult(_ result: MapHomeSearchResult) {
        focusMap(
            on: GeoPoint(
                latitude: result.coordinate.latitude,
                longitude: result.coordinate.longitude,
                altitude: 0,
                horizontalAccuracy: -1,
                verticalAccuracy: -1
            )
        )
        selectedSearchPin = result
        mapSearchResults = []
        mapSearchNotice = nil
        mapSearchCompleter.clear()
        isMapSearchFocused = false
        isSearchExpanded = false
        mapSearchText = result.title
    }

    func mapControls(
        proxy: MapProxy?,
        railHeight: CGFloat
    ) -> some View {
        // 검색·메모·일정은 왼쪽 상단 한 줄에 둔다(대표 지시). 아래 왼쪽 자리는 비운다.
        return Color.clear
            .frame(width: timeRailWidth, height: railHeight)
            .allowsHitTesting(false)
        .shadow(color: .black.opacity(0.045), radius: 5, y: 1)
    }

    func mapZoomButton(
        systemImage: String,
        direction: Int,
        proxy: MapProxy?
    ) -> some View {
        Button {
            adjustMapZoom(direction: direction, proxy: proxy)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: Layout.mapControlIcon, weight: .bold))
                .foregroundStyle(Color.tpInk)
                .frame(width: Layout.mapControlSize, height: Layout.mapControlSize)
        }
        .accessibilityLabel(
            direction > 0
                ? language.text("지도 확대", "Zoom map in")
                : language.text("지도 축소", "Zoom map out")
        )
        .disabled(
            MapHomeCameraZoomMath.isAtLimit(
                distance: visibleMapCamera?.distance,
                direction: direction
            )
        )
    }

    func adjustMapZoom(direction: Int, proxy: MapProxy?) {
        guard let camera = visibleMapCamera else { return }
        let distance = MapHomeCameraZoomMath.distance(
            from: camera.distance,
            direction: direction
        )
        guard distance != camera.distance else { return }
        recordUserMapAdjustment()
        let anchor = userTrackingMode.keepsCameraLocked || isMapCenteredOnUser
            ? displayedLocationCoordinate ?? camera.centerCoordinate
            : camera.centerCoordinate
        let center = MapHomeCameraZoomMath.centerPreservingAnchor(
            cameraCenter: camera.centerCoordinate,
            anchor: anchor,
            oldDistance: camera.distance,
            newDistance: distance
        )
        setMapPosition(.camera(
            MapCamera(
                centerCoordinate: center,
                distance: distance,
                heading: camera.heading,
                pitch: camera.pitch
            )
        ))
        updateUserCenterState(using: proxy)
    }

    var userFrequentPlaces: [FrequentPlace] {
        model.settings.frequentPlaces.filter {
            $0.kind == .custom
        }
    }
}
