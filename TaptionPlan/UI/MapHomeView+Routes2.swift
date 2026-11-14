import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    var transitAnnotations: [MapHomeTransitAnnotation] {
        model.settings.userTransitLocations.compactMap { location in
            guard isValid(location.point) else { return nil }
            return MapHomeTransitAnnotation(
                id: location.id,
                name: location.name,
                kind: location.kind,
                coordinate: CLLocationCoordinate2D(
                    latitude: location.point.latitude,
                    longitude: location.point.longitude
                )
            )
        }
    }

    var transitBoardingReadings: [SensorReading] {
        var seen = Set<UUID>()
        return (
            routeReadings
                + model.liveRouteState.readings
                + (model.latestSensorReading.map { [$0] } ?? [])
        )
        .filter {
            RouteTimelineTimestamp.isValid($0.timestamp)
                && seen.insert($0.id).inserted
        }
        .sorted { $0.timestamp < $1.timestamp }
    }

    var transitBoardingCandidates: [TransitBoardingCandidate] {
        let probe = MapHomePlaybackProbe.begin("boardingCandidates"); defer { MapHomePlaybackProbe.end(probe) }
        let dayData = currentDayDataSnapshot
        let registeredLocations = model.settings.userTransitLocations
        let nearbyPlaces = nearbyTransitPlaces
        let travel = dayData?.travel ?? []
        let decisions = model.settings.transitBoardingDecisions
        let cutoff = routeOverlayCutoff
        let group = MapHomeTransitBoardingGroup(
            dayProjectionRevision: model.dayProjectionRevision,
            settingsHash: {
                var hasher = Hasher()
                hasher.combine(registeredLocations)
                hasher.combine(decisions)
                return hasher.finalize()
            }(),
            readingsRevision: transitBoardingReadingsRevision,
            nearbyPlacesRevision: nearbyTransitPlacesRevision,
            day: Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate)
        )
        let step = MapHomeTransitBoardingRefreshPolicy.cutoffBucket(cutoff)
        // 분이 바뀔 때마다 후보를 다시 찾으면 한 번에 50ms씩 메인 스레드를 막았다. 같은 묶음 안에서는 이전 값을 먼저 보여 주고
        // 새 분의 값은 뒤에서 만든다(ARC1030A01). 하루 기록 정리도 묶음이 바뀔 때만 한다.
        let readings = transitBoardingReadingsMemo.value(
            for: readingsSignature(sourceRevision: group.readingsRevision)
        ) { transitBoardingReadings }
        // 진단 기록은 재생 중이 아닐 때 그 자리 계산분에만 남긴다(기록용 계산도 하루 기록을 여러 번 훑는다).
        let isPlaying = isDayPlaybackRunning
        transitBoardingDerived.onFresh = { candidates in
            // AI가 답할 수 있게 지금 묻는 후보를 알려 둔다(ACT1114A07).
            AssistantBoardingCandidates.current = candidates
            guard !isPlaying else { return }
            var fields = transitBoardingDiagnostics(
                readings: readings,
                registeredLocations: registeredLocations,
                nearbyPlaces: nearbyPlaces,
                travel: travel,
                through: cutoff
            )
            fields["candidate_count"] = String(candidates.count)
            fields["candidate_names"] = Array(Set(candidates.map(\.name))).sorted().joined(separator: ";")
            fields["candidate_travel_segment_count"] = String(Set(candidates.flatMap(\.travelSegmentIDs)).count)
            fields["decision_count"] = String(decisions.count)
            TaptionPlanDiagnosticsLogger.shared.record("transit_boarding_candidates_evaluated", fields: fields)
        }
        transitBoardingDerived.onUpdate = {
            if !isDayPlaybackRunning { derivedUpdateTick &+= 1 }
        }
        return transitBoardingDerived.value(group: group, step: step) {
            TransitBoardingCandidateEngine.candidates(
                readings: readings,
                registeredLocations: registeredLocations,
                nearbyPlaces: nearbyPlaces,
                travel: travel,
                decisions: decisions,
                through: cutoff
            )
        }
    }

    func refreshTransitBoardingCandidatesIfNeeded(at date: Date) -> Bool {
        guard scenePhase == .active else { return false }
        guard MapHomeTransitBoardingRefreshPolicy.shouldRefresh(
            lastRefresh: lastTransitBoardingLiveRefreshAt,
            at: date
        ) else { return false }
        lastTransitBoardingLiveRefreshAt = date
        transitBoardingReadingsRevision &+= 1
        return true
    }

    func transitBoardingDiagnostics(
        readings: [SensorReading],
        registeredLocations: [UserTransitLocation],
        nearbyPlaces: [TransitBoardingPlace],
        travel: [TravelSegment],
        through cutoff: Date
    ) -> [String: String] {
        let withPoint = readings.filter { $0.point != nil }
        let gpsAvailable = readings.filter(\.gpsAvailable)
        let precise = readings.filter {
            $0.locationFixQuality != .approximate
        }
        let usable = readings.filter { reading in
            guard reading.gpsAvailable,
                  reading.locationFixQuality != .approximate,
                  let point = reading.point,
                  point.latitude.isFinite,
                  point.longitude.isFinite,
                  (-90...90).contains(point.latitude),
                  (-180...180).contains(point.longitude) else {
                return false
            }
            return point.horizontalAccuracy <= 0
                || point.horizontalAccuracy <= 200
        }
        let poweredModes: Set<TravelMode> = [
            .bus, .subway, .taxi, .car, .train, .airplane, .ship,
        ]
        let poweredTravel = travel.filter {
            poweredModes.contains($0.mode)
        }
        let stationNames = Array(Set(
            (registeredLocations.map(\.name)
                + nearbyPlaces.map(\.name)
                + readings.compactMap(\.nearbyStationName))
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }
        )).sorted().joined(separator: ";")
        return [
            "cutoff": String(cutoff.timeIntervalSince1970),
            "readings": String(readings.count),
            "readings_with_point": String(withPoint.count),
            "readings_gps_available": String(gpsAvailable.count),
            "readings_precise": String(precise.count),
            "readings_usable": String(usable.count),
            "registered_transit_places": String(registeredLocations.count),
            "nearby_transit_places": String(nearbyPlaces.count),
            "transit_place_names": stationNames,
            "travel_segments": String(travel.count),
            "travel_powered_segments": String(poweredTravel.count),
            "travel_unconfirmed_powered_segments": String(
                poweredTravel.filter { !$0.isConfirmed }.count
            ),
            "travel_mode_counts": transitModeCounts(travel.map(\.mode)),
            "reading_station_name_count": String(
                Set(readings.compactMap(\.nearbyStationName)).count
            ),
            "reading_rail_match_count": String(
                readings.filter(\.matchesRailRoute).count
            ),
            "reading_transit_match_count": String(
                readings.filter(\.matchesPublicTransitRoute).count
            ),
        ]
    }

    func transitModeCounts(_ modes: [TravelMode]) -> String {
        let counts = Dictionary(grouping: modes, by: { $0 })
        return TravelMode.allCases.compactMap { mode in
            guard let count = counts[mode]?.count else { return nil }
            return "\(mode.rawValue)=\(count)"
        }.joined(separator: ",")
    }

    var visibleExpectedRouteOverlays: [MapHomeExpectedRouteOverlay] {
        guard Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate) else { return [] }
        let cutoff = routeOverlayCutoff
        return mapRenderCache.visibleExpectedRoutes(cutoff: cutoff) {
            expectedRouteOverlays.compactMap {
                $0.visible(through: cutoff)
            }
        }.filter { visible in
            !hasRouteDecision(predictedRoute(for: expectedRouteOverlays.first { $0.id == visible.id } ?? visible))
        }
    }

    func currentExpectedRouteInputKey() -> MapHomeExpectedRouteInputKey {
        let calendar = Calendar.autoupdatingCurrent
        let selectedDay = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: selectedDay)
            ?? selectedDay.addingTimeInterval(24 * 60 * 60)
        let dayData = currentDayDataSnapshot
        let liveReadings = model.liveRouteState.readings
        let latestReading = model.latestSensorReading
        return MapHomeExpectedRouteInputKey(
            selectedDay: selectedDay,
            dayEnd: dayEnd,
            dayProjectionRevision: model.dayProjectionRevision,
            daySourceRevision: dayData?.sourceRevision,
            daySourceUpdatedAt: dayData?.sourceUpdatedAt,
            daySourceFingerprint: dayData?.sourceFingerprint,
            isPreview: dayDataIsPreview,
            readingsPreparationID: routeReadingsPreparationGeneration.currentID,
            normalizedReadings: MapHomeDayCacheReadingsFingerprint(
                readings: normalizedRouteReadings
            ),
            normalizedLastRouteInputSignature:
                MapHomeRouteReadingsPreparation.latestRouteInputSignature(
                    normalizedRouteReadings.last
                ),
            liveReadings: MapHomeDayCacheReadingsFingerprint(
                readings: liveReadings
            ),
            liveLastUpdatedAt: model.liveRouteState.lastUpdatedAt,
            liveLastRouteInputSignature:
                MapHomeRouteReadingsPreparation.latestRouteInputSignature(
                    liveReadings.last
                ),
            latestRouteInputSignature:
                MapHomeRouteReadingsPreparation.latestRouteInputSignature(
                    latestReading
                )
        )
    }

    func isCurrentExpectedRouteRefresh(
        generation: UInt64,
        inputKey: MapHomeExpectedRouteInputKey
    ) -> Bool {
        !Task.isCancelled
            && scenePhase == .active
            && generation == expectedRouteRefreshGeneration
            && inputKey == currentExpectedRouteInputKey()
    }

    func refreshExpectedRouteOverlays(generation: UInt64) async {
        guard scenePhase == .active, !Task.isCancelled,
              generation == expectedRouteRefreshGeneration else { return }
        let inputKey = currentExpectedRouteInputKey()
        let selectedDay = inputKey.selectedDay
        let dayEnd = inputKey.dayEnd
        let dayData = currentDayDataSnapshot
        let travel = dayData?.travel ?? []
        let placesCount = (dayData?.places ?? []).count
        let normalizedReadings = normalizedRouteReadings
        let playbackReadings = currentDayReadings
        let day = TimeSpan(start: selectedDay, end: dayEnd)
        let gpsLoggingInterval = model.settings.gpsLoggingPreferences.interval
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            var overlayOperationCount = 0
            let overlayRequests = ExpectedRouteRequestEngine.requests(
                travel: travel,
                places: [],
                readings: normalizedReadings,
                in: day,
                through: dayEnd,
                frequentPlaces: [],
                gpsLoggingInterval: gpsLoggingInterval,
                operationCount: &overlayOperationCount
            )
            try Task.checkCancellation()
            var playbackOperationCount = 0
            let playbackRequests = ExpectedRouteRequestEngine.requests(
                travel: travel,
                places: [],
                readings: playbackReadings,
                in: day,
                through: dayEnd,
                frequentPlaces: [],
                gpsLoggingInterval: gpsLoggingInterval,
                operationCount: &playbackOperationCount
            )
            try Task.checkCancellation()
            return MapHomeExpectedRouteRequestBatch(
                overlayRequests: overlayRequests,
                playbackRequests: playbackRequests,
                overlayOperationCount: overlayOperationCount,
                playbackOperationCount: playbackOperationCount,
                readingsWithPointCount: normalizedReadings.reduce(into: 0) {
                    if $1.point != nil { $0 += 1 }
                },
                unconfirmedTravelCount: travel.reduce(into: 0) {
                    if !$1.isConfirmed { $0 += 1 }
                }
            )
        }
        let batch: MapHomeExpectedRouteRequestBatch
        do {
            batch = try await withTaskCancellationHandler(
                operation: { try await worker.value },
                onCancel: { worker.cancel() }
            )
        } catch {
            worker.cancel()
            return
        }
        guard isCurrentExpectedRouteRefresh(
            generation: generation,
            inputKey: inputKey
        ) else { return }
        if wbsExpectedRouteRequests != batch.playbackRequests {
            wbsExpectedRouteRequests = batch.playbackRequests
        }
        if wbsExpectedRouteRequestsInputKey != inputKey {
            wbsExpectedRouteRequestsInputKey = inputKey
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "expected_route_requests_built",
            fields: expectedRouteRequestDiagnostics(
                requests: batch.overlayRequests,
                travelCount: travel.count,
                unconfirmedTravelCount: batch.unconfirmedTravelCount,
                placesCount: placesCount,
                readingsCount: normalizedReadings.count,
                readingsWithPointCount: batch.readingsWithPointCount,
                dayStart: selectedDay,
                dayEnd: dayEnd,
                operationCount: batch.overlayOperationCount,
                playbackOperationCount: batch.playbackOperationCount
            )
        )
        if expectedRouteCache.count > 128 {
            expectedRouteCache.removeAll(keepingCapacity: true)
        }

        let limitedRequests = Array(
            batch.overlayRequests.prefix(
                MapHomeForecastRouteDisplayPolicy.maximumVisibleRoutes
            )
        )
        // 예상 경로가 모두 캐시에 있으면 직선 임시 경로를 먼저 그리지 않는다. 센서 갱신마다 투영을 두 번 만들고
        // 지도를 두 번 다시 그리던 것이 손짓 중 끊김으로 이어졌다(실사용 기록, PRF1030A02).
        let allExpectedCached = limitedRequests.allSatisfy { (expectedRouteCache[$0]?.count ?? 0) >= 2 }
        if !allExpectedCached {
            let fallbackExpected = limitedRequests.map {
                expectedRouteOverlay(for: $0, coordinates: [
                    CLLocationCoordinate2D(
                        latitude: $0.start.latitude,
                        longitude: $0.start.longitude
                    ),
                    CLLocationCoordinate2D(
                        latitude: $0.end.latitude,
                        longitude: $0.end.longitude
                    ),
                ])
            }
            let fallbackProjection = makeWBSPlaybackProjection(
                expected: fallbackExpected,
                generated: [],
                expectedRouteRequests: batch.playbackRequests
            )
            let excludedLegIDs = Set(
                fallbackExpected.map { "movement-\($0.id.uuidString)" }
                    + storedWBSResolvedRoutes.map(\.legID)
            )
            let fallbackGenerated = Array(
                generatedWBSRouteOverlays(
                    from: fallbackProjection,
                    excluding: excludedLegIDs
                ).prefix(
                    max(
                        0,
                        MapHomeForecastRouteDisplayPolicy.maximumVisibleRoutes
                            - fallbackExpected.count
                    )
                )
            )
            recordExpectedRouteProjectionDiagnostics(
                phase: "fallback",
                projection: fallbackProjection,
                expected: fallbackExpected,
                generated: fallbackGenerated,
                excludedLegIDs: excludedLegIDs
            )
            _ = applyForecastRouteState(
                MapHomeForecastRouteState(
                    expected: fallbackExpected,
                    generated: fallbackGenerated,
                    refreshGeneration: generation,
                    inputKey: inputKey
                )
            )
        }

        var resolvedExpected: [MapHomeExpectedRouteOverlay] = []
        for request in limitedRequests {
            guard isCurrentExpectedRouteRefresh(
                generation: generation,
                inputKey: inputKey
            ) else { return }
            let coordinates: [CLLocationCoordinate2D]
            if let cached = expectedRouteCache[request], cached.count >= 2 {
                coordinates = cached
            } else {
                let resolved = await mapKitRouteCoordinates(for: request)
                guard isCurrentExpectedRouteRefresh(
                    generation: generation,
                    inputKey: inputKey
                ) else { return }
                if resolved.count >= 2 {
                    expectedRouteCache[request] = resolved
                    coordinates = resolved
                } else {
                    coordinates = [
                        CLLocationCoordinate2D(
                            latitude: request.start.latitude,
                            longitude: request.start.longitude
                        ),
                        CLLocationCoordinate2D(
                            latitude: request.end.latitude,
                            longitude: request.end.longitude
                        ),
                    ]
                }
            }
            resolvedExpected.append(
                expectedRouteOverlay(for: request, coordinates: coordinates)
            )
        }
        guard isCurrentExpectedRouteRefresh(
            generation: generation,
            inputKey: inputKey
        ) else { return }

        let resolvedProjection = makeWBSPlaybackProjection(
            expected: resolvedExpected,
            generated: [],
            expectedRouteRequests: batch.playbackRequests
        )
        var resolvedGenerated = Array(
            generatedWBSRouteOverlays(
                from: resolvedProjection,
                excluding: Set(
                    resolvedExpected.map { "movement-\($0.id.uuidString)" }
                        + storedWBSResolvedRoutes.map(\.legID)
                )
            ).prefix(
                max(
                    0,
                    MapHomeForecastRouteDisplayPolicy.maximumVisibleRoutes
                        - resolvedExpected.count
                )
            )
        )
        let resolvedExcludedLegIDs = Set(
            resolvedExpected.map { "movement-\($0.id.uuidString)" }
                + storedWBSResolvedRoutes.map(\.legID)
        )
        recordExpectedRouteProjectionDiagnostics(
            phase: "resolved_before_network_routes",
            projection: resolvedProjection,
            expected: resolvedExpected,
            generated: resolvedGenerated,
            excludedLegIDs: resolvedExcludedLegIDs
        )
        var networkResolvedCount = 0
        for index in resolvedGenerated.indices {
            guard isCurrentExpectedRouteRefresh(
                generation: generation,
                inputKey: inputKey
            ) else { return }
            guard let transport = wbsRouteTransport(for: resolvedGenerated[index].mode),
                  let start = resolvedGenerated[index].coordinates.first,
                  let end = resolvedGenerated[index].coordinates.last else { continue }
            let coordinates = await MapHomeAppleRouteResolver.shared.resolve(
                start: start,
                end: end,
                transport: transport,
                departureDate: resolvedGenerated[index].departureDate
            )
            guard isCurrentExpectedRouteRefresh(
                generation: generation,
                inputKey: inputKey
            ) else { return }
            if let coordinates, coordinates.count >= 2 {
                resolvedGenerated[index] = MapHomeWBSGeneratedRouteOverlay(
                    id: resolvedGenerated[index].id,
                    mode: resolvedGenerated[index].mode,
                    departureDate: resolvedGenerated[index].departureDate,
                    arrivalDate: resolvedGenerated[index].arrivalDate,
                    coordinates: coordinates
                )
                networkResolvedCount += 1
            }
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "expected_route_network_resolution",
            fields: [
                "generated_requested": String(resolvedGenerated.count),
                "generated_network_resolved": String(networkResolvedCount),
                "generated_network_fallback": String(
                    resolvedGenerated.count - networkResolvedCount
                ),
            ]
        )
        recordExpectedRouteProjectionDiagnostics(
            phase: "resolved_after_network_routes",
            projection: resolvedProjection,
            expected: resolvedExpected,
            generated: resolvedGenerated,
            excludedLegIDs: resolvedExcludedLegIDs
        )
        guard isCurrentExpectedRouteRefresh(
            generation: generation,
            inputKey: inputKey
        ) else { return }
        let didApply = applyForecastRouteState(
            MapHomeForecastRouteState(
                expected: resolvedExpected,
                generated: resolvedGenerated,
                refreshGeneration: generation,
                inputKey: inputKey
            )
        )
        guard didApply else { return }
        applyInitialMapFocusIfNeeded()
        // 현재 위치를 따라가는 중에는 예상 경로가 갱신돼도 "경로 전체 보기"로 카메라를 끌어가지 않는다.
        // 갱신이 끝날 때마다 전체 보기와 현재 위치 따라가기가 번갈아 카메라를 옮겨 화면이 왔다 갔다 했다(대표 영상, ARC1030A02).
        if !userTrackingMode.keepsCameraLocked,
           MapHomePlaybackCameraPolicy.allowsAutomaticFit(
               isPlaybackRunning: isDayPlaybackRunning,
               hasUserAdjustedMap: hasUserAdjustedMap
           ) {
            focusMapOnAllRoutes()
        }
        persistMapDayCache()
    }

    func expectedRouteOverlay(
        for request: ExpectedRouteRequest,
        coordinates: [CLLocationCoordinate2D]
    ) -> MapHomeExpectedRouteOverlay {
        MapHomeExpectedRouteOverlay(
            id: request.id,
            segmentID: request.segmentID,
            mode: request.mode,
            departureDate: request.departureDate,
            arrivalDate: request.arrivalDate,
            coordinates: coordinates
        )
    }

    func expectedRouteRequestDiagnostics(
        requests: [ExpectedRouteRequest],
        travelCount: Int,
        unconfirmedTravelCount: Int,
        placesCount: Int,
        readingsCount: Int,
        readingsWithPointCount: Int,
        dayStart: Date,
        dayEnd: Date,
        operationCount: Int,
        playbackOperationCount: Int
    ) -> [String: String] {
        let requestModes = Dictionary(grouping: requests, by: \.mode)
        let requestSegmentIDs = Set(requests.map(\.segmentID))
        return [
            "day_start": String(dayStart.timeIntervalSince1970),
            "day_end": String(dayEnd.timeIntervalSince1970),
            "travel_segments": String(travelCount),
            "unconfirmed_travel_segments": String(unconfirmedTravelCount),
            "places": String(placesCount),
            "readings": String(readingsCount),
            "readings_with_point": String(readingsWithPointCount),
            "request_count": String(requests.count),
            "request_unique_segment_count": String(requestSegmentIDs.count),
            "request_duplicate_segment_count": String(
                max(0, requests.count - requestSegmentIDs.count)
            ),
            "request_mode_counts": TravelMode.allCases.compactMap { mode in
                guard let count = requestModes[mode]?.count else { return nil }
                return "\(mode.rawValue)=\(count)"
            }.joined(separator: ","),
            "route_cache_count": String(expectedRouteCache.count),
            "request_operations": String(operationCount),
            "playback_request_operations": String(playbackOperationCount),
        ]
    }

    @discardableResult
    func applyForecastRouteState(
        _ state: MapHomeForecastRouteState
    ) -> Bool {
        guard state.refreshGeneration == expectedRouteRefreshGeneration,
              state.inputKey == currentExpectedRouteInputKey() else {
            return false
        }
        guard !isTimelineInteractionActive || isDayPlaybackRunning else {
            pendingForecastRouteState = state
            hasDeferredWBSPlaybackRefresh = true
            TaptionPlanDiagnosticsLogger.shared.record(
                "expected_route_state_deferred",
                fields: [
                    "expected_overlay_count": String(state.expected.count),
                    "generated_overlay_count": String(state.generated.count),
                ]
            )
            return false
        }
        pendingForecastRouteState = nil
        mapRenderCache.invalidateExpectedRoutes()
        expectedRouteOverlays = state.expected
        wbsGeneratedRouteOverlays = state.generated
        refreshWBSPlaybackProjection()
        TaptionPlanDiagnosticsLogger.shared.record(
            "expected_route_state_applied",
            fields: [
                "expected_overlay_count": String(state.expected.count),
                "generated_overlay_count": String(state.generated.count),
            ]
        )
        return true
    }

    func mapKitRouteCoordinates(
        for routeRequest: ExpectedRouteRequest
    ) async -> [CLLocationCoordinate2D] {
        await MapHomeAppleRouteResolver.shared.resolve(
            start: CLLocationCoordinate2D(
                latitude: routeRequest.start.latitude,
                longitude: routeRequest.start.longitude
            ),
            end: CLLocationCoordinate2D(
                latitude: routeRequest.end.latitude,
                longitude: routeRequest.end.longitude
            ),
            transport: routeRequest.transport,
            departureDate: routeRequest.departureDate
        ) ?? []
    }

    var subwayRouteOverlays: [MapHomeSubwayRouteOverlay] {
        let probe = MapHomePlaybackProbe.begin("subwayOverlays"); defer { MapHomePlaybackProbe.end(probe) }
        let dayData = currentDayDataSnapshot
        let calendar = Calendar.autoupdatingCurrent
        guard let dayStart = calendar.startOfDay(for: model.selectedDate) as Date?,
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
        else { return [] }
        let day = TimeSpan(start: dayStart, end: dayEnd)
        let cutoff = routeOverlayCutoff
        let cutoffMinute = calendar.dateComponents(
            [.minute],
            from: dayStart,
            to: cutoff
        ).minute ?? effectiveTimelineMinute
        // 분이 바뀔 때마다 지하철 구간을 다시 풀면 재생이 100ms씩 멈췄다. 같은 날·같은 기록이면 이전 값을 먼저 보여 주고
        // 새 분의 값은 뒤에서 만든다(ARC1030A01).
        let travel = dayData?.travel ?? []
        let stored = routeReadings
        let live = model.liveRouteState.readings
        let latest = model.latestSensorReading
        subwayOverlayDerived.onUpdate = { [mapRenderCache] in
            mapRenderCache.invalidateRouteBounds()
            // 재생 중에는 0.25초마다 오는 분 알림이 화면을 다시 그린다. 재생이 아닐 때만 직접 깨운다.
            if !isDayPlaybackRunning { derivedUpdateTick &+= 1 }
        }
        return subwayOverlayDerived.value(
            group: readingsSignature(sourceRevision: dayData?.sourceRevision),
            step: cutoffMinute
        ) {
            MapHomeSubwayRouteOverlayEngine.overlays(
                travel: travel,
                readings: stored + live + (latest.map { [$0] } ?? []),
                day: day,
                through: cutoff
            )
        }
    }

    func makeTimelineRouteOverlays(
        _ projection: RouteTimelineProjection
    ) -> [MapHomeTimelineRouteOverlay] {
        projection.segments.compactMap { segment in
            guard segment.confirmedSubwayTravelID == nil else { return nil }
            let coordinates = segment.coordinates.compactMap { point -> CLLocationCoordinate2D? in
                guard isValid(point) else { return nil }
                return CLLocationCoordinate2D(
                    latitude: point.latitude,
                    longitude: point.longitude
                )
            }
            guard coordinates.count >= 2 else { return nil }
            return MapHomeTimelineRouteOverlay(
                id: segment.id,
                categoryID: segment.category.rawValue,
                opacity: segment.opacity,
                speedMetersPerSecond: segment.speedMetersPerSecond,
                coordinates: coordinates,
                coordinateTimestamps: segment.coordinateTimestamps
            )
        }
    }

    var activeExpectedRoute: MapHomeExpectedRouteOverlay? {
        let date = displayedLocationDate
        let visibleIDs = Set(displayedExpectedRouteOverlays.map(\.id))
        return expectedRouteOverlays
            .filter {
                visibleIDs.contains($0.id)
                    && $0.coordinates.count >= 2
                    && $0.departureDate <= date
                    && date <= $0.arrivalDate
            }
            .min { $0.departureDate < $1.departureDate }
    }

    var routeTimelineDate: Date {
        displayedPlaybackDate
            ?? clampedTimelineDate(
                RouteTimelineDataEngine.timelineDate(
                    selectedDate: model.selectedDate,
                    minute: effectiveTimelineMinute
                )
            )
    }

    func refreshRouteReadings(
        for date: Date,
        forceReload: Bool = false,
        preloadedDayData: PlanDayDataSnapshot? = nil,
        cachedMapDay: MapHomeDayCachePayload? = nil,
        isPreview: Bool = false
    ) async {
        let viewSignpostID = OSSignpostID(log: Self.dayViewSignpostLog)
        os_signpost(
            .begin,
            log: Self.dayViewSignpostLog,
            name: "day_view",
            signpostID: viewSignpostID
        )
        defer {
            os_signpost(
                .end,
                log: Self.dayViewSignpostLog,
                name: "day_view",
                signpostID: viewSignpostID
            )
        }
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: date)
        let dataGeneration = TaptionDataDeletionFence.currentGeneration()
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
        else { return }
        var dayData: PlanDayDataSnapshot
        var showsCachedPreview = isPreview
        if let preloadedDayData, !forceReload {
            dayData = preloadedDayData
        } else {
            dayData = await model.planDayDataSnapshot(
                for: date,
                forceReload: forceReload
            )
        }
        guard !Task.isCancelled,
              TaptionDataDeletionFence.allows(generation: dataGeneration),
              calendar.isDate(date, inSameDayAs: model.selectedDate)
        else { return }
        if dayData.sourceRevision != model.dayProjectionRevision, model.isBootstrapped {
            guard let rebased = await model.rebasePlanDayDataSnapshot(
                from: dayData,
                for: date
            ) else { return }
            guard !Task.isCancelled,
                  TaptionDataDeletionFence.allows(generation: dataGeneration),
                  calendar.isDate(date, inSameDayAs: model.selectedDate)
            else { return }
            dayData = rebased
        }
        if !isPreview, !dayData.isComplete {
            let previous = dayDataSnapshot?.isComplete == true
                ? dayDataSnapshot
                : await model.cachedPlanDayDataSnapshot(for: date)
            guard !Task.isCancelled,
                  TaptionDataDeletionFence.allows(generation: dataGeneration),
                  calendar.isDate(date, inSameDayAs: model.selectedDate) else { return }
            if let previous, previous.isComplete,
               calendar.isDate(previous.day, inSameDayAs: date) {
                if previous.sourceRevision != model.dayProjectionRevision {
                    guard let rebased = await model.rebasePlanDayDataSnapshot(from: previous, for: date),
                          !Task.isCancelled,
                          TaptionDataDeletionFence.allows(generation: dataGeneration),
                          calendar.isDate(date, inSameDayAs: model.selectedDate) else { return }
                    dayData = rebased
                } else {
                    dayData = previous
                }
                showsCachedPreview = true
                TaptionPlanDiagnosticsLogger.shared.record("map_incomplete_reload_kept_preview",
                    fields: ["readings": String(previous.readings.count)])
            }
        }
        var snapshotFields = TaptionPlanDiagnosticsTravelSummary.fields(
            for: dayData.travel
        )
        snapshotFields["day_start"] = String(dayStart.timeIntervalSince1970)
        snapshotFields["source_revision"] = String(dayData.sourceRevision)
        snapshotFields["projection_version"] = String(dayData.projectionVersion)
        snapshotFields["source_updated_at"] = String(
            dayData.sourceUpdatedAt.timeIntervalSince1970
        )
        snapshotFields["is_complete"] = String(dayData.isComplete)
        snapshotFields["is_preview"] = String(showsCachedPreview)
        snapshotFields["readings"] = String(dayData.readings.count)
        snapshotFields["readings_with_point"] = String(
            dayData.readings.filter { $0.point != nil }.count
        )
        snapshotFields["places"] = String(dayData.places.count)
        snapshotFields["travel"] = String(dayData.travel.count)
        TaptionPlanDiagnosticsLogger.shared.record(
            "map_day_snapshot_loaded",
            fields: snapshotFields
        )
        dayDataSnapshot = dayData
        reportInitialMapShellReadyIfNeeded(for: model.selectedDate)
        routeActualIndex = nil
        dayDataIsPreview = showsCachedPreview
        let merged = MapHomeRouteReadingsPolicy.merging(
            existing: routeReadings,
            loaded: dayData.readings,
            in: TimeSpan(start: dayStart, end: dayEnd)
        )
        routeReadingsLoadState = isPreview ? .loading(dayStart) : dayData.isComplete
            ? .loaded(dayStart)
            : .failed(dayStart)
        if merged != routeReadings {
            routeReadings = merged
            transitBoardingReadingsRevision &+= 1
        }
        if showsCachedPreview {
            refreshTimeRailSegments()
            prepareRouteProjectionReadings()
            refreshRouteProjection()
            focusMapIfNeeded()
            return
        }
        let restoredCachedRoutes = cachedMapDay.map {
            applyMapDayCacheRoutes($0, for: date, dayData: dayData)
        } ?? false
        refreshTimeRailSegments()
        scheduleTransitPOIRefresh()
        scheduleExpectedRouteRefresh()
        guard !isTimelineInteractionActive || isDayPlaybackRunning else {
            routeDocumentProjectionGate.deferRefresh(preparingReadings: true)
            return
        }
        if restoredCachedRoutes,
           selectedTimelineMinute == nil,
           !isDayPlaybackRunning {
            focusMapIfNeeded()
            return
        }
        prepareRouteProjectionReadings()
        refreshRouteProjection()
        if selectedTimelineMinute != nil {
            recordCurrentPlaybackAlignment()
            if let point = displayedPlaybackFocusPoint {
                focusMap(
                    on: point,
                    followsTracking: true
                )
            }
        } else {
            focusMapIfNeeded()
        }
        persistMapDayCache()
    }

    func applyMapDayCacheRoutes(
        _ payload: MapHomeDayCachePayload,
        for date: Date,
        dayData: PlanDayDataSnapshot
    ) -> Bool {
        // Route cache is only a display accelerator. Never publish it before
        // the current raw-backed day snapshot has been validated.
        guard dayData.isComplete,
              let sourceFingerprint = dayData.sourceFingerprint,
              payload.sourceFingerprint == sourceFingerprint,
              payload.readingsFingerprint
                == MapHomeDayCacheReadingsFingerprint(
                    readings: dayData.readings
                ) else {
            TaptionPlanDiagnosticsLogger.shared.record(
                "map_day_cache_rejected",
                fields: ["reason": "day_content_mismatch"]
            )
            return false
        }
        timelineRouteOverlays = payload.timeline.compactMap { overlay in
            let coordinates = overlay.coordinates.compactMap { coordinate -> CLLocationCoordinate2D? in
                guard coordinate.latitude.isFinite,
                      coordinate.longitude.isFinite,
                      (-90...90).contains(coordinate.latitude),
                      (-180...180).contains(coordinate.longitude) else { return nil }
                return CLLocationCoordinate2D(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
            }
            guard coordinates.count >= 2,
                  coordinates.count == overlay.coordinateTimestamps.count,
                  overlay.coordinateTimestamps.allSatisfy(RouteTimelineTimestamp.isValid)
            else { return nil }
            return MapHomeTimelineRouteOverlay(
                id: overlay.id,
                categoryID: overlay.categoryID,
                opacity: overlay.opacity,
                speedMetersPerSecond: overlay.speedMetersPerSecond,
                coordinates: coordinates,
                coordinateTimestamps: overlay.coordinateTimestamps
            )
        }
        cachedTemporaryLocations = (payload.temporaryLocations ?? []).compactMap { item in
            guard item.latitude.isFinite, item.longitude.isFinite,
                  (-90...90).contains(item.latitude), (-180...180).contains(item.longitude)
            else { return nil }
            return SubwayStationCatalog.TemporaryLocation(
                id: item.id, timestamp: item.timestamp, stationName: item.stationName,
                point: GeoPoint(
                    latitude: item.latitude, longitude: item.longitude,
                    altitude: .nan, horizontalAccuracy: .nan, verticalAccuracy: .nan
                ), reason: item.reason
            )
        }
        expectedRouteOverlays = (payload.expected ?? []).compactMap { overlay in
            guard let mode = TravelMode(rawValue: overlay.modeRawValue)
            else { return nil }
            let coordinates = overlay.coordinates.compactMap {
                cachedCoordinate($0)
            }
            guard coordinates.count >= 2 else { return nil }
            return MapHomeExpectedRouteOverlay(
                id: overlay.id,
                segmentID: overlay.segmentID,
                mode: mode,
                departureDate: overlay.departureDate,
                arrivalDate: overlay.arrivalDate,
                coordinates: coordinates
            )
        }
        mapRenderCache.invalidateExpectedRoutes()
        requestWBSPlaybackProjectionRefresh()
        if let subwayMinute = payload.subwayMinute {
            let overlays: [MapHomeSubwayRouteOverlay] =
                (payload.subway ?? []).compactMap { overlay in
                let coordinates = overlay.coordinates.compactMap {
                    cachedCoordinate($0)
                }
                guard !overlay.estimated, coordinates.count >= 2 else {
                    return nil
                }
                return MapHomeSubwayRouteOverlay(
                    id: overlay.id,
                    coordinates: coordinates,
                    estimated: overlay.estimated,
                    travelID: overlay.travelID
                )
            }
            mapRenderCache.restoreSubwayRoutes(
                day: Calendar.autoupdatingCurrent.startOfDay(for: date),
                minute: subwayMinute,
                overlays: overlays
            )
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "map_day_cache_restored",
            fields: [
                "day_start": String(
                    Calendar.autoupdatingCurrent.startOfDay(
                        for: date
                    ).timeIntervalSince1970
                ),
                "timeline_overlay_count": String(timelineRouteOverlays.count),
                "expected_overlay_count": String(expectedRouteOverlays.count),
                "temporary_location_count": String(cachedTemporaryLocations.count),
                "subway_overlay_count": String((payload.subway ?? []).count),
                "source_updated_at": payload.sourceUpdatedAt.map {
                    String($0.timeIntervalSince1970)
                } ?? "none",
            ]
        )
        return true
    }

    var routeOverlayCutoff: Date {
        let timelineDate = routeTimelineDate
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        return MapHomeRouteOverlayCutoffPolicy.cutoff(
            selectedDayEnd: dayEnd,
            timelineDate: timelineDate,
            isPlaybackRunning: isDayPlaybackRunning,
            interactiveProjectionCutoff: isTimelineInteractionActive
                && !isDayPlaybackRunning
                ? routeProjection?.cutoff
                : nil
        )
    }

    func requestRouteProjectionRefresh(
        preparingReadings: Bool = false
    ) {
        guard scenePhase == .active else { return }
        guard !isTimelineInteractionActive || isDayPlaybackRunning else {
            routeDocumentProjectionGate.deferRefresh(
                preparingReadings: preparingReadings
            )
            return
        }
        if preparingReadings {
            prepareRouteProjectionReadings()
        }
        refreshRouteProjection()
        recordCurrentPlaybackAlignment()
    }

    func removeCompletedExpectedRoutes(at timestamp: Date) {
        guard !expectedRouteOverlays.isEmpty else { return }
        let travel = currentDayDataSnapshot?.travel ?? []
        let travelByID = Dictionary(
            uniqueKeysWithValues: travel.map { ($0.id, $0) }
        )
        let readings = currentDayReadings
        let completed = Set<UUID>(expectedRouteOverlays.compactMap { overlay in
            guard overlay.departureDate <= timestamp,
                  let segment = travelByID[overlay.segmentID],
                  TaptionRouteEngineAdapter.hasCompleteRecordedRoute(
                      for: segment,
                      readings: readings
                  ) else { return nil }
            return overlay.id
        })
        guard !completed.isEmpty else { return }
        expectedRouteOverlays.removeAll { completed.contains($0.id) }
        mapRenderCache.invalidateExpectedRoutes()
        refreshWBSPlaybackProjection()
        persistMapDayCache()
    }

    @discardableResult
    func flushDeferredRouteProjection() -> RouteTimelineProjection? {
        guard let refresh = routeDocumentProjectionGate
            .consumeDeferredRefresh() else {
            return nil
        }
        if refresh.preparesReadings {
            prepareRouteProjectionReadings()
        }
        let projection = refreshRouteProjection()
        flushDeferredWBSPlaybackProjection()
        recordCurrentPlaybackAlignment()
        return projection
    }

    @discardableResult
    /// 경로 갱신을 요청하고 지금 가진 결과를 돌려준다. 계산은 백그라운드에서 하고, 끝나면 화면에 반영한다.
    func refreshRouteProjection() -> RouteTimelineProjection? {
        scheduleRouteProjection()
        return routeProjection
    }
}
