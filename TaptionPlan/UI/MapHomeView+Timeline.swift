import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    /// 선택한 분. 값은 관찰 저장소에 있어, 읽는 화면 조각만 다시 그려진다(ARC1030A01).
    var selectedTimelineMinute: Int? {
        get {
            if MapHomeMinuteFreeze.isFrozen { return playbackProgress.rawSelectedMinute }
            MapHomePlaybackProbe.noteMinuteRead()
            return playbackProgress.selectedMinute
        }
        nonmutating set {
            playbackProgress.rawSelectedMinute = newValue
            playbackProgress.selectedMinute = newValue
        }
    }

    /// 지금 하루요약 시트가 지도를 덮고 있는 비율. 펼치면 지도가 다 가려져 보정하지 않는다.
    var daySummaryCoverage: CGFloat {
        guard isDaySummaryPresented, !isWideLayout,
              daySummaryDetent != MapHomeDaySummarySheet.expandedDetent
        else { return 0 }
        return MapHomeDaySummaryLayout.collapsedCoverage
    }

    var sidebarInteractionWidth: CGFloat {
        MapHomeTimeSidebarMath.totalWidth(railWidth: timeRailWidth)
            + Layout.horizontalInset
    }

    /// 구간 편집을 저장한 뒤 선택 시각을 그 구간 가운데로 되돌린다.
    /// 클립 편집기와 (지금은 숨긴) 행동구간 편집 화면이 같은 규칙을 쓴다.
    func applySectionEditSave(
        _ span: TimeSpan,
        selection: MapHomeSectionEditSelection
    ) {
        refreshTimeRailSegments()
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: selection.date)
        let midpoint = span.start.addingTimeInterval(span.duration / 2)
        selectedTimelineMinute = min(
            1_439,
            max(0, Int(midpoint.timeIntervalSince(dayStart) / 60))
        )
        isTimelineSelectionPinned = true
        if selection.segment.categoryID == "unconfirmed" {
            rewardRecentCompletedDay(selection.date)
        }
    }

    /// 지금은 쓰지 않는 행동구간 편집 화면. 클립 편집기로 대체되어 호출부가
    /// 주석 처리되어 있다. 화면을 되돌릴 때 이 함수를 다시 연결한다.
    func sectionEditSheet(for selection: MapHomeSectionEditSelection) -> some View {
        MapHomeSectionEditSheet(
            model: model,
            selection: selection,
            language: language,
            onSaved: { result in
                applySectionEditSave(
                    result.selectedSpan,
                    selection: selection
                )
            }
        )
    }

    /// 시간 막대에 무늬로 표시할 회의 구간. 일정이나 그날 기록이 바뀔 때만 다시 계산한다.
    var meetingRailSpans: [Range<Int>] {
        let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate)
        let events = model.snapshot.calendarEvents
        let key = "\(dayStart.timeIntervalSinceReferenceDate)|\(events.count)|\(currentDayDataSnapshot?.sourceRevision ?? 0)"
        return meetingRailSpansMemo.value(for: key) {
            MapHomeMeetingPolicy.minuteSpans(events: events, dayStart: dayStart)
        }
    }

    func daySummaryEntries(from totalsByID: [String: TimeInterval]) -> [MapHomeDaySummaryEntry] {
        let total = totalsByID.values.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return [] }
        return totalsByID
            .filter { $0.value > 0 }
            .map { id, seconds in
                let presentation = MapHomeSidebarMajorCategory.presentation(
                    for: id,
                    categoryColors: model.settings.mapCategoryColors
                )
                return MapHomeDaySummaryEntry(
                    id: id,
                    title: presentation.localizedTitle(language),
                    systemImage: presentation.systemImage,
                    tint: presentation.tint,
                    seconds: seconds,
                    ratio: seconds / total
                )
            }
            .sorted { $0.seconds > $1.seconds }
    }

    /// 오른쪽 위 날짜 배지: 요일(토 파랑, 일·공휴일 빨강)과 큰 날짜.
    /// 누르면 앞뒤 날짜가 이어지는 날짜 줄을 펼친다. 그 줄을 좌우로 밀면 하루씩 넘어간다.
    /// 접힌 사이드바를 펼치는 화살표. 날짜 배지와 한 알약에 붙어 있다(숨김 상태에서는 아래 화살표).
    var sidebarExpandArrow: some View {
        Button {
            withAnimation(MapHomeView.sidebarToggleSpring) { isSidebarVisible = true }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                .foregroundStyle(Color.tpInk.opacity(0.85))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.text("사이드바 펼치기", "Show sidebar"))
        .accessibilityIdentifier("mapHomeSidebarExpandButton")
    }

    /// 화랑이를 누르면 카운터 창을 보이거나 숨긴다(CTR1107A01, 대표 지시). 하루 요약은 집 아이콘에서 연다.
    func toggleCounterFromCat() {
        withAnimation(.snappy(duration: 0.22)) { isCounterCollapsed.toggle() }
    }

    /// 하루 요약을 연다. 화랑이에서 열면 시트가 올라올 때 집이 아니라 화랑이를 화면에 남긴다.
    func presentDaySummary(fromCat: Bool) {
        daySummaryFocusesCat = fromCat
        isDaySummaryPresented = true
    }

    @ViewBuilder
    var mapSideRails: some View {
        if !isMenuOpen || isWideLayout {
            GeometryReader { proxy in
                mapSideRailsContent(viewportSize: proxy.size)
            }
            .zIndex(MapHomeLayerPriority.sidebar)
        }
    }

    func mapSideRailsContent(viewportSize: CGSize) -> some View {
        let frame = MapHomeOverlayLayoutMath.alignedRailFrame(
            viewportHeight: viewportSize.height,
            topInset: topOverlayHeight + Layout.timeRailTopMargin,
            bottomInset: Layout.horizontalInset + layoutStyle.bottomReservedHeight
        )
        let timeSidebarFrame = MapHomeOverlayLayoutMath.timeSidebarFrame(
            viewportHeight: viewportSize.height,
            topOverlayHeight: 0,
            topMargin: Layout.horizontalInset * 2 + Layout.dateBadgeSize,
            bottomMargin: Layout.horizontalInset + MapHomeWideLayoutPolicy.sidebarBottomReserve(viewportWidth: viewportSize.width, actionBarHeight: layoutStyle.bottomReservedHeight)
        )
        let timeSidebarWidth = MapHomeTimeSidebarMath.interactionWidth(
            railWidth: timeRailWidth,
            trailingInteractionWidth: Layout.horizontalInset
        )
        return HStack(alignment: .top, spacing: 0) {
            if !isScreenRecording, !Self.benchHidden("controls") {
            coarseRegion { mapControls(proxy: nil, railHeight: frame.height) }
                .onGeometryChange(
                    for: CGRect.self,
                    of: { geometry in
                        geometry.frame(in: .named("mapHomeViewport"))
                    },
                    action: { frame in
                        guard mapControlsFrame != frame else { return }
                        mapControlsFrame = frame
                    }
                )
            }
            Spacer(minLength: 0)
            Color.clear
                .frame(width: timeSidebarWidth, height: frame.height)
        }
        .padding(.leading, Layout.horizontalInset)
        .frame(maxWidth: .infinity)
        .frame(height: frame.height)
        .overlay(alignment: .topTrailing) {
            if isSidebarVisible {
                currentTimeRail
                    .frame(width: timeSidebarWidth, height: timeSidebarFrame.height)
                    .offset(y: timeSidebarFrame.minY - frame.minY)
                    .transition(.sidebarDrop)
            }
        }
        .position(x: viewportSize.width / 2, y: frame.midY)
    }

    var currentTimeRail: some View {
        GeometryReader { proxy in
            // 확대·축소 단추가 들어갈 바닥 자리. 시간선·날씨 띠를 이만큼 줄여 아래를 비운다.
            let zoomReserve = min(32, proxy.size.height / 3)
            let railHeight = MapHomeOverlayLayoutMath.timeSidebarHeight(
                availableHeight: proxy.size.height - zoomReserve
            )
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                let minute = timelineSelectionMinute(at: timeline.date)
                let timeSidebarInteractionWidth =
                    MapHomeTimeSidebarMath.interactionWidth(
                        railWidth: timeRailWidth,
                        trailingInteractionWidth: Layout.horizontalInset
                    )
                let weatherOriginX = MapHomeWeatherRailAlignmentMath.weatherOriginX(
                    weatherRailWidth: Layout.weatherRailWidth,
                    timeRailWidth: timeRailWidth
                )
                let selectedTimeCard = MapHomeTimeSidebarMath.selectedTimeCardFrame(
                    availableHeight: railHeight,
                    selectedMinute: minute,
                    visibleStartMinute: timeSidebarVisibleStartMinute,
                    visibleDurationMinutes: timeSidebarVisibleDurationMinutes
                )
                let selectedCardHeight = min(railHeight, selectedTimeCard.height)
                let selectedCardCenterY = min(
                    max(selectedTimeCard.midY, selectedCardHeight / 2),
                    railHeight - selectedCardHeight / 2
                )
                let timeRailTop = max(0, proxy.size.height - zoomReserve - railHeight)
                ZStack(alignment: .topLeading) {
                    if recordingShows(\.timeSidebar) {
                    Capsule()
                        .fill(Color.tpAccent.opacity(0.07))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.tpAccent.opacity(0.20), lineWidth: 0.8)
                        }
                        .frame(
                            width: timeRailWidth - 12,
                            height: selectedCardHeight
                        )
                        .position(
                            x: proxy.size.width
                                - Layout.horizontalInset
                                - (timeRailWidth - 12) / 2,
                            y: timeRailTop + selectedCardCenterY
                        )
                        .allowsHitTesting(false)
                    }
                    if model.settings.weatherSidebarVisible, recordingShows(\.weatherSidebar), !Self.benchHidden("weather") {
                        let railWeather = displayWeatherContexts
                        if let notice = MapHomeWeatherNoticePolicy.notice(
                            status: model.weatherStatus,
                            hasDisplayableWeather: railWeather.contains {
                                MapHomeWeatherDisplayPolicy.isComplete($0)
                                    && Calendar.autoupdatingCurrent.isDate(
                                        $0.observedAt,
                                        inSameDayAs: model.selectedDate
                                    )
                            }
                        ) {
                            MapHomeWeatherNoticeView(notice: notice, language: language)
                                .frame(width: MapHomeWeatherNoticeView.width, alignment: .trailing)
                                .offset(
                                    x: weatherOriginX + Layout.weatherRailWidth
                                        - MapHomeWeatherNoticeView.width,
                                    y: 6
                                )
                                .allowsHitTesting(false)
                        }
                        coarseRegion {
                            MapHomeWeatherSidebar(
                                date: model.selectedDate,
                                contexts: railWeather,
                                selectedMinute: timelineSelectionMinute(at: timeline.date),
                                language: language,
                                visibleStartMinute: timeSidebarVisibleStartMinute,
                                visibleDurationMinutes: timeSidebarVisibleDurationMinutes
                            )
                        }
                        .offset(x: weatherOriginX)
                        .allowsHitTesting(false)
                    }
                    if recordingShows(\.timeSidebar), !Self.benchHidden("timebar") {
                    MapHomeTimeSidebar(
                        smoothsPlayback: isDayPlaybackRunning && playbackDriver != nil,
                        date: model.selectedDate,
                        selectedMinute: Binding(
                            get: { timelineSelectionMinute(at: timeline.date) },
                            set: { minute in
                                selectedPawprintTimestamp = nil
                                guard selectedTimelineMinute != minute else { return }
                                stopDayPlayback(resetProgress: true)
                                isTimelineSelectionPinned = true
                                selectedTimelineMinute = minute
                            }
                        ),
                        visibleStartMinute: $timeSidebarVisibleStartMinute,
                        visibleDurationMinutes: $timeSidebarVisibleDurationMinutes,
                        activity: model.isBootstrapped
                            ? currentActivity(at: minute)
                            : nil,
                        segments: travelSidebarSegments ?? timeRailSegments,
                        detailSpans: meetingRailSpans + timeRailSegments.flatMap(\.walkSpans),
                        categoryColors: model.settings.mapCategoryColors,
                        zoomResetToken: zoomResetToken,
                        zoomStepToken: zoomStepToken,
                        railWidth: timeRailWidth,
                        maximumSelectableMinute: nil,
                        trailingInteractionWidth: Layout.horizontalInset,
                        onInteractionChanged: { isInteracting in
                            if isInteracting, isDayPlaybackRunning {
                                stopDayPlayback(resetProgress: true)
                            }
                            isTimelineInteractionActive = isInteracting
                            if isInteracting {
                                MapHomeInteractionMonitor.shared.begin("sidebar_drag", idleTimeout: 8)
                            } else {
                                MapHomeInteractionMonitor.shared.end("sidebar_drag")
                            }
                            if !isInteracting {
                                flushDeferredWBSPlaybackProjection()
                                recordTimelineWindow("handle_end")
                            }
                        },
                        onSectionEdit: { selectedMinute in
                            guard model.isBootstrapped else { return }
                            openSectionEditor(at: selectedMinute)
                        },
                        onCollapse: {
                            withAnimation(MapHomeView.sidebarToggleSpring) { isSidebarVisible = false }
                        },
                        onUnconfirmedReview: { segment in
                            guard model.isBootstrapped else { return }
                            focusedUnconfirmedReviewSegment = segment
                            isUnconfirmedReviewPresented = true
                        },
                        unconfirmedMode: { MapHomePlaybackLocation.gapMode(at: timelineDate(forMinute: Double($0.startMinute + $0.endMinute) / 2), travel: currentDayDataSnapshot?.travel ?? [], readings: historicalPlaybackReadings) }
                    )
                    // 확대·축소는 시간선 아래 비워 둔 자리에 사이드바와 같은 폭·모서리의 알약으로 눕힌다.
                    timelineZoomControls
                        .position(
                            x: proxy.size.width - Layout.horizontalInset - timeRailWidth / 2,
                            y: proxy.size.height - 11
                        )
                    }

                    let badgeColumns = scheduleBadgeColumns(railHeight: railHeight)
                    ForEach(recordingShows(\.sidebarMemos) ? scheduleStickersForSelectedDate : []) { sticker in
                        let window = MapHomeTimeSidebarMath.visibleWindow(
                            startMinute: timeSidebarVisibleStartMinute,
                            durationMinutes: timeSidebarVisibleDurationMinutes,
                            centerMinute: effectiveTimelineMinute
                        )
                        let minute = minuteOfDay(for: sticker.occurredAt)
                        let trackHeight = max(
                            1,
                            railHeight - MapHomeTimeSidebarMath.verticalInset * 2
                        )
                        let y = MapHomeTimeSidebarMath.verticalInset
                            + trackHeight * MapHomeTimeSidebarMath.position(
                                minute: minute,
                                window: window
                            )
                        Button {
                            if isStickerMode { selectedMapStickerEditor = .sticker(sticker.id); return }
                            toggleSidebarNote(.sticker(sticker, minute: minute, badgeOffset: scheduleBadgeOffset(id: "sticker-\(sticker.id)", minute: minute, isEvent: false, columns: badgeColumns)))
                        } label: {
                            StickerGlyph(symbol: sticker.systemImage, colorHex: sticker.colorHex, size: 20)
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
                                .foregroundStyle(Color(hex: sticker.colorHex))
                                .frame(width: 22, height: 22)
                                .taptionRaised(.circle, fill: .white)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            language.text(
                                "\(sticker.title) 일정 메모",
                                "\(sticker.title) schedule memo"
                            )
                        )
                        // 날씨 칩의 왼쪽 끝에 맞춘다(캡처로 잰 값: 칩 왼쪽 끝 x 17, 스티커 반지름 11).
                        .position(
                            x: scheduleBadgeBaseX + scheduleBadgeOffset(id: "sticker-\(sticker.id)", minute: minute, isEvent: false, columns: badgeColumns),
                            y: min(
                                max(y, MapHomeTimeSidebarMath.verticalInset),
                                railHeight - MapHomeTimeSidebarMath.verticalInset
                            )
                        )
                    }

                    // 일정은 시작 시간에 구글 로고로 표시한다(스티커와 같은 열).
                    // 시간이 있는 메모는 메모 아이콘으로 사이드바 시간에 바로 보인다.
                    ForEach(recordingShows(\.sidebarMemos) ? timedMemosForSelectedDate : []) { memo in
                        let window = MapHomeTimeSidebarMath.visibleWindow(
                            startMinute: timeSidebarVisibleStartMinute,
                            durationMinutes: timeSidebarVisibleDurationMinutes,
                            centerMinute: effectiveTimelineMinute
                        )
                        let minute = minuteOfDay(for: memo.occurredAt)
                        let trackHeight = max(1, railHeight - MapHomeTimeSidebarMath.verticalInset * 2)
                        let y = MapHomeTimeSidebarMath.verticalInset
                            + trackHeight * MapHomeTimeSidebarMath.position(minute: minute, window: window)
                        Button {
                            toggleSidebarNote(.memo(memo, minute: minute, badgeOffset: scheduleBadgeOffset(id: "memo-\(memo.id)", minute: minute, isEvent: false, columns: badgeColumns)))
                        } label: {
                            StickerGlyph(symbol: memo.iconSymbol(), colorHex: memo.iconColorHex, size: 20)
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                                .foregroundStyle(memo.isSticker ? Color(hex: memo.stickerColorHex ?? "#F28FA9") : Color.tpInk)
                                .frame(width: 22, height: 22)
                                .taptionRaised(.circle, fill: .white)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(memo.text) 메모")
                        .position(
                            x: scheduleBadgeBaseX + scheduleBadgeOffset(id: "memo-\(memo.id)", minute: minute, isEvent: false, columns: badgeColumns),
                            y: min(max(y, MapHomeTimeSidebarMath.verticalInset), railHeight - MapHomeTimeSidebarMath.verticalInset)
                        )
                    }
                    ForEach(recordingShows(\.sidebarMemos) ? dayCalendarEventsForSelectedDate.filter { !$0.isAllDay } : []) { event in
                        let window = MapHomeTimeSidebarMath.visibleWindow(
                            startMinute: timeSidebarVisibleStartMinute,
                            durationMinutes: timeSidebarVisibleDurationMinutes,
                            centerMinute: effectiveTimelineMinute
                        )
                        let minute = minuteOfDay(for: event.span.start)
                        let trackHeight = max(1, railHeight - MapHomeTimeSidebarMath.verticalInset * 2)
                        let y = MapHomeTimeSidebarMath.verticalInset
                            + trackHeight * MapHomeTimeSidebarMath.position(minute: minute, window: window)
                        Button {
                            toggleSidebarNote(.event(id: "\(event.id)", title: event.title, notes: event.notes, span: event.span, minute: minute, badgeOffset: scheduleBadgeOffset(id: "event-\(event.id)", minute: minute, isEvent: true, columns: badgeColumns)))
                        } label: {
                            MapHomeCalendarSourceLogo()
                                .padding(3)
                                .frame(width: 22, height: 22)
                                .taptionRaised(.circle, fill: .white)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(event.title) 일정")
                        .position(
                            x: scheduleBadgeBaseX + scheduleBadgeOffset(id: "event-\(event.id)", minute: minute, isEvent: true, columns: badgeColumns),
                            y: min(max(y, MapHomeTimeSidebarMath.verticalInset), railHeight - MapHomeTimeSidebarMath.verticalInset)
                        )
                    }
                    if let note = sidebarNote {
                        let window = MapHomeTimeSidebarMath.visibleWindow(
                            startMinute: timeSidebarVisibleStartMinute,
                            durationMinutes: timeSidebarVisibleDurationMinutes,
                            centerMinute: effectiveTimelineMinute
                        )
                        let y = MapHomeTimeSidebarMath.verticalInset + max(1, railHeight - MapHomeTimeSidebarMath.verticalInset * 2)
                            * MapHomeTimeSidebarMath.position(minute: note.minute, window: window)
                        MapHomeSidebarNoteBubble(note: note, onExpire: { sidebarNote = nil }) {
                            selectedMapStickerEditor = note.editorTarget
                            sidebarNote = nil
                        }
                        .position(
                            x: MapHomeSidebarNoteLayout.centerX(badgeX: scheduleBadgeBaseX + note.badgeOffset),
                            y: min(max(y, 40), railHeight - 40)
                        )
                    }
                }
                .onChange(of: timeline.date) { _, date in
                    refreshHomeGrowth(at: date)
                }
                .frame(
                    width: timeSidebarInteractionWidth,
                    height: railHeight
                )
                .position(
                    x: proxy.size.width - timeSidebarInteractionWidth / 2,
                    y: max(
                        railHeight / 2,
                        proxy.size.height - zoomReserve - railHeight / 2
                    )
                )
            }
        }
        .frame(
            width: MapHomeTimeSidebarMath.interactionWidth(
                railWidth: timeRailWidth,
                trailingInteractionWidth: Layout.horizontalInset
            )
        )
        .frame(maxHeight: .infinity, alignment: .trailing)
    }

    var timelineZoomControls: some View {
        HStack(spacing: 0) {
            timelineZoomButton(systemImage: "plus", direction: 1)
            timelineZoomButton(systemImage: "minus", direction: -1)
        }
        .taptionRaised(.capsule, fill: Color.tpSurface)
        .overlay(Rectangle().fill(Color.tpLine.opacity(0.45)).frame(width: 0.6, height: 12))
    }

    func timelineZoomButton(systemImage: String, direction: Int) -> some View {
        let durations = MapHomeTimeSidebarMath.zoomDurations
        let enabled = direction > 0
            ? timeSidebarVisibleDurationMinutes > (durations.last ?? 60)
            : timeSidebarVisibleDurationMinutes < (durations.first ?? 1_440)
        return Button {
            zoomStepToken += direction
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .bold))
                .foregroundStyle(enabled ? Color.tpInk : Color.tpSecondary.opacity(0.4))
                .frame(width: timeRailWidth / 2, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(
            direction > 0
                ? language.text("시간선 확대", "Zoom timeline in")
                : language.text("시간선 축소", "Zoom timeline out")
        )
    }

    func refreshTimeRailSegments() {
        guard scenePhase == .active else { return }
        guard model.isBootstrapped else {
            if !timeRailSegments.isEmpty {
                timeRailSegments = []
            }
            return
        }
        let dayData = currentDayDataSnapshot
        let next = MapHomePlaceFirstPolicy.apply(
            to: MapHomeTimeRailSegmentEngine.segments(
                from: dayData?.actuals ?? [],
                travel: dayData?.travel ?? [],
                on: model.selectedDate
            ),
            stays: dayData?.places ?? [],
            frequentPlaces: model.settings.frequentPlaces,
            readings: dayData?.readings ?? [],
            userOwnedIDs: MapHomePlaceFirstPolicy.userOwnedIDs(
                dayData?.actuals ?? [], activityCorrections: model.settings.activityCorrections
            ),
            on: model.selectedDate
        )
        if next != timeRailSegments {
            timeRailSegments = next
        }
    }

    func refreshSelectedTimelineMapPosition(
        minute: Int?,
        using proxy: MapProxy? = nil
    ) {
        let deferredProjection = flushDeferredRouteProjection()
        guard minute != nil else { return }
        _ = deferredProjection
            ?? refreshRouteProjection()
        recordCurrentPlaybackAlignment()
        guard let point = displayedPlaybackFocusPoint else { return }
        focusMap(on: point, using: proxy, followsTracking: true)
    }

    func openSectionEditor(at minute: Int) {
        guard model.isBootstrapped else { return }
        stopDayPlayback(resetProgress: true)
        let segment = MapHomeTimeRailSegmentEngine.segment(
            at: minute,
            in: timeRailSegments
        ) ?? .wholeDayUnconfirmed
        TaptionPlanDiagnosticsLogger.shared.record(
            "section_edit_open_requested",
            fields: [
                "minute": String(minute),
                "category": segment.categoryID,
                "source_count": String(segment.sourceIDs.count),
            ]
        )
        sectionEditSelection = MapHomeSectionEditSelection(
            date: model.selectedDate,
            minute: minute,
            activity: currentActivity(at: minute),
            segment: segment,
            details: sectionDetails(at: minute),
            daySegments: timeRailSegments,
            dayDetails: allDaySectionDetails()
        )
    }

    var effectiveTimelineMinute: Int {
        timelineSelectionMinute()
    }

    /// 과거 날짜 기본값 1440분은 다음 날 0시가 되므로 저장·일정 판정용 시각은 그날 23:59로 묶는다.
    var timelineSelectionDate: Date {
        timelineDate(forMinute: Double(min(
            effectiveTimelineMinute,
            MapHomeTimeSidebarMath.fullDayMinutes - 1
        )))
    }

    func timelineDate(forMinute minute: Double) -> Date {
        let safeMinute = minute.isFinite
            ? min(
                Double(MapHomeTimeSidebarMath.fullDayMinutes),
                max(0, minute)
            )
            : 0
        let wholeMinute = min(
            MapHomeTimeSidebarMath.fullDayMinutes,
            Int(safeMinute.rounded(.down))
        )
        let fraction = safeMinute - Double(wholeMinute)
        let date = RouteTimelineDataEngine.timelineDate(
            selectedDate: model.selectedDate,
            minute: wholeMinute
        ).addingTimeInterval(fraction * 60)
        return clampedTimelineDate(date)
    }

    func timelineSelectionMinute(
        at now: Date = .now
    ) -> Int {
        if isTimelineSelectionPinned, let selectedTimelineMinute {
            return selectedTimelineMinute
        }
        return selectedTimelineMinute ?? MapHomeTimeSidebarMath.defaultTimelineMinute(
            for: model.selectedDate,
            now: now,
            calendar: .autoupdatingCurrent
        )
    }

    var timelineSelectionSpan: TimeSpan? {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        guard let segment = MapHomeTimeRailSegmentEngine.segment(
            at: effectiveTimelineMinute,
            in: timeRailSegments
        ), let end = calendar.date(
            byAdding: .minute,
            value: segment.endMinute,
            to: dayStart
        ), let start = calendar.date(
            byAdding: .minute,
            value: segment.startMinute,
            to: dayStart
        ) else { return nil }
        return TimeSpan(start: start, end: end)
    }

    /// 하루 전체의 상세 활동. 구간 경계에서 자르지 않으므로 경계에 걸친 기록도 온전히 남는다.
    func allDaySectionDetails() -> [MapHomeSectionDetail] {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let dayData = currentDayDataSnapshot
        return MapHomeSectionDetailEngine.dayDetails(
            actuals: dayData?.actuals ?? [],
            travel: dayData?.travel ?? [],
            dayStart: dayStart,
            dayEnd: dayEnd,
            asOf: .now
        )
    }

    func sectionDetails(at minute: Int) -> [MapHomeSectionDetail] {
        let calendar = Calendar.autoupdatingCurrent
        let dayData = currentDayDataSnapshot
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart),
              let segment = MapHomeTimeRailSegmentEngine.segment(
                at: minute,
                in: timeRailSegments
              )
        else { return [] }
        return MapHomeSectionDetailEngine.details(
            actuals: dayData?.actuals ?? [],
            travel: dayData?.travel ?? [],
            segment: segment,
            dayStart: dayStart,
            dayEnd: dayEnd,
            asOf: .now
        )
    }

    func clampedTimelineDate(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        MapHomeRouteReadingsPolicy.clampedTimelineDate(
            selectedDate: model.selectedDate,
            timelineDate: date,
            now: now,
            calendar: calendar
        )
    }

    func minuteOfDay(for date: Date) -> Int {
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute, .second], from: date)
        return min(1_439, max(0, (components.hour ?? 0) * 60 + (components.minute ?? 0)))
    }

    /// 하루요약 시트가 지도를 덮은 만큼 집을 남은 영역의 가운데로 옮긴다.
    /// 시트를 내리면 다시 지도 전체 가운데로 돌아온다. 배율·방향은 그대로 둔다.
    /// 하루 요약 시트가 올라올 때 화면 위쪽에 남길 기준점. 화랑이에서 열었고 집 밖이면 화랑이, 아니면 집.
    var daySummaryCameraAnchor: CLLocationCoordinate2D? {
        if daySummaryFocusesCat, !isDisplayedCatAtHome, let cat = displayedLocationCoordinate {
            return cat
        }
        guard let home = model.settings.frequentPlaces.first(where: { $0.kind == .home })?.point else { return nil }
        return CLLocationCoordinate2D(latitude: home.latitude, longitude: home.longitude)
    }

    func applyDaySummaryCameraCoverage() {
        let coverage = daySummaryCoverage
        guard abs(coverage - daySummaryAppliedCoverage) > 0.001 else { return }
        // 재생 중이거나 위치를 따라가는 중에는 카메라가 다른 곳에서 움직인다. 손대지 않는다.
        guard !isDayPlaybackRunning, userTrackingMode == .idle else { return }
        guard mapViewportSize.height > 0,
              let camera = visibleMapCamera,
              let anchor = daySummaryCameraAnchor
        else { return }
        let shift = MapHomeDaySummaryLayout.centerShift(
            viewportHeight: mapViewportSize.height,
            coverage: coverage
        )
        let latitudeShift = MapHomeDaySummaryLayout.latitudeShift(
            shift: shift,
            viewportHeight: mapViewportSize.height,
            latitudeDelta: visibleMapSpan.latitudeDelta
        )
        // 중심을 아래(남쪽)로 내리면 기준점(집 또는 화랑이)은 그만큼 화면 위로 올라온다.
        let center = CLLocationCoordinate2D(
            latitude: anchor.latitude - latitudeShift,
            longitude: anchor.longitude
        )
        daySummaryAppliedCoverage = coverage
        setMapPosition(.camera(MapCamera(
            centerCoordinate: center,
            distance: camera.distance,
            heading: camera.heading,
            pitch: camera.pitch
        )))
        // Apple 지도는 아직 반영되지 않은 뷰포트 명령이 있으면 카메라 명령을 건너뛴다.
        // 같은 중심으로 뷰포트 명령도 보내 어느 쪽이 적용돼도 집이 같은 자리에 오게 한다.
        if !rendersVectorMap {
            appleViewportCommand = MapHomeAppleViewportCommand(
                revision: (appleViewportCommand?.revision ?? 0) &+ 1,
                centerCoordinate: center,
                heading: nil,
                targetPoint: nil
            )
        }
    }
}
