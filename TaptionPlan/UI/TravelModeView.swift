import SwiftUI
import TaptionPlanStore

/// 지구본 그리기. 나라 경계 자료만으로 그려 인터넷 없이도 같은 그림이 나온다.
enum TravelGlobeRenderer {
    struct Pin {
        var longitude: Double
        var latitude: Double
        var label: String
        /// 그 핀의 일정(누르면 그 일정을 연다)과 이름.
        var id = ""
        var title = ""
    }

    struct Flag {
        var id = ""
        var longitude: Double
        var latitude: Double
        var text: String
        /// 0 = 아직 없음, 1 = 꽂힘.
        var progress: Double
        var color: Color = TravelInk.actual
        /// 지난 여행은 옅게.
        var opacity: Double = 1
        /// 고른 깃발만 D-Day 이름표를 단다.
        var showsLabel = true
    }

    /// 그 깃발이 화면에서 꽂힌 자리. 지구 뒤쪽이면 nil.
    static func foot(of flag: Flag, camera: TravelGlobeCamera, size: CGSize) -> CGPoint? {
        let (base, front) = point(camera, center(in: size), flag.longitude, flag.latitude)
        return front ? base : nil
    }

    static func center(in size: CGSize) -> CGPoint { CGPoint(x: size.width / 2, y: size.height * 0.54) }

    /// 지도 위 캐릭터(재생 헤드의 시각에 있는 자리).
    struct Actor {
        var longitude: Double
        var latitude: Double
        var image: Image
        var facesEast: Bool
    }

    /// `offset`은 지도 가운데를 옮기는 양: 계획표가 올라오면 시트에 가리지 않는 자리의 가운데로 옮긴다.
    static func draw(
        _ context: inout GraphicsContext, size: CGSize, camera: TravelGlobeCamera, highlight: Set<String>,
        flags: [Flag], pins: [Pin], offset: CGSize = .zero, actor: Actor? = nil,
        home: SIMD2<Double>? = nil, route: [SIMD2<Double>] = []
    ) {
        let base = center(in: size)
        let center = CGPoint(x: base.x + offset.width, y: base.y + offset.height)
        let radius = camera.radius
        let covers = radius > hypot(size.width, size.height)
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(covers ? TravelInk.sea : TravelInk.space))
        if !covers {
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(TravelInk.sea))
            if radius < 900 { context.stroke(graticule(camera, center: center), with: .color(TravelInk.grid), lineWidth: 0.5) }
        }
        let showsProvinces = radius > 1_800
        var land = Path(), marked = Path()
        for region in TravelModeRegions.countries where isVisible(region, camera: camera, center: center, size: size) {
            if highlight.contains(region.code) {
                add(region, to: &marked, camera: camera, center: center)
            } else {
                add(region, to: &land, camera: camera, center: center)
            }
        }
        context.fill(land, with: .color(TravelInk.land))
        context.stroke(land, with: .color(TravelInk.border), lineWidth: 0.5)
        context.fill(marked, with: .color(TravelInk.planTint))
        context.stroke(marked, with: .color(TravelInk.plan), lineWidth: 1.5)
        if showsProvinces {
            var plain = Path(), chosen = Path()
            for region in TravelModeRegions.provinces where isVisible(region, camera: camera, center: center, size: size) {
                if highlight.contains(region.code) {
                    add(region, to: &chosen, camera: camera, center: center)
                } else {
                    add(region, to: &plain, camera: camera, center: center)
                }
            }
            context.fill(plain, with: .color(TravelInk.land))
            context.stroke(plain, with: .color(TravelInk.border), lineWidth: 0.5)
            context.fill(chosen, with: .color(TravelInk.planTint))
            context.stroke(chosen, with: .color(TravelInk.plan), lineWidth: 1.5)
        }
        if let home { drawHome(&context, home: home, flags: flags, camera: camera, center: center) }
        drawPins(&context, pins: pins, route: route, camera: camera, center: center)
        if let actor {
            let (spot, front) = point(camera, center, actor.longitude, actor.latitude)
            if front {
                // 발이 그 자리에 오게 위로 올려 그리고, 서쪽으로 갈 때는 좌우를 뒤집는다.
                var layer = context
                layer.translateBy(x: spot.x, y: spot.y - 20)
                if !actor.facesEast { layer.scaleBy(x: -1, y: 1) }
                layer.draw(actor.image, in: CGRect(x: -24, y: -24, width: 48, height: 48))
            }
        }
        // 이름표를 단 깃발을 맨 위에 그린다.
        for flag in flags.sorted(by: { !$0.showsLabel && $1.showsLabel }) where flag.progress > 0 {
            drawFlag(&context, flag: flag, camera: camera, center: center)
        }
    }

    private static func point(_ camera: TravelGlobeCamera, _ center: CGPoint, _ longitude: Double, _ latitude: Double) -> (CGPoint, Bool) {
        let projected = camera.project(longitude: longitude, latitude: latitude)
        return (CGPoint(x: center.x + projected.point.x, y: center.y + projected.point.y), projected.isFront)
    }

    /// 지구 뒤쪽이거나 화면 밖인 곳은 그리지 않는다.
    private static func isVisible(_ region: TravelGlobeRegion, camera: TravelGlobeCamera, center: CGPoint, size: CGSize) -> Bool {
        let corners = [(region.west, region.south), (region.west, region.north), (region.east, region.south), (region.east, region.north),
                       (region.center.x, region.center.y), (region.anchor.x, region.anchor.y)]
        let projected = corners.map { point(camera, center, $0.0, $0.1) }
        guard projected.contains(where: { $0.1 }) else { return false }
        // 넓은 나라는 상자 모서리가 모두 화면 밖이어도 화면을 덮을 수 있어, 충분히 확대했을 때만 화면 밖을 거른다.
        guard camera.radius > 600, region.east - region.west < 40 else { return true }
        let margin: CGFloat = 80
        let xs = projected.map(\.0.x), ys = projected.map(\.0.y)
        return !((xs.max() ?? 0) < -margin || (xs.min() ?? 0) > size.width + margin || (ys.max() ?? 0) < -margin || (ys.min() ?? 0) > size.height + margin)
    }

    /// 미리 구한 단위 벡터를 화면의 동·북·앞 방향에 내적해 놓는다(`TravelGlobeCamera.project`와 같은 결과).
    private static func add(_ region: TravelGlobeRegion, to path: inout Path, camera: TravelGlobeCamera, center: CGPoint) {
        guard let rings = TravelModeRegions.vectors[region.code] else { return }
        let lambda = camera.longitude * .pi / 180, phi = camera.latitude * .pi / 180
        let front = SIMD3(cos(phi) * cos(lambda), cos(phi) * sin(lambda), sin(phi))
        let east = SIMD3(-sin(lambda), cos(lambda), 0)
        let north = SIMD3(-sin(phi) * cos(lambda), -sin(phi) * sin(lambda), cos(phi))
        let radius = camera.radius
        let spans = TravelModeRegions.spans[region.code] ?? []
        // 화면에서 1.5pt보다 작은 섬은 건너뛴다(지구본일 때 작은 섬 수백 개가 그리는 시간을 차지한다).
        let smallest = 1.5 / (radius * .pi / 180)
        for (index, ring) in rings.enumerated() {
            if index > 0, index < spans.count, spans[index] < smallest { continue }
            var points: [CGPoint] = []
            points.reserveCapacity(ring.count)
            for vector in ring {
                var x = (vector * east).sum(), y = -(vector * north).sum()
                if (vector * front).sum() < 0 {
                    let length = (x * x + y * y).squareRoot()
                    if length > 0 {
                        x /= length
                        y /= length
                    }
                }
                points.append(CGPoint(x: center.x + x * radius, y: center.y + y * radius))
            }
            path.addLines(points)
            path.closeSubpath()
        }
    }

    private static func graticule(_ camera: TravelGlobeCamera, center: CGPoint) -> Path {
        var path = Path()
        func line(_ points: [(Double, Double)]) {
            var drawing = false
            for value in points {
                let (location, front) = point(camera, center, value.0, value.1)
                if front {
                    if drawing { path.addLine(to: location) } else { path.move(to: location); drawing = true }
                } else {
                    drawing = false
                }
            }
        }
        for longitude in stride(from: -180.0, to: 180.0, by: 30) { line(stride(from: -80.0, through: 80.0, by: 5).map { (longitude, $0) }) }
        for latitude in stride(from: -60.0, through: 60.0, by: 30) { line(stride(from: -180.0, through: 180.0, by: 5).map { ($0, latitude) }) }
        return path
    }

    /// 집 자리(집 아이콘)와, 집에서 여행지마다 가는 가는 점선(대표 지시: 점선·1pt·80%).
    private static func drawHome(_ context: inout GraphicsContext, home: SIMD2<Double>, flags: [Flag], camera: TravelGlobeCamera, center: CGPoint) {
        let (spot, front) = point(camera, center, home.x, home.y)
        guard front else { return }
        for flag in flags {
            let (end, visible) = point(camera, center, flag.longitude, flag.latitude)
            guard visible else { continue }
            var line = Path()
            line.move(to: spot)
            line.addLine(to: end)
            context.stroke(line, with: .color(TravelInk.plan.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        let rect = CGRect(x: spot.x - 11, y: spot.y - 11, width: 22, height: 22)
        context.fill(Path(ellipseIn: rect), with: .color(TravelInk.land))
        context.stroke(Path(ellipseIn: rect), with: .color(TravelInk.plan), lineWidth: 1.5)
        context.draw(Image(systemName: "house.fill").resizable(), in: rect.insetBy(dx: 5, dy: 5.5), style: FillStyle())
    }

    /// `route`가 있으면(길찾기로 받은 길) 핀을 곧게 잇는 대신 그 길을 그린다.
    private static func drawPins(_ context: inout GraphicsContext, pins: [Pin], route points: [SIMD2<Double>] = [], camera: TravelGlobeCamera, center: CGPoint) {
        let places = pins.map { (point(camera, center, $0.longitude, $0.latitude), $0.label) }.filter { $0.0.1 }
        guard !places.isEmpty else { return }
        var route = Path()
        if points.count > 1 {
            var isDrawing = false
            for spot in points {
                let (projected, front) = point(camera, center, spot.x, spot.y)
                if front { if isDrawing { route.addLine(to: projected) } else { route.move(to: projected) } }
                isDrawing = front
            }
        } else {
            for (index, place) in places.enumerated() {
                if index == 0 { route.move(to: place.0.0) } else { route.addLine(to: place.0.0) }
            }
        }
        context.stroke(route, with: .color(TravelInk.plan), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [6, 5]))
        for place in places {
            let rect = CGRect(x: place.0.0.x - 9, y: place.0.0.y - 9, width: 18, height: 18)
            context.fill(Path(ellipseIn: rect), with: .color(TravelInk.plan))
            context.stroke(Path(ellipseIn: rect), with: .color(TravelInk.land), lineWidth: 1.5)
            context.draw(Text(place.1).font(.system(size: 11, weight: .semibold)).foregroundStyle(TravelInk.land), at: place.0.0)
        }
    }

    private static func drawFlag(_ context: inout GraphicsContext, flag: Flag, camera: TravelGlobeCamera, center: CGPoint) {
        let (base, front) = point(camera, center, flag.longitude, flag.latitude)
        guard front else { return }
        var layer = context
        layer.opacity = min(1, flag.progress * 2) * flag.opacity
        let foot = CGPoint(x: base.x, y: base.y - (1 - flag.progress) * 60)
        var pole = Path()
        pole.move(to: foot)
        pole.addLine(to: CGPoint(x: foot.x, y: foot.y - 32))
        layer.stroke(pole, with: .color(flag.color), lineWidth: 2)
        var cloth = Path()
        cloth.move(to: CGPoint(x: foot.x, y: foot.y - 32))
        cloth.addLine(to: CGPoint(x: foot.x + 20, y: foot.y - 26))
        cloth.addLine(to: CGPoint(x: foot.x, y: foot.y - 20))
        cloth.closeSubpath()
        layer.fill(cloth, with: .color(flag.color))
        layer.fill(Path(ellipseIn: CGRect(x: foot.x - 3, y: foot.y - 3, width: 6, height: 6)), with: .color(flag.color))
        guard flag.showsLabel, flag.progress >= 1, !flag.text.isEmpty else { return }
        let label = layer.resolve(Text(flag.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(TravelInk.land))
        let textSize = label.measure(in: CGSize(width: 200, height: 40))
        let pill = CGRect(x: foot.x + 24, y: foot.y - 36, width: textSize.width + 16, height: textSize.height + 6)
        layer.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(flag.color))
        layer.draw(label, at: CGPoint(x: pill.midX, y: pill.midY))
    }
}

/// 여행 모드(TVB1112A01): 지구본과 여행 카드 → 누르면 지구가 돌고 깃발이 꽂히고 확대 → 여행 화면.
struct TravelModeView: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    /// 예전 지도 여행 모드로 그날을 연다. 일정 편집은 계획표가 생길 때까지 거기서 한다.
    let openPlan: (Date) -> Void

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
    @State private var entryTarget: TravelQuickEntrySheet.Target?
    /// 계획표에서 고른 빈 셀(TVU1113A01).
    @State private var planCell: TravelPlanCell?
    @State private var planSelectedID: String?
    @State private var columnsTrip: TravelTrip?
    /// 코스 보기를 고른 여행들(TVV1113A01). 고르지 않았으면 여행 중인 여행만 코스가 먼저.
    @State private var courseChoice: [String: Bool] = [:]
    @State private var planHistory = TravelPlanHistory()
    @State private var deleteCandidate: TravelTripDirectory.Entry?
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
            if let focused, openedID != nil, flight == nil, focused.state != .someday, !isPlanUp, pins(destination).isEmpty {
                Text(language.text("일정에 장소를 붙이면 지도에 나옵니다", "Add a place to a plan to see it on the map"))
                    .font(.footnote.weight(.semibold)).foregroundStyle(TravelInk.plan)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(TravelInk.panel, in: Capsule())
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if openedID == nil { cardColumn(entries) }
        }
        .overlay(alignment: .top) {
            if let focused, openedID != nil { tripHeader(focused) }
        }
        .overlay(alignment: .trailing) {
            if let focused, openedID != nil, !isPlanUp, focused.state != .someday {
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
                if focused.state == .someday {
                    TravelWishFooter(model: model, language: language, entry: focused)
                } else {
                    planSheet(focused)
                }
            } else {
                globeFooter
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
        .sheet(item: $columnsTrip) { TravelColumnEditorSheet(model: model, language: language, trip: $0) }
        .sheet(item: $entryTarget) { target in TravelQuickEntrySheet(model: model, language: language, target: target) { planHistory.record($0) } }
        .sheet(item: $expenseDraft) { draft in LedgerEntryForm(language: language, entry: draft, members: draft.tripID.flatMap(book.trip)?.members) }
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
        guard let target = Self.entryToOpen(entries, selectedDay: dayKey, lastTripID: lastTripID) else { return }
        focusedID = target.id
        let destination = TravelModeDestination(trip: target.trip, stops: model.settings.travelPlanStops)
        if let last = cameras(for: destination).last { camera = last }
        // 일상에서 보던 날이 그 여행 기간이면 계획표도 그날로 연다.
        if dayKey >= target.trip.startDay, dayKey <= target.trip.endDay { planDayKey = dayKey }
        openedID = target.id
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

    /// 재생 헤드가 가리키는 절대 시각(그 여행의 시간대, 없으면 기기 시간대).
    private func playDate(_ entry: TravelTripDirectory.Entry) -> Date {
        let zone = entry.trip.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        return TravelQuickEntrySheet.date(dayKey: dayKey(entry), minute: currentPlayMinute(entry), offsetSeconds: zone.secondsFromGMT())
    }

    /// 지출 넣기. 장부가 있으면 바로 입력 칸을 연다: 고른 일정의 시작, 없으면 재생 헤드의 시각(계획표가 내려 있으면 지금).
    private func addExpense(_ entry: TravelTripDirectory.Entry, minute: Int?) {
        guard book.trip(entry.id) != nil else { return ledgerTripID = entry.id }
        let zone = entry.trip.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
        let picked = minute.map { TravelQuickEntrySheet.date(dayKey: dayKey(entry), minute: $0, offsetSeconds: zone.secondsFromGMT()) }
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
        let spot = actor(entry)
        return TravelStreetMap(
            pins: planPins(entry, destination).map { .init(longitude: $0.longitude, latitude: $0.latitude, label: $0.label, id: $0.id, title: $0.title) },
            route: dayRoute(entry), actor: spot.map { .init(longitude: $0.longitude, latitude: $0.latitude, facesEast: $0.facesEast) },
            actorImage: pose(entry).map { actorArt.image($0, coat: model.settings.catStyle.rawValue) } ?? actorUIImage, fallback: destination?.point,
            // 위쪽 핀에 선 고양이가 머리말에 가리지 않게 고양이 키만큼 더 띄운다.
            insets: UIEdgeInsets(top: area.minY + 74, left: 28, bottom: viewSize.height - area.maxY + 24, right: viewSize.width - area.maxX + 28),
            fitKey: "\(entry.id)|\(dayKey(entry))|\(isPlanUp)|\(Int(viewSize.width))x\(Int(viewSize.height))|\(Int(tableHeight))",
            onSelect: { selectPin(entry, itemID: $0) }, onLongPress: { addEntry(entry, at: $0) }
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

    /// 깃발이나 카드를 누르면 그 여행지로 돌아가 포커싱하고, 포커싱된 것을 한 번 더 누르면 여행 화면으로 들어간다(대표 결정).
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
                Button { dismiss() } label: {
                    Image(systemName: "house.fill").font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40)
                        .background(TravelInk.panel, in: Circle())
                        .overlay { Circle().stroke(TravelInk.border, lineWidth: 1) }
                }
                .accessibilityLabel(language.text("일상으로 돌아가기", "Back to everyday"))
                // 확대하면 바탕이 밝은 땅이 된다. 어느 바탕에서도 읽히게 판 위에 쓴다.
                Text(language.text("여행", "Trips")).font(.headline).padding(.horizontal, 12).frame(height: 34)
                    .background(TravelInk.panel, in: Capsule())
                    .overlay { Capsule().stroke(TravelInk.border, lineWidth: 1) }
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(TravelInk.land)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(flagColor.opacity(entry.state == .past ? 0.6 : 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(entry)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(length(entry)).font(.caption).opacity(0.8)
                    if let money = book.trip(entry.id).map({ TravelPlanSpend.headline(LedgerTripMath.sheet($0, entries: book.entries)) }) {
                        let amount = LedgerMoney.text(money.amount, language: language)
                        Text(money.isLeftover ? language.runtimeText("남은 돈 \(amount)", "Left \(amount)") : language.runtimeText("쓴 돈 \(amount)", "Spent \(amount)"))
                            .font(.caption2.weight(.semibold)).foregroundStyle(money.isLeftover && money.amount < 0 ? TravelInk.actual : TravelInk.plan)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 220)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(entry.id == (flyingID ?? focusedID) ? flagColor : .clear, lineWidth: 2.5) }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
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
            Button(language.text("여행 고치기", "Edit trip"), systemImage: "pencil") { newTripDraft = .init(isDayTrip: entry.isDayTrip, editing: entry.trip) }
            Button(language.text("여행 지우기", "Delete trip"), systemImage: "trash", role: .destructive) { deleteCandidate = entry }
        }
        .accessibilityIdentifier("travelTripCard-\(entry.id)")
    }

    private var globeFooter: some View {
        HStack(spacing: 10) {
            footerButton("plus", language.text("새 여행", "New trip")) { newTripDraft = .init(isDayTrip: false) }
            footerButton("sun.max", language.text("오늘 당일치기", "Day trip today")) { newTripDraft = .init(isDayTrip: true) }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func footerButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 46)
                .background(TravelInk.panel, in: Capsule())
                .overlay { Capsule().stroke(TravelInk.border, lineWidth: 1) }
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
                Button(action: backToGlobe) {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40)
                        .background(TravelInk.land, in: Circle())
                }
                .accessibilityLabel(language.text("여행 목록으로", "Back to trips"))
                .accessibilityIdentifier("travelTripBack")
                // Trip 원본처럼 여행 이름을 누르면 여행 속성(이름·기간·나라)을 고친다.
                Button { newTripDraft = .init(isDayTrip: entry.isDayTrip, editing: entry.trip) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(entry)).font(.headline).lineLimit(1)
                        Text(subtitle(entry)).font(.caption).opacity(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(language.text("여행 고치기", "Edit trip"))
                // 일상 화면으로 바로 나간다.
                Button { exitToDaily(entry) } label: {
                    Image(systemName: "house.fill").font(.system(size: 16, weight: .semibold)).frame(width: 40, height: 40)
                        .background(TravelInk.land, in: Circle())
                }
                .accessibilityLabel(language.text("일상으로 돌아가기", "Back to everyday"))
                .accessibilityIdentifier("travelTripHome")
            }
            .padding(8)
            .background(TravelInk.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(TravelInk.border, lineWidth: 1) }
            moneyBar(entry)
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
        let next = items.first { $0.end > .now } ?? items.first
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(next.map { language.runtimeText("다음: \($0.title)", "Next: \($0.title)") } ?? language.text("아직 일정이 없습니다", "No plans yet"))
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                let planned = TravelPlanSpend.plannedTotal(items: items, tripID: entry.id)
                let plannedText = LedgerMoney.text(planned, language: language)
                Text(language.runtimeText("일정 \(items.count)개", "\(items.count) plans") + (planned > 0 ? " · " + language.runtimeText("예상 \(plannedText)", "Planned \(plannedText)") : ""))
                    .font(.caption).opacity(0.8)
            }
            Spacer(minLength: 0)
            Menu {
                Button(language.text("일정 넣기", "Add plan"), systemImage: "calendar.badge.plus") { addEntry(entry, cell: planCell) }
                Button(language.text("열 편집", "Edit columns"), systemImage: "rectangle.split.3x1") { columnsTrip = entry.trip }
                Button(language.text("지도에서 일정 보기", "View plans on the map"), systemImage: "map") { openPlan(planDay(entry, items: items)) }
                Button(language.text("지출 넣기", "Add expense"), systemImage: "wonsign") {
                    addExpense(entry, minute: nil)
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(TravelInk.land).frame(width: 44, height: 44)
                    .background(TravelInk.plan, in: Circle())
            }
            .accessibilityLabel(language.text("추가", "Add"))
        }
        .foregroundStyle(TravelInk.plan)
        .padding(.leading, 20)
        .padding(.trailing, 6)
        .frame(height: MapHomeBottomBarMetrics.pillHeight)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.25)) { isPlanUp.toggle() } }
        .accessibilityIdentifier("travelPlanFooter")
    }

    // MARK: 계획표와 시간 막대(같은 날·같은 자료를 본다)

    private func dayKey(_ entry: TravelTripDirectory.Entry) -> String {
        if let planDayKey, planDayKey >= entry.trip.startDay, planDayKey <= entry.trip.endDay { return planDayKey }
        return entry.state == .active ? today() : entry.trip.startDay
    }

    private func dayDate(_ key: String) -> Date {
        TravelTripDay.components(key).flatMap(Calendar.autoupdatingCurrent.date(from:)) ?? .now
    }

    private func table(_ entry: TravelTripDirectory.Entry) -> TravelPlanTableModel {
        let day = dayDate(dayKey(entry))
        return TravelPlanTableModel.make(
            items: model.settings.travelTripItems ?? [], tripID: entry.id, day: day,
            actual: MapHomeTimeRailSegmentEngine.segments(from: model.snapshot.actuals, on: day), now: .now,
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
                        let next = TravelPlanSheetHeight.dragged(from: tableHeight, translation: translation, size: viewSize)
                        if isDone {
                            planHeight = Double(next)
                            planDragHeight = nil
                        } else if next != planDragHeight { planDragHeight = next }
                    }
                )
                dayChips(entry)
                if showsCourse(entry) {
                    TravelCourseView(
                        table: table(entry), items: (model.settings.travelTripItems ?? []).filter { $0.tripID == entry.id }, language: language,
                        playMinute: currentPlayMinute(entry), photos: model.photoService, selectedID: $planSelectedID,
                        onScrub: { playMinute = $0 }, onEdit: { editEntry(entry, itemID: $0.id) }
                    )
                    .frame(height: planDragHeight ?? tableHeight)
                } else {
                TravelPlanTable(
                    table: table(entry), language: language,
                    onSelect: { block in editEntry(entry, itemID: block.id) },
                    onExpense: { block in addExpense(entry, minute: block.startMinute) },
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
            if isPlanUp, planHistory.tripID == entry.id, planHistory.canUndo || planHistory.canRedo {
                TravelPlanHistoryBar(history: planHistory, language: language, onUndo: { applyHistory(planHistory.undo()) }, onRedo: { applyHistory(planHistory.redo()) })
            }
            tripFooter(entry)
        }
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
        guard !entry.isDayTrip, let number = TravelTripDay.days(from: entry.trip.startDay, to: key) else { return language.text("당일", "Day trip") }
        return language.runtimeText("\(number + 1)일차", "Day \(number + 1)")
    }

    /// 일정 넣기. 고른 셀이 있으면 그 열·그 시각·그 길이, 없으면 그날 마지막 일정 끝에서 잇는다.
    private func addEntry(_ entry: TravelTripDirectory.Entry, cell: TravelPlanCell? = nil) {
        let column = cell?.column, minute = cell?.minute
        if planCell != nil { planCell = nil }
        let key = dayKey(entry), table = table(entry)
        let last = table.blocks.max { $0.endMinute < $1.endMinute }
        let kind = column.map { TravelPlanColumns.kind(forColumn: $0, in: table.columns) }.flatMap(TripImportItem.Kind.init(rawValue:)) ?? .sight
        var target = TravelQuickEntrySheet.Target.new(
            trip: entry.trip, dayKey: key, dayLabel: dayLabel(entry, key: key),
            startMinute: minute ?? TravelQuickEntry.nextStart(lastEndMinute: last?.endMinute, nowMinute: table.nowMinute), kind: kind
        )
        target.anchor = TravelModeDestination(trip: entry.trip, stops: model.settings.travelPlanStops).point
        target.duration = cell?.chosenDuration
        entryTarget = target
    }

    /// 계획표에서 끌어 옮기거나 길이를 바꾼 것을 저장하고, 되돌릴 수 있게 남긴다.
    private func editTimes(_ entry: TravelTripDirectory.Entry, block: TravelPlanTableModel.Block, move: Int = 0, resize: Int = 0) {
        Task {
            let done = move != 0
                ? await model.moveTripItem(tripID: entry.id, itemID: block.id, by: TimeInterval(move * 60))
                : await model.resizeTripItem(tripID: entry.id, itemID: block.id, endDelta: TimeInterval(resize * 60))
            guard done else { return }
            let start = block.startMinute + move, end = block.endMinute + move + resize
            withAnimation(.snappy(duration: 0.2)) {
                planHistory.record(.init(
                    tripID: entry.id, itemID: block.id, move: move, resize: resize,
                    summary: block.title + " " + TravelQuickEntrySheet.clock(start) + "–" + TravelQuickEntrySheet.clock(end)
                ))
            }
        }
    }

    /// 되돌리기·다시 하기에서 나온 한 걸음을 저장소에 반영한다.
    private func applyHistory(_ step: TravelPlanHistory.Step?) {
        guard let step else { return }
        Task { await model.applyTravelHistory(step) }
    }

    /// 선택 막대에서 지움: 되돌릴 수 있게 그 일정과 장소를 쌓아 둔다.
    private func deleteEntry(_ entry: TravelTripDirectory.Entry, itemID: String) {
        guard let item = (model.settings.travelTripItems ?? []).first(where: { $0.tripID == entry.id && $0.itemID == itemID }) else { return }
        let place = TravelPlanHistory.place(of: item, stops: model.settings.travelPlanStops)
        Task { if await model.deleteTripItem(tripID: entry.id, itemID: itemID) { planHistory.record(.existence(item, place: place, exists: false)) } }
    }

    private func editEntry(_ entry: TravelTripDirectory.Entry, itemID: String) {
        guard let item = (model.settings.travelTripItems ?? []).first(where: { $0.tripID == entry.id && $0.itemID == itemID }) else { return }
        var target = TravelQuickEntrySheet.Target.edit(item, dayLabel: dayLabel(entry, key: TravelTripDay.string(for: item.start, offsetSeconds: item.startOffsetSeconds)))
        target.anchor = TravelModeDestination(trip: entry.trip, stops: model.settings.travelPlanStops).point
        if let stop = model.settings.travelPlanStops.first(where: { $0.tripID == entry.id && $0.itemID == itemID }) {
            target.place = TravelItemPlace(name: stop.title, latitude: stop.latitude, longitude: stop.longitude)
        }
        entryTarget = target
    }

    private func dayChips(_ entry: TravelTripDirectory.Entry) -> TravelDayChips {
        TravelDayChips(days: TravelPlanDays.days(of: entry.trip).map { day in
            let label = dayLabel(entry, key: day.key)
            return (day.key, entry.isDayTrip ? label : label + " " + TravelPlanDays.shortDate(day.key))
        }, selected: dayKey(entry), showsCourse: Binding(get: { showsCourse(entry) }, set: { courseChoice[entry.id] = $0 })) { planDayKey = $0 }
    }

    private func showsCourse(_ entry: TravelTripDirectory.Entry) -> Bool { courseChoice[entry.id] ?? (entry.state == .active) }

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

    /// 예전 지도 여행 모드에서 열 날: 여행 중이면 오늘, 아니면 여행 첫날.
    private func planDay(_ entry: TravelTripDirectory.Entry, items: [TravelTripItem]) -> Date {
        if entry.state == .active { return .now }
        let calendar = Calendar.autoupdatingCurrent
        return TravelTripDay.components(entry.trip.startDay).flatMap(calendar.date(from:)) ?? items.first?.start ?? .now
    }
}

/// 계획표에서 방금 끌어 바꾼 시각(되돌리기용).
private struct TravelLedgerTarget: Identifiable {
    let id: String
}
