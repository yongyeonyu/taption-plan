import CoreLocation
import MapKit
import Observation
import OSLog
import SeasonPackKit
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
                for: homeLatestReading?.courseDegrees ?? 0
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
                // 할 일 목록이 열려 있으면 목록 밖을 눌러 닫는다(TDC1114A01).
                if memoStackExpanded, !isMenuOpen {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.snappy) { memoStackExpanded = false } }
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                        .zIndex(MapHomeLayerPriority.loading)
                }
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

            if showsStatusBandLayer { AnyView(statusBandLayer).zIndex(MapHomeLayerPriority.header - 0.25) }

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
            Task { await AnnouncementService.shared.refresh() }
            Task { await SeasonPackAdapter.refresh() }
            Task { await FlightShareIntake.drain(into: model) }
        }
        .task { await checkTripRelay() }
        .task { await AnnouncementService.shared.refresh() }
        .task { SeasonPackAdapter.sync(model: model); await SeasonPackAdapter.refresh() }
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
        .overlay(alignment: .top) { ArrivalCardHost(model: model, language: language) { homeTopNotices } }
        .overlay { SeasonPackOverlay() }
        .simultaneousGesture(TapGesture().onEnded { SeasonPackCenter.shared.noteUserTouch() }, including: SeasonPackCenter.shared.stage.flight == nil ? .subviews : .all) // 산타가 날 때만 어디를 눌러도 그 회차를 멈춘다(그 밖에는 지도 제스처에 아무 영향 없음)
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

    /// 내용이 비어 있는 메모(취소된 빈 초안 등)는 화면에 올리지 않는다.
    static func hasText(_ memo: ActionMemo) -> Bool {
        !memo.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 왼쪽 상단: 돋보기·할 일 목록·집. 할 일 목록을 누르면 확인할 것·일정·메모·지출·AI를 모은 패널이 펼쳐진다(TDP1113A01).
    /// 메뉴 단추는 하단 맨 왼쪽으로 내렸다(대표 요청, 2026-10-26).
    var topLeftControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 날짜 줄이 이 자리를 덮을 때만(아이폰 폭) 숨긴다.
            if !isDateWeekExpanded || !MapHomeWideLayoutPolicy.dateStripOverlapsTopLeftControls(viewportWidth: mapViewportSize.width) {
                // 할 일 목록 판이 늘 맨 위에 있고 단추는 그 오른쪽에 세로로 선다(TDW1114A01). 첫 탭 「오늘」은 지출 한 줄만.
                HStack(alignment: .top, spacing: 8) {
                    memoListPanel
                    VStack(spacing: 8) {
                        if passportReturnPage != nil { passportBackButton }
                        searchCircleButton
                        modeButtons
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
                                openTodoPanel(.schedule)
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
                    EmptyView() // 할 일 목록 패널은 왼쪽 아래 단추 위에 뜬다(TDB1114A01).
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
        .onChange(of: memoStackExpanded) { _, open in
            setTopPanel(.memo, open: open)
            // 닫으면 「오늘」로 접고, 다른 곳에서 열면 「전체」로 편다.
            if !open, memoLedgerFilter != .today { memoLedgerFilter = .today }
            if open, memoLedgerFilter == .today { memoLedgerFilter = .memos }
        }
        .onChange(of: memoLedgerFilter) { _, filter in
            let open = filter != .today
            if memoStackExpanded != open { withAnimation(.snappy) { memoStackExpanded = open } }
            // 펼칠 때 확인할 것을 다시 읽는다.
            if open { Task { todoItems = await launchPromptQueue() } }
        }
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
        guard model.isBootstrapped, isHomeLive else { return }
        #if DEBUG || BENCH
        MapHomePerfBench.stage("day_source_begin")
        #endif
        let date = model.selectedDate
        guard let prepared = await model.planDaySourceSnapshot(for: date, reusing: dayDataSnapshot),
              !Task.isCancelled, prepared.sourceRevision == model.dayProjectionRevision,
              Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: model.selectedDate) else { return }
        if currentDayDataSnapshot == nil
            || (prepared.isComplete && prepared.sourceRevision != dayDataSnapshot?.sourceRevision) {
            dayDataSnapshot = prepared
            #if DEBUG || BENCH
            MapHomePerfBench.stage("day_source_ready")
            #endif
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
            isActive: isHomeLive
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
