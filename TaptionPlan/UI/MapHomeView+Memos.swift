import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

extension MapHomeView {
    var mapStickersOnMap: [MapSticker] {
        MapStickerDisplayFilterEngine.visibleMapStickers(
            model.snapshot.stickers,
            on: model.selectedDate
        ).filter { $0.point.map(isValid) == true }
    }

    var mapMemosOnMap: [ActionMemo] {
        // 재생 중 메모는 지도 대신 상단 알림으로 나온다.
        guard memoDisplayMode != .hidden, !isDayPlaybackRunning else { return [] }
        return MapMemoDisplayFilterEngine.visibleMemos(
            model.snapshot.memos,
            on: model.selectedDate,
            filter: model.settings.mapMemoDisplayFilter,
            selectedPlanIDs: mapMemoRelevantPlanIDs,
            selectedTargetIDs: []
        )
        .filter { $0.mapPoint.map(isValid) == true }
        .sorted {
            if $0.occurredAt != $1.occurredAt {
                return $0.occurredAt < $1.occurredAt
            }
            return $0.createdAt < $1.createdAt
        }
    }

    var mapMemoRelevantPlanIDs: Set<UUID> {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: model.selectedDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        return Set(
            model.snapshot.plans
                .filter { $0.span.start < end && $0.span.end > start }
                .map(\.id)
        )
    }

    /// 선택한 날의 시간 메모 목록을 한 번만 계산해 둔다(배지마다 전체 메모를 다시 훑지 않도록).
    func refreshTimedMemoCache() {
        timedMemoCache = model.snapshot.memos.filter {
            $0.isTimeless != true
                && !model.isMemoDraft($0.id)
                && Self.hasText($0)
                && Calendar.autoupdatingCurrent.isDate($0.occurredAt, inSameDayAs: model.selectedDate)
        }
    }

    var scheduleStickersForSelectedDate: [MapSticker] {
        model.snapshot.stickers.filter {
            $0.placement == .schedule
                && Calendar.autoupdatingCurrent.isDate(
                    $0.occurredAt,
                    inSameDayAs: model.selectedDate
                )
        }
    }

    var selectedSchedulePlanIDs: Set<UUID> {
        let selectedDate = timelineSelectionDate
        return Set(
            model.snapshot.plans
                .filter { $0.span.start <= selectedDate && selectedDate < $0.span.end }
                .map(\.id)
        )
    }

    /// 사이드바(선택 시각, 없으면 지금)가 일정 메모 시각의 앞뒤 30분 안에 오면 보여 주는 메모. 가장 가까운 하나.
    var nearbyScheduleMemo: MapSticker? {
        MapHomeMemoPreviewPolicy.nearest(
            in: model.snapshot.stickers,
            at: timelineSelectionDate,
            selectedDate: model.selectedDate,
            dismissed: dismissedMemoPreviewIDs
        )
    }

    func scheduleMemoPreview(_ memo: MapSticker) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: memo.systemImage)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                .foregroundStyle(Color(hex: memo.colorHex))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.96), in: Circle())
                .overlay(Circle().stroke(Color(hex: memo.colorHex), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(memo.title)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                    .lineLimit(1)
                if let text = memo.memo, !text.isEmpty {
                    Text(text)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                        .foregroundStyle(Color.tpSecondary)
                        .lineLimit(2)
                }
                Text(memo.occurredAt.formatted(date: .omitted, time: .shortened))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            }
            .foregroundStyle(Color.tpInk)
            Spacer(minLength: 4)
            Button {
                dismissedMemoPreviewIDs.insert(memo.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("닫기", "Dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 280, alignment: .leading)
        .background(Color.tpSurface.opacity(0.97), in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous)
                .stroke(Color.tpBorder, lineWidth: TaptionBorder.width)
        }
        .taptionShadow(.floating)
        .contentShape(Rectangle())
        .onTapGesture { selectedMapStickerEditor = .sticker(memo.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(language.text("일정 메모 \(memo.title)", "Schedule memo \(memo.title)"))
        .transition(.opacity)
    }

    /// 시간을 지정하지 않았고 위치도 없는 메모: 왼쪽 위에 큐처럼 쌓인다(오래된 것이 위).
    /// 선택한 날짜의 메모(시각 있는 메모 + 시각 없이 그날 만든 메모, 지도 메모 포함). 시각 없는 메모가 위, 그 다음 시각 순.
    var queuedMemos: [ActionMemo] {
        let calendar = Calendar.autoupdatingCurrent
        func onSelectedDay(_ date: Date) -> Bool { calendar.isDate(date, inSameDayAs: model.selectedDate) }
        return model.snapshot.memos
            .filter { memo in
                guard !model.isMemoDraft(memo.id), Self.hasText(memo) else { return false }
                return memo.isTimeless == true ? onSelectedDay(memo.createdAt) : onSelectedDay(memo.occurredAt)
            }
            .sorted { lhs, rhs in
                let lhsTimed = lhs.isTimeless != true, rhsTimed = rhs.isTimeless != true
                if lhsTimed != rhsTimed { return !lhsTimed }
                return lhsTimed ? lhs.occurredAt < rhs.occurredAt : lhs.createdAt < rhs.createdAt
            }
    }

    /// 시간은 있고 위치는 없는 메모: 사이드바 시각이 앞뒤 30분 안이면 가장 가까운 하나를 보여 준다.
    var nearbyTimedMemo: ActionMemo? {
        let calendar = Calendar.autoupdatingCurrent
        let center = timelineSelectionDate
        return model.snapshot.memos
            .filter {
                $0.isTimeless != true && $0.mapPoint == nil && !model.isMemoDraft($0.id)
                    && Self.hasText($0) && !dismissedMemoPreviewIDs.contains($0.id)
                    && calendar.isDate($0.occurredAt, inSameDayAs: model.selectedDate)
                    && abs($0.occurredAt.timeIntervalSince(center)) <= 15 * 60
                    && $0.planID == nil
            }
            .min { abs($0.occurredAt.timeIntervalSince(center)) < abs($1.occurredAt.timeIntervalSince(center)) }
    }

    /// 화면에 쓸 일정. 아직 다른 날짜의 목록을 들고 있으면(날짜를 막 바꾼 직후) 빈 목록으로
    /// 두어 이전 날짜 일정이 좌측 상단·사이드바에 남지 않게 한다.
    var dayCalendarEventsForSelectedDate: [CalendarRecord] {
        guard let day = dayCalendarEventsDate,
              Calendar.autoupdatingCurrent.isDate(day, inSameDayAs: model.selectedDate) else {
            return []
        }
        return dayCalendarEvents
    }

    /// 선택한 날의 일정을 불러온다. 구글 계정이 연결돼 있으면 구글에서, 아니면 기기 캘린더에서 읽는다.
    func loadDayCalendarEvents() async {
        let day = model.selectedDate
        let calendar = Calendar.autoupdatingCurrent
        // 날짜를 바꾼 직후에는 이전 날짜 목록을 즉시 내린다.
        if let loaded = dayCalendarEventsDate, !calendar.isDate(loaded, inSameDayAs: day) {
            dayCalendarEvents = []
            dayCalendarEventsDate = nil
        }
        let (loaded, problem) = await MapHomeDayCalendarLoader.events(on: day, calendar: calendar, service: calendarService)
        // 날짜를 빠르게 넘기면 이전 날짜의 늦은 응답이 올 수 있으므로 지금 날짜와 같을 때만 반영한다.
        guard calendar.isDate(day, inSameDayAs: model.selectedDate) else { return }
        dayCalendarEvents = loaded
        dayCalendarEventsDate = day
        if calendarAccessProblem != problem { calendarAccessProblem = problem }
        if problem == nil { await model.applyDayCalendarEvents(loaded, on: day, fromGoogle: GoogleCalendarAccount.shared.isConnected) }
    }

    /// 할 일 목록 패널(TDP1113A01): 확인할 것·일정·메모·지출·AI를 한 판에 모은다. 폭은 280.
    var memoListPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            LedgerMemoHeader(filter: $memoLedgerFilter, linkedMemoIDs: $memoLedgerLinkedIDs, language: language, day: model.selectedDate)
            switch memoLedgerFilter {
            case .today:
                EmptyView()
            case .ai:
                AITaskPanel(language: language)
            case .check:
                todoCheckRows(showsEmpty: true)
            case .schedule:
                ForEach(dayPlans) { plan in planCard(plan) }
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
                    },
                    width: todoPanelWidth - 16
                )
            case .memos:
                if let legacy = nearbyScheduleMemo { scheduleMemoPreview(legacy) }
                let rows = todoPanelRows
                // 처음에는 4줄, 넘치면 펼침 단추로 스크롤 목록을 연다.
                if queueExpanded {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(rows) { todoPanelRow($0) }
                        }
                    }
                    .refreshable { await AssistantCommandRefresh.now(language: language, manual: true) }
                    .frame(maxHeight: 360)
                } else {
                    ForEach(rows.prefix(Self.todoPanelCollapsedRows)) { todoPanelRow($0) }
                }
                if rows.count > Self.todoPanelCollapsedRows {
                    Button {
                        withAnimation(.snappy) { queueExpanded.toggle() }
                    } label: {
                        Label(
                            queueExpanded ? language.text("접기", "Collapse") : "+\(rows.count - Self.todoPanelCollapsedRows)",
                            systemImage: queueExpanded ? "chevron.up" : "chevron.down"
                        )
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .mapHomeGlass(in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // 목록 전체를 한 판으로 감싼다(MBG1111A01). 바깥 폭은 280.
        .frame(width: todoPanelWidth - 16, alignment: .leading)
        .padding(8)
        .background(Color.tpBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: TaptionCorner.large, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: TaptionCorner.large, style: .continuous).stroke(Color.tpBorder, lineWidth: TaptionBorder.width) }
        .taptionShadow(.floating)
    }

    static let todoPanelCollapsedRows = 4

    /// 늘 왼쪽 위에 떠 있는 판의 폭(TDW1114A01): 오른쪽에 단추 한 줄과 날짜 배지가 들어갈 자리를 남긴다. 넓은 화면은 280.
    var todoPanelWidth: CGFloat {
        guard mapViewportSize.width > 0 else { return 280 }
        return min(280, max(220, mapViewportSize.width - Layout.horizontalInset - 8 - 44 - 8 - 64))
    }

    /// 메모를 지도에 보이게 한 설정에서만 메모 카드를 패널에 넣는다.
    var todoPanelShowsMemos: Bool { recordingShows(\.sidebarMemos) && memoDisplayMode == .all }

    var dayPlans: [PlanRecord] { MapHomeTodoPanelRow.plans(model.snapshot.plans, on: model.selectedDate) }

    /// 「전체」·「메모」 줄. 「전체」는 메모·일정·앱 계획·메모로 넣지 않은 지출을 시간순으로 섞는다.
    var todoPanelRows: [MapHomeTodoPanelRow] {
        var memos = todoPanelShowsMemos ? panelMemos : []
        // 지금 시각 근처 메모가 목록에 없으면 함께 보인다.
        if todoPanelShowsMemos, let timed = nearbyTimedMemo, !memos.contains(where: { $0.id == timed.id }) { memos.append(timed) }
        let rows = memos.map(MapHomeTodoPanelRow.memo)
        return MapHomeTodoPanelRow.ordered(rows)
    }

    @ViewBuilder
    func todoPanelRow(_ row: MapHomeTodoPanelRow) -> some View {
        switch row {
        case .memo(let memo):
            memoCard(memo, showsTime: memo.isTimeless != true)
        case .event(let event):
            MapHomeTodoScheduleCard(systemImage: "calendar", title: event.title,
                                    time: MapHomeTodoScheduleCard.time(event.span, allDay: event.isAllDay, language: language))
                .contentShape(Rectangle())
                .onTapGesture { memoLedgerFilter = .schedule }
                .accessibilityAddTraits(.isButton)
        case .plan(let plan):
            planCard(plan)
        case .expense(let entry):
            Button { LedgerPresenter.shared.isPresented = true } label: { LedgerMemoCard(entry: entry, language: language) }
                .buttonStyle(.plain)
        }
    }

    func planCard(_ plan: PlanRecord) -> some View {
        MapHomeTodoScheduleCard(systemImage: "checkmark.circle", title: plan.title,
                                time: MapHomeTodoScheduleCard.time(plan.span, allDay: false, language: language))
    }

    @ViewBuilder
    func todoCheckRows(showsEmpty: Bool) -> some View {
        if todoItems.isEmpty {
            if showsEmpty {
                Text(language.text("지금 확인할 것이 없어요.", "Nothing to check right now."))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .regular))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
            }
        } else {
            let canUseAI = MemoPolishQueue.hasConnection()
            MapHomeTodoRows(language: language, items: todoItems, canUseAI: canUseAI) { prompt in
                UserDefaults.standard.set("", forKey: MapHomeLaunchPromptDeferral.key)
                withAnimation(.snappy) { memoStackExpanded = false }
                presentLaunchPrompt(prompt)
            } onHandOff: { prompt in
                guard let task = MapHomeLaunchPromptHandoff.task(for: prompt),
                      AITaskQueue.enqueue(task.kind, text: task.text, day: .now) else { return false }
                MapHomeLaunchPromptHandoff.markHanded(prompt.id)
                return true
            }
            if memoLedgerFilter == .check {
                Text(MapHomeTodoRows.footer(canUseAI: canUseAI, language: language))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .regular))
                    .foregroundStyle(Color.tpSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// 할 일 목록 단추: 닫혀 있으면 확인할 것을 읽고 연다(있으면 「확인」 탭, 없으면 「전체」).
    func toggleTodoPanel() {
        if memoStackExpanded {
            withAnimation(.snappy) { memoLedgerFilter = .today }
            return
        }
        Task {
            let items = await launchPromptQueue()
            todoItems = items
            withAnimation(.snappy) { memoLedgerFilter = items.isEmpty ? .memos : .check }
        }
    }

    /// 다른 곳(왼쪽 위 미리보기)에서 정한 탭으로 연다.
    func openTodoPanel(_ filter: LedgerMemoFilter) {
        memoLedgerFilter = filter
        withAnimation(.snappy) { memoStackExpanded = true }
        Task { todoItems = await launchPromptQueue() }
    }

    /// 그날 메모 수. 지금 시각 근처 메모는 목록에도 들어 있으므로 ID로 합쳐 한 번만 센다.
    var todoMemoCount: Int {
        guard todoPanelShowsMemos else { return 0 }
        return Set(queuedMemos.map(\.id) + [nearbyTimedMemo?.id].compactMap { $0 }).count
    }

    func memoCard(_ memo: ActionMemo, showsTime: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StickerGlyph(symbol: memo.iconSymbol(fallback: showsTime ? "clock.fill" : "note.text"), colorHex: memo.iconColorHex, size: 24)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                .foregroundStyle(Color.tpReferenceBlue)
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.9), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(memo.text)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(2)
                LedgerMemoBadge(memoID: memo.id, language: language)
                if showsTime {
                    Text(memo.occurredAt.formatted(date: .omitted, time: .shortened))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .regular))
                        .foregroundStyle(Color.tpSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .mapHomeGlass(in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { selectedMapStickerEditor = .memo(memo.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(language.text("메모 \(memo.text)", "Memo \(memo.text)"))
    }

    /// 새 메모: 먼저 임시 초안을 만들고 편집 화면을 연다. 위치·시간은 편집 화면에서 정한다.
    /// 메모 추가: 시각은 지금, 위치는 현재 위치(없으면 위치 없이). 사용자가 시각을 바꾸고 위치는 뺄 수 있다.
    func addMemo() {
        isMenuOpen = false
        // 기본 일시는 지금 보고 있는 날짜와 사이드바 시간(날짜를 바꾸거나 사이드바를 옮긴 값)이다.
        let now = timelineSelectionDate
        let here = currentCoordinate.map {
            GeoPoint(latitude: $0.latitude, longitude: $0.longitude, altitude: 0, horizontalAccuracy: 0, verticalAccuracy: 0)
        }
        guard let id = model.addMemoDraft(
            text: language.text("새 메모", "New memo"),
            occurredAt: now,
            mapPoint: here,
            isTimeless: false
        ) else { return }
        selectedMapStickerEditor = .newMemo(id)
    }

    /// 편집 화면에서 "위치 추가": 편집 화면을 닫고 지도에서 핀을 고르게 한 뒤 다시 편집 화면으로 돌아온다.
    func beginMemoLocationPick(_ id: UUID) {
        pendingMemoLocationID = id
        isMenuOpen = false
        isPlacingMapMemo = true
    }

    func finishMemoLocationPick(apply: Bool) {
        guard let id = pendingMemoLocationID else { return }
        pendingMemoLocationID = nil
        if apply, let center = mapCenterPoint {
            let point = GeoPoint(
                latitude: center.latitude,
                longitude: center.longitude,
                altitude: 0,
                horizontalAccuracy: 0,
                verticalAccuracy: 0
            )
            if model.isMemoDraft(id) {
                model.updateMemoDraft(id, text: nil, occurredAt: nil, isTimeless: nil, mapPoint: .some(point))
            } else if let memo = model.snapshot.memos.first(where: { $0.id == id }) {
                _ = model.updateMapMemo(
                    id,
                    text: memo.text,
                    kind: memo.kind,
                    mapPoint: point,
                    occurredAt: memo.occurredAt,
                    isTimeless: memo.isTimeless == true
                )
            }
        }
        selectedMapStickerEditor = model.isMemoDraft(id) ? .newMemo(id) : .memo(id)
    }

    /// 위치 고르기: 지도 가운데에 핀을 두고 지도를 움직여 맞춘다. 취소·확인 버튼은 핀 바로 아래에 붙어 함께 떠 있다.
    var mapMemoPlacementOverlay: some View {
        ZStack {
            VStack {
                Text(language.text("지도를 움직여 핀 위치를 맞추세요", "Move the map to place the pin"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .mapHomeGlass(in: Capsule())
                    .padding(.top, 10)
                    .allowsHitTesting(false)
                Spacer()
            }
            ZStack {
                MapHomePlacementPin()
                    .offset(y: -MapHomePlacementPin.height / 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                HStack(spacing: 10) {
                    Button {
                        isPlacingMapMemo = false
                        if pendingMemoLocationID != nil { finishMemoLocationPick(apply: false) }
                    } label: {
                        Text(language.text("취소", "Cancel"))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                            .foregroundStyle(Color.tpInk)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 40)
                            .mapHomeGlass(in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        isPlacingMapMemo = false
                        if pendingMemoLocationID != nil {
                            finishMemoLocationPick(apply: true)
                        } else {
                            addMapMemo()
                        }
                    } label: {
                        Text(pendingMemoLocationID != nil
                             ? language.text("이 위치로", "Use this spot")
                             : language.text("여기에 메모", "Memo here"))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 40)
                            .background(Color.tpReferenceBlue, in: Capsule())
                            .shadow(color: Color.tpReferenceBlue.opacity(0.35), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                }
                .offset(y: 34)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func addMapMemo() {
        guard let point = mapCenterPoint else { return }
        addMapMemo(
            at: CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
        )
    }

    func addMapMemo(at coordinate: CLLocationCoordinate2D) {
        let point = GeoPoint(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            altitude: 0,
            horizontalAccuracy: 0,
            verticalAccuracy: 0
        )
        // 위치 메모의 기본 일시는 지금 보고 있는 날짜와 사이드바 시간이다.
        let occurredAt = timelineSelectionDate
        let planID = MapMemoLinkEngine
            .plan(containing: occurredAt, in: model.snapshot.plans)?.id
        guard let id = model.addMapMemo(
            text: language.text("새 지도 메모", "New map memo"),
            kind: .idea,
            mapPoint: point,
            planID: planID,
            occurredAt: occurredAt,
            shouldPersist: false
        ) else { return }
        isMenuOpen = false
        selectedMapStickerEditor = .newMemo(id)
    }

    /// 타일을 추가할 때 애플 지도 스타일이면 벡터 스타일로 바꾸고, 다 붙이거나 집에서 벗어나면 원래 스타일로 되돌린다.
    /// 사용자가 그 사이에 직접 스타일을 바꿨다면 되돌리지 않는다.
    func toggleSidebarNote(_ note: MapHomeSidebarNote) {
        sidebarNote = sidebarNote?.id == note.id ? nil : note
    }

    func vectorMapStickerMarkerID(_ id: UUID) -> String {
        "map-sticker-\(id.uuidString)"
    }

    func vectorMapMemoMarkerID(_ id: UUID) -> String {
        "map-memo-\(id.uuidString)"
    }

    /// 선택한 날의 메모 수: 시각이 있는 메모는 그 날짜, 시각이 없는 메모는 만든 날짜로 센다. 지도에 찍은 메모는 따로 센다.
    var dayMemoCounts: (total: Int, map: Int) {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: model.selectedDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let memos = model.snapshot.memos.filter { memo -> Bool in
            let when: Date = (memo.isTimeless == true) ? memo.createdAt : memo.occurredAt
            return when >= start && when < end
        }
        return (memos.count, memos.filter { $0.mapPoint != nil }.count)
    }

    /// 달력 지표 합계. 사진 수는 비싸고 천천히 바뀌어 `includePhotos`가 true일 때만 읽는다.
    func calendarTimeTotals(month: Date, includePhotos: Bool) async -> [Date: [String: TimeInterval]] {
        let actuals = model.snapshot.actuals
        let travel = model.snapshot.travel
        let stays = model.snapshot.places
        let placeKinds = FrequentPlaceResolutionEngine().kindsByPlaceKey(
            model.snapshot.settings.frequentPlaces
        )
        let sealedDays = model.sealedDays
        var result = await Task.detached(priority: .utility) {
            MapHomeCalendarTimeTotalsPolicy.totals(
                actuals: actuals,
                travel: travel,
                stays: stays,
                placeKinds: placeKinds,
                month: month,
                asOf: .now,
                calendar: MapHomeGrowthPolicy.localCalendar,
                sealed: sealedDays
            )
        }.value
        // 걸음 수·사진 수는 사용자가 "+"로 켠 때만 읽는다(건강·사진 접근 비용을 아끼기 위해).
        let enabled = MapHomeCalendarTimeKind.enabledExtras(
            from: UserDefaults.standard.string(forKey: MapHomeCalendarTimeKind.extraStorageKey) ?? ""
        )
        if enabled.contains(.steps) || enabled.contains(.stepDistance) || enabled.contains(.calories) {
            let stride = MapHomeStride.current
            let dailySteps = await model.calendarDailyStepCounts(month: month)
            for (day, steps) in dailySteps {
                if enabled.contains(.steps) { result[day, default: [:]][MapHomeCalendarTimeKind.steps.rawValue] = steps }
                if enabled.contains(.stepDistance), steps > 0 {
                    result[day, default: [:]][MapHomeCalendarTimeKind.stepDistance.rawValue] = steps * stride
                }
            }
            if enabled.contains(.calories) {
                for (day, value) in await model.calendarDailyCalories(month: month, steps: dailySteps, strideMeters: stride) {
                    result[day, default: [:]][MapHomeCalendarTimeKind.calories.rawValue] = value.kilocalories
                    result[day, default: [:]][MapHomeCalendarTimeKind.caloriesEstimatedKey] = value.isEstimated ? 1 : 0
                }
            }
        }
        // 월 기록 목록이 비어 있으면(지도에는 보이는 날도) 날짜별 기록에서 다시 센다. 지도와 같은 출처를 쓴다.
        if result.isEmpty {
            result = await dayFallbackTotals(month: month)
        }
        if enabled.contains(.income) || enabled.contains(.expense) {
            await LedgerBook.shared.load()
            for (day, value) in LedgerDaySpending.monthTotals(month: month) {
                if enabled.contains(.income), value.income > 0 { result[day, default: [:]][MapHomeCalendarTimeKind.income.rawValue] = value.income }
                if enabled.contains(.expense), value.expense > 0 { result[day, default: [:]][MapHomeCalendarTimeKind.expense.rawValue] = value.expense }
            }
        }
        if includePhotos, enabled.contains(.photos) {
            let library = photoLibrary
            let counts = await Task.detached(priority: .utility) {
                MapHomeCalendarTimeTotalsPolicy.photoCounts(in: month, moments: { library.moments(in: $0) }, calendar: MapHomeGrowthPolicy.localCalendar)
            }.value
            for (day, count) in counts {
                result[day, default: [:]][MapHomeCalendarTimeKind.photos.rawValue] = count
            }
        }
        return result
    }

    /// 날짜별 기록(지도가 쓰는 출처)으로 한 달 합계를 만든다. 오늘까지의 날짜만 본다.
    /// 저장된 기록 목록에 없는 날(최근 이틀처럼 지도에는 보이는 날)은 날짜별 기록에서 다시 판정해 달력 점을 채운다.
    /// 지도와 같은 출처를 쓰므로, 지도에는 기록이 있는데 달력 점만 비는 일이 없다(대표 지적 "달력 점 안나옴", ARC1030A03).
    func calendarLogStatusesFillingGaps(
        _ base: [Date: MapHomeCalendarLogStatus], month: Date
    ) async -> [Date: MapHomeCalendarLogStatus] {
        let calendar = MapHomeGrowthPolicy.localCalendar
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let days = calendar.range(of: .day, in: .month, for: first) else { return base }
        var result = base
        var filled = 0
        for offset in 0..<days.count {
            guard let day = calendar.date(byAdding: .day, value: offset, to: first), day <= .now,
                  result[day] == nil,
                  let data = await model.cachedPlanDayDataSnapshot(for: day) else { continue }
            let statuses = MapHomeCalendarLogStatusPolicy.statuses(
                actuals: data.actuals, travel: data.travel, month: day, asOf: .now, calendar: calendar
            )
            if let status = statuses[day] { result[day] = status; filled += 1 }
        }
        if filled > 0 {
            TaptionPlanDiagnosticsLogger.shared.record("calendar_log_status_filled", metrics: ["filled": Double(filled)])
        }
        return result
    }

    func scheduleExpectedRouteRefresh() {
        expectedRouteRefreshGeneration &+= 1
        let refreshGeneration = expectedRouteRefreshGeneration
        if pendingForecastRouteState != nil {
            pendingForecastRouteState = nil
        }
        expectedRouteRefreshTask?.cancel()
        guard scenePhase == .active else {
            expectedRouteRefreshTask = nil
            return
        }
        expectedRouteRefreshTask = Task { @MainActor in
            do {
                // 실행 직후 위치·하루 자료가 0.3초 간격으로 들어와 같은 입력으로 6번 다시 만들었다. 묶어서 한 번만 만든다(LAG1107A01).
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  scenePhase == .active,
                  refreshGeneration == expectedRouteRefreshGeneration else {
                return
            }
            await refreshExpectedRouteOverlays(generation: refreshGeneration)
            guard !Task.isCancelled,
                  refreshGeneration == expectedRouteRefreshGeneration else {
                return
            }
            expectedRouteRefreshTask = nil
        }
    }

    func scheduleTransitPOIRefresh() {
        guard MapHomeTransitPOIRefreshPolicy.canStart(
            isBootstrapped: model.isBootstrapped,
            isSceneActive: scenePhase == .active
        ) else { return }
        let dataGeneration = TaptionDataDeletionFence.currentGeneration()
        guard TaptionDataDeletionFence.allows(
            generation: dataGeneration
        ) else { return }
        let selectedDate = model.selectedDate
        let readings = transitBoardingReadings
        transitPOIRefreshTask?.cancel()
        transitPOIRefreshGeneration &+= 1
        let generation = transitPOIRefreshGeneration
        transitPOIRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            let places = await AppleTransitBoardingPOIResolver.shared.resolving(
                readings: readings
            )
            guard !Task.isCancelled,
                  generation == transitPOIRefreshGeneration,
                  scenePhase == .active,
                  TaptionDataDeletionFence.allows(
                    generation: dataGeneration
                  ),
                  Calendar.autoupdatingCurrent.isDate(
                      selectedDate,
                      inSameDayAs: model.selectedDate
                  ) else { return }
            if nearbyTransitPlaces != places {
                nearbyTransitPlaces = places
                nearbyTransitPlacesRevision &+= 1
            }
        }
    }

    func scheduleLiveRouteProjectionRefresh() {
        liveRouteProjectionRefreshTask?.cancel()
        guard scenePhase == .active else {
            liveRouteProjectionRefreshTask = nil
            return
        }
        liveRouteProjectionRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, scenePhase == .active else { return }
            mapRenderCache.invalidateRouteData()
            requestRouteProjectionRefresh(preparingReadings: true)
            if let timestamp = [
                model.latestSensorReading?.timestamp,
                model.liveRouteState.readings.last?.timestamp,
            ].compactMap({ $0 }).max() {
                removeCompletedExpectedRoutes(at: timestamp)
            }
            liveRouteProjectionRefreshTask = nil
        }
    }

    /// 경로 계산을 메인 스레드 밖에서 돌린다. 입력이 같으면 이전 결과를 그대로 쓴다.
    /// 계산이 끝났을 때 입력이 이미 바뀌었다면 결과를 버린다(늦은 결과가 최신 경로를 덮지 않도록).
    func scheduleRouteProjection() {
        guard scenePhase == .active,
              let dayData = currentDayDataSnapshot else {
            routeProjectionSkips[0] += 1
            return
        }
        let calendar = Calendar.autoupdatingCurrent
        let actuals = dayData.actuals
        let actualIndex = routeActualIndex ?? RouteTimelineDataEngine.actualIndex(
            selectedDate: model.selectedDate,
            actuals: actuals,
            calendar: calendar
        )
        if routeActualIndex == nil {
            routeActualIndex = actualIndex
        }
        let timelineDate = routeTimelineDate
        let dayStart = calendar.startOfDay(for: model.selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(24 * 60 * 60)
        let rawProjectionDate = MapHomeRouteOverlayCutoffPolicy.cutoff(
            selectedDayEnd: dayEnd,
            timelineDate: timelineDate,
            isPlaybackRunning: isDayPlaybackRunning
        )
        // 재생 중에는 분 단위로 잘라, 같은 분 안의 틱이 투영을 다시 만들지 않게 한다(PLY1029A01).
        let projectionDate = isDayPlaybackRunning
            ? Date(timeIntervalSinceReferenceDate: (rawProjectionDate.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
            : rawProjectionDate
        let selectedSpan = isDayPlaybackRunning ? nil : timelineSelectionSpan
        let readings = displayRouteReadings
        let inputKey = RouteProjectionInputKey(
            day: dayStart,
            sourceRevision: dayData.sourceRevision,
            cutoff: projectionDate,
            selectedStart: selectedSpan?.start,
            selectedEnd: selectedSpan?.end,
            isPlaying: isDayPlaybackRunning,
            readingCount: readings.count,
            lastReadingTime: readings.last?.timestamp,
            actualCount: actuals.count,
            sleepCount: model.sleepSessions.count,
            confirmedSleepCount: model.settings.confirmedSleepSpans.count
        )
        if inputKey == routeProjectionInputKey, routeProjection != nil {
            routeProjectionSkips[1] += 1
            return
        }
        // 재생 중에는 계산이 끝나기 전에 입력이 바뀌어도 작업을 끊지 않는다. 매초 끊으면 결과가 한 번도 반영되지 않아
        // 발자국과 경로가 재생이 끝날 때까지 나오지 않았다. 끝나면 가장 최근 입력으로 한 번 더 계산한다(ARC1030A02).
        if isDayPlaybackRunning, routeProjectionInFlight {
            routeProjectionDirty = true
            routeProjectionSkips[2] += 1
            return
        }
        routeProjectionInputKey = inputKey
        let travel = dayData.travel
        let confirmedSleepSpans = model.settings.confirmedSleepSpans
        let sleepSessions = model.sleepSessions
        let selectedDate = model.selectedDate
        routeProjectionTask?.cancel()
        routeProjectionRunID &+= 1
        let runID = routeProjectionRunID
        routeProjectionInFlight = true
        let runStart = ProcessInfo.processInfo.systemUptime
        routeProjectionTask = Task { @MainActor in
            let next = await Task.detached(priority: .userInitiated) {
                RouteTimelineDataEngine.project(
                    selectedDate: selectedDate,
                    through: projectionDate,
                    selectedSpan: selectedSpan,
                    actuals: actuals,
                    actualIndex: actualIndex,
                    travel: travel,
                    readings: readings,
                    readingsAreNormalized: true,
                    filtersSparseRouteConnections: true,
                    confirmedSleepSpans: confirmedSleepSpans,
                    sleepSessions: sleepSessions,
                    calendar: calendar
                )
            }.value
            if routeProjectionRunID == runID { routeProjectionInFlight = false }
            routeProjectionLastMS = (ProcessInfo.processInfo.systemUptime - runStart) * 1000
            guard !Task.isCancelled else { return }
            // 재생 중에는 조금 늦은 결과도 쓴다(같은 재생이면 입력이 이미 다음 분으로 넘어가 있어도 괜찮다).
            guard routeProjectionInputKey == inputKey || (isDayPlaybackRunning && inputKey.isPlaying) else { return }
            let overlays = makeTimelineRouteOverlays(next)
            mapRenderCache.invalidateRouteData()
            routeProjection = next
            timelineRouteOverlays = overlays
            routeProjectionApplied += 1
            if routeProjectionDirty, isDayPlaybackRunning {
                routeProjectionDirty = false
                scheduleRouteProjection()
            }
        }
    }

    var hasScheduleWeatherChips: Bool {
        model.settings.weatherSidebarVisible
            && recordingShows(\.weatherSidebar)
            && !displayWeatherContexts.isEmpty
    }

    /// 일정·스티커 배지의 기준 x.
    var scheduleBadgeBaseX: CGFloat {
        MapHomeTimeSidebarMath.scheduleBadgeBaseX(hasWeatherChips: hasScheduleWeatherChips)
    }

    /// 표식의 x 이동량. 날씨 칩이 없으면 겹치는 만큼 왼쪽 열로 벌린다.
    /// 날씨 칩이 있으면 같은 시간(±10분)의 일정은 왼쪽, 스티커는 오른쪽으로 나눈다.
    func scheduleBadgeOffset(id: String, minute: Int, isEvent: Bool, columns: [String: Int]) -> CGFloat {
        guard hasScheduleWeatherChips else {
            return -CGFloat(columns[id] ?? 0) * MapHomeTimeSidebarMath.scheduleBadgeColumnWidth
        }
        let timedEvents = dayCalendarEventsForSelectedDate.filter { !$0.isAllDay }.map { minuteOfDay(for: $0.span.start) }
        let timedStickers = scheduleStickersForSelectedDate.map { minuteOfDay(for: $0.occurredAt) }
            + timedMemosForSelectedDate.map { minuteOfDay(for: $0.occurredAt) }
        let others = isEvent ? timedStickers : timedEvents
        guard others.contains(where: { abs($0 - minute) <= 10 }) else { return 0 }
        return isEvent ? -14 : 14
    }

    /// 지금 보이는 시간대에서 표식과 미확인 아이콘의 y로 열을 정한다. 날씨 칩이 있으면 쓰지 않는다.
    func scheduleBadgeColumns(railHeight: CGFloat) -> [String: Int] {
        guard !hasScheduleWeatherChips, recordingShows(\.sidebarMemos) else { return [:] }
        let window = MapHomeTimeSidebarMath.visibleWindow(
            startMinute: timeSidebarVisibleStartMinute,
            durationMinutes: timeSidebarVisibleDurationMinutes,
            centerMinute: effectiveTimelineMinute
        )
        let inset = MapHomeTimeSidebarMath.verticalInset
        let trackHeight = max(1, railHeight - inset * 2)
        func y(_ date: Date) -> CGFloat {
            inset + trackHeight * MapHomeTimeSidebarMath.position(minute: minuteOfDay(for: date), window: window)
        }
        let badges = scheduleStickersForSelectedDate.map { (id: "sticker-\($0.id)", y: y($0.occurredAt)) }
            + timedMemosForSelectedDate.map { (id: "memo-\($0.id)", y: y($0.occurredAt)) }
            + dayCalendarEventsForSelectedDate.filter { !$0.isAllDay }.map { (id: "event-\($0.id)", y: y($0.span.start)) }
        let reviewSegments = MapHomeUnconfirmedReviewPolicy.visibleReviewTargets(
            from: timeRailSegments, in: window, for: model.selectedDate
        )
        let centers = MapHomeTimeSidebarMath.unconfirmedReviewMarkerCenters(
            segments: reviewSegments, window: window, trackHeight: trackHeight, verticalInset: inset
        )
        return MapHomeTimeSidebarMath.scheduleBadgeColumns(badges: badges, reviewMarkerYs: Array(centers.values))
    }
}
