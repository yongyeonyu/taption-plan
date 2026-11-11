import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    enum Layout {
        static let horizontalInset: CGFloat = 10
        /// 상단 한 줄의 공통 높이(메모·일정 원형 버튼, 날짜 줄, 날짜 배지).
        static let dateBadgeSize: CGFloat = 40
        /// 상단 한 줄의 위 여백. 메뉴·메모·일정·날짜 배지가 모두 이 값만큼
        /// 내려온 같은 높이에 놓인다(가운데 높이 = topRowInset + dateBadgeSize/2).
        static let topRowInset: CGFloat = 12
        static let headerVisibleHeight: CGFloat = 46
        static let headerHitTarget: CGFloat = 44
        static let headerIcon: CGFloat = 19
        static let mapControlSize = MapHomeOverlayLayoutMath.controlSize
        static let mapControlIcon: CGFloat = 15
        static let mapControlSpacing = MapHomeOverlayLayoutMath.controlSpacing
        static let weatherRailWidth: CGFloat = 62
        static let timeRailTopMargin: CGFloat = 46
        static let topOverlayFallbackHeight: CGFloat = 104
        static let overlayBottomMargin = MapHomeOverlayLayoutMath.sharedBottomMargin
        static let menuMinimumWidth: CGFloat = 260
        static let menuMaximumWidth: CGFloat = 300

        static func menuWidth(for viewportWidth: CGFloat) -> CGFloat {
            min(max(viewportWidth * 0.72, menuMinimumWidth), menuMaximumWidth)
        }
    }

    var isHeadingMode: Bool {
        compassControlState == .compass
    }

    var compassRotationDegrees: Double {
        headingMonitor.rotationDegrees
            ?? MapHomeCompassControlState.iconRotationDegrees(
                for: model.latestSensorReading?.courseDegrees ?? 0
            )
    }

    /// 행동구간 편집에 들어갈 때 바로 여는 클립 편집기. 저장하면 고른 구간을
    /// 그대로 선택해 두고, 미확인 구간을 고쳤으면 그날 보상을 준다.
    func clipEditorSheet(
        for selection: MapHomeSectionEditSelection
    ) -> some View {
        MapHomeNLEClipEditor(
            model: model,
            language: language,
            date: selection.date,
            segments: selection.daySegments.isEmpty
                ? [selection.segment]
                : selection.daySegments,
            details: selection.dayDetails.isEmpty
                ? selection.details
                : selection.dayDetails,
            focusMinute: selection.segment.startMinute,
            onSaved: {
                applySectionEditSave(
                    selection.selectedSpan,
                    selection: selection
                )
            }
        )
    }

    func quickConfirmUnconfirmed(
        _ segment: MapHomeTimeRailSegment,
        as category: MapHomeSidebarMajorCategory
    ) async -> Bool {
        guard model.isBootstrapped else { return false }
        let calendar = Calendar.autoupdatingCurrent
        let selectedDay = model.selectedDate
        // 여러 개 정할 때와 같은 요청을 만든다(리뷰: 같은 구간이 길에 따라 다른 기록이 되지 않게).
        guard let request = MapHomeUnconfirmedBatch.request(for: segment, category: category, day: selectedDay, calendar: calendar)
        else { return false }
        guard await model.saveActivitySectionEdit(request) != nil else { return false }
        refreshTimeRailSegments()
        if calendar.isDate(model.selectedDate, inSameDayAs: selectedDay) {
            selectedTimelineMinute = MapHomeUnconfirmedReviewPolicy.midpointMinute(for: segment)
            isTimelineSelectionPinned = true
        }
        rewardRecentCompletedDay(selectedDay)
        return true
    }

    var foregroundContent: some View {
        ZStack(alignment: .top) {
            // 지도·사이드 레일·재생 HUD는 분을 읽는다. 분이 바뀔 때 이 조각만 다시 그리게 따로 감싼다(ARC1030A01).
            MapHomeObservingView {
                // 정지 상태 확대는 지도 화면이 떠 있는 동안만 2초마다 한 걸음(전역 타이머·지도별 중복 구독 대신, PRF1101A01).
                AnyView(map).task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        advanceStationaryZoomIfNeeded()
                    }
                }
                .onChange(of: selectedTimelineMinute) { _, _ in
                    // 선택한 분을 읽는 수식어는 부모 본문이 아니라 이 조각에 둔다(ARC1030A01).
                    if !isTimelineInteractionActive, !isDayPlaybackRunning { recordTimelineWindow("select") }
                }
            }
                .padding(.leading, mapLeadingInset)
                .animation(.easeInOut(duration: 0.22), value: mapLeadingInset)
                .background(Color.tpBackground)
                .ignoresSafeArea()
                .zIndex(MapHomeLayerPriority.map)

            if !Self.benchHidden("rails") { MapHomeObservingView { AnyView(mapSideRails) } }

            if isPlacingMapMemo {
                mapMemoPlacementOverlay
                    .zIndex(MapHomeLayerPriority.loading)
            }

            if !isScreenRecording, !Self.benchHidden("topleft") {
                coarseRegion { AnyView(topLeftControls) }
                    .zIndex(MapHomeLayerPriority.loading)
            }

            if isDayDataLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(language.text("날짜 데이터 불러오는 중", "Loading day data"))
                }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                .foregroundStyle(Color.tpInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.tpSurface.opacity(0.92), in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .allowsHitTesting(false)
                .zIndex(MapHomeLayerPriority.loading)
            }

            VStack(spacing: 0) {
                Color.clear
                    .frame(height: Layout.headerVisibleHeight + 8)
                    .allowsHitTesting(false)
                if !isScreenRecording,
                   isSearchExpanded || isMapSearchFocused || hasMapSearchResults || !mapSearchText.isEmpty
                    || (selectedSearchPin != nil && pendingLongPressCoordinate == nil) {
                    HStack(alignment: .top, spacing: 0) {
                        mapSearchBar
                    }
                    .mapHomeWideTopOverlay(viewportWidth: mapViewportSize.width)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, Layout.horizontalInset)
            .padding(.top, 2)
            .frame(maxHeight: .infinity, alignment: .top)
            .zIndex(MapHomeLayerPriority.search)

            if isMenuOpen, !isScreenRecording {
                Group { if isWideLayout { AnyView(sidebarContent).environment(\.mapHomeMenuIsCompact, MapHomeWideLayoutPolicy.menuUsesCompactRows(viewportSize: mapViewportSize, hasPermissionCard: !sensorCollectionPermissionGate.sensorCollectionReady)).mapHomeWidePanelFrame(viewportWidth: mapViewportSize.width, kind: menuPanelKind) } else { menu } }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(MapHomeLayerPriority.menu)
            }

            if !isScreenRecording {
                // 듀오 바깥 화면: 날짜 배지를 알약 바로 아래, 사이드바와 같은 세로 중심선에(DUO1111A03).
                dateBadge
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, duoStatusColumn > 0 ? MapHomeOverlayLayoutMath.sideStatusPillBottom + 6 : Layout.topRowInset)
                    .padding(.leading, Layout.horizontalInset)
                    .padding(.trailing, Layout.horizontalInset - (duoStatusColumn > 0 ? MapHomeOverlayLayoutMath.pillCenterShift(column: duoStatusColumn, trailing: Layout.horizontalInset, width: Layout.dateBadgeSize) : 0))
                    .zIndex(MapHomeLayerPriority.header)
            }

            // 가계부 창 호스트: 하단 막대·왼쪽 위 단추가 숨는 화면(녹화·메뉴·다른 배치)에서도 열리게 늘 있는 층에 둔다(리뷰).
            ledgerSheetHost.frame(width: 0, height: 0)
            // 사진 반달은 하단 메뉴 아래에 깔린다. 메뉴를 가리면 안 된다(대표 지시).
            photoArcLayer
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .zIndex(MapHomeLayerPriority.header - 0.5)

            if !isScreenRecording, !isMenuOpen || isWideLayout, layoutStyle.movesActionsToBottom {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    AnyView(bottomActionBar)
                        .mapHomeWideActionBar(viewportWidth: mapViewportSize.width)
                }
                .zIndex(MapHomeLayerPriority.header)
            }

            // 화랑이 자리 보이스오버 단추(카운터 보이기·숨기기). 화면 탭 판정은 지도 탭(`handleMapTap`)이 한다(CTR1107A01).
            if !isScreenRecording, !isMenuOpen || isWideLayout {
                MapHomeObservingView { stickmanTapTarget }
                    .zIndex(MapHomeLayerPriority.header + 1)
            }
        }
        .onChange(of: isDayPlaybackRunning) { _, isRunning in
            if !isRunning { finishRecordingPlayback() }
        }
        .task { await runBenchAutoPlayback() }
        .task { await model.runPlaceBookAuditIfRequested() }
        .task { PlanTextSuggester.removeLegacyExaoneKey() }
        .task(id: scenePhase == .active) { if scenePhase == .active { await runLaunchPrompts() } }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshTripClipboardOffer()
            Task { await checkTripRelay() }
        }
        .task { await checkTripRelay() }
        // 켜져 있는 동안 AI 비서 명령을 받는다(SYN1111A03). AI와 대화 중이면 10초, 아니면 5분.
        // 10초마다 깨어 간격만 다시 본다(네트워크 없음). 직접 새로고침하면 다음 깸에 바로 빨라진다.
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            var lastFetch = Date.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                let now = Date.now
                guard now.timeIntervalSince(lastFetch) >= AssistantCommandPolling.nextInterval(now: now) - 1 else { continue }
                lastFetch = now
                await AssistantCommandRefresh.now(language: language)
            }
        }
        .overlay(alignment: .top) { tripClipboardBanner }
        .mapHomeAssistant(self)
        .task(id: model.selectedDate) { await loadPhotoMoments(asksPermission: showsPhotosOnMap && FirstRunTutorialStore().allowsUnaskedPermissionPrompts) }
        .task(id: MapHomeDayCalendarLoader.key(day: model.selectedDate)) { await loadDayCalendarEvents() }
        .task {
            // 로딩이 너무 오래 걸리면 시간 제한 후 홈을 연다(무한 로딩 방지).
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            initialReadyForced = true
            reportInitialMapShellReadyIfNeeded(for: model.selectedDate)
        }
        .onAppear {
            TaptionSeasonStore.select(model.selectedDate)
            refreshTimedMemoCache()
            applyPendingMapHomeRoute()
        }
        .onChange(of: model.pendingMapHomeRoute) { _, _ in
            applyPendingMapHomeRoute()
        }
        .onChange(of: model.selectedDate) { _, date in
            TaptionSeasonStore.select(date)
            refreshTimedMemoCache()
            // 날짜가 바뀌면 이전 날짜 일정을 즉시 내린다. 다시 불러오는 동안 옛 목록이
            // 좌측 상단·사이드바에 남아 있으면 날짜를 바꿔도 그대로인 것처럼 보인다.
            dayCalendarEvents = []
            dayCalendarEventsDate = nil
        }
        .onChange(of: model.snapshot.memos) { _, _ in refreshTimedMemoCache() }
        .onChange(of: showsPhotosOnMap) { _, _ in Task { await loadPhotoMoments(asksPermission: true) } }
        // 하루 데이터가 늦게 들어오면 위치 없는 사진의 추정 위치도 다시 맞춘다.
        .onChange(of: isDayDataLoading) { _, loading in
            if !loading, photosNeedReadingRetry { Task { await loadPhotoMoments(asksPermission: false) } }
        }
        .sheet(isPresented: $isRecordingOptionsPresented) {
            MapHomeRecordingOptionsSheet(
                layers: Binding(
                    get: { recordingLayers },
                    set: { recordingLayersRaw = $0.rawValue }
                ),
                language: language,
                onStart: startRecordingPlayback,
                canPreviewMusic: !model.isRecordingVoiceMemo,
                onRenderVideo: {
                    isRecordingOptionsPresented = false
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        isPlaybackVideoPresented = true
                    }
                },
                adaptiveZoom: Binding(
                    get: { (MapHomePlaybackZoomMode(rawValue: playbackZoomModeRaw) ?? .adaptive) == .adaptive },
                    set: { playbackZoomModeRaw = ($0 ? MapHomePlaybackZoomMode.adaptive : .fixed).rawValue }
                ),
                mapStyleTitle: mapStyleTitle(model.settings.mapDisplayStyle),
                mapStyles: (MapDisplayStyle.openFreeMapStyles + MapDisplayStyle.appleStyles).map { style in
                    MapHomeRecordingMapStyleChoice(
                        id: style.rawValue, title: mapStyleTitle(style), systemImage: mapStyleSystemImage(style),
                        select: { model.setMapDisplayStyle(style) }
                    )
                }
            )
            .presentationDetents([.height(640), .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.tpBackground)
        }
        .sheet(isPresented: $isPlaybackVideoPresented) {
            MapHomePlaybackVideoSheet(model: model, language: language, selectedDate: model.selectedDate, accessoryID: homeGrowthHistory.season.equippedAccessory, makeRenderer: makePlaybackVideoRenderer)
                .presentationDetents([.height(520), .large])
                .presentationDragIndicator(.visible)
        }
        .alert(
            language.text("화면 녹화", "Screen recording"),
            isPresented: Binding(
                get: { recordingFailureMessage != nil },
                set: { if !$0 { recordingFailureMessage = nil } }
            )
        ) {
            Button(language.text("확인", "OK"), role: .cancel) { recordingFailureMessage = nil }
        } message: {
            Text(recordingFailureMessage ?? "")
        }
        // 공유 시트는 파일 주소가 정해진 뒤에만 연다(주소 없이 열리면 빈 화면이 나온다).
        .sheet(item: $recordedVideoShare) { url in
            MapHomeShareSheet(url: url)
                .presentationDetents([.medium, .large])
        }
    }

    /// `body`의 수정자 체인이 길면 타입 검사가 느려져(CI에서 시간 초과) 세 덩어리로 나눈다.
    var baseContent: some View {
        Group {
            if scenePhase == .background {
                Color.tpSurface.ignoresSafeArea()
            } else {
                foregroundContent
            }
        }
        .coordinateSpace(name: "mapHomeViewport")
        // 말풍선 탭 판정을 위해 지도 화면의 창 기준 원점을 알려 둔다(BBL1111A02).
        .background {
            MapHomeWindowFrameProbe(frame: Binding(get: { nil }, set: { MapHomeCatBubbleState.shared.viewportOrigin = $0?.origin ?? .zero }))
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onGeometryChange(
            for: CGSize.self,
            of: { $0.size },
            action: { size in
                let integralSize = CGSize(
                    width: size.width.rounded(),
                    height: size.height.rounded()
                )
                Task { @MainActor in
                    await Task.yield()
                    guard mapViewportSize != integralSize else { return }
                    mapViewportSize = integralSize
                }
            }
        )
        .preferredColorScheme(TaptionUITheme.current.colorScheme)
    }

    func presentationModifiers(_ content: some View) -> some View {
        content
        .sheet(item: $selectedMarkerInfo) { info in
            MapHomeMarkerInfoSheet(kind: info, language: language, model: model, placeID: selectedMarkerPlaceID)
                .presentationDetents([.height(320), .medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $counterDetail) { focus in
            let snapshot = counterDetailSnapshot.value(for: focus) {
                // 창에 보이는 카운터를 탭으로 늘어놓고, 누른 줄의 탭을 먼저 고른다.
                let targets = counterRowTargets.contains(focus) ? counterRowTargets : [focus]
                return MapHomeCounterDetailSnapshot.Value(
                    contents: targets.map { counterDetailContent(for: $0) },
                    initialIndex: targets.firstIndex(of: focus) ?? 0,
                    dateText: model.selectedDate.formatted(
                        Date.FormatStyle().month(.wide).day().weekday(.wide)
                            .locale(language.locale)
                    )
                )
            }
            MapHomeCounterDetailSheet(
                contents: snapshot.contents,
                initialIndex: snapshot.initialIndex,
                dateText: snapshot.dateText
            )
        }
        .mapHomeWidePanel(isPresented: $isDaySummaryPresented, viewportWidth: mapViewportSize.width, language: language) {
            MapHomeDaySummarySheet(
                date: model.selectedDate,
                categories: daySummaryCategories,
                stepCount: dayStepCount,
                travelDistances: MapHomeDayTravelSummary.entries(
                    from: currentDayDataSnapshot?.travel ?? []
                ),
                growthData: $homeGrowthData,
                language: language,
                growthCard: MapHomeGrowthCardInfo(
                    level: MapHomeGrowthPolicy.dailyLevel(for: model.selectedDate),
                    status: homeGrowthMarkerStatus,
                    isQualifiedToday: isHomeGrowthQualifiedToday,
                    streak: homeGrowthHistory.season.streak,
                    pendingWeeklyRewards: homeGrowthHistory.season.pendingWeeklyRewards
                ),
                homeArtwork: AnyView(daySummaryHomeArtwork),
                salary: salaryLive,
                memoCounts: dayMemoCounts,
                model: model,
                homePlaceID: model.settings.frequentPlaces.first { $0.kind == .home }?.id,
                detent: $daySummaryDetent
            )
            .presentationDragIndicator(.visible)
        }
        // 시트가 올라오고 내려갈 때마다 집을 가려지지 않은 지도 영역 가운데로 다시 맞춘다.
        .onChange(of: isDaySummaryPresented) { _, presented in
            if !presented {
                daySummaryFocusesCat = false
                // 다음에 열 때는 다시 접힌 높이에서 시작한다.
                daySummaryDetent = MapHomeDaySummarySheet.collapsedDetent
            }
            applyDaySummaryCameraCoverage()
        }
        .onChange(of: daySummaryDetent) { _, _ in
            applyDaySummaryCameraCoverage()
        }
        .sheet(isPresented: $isCarAudioSheetPresented, onDismiss: {
            // 등록을 바꾸면 오늘 이동을 다시 판정한다.
            Task { _ = await model.refreshSensorTimeline() }
        }) {
            MapHomeCarAudioSheet(model: model, language: language)
        }
        .sheet(isPresented: $isShortcutsGuidePresented) { BokkiShortcutsGuide(language: language) }
        .sheet(isPresented: $isSalarySettingsPresented) {
            MapHomeSalarySettingsSheet(
                language: language,
                monthWorkSeconds: salaryLive?.month?.workSeconds ?? 0,
                projectedMonthWorkSeconds: salaryLive?.projectedMonthWorkSeconds ?? 0,
                pastMonthWorkSeconds: salaryLive?.pastMonthWorkSeconds ?? [:]
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // 연봉을 넣었으면 30초마다 오늘 근무 시간을 다시 센다(사이 값은 지도 라벨이 표시 간격마다 더한다).
        // 기록을 다 불러오기 전(앱 시작 직후)에 센 0을 붙들지 않게, 기록 개수가 바뀌면 처음부터 다시 센다.
        .task(id: salaryTaskID) {
            guard scenePhase == .active else { return }
            var monthComputedAt: Date?
            while !Task.isCancelled {
                let needsMonth = monthComputedAt.map { Date.now.timeIntervalSince($0) >= 300 } ?? true
                await refreshSalary(includeMonth: needsMonth)
                if needsMonth { monthComputedAt = .now }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .alert(
            language.text("집이 등록돼 있지 않아요", "No home place yet"),
            isPresented: $isHomeMissingAlertPresented
        ) {
            Button(language.text("나중에", "Not now"), role: .cancel) {}
            Button(language.text("위치 설정 열기", "Open location settings")) { openLocationSettings() }
        } message: {
            Text(language.text("메뉴 > 위치에서 집을 먼저 등록해 주세요.", "Add your home in Menu > Location first."))
        }
        .onSiriScreenRequest { openSiriScreen() }
        .mapHomeLaunchPrompts($launchPrompt, model: model, language: language, onResume: {
            launchPromptsAsked = []
            Task { await runLaunchPrompts() }
        }) {
            focusedUnconfirmedReviewSegment = nil
            isUnconfirmedReviewPresented = true
        }
        .sheet(isPresented: $isStrideCalibrationPresented) {
            MapHomeStrideCalibrationSheet(language: language)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .mapHomeWidePanel(isPresented: $isCalendarPresented, kind: .calendar, title: language.text("달력", "Calendar"), viewportWidth: mapViewportSize.width, language: language) {
            MapHomeCalendarSheet(
                selectedDate: $model.selectedDate,
                starredDays: travelPlanDays,
                minimumDay: travelModeMinimumDay,
                holidayName: { date in
                    TimelineAxisGrid.koreanHolidayName(on: date)
                },
                logStatuses: { month in
                    let actuals = model.snapshot.actuals
                    let travel = model.snapshot.travel
                    let base = await Task.detached(priority: .userInitiated) {
                        MapHomeCalendarLogStatusPolicy.statuses(
                            actuals: actuals,
                            travel: travel,
                            month: month,
                            asOf: .now,
                            calendar: MapHomeGrowthPolicy.localCalendar
                        )
                    }.value
                    return await calendarLogStatusesFillingGaps(base, month: month)
                },
                timeTotals: { month in await calendarTimeTotals(month: month, includePhotos: true) },
                liveTotals: { month in await calendarTimeTotals(month: month, includePhotos: false) },
                placeVisits: { day in
                    let stays = model.snapshot.places
                    let names = Dictionary(
                        model.settings.frequentPlaces.map { ($0.stablePlaceKey, $0.displayName) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    let symbols = Dictionary(
                        model.settings.frequentPlaces.map { ($0.stablePlaceKey, $0.kind.systemImage) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    guard let dayEnd = MapHomeGrowthPolicy.localCalendar.date(byAdding: .day, value: 1, to: day) else { return [] }
                    return await Task.detached(priority: .userInitiated) {
                        MapHomeCalendarPlaceVisitPolicy.visits(
                            stays: stays, day: day, dayEnd: dayEnd, registeredNames: names, registeredSymbols: symbols
                        )
                    }.value
                },
                timeTint: { categoryID in
                    MapHomeSidebarMajorCategory.presentation(
                        for: categoryID,
                        categoryColors: model.settings.mapCategoryColors
                    ).tint
                },
                language: language,
                // 달력 빠른 갱신은 15초 단위로만 다시 계산한다(달 전체 재계산 부담을 줄임).
                liveToken: ((model.latestSensorReading?.timestamp.timeIntervalSince1970 ?? 0) / 15).rounded(.down)
            )
        }
        .sheet(item: $selectedLocationDestination) { destination in
            locationDestinationSheet(for: destination)
        }
        .sheet(isPresented: $isTransitLocationsPresented) {
            MapHomeTransitLocationsSheet(
                model: model,
                language: language,
                initialCenter: currentCoordinate ?? visibleMapCenter,
                initialSpan: visibleMapSpan
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedUserLocation) { selection in
            userLocationSheet(for: selection)
        }
        .sheet(item: $selectedMapStickerEditor) { target in
            MapHomeStickerEditorSheet(
                model: model,
                target: target,
                language: language,
                onRequestLocation: { id in beginMemoLocationPick(id) }
            )
        }
        .sheet(item: $selectedTransitBoardingCandidate) { candidate in
            MapHomeTransitBoardingCandidateSheet(
                model: model,
                candidate: candidate,
                language: language
            )
            .presentationDetents([.height(270)])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedPredictedRoute) { route in
            MapHomePredictedRouteMenu(model: model, route: route, language: language)
                .presentationDetents([.height(230)])
                .presentationDragIndicator(.visible)
        }
        .sheet(
            isPresented: $isSearchPinMenuPresented,
            onDismiss: {
                if let selection = pendingUserLocationSelection {
                    pendingUserLocationSelection = nil
                    selectedUserLocation = selection
                } else {
                    selectedSearchPin = nil
                }
            }
        ) {
            searchPinSheet
        }
        .onReceive(NotificationCenter.default.publisher(for: .taptionPlanAlarmTapped)) { note in
            guard let raw = note.userInfo?["kind"] as? String, let kind = MapHomeAlarmKind(rawValue: raw) else { return }
            if kind == .dailyCard {
                openDailyCardFromAlarm(fireDate: note.userInfo?["fire"] as? Date ?? .now)
                return
            }
            // 시간은 지금으로 채운다(알람을 보낸 시각이 아니라, 실제로 확인하는 시각).
            pendingAlarm = (kind, .now)
        }
        .sheet(item: alarmConfirmBinding) { item in
            MapHomeAlarmConfirmSheet(
                kind: item.kind,
                initialDate: item.at,
                language: language,
                onConfirm: { date in
                    if let entry = MapHomeAlarmRecordMapping.entry(for: item.kind, language: language) {
                        model.confirmAlarmRecord(categoryID: entry.categoryID, title: entry.title, at: date, opens: entry.opens)
                    }
                    pendingAlarm = nil
                },
                onCancel: { pendingAlarm = nil }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isAlarmSettingsPresented) {
            MapHomeAlarmSettingsSheet(language: language) { model.scheduleNearbyMemoSync() }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .mapHomeWidePanel(isPresented: $isDailyCardPresented, title: language.text("하루 카드", "Day card"), viewportWidth: mapViewportSize.width, language: language) {
            MapHomeDailyCardSheet(
                initialDay: model.selectedDate,
                language: language,
                makeContent: { await dailyCardContent(for: $0) }
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // 알림 판정: 기록이 바뀔 때마다(장소 머묾·수면·시급) 켜 둔 알림만 보낸다. 하루 카드 예약도 맞춘다.
        .task(id: "\(model.snapshot.places.count)|\(model.snapshot.actuals.count)|\(salaryLive?.hourlyRate ?? 0)") {
            await MapHomeAlarmCenter.shared.syncDailyCardSchedule(language: language)
            let snap = model.snapshot
            let readings = await model.readingsForAlarmCheck(on: .now)
            await MapHomeAlarmCenter.shared.evaluate(
                actuals: snap.actuals,
                travel: snap.travel,
                stays: snap.places,
                frequentPlaces: snap.settings.frequentPlaces,
                readings: readings,
                language: language
            )
            if let salaryLive {
                await MapHomeAlarmCenter.shared.noteRate(
                    salaryLive.hourlyRate,
                    isWorking: salaryLive.isWorking,
                    breakEvenHours: salaryLive.isWorking ? MapHomeAlarmPolicy.breakEvenHours(
                        settings: MapHomeSalaryPolicy.loadSettings(),
                        monthWorkSeconds: salaryLive.month?.workSeconds ?? 0,
                        projectedMonthWorkSeconds: salaryLive.projectedMonthWorkSeconds,
                        samples: []
                    ) : nil,
                    language: language
                )
            }
        }
        .onChange(of: model.selectedDate) { keepSelectedDateInFuture() }
        .sheet(isPresented: $isTravelPlanPresented) {
            MapHomeTripPlanSheet(model: model, language: language, initialDay: model.selectedDate) { pin in
                isTravelPlanPresented = false
                showPlaceBookEntryOnMap(pin)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $isPlaceBookPresented) {
            MapHomePlaceBookSheet(
                source: model.placeBookVisitSource,
                language: language,
                currentCoordinate: currentCoordinate,
                onSelect: showPlaceBookEntryOnMap
            )
        }
        .fullScreenCover(isPresented: $isPassportPresented) {
            MapHomePassportSheet(
                source: model.placeBookVisitSource,
                language: language,
                initialPage: passportStartPage,
                onSelectDay: { day, page in
                    isPassportPresented = false
                    isMenuOpen = false
                    passportReturnPage = page
                    // 여권은 다녀온 기록이라 여행 모드(미래만 고름)를 끄고 그날로 간다.
                    if isTravelMode { isTravelMode = false }
                    model.selectedDate = day
                }
            )
        }
        .sheet(isPresented: $isMapAttributionPresented) {
            MapHomeAttributionSheet(language: language)
                .presentationDetents([.height(360), .large])
                .presentationDragIndicator(.visible)
        }
        // + 버튼은 바로 메모 편집 화면을 연다. 시간·위치·스티커는 그 화면에서 고른다.
        .confirmationDialog(
            language.text("지도에 메모 추가", "Add map memo"),
            isPresented: $isLongPressMenuPresented,
            titleVisibility: .visible
        ) {
            Button(language.text("추가", "Add")) { routeLongPress(.memo) }
            Button(language.text("취소", "Cancel"), role: .cancel) {
                pendingLongPressCoordinate = nil
                selectedSearchPin = nil
            }
        }
        .overlay {
            if isDayPlaybackRunning, recordingShows(\.mapMemos), let minute = dayPlaybackCurrentMinute {
                MapHomePlaybackMomentsOverlay(minute: minute, events: playbackMomentEvents, topInset: Layout.topRowInset + Layout.dateBadgeSize + 8, trailingInset: isSidebarVisible ? timeRailWidth + 12 : 12)
            }
        }
        .onChange(of: model.selectedDate) { _, _ in photoBrowserSelection = nil }
        .alert(language.text("위치를 '항상 허용'으로 바꿔 주세요", "Set location to Always"), isPresented: $isLocationAlwaysPromptPresented) {
            Button(language.text("설정 열기", "Open Settings")) { LocationAlwaysPrompt.settingsURL.map { UIApplication.shared.open($0) } }
            Button(language.text("나중에", "Later"), role: .cancel) {}
        } message: {
            Text(LocationAlwaysPrompt.message(language))
        }
        .confirmationDialog(language.text("여행 계획 추가", "Add to trip"), isPresented: $isTravelAddChoicePresented, titleVisibility: .visible) {
            Button(language.text("직접 입력", "Enter manually")) { isTravelPlanPresented = true }
            Button(language.text("AI로 만들기", "Plan with AI")) { isTripImportPresented = true }
        }
        .sheet(isPresented: $isTripImportPresented) {
            MapHomeTripImportSheet(model: model, language: language, initialText: pastedTripText) { day in model.selectedDate = day }
                .onDisappear { pastedTripText = nil }
                .presentationDetents([.large])
        }
        .sheet(isPresented: $isCalendarConnectPresented) { MapHomeCalendarConnectSheet(model: model, language: language) }
        .sheet(isPresented: $isDataProtectionPresented) {
            MapHomeSecuritySheet(model: model, language: language)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isCategoryAddPresented) {
            MapHomeCategoryAddSheet(model: model, language: language)
                .presentationDetents([.height(320)])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $editingUserCategory) { category in
            MapHomeCategoryAddSheet(model: model, language: language, editing: category)
                .presentationDetents([.height(380)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $proAccess.isPurchaseSheetPresented) {
            TaptionProAccessView(
                controller: proAccess,
                allowsDismiss: true
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(
            isPresented: $isUnconfirmedReviewPresented,
            onDismiss: {
                focusedUnconfirmedReviewSegment = nil
                guard let minute = pendingUnconfirmedEditMinute else { return }
                pendingUnconfirmedEditMinute = nil
                Task { @MainActor in
                    await Task.yield()
                    openSectionEditor(at: minute)
                }
            }
        ) {
            MapHomeUnconfirmedReviewSheet(
                date: model.selectedDate,
                segments: timeRailSegments,
                focusedSegment: focusedUnconfirmedReviewSegment,
                recentDates: focusedUnconfirmedReviewSegment == nil
                    ? MapHomeUnconfirmedReviewPolicy.recentDates()
                    : [],
                language: language,
                onDateSelect: { day in
                    guard !Calendar.autoupdatingCurrent.isDate(day, inSameDayAs: model.selectedDate) else { return }
                    model.selectedDate = day
                    refreshTimeRailSegments()
                },
                onSelect: { segment in
                    pendingUnconfirmedEditMinute = MapHomeUnconfirmedReviewPolicy
                        .midpointMinute(for: segment)
                    isUnconfirmedReviewPresented = false
                },
                onQuickConfirm: { segment, category in
                    await quickConfirmUnconfirmed(segment, as: category)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            language.text("설정을 기본값으로 초기화할까요?", "Reset settings to defaults?"),
            isPresented: $isSettingsResetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(language.text("설정 초기화", "Reset settings"), role: .destructive) {
                isMenuOpen = false
                Task { await model.resetSettingsToDefaults() }
            }
            Button(language.text("취소", "Cancel"), role: .cancel) {}
        } message: {
            Text(language.text("계획과 기록은 삭제되지 않습니다.", "Your plans and records will not be deleted."))
        }
        .fullScreenCover(
            item: $sectionEditSelection,
            onDismiss: {
                sectionEditSelection = nil
                refreshTimeRailSegments()
            }
        ) { selection in
            // 행동구간 편집에 들어가면 클립 편집기를 바로 연다. 기존 행동구간
            // 편집 화면은 아래 한 줄을 되살리면 그대로 돌아온다.
            // sectionEditSheet(for: selection)
            clipEditorSheet(for: selection)
        }
        .animation(.easeInOut(duration: 0.22), value: isMenuOpen)
        .mapHomeWidePanelsExclusive(viewportWidth: mapViewportSize.width, [$isMenuOpen, $isCalendarPresented, $isDaySummaryPresented, $isDailyCardPresented, $isSearchExpanded, $todayCalendarExpanded])
        .onChange(of: isMenuOpen) { _, isOpen in
            guard isOpen else { return TaptionFont.applyPending() }
            Task { @MainActor in await model.refreshPermissions() }
        }
    }

    /// 사슬이 길면 타입 검사가 수십 초 걸려(43초, ARC1103A01) 세 덩어리로 나눈다. 수식어 순서는 그대로다.
    func lifecycleModifiers(_ content: some View) -> some View {
        lifecycleLiveRouteModifiers(lifecycleDataModifiers(lifecycleSessionModifiers(content)))
    }

    func lifecycleSessionModifiers(_ content: some View) -> some View {
        content
        .onAppear {
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
                model.latestSensorReading
            )
        ) { _, _ in
            guard Calendar.autoupdatingCurrent.isDateInToday(
                model.selectedDate
            ) else { return }
            if refreshTransitBoardingCandidatesIfNeeded(
                at: model.latestSensorReading?.timestamp ?? .now
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

    /// 내용이 비어 있는 메모(취소된 빈 초안 등)는 화면에 올리지 않는다.
    static func hasText(_ memo: ActionMemo) -> Bool {
        !memo.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 왼쪽 상단: 메모 원형 버튼과 구글 일정 버튼. 일정을 누르면 오늘 일정 목록이 펼쳐진다.
    /// 메뉴 단추는 하단 맨 왼쪽으로 내렸다(대표 요청, 2026-10-26).
    var topLeftControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 날짜 줄이 이 자리를 덮을 때만(아이폰 폭) 숨긴다.
            if !isDateWeekExpanded || !MapHomeWideLayoutPolicy.dateStripOverlapsTopLeftControls(viewportWidth: mapViewportSize.width) {
                HStack(spacing: 8) {
                    if passportReturnPage != nil { passportBackButton }
                    searchCircleButton
                    modeButtons
                    if recordingShows(\.sidebarMemos), memoDisplayMode == .all {
                        memoCircleButton
                    }
                    MapHomeCalendarButton(isExpanded: todayCalendarExpanded, count: dayCalendarEventsForSelectedDate.count) {
                        switch calendarAccessProblem {
                        case .googleFailed:
                            model.selectTab(.settings)
                        case .permissionDenied:
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        case nil:
                            withAnimation(.snappy) { todayCalendarExpanded.toggle() }
                        }
                    }
                }
            }
            // 현재 시간 ±15분 안의 메모·일정은 목록을 펼치지 않아도 왼쪽 상단에 보인다.
            // 목록을 펼쳤으면 같은 메모가 그 안에 있으므로 숨긴다.
            if !memoStackExpanded, !nearbyPreviewRows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(nearbyPreviewRows, id: \.id) { row in
                        HStack(spacing: 6) {
                            Image(systemName: row.systemImage)
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                                .foregroundStyle(Color.tpReferenceBlue)
                            Text(row.title)
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                                .foregroundStyle(Color.tpInk)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(row.time)
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                                .foregroundStyle(Color.tpSecondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let id = row.memoID {
                                selectedMapStickerEditor = .memo(id)
                            } else {
                                withAnimation(.snappy) { todayCalendarExpanded = true }
                            }
                        }
                        .accessibilityAddTraits(.isButton)
                    }
                }
                .padding(10)
                .frame(width: 280, alignment: .leading)
                .mapHomeGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            // 먼저 연 패널이 위에 오고, 나중에 연 패널은 그 아래에 붙는다. 폭은 같다.
            ForEach(topPanelOrder, id: \.self) { panel in
                switch panel {
                case .memo:
                    if memoStackExpanded, recordingShows(\.sidebarMemos), memoDisplayMode == .all {
                        memoListPanel
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                case .calendar:
                    if todayCalendarExpanded {
                        MapHomeTodayCalendarList(
                            language: language,
                            service: calendarService,
                            date: model.selectedDate,
                            titleDetails: model.snapshot.settings.calendarTitleDetails,
                            onChooseDetail: { title, choice in
                                Task {
                                    switch choice {
                                    case .automatic: await model.clearCalendarTitleDetail(title: title, on: model.selectedDate)
                                    case .none: await model.setCalendarTitleDetail(nil, title: title, on: model.selectedDate)
                                    case .detail(let id): await model.setCalendarTitleDetail(id, title: title, on: model.selectedDate)
                                    }
                                }
                            }
                        )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, Layout.horizontalInset)
        // 듀오 바깥 화면은 단추 윗줄을 상태 줄 알약 위쪽에 맞춘다(DUO1111A03).
        .padding(.top, duoStatusColumn > 0 ? MapHomeOverlayLayoutMath.sideStatusPillTop : Layout.topRowInset)
        .onChange(of: memoStackExpanded) { _, open in setTopPanel(.memo, open: open) }
        .onChange(of: todayCalendarExpanded) { _, open in setTopPanel(.calendar, open: open) }
    }

    enum TopPanel: Hashable { case memo, calendar }

    func setTopPanel(_ panel: TopPanel, open: Bool) {
        topPanelOrder.removeAll { $0 == panel }
        if open { topPanelOrder.append(panel) }
    }

    struct NearbyPreviewRow: Identifiable {
        let id: String
        let systemImage: String
        let title: String
        let time: String
        /// 메모면 그 메모를 열고, 일정이면 오늘 일정 목록을 연다.
        var memoID: UUID? = nil
    }

    /// 현재 시간 ±15분 안의 메모와 일정 목록(왼쪽 상단 미리보기).
    var nearbyPreviewRows: [NearbyPreviewRow] {
        let center = timelineSelectionDate
        let window: TimeInterval = 15 * 60
        var rows: [NearbyPreviewRow] = []
        if let memo = nearbyTimedMemo {
            rows.append(NearbyPreviewRow(
                id: "memo-\(memo.id.uuidString)",
                systemImage: "note.text",
                title: memo.text,
                time: memo.occurredAt.formatted(date: .omitted, time: .shortened),
                memoID: memo.id
            ))
        }
        for event in dayCalendarEventsForSelectedDate where !event.isAllDay
            && abs(event.span.start.timeIntervalSince(center)) <= window {
            rows.append(NearbyPreviewRow(
                id: "event-\(event.id)",
                systemImage: "calendar",
                title: event.title,
                time: event.span.start.formatted(date: .omitted, time: .shortened)
            ))
        }
        return rows
    }

    func runDaySourceTask() async {
        guard model.isBootstrapped, scenePhase == .active else { return }
        let date = model.selectedDate
        guard let prepared = await model.planDaySourceSnapshot(for: date, reusing: dayDataSnapshot),
              !Task.isCancelled, prepared.sourceRevision == model.dayProjectionRevision,
              Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: model.selectedDate) else { return }
        if currentDayDataSnapshot == nil
            || (prepared.isComplete && prepared.sourceRevision != dayDataSnapshot?.sourceRevision) {
            dayDataSnapshot = prepared
            dayDataIsPreview = !prepared.isComplete
            reportInitialMapShellReadyIfNeeded(for: model.selectedDate)
        }
        routeActualIndex = nil
        refreshHomeGrowth(at: .now)
        refreshTimeRailSegments()
        requestRouteProjectionRefresh(preparingReadings: true)
        requestWBSPlaybackProjectionRefresh()
        scheduleExpectedRouteRefresh()
            }

    /// `body`의 수정자 체인이 길어 타입 검사가 느려지지 않도록 `.task`의 id를 따로 계산한다.
    var daySourceTaskKey: MapHomeDaySourceTaskKey {
        MapHomeDaySourceTaskKey(
            day: Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate),
            revision: model.dayProjectionRevision,
            isReady: model.isBootstrapped,
            isActive: scenePhase == .active
        )
    }

    /// 벡터 지도 `MapHomeFogLayer`와 같은 걷어낼 지점(발자국·장소 72pt, 현재 위치 96pt).
    var appleFogReveals: [MapHomeFogReveal]? {
        guard fogStrength != .off else { return nil }
        let radius = MapHomeFogStrength.revealRadius
        var reveals = playbackVisibleWaypoints(pawprintWaypoints).map { MapHomeFogReveal(coordinate: $0.coordinate, radius: radius) }
        reveals += placeAnnotations.map { MapHomeFogReveal(coordinate: $0.coordinate, radius: radius) }
        if let displayed = displayedLocationCoordinate {
            reveals.append(MapHomeFogReveal(coordinate: displayed, radius: MapHomeFogStrength.currentLocationRadius))
        }
        return reveals
    }

    func visibleForecastCoordinates(
        for leg: MapHomeWBSPlaybackLeg,
        through cutoff: Date
    ) -> [CLLocationCoordinate2D]? {
        guard cutoff > leg.startDate,
              leg.coordinates.count >= 2 else { return nil }
        let coordinates = leg.coordinates.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard cutoff < leg.endDate else { return coordinates }
        let duration = leg.endDate.timeIntervalSince(leg.startDate)
        guard duration > 0 else { return coordinates }
        let fraction = min(
            max(cutoff.timeIntervalSince(leg.startDate) / duration, 0),
            1
        )
        return MapHomeExpectedRouteOverlay.prefixByDistance(
            coordinates,
            fraction: fraction,
            segmentLengths: leg.segmentLengths
        )
    }

    var vectorPlayerHeading: CLLocationDirection {
        appleMapPlayback?.headingDegrees ?? 0
    }

    func coordinates(for route: MapPredictedRoute, through cutoff: Date? = nil) -> [CLLocationCoordinate2D] {
        let points = route.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        guard let cutoff else { return points }
        let fraction = min(1, max(0, cutoff.timeIntervalSince(route.span.start) / route.span.duration))
        guard fraction > 0 else { return [] }
        return MapHomeExpectedRouteOverlay.prefixByDistanceResult(points, fraction: fraction,
            segmentLengths: MapHomeExpectedRoutePlaybackMath.segmentLengths(for: points)).coordinates
    }

    func pawprintTarget(
        at point: CGPoint,
        waypoints: [PawprintWaypoint],
        positions: [String: CGPoint]? = nil
    ) -> PawprintWaypoint? {
        guard let positions = positions ?? vectorMapViewportStore.viewport?.markerPoints else { return nil }
        let targets = waypoints.compactMap { waypoint -> MapHomePawprintTapTarget? in
            guard let position = positions[vectorPawprintMarkerID(waypoint.index)]
            else { return nil }
            return MapHomePawprintTapTarget(
                id: waypoint.index, point: position,
                timestamp: waypoint.timestamp, isPredicted: waypoint.isPredicted,
                routeID: waypoint.predictedRoute?.id,
                routeSpan: waypoint.predictedRoute?.span
            )
        }
        guard let id = MapHomePawprintInteractionPolicy.nearestTarget(
            to: point, targets: targets, selectedDate: model.selectedDate
        ) else { return nil }
        return waypoints.first { $0.index == id }
    }

    func selectPawprint(_ waypoint: PawprintWaypoint) {
        if let route = waypoint.predictedRoute {
            stopDayPlayback(resetProgress: false)
            recordUserMapAdjustment()
            currentLocationRequestTask?.cancel()
            currentLocationRequestTask = nil
            setUserTrackingMode(.idle)
            selectedPredictedRoute = route
            dismissMapSearchOverlay()
            return
        }
        guard let selection = MapHomePawprintInteractionPolicy.selection(
            timestamp: waypoint.timestamp, isPredicted: waypoint.isPredicted,
            selectedDate: model.selectedDate
        ) else { return }
        stopDayPlayback(resetProgress: true)
        isTimelineInteractionActive = false
        recordUserMapAdjustment()
        currentLocationRequestTask?.cancel()
        currentLocationRequestTask = nil
        setUserTrackingMode(.idle)
        isTimelineSelectionPinned = true
        selectedTimelineMinute = selection.minute
        selectedPawprintTimestamp = selection.timestamp
        highlightedPawprintTimestamp = waypoint.timestamp
        selectedPawprintCoordinate = waypoint.coordinate
        _ = refreshRouteProjection()
        recordCurrentPlaybackAlignment()
        focusMap(on: wbsGeoPoint(waypoint.coordinate), using: nil, followsTracking: true)
        dismissMapSearchOverlay()
    }
}
