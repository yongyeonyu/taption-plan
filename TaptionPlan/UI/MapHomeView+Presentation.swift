import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    /// 시트·전체 화면·알림 연결. 사슬이 길면 타입 검사가 느려져 세 덩어리로 나눈다. 수식어 순서는 그대로다.
    func presentationModifiers(_ content: some View) -> some View {
        presentationScreenModifiers(presentationMapModifiers(presentationDayModifiers(content)))
    }

    func presentationDayModifiers(_ content: some View) -> some View {
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
        .sheet(isPresented: $isPlanRealityPresented) { PlanRealityView(model: model, language: language) }
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
            guard isHomeLive else { return }
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
        .mapHomeLaunchPrompts($launchPrompt, model: model, language: language) {
            focusedUnconfirmedReviewSegment = nil
            isUnconfirmedReviewPresented = true
        }
    }

    func presentationMapModifiers(_ content: some View) -> some View {
        content
        .sheet(isPresented: $isStrideCalibrationPresented) {
            MapHomeStrideCalibrationSheet(language: language)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .mapHomeWidePanel(isPresented: $isCalendarPresented, kind: .calendar, title: language.text("달력", "Calendar"), viewportWidth: mapViewportSize.width, language: language) {
            MapHomeCalendarSheet(
                selectedDate: calendarSelectedDateBinding,
                starredDays: travelPlanDays,
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
                liveToken: ((homeLatestReading?.timestamp.timeIntervalSince1970 ?? 0) / 15).rounded(.down)
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
    }

    func presentationScreenModifiers(_ content: some View) -> some View {
        content
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
        .onChange(of: TripShareInbox.shared.pending != nil, initial: true) { _, invited in if invited { isTravelHomePresented = true } }
        .travelModeCover(isPresented: $isTravelHomePresented) {
            // 받은 여행 계획(붙여넣기·중계)도 여기서 가져온다. 예전 지도 여행 모드로는 가지 않는다(TVX1116A01).
            TravelModeView(model: model, language: language, importText: pastedTripText)
                .onDisappear { pastedTripText = nil }
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
                    model.selectedDate = day
                }
            )
        }
        .mapHomeUsageGuide(isPresented: $isHomeGuidePresented, language: language)
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
}
