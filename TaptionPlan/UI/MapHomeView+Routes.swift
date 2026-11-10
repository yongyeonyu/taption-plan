import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    var isMapSearchOverlayPresented: Bool {
        isMapSearchFocused
            || hasMapSearchResults
    }

    var topOverlayHeight: CGFloat {
        MapHomeOverlayLayoutMath.topOverlayHeight(
            headerFrame: headerFrame,
            searchFrame: searchFieldFrame,
            fallback: Layout.topOverlayFallbackHeight
        )
    }

    func lifecycleLiveRouteModifiers(_ content: some View) -> some View {
        content
        .onChange(of: model.selectedDate) { oldDate, newDate in
            let calendar = Calendar.autoupdatingCurrent
            let dayChanged = !calendar.isDate(oldDate, inSameDayAs: newDate)
            stopDayPlayback(resetProgress: true)
            selectedTimelineMinute = nil
            isTimelineSelectionPinned = false

            if dayChanged {
                resetDayScopedMapState(for: newDate)
                hasUserAdjustedMap = false
                routeReadingsLoadState = .loading(
                    MapHomeRouteReadingsPolicy.dayKey(for: newDate)
                )
                lastTransitBoardingLiveRefreshAt = nil
                transitBoardingReadingsRevision &+= 1
                nearbyTransitPlacesRevision &+= 1
            } else {
                prepareRouteProjectionReadings()
                refreshRouteProjection()
                recordCurrentPlaybackAlignment()
            }

            let shouldFitRoutes = shouldFitRoutesAfterDateChange
            shouldFitRoutesAfterDateChange = false
            if shouldFitRoutes || dayChanged {
                setMapPosition(.automatic)
                focusMapIfNeeded()
            } else if calendar.isDateInToday(newDate),
                      currentCoordinate != nil {
                focusUserLocation()
            }
            refreshTimeRailSegments()
        }
        .onChange(of: model.sleepSessions) { _, _ in
            requestRouteProjectionRefresh(preparingReadings: true)
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: model.settings.confirmedSleepSpans) { _, _ in
            requestRouteProjectionRefresh()
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: model.backupRestoreRevision) { _, _ in
            Task {
                await refreshRouteReadings(
                    for: model.selectedDate,
                    forceReload: true
                )
                scheduleExpectedRouteRefresh()
            }
        }
        .onChange(of: model.liveRouteState.readings.last?.id) { _, _ in
            guard Calendar.autoupdatingCurrent.isDateInToday(
                model.selectedDate
            ) else { return }
            if refreshTransitBoardingCandidatesIfNeeded(
                at: model.liveRouteState.readings.last?.timestamp ?? .now
            ) {
                scheduleTransitPOIRefresh()
            }
            scheduleLiveRouteProjectionRefresh()
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: model.liveRouteState.lastUpdatedAt) { _, _ in
            guard Calendar.autoupdatingCurrent.isDateInToday(
                model.selectedDate
            ) else { return }
            prepareRouteProjectionReadings()
            scheduleLiveRouteProjectionRefresh()
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if startupCameraPolicy.shouldRestoreZoom(on: phase) {
                restoreInitialMapZoom()
            }
            if phase != .active {
                routeReadingsPreparationTask?.cancel()
                routeReadingsPreparationTask = nil
                routeReadingsPreparationGeneration.advance()
                lastPreparedRouteReadingsSignature = nil
                liveRouteProjectionRefreshTask?.cancel()
                liveRouteProjectionRefreshTask = nil
                expectedRouteRefreshTask?.cancel()
                expectedRouteRefreshTask = nil
                expectedRouteRefreshGeneration &+= 1
                pendingForecastRouteState = nil
                routeDocumentProjectionGate.reset()
                transitPOIRefreshTask?.cancel()
                transitPOIRefreshTask = nil
                transitPOIRefreshGeneration &+= 1
                stopDayPlayback(resetProgress: true)
            } else {
                refreshHomeGrowth(at: .now)
                refreshTimeRailSegments()
                transitBoardingReadingsRevision &+= 1
                scheduleTransitPOIRefresh()
                scheduleExpectedRouteRefresh()
                prepareRouteProjectionReadings()
            }
        }
    }

    /// Apple 지도에서도 카운터 창을 화랑이 머리 위에 띄운다(벡터 지도와 같은 위치 규칙).
    /// 지도가 움직이는 동안은 프레임마다 받은 점(`appleStickmanLivePoint`)을 화면 틱마다 읽어 화랑이와 함께 옮긴다.
    var appleSalaryOverlay: some View {
        GeometryReader { geometry in
            if let stickman = displayedStickmanViewportPoint,
               CGRect(origin: .zero, size: geometry.size).contains(stickman),
               recordingShows(\.counterWidget) {
                counterWindow(at: CGPoint(
                    x: stickman.x,
                    y: stickman.y + MapHomeStickmanAnnotationLayout.centerOffset.y - 42
                ), tracksAppleCamera: true)
            }
        }
        .allowsHitTesting(false)
    }

    func runRouteReadingsTask() async {
        guard model.isBootstrapped || model.hasPreparedStartupSettings,
              scenePhase == .active else { return }
        let loadStartedAt = ProcessInfo.processInfo.systemUptime
        let date = model.selectedDate
        if !routeReadingsLoadState.isLoaded(for: date) {
            routeReadingsLoadState = .loading(
                MapHomeRouteReadingsPolicy.dayKey(for: date)
            )
        }
        applyInitialMapFocusIfNeeded()
        reportInitialMapShellReadyIfNeeded(for: date)
        await Task.yield()
        if let preview = await model.startupDayDataPreview(for: date) {
            await refreshRouteReadings(for: date, preloadedDayData: preview, isPreview: true)
        }
        await model.prepareLocalDataForDisplay()
        guard !Task.isCancelled, scenePhase == .active,
              Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: model.selectedDate)
        else { return }
        if let cached = await model.cachedPlanDayDataSnapshot(for: date) {
            await refreshRouteReadings(
                for: date,
                preloadedDayData: cached,
                isPreview: true
            )
            guard !Task.isCancelled,
                  Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: model.selectedDate)
            else { return }
            TaptionPlanDiagnosticsLogger.shared.record(
                "map_cached_projection_ready",
                fields: ["duration_ms": String(Int((
                    ProcessInfo.processInfo.systemUptime - loadStartedAt
                ) * 1_000))]
            )
        }
        guard !Task.isCancelled else { return }
        async let dayData = model.planDayDataSnapshot(
            for: date,
            forceReload: false,
            refreshRawReadings: true
        )
        prepareRouteProjectionReadings()
        refreshRouteProjection()
        focusMapIfNeeded()
        refreshTimeRailSegments()
        let mapCacheStartedAt = ProcessInfo.processInfo.systemUptime
        let cachedMapDay = await loadMapDayCache(for: date)
        let mapCacheDuration = ProcessInfo.processInfo.systemUptime
            - mapCacheStartedAt
        applyInitialMapFocusIfNeeded()
        guard !Task.isCancelled,
              Calendar.autoupdatingCurrent.isDate(
                  date,
                  inSameDayAs: model.selectedDate
              ) else { return }
        refreshTimeRailSegments()
        let snapshotWaitStartedAt = ProcessInfo.processInfo.systemUptime
        await refreshRouteReadings(
            for: date,
            preloadedDayData: await dayData,
            cachedMapDay: cachedMapDay
        )
        TaptionPlanDiagnosticsLogger.shared.record(
            "map_date_load_finished",
            fields: [
                "duration_ms": String(Int((
                    ProcessInfo.processInfo.systemUptime - loadStartedAt
                ) * 1_000)),
                "map_cache_ms": String(Int(mapCacheDuration * 1_000)),
                "snapshot_wait_ms": String(Int((
                    ProcessInfo.processInfo.systemUptime - snapshotWaitStartedAt
                ) * 1_000)),
            ]
        )
        applyInitialMapFocusIfNeeded()
            }

    var routeReadingsTaskKey: MapHomeRouteReadingsTaskKey {
        let date = model.selectedDate
        let isToday = Calendar.autoupdatingCurrent.isDateInToday(date)
        let rawRevision: UInt64 = isToday ? 0 : model.rawDataRevision(for: date)
        return MapHomeRouteReadingsTaskKey(
            date: date,
            isBootstrapped: model.isBootstrapped || model.hasPreparedStartupSettings,
            rawDataRevision: rawRevision,
            isSceneActive: scenePhase == .active
        )
    }

    var vectorHistoricalRoutes: [MapHomeVectorRoute] {
        timelineRouteOverlays.dropLast().flatMap { overlay in
            vectorRoutes(for: overlay, idPrefix: "")
        }
    }

    /// 실제 경로를 속도 그라데이션 구간으로 나눈다. 속도를 모르면 기존 단색 한 줄이다.
    func vectorRoutes(
        for overlay: MapHomeTimelineRouteOverlay,
        idPrefix: String
    ) -> [MapHomeVectorRoute] {
        let opacity = MapHomeWBSTripStyle.actualRouteOpacity
            * min(max(overlay.opacity, 0), 1)
        guard let slices = mapRenderCache.gradientSlices(
            id: overlay.id,
            coordinates: overlay.coordinates,
            geometrySignature: overlay.geometrySignature,
            timestamps: overlay.coordinateTimestamps
        ) else {
            return [
                MapHomeVectorRoute(
                    id: idPrefix + overlay.id,
                    coordinates: overlay.coordinates,
                    geometrySignature: overlay.geometrySignature,
                    colorHex: MapHomeWBSTripStyle.actualRouteHex,
                    opacity: opacity
                )
            ]
        }
        return slices.map { slice in
            MapHomeVectorRoute(
                id: idPrefix + slice.id,
                coordinates: slice.coordinates,
                geometrySignature: slice.geometrySignature,
                colorHex: slice.colorHex,
                opacity: opacity
            )
        }
    }

    var appleActualRoutes: [MapHomeAppleRoute] {
        timelineRouteOverlays.flatMap { overlay -> [MapHomeAppleRoute] in
            let opacity = MapHomeWBSTripStyle.actualRouteOpacity
                * min(max(overlay.opacity, 0), 1)
            guard let slices = mapRenderCache.gradientSlices(
                id: overlay.id,
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                timestamps: overlay.coordinateTimestamps
            ) else {
                return [
                    MapHomeAppleRoute(
                        id: "timeline-\(overlay.id)",
                        coordinates: overlay.coordinates,
                        geometrySignature: overlay.geometrySignature,
                        colorHex: MapHomeWBSTripStyle.actualRouteHex,
                        opacity: opacity,
                        phase: .actual,
                        transport: nil
                    )
                ]
            }
            return slices.map { slice in
                MapHomeAppleRoute(
                    id: "timeline-\(slice.id)",
                    coordinates: slice.coordinates,
                    geometrySignature: slice.geometrySignature,
                    colorHex: slice.colorHex,
                    opacity: opacity,
                    phase: .actual,
                    transport: nil
                )
            }
        }
    }

    var appleMapRoutes: [MapHomeAppleRoute] {
        var routes = appleActualRoutes

        routes += subwayRouteOverlays.compactMap { overlay in
            guard overlay.coordinates.count >= 2 else { return nil }
            return MapHomeAppleRoute(
                id: "subway-\(overlay.id.uuidString)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: MapHomeWBSTripStyle.transitRouteHex,
                opacity: overlay.estimated
                    ? MapHomeWBSTripStyle.forecastRouteOpacity
                    : MapHomeWBSTripStyle.actualRouteOpacity,
                phase: overlay.estimated ? .forecast : .actual,
                transport: .transit
            )
        }

        routes += appleMapForecastRoutes
        routes += appleUserSelectedRoutes
        return routes.filter { $0.coordinates.count >= 2 }
    }

    /// 사용자가 확정한 예상 경로와 지금 선택한 예상 경로의 선. 발자국이 이 경로 위에 그려지므로 선도 같은 좌표로 그린다
    /// (벡터 지도의 `vectorUserSelectedRoutes`와 같은 내용).
    var appleUserSelectedRoutes: [MapHomeAppleRoute] {
        var routes = confirmedPredictedRoutes.map { route -> MapHomeAppleRoute in
            let points = coordinates(for: route, through: routeOverlayCutoff)
            return MapHomeAppleRoute(
                id: "confirmed-predicted-\(route.id)",
                coordinates: points,
                geometrySignature: MapHomeRouteGeometrySignature.value(for: points),
                colorHex: MapHomeWBSTripStyle.actualRouteHex,
                opacity: 0.95,
                phase: .actual,
                transport: nil
            )
        }
        if let selectedPredictedRoute {
            let points = coordinates(for: selectedPredictedRoute)
            routes.append(MapHomeAppleRoute(
                id: "selected-\(selectedPredictedRoute.id)",
                coordinates: points,
                geometrySignature: MapHomeRouteGeometrySignature.value(for: points),
                colorHex: "#FF9800",
                opacity: 1,
                phase: .actual,
                transport: nil
            ))
        }
        return routes
    }

    var appleMapForecastRoutes: [MapHomeAppleRoute] {
        let expected = displayedExpectedRouteOverlays
        let generated = displayedWBSGeneratedRouteOverlays
        let fallback = expected.map { overlay in
            MapHomeAppleRoute(
                id: "expected-\(overlay.id.uuidString)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: MapHomeAppleRouteTransport(mode: overlay.mode)
                    .forecastColorHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity,
                phase: .forecast,
                transport: MapHomeAppleRouteTransport(mode: overlay.mode)
            )
        } + generated.map { overlay in
            MapHomeAppleRoute(
                id: "wbs-\(overlay.id)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: overlay.mode.map {
                    MapHomeAppleRouteTransport(mode: $0).forecastColorHex
                } ?? MapHomeWBSTripStyle.forecastRouteHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity,
                phase: .forecast,
                transport: overlay.mode.map { MapHomeAppleRouteTransport(mode: $0) }
            )
        }
        guard let projection = wbsPlaybackProjection else { return fallback }
        let expectedLegIDs = Set(expected.map { "movement-\($0.id.uuidString)" })
        let generatedLegIDs = Set(generated.map(\.id))
        let dottedLegIDs = expectedLegIDs.union(generatedLegIDs)
        let baseSignatures = Dictionary(
            fallback.map { ($0.id, $0.geometrySignature) },
            uniquingKeysWith: { first, _ in first }
        )
        let cutoff = routeOverlayCutoff
        let projected = projection.legs.compactMap { leg -> MapHomeAppleRoute? in
            guard dottedLegIDs.contains(leg.id),
                  leg.routePhase == .forecast,
                  leg.activity == .movement,
                  let coordinates = visibleForecastCoordinates(
                    for: leg,
                    through: cutoff
                  ) else { return nil }
            let id: String
            if expectedLegIDs.contains(leg.id) {
                id = "expected-\(String(leg.id.dropFirst("movement-".count)))"
            } else {
                id = "wbs-\(leg.id)"
            }
            guard let baseSignature = baseSignatures[id] else { return nil }
            return MapHomeAppleRoute(
                id: id,
                coordinates: coordinates,
                geometrySignature: MapHomeRouteGeometrySignature.derived(
                    from: baseSignature,
                    coordinates: coordinates
                ),
                colorHex: leg.mode.map {
                    MapHomeAppleRouteTransport(mode: $0).forecastColorHex
                } ?? MapHomeWBSTripStyle.forecastRouteHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity,
                phase: .forecast,
                transport: leg.mode.map { MapHomeAppleRouteTransport(mode: $0) }
            )
        }
        return projected
    }

    var vectorActiveRouteSegments: [MapHomeVectorRoute] {
        guard let overlay = timelineRouteOverlays.last else { return [] }
        let routes = vectorRoutes(for: overlay, idPrefix: "active-")
        return routes.count == 1 && routes[0].id == "active-" + overlay.id
            ? [] : routes
    }

    var vectorActiveRoute: MapHomeVectorRoute? {
        guard let overlay = timelineRouteOverlays.last else { return nil }
        return MapHomeVectorRoute(
            id: "active-\(overlay.id)",
            coordinates: overlay.coordinates,
            geometrySignature: overlay.geometrySignature,
            colorHex: MapHomeWBSTripStyle.actualRouteHex,
            opacity: MapHomeWBSTripStyle.actualRouteOpacity
                * min(max(overlay.opacity, 0), 1)
        )
    }

    var vectorExpectedRoutes: [MapHomeVectorRoute] {
        let expected = displayedExpectedRouteOverlays.map { overlay in
            MapHomeVectorRoute(
                id: "expected-\(overlay.id.uuidString)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: MapHomeAppleRouteTransport(mode: overlay.mode)
                    .forecastColorHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity
            )
        }
        let generated = displayedWBSGeneratedRouteOverlays.map { overlay in
            MapHomeVectorRoute(
                id: "wbs-\(overlay.id)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: overlay.mode.map {
                    MapHomeAppleRouteTransport(mode: $0).forecastColorHex
                } ?? MapHomeWBSTripStyle.forecastRouteHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity
            )
        }
        let estimatedSubway: [MapHomeVectorRoute] = subwayRouteOverlays.compactMap {
            overlay -> MapHomeVectorRoute? in
            guard overlay.estimated,
                  predictedRoute(for: overlay).map({ !hasRouteDecision($0) }) ?? true else { return nil }
            return MapHomeVectorRoute(
                id: "subway-estimated-\(overlay.id)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: MapHomeWBSTripStyle.transitRouteHex,
                opacity: MapHomeWBSTripStyle.forecastRouteOpacity
            )
        }
        return expected + generated + estimatedSubway
    }

    var vectorSubwayRoutes: [MapHomeVectorRoute] {
        subwayRouteOverlays.compactMap { overlay in
            guard !overlay.estimated,
                  predictedRoute(for: overlay).map({ !hasRouteDecision($0) }) ?? true else { return nil }
            return MapHomeVectorRoute(
                id: "subway-\(overlay.id)",
                coordinates: overlay.coordinates,
                geometrySignature: overlay.geometrySignature,
                colorHex: MapHomeWBSTripStyle.transitRouteHex,
                opacity: MapHomeWBSTripStyle.actualRouteOpacity
            )
        }
    }

    /// 지도 위 표시에 쓰는 값을 화면 갱신마다 한 번만 계산한다. 마커 목록과 60Hz 오버레이가 같은 값을 쓴다
    /// (성능 리뷰: 오버레이가 매 프레임 계산 프로퍼티를 다시 읽던 낭비).
    func mapOverlayInputs() -> MapHomeOverlayInputs {
        MapHomeOverlayInputs(
            places: recordingShows(\.placeIcons) ? placeAnnotations : [],
            temporaryLocations: temporaryLocationAnnotations,
            transit: transitAnnotations,
            boarding: transitBoardingCandidates,
            stickers: mapStickersOnMap,
            photos: photoClusters,
            memos: recordingShows(\.mapMemos) ? mapMemosOnMap : []
        )
    }

    func predictedRoute(source: String, travelID: UUID? = nil, mode: TravelMode,
                                span: TimeSpan, coordinates: [CLLocationCoordinate2D]) -> MapPredictedRoute {
        MapPredictedRoute(source: source, travelID: travelID, mode: mode, span: span,
            coordinates: coordinates.map { GeoPoint(latitude: $0.latitude, longitude: $0.longitude,
                altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1) })
    }

    func predictedRoute(for overlay: MapHomeExpectedRouteOverlay) -> MapPredictedRoute {
        predictedRoute(source: overlay.mode == .subway || overlay.mode == .train ? "rail" : "forecast",
            travelID: overlay.segmentID, mode: overlay.mode,
            span: TimeSpan(start: overlay.departureDate, end: overlay.arrivalDate), coordinates: overlay.coordinates)
    }

    func predictedRoute(for overlay: MapHomeWBSGeneratedRouteOverlay) -> MapPredictedRoute {
        let mode = overlay.mode ?? .walking
        let matching = currentDayDataSnapshot?.travel.filter {
            abs($0.span.start.timeIntervalSince(overlay.departureDate)) <= 1
                && abs($0.span.end.timeIntervalSince(overlay.arrivalDate)) <= 1
        } ?? []
        return predictedRoute(source: mode == .subway || mode == .train ? "rail" : "forecast",
            travelID: matching.count == 1 ? matching[0].id : nil,
            mode: mode, span: TimeSpan(start: overlay.departureDate, end: overlay.arrivalDate),
            coordinates: overlay.coordinates)
    }

    func predictedRoute(for overlay: MapHomeSubwayRouteOverlay) -> MapPredictedRoute? {
        guard let travel = currentDayDataSnapshot?.travel.first(where: { $0.id == (overlay.travelID ?? overlay.id) }) else { return nil }
        let points = travel.subwayRoute.map { SubwayTrackCatalog.following($0.coordinates) }?.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        } ?? overlay.coordinates
        return predictedRoute(source: "rail", travelID: travel.id, mode: travel.mode,
            span: travel.span, coordinates: points.count >= 2 ? points : overlay.coordinates)
    }

    func hasRouteDecision(_ route: MapPredictedRoute) -> Bool {
        model.snapshot.settings.predictedRouteDecisions.contains { $0.matches(route) }
    }

    var predictedMapRoutes: [MapPredictedRoute] {
        let probe = MapHomePlaybackProbe.begin("predictedMapRoutes"); defer { MapHomePlaybackProbe.end(probe) }
        let cutoff = routeOverlayCutoff
        // 지난 날짜에는 예상 경로(일정·학습으로 만든 회색 경로)와 공백 추정을 만들지 않는다. 실제 이동에서 풀린 지하철 구간만 남긴다.
        // 예전에는 지하철 예상 경로가 "rail"로 남아, 차로 이동한 날에도 지하철 회색 발자국이 계속 나왔다(ARC1030A02).
        let isPastDay = !Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate)
        var routes: [MapPredictedRoute] = []
        if !isPastDay {
            routes += expectedRouteOverlays.filter { $0.departureDate < cutoff }.map { predictedRoute(for: $0) }
            routes += wbsGeneratedRouteOverlays.filter { $0.departureDate < cutoff }.map { predictedRoute(for: $0) }
        }
        routes += subwayRouteOverlays.compactMap { predictedRoute(for: $0) }
        // 하루 전체에서 한 번 구한 틈을 컷오프로 거른다. 틈은 앞뒤 두 위치로 정해지므로 컷오프로 먼저 자르는 것과 같다(ARC1030A01).
        let allGaps = predictedGapsMemo.value(for: MapHomeReadingsSignature(
            day: Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate), sourceRevision: nil,
            storedCount: normalizedRouteReadings.count, storedLastID: normalizedRouteReadings.last?.id,
            liveCount: 0, liveLastID: nil, latestID: nil
        )) {
            MapHomeGPSGapPredictionPolicy.predictedGaps(from: normalizedRouteReadings)
        }
        routes += (isPastDay ? [] : allGaps).filter { $0.end.timestamp <= cutoff }.compactMap { gap in
            guard let first = gap.start.point, let last = gap.end.point else { return nil }
            return MapPredictedRoute(source: "gps-gap", travelID: nil, mode: .walking,
                span: TimeSpan(start: gap.start.timestamp, end: gap.end.timestamp),
                coordinates: [first] + gap.coordinates.map {
                    GeoPoint(latitude: $0.latitude, longitude: $0.longitude, altitude: 0,
                        horizontalAccuracy: -1, verticalAccuracy: -1)
                } + [last])
        }
        var seen = Set<String>()
        return routes.filter { $0.isValid && !hasRouteDecision($0) && seen.insert($0.id).inserted }
    }

    var confirmedPredictedRoutes: [MapPredictedRoute] {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: model.selectedDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return model.snapshot.settings.predictedRouteDecisions.filter {
            !$0.isDeleted && $0.route.isValid
                && $0.route.span.start < end && $0.route.span.end > start
        }.map(\.route)
    }

    var vectorUserSelectedRoutes: [MapHomeVectorRoute] {
        var routes = confirmedPredictedRoutes.map { route in
            let points = coordinates(for: route, through: routeOverlayCutoff)
            return MapHomeVectorRoute(id: "confirmed-predicted-\(route.id)", coordinates: points,
                geometrySignature: MapHomeRouteGeometrySignature.value(for: points),
                colorHex: MapHomeWBSTripStyle.actualRouteHex, opacity: 0.95)
        }
        if let selectedPredictedRoute {
            let points = coordinates(for: selectedPredictedRoute)
            routes.append(MapHomeVectorRoute(id: "selected-\(selectedPredictedRoute.id)", coordinates: points,
                geometrySignature: MapHomeRouteGeometrySignature.value(for: points),
                colorHex: "#FF9800", opacity: 1))
        }
        return routes
    }

    func vectorMapAnnotationOverlay(
        style: MapHomeVectorStyle,
        viewport: MapHomeVectorViewport?,
        stickmanPoint: CGPoint?,
        statics: MapHomePlaybackStaticLayers,
        inputs: MapHomeOverlayInputs,
        playback: MapHomeApplePlayback?,
        displayedSpeed: Double?
    ) -> some View {
        _ = MapHomePlaybackFrameStats.noteOverlayEvaluation()
        let places = inputs.places
        return ZStack {
            if fogStrength != .off {
                // 구동기 재생 중에는 화랑이가 지나간 시각까지의 발자국만 걷어 낸다(ARC1030A02).
                MapHomeFogLayer(
                    opacity: fogStrength.opacity,
                    reveals: fogReveals(viewport: viewport, waypoints: playbackFogWaypoints(statics),
                                        places: places, stickmanPoint: stickmanPoint)
                )
            }
            homeLandOverlay(viewport: viewport, content: statics.land)
            placeZoneOverlay(viewport: viewport, zones: statics.zones)
            // 그리는 순서로 정렬돼 있다. 구동기 재생 중에는 지도 코디네이터 레이어가 그린다(OPT1102A01).
            ForEach(recordingShows(\.footprints) && !Self.benchHidden("paws") && playbackDriver == nil
                    ? statics.pawprints.drawOrder : []) { waypoint in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorPawprintMarkerID(waypoint.index)
                ) {
                    MapHomeProjectedAnnotation(point: point, anchor: .center) {
                        if let timestamp = waypoint.timestamp, !waypoint.isPredicted {
                            pawprintImage(waypoint)
                                .accessibilityLabel(
                                    Text(language.text("기록 발자국 ", "Recorded paw "))
                                        + Text(timestamp, style: .time)
                                )
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { selectPawprint(waypoint) }
                        } else if waypoint.predictedRoute != nil {
                            pawprintImage(waypoint)
                                .accessibilityLabel(language.text("예상 경로 선택", "Select predicted route"))
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { selectPawprint(waypoint) }
                        } else {
                            pawprintImage(waypoint).accessibilityHidden(true)
                        }
                    }
                }
            }
            ForEach(inputs.temporaryLocations) { location in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorTemporaryMarkerID(location.id)
                ) {
                    MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
                        VStack(spacing: 2) {
                            Image(systemName: "tram.fill")
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                                .foregroundStyle(Color.tpReferenceBlue.opacity(0.72))
                            Text(language.text("임시 위치", "Temporary"))
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .semibold))
                                .foregroundStyle(Color.tpInk.opacity(0.72))
                        }
                        .padding(5)
                        .background(Color.tpSurface.opacity(0.66), in: Capsule())
                        .overlay {
                            Capsule().stroke(
                                Color.tpReferenceBlue.opacity(0.45),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                            )
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            language.text(
                                "\(location.stationName) 지하철 임시 위치",
                                "\(location.stationName) temporary subway location"
                            )
                        )
                        .allowsHitTesting(false)
                    }
                }
            }

            ForEach(places) { place in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorPlaceMarkerID(place.id)
                ) {
                    // 핀 내용은 비교되고, 지도만 움직인 프레임에는 위치만 바뀐다(OPT1102A01).
                    MapHomeProjectedAnnotation(
                        point: point,
                        anchor: MapHomePlaceAnnotationLayout.vectorAnchor
                    ) {
                        MapHomePlacePinItem(place: place, language: language) { isDaySummaryPresented = true }
                            .equatable()
                    }
                    .zIndex(MapHomePlaceDisplayPolicy.vectorZIndex(for: place.destination))
                }
            }

            ForEach(inputs.transit) { place in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorTransitMarkerID(place.id)
                ) {
                    MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
                    Button {
                        selectedUserLocation = .transit(place.id)
                        } label: {
                            MapHomeTransitPlacePin(name: place.name, kind: place.kind)
                                .fixedSize()
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(false)
                        .accessibilityLabel(
                            language.text(
                                "\(place.name) 사용자 위치 메뉴",
                                "\(place.name) user location menu"
                            )
                        )
                    }
                }
            }

            ForEach(inputs.boarding) { candidate in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorBoardingCandidateMarkerID(candidate.id)
                ) {
                    MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
                        Button {
                            selectedTransitBoardingCandidate = candidate
                        } label: {
                            MapHomeTransitBoardingCandidatePin(
                                name: TransitPlaceName.display(candidate.name, kind: candidate.kind, point: candidate.point, language: language),
                                kind: candidate.kind
                            )
                            .fixedSize()
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(false)
                        .accessibilityLabel(
                            language.text(
                                "\(candidate.name) \(candidate.kind.title) 탑승 확인",
                                "Confirm boarding at \(candidate.name) \(candidate.kind.englishTitle)"
                            )
                        )
                    }
                }
            }

            ForEach(inputs.stickers) { sticker in
                if let point = vectorPoint(
                    in: viewport,
                    for: vectorMapStickerMarkerID(sticker.id)
                ) {
                    MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
                        Button {
                            selectedMapStickerEditor = .sticker(sticker.id)
                        } label: {
                            MapHomeMapStickerMarker(sticker: sticker)
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(isStickerMode)
                        .accessibilityLabel(
                            language.text(
                                "\(sticker.title) 메모 스티커",
                                "\(sticker.title) memo sticker"
                            )
                        )
                    }
                }
            }

            ForEach(inputs.photos) { cluster in
                if let info = photoPinInfo(for: cluster),
                   let point = photoPinPoint(cluster, in: viewport, places: inputs.places) {
                    MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
                        Button {
                            photoBrowserSelection = MapHomePhotoBrowserSelection(startID: cluster.moments.first?.id)
                        } label: {
                            MapHomePhotoPin(
                                coverID: info.coverID,
                                count: info.count,
                                isHighlighted: info.highlighted
                            )
                            .transition(.scale.combined(with: .opacity))
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(false)
                    }
                    .animation(.easeOut(duration: 0.25), value: info.coverID)
                }
            }

            ForEach(recordingShows(\.mapMemos) ? inputs.memos : []) { memo in
                if let projected = vectorPoint(
                    in: viewport,
                    for: vectorMapMemoMarkerID(memo.id)
                ) {
                    MapHomeProjectedAnnotation(point: projected, anchor: .bottom) {
                        Button {
                            selectedMapStickerEditor = .memo(memo.id)
                        } label: {
                            MapHomeMapMemoMarker(memo: memo)
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(false)
                        .accessibilityLabel(
                            language.text(
                                "\(memo.text) 지도 메모, \(memo.occurredAt.formatted(date: .omitted, time: .shortened))",
                                "\(memo.text) map memo, \(memo.occurredAt.formatted(date: .omitted, time: .shortened))"
                            )
                        )
                    }
                }
            }

            if selectedTimelineMinute != nil,
               !isDisplayedCatAtHome,
               let point = (playbackDriver != nil ? vectorMapViewportStore.livePoint : nil)
                   ?? vectorPoint(in: viewport, for: vectorDisplayedMarkerID) {
                // 구동기 재생 중에는 화살표를 화랑이와 같은 점에 둔다(대표 지시, ARC1030A02).
                MapHomeVectorPlayerMarker(
                    heading: playback?.headingDegrees ?? 0,
                    backgroundHex: style.backgroundHex
                )
                    .position(x: point.x, y: point.y + 11)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if let playback,
               recordingShows(\.cat),
               stickmanPoint != nil || vectorMapViewportStore.livePoint != nil {
                // 재생 중에는 UIKit 뷰가 `liveChannel` 점으로 위치만 옮긴다. SwiftUI는 매 프레임 다시 그리지 않는다(PRF1101A01).
                let point = vectorMapViewportStore.livePoint ?? stickmanPoint ?? .zero
                let offset = MapHomeStickmanAnnotationLayout.centerOffset
                MapHomeLivePointFollower(
                    channel: playbackDriver == nil ? nil : vectorMapViewportStore.liveChannel,
                    fallback: CGPoint(x: point.x + offset.x, y: point.y + offset.y),
                    offset: CGSize(width: offset.x, height: offset.y)
                ) {
                MapHomeStickmanMarker(
                    action: playback.action,
                    animationPhase: playbackDriver == nil ? playback.stickmanAnimationPhase : nil,
                    routePhase: playback.phase == .forecast
                        ? .forecast
                        : .actual,
                    speedMetersPerSecond: displayedSpeed,
                    equippedAccessoryID: homeGrowthHistory.season.equippedAccessory,
                    facesLeft: MapHomeStickmanFacing.facesLeft(
                        headingDegrees: playback.headingDegrees,
                        cameraHeading: viewport?.heading ?? 0,
                        action: playback.action
                    )
                    )
                    .catSpeechBubble(
                        action: playback.action,
                        facesLeft: MapHomeStickmanFacing.facesLeft(
                            headingDegrees: playback.headingDegrees,
                            cameraHeading: viewport?.heading ?? 0,
                            action: playback.action
                        )
                    )
                }
                    .zIndex(MapHomeLayerPriority.stickman)
                    // 화랑이 위에서도 지도 팬·핀치줌이 최우선이 되도록 마커는
                    // 히트테스트에서 제외한다(다른 마커와 동일). UIKit 지도 위의
                    // SwiftUI simultaneousGesture는 드래그를 지도로 흘려보내지
                    // 못해 고양이 주변 터치를 삼켰다. 상세는 중앙 상단 탐험 HUD로
                    // 연다.
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(
                        "\(playback.accessibilityLabel), \(language.text("설명 보기","Show info"))"
                    )
            }

            // 카운터 창은 녹화에서 끄지 않는 한 늘 보인다: 화랑이가 밖에 있으면 그 위, 집에 있으면 집 핀 안의 화랑이 위.
            // 연봉과 나머지 카운터는 한 상자에 담는다(표시 > 카운터에서 켠 것만).
            if recordingShows(\.counterWidget),
               let anchor = salaryAnchor(viewport: viewport, stickmanPoint: playback == nil ? nil : stickmanPoint) {
                counterWindow(at: anchor, tracksPlaybackPoint: playback != nil)
            }

            ForEach(Array(travelStopsOnSelectedDay.enumerated()), id: \.element.id) { index, stop in
                if let point = vectorPoint(in: viewport, for: travelStopMarkerID(stop)) {
                    MapHomeProjectedAnnotation(point: point, anchor: .center) {
                        MapHomeTravelStopPin(number: index + 1, status: TripItemStatus(raw: stop.status))
                            .accessibilityLabel(TripItemStatus(raw: stop.status).spoken(stop.title, language))
                    }
                }
            }

            if let selectedSearchPin,
               let point = vectorPoint(in: viewport, for: vectorSearchMarkerID) {
                MapHomeProjectedAnnotation(point: point, anchor: .bottom) {
                    Button {
                        isSearchPinMenuPresented = true
                    } label: {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(36)), weight: .bold))
                            .foregroundStyle(Color.tpPastelRose)
                            .background(Circle().fill(.white))
                            .frame(width: 48, height: 48)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        language.text(
                            "\(selectedSearchPin.title) 위치 추가",
                            "Add \(selectedSearchPin.title) location"
                        )
                    )
                }
            }
        }
        .clipped()
    }

    /// 등록지점 범위: 빨간 원은 반경, 주황 두 원은 ±15% 히스테리시스 구간.
    @ViewBuilder
    func placeZoneOverlay(viewport: MapHomeVectorViewport?, zones: [MapHomePlaceZoneItem]) -> some View {
        if !zones.isEmpty, let viewport, viewport.pitch < 5, mapViewportSize.height > 0 {
            let metersPerPoint = viewport.span.latitudeDelta * 111_320 / Double(mapViewportSize.height)
            if metersPerPoint.isFinite, metersPerPoint > 0 {
                ForEach(zones) { zone in
                    if let pin = vectorPoint(in: viewport, for: vectorPlaceMarkerID(zone.id)) {
                        MapHomePlaceZoneRings(radiusMeters: zone.radiusMeters, metersPerPoint: metersPerPoint)
                            .equatable()
                            .frame(width: 0, height: 0)
                            .opacity(0.5)
                            .position(pin)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    func vectorTransitMarkerID(_ id: UUID) -> String {
        "transit-\(id.uuidString)"
    }

    func routeLongPress(_ action: MapHomeLongPressAction) {
        guard let coordinate = pendingLongPressCoordinate else { return }
        pendingLongPressCoordinate = nil
        switch action {
        case .location:
            presentLocationAddition(at: coordinate)
        case .memo:
            selectedSearchPin = nil
            addMapMemo(at: coordinate)
        }
    }

    /// 오늘로 가서 전체 경로를 화면에 맞춘다(날짜 배지 더블탭).
    func jumpToTodayAndFitRoutes() {
        isDateWeekExpanded = false
        jumpToTodayAndCurrentMapPosition()
        // 날짜를 바꾸면 경로 데이터가 늦게 들어오므로, 불러온 뒤 한 번 더 전체 경로를 화면에 맞춘다.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !isDayPlaybackRunning else { return }
            focusMapOnAllRoutes()
        }
    }

    /// 요약 카드에 그릴 경로. 확정한 날은 저장해 둔 단순화 경로를 쓴다(센서 원본을 다시 읽지 않는다).
    var daySummaryRoutePoints: [GeoPoint] {
        if let sealed = model.sealedDay(for: model.selectedDate), !sealed.polyline.isEmpty {
            return sealed.routePoints
        }
        return currentDayReadings.compactMap { reading in
            reading.point.map {
                GeoPoint(
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    altitude: 0,
                    horizontalAccuracy: 0,
                    verticalAccuracy: 0
                )
            }
        }
    }

    func dismissMapSearchOverlay() {
        if isSearchPinMenuPresented, selectedSearchPin != nil {
            cancelPendingMapLocationAddition()
            return
        }
        guard isMapSearchFocused
                || !mapSearchResults.isEmpty
                || !mapSearchCompleter.results.isEmpty
                || !mapSearchCompleter.kakaoResults.isEmpty
        else { return }
        isMapSearchFocused = false
        isSearchExpanded = false
        mapSearchResults = []
        mapSearchCompleter.clear()
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    /// 화면에 그려진 예상 경로 위의 좌표를 시각으로 찾는다(구동기·영상 공용).
    func expectedRouteCoordinateLookup() -> (Date) -> GeoPoint? {
        let overlays = expectedRouteOverlays
        let visibleIDs = Set(displayedExpectedRouteOverlays.map(\.id))
        return { date in
            let route = overlays.filter {
                visibleIDs.contains($0.id) && $0.coordinates.count >= 2
                    && $0.departureDate <= date && date <= $0.arrivalDate
            }.min { $0.departureDate < $1.departureDate }
            guard let coordinate = route?.coordinate(at: date), CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return wbsGeoPoint(coordinate)
        }
    }
}
