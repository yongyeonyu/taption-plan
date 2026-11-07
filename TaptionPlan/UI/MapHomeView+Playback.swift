import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    var dayPlaybackCurrentMinute: Double? {
        get {
            if MapHomeMinuteFreeze.isFrozen { return playbackProgress.rawCurrentMinute }
            MapHomePlaybackProbe.noteMinuteRead()
            return playbackProgress.currentMinute
        }
        nonmutating set {
            playbackProgress.rawCurrentMinute = newValue
            playbackProgress.currentMinute = newValue
        }
    }

    /// 측정용: `-benchHide=rails,topleft`로 영역을 빼고 끊김이 어디서 오는지 가른다(ARC1030A01).
    static func benchHidden(_ name: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-benchHide=") && $0.contains(name) }
    }

    var appleMapPlayback: MapHomeApplePlayback? {
        guard !isDisplayedCatAtHome,
              let coordinate = displayedLocationCoordinate else { return nil }
        let heading: CLLocationDirection
        let phase: MapHomeAppleRoutePhase
        let animationPhase: Int?
        let cameraCoordinate: CLLocationCoordinate2D
        if selectedPawprintPoint != nil {
            heading = CLLocationDirection(wbsPlaybackFrame?.direction.rawValue ?? 0) * 45
            phase = .actual
            animationPhase = wbsPlaybackFrame?.stickmanFrameIndex
            cameraCoordinate = coordinate
        } else if let frame = wbsPlaybackFrame {
            heading = CLLocationDirection(frame.direction.rawValue * 45)
            phase = frame.routePhase == .actual ? .actual : .forecast
            animationPhase = frame.stickmanFrameIndex
            cameraCoordinate = CLLocationCoordinate2D(
                latitude: frame.cameraCoordinate.latitude,
                longitude: frame.cameraCoordinate.longitude
            )
        } else if let route = activeExpectedRoute {
            heading = MapHomeApplePlaybackMath.heading(
                at: displayedLocationDate,
                departureDate: route.departureDate,
                arrivalDate: route.arrivalDate,
                coordinates: route.coordinates,
                segmentLengths: route.segmentLengths
            )
            phase = .forecast
            animationPhase = MapHomeExpectedRoutePlaybackMath.progress(
                at: displayedLocationDate,
                departureDate: route.departureDate,
                arrivalDate: route.arrivalDate
            ).map(MapHomeStickmanAnimationEngine.phase(for:))
            cameraCoordinate = coordinate
        } else {
            heading = MapHomeApplePlaybackMath.stableHeading(
                MapHomePlaybackLocation.gapHeading(at: displayedLocationDate, travel: currentDayDataSnapshot?.travel ?? [], readings: historicalPlaybackReadings)
                    ?? MapHomeApplePlaybackMath.heading(
                    at: displayedLocationDate,
                    readings: historicalPlaybackReadings
                ) ?? model.latestSensorReading?.courseDegrees
                    ?? headingMonitor.headingDegrees
                    ?? 0
            )
            phase = .actual
            animationPhase = routeProjection.flatMap {
                MapHomeRouteTimelinePlaybackMath.progress(
                    at: displayedLocationDate,
                    in: $0.segments
                )
            }.map(MapHomeStickmanAnimationEngine.phase(for:))
            cameraCoordinate = coordinate
        }
        let action = displayedStickmanAction
        return MapHomeApplePlayback(
            coordinate: coordinate,
            cameraCoordinate: cameraCoordinate,
            headingDegrees: heading,
            action: action,
            accessibilityLabel: "\(displayedLocationAccessibilityLabel) · \(action.title)",
            phase: phase,
            followsUserLocation: selectedTimelineMinute == nil,
            equippedAccessoryID: homeGrowthHistory.season.equippedAccessory,
            stickmanAnimationPhase: selectedTimelineMinute == nil
                ? nil
                : animationPhase
        )
    }

    /// 실제 경로의 좌표와 시각을 함께 샘플링하며 예상 발자국에는 시각을 부여하지 않는다.
    /// 구동기 재생 중에는 화랑이가 지나간 시각까지의 발자국만 보여, 발자국이 화랑이가 지나가면서 깔린다(대표 지시, ARC1030A05).
    /// 재생을 누르자마자 하루치 발자국이 한꺼번에 깔리던 것을 막는다. 벡터 지도는 화면 틱마다, Apple 지도는 분 알림마다 부른다.
    func playbackVisibleWaypoints(_ all: [PawprintWaypoint]) -> [PawprintWaypoint] {
        guard let driver = playbackDriver else { return all }
        let now = driver.inputs.dayStart.addingTimeInterval(driver.minute * 60)
        return all.filter { $0.timestamp.map { $0 <= now } ?? true }
    }

    var dayPlaybackButton: some View {
        Button {
            toggleDayPlayback()
        } label: {
            Image(systemName: isDayPlaybackRunning ? "pause.fill" : "play.fill")
                .font(.system(size: MapHomeSearchLayoutMath.playbackIconSize, weight: .bold))
                .foregroundStyle(Color.tpInk)
                .frame(
                    width: MapHomeSearchLayoutMath.playbackVisualSize,
                    height: MapHomeSearchLayoutMath.playbackVisualSize
                )
                .background(Color.tpSurface.opacity(0.96), in: Circle())
                .overlay {
                    Circle().stroke(Color.tpLine.opacity(0.78), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.07), radius: 9, y: 3)
                .frame(
                    width: MapHomeSearchLayoutMath.playbackTouchSize,
                    height: MapHomeSearchLayoutMath.playbackTouchSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isDayPlaybackRunning
                ? language.text("하루 재생 일시 정지", "Pause day playback")
                : language.text("하루 재생", "Play day")
        )
    }

    var recordingLayers: MapHomeRecordingLayers {
        MapHomeRecordingLayers(rawValue: recordingLayersRaw)
    }

    /// 녹화 중에는 고른 레이어만 보이고, 녹화 중이 아니면 항상 보인다.
    func recordingShows(_ layer: KeyPath<MapHomeRecordingLayers, Bool>) -> Bool {
        if layer == \MapHomeRecordingLayers.routes, !showsRoutesOnMap { return false }
        if layer == \MapHomeRecordingLayers.footprints, !showsFootprintsOnMap { return false }
        return !isScreenRecording || recordingLayers[keyPath: layer]
    }

    /// 녹화 메뉴를 열기 전에 사진 저장 권한과 화면 기록 허용을 먼저 받는다.
    func openRecordingOptions() {
        Task { @MainActor in
            guard await MapHomeScreenRecordingStore.requestPhotoAddAccess() else {
                recordingFailureMessage = "사진 저장 권한이 없어 녹화하지 않았습니다. 설정에서 사진 권한을 허용해 주세요."
                return
            }
            guard await screenRecorder.probePermission() else {
                recordingFailureMessage = screenRecorder.lastFailureMessage ?? "화면 녹화를 시작하지 못했습니다."
                return
            }
            // 본문이 표시 상태를 읽지 않게 측정은 여는 자리에서 시작한다.
            MapHomeInteractionMonitor.shared.begin("popup_recording", duration: 1.2)
            isRecordingOptionsPresented = true
        }
    }

    func startRecordingPlayback() {
        isRecordingOptionsPresented = false
        // 권한 확인·ReplayKit 시작 대기 동안 기존 재생이 계속 돌지 않게 먼저 멈춘다.
        if isDayPlaybackRunning { stopDayPlayback(resetProgress: true) }
        Task { @MainActor in
            // 권한은 재생 전에 먼저 묻는다: 사진 저장 → 화면 녹화.
            guard await MapHomeScreenRecordingStore.requestPhotoAddAccess() else {
                TaptionPlanDiagnosticsLogger.shared.record("screen_recording_blocked", fields: ["reason": "photo_access_denied"])
                recordingFailureMessage = "사진 저장 권한이 없어 녹화하지 않았습니다. 설정에서 사진 권한을 허용해 주세요."
                return
            }
            isScreenRecording = true
            // 시트가 내려가고 화면이 정리될 시간을 둔다.
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard await screenRecorder.start() else {
                isScreenRecording = false
                recordingFailureMessage = screenRecorder.lastFailureMessage ?? "화면 녹화를 시작하지 못했습니다."
                return
            }
            // 녹화는 항상 자정(0시)부터 처음부터 재생한다.
            startDayPlayback(fromMidnight: true)
        }
    }

    func finishRecordingPlayback() {
        guard isScreenRecording else { return }
        Task { @MainActor in
            let recorded = await screenRecorder.stop()
            isScreenRecording = false
            guard let recorded else { return }
            let url = await recordingWithSelectedMusic(recorded)
            let saved = await MapHomeScreenRecordingStore.saveToPhotos(url)
            TaptionPlanDiagnosticsLogger.shared.record("screen_recording_saved", fields: ["saved": saved ? "true" : "false"])
            // 녹화 화면을 닫는 애니메이션이 끝난 뒤 공유 시트를 연다.
            try? await Task.sleep(for: .milliseconds(400))
            recordedVideoShare = url
        }
    }

    /// 고른 곡을 넣은 파일을 돌려준다. 넣지 못하면 음악 없는 원본을 살리고 알린다.
    func recordingWithSelectedMusic(_ recorded: URL) async -> URL {
        let raw = UserDefaults.standard.string(forKey: "playbackVideoMusic") ?? MapHomePlaybackMusicTrack.defaultID
        guard let music = MapHomePlaybackMusicTrack.stored(raw)?.url else { return recorded }
        do {
            let url = try await MapHomeRecordingMusicMuxer.mux(video: recorded, music: music)
            try? FileManager.default.removeItem(at: recorded)
            return url
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record("screen_recording_music_failed", level: .error, fields: ["error": String(describing: error)])
            recordingFailureMessage = language.text("음악을 넣지 못해 음악 없이 저장했습니다.", "Couldn't add music, so the video was saved without it.")
            return recorded
        }
    }

    func toggleDayPlayback() {
        if isDayPlaybackRunning {
            stopDayPlayback(resetProgress: false)
        } else {
            startDayPlayback()
        }
    }

    /// 재생은 사이드바 시각과 상관없이 늘 자정(00시)부터 시작한다(대표 지시, ARC1030A02).
    func startDayPlayback(fromMidnight: Bool = true) {
        dayPlaybackTask?.cancel()
        let currentDate = Date.now
        let playbackEndMinute = MapHomeDayPlaybackMath.playbackEndMinute(
            for: model.selectedDate,
            now: currentDate
        )
        let defaultMinute = MapHomeDayPlaybackMath.playbackStartMinute(
            selectedMinute: selectedTimelineMinute,
            endMinute: playbackEndMinute,
            isToday: Calendar.autoupdatingCurrent.isDate(
                model.selectedDate,
                inSameDayAs: currentDate
            )
        )
        let pawSelection = MapHomePawprintInteractionPolicy.selection(
            timestamp: selectedPawprintTimestamp, isPredicted: false,
            selectedDate: model.selectedDate
        )
        let currentMinute = fromMidnight ? 0 : (pawSelection.map {
            defaultMinute == Double($0.minute) && $0.minuteOffset < playbackEndMinute
                ? $0.minuteOffset : defaultMinute
        } ?? defaultMinute)
        selectedPawprintTimestamp = nil
        selectedPawprintCoordinate = nil
        var playbackMinute = currentMinute
        dayPlaybackCurrentMinute = currentMinute
        let movingRanges = dayPlaybackMovementRanges
        playbackZoomPlan = makePlaybackZoomPlan(movingRanges: movingRanges)
        if currentMinute == 0 {
            selectedTimelineMinute = 0
        }
        isTimelineSelectionPinned = true
        isTimelineInteractionActive = true
        isDayPlaybackRunning = true
        playbackZoomSmoother.reset()
        lastPlaybackRouteProjectionUptime = 0
        lastPlaybackMapFocusUptime = 0
        lastPlaybackMarkerUptime = 0
        mapRenderCache.invalidateRouteData()
        routeProjection = nil
        timelineRouteOverlays = []
        prepareRouteProjectionReadings()
        hasDeferredWBSPlaybackRefresh = false
        refreshWBSPlaybackProjection()
        refreshRouteProjection()
        recordCurrentPlaybackAlignment()
        lastPlaybackRouteProjectionUptime = ProcessInfo.processInfo.systemUptime
        // 재생은 개요 연출 없이 00시 위치로 바로 포커싱한다(대표 지시, ARC1030A05).
        isPlaybackIntroActive = false
        playbackIntroTask?.cancel()
        // 벡터 지도와 Apple 지도 모두 구동기가 프레임마다 지도 엔진에 카메라를 바로 놓는다(대표 지시, ARC1030A04).
        startDriverPlayback(
            startMinute: currentMinute, endMinute: playbackEndMinute, movingRanges: movingRanges
        )
    }

    var dayPlaybackMovementRanges: [MapHomePlaybackMovementRange] {
        let calendar = Calendar.autoupdatingCurrent
        let dayData = currentDayDataSnapshot
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let readingRanges = dayPlaybackReadingRanges(
            from: routeReadings + model.liveRouteState.readings,
            dayStart: dayStart,
            dayEnd: dayEnd
        )
        // 세부 활동(머무름·휴식·걷기)을 이동 구간에서 떼어 각자의 속도로 재생한다.
        let details: [(start: Double, end: Double, mode: TravelMode?, isStationary: Bool)] = (dayData?.actuals ?? []).compactMap { actual in
            let start = actual.startedAt.timeIntervalSince(dayStart) / 60
            let end = (actual.endedAt ?? actual.startedAt.addingTimeInterval(60)).timeIntervalSince(dayStart) / 60
            guard end > start else { return nil }
            let title = actual.title
            if title.contains("걷기") || title.contains("Walk") {
                return (start, end, .walking, false)
            }
            if title.contains("머무름") || title.contains("휴식") || title.contains("Rest") || title.contains("Stay") {
                return (start, end, nil, true)
            }
            return nil
        }
        let travelRanges = (dayData?.travel ?? []).flatMap { segment -> [MapHomePlaybackMovementRange] in
            // 확정되지 않은 이동도 대분류가 '이동'이면 이동 배속으로 지나간다(정지 배속이면 한순간에 사라진다).
            guard segment.distanceMeters > 0
                    || segment.mode == .subway
                        && ((segment.subwayRoute?.coordinates.count ?? 0) >= 2)
            else { return [] }
            let range = MapHomePlaybackMovementRange(
                startMinute: segment.span.start.timeIntervalSince(dayStart) / 60,
                endMinute: segment.span.end.timeIntervalSince(dayStart) / 60,
                mode: segment.mode
            )
            return MapHomePlaybackMovementRange.carved(range, details: details)
        }
        // 이동으로 분류된 시간은 확정 여부·센서 유무와 상관없이 이동 배속으로 본다.
        let categoryRanges = MapHomePlaybackCategoryRanges.movementRanges(
            snapshot: dayData, frequentPlaces: model.snapshot.settings.frequentPlaces,
            dayStart: dayStart, dayEnd: dayEnd)
        return MapHomePlaybackCategoryRanges.removingSleep(MapHomePlaybackMovementRange.normalized(
            readingRanges + travelRanges + categoryRanges
        ), snapshot: dayData, dayStart: dayStart)
    }

    func dayPlaybackReadingRanges(
        from readings: [SensorReading],
        dayStart: Date,
        dayEnd: Date
    ) -> [MapHomePlaybackMovementRange] {
        let ordered = readings
            .filter {
                RouteTimelineTimestamp.isValid($0.timestamp)
                    && $0.timestamp >= dayStart
                    && $0.timestamp < dayEnd
                    && $0.point != nil
                    && $0.motion.isMovement
            }
            .sorted { $0.timestamp < $1.timestamp }
        guard let first = ordered.first else { return [] }

        var result: [MapHomePlaybackMovementRange] = []
        var start = first.timestamp
        var previous = first.timestamp
        var mode = playbackMode(for: first)
        for reading in ordered.dropFirst() {
            let nextMode = playbackMode(for: reading)
            if reading.timestamp.timeIntervalSince(previous) > 15 * 60
                || nextMode != mode {
                result.append(
                    MapHomePlaybackMovementRange(
                        startMinute: start.timeIntervalSince(dayStart) / 60,
                        endMinute: previous.timeIntervalSince(dayStart) / 60,
                        mode: mode
                    )
                )
                start = reading.timestamp
                mode = nextMode
            }
            previous = reading.timestamp
        }
        result.append(
            MapHomePlaybackMovementRange(
                startMinute: start.timeIntervalSince(dayStart) / 60,
                endMinute: previous.timeIntervalSince(dayStart) / 60,
                mode: mode
            )
        )
        return result
    }

    func playbackMode(for reading: SensorReading) -> TravelMode? {
        if reading.matchesRailRoute
            || (reading.subwayWiFiObservationStreak ?? 0) > 0 {
            return .subway
        }
        if reading.matchesPublicTransitRoute {
            return .bus
        }
        if reading.onWater {
            return .ship
        }
        switch reading.motion {
        case .walking: return .walking
        case .running: return .running
        case .cycling: return .cycling
        case .automotive: return .car
        case .stationary, .unknown: return nil
        }
    }

    /// 재생 중이면 **취소**한다. 재생을 시작하기 전 시각으로 되돌리므로
    /// (`resetProgress: true`) '멈춤'이 아니라 '취소'다. 지도를 움직이거나
    /// 현재 위치로 갈 때 부른다 — 하단 단추는 늘리지 않는다(대표 요청, 2026-10-26).
    func cancelDayPlaybackIfRunning() {
        guard isDayPlaybackRunning else { return }
        stopDayPlayback(resetProgress: true)
    }

    /// 재생 구동기를 세운다. 프레임 계산은 구동기, 화면 갱신은 정수 분마다(PLY1029A03).
    func makePlaybackZoomPlan(movingRanges: [MapHomePlaybackMovementRange]) -> MapHomePlaybackZoomPlan {
        let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate)
        let readings = routeReadings + model.liveRouteState.readings
        let places = model.settings.frequentPlaces.compactMap(\.point)
        return MapHomePlaybackZoomPlan(
            inputs: MapHomePlaybackZoomInputBuilder.inputs(
                ranges: movingRanges, dayStart: dayStart, travel: currentDayDataSnapshot?.travel ?? [],
                readings: readings, places: places
            ),
            profile: MapHomePlaybackZoomProfile.build(readings: readings, places: places, dayStart: dayStart)
        )
    }

    /// 실시간 재생과 영상 렌더링이 같은 입력을 쓴다(VID1029A01).
    func playbackDriverInputs(
        startMinute: Double, endMinute: Double, movingRanges: [MapHomePlaybackMovementRange],
        zoomPlan: MapHomePlaybackZoomPlan
    ) -> MapHomePlaybackDriver.Inputs {
        .init(
            startMinute: startMinute, endMinute: endMinute, movingRanges: movingRanges,
            dayStart: Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate),
            readings: routeReadingsLoadState.isLoaded(for: model.selectedDate) ? historicalPlaybackReadings : [],
            travel: currentDayDataSnapshot?.travel ?? [],
            places: currentDayDataSnapshot?.places ?? [],
            zoomPlan: zoomPlan
        )
    }

    /// 하루 재생을 프레임마다 그려 끊김 없는 60fps 영상으로 만든다(VID1029A01). 화랑이는 정중앙 고정.
    func makePlaybackVideoRenderer(hiddenPlaces: [MapHomeRangeTripPlan.Point]) -> MapHomePlaybackVideoRenderer? {
        // 영상은 벡터 지도로만 그린다. 애플 지도를 쓰는 중이면 기본 벡터 지도로 만든다.
        guard let style = model.settings.mapDisplayStyle.runtimeStyle.mapHomeVectorStyle
            ?? MapDisplayStyle.mapLibreRPG.runtimeStyle.mapHomeVectorStyle else { return nil }
        let ranges = dayPlaybackMovementRanges
        let end = MapHomeDayPlaybackMath.playbackEndMinute(for: model.selectedDate, now: .now)
        var timeline = MapHomePlaybackTimeline(
            inputs: playbackDriverInputs(
                startMinute: 0, endMinute: end, movingRanges: ranges, zoomPlan: makePlaybackZoomPlan(movingRanges: ranges)
            ),
            projection: wbsPlaybackProjection
        )
        timeline.preferredForecastLegIDs = visibleForecastPlaybackLegIDs
        timeline.expectedCoordinate = expectedRouteCoordinateLookup()
        timeline.isAdaptiveZoom = MapHomePlaybackZoomMode(rawValue: playbackZoomModeRaw) != .fixed
        let day = currentDayDataSnapshot
        let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate)
        let frequentPlaces = model.settings.frequentPlaces
        let sleepSessions = model.sleepSessions
        let accessory = homeGrowthHistory.season.equippedAccessory
        return MapHomePlaybackVideoRenderer(style: style, timeline: timeline, hiddenPlaces: hiddenPlaces) { minute in
            MapHomePlaybackVideoStickman(
                action: MapHomeStickmanActionResolver.action(
                    at: dayStart.addingTimeInterval(minute * 60), actuals: day?.actuals ?? [],
                    travel: day?.travel ?? [], places: day?.places ?? [], frequentPlaces: frequentPlaces,
                    sleepSessions: sleepSessions
                ),
                equippedAccessoryID: accessory
            )
        }
    }

    func startDriverPlayback(
        startMinute: Double, endMinute: Double, movingRanges: [MapHomePlaybackMovementRange]
    ) {
        let driver = MapHomePlaybackDriver(inputs: playbackDriverInputs(
            startMinute: startMinute, endMinute: endMinute, movingRanges: movingRanges, zoomPlan: playbackZoomPlan
        ))
        syncPlaybackDriverProjection(driver)
        driver.isAdaptiveZoom = MapHomePlaybackZoomMode(rawValue: playbackZoomModeRaw) != .fixed
        driver.isCameraSuppressed = { isPlaybackIntroActive }
        // 측정용: `-benchMinute=none|sel|cur|proj`면 분 알림이 하는 일을 골라서 한다(정지 원인을 가를 때만 쓴다, ARC1030A01).
        let benchMinute = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("-benchMinute=") }?
            .dropFirst("-benchMinute=".count)
        driver.onMinute = { minute in
            let probe = MapHomePlaybackProbe.begin("onMinute"); defer { MapHomePlaybackProbe.end(probe) }
            let whole = min(MapHomeTimeSidebarMath.fullDayMinutes, max(0, Int(minute.rounded(.down))))
            if benchMinute == nil || benchMinute == "sel" {
                if selectedTimelineMinute != whole { selectedTimelineMinute = whole }
            }
            if benchMinute == nil || benchMinute == "cur" {
                dayPlaybackCurrentMinute = Double(whole)
            }
            playbackProgress.advanceCoarseTickIfNeeded(nowUptime: ProcessInfo.processInfo.systemUptime)
            if TimelineInteractionFrameGate.shouldRender(
                lastUptime: &lastPlaybackTraceUptime,
                nowUptime: ProcessInfo.processInfo.systemUptime,
                minimumInterval: 5
            ) {
                // 재생 중 경로가 실제로 쌓이는지 로그로 남긴다(발자국이 안 나오던 문제 확인용, ARC1030A02).
                TaptionPlanDiagnosticsLogger.shared.record("playback_route_trace", fields: [:], metrics: [
                    "minute": minute,
                    "overlays": Double(timelineRouteOverlays.count),
                    "overlay_points": Double(timelineRouteOverlays.reduce(0) { $0 + $1.coordinates.count }),
                    "live_markers": Double(vectorMapViewportStore.livePlaybackViewport?.markerPoints.count ?? 0),
                    "in_flight": routeProjectionInFlight ? 1 : 0,
                    "runs": Double(routeProjectionRunID),
                    "applied": Double(routeProjectionApplied),
                    "last_ms": routeProjectionLastMS,
                    "segments": Double(routeProjection?.segments.count ?? -1),
                    "skip_nosnapshot": Double(routeProjectionSkips[0]),
                    "scene_active": scenePhase == .active ? 1 : 0,
                    "has_snapshot": dayDataSnapshot != nil ? 1 : 0,
                    "snapshot_complete": dayDataSnapshot?.isComplete == true ? 1 : 0,
                    "snapshot_version": Double(dayDataSnapshot?.projectionVersion ?? 0),
                    "same_day": dayDataSnapshot.map { Calendar.autoupdatingCurrent.isDate($0.day, inSameDayAs: model.selectedDate) ? 1.0 : 0.0 } ?? -1,
                    "rev_model": Double(model.dayProjectionRevision),
                    "rev_snapshot": Double(dayDataSnapshot?.sourceRevision ?? 0),
                    "skip_samekey": Double(routeProjectionSkips[1]),
                    "skip_inflight": Double(routeProjectionSkips[2]),
                ])
            }
            // 경로 투영은 지도 경로 전체를 다시 그린다. 재생 중에는 1초에 한 번만(PLY1029A06).
            if benchMinute == nil || benchMinute == "proj", TimelineInteractionFrameGate.shouldRender(
                lastUptime: &lastPlaybackRouteProjectionUptime,
                nowUptime: ProcessInfo.processInfo.systemUptime,
                minimumInterval: 1
            ) {
                refreshRouteProjection()
            }
        }
        driver.onFinished = { finishDayPlayback(endMinute: endMinute) }
        vectorMapViewportStore.livePlaybackViewport = nil
        playbackDriver = driver
        driver.start()
    }

    /// 예상 경로가 풀려 투영이 바뀌면 구동기에도 넘긴다.
    func syncPlaybackDriverProjection(_ driver: MapHomePlaybackDriver? = nil) {
        guard let driver = driver ?? playbackDriver else { return }
        driver.projection = wbsPlaybackProjection
        driver.preferredForecastLegIDs = visibleForecastPlaybackLegIDs
        driver.expectedCoordinate = expectedRouteCoordinateLookup()
    }

    /// 재생이 끝까지 간 뒤의 마무리(예전 루프와 구동기가 함께 쓴다).
    func finishDayPlayback(endMinute: Double) {
        selectedTimelineMinute = endMinute >= Double(MapHomeTimeSidebarMath.fullDayMinutes)
            ? MapHomeTimeSidebarMath.fullDayMinutes
            : min(MapHomeTimeSidebarMath.fullDayMinutes - 1, max(0, Int(endMinute.rounded(.down))))
        isDayPlaybackRunning = false
        isTimelineInteractionActive = false
        dayPlaybackCurrentMinute = nil
        _ = flushDeferredRouteProjection() ?? refreshRouteProjection()
        flushDeferredWBSPlaybackProjection()
        recordCurrentPlaybackAlignment()
        dayPlaybackTask = nil
        playbackDriver = nil
        lastPlaybackRouteProjectionUptime = 0
        lastPlaybackMapFocusUptime = 0
        lastPlaybackMarkerUptime = 0
    }

    func stopDayPlayback(resetProgress: Bool) {
        playbackDriver?.stop()
        playbackDriver = nil
        playbackIntroTask?.cancel()
        isPlaybackIntroActive = false
        selectedPawprintTimestamp = nil
        selectedPawprintCoordinate = nil
        let wasRunning = isDayPlaybackRunning
        if wasRunning, !resetProgress, let currentMinute = dayPlaybackCurrentMinute {
            selectedTimelineMinute = min(
                MapHomeTimeSidebarMath.fullDayMinutes,
                max(0, Int(currentMinute.rounded(.down)))
            )
        }
        dayPlaybackTask?.cancel()
        dayPlaybackTask = nil
        isDayPlaybackRunning = false
        dayPlaybackCurrentMinute = nil
        lastPlaybackRouteProjectionUptime = 0
        lastPlaybackMapFocusUptime = 0
        lastPlaybackMarkerUptime = 0
        lastTimelineMapFocusUptime = 0
        if wasRunning {
            isTimelineInteractionActive = false
            _ = flushDeferredRouteProjection()
                ?? refreshRouteProjection()
            flushDeferredWBSPlaybackProjection()
            recordCurrentPlaybackAlignment()
        }
    }

    var playbackMomentEvents: [(minute: Double, moment: MapHomePlaybackMomentsOverlay.Moment)] {
        MapHomePlaybackMomentsOverlay.events(memos: timedMemosForSelectedDate, day: model.selectedDate)
    }

    var playbackPhotos: [MapHomePlaybackPhotoStrip.Photo] {
        MapHomePlaybackPhotoStrip.photos(from: photoMoments, day: model.selectedDate)
    }

    var visibleWBSGeneratedRouteOverlays: [MapHomeWBSGeneratedRouteOverlay] {
        guard Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate) else { return [] }
        let cutoff = routeOverlayCutoff
        return wbsGeneratedRouteOverlays.filter { !hasRouteDecision(predictedRoute(for: $0)) }.compactMap {
            $0.visible(through: cutoff)
        }
    }

    func generatedWBSRouteOverlays(
        from projection: MapHomeWBSPlaybackProjection,
        excluding excludedLegIDs: Set<String>
    ) -> [MapHomeWBSGeneratedRouteOverlay] {
        projection.legs.compactMap { leg in
            guard leg.routePhase == .forecast,
                  leg.activity == .movement,
                  !excludedLegIDs.contains(leg.id),
                  leg.coordinates.count >= 2 else { return nil }
            return MapHomeWBSGeneratedRouteOverlay(
                id: leg.id,
                mode: leg.mode,
                departureDate: leg.startDate,
                arrivalDate: leg.endDate,
                coordinates: leg.coordinates.map {
                    CLLocationCoordinate2D(
                        latitude: $0.latitude,
                        longitude: $0.longitude
                    )
                }
            )
        }
    }

    func recordExpectedRouteProjectionDiagnostics(
        phase: String,
        projection: MapHomeWBSPlaybackProjection,
        expected: [MapHomeExpectedRouteOverlay],
        generated: [MapHomeWBSGeneratedRouteOverlay],
        excludedLegIDs: Set<String>
    ) {
        let forecastMovements = projection.legs.filter {
            $0.routePhase == .forecast && $0.activity == .movement
        }
        let forecastGapMovements = forecastMovements.filter {
            $0.id.hasPrefix("movement-gap-")
        }
        let forecastTravelMovements = forecastMovements.filter {
            !$0.id.hasPrefix("movement-gap-")
                && $0.id.hasPrefix("movement-")
        }
        let actualMovements = projection.legs.filter {
            $0.routePhase == .actual && $0.activity == .movement
        }
        var intervalOverlapPairs = 0
        var sameEndpointPairs = 0
        if forecastMovements.count > 1 {
            for index in 0..<(forecastMovements.count - 1) {
                for otherIndex in (index + 1)..<forecastMovements.count {
                    let lhs = forecastMovements[index]
                    let rhs = forecastMovements[otherIndex]
                    let lhsSpan = TimeSpan(
                        start: lhs.startDate,
                        end: lhs.endDate
                    )
                    if lhsSpan.intersection(with: TimeSpan(
                        start: rhs.startDate,
                        end: rhs.endDate
                    )) != nil {
                        intervalOverlapPairs += 1
                    }
                    guard let lhsStart = lhs.coordinates.first,
                          let lhsEnd = lhs.coordinates.last,
                          let rhsStart = rhs.coordinates.first,
                          let rhsEnd = rhs.coordinates.last else {
                        continue
                    }
                    let sameDirection = distanceMeters(lhsStart, rhsStart) <= 100
                        && distanceMeters(lhsEnd, rhsEnd) <= 100
                    let reverseDirection = distanceMeters(lhsStart, rhsEnd) <= 100
                        && distanceMeters(lhsEnd, rhsStart) <= 100
                    if sameDirection || reverseDirection {
                        sameEndpointPairs += 1
                    }
                }
            }
        }
        let generatedModes = Dictionary(
            grouping: generated.compactMap(\.mode),
            by: { $0 }
        )
        var routeCandidates: [MapHomeExpectedRouteDiagnostics.Candidate] = []
        for route in expected {
            guard let first = route.coordinates.first, let last = route.coordinates.last else { continue }
            routeCandidates.append(MapHomeExpectedRouteDiagnostics.Candidate(
                kind: "expected", mode: route.mode.rawValue,
                start: route.departureDate, end: route.arrivalDate, first: first, last: last
            ))
        }
        for route in generated {
            guard let first = route.coordinates.first, let last = route.coordinates.last else { continue }
            routeCandidates.append(MapHomeExpectedRouteDiagnostics.Candidate(
                kind: "generated", mode: route.mode?.rawValue ?? "unknown",
                start: route.departureDate, end: route.arrivalDate, first: first, last: last
            ))
        }
        for leg in forecastMovements {
            guard let first = leg.coordinates.first, let last = leg.coordinates.last else { continue }
            let kind: String = leg.id.hasPrefix("movement-gap-") ? "forecast_gap" : "forecast_movement"
            routeCandidates.append(MapHomeExpectedRouteDiagnostics.Candidate(
                kind: kind, mode: "leg",
                start: leg.startDate, end: leg.endDate,
                first: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
                last: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude)
            ))
        }
        let routeSummary: [String: String] = MapHomeExpectedRouteDiagnostics.fields(for: routeCandidates)
        let baseFields: [String: String] = [
                "phase": phase,
                "expected_overlay_count": String(expected.count),
                "generated_overlay_count": String(generated.count),
                "projection_leg_count": String(projection.legs.count),
                "projection_forecast_movement_count": String(
                    forecastMovements.count
                ),
                "projection_forecast_travel_movement_count": String(
                    forecastTravelMovements.count
                ),
                "projection_forecast_gap_count": String(
                    forecastGapMovements.count
                ),
                "projection_actual_movement_count": String(
                    actualMovements.count
                ),
                "forecast_interval_overlap_pairs": String(
                    intervalOverlapPairs
                ),
                "forecast_same_endpoint_pairs": String(sameEndpointPairs),
                "excluded_leg_count": String(excludedLegIDs.count),
                "generated_mode_counts": TravelMode.allCases.compactMap {
                    mode in
                    guard let count = generatedModes[mode]?.count else {
                        return nil
                    }
                    return "\(mode.rawValue)=\(count)"
                }.joined(separator: ","),
        ]
        TaptionPlanDiagnosticsLogger.shared.record(
            "expected_route_projection_built",
            fields: baseFields.merging(routeSummary, uniquingKeysWith: { base, _ in base })
        )
    }

    func wbsRouteTransport(
        for mode: TravelMode?
    ) -> ExpectedRouteTransport? {
        guard let mode else { return nil }
        switch mode {
        case .car, .taxi: return .automobile
        case .bus, .subway, .train: return .transit
        case .walking, .running, .cycling: return .walking
        case .airplane, .ship: return .direct
        }
    }

    var wbsPlaybackFrame: MapHomeWBSPlaybackFrame? {
        let probe = MapHomePlaybackProbe.begin("wbsFrame"); defer { MapHomePlaybackProbe.end(probe) }
        guard selectedTimelineMinute != nil else { return nil }
        return wbsPlaybackProjection?.frame(
            at: displayedLocationDate,
            preferredForecastLegIDs: visibleForecastPlaybackLegIDs
        )
    }

    var visibleForecastPlaybackLegIDs: Set<String> {
        Set(
            displayedExpectedRouteOverlays.map {
                "movement-\($0.id.uuidString)"
            } + displayedWBSGeneratedRouteOverlays.map(\.id)
        )
    }

    var historicalPlaybackCoordinate: CLLocationCoordinate2D? {
        guard let point = displayedPlaybackLocation?.coordinate,
              isValid(point) else { return nil }
        return CLLocationCoordinate2D(
            latitude: point.latitude,
            longitude: point.longitude
        )
    }

    var expectedRoutePlaybackCoordinate: CLLocationCoordinate2D? {
        activeExpectedRoute?.coordinate(at: displayedLocationDate)
    }

    func computeRecordedStickmanAction() -> MapHomeStickmanAction {
        let actuals = currentDayDataSnapshot?.actuals ?? []
        let sleepSessions = model.sleepSessions
        if MapHomeStickmanActionResolver.hasAppleWatchConfirmedSleep(
            at: displayedLocationDate,
            actuals: actuals,
            sleepSessions: sleepSessions
        ) {
            return MapHomeStickmanActionResolver.sleepStageAction(at: displayedLocationDate, actuals: actuals, sleepSessions: sleepSessions)
        }
        let transitReadings = (currentDayDataSnapshot?.readings ?? routeReadings)
            + model.liveRouteState.readings
            + (model.latestSensorReading.map { [$0] } ?? [])
        let hasManualRecord = actuals.contains {
            ($0.manuallyCorrected || $0.source == .manual) && $0.startedAt <= displayedLocationDate && displayedLocationDate < ($0.endedAt ?? .distantFuture)
        }
        if !hasManualRecord, let mode = MapHomeLiveTransitPolicy.mode(at: displayedLocationDate, travel: currentDayDataSnapshot?.travel ?? [], readings: transitReadings) {
            return MapHomeStickmanActionResolver.action(for: mode)
        }
        // 등록 지점 안에서 걸으면 그 곳의 걷기다. 회사면 노트북을 들고 걷는다.
        let walkMinute = minuteOfDay(for: displayedLocationDate)
        if let walking = timeRailSegments.first(where: { $0.walkSpans.contains { $0.contains(walkMinute) } }) {
            return walking.categoryID == "work" ? .workWalking : .walking
        }
        // 대분류 줄이 정본이다. 식사·업무처럼 머무는 대분류면 근처 걸음 표본이나 다른 기록이 동작을 바꾸지 못한다.
        if let action = MapHomeStickmanActionResolver.railAction(
            segment: MapHomeTimeRailSegmentEngine.segment(at: walkMinute, in: timeRailSegments),
            details: sectionDetails(at: walkMinute),
            minute: walkMinute
        ) {
            return MapHomeStickmanActionResolver.placed(action, at: displayedLocationCoordinate, frequentPlaces: model.settings.frequentPlaces)
        }
        if let frame = wbsPlaybackFrame {
            switch frame.activity {
            case .movement:
                let mode = frame.mode ?? MapHomePlaybackLocation.gapMode(at: displayedLocationDate, travel: currentDayDataSnapshot?.travel ?? [], readings: historicalPlaybackReadings)
                return mode.map(MapHomeStickmanActionResolver.action(for:)) ?? .movement
            case .stay:
                if let categoryID = frame.categoryID {
                    // 머무는 동안도 그 시각의 상세 활동 장면을 쓴다(RIG1103A02).
                    let detail = sectionDetails(at: walkMinute)
                        .filter { $0.startMinute <= walkMinute && walkMinute < $0.endMinute }
                        .min { ($0.endMinute - $0.startMinute) < ($1.endMinute - $1.startMinute) }
                    return MapHomeStickmanActionResolver.action(for: categoryID, label: detail?.title ?? "")
                }
            }
        }
        if selectedTimelineMinute != nil, activeExpectedRoute == nil || currentDayDataSnapshot?.travel.contains(where: { $0.span.contains(displayedLocationDate) }) == true, let mode = MapHomePlaybackLocation.gapMode(at: displayedLocationDate, travel: currentDayDataSnapshot?.travel ?? [], readings: historicalPlaybackReadings) {
            return MapHomeStickmanActionResolver.action(for: mode)
        }
        if let activeExpectedRoute {
            return MapHomeStickmanActionResolver.action(for: activeExpectedRoute.mode)
        }
        let resolved = MapHomeStickmanActionResolver.action(
            at: displayedLocationDate,
            actuals: actuals,
            travel: currentDayDataSnapshot?.travel ?? [],
            places: currentDayDataSnapshot?.places ?? [],
            frequentPlaces: model.settings.frequentPlaces,
            readings: transitReadings,
            sleepSessions: sleepSessions
        )
        guard resolved == .activity, selectedTimelineMinute == nil else { return resolved }
        return MapHomeStickmanActionResolver.action(atCurrent: model.latestSensorReading?.point, frequentPlaces: model.settings.frequentPlaces) ?? resolved
    }

    var historicalPlaybackAccessibilityLabel: String {
        let minute = min(
            max(Int((displayedPlaybackMinute ?? 0).rounded(.down)), 0),
            MapHomeTimeSidebarMath.fullDayMinutes
        )
        let time = String(format: "%02d:%02d", minute / 60, minute % 60)
        return language.text("과거 위치 \(time)", "Past location \(time)")
    }

    func requestWBSPlaybackProjectionRefresh() {
        guard scenePhase == .active else {
            hasDeferredWBSPlaybackRefresh = true
            return
        }
        guard !isTimelineInteractionActive || isDayPlaybackRunning else {
            hasDeferredWBSPlaybackRefresh = true
            return
        }
        refreshWBSPlaybackProjection()
    }

    func flushDeferredWBSPlaybackProjection() {
        if let pendingForecastRouteState {
            self.pendingForecastRouteState = nil
            hasDeferredWBSPlaybackRefresh = false
            if !applyForecastRouteState(pendingForecastRouteState) {
                refreshWBSPlaybackProjection()
            }
            return
        }
        guard hasDeferredWBSPlaybackRefresh else { return }
        hasDeferredWBSPlaybackRefresh = false
        refreshWBSPlaybackProjection()
    }

    func refreshWBSPlaybackProjection() {
        guard scenePhase == .active else {
            hasDeferredWBSPlaybackRefresh = true
            return
        }
        hasDeferredWBSPlaybackRefresh = false
        var next = makeWBSPlaybackProjection(
            expected: expectedRouteOverlays,
            generated: wbsGeneratedRouteOverlays
        )
        let activeGeneratedIDs = Set(next.legs.compactMap { leg in
            leg.routePhase == .forecast && leg.activity == .movement
                ? leg.id
                : nil
        })
        let generated = wbsGeneratedRouteOverlays.filter {
            activeGeneratedIDs.contains($0.id)
        }
        if generated.count != wbsGeneratedRouteOverlays.count {
            wbsGeneratedRouteOverlays = generated
            mapRenderCache.invalidateExpectedRoutes()
            next = makeWBSPlaybackProjection(
                expected: expectedRouteOverlays,
                generated: generated
            )
        }
        if wbsPlaybackProjection != next {
            wbsPlaybackProjection = next
        }
        syncPlaybackDriverProjection()
    }

    func makeWBSPlaybackProjection(
        expected: [MapHomeExpectedRouteOverlay],
        generated: [MapHomeWBSGeneratedRouteOverlay],
        expectedRouteRequests: [ExpectedRouteRequest]? = nil
    ) -> MapHomeWBSPlaybackProjection {
        let dayData = currentDayDataSnapshot
        let playbackRequests: [ExpectedRouteRequest]?
        if let expectedRouteRequests {
            playbackRequests = expectedRouteRequests
        } else if wbsExpectedRouteRequestsInputKey == currentExpectedRouteInputKey() {
            playbackRequests = wbsExpectedRouteRequests
        } else {
            // 입력이 바뀐 뒤 아직 예상 경로 요청을 다시 만들지 않은 상태다. 여기서
            // 빈 배열을 넘기면 예상 이동 구간이 하나도 없는 투영이 만들어지고,
            // 확정된 장소가 없는 미확정 경로에서는 화랑이가 설 자리가 없어 사라진다.
            // 예상 경로 갱신과 같은 입력으로 다시 계산해 leg id를 맞춘다.
            let daySpan = Self.routeDaySpan(for: model.selectedDate)
            playbackRequests = ExpectedRouteRequestEngine.requests(
                travel: dayData?.travel ?? [],
                places: [],
                readings: normalizedRouteReadings,
                in: daySpan,
                through: daySpan.end,
                frequentPlaces: [],
                gpsLoggingInterval: model.settings.gpsLoggingPreferences.interval
            )
        }
        let expectedRoutes = expected.map { overlay in
            MapHomeWBSResolvedRoute(
                legID: "movement-\(overlay.id.uuidString)",
                coordinates: overlay.coordinates.map(wbsGeoPoint)
            )
        }
        let generatedRoutes = generated.map { overlay in
            MapHomeWBSResolvedRoute(
                legID: overlay.id,
                coordinates: overlay.coordinates.map(wbsGeoPoint)
            )
        }
        return MapHomeWBSPlaybackProjection.make(
            selectedDate: model.selectedDate,
            places: dayData?.places ?? [],
            travel: dayData?.travel ?? [],
            readings: currentDayReadings,
            expectedRouteRequests: playbackRequests,
            resolvedRoutes: expectedRoutes + generatedRoutes + storedWBSResolvedRoutes,
            actuals: dayData?.actuals ?? [],
            confirmedSleepSpans: model.settings.confirmedSleepSpans,
            sleepSessions: model.sleepSessions
        )
    }

    var storedWBSResolvedRoutes: [MapHomeWBSResolvedRoute] {
        (currentDayDataSnapshot?.travel ?? []).compactMap { segment in
            guard segment.mode == .subway,
                  segment.isConfirmed,
                  let route = segment.subwayRoute,
                  SubwayStationCatalog.isValid(route),
                  route.coordinates.count >= 2 else { return nil }
            return MapHomeWBSResolvedRoute(
                legID: "movement-\(segment.id.uuidString)",
                coordinates: route.coordinates
            )
        }
    }

    func wbsGeoPoint(
        _ coordinate: CLLocationCoordinate2D
    ) -> GeoPoint {
        GeoPoint(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            altitude: 0,
            horizontalAccuracy: -1,
            verticalAccuracy: -1
        )
    }

    func recordCurrentPlaybackAlignment() {
        if let frame = wbsPlaybackFrame, selectedPawprintPoint == nil {
            recordPlaybackRouteAlignment(frame)
        }
    }

    func recordPlaybackRouteAlignment(
        _ frame: MapHomeWBSPlaybackFrame
    ) {
        let dottedLegIDs = visibleForecastPlaybackLegIDs
        let cutoffDelta = routeOverlayCutoff.timeIntervalSince(
            displayedLocationDate
        )
        TaptionPlanDiagnosticsLogger.shared.record(
            "expected_route_playback_alignment",
            fields: [
                "frame_leg_id": frame.legID,
                "frame_phase": frame.routePhase.rawValue,
                "frame_activity": frame.activity == .movement
                    ? "movement"
                    : "stay",
                "frame_progress": String(frame.progress),
                "forecast_overlay_count": String(dottedLegIDs.count),
                "frame_matches_forecast_overlay": String(
                    dottedLegIDs.contains(frame.legID)
                ),
                "cutoff_delta_seconds": String(cutoffDelta),
                "is_playback_running": String(isDayPlaybackRunning),
            ]
        )
    }

    /// 재생 중 화랑이가 화면 가운데에서 얼마나 벗어났는지 1초에 한 번 기록한다(좌표 없이 픽셀과 유무만).
    func recordPlaybackFocusSample() {
        guard TimelineInteractionFrameGate.shouldRender(
            lastUptime: &lastPlaybackFocusLogUptime,
            nowUptime: ProcessInfo.processInfo.systemUptime,
            minimumInterval: 1
        ) else { return }
        let center = currentLocationTargetPoint
        let offset = displayedStickmanViewportPoint.map {
            hypot($0.x - center.x, $0.y - center.y)
        }
        TaptionPlanDiagnosticsLogger.shared.record(
            "playback_focus_sample",
            metrics: [
                "has_point": displayedPlaybackFocusPoint == nil ? 0 : 1,
                "has_camera": visibleMapCamera == nil ? 0 : 1,
                "stickman_offset_px": offset?.rounded() ?? -1,
                "camera_distance_m": visibleMapCamera?.distance.rounded() ?? -1,
                "speed_mps": displayedSpeedMetersPerSecond ?? -1,
            ]
        )
    }

    /// Apple 지도의 재생 중 속도 비례 줌. 가운데 맞추기는 지도 뷰가 하고, 여기서는 거리만 바꾼다.
    func advanceApplePlaybackZoom() {
        guard isDayPlaybackRunning,
              !isPlaybackIntroActive,
              TimelineInteractionFrameGate.shouldRender(
                  lastUptime: &lastPlaybackMapFocusUptime,
                  nowUptime: ProcessInfo.processInfo.systemUptime,
                  minimumInterval: MapHomeDayPlaybackMath.mapFocusInterval
              ),
              let camera = visibleMapCamera,
              let point = displayedPlaybackFocusPoint else { return }
        let next = playbackAwareDistance(current: camera.distance)
        guard abs(next - camera.distance) / camera.distance >= 0.01 else { return }
        requestAppleMapCenter(
            CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
            distance: next
        )
    }

    /// 재생 중에는 속도에 맞춘 거리를, 실시간 따라가기에서는 속도 비례 줌을, 아니면 현재 거리를 돌려준다.
    func playbackAwareDistance(current: Double) -> Double {
        guard isDayPlaybackRunning else {
            return liveFollowDistance(current: current) ?? current
        }
        guard MapHomePlaybackZoomMode(rawValue: playbackZoomModeRaw) != .fixed else {
            return current
        }
        let playbackMinute = dayPlaybackCurrentMinute ?? Double(selectedTimelineMinute ?? 0)
        let target = playbackZoomPlan.targetDistance(
            atMinute: playbackMinute,
            speedMetersPerSecond: displayedSpeedMetersPerSecond
        )
        let next = playbackZoomSmoother.next(
            current: current,
            target: target,
            uptime: ProcessInfo.processInfo.systemUptime
        )
        TaptionPlanDiagnosticsLogger.shared.record(
            "playback_zoom_sample",
            metrics: [
                "plan_scale": playbackZoomPlan.scale(atMinute: playbackMinute),
                "current_m": current.rounded(),
                "target_m": target.rounded(),
                "next_m": next.rounded(),
            ]
        )
        return next
    }

    /// 시간선 창을 진단에 남긴다(확대 단계·손잡이·「현재 위치」 확인용).
    func recordTimelineWindow(_ source: String) {
        MapHomeTimelineWindowRecord.write(
            source: source, startMinute: timeSidebarVisibleStartMinute,
            durationMinutes: timeSidebarVisibleDurationMinutes, selectedMinute: selectedTimelineMinute
        )
    }
}
