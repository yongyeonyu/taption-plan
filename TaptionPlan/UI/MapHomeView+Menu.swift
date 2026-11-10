import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    var language: MapHomeLanguage {
        switch AppLanguagePreference.resolve(rawValue: languageRawValue) {
        case .korean: .korean
        case .english: .english
        }
    }

    var menuPanelKind: MapHomeWidePanelKind {
        MapHomeWideLayoutPolicy.menuPanelKind(viewportSize: mapViewportSize, hasPermissionCard: !sensorCollectionPermissionGate.sensorCollectionReady)
    }

    // MARK: 통합 메모 표시

    var memoDisplayMode: MapHomeMemoDisplayMode {
        MapHomeMemoDisplayMode(rawValue: memoDisplayRaw) ?? .all
    }

    /// 화랑이 위 카운터 위젯을 눌렀는지. 위젯을 눌러도 지도 이동이 막히지 않게 지도 탭에서 영역으로 판정한다.
    /// 카운터 창 자리는 지도 오버레이(=지도 로컬) 좌표로 기록된다.
    func isCounterWindowTapped(at tapPoint: CGPoint) -> Bool {
        let frame = counterWindowFrame.frame
        return frame.width > 0 && frame.height > 0 && frame.insetBy(dx: -8, dy: -8).contains(tapPoint)
    }

    /// 누른 줄의 카운터 상세 화면을 연다. 줄은 위에서 아래로 같은 높이로 쌓여 있어 높이 비율로 고른다.
    /// 줄 목록을 아직 모르면(창이 막 생긴 때) 예전처럼 카운터 메뉴를 연다.
    func openCounterDetail(at tapPoint: CGPoint) {
        let rows = counterWindowFrame.frame
        let targets = counterRowTargets
        guard let index = MapHomeCounterDetailBuilder.rowIndex(
            tapY: tapPoint.y, frame: rows, count: targets.count
        ) else {
            openCounterMenu()
            return
        }
        counterDetail = targets[index]
    }

    /// 상세 화면 내용. 연 순간의 값으로 만든다.
    func counterDetailContent(for target: MapHomeCounterDetailTarget) -> MapHomeCounterDetailContent {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let now = Date()
        let badges = mapCounterBadges(asOf: now)
        switch target {
        case .salary:
            let live = salaryLive
            let workSeconds: TimeInterval
            if let minute = counterCutoffMinute {
                workSeconds = MapHomeSalaryPolicy.workSeconds(in: salaryWorkSpans[dayStart] ?? [], until: dayStart + minute * 60)
            } else if calendar.isDateInToday(model.selectedDate), let live {
                workSeconds = MapHomeSalaryPolicy.liveWorkSeconds(
                    base: live.todayWorkSeconds, baseDate: live.measuredAt, isWorking: live.isWorking, now: now, tick: 1
                )
            } else {
                workSeconds = MapHomeSalaryPolicy.workSeconds(in: salaryWorkSpans[dayStart] ?? [], until: .distantFuture)
            }
            let rate = live?.hourlyRate ?? 0
            return MapHomeCounterDetailBuilder.salary(
                spans: salaryWorkSpans[dayStart] ?? [],
                earned: MapHomeSalaryPolicy.wonText(
                    MapHomeSalaryPolicy.earnings(workSeconds: workSeconds, hourlyRate: rate), language: language
                ),
                hourlyRateText: MapHomeSalaryPolicy.wonText(rate, language: language),
                language: language
            )
        case .allowance:
            return MapHomeAllowancePolicy.detail(day: dayStart, playbackMinute: counterCutoffMinute, now: now, language: language)
        case .kind(let kind):
            let total = badges.first(where: { $0.kind == kind })?.text ?? "–"
            switch kind {
            case .steps:
                return MapHomeCounterDetailBuilder.steps(
                    readings: currentDayReadings, total: total, dayStart: dayStart, language: language
                )
            case .distance:
                return MapHomeCounterDetailBuilder.distance(
                    segments: MapHomeCounterTimelinePolicy.visibleSegments(
                        displayDayDataSnapshot?.travel ?? [], cutoff: counterCutoffDate, day: selectedDaySpan
                    ), total: total, language: language
                )
            case .work, .study, .hobby, .exercise:
                let seconds = kind.categoryID.flatMap { daySummaryCategorySeconds(asOf: counterCutoffDate, now: now)[$0] } ?? 0
                return MapHomeCounterDetailBuilder.time(
                    kind: kind,
                    actuals: displayDayDataSnapshot?.actuals ?? [],
                    totalSeconds: seconds,
                    total: total,
                    dayStart: dayStart,
                    dayEnd: dayEnd,
                    now: now,
                    language: language
                )
            }
        }
    }

    /// 왼쪽 메뉴를 열고 표시 > 카운터 항목을 펼친다(위젯을 누르면 카운터 메뉴로 볼 수 있는 내용만 보여 준다).
    func openCounterMenu() {
        openMenu()
        isDisplayMenuExpanded = true
        isCounterMenuExpanded = true
    }

    func presentMapLongPressMenu(at coordinate: CLLocationCoordinate2D) {
        mapSearchResults = []
        isMapSearchFocused = false
        isSearchExpanded = false
        pendingLongPressCoordinate = coordinate
        // 누른 자리에 핀이 먼저 꽂힌 다음 메뉴가 뜬다.
        selectedSearchPin = MapHomeSearchResult(
            title: language.text("사용자 지점", "User location"),
            subtitle: language.text("지도에서 선택한 위치", "Long-pressed map location"),
            coordinate: coordinate
        )
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            if pendingLongPressCoordinate != nil { isLongPressMenuPresented = true }
        }
    }

    /// 대분류별 초. `cutoff`를 넘기면 그 시각까지로 잘라 센다(재생 중 카운터가 시간을 따라 올라간다).
    /// 멈춰 있을 때(`cutoff == nil`)는 `now`까지로 센다 — 창의 시계가 10초마다 넘겨 주는
    /// 그 순간이라, 진행 중인 활동이 분 단위로 올라간다.
    func daySummaryCategorySeconds(asOf cutoff: Date?, now: Date = .now) -> [String: TimeInterval] {
        // 확정한 날은 저장해 둔 대분류별 초를 그대로 쓴다(다시 계산하지 않는다).
        if cutoff == nil,
           let sealed = model.sealedDay(for: model.selectedDate),
           !sealed.categorySeconds.isEmpty {
            return sealed.categoryDurations
        }
        let snap = displayDayDataSnapshot
        let actuals = snap?.actuals ?? []
        let travel = snap?.travel ?? []
        let stays = snap?.places ?? []
        let placeKinds = FrequentPlaceResolutionEngine().kindsByPlaceKey(
            model.snapshot.settings.frequentPlaces
        )
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: model.selectedDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 60 * 60)
        let dayWindow = TimeSpan(start: start, end: end)
        let totalsByID = TaptionSealedDayBuilder.categoryDurations(
            actuals: actuals,
            travel: travel,
            stays: stays,
            placeKinds: placeKinds,
            day: dayWindow,
            asOf: cutoff ?? now
        )
        // 재생 시각으로 잘라 내려면 원본이 있어야 한다. 없으면 저장해 둔 확정값으로 물러선다.
        if totalsByID.isEmpty, let sealed = model.sealedDay(for: model.selectedDate) {
            return sealed.categoryDurations
        }
        return totalsByID
    }

    func openMenu() {
        model.prewarmPlaceBookVisits()
        isLocationMenuExpanded = false
        isUserLocationsMenuExpanded = false
        isCategoryMenuExpanded = false
        isDisplayMenuExpanded = false
        isCounterMenuExpanded = false
        isSidebarGroupExpanded = false
        isMapGroupExpanded = false
        isSettingsMenuExpanded = false
        withAnimation(.easeInOut(duration: 0.22)) { isMenuOpen = true }
    }

    /// 안내 알림에서 바로 메뉴 > 위치를 연다. 알림이 말한 목적지로 데려간다.
    func openLocationSettings() {
        openMenu()
        isLocationMenuExpanded = true
    }

    /// 화랑이가 실제로 그려지는 화면 점. 집에 있으면 집 핀(아바타 중심)이고, 아니면 위치 점이다.
    /// 집에 있을 때 위치 점은 집 반경 안 어딘가라 화랑이와 수십 pt 어긋날 수 있다(TAP1031A01 기기 로그).
    /// Apple 지도의 점은 걷는 화랑이 좌표(집에 있으면 집 핀)로 이미 투영돼 있다. 벡터 저장소의 점은
    /// 벡터 지도에서만 유효하므로 Apple 지도에서는 읽지 않는다(지난 재생 값이 남아 엉뚱한 곳을 가리킨다).
    var displayedCatViewportPoint: CGPoint? {
        guard rendersVectorMap else { return displayedStickmanViewportPoint }
        if isDisplayedCatAtHome,
           let home = model.settings.frequentPlaces.first(where: { $0.kind == .home }),
           let viewport = vectorMapViewportStore.viewport,
           let pin = vectorPoint(in: viewport, for: vectorPlaceMarkerID(home.id)) {
            return pin
        }
        return vectorMapViewportStore.livePoint
            ?? vectorMapViewportStore.stickmanPoint
            ?? displayedStickmanViewportPoint
    }

    /// 화랑이(집에 있으면 집 핀) 머리 위 카운터 창. 연봉과 나머지 카운터를 **한 상자**에 담는다.
    /// 업무 구간에서만 오르고, 재생 중에는 재생 시각까지 번 돈을 표시 간격 단위로 보여 준다.
    /// 창은 **스스로 박자**를 가진다 — 연봉 줄을 껐어도 나머지 숫자가 시간을 따라 움직인다.
    /// 재생·Apple 지도 이동 중에는 UIKit 뷰가 위치만 옮기고(PRF1101A01), 내용은 0.25초 박자로만 다시 만든다(PRF1101B01).
    func counterWindow(
        at anchor: CGPoint,
        tracksPlaybackPoint: Bool = false,
        tracksAppleCamera: Bool = false
    ) -> some View {
        let box = counterWindowFrame
        let channel = tracksPlaybackPoint && playbackDriver != nil ? vectorMapViewportStore.liveChannel
            : tracksAppleCamera && isAppleCameraMoving ? appleStickmanLivePoint.channel
            : nil
        return MapHomeLivePointFollower(
            channel: channel,
            attachment: tracksAppleCamera ? appleStickmanLivePoint.markerAttachment : nil,
            fallback: CGPoint(x: anchor.x, y: anchor.y - 8 - 160),
            offset: CGSize(width: 0, height: MapHomeStickmanAnnotationLayout.centerOffset.y - 42 - 8 - 160),
            knownContentSize: CGSize(width: 240, height: 320),
            onFrame: { box.hostFrame = $0 }
        ) {
            EquatableView(content: MapHomeCounterContentGate(playbackTick: MapHomeCounterBadgeThrottle.playbackTick(isPlaying: isDayPlaybackRunning), isCollapsed: isCounterCollapsed) {
                // 숨긴 동안은 아무것도 그리지 않고 누를 자리도 없다. 화랑이를 다시 누르면 나온다(CTR1107A01).
                if isCounterCollapsed {
                    Color.clear.frame(width: 0, height: 0).onAppear { box.contentSize = .zero }
                } else {
                    MapHomeCounterClock(isLive: isCounterLive) { now in
                        counterWindowContent(now: now)
                            .onGeometryChange(for: CGSize.self, of: \.size) { box.contentSize = $0 }
                    }
                }
            })
            .frame(width: 240, height: 320, alignment: .bottom)
        }
        .onDisappear { box.reset() }
        .allowsHitTesting(false)
        .zIndex(MapHomeLayerPriority.stickman)
    }

    /// 오늘을 보고 있거나 재생 중이면 카운터 값이 흐른다. 지난 날은 값이 변하지 않는다.
    var isCounterLive: Bool {
        isDayPlaybackRunning
            || MapHomeGrowthPolicy.localCalendar.isDateInToday(model.selectedDate)
    }

    /// 창에 넣을 값. `now`는 시계가 준 순간이라 연봉과 나머지 줄이 같은 박자로 갱신된다.
    @ViewBuilder
    func counterWindowContent(now: Date) -> some View {
        if let salaryLive, showsSalaryCounter {
            let tick = TimeInterval(max(1, salaryTickSeconds))
            let calendar = MapHomeGrowthPolicy.localCalendar
            let day = calendar.startOfDay(for: model.selectedDate)
            if let minute = counterCutoffMinute {
                let seconds = MapHomeSalaryPolicy.workSeconds(in: salaryWorkSpans[day] ?? [], until: day + minute * 60)
                counterTable(now: now, salarySeconds: MapHomeSalaryPolicy.quantized(seconds, tick: tick), isWorking: false)
            } else if calendar.isDateInToday(model.selectedDate) {
                counterTable(
                    now: now,
                    salarySeconds: MapHomeSalaryPolicy.liveWorkSeconds(
                        base: salaryLive.todayWorkSeconds,
                        baseDate: salaryLive.measuredAt,
                        isWorking: salaryLive.isWorking,
                        now: now,
                        tick: tick
                    ),
                    isWorking: salaryLive.isWorking
                )
            } else {
                let seconds = MapHomeSalaryPolicy.workSeconds(in: salaryWorkSpans[day] ?? [], until: .distantFuture)
                counterTable(now: now, salarySeconds: seconds, isWorking: false)
            }
        } else {
            counterTable(now: now, salarySeconds: nil, isWorking: false)
        }
    }

    /// 창에 넣을 값. 연봉이 없으면 나머지 카운터만 담는다.
    func counterTable(now: Date, salarySeconds: TimeInterval?, isWorking: Bool) -> some View {
        let salary = salarySeconds.flatMap { seconds in
            salaryLive.map { MapHomeCounterSalary.earned(seconds: seconds, hourlyRate: $0.hourlyRate, isWorking: isWorking, language: language) }
        }
        let allowance = !showsSalaryCounter ? nil : MapHomeAllowancePolicy.counterLine(
            day: model.selectedDate, playbackMinute: counterCutoffMinute,
            now: now, tick: TimeInterval(max(1, salaryTickSeconds)), language: language
        )
        let badges = mapCounterBadges(asOf: now)
        let targets = badges.map { MapHomeCounterDetailTarget.kind($0.kind) } + (allowance == nil ? [] : [.allowance]) + (salary == nil ? [] : [.salary])
        return MapHomeCounterTable(salary: salary, allowance: allowance, badges: badges, language: language, isPlaying: isDayPlaybackRunning)
            .onChange(of: targets, initial: true) { _, next in
                if counterRowTargets != next { counterRowTargets = next }
            }
    }

    /// 화랑이 위에 쌓아 보여 줄 카운터 값. 켠 것만, 값이 있는 것만 올린다.
    ///
    /// `now`는 창의 시계가 준 순간이다. 재생 중이면 재생 시각까지, 멈춰 있으면 지금까지로
    /// 잘라 센다. 이 값이 매번 새로 계산되더라도 분 버킷 캐시가 하루 전체 재계산을 막는다.
    func mapCounterBadges(asOf now: Date) -> [MapHomeCounterBadge] {
        let probe = MapHomePlaybackProbe.begin("counterBadges"); defer { MapHomePlaybackProbe.end(probe) }
        let key = MapHomeCounterBadgeThrottle.Key(
            revision: model.dayProjectionRevision,
            day: model.selectedDate,
            kinds: enabledCounterKinds,
            english: language == .english,
            handleMinute: isDayPlaybackRunning ? nil : selectedTimelineMinute
        )
        return counterBadgeThrottle.badges(
            key: key,
            isPlaying: isDayPlaybackRunning,
            uptime: ProcessInfo.processInfo.systemUptime
        ) { computeMapCounterBadges(asOf: now) }
    }

    func computeMapCounterBadges(asOf now: Date) -> [MapHomeCounterBadge] {
        let cutoff = counterCutoffDate
        let seconds = counterValueCache.categorySeconds(
            cutoff: cutoff,
            now: now,
            revision: model.dayProjectionRevision
        ) { daySummaryCategorySeconds(asOf: $0, now: now) }
        let steps = MapHomeCounterTimelinePolicy.stepCount(readings: currentDayReadings, cutoff: cutoff)
        let meters = MapHomeCounterTimelinePolicy.travelMeters(
            segments: displayDayDataSnapshot?.travel ?? [], cutoff: cutoff, day: selectedDaySpan)
        return enabledCounterKinds.compactMap { kind in
            counterText(kind, seconds: seconds, steps: steps, meters: meters, showsZero: cutoff != nil)
                .map { MapHomeCounterBadge(kind: kind, text: $0) }
        }
    }

    /// 재생 중이면 재생 시각, 아니면 사이드바 핸들 시각. 핸들을 놓아 둔 게 없으면 nil(하루 전체 합계).
    var counterCutoffMinute: Double? {
        isDayPlaybackRunning ? dayPlaybackCurrentMinute : selectedTimelineMinute.map(Double.init)
    }

    var counterCutoffDate: Date? {
        MapHomeCounterTimelinePolicy.cutoff(
            dayStart: MapHomeGrowthPolicy.localCalendar.startOfDay(for: model.selectedDate),
            minute: counterCutoffMinute
        )
    }

    func counterText(
        _ kind: MapHomeCounterKind,
        seconds categorySeconds: [String: TimeInterval],
        steps: Int?,
        meters: Double,
        showsZero: Bool
    ) -> String? {
        // 핸들·재생 시각을 움직이는 동안 0이라고 줄을 없애면 창이 들썩인다.
        switch kind {
        case .steps:
            guard showsZero || (steps ?? 0) > 0 else { return nil }
            return (steps ?? 0).formatted()
        case .distance:
            guard showsZero || meters > 0 else { return nil }
            return MapHomeDayTravelSummary.distanceText(meters)
        case .work, .study, .hobby, .exercise:
            // 켜 둔 시간 카운터는 위치와 상관없이 늘 보인다. 값이 없으면 0으로 보이고, 사라졌다 나타나지 않는다(대표 지시, ARC1030A07).
            guard let categoryID = kind.categoryID else { return nil }
            return DurationText.localized(max(0, categorySeconds[categoryID] ?? 0), english: language == .english)
        }
    }

    var menu: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea(edges: .top)
                    .contentShape(Rectangle())
                    .onTapGesture { isMenuOpen = false }

                let menuHeight = max(0, proxy.size.height)
                let menuTop = max(Layout.headerVisibleHeight, headerFrame.maxY)
                sidebarContent
                .frame(
                    width: Layout.menuWidth(for: proxy.size.width),
                    height: max(0, menuHeight - menuTop),
                    alignment: .top
                )
                .background(Color.tpSurface.opacity(0.62))
                .mapHomeGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.tpLine.opacity(0.6), lineWidth: 0.8)
                }
                .padding(.top, menuTop)
                // 왼쪽 가장자리에서 펼쳐져 오른쪽 시간 사이드바를 가리지 않는다.
                .padding(.leading, Layout.horizontalInset)
                .shadow(color: Color.black.opacity(0.18), radius: 22, x: 8, y: 0)
            }
        }
    }

    var sidebarContent: some View {
        ScrollView(showsIndicators: false) {
            MapHomeWidePanelColumns(columns: menuPanelKind.columns, spacing: 14, alignment: .leading, trailingTopInset: 0) {
            HStack(spacing: 12) {
                MapHomeMenuCatPicker(selected: model.selectedCatCoat, language: language) { model.selectCatCoat($0) }

                MapHomeMenuHeaderTitle(language: language)
                Button { isMenuOpen = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                        .foregroundStyle(Color.tpInk.opacity(0.7))
                        .frame(width: TaptionMenuMetrics.minimumHitSize, height: TaptionMenuMetrics.minimumHitSize)
                        .mapHomeGlass(in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("메뉴 닫기", "Close menu"))
            }
            .padding(.bottom, 8)

            if !sensorCollectionPermissionGate.sensorCollectionReady, menuPanelKind.columns == 1 {
                sensorPermissionCard
                    .padding(.bottom, 10)
            }

            menuGroupLabel(language.text("기록", "Record"))
            menuGroupCard {
                locationMenuItem
                menuGroupDivider
                categoryMenuItem
                menuGroupDivider
                // 등록 장소·랜드마크 도장을 모은 장소 도감(INK1108A01).
                menuRowButton("seal.fill", language.text("장소 도감", "Place book"), tint: .tpMenuChip(MapHomeInkWash.sealHex)) { isPlaceBookPresented = true }
                menuGroupDivider
                menuRowButton("book.closed.fill", language.text("여권", "Passport"), tint: .tpMenuChip(MapHomeInkWash.sealHex)) {
                    passportStartPage = 0
                    passportReturnPage = nil
                    isPassportPresented = true
                }
            }
            menuGroupLabel(language.text("화면", "View"))
            menuGroupCard {
                displayMenuItem
                menuGroupDivider
                MapHomeLanguageMenuItem(language: language) {
                    model.languagePreferenceDidChange()
                }
                menuGroupDivider
                if TaptionFont.isUserSelectable {
                    TaptionFontMenuRow(language: language)
                }
            }
            menuGroupLabel(language.text("연결", "Connections"))
            menuGroupCard {
                MapHomeAppleWatchMenuItem(model: model, language: language)
                menuGroupDivider
                menuRowButton("calendar.badge.plus", language.text("캘린더 연결", "Calendar"), tint: .tpMenuChip("#3E8FDC")) { isCalendarConnectPresented = true }
                menuGroupDivider
                // 차량 오디오(블루투스·CarPlay)가 연결된 이동은 자동차로 확정한다(CAR1029A01).
                menuRowButton("car.fill", language.text("내 차 등록", "My car"), tint: .tpMenuChip("#4F86B8")) { isCarAudioSheetPresented = true }
                // 「AI 연결」(AIR1110A03, 예전 AI 비서): AI별 연결·PIN·공유 수준. 중계 서버가 없으면 숨긴다.
                if TripRelay.isAvailable {
                    menuGroupDivider
                    menuRowButton("sparkles", language.text("AI 연결", "AI connections"), tint: .tpMenuChip("#7A6FD0")) { isAssistantPresented = true }
                }
            }
            } trailing: {
            if !sensorCollectionPermissionGate.sensorCollectionReady, menuPanelKind.columns > 1 { sensorPermissionCard.padding(.bottom, 10) }
            menuGroupLabel(language.text("앱", "App"))
            menuGroupCard {
                settingsMenuItem
                menuGroupDivider
                menuRowButton("bell.badge", language.text("알림", "Alerts"), tint: .tpMenuChip("#D9952B")) { isAlarmSettingsPresented = true }
                menuGroupDivider
                menuRowButton("photo.on.rectangle.angled", language.text("하루 카드", "Day card"), tint: .tpMenuChip("#D9627F")) { isDailyCardPresented = true }
                menuGroupDivider
                menuRowButton("info.circle", language.text("지도 출처", "Map attribution"), tint: .tpMenuChip("#8C8574")) { isMapAttributionPresented = true }
            }

            Spacer(minLength: 28)

            if TaptionCommercePolicy.supportsPaidPurchase {
                menuItem(
                    "sparkles",
                    proMenuTitle,
                    isSelected: proAccess.hasPermanentAccess
                ) {
                    proAccess.isPurchaseSheetPresented = true
                }
            }

            Divider()
                .padding(.vertical, 9)

            HStack(spacing: 8) {
                Circle()
                    .fill(currentCoordinate == nil ? Color.tpInk.opacity(0.3) : Color.tpAccent)
                    .frame(width: 7, height: 7)
                Text(
                    currentCoordinate == nil
                        ? language.text("위치 기록을 기다리는 중", "Waiting for location")
                        : language.text("현재 위치 기록 중", "Recording current location")
                )
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mapHomeGlass(in: Capsule())

            Divider()
                .padding(.vertical, 9)

            appVersionFooter
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(MapHomeScrollBounceDisabler())
    }

    /// 메인 메뉴 묶음 제목과 카드. 항목은 카드 안에서 얇은 구분선으로 나눈다.
    /// 표시 메뉴 안의 이동 항목: 아래 토글·선택 행과 같은 글자 크기·여백·아이콘 색으로 맞춘다.
    /// 드롭다운 행: 제목과 현재 값, 위아래 화살표. 다른 메뉴 행과 같은 크기를 쓴다.
    /// 표시 > 사이드바: 사이드바에 함께 그려지는 항목과 시각 표시를 한 묶음으로 둔다(대표 지시, UIX1101A02).
    var sidebarDisplayGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            displayGroupHeader(language.text("사이드바", "Sidebar"), systemImage: "sidebar.right", isExpanded: $isSidebarGroupExpanded)
            if isSidebarGroupExpanded {
                displayToggle(
                    language.text("날씨", "Weather"),
                    systemImage: "cloud.sun.fill",
                    isOn: Binding(
                        get: { model.settings.weatherSidebarVisible },
                        set: { model.setWeatherSidebarVisible($0) }
                    )
                )
                displayToggle(
                    language.text("메모 표시", "Show memos"),
                    systemImage: "note.text",
                    isOn: Binding(
                        get: { memoDisplayMode != .hidden },
                        set: { memoDisplayRaw = ($0 ? MapHomeMemoDisplayMode.all : .hidden).rawValue }
                    )
                )
                Menu {
                    Picker("", selection: $sidebarTimeFormatRaw) {
                        ForEach(MapHomeSidebarTimeFormat.allCases) { format in
                            Text(format.title(language)).tag(format.rawValue)
                        }
                    }
                } label: {
                    displayDropdownRow(
                        "clock",
                        language.text("시간 표시", "Time format"),
                        (MapHomeSidebarTimeFormat(rawValue: sidebarTimeFormatRaw) ?? .twentyFourHour).title(language)
                    )
                }
                .padding(.vertical, 3)
            }
        }
    }

    func displayDropdownRow(_ systemImage: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                .foregroundStyle(Color.tpInk)
            Spacer()
            Text(value)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.tpAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }

    func displaySubRow(_ systemImage: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                .foregroundStyle(Color.tpInk)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }

    /// 메뉴 한 줄: 아이콘 상자 + 제목 + 오른쪽 화살표. 지도 출처와 같은 모양이다.
    func menuRowButton(
        _ systemImage: String,
        _ title: String,
        tint: Color = .tpAccent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                MapHomeMenuIconChip(systemImage: systemImage, tint: tint)
                Text(title)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.tpInk)
            .modifier(MapHomeMenuRowPadding())
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func menuGroupLabel(_ title: String) -> some View {
        Text(title)
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
            .foregroundStyle(Color.tpSecondary)
            .modifier(MapHomeMenuGroupLabelPadding())
            .padding(.bottom, 6)
            .padding(.horizontal, 6)
    }

    func menuGroupCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.vertical, 2)
        .background(Color.tpSurface.opacity(0.78), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.tpLine.opacity(0.7), lineWidth: 0.8)
        }
    }

    var menuGroupDivider: some View {
        Divider()
            .overlay(Color.tpLine.opacity(0.7))
            .padding(.leading, 57)
            .padding(.trailing, 12)
    }

    var categoryMenuItem: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                isCategoryMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    MapHomeMenuIconChip(systemImage: "paintpalette.fill", tint: .tpMenuChip("#9A5B8F"))
                    Text(language.text("행동 분류", "Activity categories"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                    Spacer()
                    Image(systemName: isCategoryMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.tpInk)
                .modifier(MapHomeMenuRowPadding())
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("행동 분류 목록", "Activity category list"))

            if isCategoryMenuExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(
                        MapHomeSidebarMajorCategory.all(
                            categoryColors: model.settings.mapCategoryColors
                        )
                    ) { category in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 9) {
                                Circle()
                                    .fill(category.tint)
                                    .frame(width: 10, height: 10)
                                MapHomeStickmanGlyph(
                                    action: category.stickmanAction,
                                    size: 36,
                                    equippedAccessoryID: homeGrowthHistory.season.equippedAccessory
                                )
                                .frame(width: 60, height: MapHomeGrowthAccessoryCatalog.hatAssetName(for: homeGrowthHistory.season.equippedAccessory) == nil ? 46 : 60)
                                .clipped()
                                Text(category.localizedTitle(language))
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                                Spacer()
                                if !MapHomeCategoryDetailRows.details(for: category.id).isEmpty {
                                    Button {
                                        if expandedCategoryDetails.insert(category.id).inserted == false {
                                            expandedCategoryDetails.remove(category.id)
                                        }
                                    } label: {
                                        Image(systemName: expandedCategoryDetails.contains(category.id) ? "chevron.up" : "chevron.down")
                                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 32, height: 32)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(language.text(
                                        "\(category.localizedTitle(language)) 상세 분류",
                                        "\(category.localizedTitle(language)) details"
                                    ))
                                }
                                Button {
                                    if activePaletteCategoryID == category.id {
                                        activePaletteCategoryID = nil
                                    } else {
                                        customPaletteColor = Color(
                                            hex: model.settings.mapCategoryColors[category.id]
                                                ?? category.hex
                                        )
                                        activePaletteCategoryID = category.id
                                    }
                                } label: {
                                    Circle()
                                        .fill(category.tint)
                                        .frame(width: 23, height: 23)
                                        .overlay {
                                            Image(systemName: activePaletteCategoryID == category.id
                                                ? "chevron.up"
                                                : "paintpalette.fill")
                                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    language.text(
                                        "\(category.localizedTitle(language)) 색상 팔레트",
                                        "\(category.localizedTitle(language)) color palette"
                                    )
                                )
                            }
                            if expandedCategoryDetails.contains(category.id) {
                                MapHomeCategoryDetailRows(categoryID: category.id, language: language, accessoryID: homeGrowthHistory.season.equippedAccessory)
                            }
                            if activePaletteCategoryID == category.id {
                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6),
                                    spacing: 6
                                ) {
                                    ForEach(Self.categoryPaletteHexes, id: \.self) { hex in
                                        Button {
                                            model.setMapCategoryColor(hex, for: category.id)
                                            activePaletteCategoryID = nil
                                        } label: {
                                            Circle()
                                                .fill(Color(hex: hex))
                                                .frame(width: 22, height: 22)
                                                .overlay {
                                                    Circle()
                                                        .stroke(.white.opacity(0.9), lineWidth: 1)
                                                }
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(language.text("색상 선택", "Choose color"))
                                    }

                                    ColorPicker(
                                        language.text("사용자 지정", "Custom"),
                                        selection: Binding(
                                            get: { customPaletteColor },
                                            set: { color in
                                                customPaletteColor = color
                                                if let hex = color.hexRGBString {
                                                    model.setMapCategoryColor(hex, for: category.id)
                                                }
                                            }
                                        ),
                                        supportsOpacity: false
                                    )
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold))
                                    .frame(maxWidth: .infinity, minHeight: 28)
                                    .padding(.horizontal, 5)
                                    .background(Color.tpInk.opacity(0.07), in: Capsule())
                                    .accessibilityLabel(
                                        language.text("사용자 지정 색상", "Custom category color")
                                    )
                                }
                                .padding(.leading, 39)
                                .padding(.bottom, 4)
                            }
                        }
                        .foregroundStyle(Color.primary)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            category.tint.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .accessibilityElement(children: .contain)
                    }

                    Button {
                        isCategoryAddPresented = true
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                            Text(language.text("사용자 추가", "Add custom"))
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                            Spacer()
                        }
                        .foregroundStyle(Color.tpReferenceBlue)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.plain)

                    ForEach(model.settings.mapUserActivityCategories) { category in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 9) {
                                Circle()
                                    .fill(Color(hex: category.hex))
                                    .frame(width: 10, height: 10)
                                TaptionCuteIcon(category.systemImage, size: 18)
                                    .foregroundStyle(Color(hex: category.hex))
                                    .frame(width: 20)
                                Text(category.title)
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                                Spacer()
                                Button {
                                    editingUserCategory = category
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                                        .foregroundStyle(Color.tpSecondary)
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(language.text("\(category.title) 수정", "Edit \(category.title)"))
                                Button {
                                    if activePaletteCategoryID == category.id.uuidString {
                                        activePaletteCategoryID = nil
                                    } else {
                                        customPaletteColor = Color(hex: category.hex)
                                        activePaletteCategoryID = category.id.uuidString
                                    }
                                } label: {
                                    Image(systemName: "paintpalette.fill")
                                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                                        .foregroundStyle(Color(hex: category.hex))
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(language.text("\(category.title) 색상 팔레트", "\(category.title) color palette"))
                            }
                            if activePaletteCategoryID == category.id.uuidString {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                                    ForEach(Self.categoryPaletteHexes, id: \.self) { hex in
                                        Button {
                                            model.setMapCategoryColor(hex, for: category.id.uuidString)
                                            activePaletteCategoryID = nil
                                        } label: {
                                            Circle().fill(Color(hex: hex)).frame(width: 22, height: 22)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    ColorPicker(language.text("사용자 지정", "Custom"), selection: Binding(
                                        get: { customPaletteColor },
                                        set: { color in
                                            customPaletteColor = color
                                            if let hex = color.hexRGBString {
                                                model.setMapCategoryColor(hex, for: category.id.uuidString)
                                            }
                                        }
                                    ), supportsOpacity: false)
                                    .frame(minHeight: 28)
                                }
                                .padding(.leading, 39)
                            }
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 8)
                        .background(
                            Color.tpReferenceMint.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                    }
                }
                .padding(.leading, 12)
                Text(language.text("색상을 선택하면 즉시 저장됩니다.", "Colors save immediately."))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10.5)), weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
    }

    var locationMenuItem: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                isLocationMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    MapHomeMenuIconChip(systemImage: "mappin.and.ellipse", tint: .tpMenuChip("#C8553D"))
                    Text(language.text("위치", "Location"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                    Spacer()
                    Image(systemName: isLocationMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.tpInk)
                .modifier(MapHomeMenuRowPadding())
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("위치 목록", "Location list"))

            if isLocationMenuExpanded {
                VStack(spacing: 5) {
                    userLocationsMenuItem
                    ForEach(MapHomeLocationDestination.allCases.filter { $0 != .user }) { destination in
                        locationDestinationRow(destination)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    var userLocationsMenuItem: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                isUserLocationsMenuExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    MapHomeLocationThumbnail(
                        destination: .user,
                        size: 34
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text("사용자", "User"))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                        Text(
                            language.text(
                                "등록된 사용자 위치 \(userLocationCount)개",
                                "\(userLocationCount) saved user locations"
                            )
                        )
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10.5)), weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isUserLocationsMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.primary)
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
                .background(
                    Color.tpReferenceRose.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                language.text("사용자 위치 목록", "User location list")
            )

            if isUserLocationsMenuExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if userLocationCount == 0 {
                        Text(language.text("등록된 사용자 위치가 없습니다.", "No saved user locations."))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                    }

                    ForEach(userFrequentPlaces) { place in
                        userFrequentPlaceRow(place)
                    }
                    ForEach(model.settings.userTransitLocations) { location in
                        userTransitLocationRow(location)
                    }

                    Button {
                        isTransitLocationsPresented = true
                        isMenuOpen = false
                    } label: {
                        Label(
                            language.text("사용자 위치 관리", "Manage user locations"),
                            systemImage: "slider.horizontal.3"
                        )
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11.5)), weight: .semibold))
                        .foregroundStyle(Color.tpReferenceBlue)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 12)
            }
        }
    }

    var displayMenuItem: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                isDisplayMenuExpanded.toggle()
            } label: {
                HStack(spacing: 13) {
                    MapHomeMenuIconChip(systemImage: "square.3.layers.3d", tint: .tpMenuChip("#C98A3F"))
                    Text(language.text("표시", "Display"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                    Spacer()
                    Image(systemName: isDisplayMenuExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.tpInk)
                .modifier(MapHomeMenuRowPadding())
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isDisplayMenuExpanded {
                // 지도 스타일을 맨 위에 둔다. 드롭다운은 같은 행 모양으로 통일한다.
                Menu {
                    // 판타지 지도를 맨 위에 두고, 나머지 벡터 스타일, Apple 스타일 순으로 보여 준다(대표 지시, ARC1030A04).
                    ForEach(MapDisplayStyle.openFreeMapStyles + MapDisplayStyle.appleStyles, id: \.self) { style in
                        Button {
                            model.setMapDisplayStyle(style)
                        } label: {
                            Label(mapStyleTitle(style), systemImage: mapStyleSystemImage(style))
                        }
                    }
                } label: {
                    displayDropdownRow(
                        "map.fill",
                        language.text("지도 스타일", "Map style"),
                        mapStyleTitle(model.settings.mapDisplayStyle)
                    )
                }
                .accessibilityLabel(language.text("지도 스타일 선택", "Choose map style"))

                // 안개 탐험은 지도 스타일 바로 아래에 둔다(대표 지시, ARC1030A11).
                Menu {
                    ForEach(MapHomeFogStrength.allCases) { strength in
                        Button(language.runtimeText(strength.koreanLabel, strength.englishLabel)) {
                            fogStrengthRaw = strength.rawValue
                        }
                    }
                } label: {
                    displayDropdownRow(
                        "cloud.fog.fill",
                        language.text("안개 탐험", "Fog of Exploration"),
                        language.runtimeText(fogStrength.koreanLabel, fogStrength.englishLabel)
                    )
                }
                .accessibilityLabel(language.text("안개 탐험 선택", "Choose fog of exploration"))

                counterMenuItem
                sidebarDisplayGroup
                mapDisplayGroup
            }
        }
    }

    /// 카운터처럼 펼치고 닫는 표시 그룹의 머리 줄.
    func displayGroupHeader(_ title: String, systemImage: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            isExpanded.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                Spacer()
                Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func displayToggle(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
        }
        .tint(Color.tpReferenceBlue)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }
}
