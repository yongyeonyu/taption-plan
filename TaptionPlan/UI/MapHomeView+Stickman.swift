import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    /// 지도에서 "가운데"로 삼을 점. 하루요약 시트가 아래를 덮으면 가려지지 않은 영역의 가운데다.
    var currentLocationTargetPoint: CGPoint {
        MapHomeDaySummaryLayout.targetPoint(
            viewportSize: mapViewportSize,
            coverage: daySummaryCoverage
        ).applying(CGAffineTransform(translationX: mapLeadingInset / 2, y: 0))
    }

    func locationDestinationSheet(
        for destination: MapHomeLocationDestination
    ) -> some View {
        MapHomeLocationSheet(
            model: model,
            destination: destination,
            language: language
        ) {
            setMapPosition(.automatic)
            focusMapIfNeeded()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    func userLocationSheet(
        for selection: MapHomeUserLocationSelection
    ) -> some View {
        MapHomeUserLocationActionSheet(
            model: model,
            selection: selection,
            language: language
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// 화랑이가 화면에 그려지는 점. 재생 중에는 구동기가 프레임마다 정한 점이 가장 정확하다.
    func isStickmanTapped(at tapPoint: CGPoint) -> Bool {
        guard let stickmanPoint = displayedCatViewportPoint else { return false }
        return MapHomeCatTapRouting.shouldPresentCatDetails(
            tapPoint: tapPoint,
            locationPoint: stickmanPoint,
            isAtHome: isDisplayedCatAtHome
        )
    }

    /// 집 아이콘·레벨 라벨 탭. 핀 안쪽 제스처에 기대지 않고 지도 단위 탭에서 집 핀 좌표로 판정한다.
    func isHomeSummaryTapped(at tapPoint: CGPoint) -> Bool {
        guard let home = model.settings.frequentPlaces.first(where: { $0.kind == .home }),
              let viewport = vectorMapViewportStore.viewport,
              let pinPoint = vectorPoint(in: viewport, for: vectorPlaceMarkerID(home.id)) else { return false }
        // 집 아이콘(핀 위쪽)과 레벨 라벨 영역을 넓게 잡는다. 화랑이가 집에 있어도 같은 영역이다.
        let iconRect = CGRect(x: pinPoint.x - 56, y: pinPoint.y - 110, width: 112, height: 150)
        return iconRect.contains(tapPoint)
    }

    // MARK: 집 주변 땅(지도)

    /// 붙일 땅(타일)이 남아 있고, 카메라가 집 300m 안에서 400m 이하로 가까울 때. 타일을 추가하는 동안만 벡터 스타일이 필요하다.
    var isNearHomeLand: Bool {
        guard MapHomeLandFeature.isVisible,
              autoLandStyleEnabled,
              let camera = visibleMapCamera, camera.distance <= 400,
              let home = model.settings.frequentPlaces.first(where: { $0.kind == .home })?.point else { return false }
        let season = homeGrowthHistory.season
        let placed = Set((season.landPlotPlacements ?? []).map(\.plotID))
        guard season.landPlots.contains(where: { !placed.contains($0) }) else { return false }
        let center = GeoPoint(
            latitude: camera.centerCoordinate.latitude,
            longitude: camera.centerCoordinate.longitude,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        return distanceMeters(center, home) <= 300
    }

    /// 집 주변에 이어 붙인 땅을 지도 위에 그린다(최대 확대에 가까울수록 크게). 붙일 땅이 남아 있으면
    /// 이을 수 있는 빈 칸이 점선 "+"로 나오고, 눌러서 이어 붙인다. 벡터 지도 스타일에서만 그린다.
    @ViewBuilder
    func homeLandOverlay(viewport: MapHomeVectorViewport?, content: MapHomeHomeLandContent?) -> some View {
        if let content, let layout = homeLandLayout(viewport: viewport) {
            // 칸 내용은 부모 평가에서 만들고, 프레임마다 위치·방위만 옮긴다(OPT1102A01).
            MapHomeHomeLandGrid(
                content: content,
                cell: layout.cell,
                attachLabel: language.text("여기에 땅 이어 붙이기", "Attach land here"),
                onPlace: { x, y in placeLandFromMap(x: x, y: y) }
            )
            .equatable()
            .frame(width: 0, height: 0)
            .rotationEffect(.degrees(-layout.heading))
            .position(layout.center)
        }
    }

    struct HomeLandLayout {
        let center: CGPoint
        let cell: CGFloat
        let heading: Double
    }

    /// 집 핀의 화면 위치와 한 칸의 화면 크기. 집이 없거나 너무 멀리 있거나 기울어져 있으면 nil.
    func homeLandLayout(viewport: MapHomeVectorViewport?) -> HomeLandLayout? {
        guard MapHomeLandFeature.isVisible,
              let viewport,
              viewport.pitch < 5,
              mapViewportSize.height > 0,
              let home = model.settings.frequentPlaces.first(where: { $0.kind == .home }),
              let pin = vectorPoint(in: viewport, for: vectorPlaceMarkerID(home.id)) else { return nil }
        let metersPerPoint = viewport.span.latitudeDelta * 111_320 / Double(mapViewportSize.height)
        guard metersPerPoint.isFinite, metersPerPoint > 0 else { return nil }
        let cell = CGFloat(Self.landCellMeters / metersPerPoint)
        // 너무 작게 보이면 그리지 않고, 화면보다 훨씬 크면 그리지 않는다.
        guard cell >= 14, cell <= 900 else { return nil }
        return HomeLandLayout(center: pin, cell: cell, heading: viewport.heading)
    }

    func presentLocationAddition(at coordinate: CLLocationCoordinate2D) {
        mapSearchResults = []
        isMapSearchFocused = false
        isSearchExpanded = false
        selectedSearchPin = MapHomeSearchResult(
            title: language.text("사용자 지점", "User location"),
            subtitle: language.text("지도에서 선택한 위치", "Long-pressed map location"),
            coordinate: coordinate
        )
        isSearchPinMenuPresented = true
    }

    var homeGrowthHistory: MapHomeGrowthHistory {
        growthHistoryCache.history(for: homeGrowthData) ?? .initial(for: .now)
    }

    /// 저장된 값이 있는데 읽지 못하면 초기값으로 덮어쓰지 않는다.
    var canWriteHomeGrowth: Bool {
        homeGrowthData.isEmpty || growthHistoryCache.history(for: homeGrowthData) != nil
    }

    func refreshHomeGrowth(at now: Date) {
        guard model.isBootstrapped, scenePhase == .active, canWriteHomeGrowth else { return }
        var history = homeGrowthHistory
        let calendar = MapHomeGrowthPolicy.localCalendar
        if let key = history.season.pendingDay,
           let day = MapHomeGrowthPolicy.date(for: key, calendar: calendar),
           calendar.startOfDay(for: day) < calendar.startOfDay(for: now) {
            history.season.pendingDayQualified = MapHomeGrowthPolicy.qualifiesDay(
                actuals: model.snapshot.actuals,
                travel: model.snapshot.travel,
                on: day,
                asOf: now,
                calendar: calendar
            )
        }
        // 어느 날을 보고 있어도 올해 집 레벨은 오늘 날짜다(성장 화면·카드가 같은 값을 읽게, 리뷰).
        MapHomeGrowthPolicy.refreshDailyLevel(in: &history, now: now, calendar: calendar)
        MapHomeGrowthPolicy.closePendingDay(
            in: &history,
            asOf: now,
            calendar: calendar
        )
        if calendar.isDate(model.selectedDate, inSameDayAs: now),
           let dayData = currentDayDataSnapshot {
            MapHomeGrowthPolicy.observeCurrentDay(
                in: &history,
                date: now,
                qualified: MapHomeGrowthPolicy.qualifiesDay(
                    actuals: dayData.actuals,
                    travel: dayData.travel,
                    on: now,
                    asOf: now,
                    calendar: calendar
                ),
                calendar: calendar
            )
        }
        guard let encoded = try? JSONEncoder().encode(history),
              encoded != homeGrowthData else { return }
        homeGrowthData = encoded
    }

    /// 하루를 대분류(수면·업무·이동·식사·취미·운동 등)로 묶은 요약. 세부 기록
    /// 원본(actuals)은 그대로 두고 파생 집계만 만든다. 비중은 관측된 총 시간
    /// 대비로 계산해 합이 100%가 되게 한다.
    var daySummaryCategories: [MapHomeDaySummaryEntry] {
        daySummaryEntries(from: daySummaryCategorySeconds(asOf: nil))
    }

    /// 화랑이의 손쉬운 사용 요소. 손가락 터치는 받지 않는다. 여기 닿은 손가락이 지도 핀치에서 빠지기 때문이다(대표 지시).
    /// 탭은 지도 탭(`handleMapTap`)이 위치로 판정한다.
    @ViewBuilder
    var stickmanTapTarget: some View {
        if let point = displayedCatViewportPoint {
            let atHome = isDisplayedCatAtHome
            // 지도 로컬 점을 뷰포트 공간으로 옮겨 놓는다(이 층은 뷰포트 공간에 있다).
            let center = viewportPoint(fromMapLocal: atHome ? point : MapHomeCatTapRouting.markerPoint(locationPoint: point, isAtHome: false))
            let size: CGFloat = atHome
                ? MapHomePlacePinLayout.avatarSize
                : MapHomeStickmanMarker.size.width + 8
            Color.clear
                .frame(width: size, height: size)
                .contentShape(Circle())
                .position(x: center.x, y: center.y)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(language.text("화랑이 카운터 보이기·숨기기", "Show or hide counters"))
                .accessibilityAction { toggleCounterFromCat() }
        }
    }

    func cancelPendingMapLocationAddition() {
        pendingUserLocationSelection = nil
        selectedSearchPin = nil
        isSearchPinMenuPresented = false
    }

    var userLocationCount: Int {
        userFrequentPlaces.count + model.settings.userTransitLocations.count
    }

    func userTransitLocationRow(_ location: UserTransitLocation) -> some View {
        Button {
            focusMap(on: location.point)
            isMenuOpen = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: location.kind.systemImage)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                    .foregroundStyle(Color.tpReferenceBlue)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(location.name)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12.5)), weight: .semibold))
                        .lineLimit(1)
                    Text(language.runtimeText(location.kind.title, location.kind.englishTitle))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(9.5)), weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "location.fill")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    func locationDestinationRow(
        _ destination: MapHomeLocationDestination
    ) -> some View {
        HStack(spacing: 0) {
            Button {
                activateLocationDestination(destination)
            } label: {
                HStack(spacing: 10) {
                    MapHomeLocationThumbnail(destination: destination, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.runtimeText(destination.koreanName, destination.englishName))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                        Text(locationDestinationSubtitle(destination))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10.5)), weight: .medium))
                            .foregroundStyle(destination == .user ? destination.tint : .secondary)
                    }
                    Spacer()
                }
                .foregroundStyle(Color.primary)
                .padding(.vertical, 7)
                .padding(.leading, 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(locationDestinationAccessibilityLabel(destination))

            if destination != .user {
                Button {
                    selectedLocationDestination = destination
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                        .foregroundStyle(destination.tint)
                        .frame(width: 38, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    language.text(
                        "\(destination.koreanName) 위치 편집",
                        "Edit \(destination.englishName) location"
                    )
                )
            }
        }
        .padding(.trailing, destination == .user ? 8 : 2)
        .background(
            destination.tint.opacity(destination == .user ? 0.10 : 0.055),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    func activateLocationDestination(
        _ destination: MapHomeLocationDestination
    ) {
        let place = destination.placeKind.flatMap { kind in
            model.settings.frequentPlaces.first { $0.kind == kind }
        }
        switch MapHomeLocationActivation.resolve(
            isCurrentLocation: destination == .user,
            hasSavedPoint: place?.point != nil
        ) {
        case .currentLocation:
            focusUserLocation()
            isMenuOpen = false
        case .savedLocation:
            guard let point = place?.point else { return }
            focusMap(on: point)
            isMenuOpen = false
        case .edit:
            selectedLocationDestination = destination
        }
    }

    func locationDestinationSubtitle(
        _ destination: MapHomeLocationDestination
    ) -> String {
        if destination == .user {
            return currentCoordinate == nil
                ? language.text("위치 확인 중", "Locating")
                : language.text("현재 위치", "Current location")
        }
        guard let kind = destination.placeKind,
              let place = model.settings.frequentPlaces.first(where: { $0.kind == kind })
        else {
            return language.text("현재 위치로 설정", "Set from current location")
        }
        if place.point != nil {
            return language.text("설정됨", "Set") + " · " + language.runtimeText(FloorLabel.korean(place.floor ?? 1), FloorLabel.english(place.floor ?? 1))
        }
        return language.text("현재 위치로 설정", "Set from current location")
    }

    func locationDestinationAccessibilityLabel(
        _ destination: MapHomeLocationDestination
    ) -> String {
        let name = language.runtimeText(destination.koreanName, destination.englishName)
        if destination == .user {
            return language.text("\(name) 현재 위치 보기", "Show \(name) location")
        }
        if let kind = destination.placeKind,
           model.settings.frequentPlaces.first(where: { $0.kind == kind })?.point != nil {
            return language.text("\(name) 위치 보기", "Show \(name) location")
        }
        return language.text("\(name) 위치 설정", "Set \(name) location")
    }

    /// 하루 요약 카드의 집. 지도 핀을 그대로 줄인다.
    var daySummaryHomeArtwork: some View {
        let point = model.settings.frequentPlaces.first { $0.kind == .home }?.point
        return MapHomePlacePin(
            name: language.text("집", "Home"), floor: nil, destination: .home, growthLevel: MapHomeGrowthPolicy.dailyLevel(for: model.selectedDate),
            weatherBadge: MapHomeHomeWeatherBadgePolicy.badge(from: model.snapshot.weather, now: .now),
            homeSky: point.map {
                MapHomeHomeSkyInput(coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                    selectedDay: model.selectedDate, progress: playbackProgress, isPlaybackRunning: false)
            }
        )
        // 지도 아이콘과 같은 크기. 번지는 빛은 칸 밖으로 나가도 된다.
        .frame(width: 96, height: 112)
        .allowsHitTesting(false)
    }

    var homeGrowthMarkerStatus: String {
        let calendar = MapHomeGrowthPolicy.localCalendar
        let history = homeGrowthHistory
        let today = Date.now
        guard calendar.isDate(model.selectedDate, inSameDayAs: today),
              history.season.pendingDay
                == MapHomeGrowthPolicy.dayKey(today, calendar: calendar),
              history.season.pendingDayQualified else {
            return language.text("오늘 기록을 쌓아보세요", "Build today's log")
        }
        return language.text("오늘 성장 조건 충족", "Today's growth goal met")
    }

    var isHomeGrowthQualifiedToday: Bool {
        let calendar = MapHomeGrowthPolicy.localCalendar
        let today = Date.now
        let history = homeGrowthHistory
        return calendar.isDate(model.selectedDate, inSameDayAs: today)
            && history.season.pendingDay
                == MapHomeGrowthPolicy.dayKey(today, calendar: calendar)
            && history.season.pendingDayQualified
    }

    func mapCategoryColor(_ id: String) -> Color {
        Color(
            hex: model.settings.mapCategoryColors[id]
                ?? MapHomePastelPalette.hex(id)
        )
    }

    var temporaryLocationAnnotations: [MapHomeTemporaryLocationAnnotation] {
        let probe = MapHomePlaybackProbe.begin("temporaryLocations"); defer { MapHomePlaybackProbe.end(probe) }
        // 임시 위치는 하루 기록만으로 정해지고 컷오프와 무관하다(컷오프는 아래에서 거른다). 매번 다시 뽑지 않는다(ARC1030A01).
        let derived = temporaryLocationsMemo.value(for: readingsSignature(sourceRevision: currentDayDataSnapshot?.sourceRevision)) {
            SubwayStationCatalog.temporaryLocations(
                from: routeReadings + model.liveRouteState.readings + (model.latestSensorReading.map { [$0] } ?? [])
            )
        }
        let locations = derived.isEmpty ? cachedTemporaryLocations : derived
        return locations
            .filter { $0.timestamp <= routeOverlayCutoff }
            .map {
                MapHomeTemporaryLocationAnnotation(
                    id: $0.id,
                    stationName: $0.stationName,
                    timestamp: $0.timestamp,
                    point: $0.point,
                    reason: $0.reason
                )
            }
    }

    /// 집 위치로 카메라를 옮긴다. 땅 한 칸이 보이는 거리(집 주변 땅 타일의 최소 표시 크기 이상)로 확대한다.
    func focusMapOnHome() {
        guard let home = model.settings.frequentPlaces.first(where: { $0.kind == .home })?.point else {
            isHomeMissingAlertPresented = true
            return
        }
        hasUserAdjustedMap = true
        // 집 버튼도 배율 80으로 맞춘다. 자동 줌이 곧바로 덮어쓰지 않도록 잠시 멈춘다.
        liveZoomGovernor.pauseForUserAdjustment(uptime: ProcessInfo.processInfo.systemUptime)
        setMapPosition(.camera(
            MapCamera(
                centerCoordinate: CLLocationCoordinate2D(latitude: home.latitude, longitude: home.longitude),
                distance: MapHomeCameraZoomMath.distance(forScale: 80),
                heading: 0,
                pitch: 0
            )
        ))
    }

    func focusUserLocation(
        using proxy: MapProxy? = nil,
        heading: CLLocationDirection? = nil,
        preservesCamera: Bool = false
    ) {
        guard let coordinate = liveFocusCoordinate else {
            isMapCenteredOnUser = false
            return
        }

        if preservesCamera, !rendersVectorMap {
            let distance = visibleMapCamera.flatMap {
                liveFollowDistance(current: $0.distance)
            }
            if let heading {
                requestAppleMapHeading(heading, centeredAt: coordinate, distance: distance)
            } else {
                requestAppleMapCenter(coordinate, distance: distance)
            }
            return
        }

        if let proxy,
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
                    heading: heading ?? camera.heading,
                    pitch: camera.pitch
                )
            ))
        } else if let camera = visibleMapCamera {
            setMapPosition(.camera(
                MapCamera(
                    centerCoordinate: coordinate,
                    distance: playbackAwareDistance(current: camera.distance),
                    heading: heading ?? camera.heading,
                    pitch: camera.pitch
                )
            ))
        } else {
            let span = preservesCamera
                ? visibleMapSpan
                : MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.010)
            setMapPosition(.region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: span
                )
            ))
        }
        if !rendersVectorMap {
            if let heading {
                requestAppleMapHeading(heading, centeredAt: coordinate)
            } else {
                requestAppleMapCenter(coordinate)
            }
        }
    }

    /// 현재 위치 버튼: 배율은 80으로 고정한다(현재 배율에서 80으로 옮긴다). 방향과 기울기는 그대로 둔다.
    func focusCurrentLocationAtFixedScale() {
        let camera = visibleMapCamera
        let coordinate = currentCoordinate ?? visibleMapCenter
        let distance = MapHomeCameraZoomMath.distance(forScale: 80)
        // 하루요약 시트가 아래를 덮으면 가려지지 않은 영역의 가운데에 오도록 중심을 남쪽으로 내린다.
        var center = coordinate
        if let camera, camera.distance > 0, mapViewportSize.height > 0 {
            let shift = MapHomeDaySummaryLayout.centerShift(
                viewportHeight: mapViewportSize.height,
                coverage: daySummaryCoverage
            )
            center.latitude -= MapHomeDaySummaryLayout.latitudeShift(
                shift: shift,
                viewportHeight: mapViewportSize.height,
                latitudeDelta: visibleMapSpan.latitudeDelta * distance / camera.distance
            )
        }
        setMapPosition(.camera(MapCamera(
            centerCoordinate: center,
            distance: distance,
            heading: camera?.heading ?? 0,
            pitch: camera?.pitch ?? 0
        )))
        if !rendersVectorMap {
            requestAppleMapCenter(coordinate, distance: distance)
        }
    }

    /// 위젯·알림·URL이 남긴 이동 요청을 한 번만 적용한다. 소비 즉시 지우지
    /// 않으면 화면이 다시 나타날 때마다 같은 곳으로 끌려간다. 상점 잠금 때문에
    /// 지도 홈이 아직 없을 때 들어온 요청도 잠금이 풀린 뒤 `onAppear`에서 온다.
    func applyPendingMapHomeRoute() {
        guard let route = model.pendingMapHomeRoute else { return }
        model.pendingMapHomeRoute = nil
        route.apply(
            openDaySummary: { isDaySummaryPresented = true },
            followLiveLocation: {
                requestAndFollowUserLocation(using: nil, fixedScale: true)
            }
        )
    }

    func requestAndFollowUserLocation(using proxy: MapProxy?, fixedScale: Bool = false) {
        // 현재 위치로 가면 재생을 취소한다. 두 레이아웃의 위치 단추가 모두 여기를
        // 지나므로 한 곳에서 처리한다(대표 요청, 2026-10-26).
        cancelDayPlaybackIfRunning()
        // 현재 위치 단추를 누르면 AI 비서 명령도 바로 받는다(대표 지시 SYN1111A02).
        Task { await AssistantCommandRefresh.now(language: language, manual: true) }
        recordTimelineWindow("recenter_before")
        // 지도만 지금으로 옮기고 시간선은 보던 시각에 두면, 확대해 둔 사이드바가
        // 지금과 다른 시각을 가리킨다. 날짜와 선택을 함께 지금으로 되돌린다
        // (대표 지적, 2026-10-27). 날짜를 오늘로 맞추는 일도 여기서만 한다.
        let now = Date()
        if !Calendar.autoupdatingCurrent.isDate(model.selectedDate, inSameDayAs: now) {
            model.selectedDate = now
        }
        if isTimelineSelectionPinned || selectedTimelineMinute != nil {
            selectedTimelineMinute = nil
            isTimelineSelectionPinned = false
        }
        recordTimelineWindow("recenter_after")
        // 위치 버튼으로 다시 따라가기 시작하면 자동 줌 일시 정지를 푼다.
        liveZoomGovernor.reset()
        // 배율 80으로 맞추는 버튼이므로 속도 비례 자동 줌이 곧바로 배율을 덮어쓰지 않게 잠시 멈춘다.
        if fixedScale {
            liveZoomGovernor.pauseForUserAdjustment(uptime: ProcessInfo.processInfo.systemUptime)
        }
        hasCancelledInitialLocationFocus = false
        setUserTrackingMode(.locating)
        // GPS를 기다리는 동안에도 가장 최근 위치로 먼저 이동해 화랑이를 보여준다.
        // 배율 80 고정이면 어느 단계에서도 현재 배율을 그대로 쓰지 않는다.
        if fixedScale {
            focusCurrentLocationAtFixedScale()
        } else {
            focusUserLocation(using: proxy, preservesCamera: true)
        }
        currentLocationRequestTask?.cancel()
        currentLocationRequestTask = Task { @MainActor in
            defer { currentLocationRequestTask = nil }
            let isAvailable = await model.requestMapCurrentLocation(
                requiresFreshReading: true
            )
            guard !Task.isCancelled,
                  userTrackingMode.keepsCameraLocked else { return }
            guard isAvailable || liveFocusCoordinate != nil else {
                setUserTrackingMode(.idle)
                return
            }
            if isAvailable { setUserTrackingMode(.following) }
            if fixedScale {
                focusCurrentLocationAtFixedScale()
            } else {
                focusUserLocation(using: proxy, preservesCamera: true)
            }
        }
    }

    func applyInitialLocationIfAvailable(using proxy: MapProxy?) {
        guard MapHomePlaybackCameraPolicy.allowsInitialFocus(
            isPlaybackRunning: isDayPlaybackRunning
        ),
              mapViewportSize.width > 0,
              mapViewportSize.height > 0,
              !hasAppliedInitialLocation,
              !hasAppliedInitialMapFocus,
              currentCoordinate != nil else { return }
        applyInitialMapFocusIfNeeded()
    }

    func beginInitialLocationRequest(using proxy: MapProxy?) {
        guard MapHomePlaybackCameraPolicy.allowsInitialFocus(
            isPlaybackRunning: isDayPlaybackRunning
        ),
              mapViewportSize.width > 0,
              mapViewportSize.height > 0,
              !hasAppliedInitialMapFocus, model.permissionState(for: .location).isGranted || FirstRunTutorialStore().allowsUnaskedPermissionPrompts,
              initialLocationRequestTask == nil else { return }
        initialLocationRequestTask = Task { @MainActor in
            defer { initialLocationRequestTask = nil }
            let isAvailable = await model.requestMapCurrentLocation(
                requiresFreshReading: true
            )
            guard !Task.isCancelled,
                  isAvailable,
                  !hasCancelledInitialLocationFocus,
                  !hasAppliedInitialMapFocus,
                  MapHomePlaybackCameraPolicy.allowsInitialFocus(
                      isPlaybackRunning: isDayPlaybackRunning
                  ),
                  userTrackingMode == .idle else {
                return
            }
            applyInitialMapFocusIfNeeded()
        }
    }
}
