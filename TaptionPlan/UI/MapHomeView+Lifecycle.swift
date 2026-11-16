import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    /// 사슬이 길면 타입 검사가 수십 초 걸려(43초, ARC1103A01) 세 덩어리로 나눈다. 수식어 순서는 그대로다.
    func lifecycleModifiers(_ content: some View) -> some View {
        lifecycleLiveRouteModifiers(lifecycleDataModifiers(lifecycleSessionModifiers(content)))
    }

    func lifecycleSessionModifiers(_ content: some View) -> some View {
        content
        .onAppear {
            #if DEBUG || BENCH
            MapHomePerfBench.stage("map_home_appear")
            #endif
            if scenePhase == .active { restoreInitialMapZoom() }
            prepareRouteProjectionReadings()
            refreshHomeGrowth(at: .now)
        }
        .onChange(of: model.snapshotRevision) { _, _ in
            refreshHomeGrowth(at: .now)
        }
        .onChange(of: model.dayProjectionRevision) { _, _ in
            routeActualIndex = nil
        }
        // 팝업·시트가 열리는 1.2초 동안의 화면 틱을 잰다(ARC1030A07).
        .onChange(of: isDaySummaryPresented) { _, on in MapHomeInteractionMonitor.shared.begin(on ? "popup_day_summary" : "popup_day_summary_close", duration: 1.2) }
        .onChange(of: counterDetail != nil) { _, on in
            if !on { counterDetailSnapshot.clear() }
            MapHomeInteractionMonitor.shared.begin(on ? "popup_counter_detail" : "popup_counter_detail_close", duration: 1.2)
        }
        .onChange(of: isMenuOpen) { _, on in if on { MapHomeInteractionMonitor.shared.begin("popup_menu", duration: 1.2) } }
        .onChange(of: isDateWeekExpanded) { _, on in if on { MapHomeInteractionMonitor.shared.begin("popup_date_strip", duration: 1.2) } }
        .onChange(of: sectionEditSelection != nil) { _, on in if on { MapHomeInteractionMonitor.shared.begin("popup_clip_editor", duration: 1.2) } }
        .onChange(of: playbackZoomModeRaw) { _, raw in
            // 재생 중에 설정을 바꿔도 곧바로 적용한다.
            playbackDriver?.isAdaptiveZoom = MapHomePlaybackZoomMode(rawValue: raw) != .fixed
        }
        .onChange(of: model.isBootstrapped) { _, isReady in
            if isReady { refreshHomeGrowth(at: .now) }
        }
        .onChange(of: model.selectedDate) { _, _ in
            refreshHomeGrowth(at: .now)
        }
        .onDisappear {
            routeReadingsPreparationTask?.cancel()
            routeReadingsPreparationTask = nil
            routeReadingsPreparationGeneration.advance()
            lastPreparedRouteReadingsSignature = nil
            currentLocationRequestTask?.cancel()
            currentLocationRequestTask = nil
            initialLocationRequestTask?.cancel()
            initialLocationRequestTask = nil
            mapSearchTask?.cancel()
            mapSearchTask = nil
            expectedRouteRefreshTask?.cancel()
            expectedRouteRefreshTask = nil
            expectedRouteRefreshGeneration &+= 1
            liveRouteProjectionRefreshTask?.cancel()
            liveRouteProjectionRefreshTask = nil
            transitPOIRefreshTask?.cancel()
            transitPOIRefreshTask = nil
            mapSearchCompleter.clear()
            stopDayPlayback(resetProgress: true)
            headingMonitor.stop()
        }
    }

    func lifecycleDataModifiers(_ content: some View) -> some View {
        content
        .task(id: daySourceTaskKey) { await runDaySourceTask() }
        .task(id: routeReadingsTaskKey) { await runRouteReadingsTask() }
        .onChange(
            of: MapHomeRouteReadingsPreparation.latestRouteInputSignature(
                homeLatestReading
            )
        ) { _, _ in
            guard Calendar.autoupdatingCurrent.isDateInToday(
                model.selectedDate
            ) else { return }
            if refreshTransitBoardingCandidatesIfNeeded(
                at: homeLatestReading?.timestamp ?? .now
            ) {
                scheduleTransitPOIRefresh()
            }
            scheduleLiveRouteProjectionRefresh()
            scheduleExpectedRouteRefresh()
        }
        .onChange(of: currentMapLocationReading?.id) { _, _ in
            applyInitialLocationIfAvailable(using: nil)
            guard selectedTimelineMinute == nil,
                  Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate),
                  userTrackingMode.keepsCameraLocked
            else { return }
            focusDisplayedLocation(using: nil)
        }
        .onChange(of: model.settings.frequentPlaces) { _, _ in
            focusMapIfNeeded()
        }
        .onChange(of: model.snapshot.weather) { _, weather in
            cachedWeatherContexts = MapHomeWeatherDisplayCache.merged(
                cached: cachedWeatherContexts,
                incoming: weather
            )
        }
        .onChange(of: model.selectedDate) { _, _ in sidebarNote = nil }
        .onChange(of: model.settings.mapDisplayStyle) { _, _ in
            mapCameraRevision &+= 1
            persistMapDayCache()
        }
        .onChange(of: isNearHomeLand) { _, near in applyAutoLandStyle(near: near) }
        .onChange(of: timeSidebarVisibleDurationMinutes) { _, _ in recordTimelineWindow("zoom") }
        // 잠금 화면 활동 카드에 같은 연봉 글자를 보여 주기 위해 기기 설정에 적어 둔다.
        .onChange(of: salaryLive) { _, _ in
            persistSalaryForLockScreen()
        }
    }
}
