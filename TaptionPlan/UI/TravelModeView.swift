import SwiftUI
import TaptionPlanStore

/// 여행 모드(TVB1112A01): 지구본과 여행 카드 → 누르면 지구가 돌고 깃발이 꽂히고 확대 → 여행 화면.
struct TravelModeView: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    /// 붙여넣기 배너·중계로 받은 여행 계획. 있으면 들어오자마자 가져오기 창을 연다(TVX1116A01).
    var importText: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera = TravelGlobeCamera(longitude: 127, latitude: 28, radius: 140)
    @State private var flight: TravelGlobeFlight?
    @State private var flightStart = Date.distantPast
    @State private var flyingID: String?
    @State private var openedID: String?
    /// 지구본에서 고른(포커싱한) 여행. 그 깃발이나 카드를 한 번 더 누르면 여행 화면으로 들어간다.
    @State private var focusedID: String?
    @State private var dragBase: TravelGlobeCamera?
    @State private var pinchBase: Double?
    @State private var lastGestureUpdate = Date.distantPast
    @State private var viewSize = CGSize(width: 390, height: 760)
    @State private var newTripDraft: TravelNewTripSheet.Draft?
    @State private var ledgerTripID: String?
    @State private var expenseDraft: LedgerEntry?
    @State private var realityDay: TravelTodayDay?
    @State private var entryTarget: TravelQuickEntrySheet.Target?
    /// 계획표에서 고른 빈 셀(TVU1113A01).
    @State private var planCell: TravelPlanCell?
    @State private var planSelectedID: String?
    @State private var columnsTrip: TravelTrip?
    /// 계획표를 먼저 보기로 고른 여행 번호들(쉼표로 이음, 기기에 기억). 고르지 않은 여행은 코스가 먼저 열린다(TVV1113A01 C1).
    @AppStorage("travelPlanTableTrips") private var tableTrips = ""
    @State private var courseAdding: TravelTripDirectory.Entry?
    /// 위키백과 장소 사진(C6). 연락처가 설정돼 있고 스위치가 켜져 있을 때만 받는다.
    @State private var placePhotos = TravelPlacePhotoStore()
    @State private var planHistory = TravelPlanHistory()
    /// 계획표 모델 캐시(TVM1117A02). 값이 아니라 참조라 고쳐도 본문을 다시 그리지 않는다.
    @State private var tableCache = TravelPlanTableCache()
    @State private var deleteCandidate: TravelTripDirectory.Entry?
    /// AI로 만들기(가져오기) 창. 예전에는 지도 여행 모드로 건너가야 했다.
    @State private var isImportPresented = false
    /// 여행 공유 시트(TSH1114A26). 내용은 `TripShareHost`가 띄운다.
    @State private var shareRoute: TripShareRoute?
    /// 재생 헤드의 시각(그날 0시부터의 분). nil이면 처음 자리(오늘은 지금, 아니면 첫 일정 시작).
    @State private var playMinute: Int?
    /// 고른 고양이 그림(한 번 만들어 둔다).
    @State private var actorImage: Image?
    @State private var actorUIImage: UIImage?
    @State private var actorArt = TravelActorArt()
    /// 곳 사이 길(Apple 길찾기). 올 때까지는 곧은 선.
    @State private var routes = TravelRouteStore()
    @State private var didEnter = false
    /// 마지막으로 열어 둔 여행. 여행 화면에서 일상으로 나갔다가 돌아오면 그 여행으로 바로 온다(지구본에서 나갔으면 지구본).
    @AppStorage("travelLastOpenedTripID") private var lastTripID = ""
    /// 손잡이로 정한 계획표 높이(0이면 반반)와, 끄는 동안의 높이(TVU1113A01).
    @AppStorage("travelPlanSheetHeight") private var planHeight = 0.0
    @State private var planDragHeight: CGFloat?
    private var tableHeight: CGFloat { TravelPlanSheetHeight.height(viewSize, stored: planHeight) }
    /// 계획표 시트가 올라와 있는지. 올라오면 작은 시간 막대는 사라진다(대표 결정).
    @State private var isPlanUp = false
    /// 계획표와 시간 막대가 함께 보는 날(`YYYY-MM-DD`). nil이면 여행 중엔 오늘, 아니면 첫날.
    @State private var planDayKey: String?

    private var book: LedgerBook { LedgerBook.shared }

    private var entries: [TravelTripDirectory.Entry] {
        model.travelTripEntries(names: Dictionary(book.trips.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
    }

    /// 넓은 화면(패드, 펼친 듀오)이나 가로 모드: 계획표를 아래 전체가 아니라 오른쪽 판으로 둔다.
    static func isWide(_ size: CGSize) -> Bool { size.width >= 700 || size.width > size.height }

    /// 계획표 높이: 세로 폰은 화면의 절반, 넓은 화면·가로는 머리말과 아래 줄을 뺀 나머지(화면의 70%까지).
    static func planTableHeight(_ size: CGSize) -> CGFloat {
        isWide(size) ? max(120, min(size.height - 280, size.height * 0.7)) : size.height * 0.5
    }

    private var restRadius: Double { Double(min(viewSize.width, viewSize.height)) * 0.38 }

    var body: some View {
        let entries = self.entries
        let focused = entries.first { $0.id == (openedID ?? flyingID ?? focusedID) }
        let destination = focused.map { TravelModeDestination(trip: $0.trip, stops: model.settings.travelPlanStops) }
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: flight == nil)) { timeline in
                let elapsed = timeline.date.timeIntervalSince(flightStart)
                let now = flight.map { $0.camera(at: elapsed) } ?? camera
                Canvas { context, size in
                    TravelGlobeRenderer.draw(
                        &context, size: size, camera: now, highlight: highlight(destination),
                        flags: flags(entries, flightProgress: flight.map { $0.flagProgress(at: elapsed) } ?? 1),
                        pins: openedID == nil ? [] : planPins(focused, destination),
                        offset: focused.map(mapOffset) ?? .zero, actor: focused.flatMap(actor),
                        home: home, route: focused.map(dayRoute) ?? []
                    )
                }
            }
            // 그리는 크기와 누른 자리를 재는 크기가 같아야 깃발이 눌린다. 그래서 안전 영역까지 포함한 이 크기 하나만 쓴다.
            .gesture(globeGestures(entries, size: proxy.size), isEnabled: openedID == nil && flight == nil)
            // 크기를 먼저 넣고 다음 차례에 들어가야, 패드에서도 그 화면 크기로 지구본을 잡는다.
            .onAppear {
                viewSize = proxy.size
                Task { @MainActor in enter(entries) }
            }
            .onChange(of: proxy.size) { _, size in
                viewSize = size
                Task { @MainActor in refit() }
            }
        }
        .ignoresSafeArea()
        // 여행에 들어가면 경계 그림 위에 오픈맵을 띄운다(대표 지시).
        .overlay { if let focused, openedID != nil, flight == nil { streetMap(focused, destination).ignoresSafeArea() } }
        .overlay {
            if let focused, openedID != nil, flight == nil, !isPlanUp, pins(destination).isEmpty {
                // 안내만 있던 자리에 바로 누를 단추를 둔다(TVX1116A01). 날짜 없는 여행은 날짜를 먼저 정한다.
                Button { courseAdding = focused } label: {
                    Label(language.text("곳을 더하면 지도에 나옵니다", "Add a stop to see it on the map"), systemImage: "plus")
                        .font(.footnote.weight(.medium)).foregroundStyle(TravelInk.plan)
                        .padding(.horizontal, 14).frame(height: TaptionControl.chip)
                        .background(TravelInk.panel, in: Capsule())
                        .overlay { Capsule().stroke(TravelInk.border, lineWidth: TaptionBorder.width) }
                        .taptionTouchTarget(visualWidth: TaptionControl.primary, visualHeight: TaptionControl.chip)
                }
                .buttonStyle(.plain)
                .disabled(focused.state == .someday)
                .accessibilityIdentifier("travelEmptyAddStop")
            }
        }
        .overlay(alignment: .topLeading) {
            if openedID == nil { cardColumn(entries) }
        }
        .overlay(alignment: .top) {
            if let focused, openedID != nil { tripHeader(focused) }
        }
        .overlay(alignment: .trailing) {
            if let focused, openedID != nil, !isPlanUp {
                Button { withAnimation(.snappy(duration: 0.25)) { isPlanUp = true } } label: { TravelMiniRail(table: table(focused)) }
                    .buttonStyle(.plain)
                    .padding(.trailing, 10)
                    .padding(.top, 130)
                    .padding(.bottom, 110)
                    .accessibilityLabel(language.text("계획표 올리기", "Open plan table"))
                    .accessibilityIdentifier("travelMiniRail")
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let focused, openedID != nil {
                planSheet(focused)
            } else {
                globeFooter(focused)
            }
        }
        .confirmationDialog(
            language.text("이 여행과 그 일정을 모두 지울까요?", "Delete this trip and all its plans?"),
            isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }), titleVisibility: .visible
        ) {
            Button(language.text("여행 지우기", "Delete trip"), role: .destructive) {
                guard let entry = deleteCandidate else { return }
                if openedID == entry.id || focusedID == entry.id { backToGlobe() }
                Task { await model.deleteTravelTrip(entry.id) }
            }
        }
        .onChange(of: openedID) { _, id in lastTripID = id ?? "" }
        .onChange(of: importText) { _, text in if text != nil, !isImportPresented { isImportPresented = true } }
        .onChange(of: isPlanUp) { _, _ in
            if planCell != nil { planCell = nil }
            applyPlanCamera()
        }
        .onChange(of: planDayKey) { _, _ in
            playMinute = nil
            if planCell != nil { planCell = nil }
            applyPlanCamera()
        }
        .task {
            // 설정에서 고른 고양이(화랑·춘향·윤복…)를 그대로 쓴다.
            let cat = HwarangDiagnostics.frame(scene: .walkLoop, sec: 0.7, side: 96, small: true, coat: .named(model.settings.catStyle.rawValue))
            actorUIImage = cat
            actorImage = Image(uiImage: cat)
        }
        .task(id: flightStart) { await finishFlight() }
        .task { await book.load() }
        .sheet(item: $newTripDraft) { draft in
            TravelNewTripSheet(model: model, language: language, draft: draft) { trip in
                guard draft.editing == nil else { return }
                fly(to: TravelTripDirectory.entry(trip, isStored: true, today: today()))
            }
        }
        .sheet(item: Binding(get: { ledgerTripID.map(TravelLedgerTarget.init) }, set: { ledgerTripID = $0?.id })) { target in
            LedgerSheet(language: language, tripID: target.id, plannedTrips: LedgerBook.plannedTrips(
                stops: model.settings.travelPlanStops, items: model.settings.travelTripItems ?? [], trips: model.settings.travelTrips ?? []
            ))
        }
        .sheet(item: $courseAdding) { entry in
            TravelPlacePicker(language: language, query: "", anchor: TravelModeDestination(trip: entry.trip, stops: model.settings.travelPlanStops).point, onPick: { _ in }) {
                addCourseStop(entry, name: $0, place: $1, kind: $2)
            }
        }
        .sheet(isPresented: $isImportPresented) {
            MapHomeTripImportSheet(model: model, language: language, initialText: importText) { openImported($0) }
                .presentationDetents([.large])
        }
        .sheet(item: $columnsTrip) { TravelColumnEditorSheet(model: model, language: language, trip: $0) }
        .sheet(item: $entryTarget) { target in TravelQuickEntrySheet(model: model, language: language, target: target) { planHistory.record($0) } }
        .sheet(item: $expenseDraft) { draft in LedgerEntryForm(language: language, entry: draft, members: draft.tripID.flatMap(book.trip)?.members) }
        .sheet(item: $realityDay) { PlanRealityView(model: model, language: language, day: $0.date) }
        .tripShare(model: model, language: language, openedID: openedID, route: $shareRoute)
        .preferredColorScheme(openedID == nil && flight == nil ? .dark : .light)
        .accessibilityIdentifier("travelModeScreen")
    }

    // MARK: 움직임

    private func today() -> String {
        let parts = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: .now)
        return TravelTripDay.string(year: parts.year ?? 0, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// 처음 들어올 때: 오늘이 여행 기간이면 그 여행으로 바로 간다(대표 결정).
    private func enter(_ entries: [TravelTripDirectory.Entry]) {
        guard !didEnter else { return }
        didEnter = true
        camera.radius = restRadius
        let dayKey = Self.dayKey(model.selectedDate)
        if importText != nil { isImportPresented = true }
        guard let target = Self.entryToOpen(entries, selectedDay: dayKey, lastTripID: lastTripID) else { return }
        focusedID = target.id
        let destination = TravelModeDestination(trip: target.trip, stops: model.settings.travelPlanStops)
        if let last = cameras(for: destination).last { camera = last }
        // 일상에서 보던 날이 그 여행 기간이면 계획표도 그날로 연다.
        if dayKey >= target.trip.startDay, dayKey <= target.trip.endDay { planDayKey = dayKey }
        openedID = target.id
    }

    /// 가져온 계획의 첫날을 품은 여행을 그날로 연다.
    private func openImported(_ day: Date) {
        let key = Self.dayKey(day)
        guard let entry = entries.first(where: { $0.trip.startDay <= key && key <= $0.trip.endDay }) else { return }
        if openedID != entry.id { backToGlobe() }
        if let last = cameras(for: TravelModeDestination(trip: entry.trip, stops: model.settings.travelPlanStops)).last { camera = last }
        focusedID = entry.id
        planDayKey = key
        openedID = entry.id
    }

    static func dayKey(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return TravelTripDay.string(year: parts.year ?? 0, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// 일상에서 넘어올 때 바로 열 여행: 일상에서 보던 날을 품은 여행 → 지금 여행 중인 것 → 마지막으로 열어 둔 것. 없으면 지구본.
    static func entryToOpen(_ entries: [TravelTripDirectory.Entry], selectedDay: String, lastTripID: String) -> TravelTripDirectory.Entry? {
        entries.first { $0.trip.startDay <= selectedDay && selectedDay <= $0.trip.endDay }
            ?? entries.first { $0.state == .active }
            ?? entries.first { !lastTripID.isEmpty && $0.id == lastTripID }
    }

    /// 여행 화면에서 일상으로 바로 나간다. 계획표에서 날을 골라 보고 있었으면 일상도 그날로 맞춘다.
    private func exitToDaily(_ entry: TravelTripDirectory.Entry) {
        if planDayKey != nil || entry.state == .active { model.selectedDate = dayDate(dayKey(entry)) }
        dismiss()
    }

    /// 화면이 돌거나 크기가 바뀌면 지금 보던 것을 새 크기에 다시 맞춘다(움직이는 중에는 그대로 둔다).
    private func refit() {
        guard flight == nil else { return }
        guard let id = openedID ?? focusedID, let entry = entries.first(where: { $0.id == id }) else {
            camera.radius = restRadius
            return
        }
        applyPlanCamera()
    }

    private func fit(_ box: (west: Double, south: Double, east: Double, north: Double), in size: CGSize? = nil) -> TravelGlobeCamera {
        let size = size ?? viewSize
        return TravelGlobeCamera.fitting(
            west: box.west, south: box.south, east: box.east, north: box.north, width: Double(size.width), height: Double(size.height),
            padding: 56, minimumRadius: restRadius, maximumRadius: 60_000
        )
    }

    // MARK: 재생 헤드와 지도(TVP1112A01)

    /// 계획표가 올라왔을 때 지도에 남는 자리. 세로 폰은 머리말 아래~시트 위, 넓은 화면은 판 왼쪽.
    static func mapArea(_ size: CGSize, isPlanUp: Bool, tableHeight: CGFloat? = nil) -> CGRect {
        guard isPlanUp else { return CGRect(origin: .zero, size: size) }
        if isWide(size) {
            let panel = min(460, size.width * 0.5) + 20
            return CGRect(x: 0, y: 120, width: size.width - panel, height: max(80, size.height - 120))
        }
        let sheet = (tableHeight ?? planTableHeight(size)) + 150
        return CGRect(x: 0, y: 130, width: size.width, height: max(80, size.height - sheet - 130))
    }

    /// 그 자리의 가운데로 지도 가운데를 옮기는 양.
    private func mapOffset(_ entry: TravelTripDirectory.Entry) -> CGSize {
        guard isPlanUp, openedID == entry.id else { return .zero }
        let area = Self.mapArea(viewSize, isPlanUp: true, tableHeight: tableHeight), base = TravelGlobeRenderer.center(in: viewSize)
        return CGSize(width: area.midX - base.x, height: area.midY - base.y)
    }

    /// 그날 일정 가운데 지도 핀이 있는 것(시각 순).
    private func playStops(_ entry: TravelTripDirectory.Entry) -> [TravelPlayhead.Stop] {
        let pins = model.settings.travelPlanStops.filter { $0.tripID == entry.id }
        return table(entry).blocks.compactMap { block in
            pins.first { $0.itemID == block.id }.map {
                TravelPlayhead.Stop(id: block.id, startMinute: block.startMinute, endMinute: block.endMinute, longitude: $0.longitude, latitude: $0.latitude)
            }
        }
    }

    /// 재생 헤드가 가리키는 절대 시각(그 날·그 분의 시차, TVM1117A02).
    private func playDate(_ entry: TravelTripDirectory.Entry) -> Date {
        TravelPlanSpend.date(trip: entry.trip, items: model.settings.travelTripItems ?? [], dayKey: dayKey(entry), minute: currentPlayMinute(entry))
    }

    /// 지출 넣기. 장부가 있으면 바로 입력 칸을 연다: 고른 일정의 시작, 없으면 재생 헤드의 시각(계획표가 내려 있으면 지금).
    private func addExpense(_ entry: TravelTripDirectory.Entry, minute: Int?, itemID: String? = nil) {
        guard book.trip(entry.id) != nil else {
            // 가계부에 이 여행이 아직 없으면 예산 없는 여행 장부를 만들고 바로 입력 칸을 연다(TVX1116A01). 만들 수 없으면 전처럼 가계부를 연다.
            let planned = LedgerBook.plannedTrips(stops: model.settings.travelPlanStops, items: model.settings.travelTripItems ?? [], trips: model.settings.travelTrips ?? [])
            guard let trip = planned.first(where: { $0.id == entry.id }) else { return ledgerTripID = entry.id }
            Task {
                await book.saveTrip(trip)
                if book.trip(entry.id) != nil { addExpense(entry, minute: minute, itemID: itemID) } else { ledgerTripID = entry.id }
            }
            return
        }
        let items = model.settings.travelTripItems ?? []
        let picked = minute.map { TravelPlanSpend.date(trip: entry.trip, items: items, dayKey: dayKey(entry), minute: $0, itemID: itemID) }
        expenseDraft = TravelPlanSpend.draft(tripID: entry.id, at: picked ?? (isPlanUp ? playDate(entry) : .now))
    }

    private func currentPlayMinute(_ entry: TravelTripDirectory.Entry) -> Int {
        let table = table(entry)
        return playMinute ?? TravelPlayhead.startMinute(nowMinute: table.nowMinute, firstStartMinute: table.blocks.first?.startMinute)
    }

    /// 계획표가 올라와 있으면 그날 핀만(그날 차례 번호), 아니면 여행 전체.
    private func planPins(_ entry: TravelTripDirectory.Entry?, _ destination: TravelModeDestination?) -> [TravelGlobeRenderer.Pin] {
        guard let entry, isPlanUp else { return pins(destination) }
        let stops = playStops(entry)
        guard !stops.isEmpty else { return pins(destination) }
        let titles = Dictionary(table(entry).blocks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        // 핀이 많으면 이름이 겹치니, 재생 시각에 머무는 곳 하나만 이름을 단다.
        let here = TravelPlayhead.position(at: currentPlayMinute(entry), stops: stops, paths: routes.paths)?.stopID
        return stops.enumerated().map { index, stop in
            .init(longitude: stop.longitude, latitude: stop.latitude, label: "\(index + 1)", id: stop.id,
                  title: stops.count <= 5 || stop.id == here ? titles[stop.id] ?? "" : "")
        }
    }

    /// 자주 가는 곳에 등록한 집 자리.
    private var home: SIMD2<Double>? {
        model.settings.frequentPlaces.first { $0.kind == .home }?.point.map { SIMD2($0.longitude, $0.latitude) }
    }

    /// 계획표가 올라와 있을 때 그날의 길: 구간마다 받은 길, 아직 없으면 곧은 선.
    private func dayRoute(_ entry: TravelTripDirectory.Entry) -> [SIMD2<Double>] {
        guard isPlanUp, openedID == entry.id else { return [] }
        let stops = playStops(entry)
        guard stops.count > 1, !routes.paths.isEmpty else { return [] }
        var line: [SIMD2<Double>] = [SIMD2(stops[0].longitude, stops[0].latitude)]
        for (from, to) in zip(stops, stops.dropFirst()) {
            line += routes.paths[TravelPlayhead.legKey(from.id, to.id)] ?? [SIMD2(to.longitude, to.latitude)]
        }
        return line
    }

    /// 재생 시각의 동작: 머무는 중이면 일정 종류, 이동 중이면 수단(TVW1112A01).
    private func pose(_ entry: TravelTripDirectory.Entry) -> TravelPlayhead.Pose? {
        guard isPlanUp, openedID == entry.id else { return nil }
        let stops = playStops(entry), items = model.settings.travelTripItems ?? []
        guard let spot = TravelPlayhead.position(at: currentPlayMinute(entry), stops: stops, paths: routes.paths) else { return nil }
        func item(_ id: String?) -> TravelTripItem? { items.first { $0.tripID == entry.id && $0.itemID == id } }
        if let here = item(spot.stopID) { return TravelPlayhead.pose(kind: here.kind, title: here.title) }
        guard let from = item(spot.fromID), let to = item(spot.toID),
              let a = stops.first(where: { $0.id == from.itemID }), let b = stops.first(where: { $0.id == to.itemID }) else { return .walk }
        let meters = TravelRouteStore.meters(a, b)
        return TravelPlayhead.movingPose(fromKind: from.kind, fromTitle: from.title, toKind: to.kind, toTitle: to.title, meters: meters)
    }

    /// 여행 화면의 오픈맵: 핀·계획 길·고양이를 올리고, 머리말과 계획표가 가리지 않는 자리에 맞춘다.
    private func streetMap(_ entry: TravelTripDirectory.Entry, _ destination: TravelModeDestination?) -> TravelStreetMap {
        let area = isPlanUp ? Self.mapArea(viewSize, isPlanUp: true, tableHeight: tableHeight) : CGRect(x: 0, y: 150, width: viewSize.width, height: max(80, viewSize.height - 270))
        let spot = actor(entry), isCourse = isPlanUp && showsCourse(entry)
        return TravelStreetMap(
            pins: TravelCoursePlanner.mapPins(planPins(entry, destination), blocks: isCourse ? table(entry).blocks : [], minute: currentPlayMinute(entry), photos: placePhotos.photos),
            route: dayRoute(entry), actor: spot.map { .init(longitude: $0.longitude, latitude: $0.latitude, facesEast: $0.facesEast) },
            actorImage: pose(entry).map { actorArt.image($0, coat: model.settings.catStyle.rawValue) } ?? actorUIImage, fallback: destination?.point,
            // 위쪽 핀에 선 고양이가 머리말에 가리지 않게 고양이 키만큼 더 띄운다.
            insets: UIEdgeInsets(top: area.minY + 74, left: 28, bottom: viewSize.height - area.maxY + 24, right: viewSize.width - area.maxX + 28),
            fitKey: "\(entry.id)|\(dayKey(entry))|\(isPlanUp)|\(Int(viewSize.width))x\(Int(viewSize.height))|\(Int(tableHeight))",
            onSelect: { selectPin(entry, itemID: $0) }, isCourse: isCourse, onLongPress: { addEntry(entry, at: $0) },
            companions: TripLiveLocationService.shared.marks(tripID: entry.id, language: language)
        )
    }

    /// 재생 헤드의 시각에 고양이가 설 자리.
    private func actor(_ entry: TravelTripDirectory.Entry) -> TravelGlobeRenderer.Actor? {
        guard isPlanUp, openedID == entry.id, let image = actorImage,
              let spot = TravelPlayhead.position(at: currentPlayMinute(entry), stops: playStops(entry), paths: routes.paths) else { return nil }
        return .init(longitude: spot.longitude, latitude: spot.latitude, image: image, facesEast: spot.facesEast)
    }

    /// 계획표를 올리면 그날 핀이 남은 자리에 다 들어오게 지도를 맞추고, 내리면 여행 전체로 돌아간다.
    private func applyPlanCamera() {
        guard flight == nil, let id = openedID, let entry = entries.first(where: { $0.id == id }) else { return }
        let stops = isPlanUp ? playStops(entry) : []
        guard !stops.isEmpty else {
            let destination = TravelModeDestination(trip: entry.trip, stops: model.settings.travelPlanStops)
            if let last = cameras(for: destination).last { camera = last }
            return
        }
        let lons = stops.map(\.longitude), lats = stops.map(\.latitude), pad = 0.02
        Task { await routes.load(stops) }
        camera = fit(
            ((lons.min() ?? 0) - pad, (lats.min() ?? 0) - pad, (lons.max() ?? 0) + pad, (lats.max() ?? 0) + pad),
            in: Self.mapArea(viewSize, isPlanUp: true, tableHeight: tableHeight).size
        )
    }

    /// 확대 단계: 나라 → (국내는 시·도) → 그 여행의 핀이 다 보이는 자리.
    private func cameras(for destination: TravelModeDestination) -> [TravelGlobeCamera] {
        var stops: [TravelGlobeCamera] = []
        if let country = destination.country { stops.append(fit(country.mainBox)) }
        if let province = destination.province { stops.append(fit(province.mainBox)) }
        if destination.stops.count >= 1 {
            let lons = destination.stops.map(\.longitude), lats = destination.stops.map(\.latitude)
            let pad = 0.03
            stops.append(fit(((lons.min() ?? 0) - pad, (lats.min() ?? 0) - pad, (lons.max() ?? 0) + pad, (lats.max() ?? 0) + pad)))
        }
        return stops
    }

    // MARK: 지구본 만지기(TVE1112A01): 끌어서 돌리기, 벌려서 확대, 깃발 누르기

    /// 손가락 입력은 화면 갱신(60Hz)보다 자주 와도 한 번만 반영한다.
    private func acceptsGestureUpdate() -> Bool {
        let now = Date.now
        guard now.timeIntervalSince(lastGestureUpdate) >= 1.0 / 60 else { return false }
        lastGestureUpdate = now
        return true
    }

    private func globeGestures(_ entries: [TravelTripDirectory.Entry], size: CGSize) -> some Gesture {
        let drag = DragGesture(minimumDistance: 6)
            .onChanged { value in
                let base = dragBase ?? camera
                if dragBase == nil { dragBase = base }
                guard acceptsGestureUpdate() else { return }
                camera = TravelGlobeTouch.rotated(base, by: value.translation)
            }
            .onEnded { value in
                if let base = dragBase { camera = TravelGlobeTouch.rotated(base, by: value.translation) }
                dragBase = nil
            }
        let pinch = MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? camera.radius
                if pinchBase == nil { pinchBase = base }
                guard acceptsGestureUpdate() else { return }
                camera.radius = TravelGlobeTouch.zoomed(base, by: value.magnification, rest: restRadius)
            }
            .onEnded { value in
                if let base = pinchBase { camera.radius = TravelGlobeTouch.zoomed(base, by: value.magnification, rest: restRadius) }
                pinchBase = nil
            }
        let tap = SpatialTapGesture()
            .onEnded { value in
                let all = flags(entries, flightProgress: 1)
                guard let id = TravelGlobeTouch.flag(at: value.location, flags: all, camera: camera, size: size),
                      let entry = entries.first(where: { $0.id == id }) else { return }
                select(entry)
            }
        return drag.simultaneously(with: pinch).simultaneously(with: tap)
    }

    /// 깃발이나 카드를 한 번 누르면 그 여행지로 날아가 바로 여행 화면으로 들어간다(TVX1116A01, 두 번 누르기를 없앰).
    private func select(_ entry: TravelTripDirectory.Entry) {
        guard flight == nil else { return }
        if focusedID == entry.id {
            let destination = TravelModeDestination(trip: entry.trip, stops: model.settings.travelPlanStops)
            if let last = cameras(for: destination).last { camera = last }
            openedID = entry.id
        } else {
            fly(to: entry)
        }
    }

    /// 여행마다 깃발 하나. 색은 사용자가 정한 것, 없으면 순서대로 기본 색. 지난 여행은 옅게.
    private func flags(_ entries: [TravelTripDirectory.Entry], flightProgress: Double) -> [TravelGlobeRenderer.Flag] {
        guard openedID == nil else { return [] }
        return entries.enumerated().compactMap { index, entry in
            guard let point = TravelModeDestination(trip: entry.trip, stops: model.settings.travelPlanStops).point else { return nil }
            let chosen = entry.id == (flyingID ?? focusedID)
            return TravelGlobeRenderer.Flag(
                id: entry.id, longitude: point.x, latitude: point.y, text: tag(entry),
                progress: entry.id == flyingID ? flightProgress : 1,
                color: Color(hex: TravelInk.flagHex(entry.trip, order: index)),
                opacity: (entry.state == .past || entry.state == .someday) && !chosen ? 0.45 : 1, showsLabel: chosen
            )
        }
    }

    private func setFlagColor(_ hex: String?, for entry: TravelTripDirectory.Entry) {
        var trip = entry.trip
        trip.flagColorHex = hex
        Task { await model.saveTravelTrip(trip) }
    }

    private func fly(to entry: TravelTripDirectory.Entry) {
        guard flight == nil else { return }
        let destination = TravelModeDestination(trip: entry.trip, stops: model.settings.travelPlanStops)
        guard let point = destination.point else {
            // 어디인지 모르는 여행은 지구를 돌리지 않고 바로 연다.
            focusedID = entry.id
            openedID = entry.id
            return
        }
        let plan = TravelGlobeFlight(
            start: TravelGlobeCamera(longitude: camera.longitude, latitude: camera.latitude, radius: restRadius),
            targetLongitude: point.x, targetLatitude: point.y, stops: cameras(for: destination)
        )
        openedID = nil
        flyingID = entry.id
        if reduceMotion {
            camera = plan.camera(at: plan.duration)
            focusedID = entry.id
            flyingID = nil
            openedID = entry.id
            return
        }
        flight = plan
        flightStart = .now
    }

    private func finishFlight() async {
        guard let plan = flight, let id = flyingID else { return }
        try? await Task.sleep(for: .seconds(plan.duration + 0.25))
        guard !Task.isCancelled, flight == plan else { return }
        camera = plan.camera(at: plan.duration)
        flight = nil
        flyingID = nil
        focusedID = id
        openedID = id
    }

    private func backToGlobe() {
        focusedID = nil
        isPlanUp = false
        planDayKey = nil
        openedID = nil
        flyingID = nil
        flight = nil
        camera.radius = restRadius
    }

    private func highlight(_ destination: TravelModeDestination?) -> Set<String> {
        guard let destination else { return [] }
        if let province = destination.province { return [province.code] }
        return destination.country.map { [$0.code] } ?? []
    }

    private func pins(_ destination: TravelModeDestination?) -> [TravelGlobeRenderer.Pin] {
        (destination?.stops ?? []).enumerated().map { .init(longitude: $1.longitude, latitude: $1.latitude, label: "\($0 + 1)", id: $1.itemID ?? "") }
    }

    // MARK: 글

    private func tag(_ entry: TravelTripDirectory.Entry) -> String {
        switch entry.state {
        case .active: language.text("여행 중", "On trip")
        case .upcoming: "D-\(entry.daysUntilStart ?? 0)"
        case .past: language.text("지난 여행", "Past")
        case .someday: language.text("언젠가", "Someday")
        }
    }

    private func length(_ entry: TravelTripDirectory.Entry) -> String {
        entry.isDayTrip
            ? language.text("당일", "Day trip")
            : language.runtimeText("\(entry.nights)박 \(entry.dayCount)일", "\(entry.nights) nights, \(entry.dayCount) days")
    }

    private func title(_ entry: TravelTripDirectory.Entry) -> String {
        entry.trip.title.isEmpty ? language.text("이름 없는 여행", "Untitled trip") : entry.trip.title
    }

    // MARK: 지구본 화면

    private func cardColumn(_ entries: [TravelTripDirectory.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { dismiss() } label: { TravelRoundButtonLabel(symbol: "house.fill", fill: TravelInk.panel) }
                .accessibilityLabel(language.text("일상으로 돌아가기", "Back to everyday"))
                // 확대하면 바탕이 밝은 땅이 된다. 어느 바탕에서도 읽히게 판 위에 쓴다.
                Text(language.text("여행", "Trips")).font(.headline).padding(.horizontal, 12).frame(height: TaptionControl.chip)
                    .background(TravelInk.panel, in: Capsule())
                    .overlay { Capsule().stroke(TravelInk.border, lineWidth: TaptionBorder.width) }
                if TripShareStore.shared.isAvailable {
                    Button { shareRoute = .join(nil) } label: { TravelRoundButtonLabel(symbol: "person.badge.plus", fill: TravelInk.panel) }
                    .accessibilityLabel(language.text("초대로 참여", "Join with an invite"))
                    .accessibilityIdentifier("travelShareJoin")
                }
            }
            if entries.isEmpty {
                Text(language.text("아직 여행이 없습니다. 아래에서 첫 여행을 만들어 보세요.", "No trips yet. Make your first one below."))
                    .font(.footnote).padding(.horizontal, 12).padding(.vertical, 10).frame(width: 220, alignment: .leading)
                    .background(TravelInk.panel, in: RoundedRectangle(cornerRadius: TaptionCorner.medium))
                    .accessibilityIdentifier("travelNoTrips")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in card(entry) }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 330)
        }
        .foregroundStyle(TravelInk.plan)
        .padding(.leading, 14)
        .padding(.top, 8)
    }

    private func card(_ entry: TravelTripDirectory.Entry) -> some View {
        let order = entries.firstIndex { $0.id == entry.id } ?? 0
        let flagColor = Color(hex: TravelInk.flagHex(entry.trip, order: order))
        return Button { select(entry) } label: {
            if entry.state == .someday {
                TravelWishCard(title: title(entry), length: length(entry), tag: tag(entry), color: flagColor, isChosen: entry.id == (flyingID ?? focusedID))
            } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(tag(entry))
                    Spacer(minLength: 6)
                    if let currency = entry.trip.currencyCode { Text(currency) }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(TravelInk.land)
                .padding(.leading, 9)
                .padding(.trailing, 34)
                .frame(height: 26)
                .background(flagColor.opacity(entry.state == .past ? 0.6 : 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(entry)).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(length(entry)).font(.caption).opacity(0.8)
                    TripShareMemberBadge(tripID: entry.id, language: language)
                    if let money = book.trip(entry.id).map({ TravelPlanSpend.headline(LedgerTripMath.sheet($0, entries: book.entries)) }) {
                        let amount = LedgerMoney.text(money.amount, language: language)
                        Text(money.isLeftover ? language.runtimeText("남은 돈 \(amount)", "Left \(amount)") : language.runtimeText("쓴 돈 \(amount)", "Spent \(amount)"))
                            .font(.caption2.weight(.medium)).foregroundStyle(money.isLeftover && money.amount < 0 ? TravelInk.actual : TravelInk.plan)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 220)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: TaptionCorner.medium))
            .overlay { RoundedRectangle(cornerRadius: TaptionCorner.medium).stroke(entry.id == (flyingID ?? focusedID) ? flagColor : .clear, lineWidth: 2.5) }
            }
        }
        .buttonStyle(.plain)
        // 길게 누르기를 모르는 사람도 고치기·지우기를 찾게 ⋯ 단추로도 같은 메뉴를 연다(TVX1116A01).
        .overlay(alignment: .topTrailing) {
            Menu { cardMenu(entry) } label: {
                // 메뉴는 그림 밖 contentShape를 누르는 자리로 쓰지 않아 틀 자체를 44×44로 둔다. 그림은 오른쪽 위 그대로, 넓힌 자리는 카드 안쪽(TVM1117A02).
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 26)
                    .padding(.leading, 10).padding(.bottom, 18).contentShape(Rectangle())
                    .foregroundStyle(entry.state == .someday ? TravelInk.plan : TravelInk.land)
            }
            .accessibilityLabel(language.text("여행 메뉴", "Trip menu"))
            .accessibilityIdentifier("travelTripCardMenu-\(entry.id)")
        }
        .contextMenu { cardMenu(entry) }
        .accessibilityIdentifier("travelTripCard-\(entry.id)")
    }

    @ViewBuilder private func cardMenu(_ entry: TravelTripDirectory.Entry) -> some View {
            // 깃발 색 고르기. 저장한 여행만 바꿀 수 있다.
            if entry.isStored {
                ForEach(TravelInk.flagHexes, id: \.self) { hex in
                    Button { setFlagColor(hex, for: entry) } label: {
                        // 메뉴는 아이콘을 한 색으로 칠하므로, 원래 색 그림으로 견본을 넣는다. 고른 색에는 체크가 들어간다.
                        Label { Text(TravelInk.flagName(hex, language: language)) } icon: {
                            Image(uiImage: TravelInk.swatch(hex, isChosen: entry.trip.flagColorHex == hex))
                        }
                    }
                }
                Button(language.text("기본 색으로", "Use default color")) { setFlagColor(nil, for: entry) }
                Divider()
            }
            Button(language.text("여행 고치기", "Edit trip"), systemImage: "pencil") {
                shareEdit(entry, .tripInfo) { newTripDraft = .init(isDayTrip: entry.isDayTrip, editing: entry.trip) }
            }
            Button(language.text("여행 지우기", "Delete trip"), systemImage: "trash", role: .destructive) { deleteCandidate = entry }
    }

    /// 여행을 고르면 두 단추로 바로 들어간다(TPB1114A01): 왼쪽 카드(코스), 오른쪽 상세(계획표). 아니면 새 여행·당일치기.
    private func globeFooter(_ entry: TravelTripDirectory.Entry?) -> some View {
        HStack(spacing: 10) {
            if let entry {
                footerButton("rectangle.stack", language.text("카드로 짜기", "Plan with cards")) { enterPlan(entry, course: true) }
                footerButton("tablecells", language.text("상세로 짜기", "Plan in detail")) { enterPlan(entry, course: false) }
            } else {
                footerButton("plus", language.text("새 여행", "New trip")) { newTripDraft = .init(isDayTrip: false) }
                footerButton("sun.max", language.text("오늘 당일치기", "Day trip today")) { newTripDraft = .init(isDayTrip: true) }
                Button { isImportPresented = true } label: {
                    Image(systemName: "sparkles").font(.system(size: 17, weight: .medium)).frame(width: TaptionControl.primary, height: TaptionControl.primary)
                        .background(TravelInk.panel, in: Circle())
                        .overlay { Circle().stroke(TravelInk.border, lineWidth: TaptionBorder.width) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(TravelInk.plan)
                .accessibilityLabel(language.text("AI로 만들기", "Plan with AI"))
                .accessibilityIdentifier("travelImportAI")
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    /// 고른 여행에 들어가 계획 판을 올린다. 카드(코스)와 상세(계획표) 중 고른 쪽을 그 여행에 기억한다.
    private func enterPlan(_ entry: TravelTripDirectory.Entry, course: Bool) {
        tableTrips = TravelCoursePlanner.tableTrips(tableTrips, tripID: entry.id, showsCourse: course)
        let destination = TravelModeDestination(trip: entry.trip, stops: model.settings.travelPlanStops)
        if let last = cameras(for: destination).last { camera = last }
        (flight, flyingID) = (nil, nil) // 도는 중에 눌렀으면 비행을 끝내고 바로 들어간다(TFM1114A01).
        focusedID = entry.id
        openedID = entry.id
        withAnimation(.snappy(duration: 0.25)) { isPlanUp = true }
    }

    private func footerButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).frame(height: TaptionControl.primary)
                .background(TravelInk.panel, in: Capsule())
                .overlay { Capsule().stroke(TravelInk.border, lineWidth: TaptionBorder.width) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(TravelInk.plan)
    }

    // MARK: 여행 화면 뼈대

    private func tripHeader(_ entry: TravelTripDirectory.Entry) -> some View {
        // 여행 이름 줄이 맨 위, 돈 줄은 그 아래에 따로 둔다(대표 지시).
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // 뒤로가기: 여행 목록(지구본)으로. 지구본 그림만으로는 뒤로가기인 줄 알기 어려웠다(대표 지적).
                Button(action: backToGlobe) { TravelRoundButtonLabel(symbol: "chevron.left", fill: TravelInk.land) }
                .accessibilityLabel(language.text("여행 목록으로", "Back to trips"))
                .accessibilityIdentifier("travelTripBack")
                // Trip 원본처럼 여행 이름을 누르면 여행 속성(이름·기간·나라)을 고친다.
                Button { shareEdit(entry, .tripInfo) { newTripDraft = .init(isDayTrip: entry.isDayTrip, editing: entry.trip) } } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(entry)).font(.headline).lineLimit(1)
                        Text(subtitle(entry)).font(.caption).opacity(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(language.text("여행 고치기", "Edit trip"))
                // 여행 공유(TSH1114A26). 서버 주소가 없는 빌드에서는 숨긴다.
                if TripShareStore.shared.isAvailable, entry.isStored {
                    Button { shareRoute = .panel(tripID: entry.id) } label: { TravelRoundButtonLabel(symbol: "person.2.fill", fill: TravelInk.land) }
                    .accessibilityLabel(language.text("여행 공유", "Share trip"))
                    .accessibilityIdentifier("travelTripShare")
                }
                // 일상 화면으로 바로 나간다.
                Button { exitToDaily(entry) } label: { TravelRoundButtonLabel(symbol: "house.fill", fill: TravelInk.land) }
                .accessibilityLabel(language.text("일상으로 돌아가기", "Back to everyday"))
                .accessibilityIdentifier("travelTripHome")
            }
            .padding(8)
            .background(TravelInk.panel, in: RoundedRectangle(cornerRadius: TaptionCorner.large))
            .overlay { RoundedRectangle(cornerRadius: TaptionCorner.large).stroke(TravelInk.border, lineWidth: 1) }
            moneyBar(entry)
            TripShareStatusBand(language: language, tripID: entry.id)
            TripLiveLocationBand(language: language, tripID: entry.id)
            TripShareNoticeBand(model: model, language: language, tripID: entry.id)
        }
        .foregroundStyle(TravelInk.plan)
        // 넓은 화면에서 줄이 끝까지 늘어나지 않게 왼쪽에 묶는다.
        .frame(maxWidth: 520)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func subtitle(_ entry: TravelTripDirectory.Entry) -> String {
        let state: String = switch entry.state {
        case .active: language.runtimeText("\(entry.dayNumber ?? 1)일차", "Day \(entry.dayNumber ?? 1)")
        case .upcoming: "D-\(entry.daysUntilStart ?? 0)"
        case .past: language.text("지난 여행", "Past")
        case .someday: language.text("언젠가", "Someday")
        }
        return "\(length(entry)) · \(state)"
    }

    /// 맨 위 돈 표시줄의 자리. 지금은 예산 대비 남은 돈과 쓴 돈만 보인다(통화별 칸은 지갑 단계에서).
    private func moneyBar(_ entry: TravelTripDirectory.Entry) -> some View {
        // 계획표가 올라와 있으면 재생 헤드의 시각까지 쓴 돈을 보인다(Trip과 같게).
        let upTo: Date? = isPlanUp && openedID == entry.id ? playDate(entry) : nil
        let counted = upTo.map { limit in book.entries.filter { $0.occurredAt <= limit } } ?? book.entries
        let sheet = book.trip(entry.id).map { LedgerTripMath.sheet($0, entries: counted) }
        return TravelMoneyBar(sheet: sheet, isUpTo: upTo != nil, language: language) { ledgerTripID = entry.id }
    }

    private func tripFooter(_ entry: TravelTripDirectory.Entry) -> some View {
        let items = (model.settings.travelTripItems ?? []).filter { $0.tripID == entry.id }.sorted { $0.start < $1.start }
        return TravelTripFooter(items: items, tripID: entry.id, language: language, actions: [
            .init(language.text("일정 넣기", "Add plan"), "calendar.badge.plus") { addEntry(entry, cell: planCell) },
            .init(language.text("곳 더하기", "Add a stop"), "mappin.and.ellipse") { courseAdding = entry },
            .init(language.text("열 편집", "Edit columns"), "rectangle.split.3x1") { columnsTrip = entry.trip },
            .init(language.text("AI로 만들기", "Plan with AI"), "sparkles") { isImportPresented = true },
            .init(language.text("지출 넣기", "Add expense"), "wonsign") { addExpense(entry, minute: nil) },
            .init(language.text("계획과 실제", "Plan vs actual"), "chart.bar.xaxis") { realityDay = .init(date: dayDate(dayKey(entry))) },
        ]) { withAnimation(.snappy(duration: 0.25)) { isPlanUp.toggle() } }
    }

    /// 여행 중이고 보는 날이 오늘이면, 내린 판에 한 줄 대신 오늘 카드를 보인다(TVZ1116C01).
    @ViewBuilder private func sheetFoot(_ entry: TravelTripDirectory.Entry) -> some View {
        if !isPlanUp, entry.state == .active, dayKey(entry) == today() {
            TravelTodayCard(
                model: model, entry: entry, blocks: table(entry).blocks, travelMinutes: routes.minutes,
                sheet: book.trip(entry.id).map { LedgerTripMath.sheet($0, entries: book.entries) }, language: language,
                onExpense: { addExpense(entry, minute: nil) }, onAddStop: { courseAdding = entry },
                onReality: { realityDay = .init(date: dayDate(dayKey(entry))) }, onRaise: { withAnimation(.snappy(duration: 0.25)) { isPlanUp = true } }
            )
        } else {
            tripFooter(entry)
        }
    }

    /// 코스에서 곳 더하기(TVV1113A01 C2): 편집기를 거치지 않고 그날 코스 끝에 붙인다. 시각은 앱이 잡는다.
    private func addCourseStop(_ entry: TravelTripDirectory.Entry, name: String, place: TravelItemPlace?, kind: String) {
        let key = dayKey(entry), table = table(entry), kind = TripImportItem.Kind(rawValue: kind) ?? .sight
        let slot = TravelCoursePlanner.nextSlot(blocks: table.blocks, kind: kind.rawValue, nowMinute: table.nowMinute)
        // 출국 비행 전은 출발지, 도착부터는 여행지 시차(REV1117A01).
        let offset = TravelTimeZones.offset(trip: entry.trip, items: model.settings.travelTripItems ?? [], dayKey: key, minute: slot.start)
        let start = TravelQuickEntrySheet.date(dayKey: key, minute: slot.start, offsetSeconds: offset)
        shareEdit(entry, .addStop(dayKey: key)) {
            Task {
                guard let id = await TripSharePlanEditor.addItem(
                    model: model, tripID: entry.id, kind: kind, title: name, start: start, end: start.addingTimeInterval(TimeInterval(slot.duration * 60)),
                    offsetSeconds: offset, place: place
                ), let added = (model.settings.travelTripItems ?? []).first(where: { $0.tripID == entry.id && $0.itemID == id }) else { return }
                planHistory.record(.existence(added, place: place, exists: true))
                playMinute = slot.start
            }
        }
    }

    /// 공유 여행의 편집은 공유 편집기가 먼저 받는다(TSH1114A26). 공유하지 않는 여행은 `local`을 그대로 한다.
    private func shareEdit(_ entry: TravelTripDirectory.Entry, _ edit: TripSharePlanEdit, _ local: @escaping () -> Void) {
        TripSharePlanEditor.route(model: model, tripID: entry.id, edit: edit, local: local)
    }

    // MARK: 계획표와 시간 막대(같은 날·같은 자료를 본다)

    private func dayKey(_ entry: TravelTripDirectory.Entry) -> String {
        if let planDayKey, planDayKey >= entry.trip.planStartDay, planDayKey <= entry.trip.planEndDay { return planDayKey }
        return entry.state == .active ? today() : entry.trip.planStartDay
    }

    private func dayDate(_ key: String) -> Date {
        TravelTripDay.components(key).flatMap(Calendar.autoupdatingCurrent.date(from:)) ?? .now
    }

    /// 그날 계획표 모델. 본문 한 번에 여러 곳이 묻지만 내용이 같으면 한 번만 만든다(TVM1117A02).
    private func table(_ entry: TravelTripDirectory.Entry) -> TravelPlanTableModel {
        let key = dayKey(entry), now = Date.now
        let cacheKey = TravelPlanTableCache.Key(
            tripID: entry.id, dayKey: key, contentRevision: model.snapshotContentRevision, ledgerRevision: book.revision,
            columns: entry.trip.columns, nowMinute: TravelPlanTableCache.minute(now), timeZone: TimeZone.autoupdatingCurrent.identifier
        )
        return tableCache.table(cacheKey) { makeTable(entry, dayKey: key, now: now) }
    }

    private func makeTable(_ entry: TravelTripDirectory.Entry, dayKey: String, now: Date) -> TravelPlanTableModel {
        let day = dayDate(dayKey)
        return TravelPlanTableModel.make(
            items: model.settings.travelTripItems ?? [], tripID: entry.id, day: day,
            actual: MapHomeTimeRailSegmentEngine.segments(from: model.snapshot.actuals, on: day), now: now,
            spent: TravelPlanSpend.byItem(items: model.settings.travelTripItems ?? [], tripID: entry.id, entries: book.entries),
            columns: TravelPlanColumns.resolved(entry.trip.columns)
        )
    }

    /// 아래 시트: 내려 있으면 다음 일정 한 줄, 끌어올리면 계획표.
    private func planSheet(_ entry: TravelTripDirectory.Entry) -> some View {
        // 메인 홈 하단 메뉴와 같은 높이·여백·곡률이고 화면 아래 끝까지 내려간다(TVA1113A01, 대표 지시).
        let corner = MapHomeBottomBarMetrics.pillHeight / 2
        return VStack(spacing: 0) {
            if isPlanUp {
                TravelPlanHandleBar(
                    language: language, isMapFolded: TravelPlanSheetHeight.isMapFolded(planDragHeight ?? tableHeight, size: viewSize),
                    canResize: !Self.isWide(viewSize),
                    onLower: { withAnimation(.snappy(duration: 0.25)) { isPlanUp = false } },
                    onToggleMap: { withAnimation(.snappy(duration: 0.25)) { planHeight = Double(TravelPlanSheetHeight.toggled(tableHeight, size: viewSize)) } },
                    onDrag: { translation, isDone in
                        // 끄는 동안 높이를 따라 바꾸면 계획표가 계속 다시 그려져 떨린다(대표 신고). 손을 떼면 한 번에 끝으로 간다(PSN1114A01).
                        guard isDone, let next = TravelPlanSheetHeight.snapped(from: tableHeight, translation: translation, size: viewSize) else { return }
                        withAnimation(.snappy(duration: 0.25)) { planHeight = Double(next) }
                    }
                )
                dayChips(entry)
                TravelPuzzleDrawer(model: model, tripID: entry.id, language: language)
                if showsCourse(entry) {
                    TravelCourseView(
                        table: table(entry), items: (model.settings.travelTripItems ?? []).filter { $0.tripID == entry.id }, language: language,
                        playMinute: currentPlayMinute(entry), photos: model.photoService, selectedID: $planSelectedID,
                        onScrub: { playMinute = $0 }, onEdit: { editEntry(entry, itemID: $0.id) }, onAddStop: { courseAdding = entry }, onAddDetail: { addEntry(entry, detailOf: $0) },
                        onReorder: { step in shareEdit(entry, .reorder(dayKey: dayKey(entry))) { Task { if await TripSharePlanEditor.applyStep(model: model, step) { planHistory.record(step) } } } }, onDelete: { deleteEntry(entry, itemID: $0.id) },
                        placePhotos: placePhotos.photos
                    )
                    .task(id: model.settings.travelPlanStops.count) {
                        // 위키백과 사진은 늘 받는다(WPA1114A01, 대표 지시: 메뉴 스위치 없앰). 연락처가 없으면 가게 안에서 받지 않는다.
                        await placePhotos.load(TravelPlacePhotoStore.Place.places(tripID: entry.id, stops: model.settings.travelPlanStops))
                    }
                    .frame(height: planDragHeight ?? tableHeight)
                } else {
                TravelPlanTable(
                    table: table(entry), language: language, shareTripID: entry.id,
                    onSelect: { block in editEntry(entry, itemID: block.id) },
                    onExpense: { block in addExpense(entry, minute: block.startMinute, itemID: block.id) },
                    onDelete: { block in deleteEntry(entry, itemID: block.id) },
                    onAdd: { cell in addEntry(entry, cell: cell) },
                    cell: $planCell,
                    onMove: { block, minutes in editTimes(entry, block: block, move: minutes) },
                    onResize: { block, minutes in editTimes(entry, block: block, resize: minutes) },
                    playMinute: currentPlayMinute(entry),
                    onScrub: { playMinute = $0 }, onExpenseAt: { addExpense(entry, minute: $0) }, selection: $planSelectedID,
                    tightIDs: TravelPlayhead.tightStops(playStops(entry), travelMinutes: routes.minutes),
                    onEditColumns: { columnsTrip = entry.trip }
                )
                    .id(dayKey(entry))
                    .frame(height: planDragHeight ?? tableHeight)
                    .padding(.horizontal, 8)
                }
            }
            // 공유 여행에서는 되돌리기를 쓰지 않는다(대표 결정, TSH1114A26).
            if isPlanUp, planHistory.tripID == entry.id, planHistory.canUndo || planHistory.canRedo, !model.isSharedTrip(entry.id) {
                TravelPlanHistoryBar(history: planHistory, language: language, onUndo: { applyHistory(planHistory.undo()) }, onRedo: { applyHistory(planHistory.redo()) })
            }
            sheetFoot(entry)
        }
        .travelDayBoard(model: model, tripID: entry.id, trip: entry.trip, dayKey: dayKey(entry), blocks: table(entry).blocks, language: language, history: $planHistory)
        .background(TravelInk.panel, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: corner, style: .continuous).stroke(TravelInk.border, lineWidth: 1) }
        .frame(maxWidth: Self.isWide(viewSize) ? min(460, viewSize.width * 0.5) : .infinity)
        .padding(.horizontal, MapHomeBottomBarMetrics.edgeMargin)
        .padding(.bottom, MapHomeBottomBarMetrics.edgeMargin)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .ignoresSafeArea(edges: .bottom)
        .gesture(DragGesture(minimumDistance: 12).onEnded { value in
            // 위로 끌면 올리고 아래로 끌면 내린다.
            guard abs(value.translation.height) > 30 else { return }
            withAnimation(.snappy(duration: 0.25)) { isPlanUp = value.translation.height < 0 }
        })
    }

    private func dayLabel(_ entry: TravelTripDirectory.Entry, key: String) -> String {
        guard !entry.isDayTrip, let number = TravelTripDay.days(from: entry.trip.planStartDay, to: key) else { return language.text("당일", "Day trip") }
        return language.runtimeText("\(number + 1)일차", "Day \(number + 1)")
    }

    /// 일정 넣기. 고른 셀이 있으면 그 열·그 시각·그 길이, 없으면 그날 마지막 일정 끝에서 잇는다.
    private func addEntry(_ entry: TravelTripDirectory.Entry, cell: TravelPlanCell? = nil, detailOf parent: TravelPlanTableModel.Block? = nil) {
        let column = cell?.column
        // 세부 계획이면 그 코스 곳 안의 시각으로 연다.
        let detail = parent.map { TravelCourse.detailSlot(parent: $0, details: TravelCourse.details(of: $0, in: table(entry).blocks)) }
        let minute = detail?.start ?? cell?.minute
        if planCell != nil { planCell = nil }
        let key = dayKey(entry), table = table(entry)
        let kind = column.map { TravelPlanColumns.kind(forColumn: $0, in: table.columns) }.flatMap(TripImportItem.Kind.init(rawValue:)) ?? (parent == nil ? .sight : .other)
        var target = TravelQuickEntrySheet.Target.new(
            trip: entry.trip, dayKey: key, dayLabel: dayLabel(entry, key: key),
            startMinute: minute ?? TravelCoursePlanner.nextStart(blocks: table.blocks, nowMinute: table.nowMinute), kind: kind
        )
        target.anchor = TravelModeDestination(trip: entry.trip, stops: model.settings.travelPlanStops).point
        target.duration = detail?.duration ?? cell?.chosenDuration
        target.parentItemID = parent?.id
        shareEdit(entry, .add(dayKey: key, parentItemID: parent?.id)) { entryTarget = target }
    }

    /// 계획표에서 끌어 옮기거나 길이를 바꾼 것을 저장하고, 되돌릴 수 있게 남긴다.
    private func editTimes(_ entry: TravelTripDirectory.Entry, block: TravelPlanTableModel.Block, move: Int = 0, resize: Int = 0) {
        shareEdit(entry, move != 0 ? .move(itemID: block.id, minutes: move) : .resize(itemID: block.id, minutes: resize)) { Task {
            let done = move != 0
                ? await TripSharePlanEditor.moveItem(model: model, tripID: entry.id, itemID: block.id, by: TimeInterval(move * 60))
                : await TripSharePlanEditor.resizeItem(model: model, tripID: entry.id, itemID: block.id, endDelta: TimeInterval(resize * 60))
            guard done else { return }
            let start = block.startMinute + move, end = block.endMinute + move + resize
            withAnimation(.snappy(duration: 0.2)) {
                planHistory.record(.init(
                    tripID: entry.id, itemID: block.id, move: move, resize: resize,
                    summary: block.title + " " + TravelQuickEntrySheet.clock(start) + "–" + TravelQuickEntrySheet.clock(end)
                ))
            }
        } }
    }

    /// 되돌리기·다시 하기에서 나온 한 걸음을 저장소에 반영한다.
    private func applyHistory(_ step: TravelPlanHistory.Step?) {
        guard let step else { return }
        TripSharePlanEditor.route(model: model, tripID: step.tripID, edit: .history) { Task { await model.applyTravelHistory(step) } }
    }

    /// 선택 막대에서 지움: 되돌릴 수 있게 그 일정과 장소를 쌓아 둔다.
    private func deleteEntry(_ entry: TravelTripDirectory.Entry, itemID: String) {
        shareEdit(entry, .delete(itemID: itemID)) {
            Task { if let step = await TripSharePlanEditor.deleteItem(model: model, tripID: entry.id, itemID: itemID) { planHistory.record(step) } }
        }
    }

    private func editEntry(_ entry: TravelTripDirectory.Entry, itemID: String) {
        guard let item = (model.settings.travelTripItems ?? []).first(where: { $0.tripID == entry.id && $0.itemID == itemID }) else { return }
        var target = TravelQuickEntrySheet.Target.edit(item, dayLabel: dayLabel(entry, key: TravelTripDay.string(for: item.start, offsetSeconds: item.startOffsetSeconds)))
        target.anchor = TravelModeDestination(trip: entry.trip, stops: model.settings.travelPlanStops).point
        if let stop = model.settings.travelPlanStops.first(where: { $0.tripID == entry.id && $0.itemID == itemID }) {
            target.place = TravelItemPlace(name: stop.title, latitude: stop.latitude, longitude: stop.longitude)
        }
        shareEdit(entry, .open(itemID: itemID)) { entryTarget = target }
    }

    private func dayChips(_ entry: TravelTripDirectory.Entry) -> TravelDayChips {
        TravelDayChips(days: TravelPlanDays.days(of: entry.trip).map { day in
            let label = dayLabel(entry, key: day.key)
            return (day.key, entry.isDayTrip || entry.trip.isWish ? label : label + " " + TravelPlanDays.shortDate(day.key))
        }, selected: dayKey(entry), showsCourse: Binding(get: { showsCourse(entry) }, set: { tableTrips = TravelCoursePlanner.tableTrips(tableTrips, tripID: entry.id, showsCourse: $0) })) { planDayKey = $0 }
    }

    private func showsCourse(_ entry: TravelTripDirectory.Entry) -> Bool { TravelCoursePlanner.showsCourse(tableTrips, tripID: entry.id) }

    /// 지도 핀을 누름(Trip 원본): 편집기를 열지 않고 그 일정을 고르고, 계획표를 그날·그 시각으로 옮긴다.
    private func selectPin(_ entry: TravelTripDirectory.Entry, itemID: String) {
        guard let item = (model.settings.travelTripItems ?? []).first(where: { $0.tripID == entry.id && $0.itemID == itemID }) else { return }
        let focus = TravelMapSpot.focus(item)
        if dayKey(entry) != focus.dayKey { planDayKey = focus.dayKey }
        withAnimation(.snappy(duration: 0.25)) { isPlanUp = true }
        // 날이 바뀌면 재생 시각이 지워지므로 그 뒤에 넣는다.
        Task { @MainActor in
            playMinute = focus.minute
            planSelectedID = itemID
        }
    }

    /// 빈 지도를 길게 누름(Trip 원본): 그 자리를 장소로 붙인 새 일정 편집기를 연다.
    private func addEntry(_ entry: TravelTripDirectory.Entry, at spot: SIMD2<Double>) {
        Task { @MainActor in
            let place = await TravelMapSpot.place(latitude: spot.y, longitude: spot.x)
            addEntry(entry)
            entryTarget?.place = place
        }
    }
}

/// 계획표에서 방금 끌어 바꾼 시각(되돌리기용).
private struct TravelLedgerTarget: Identifiable {
    let id: String
}
