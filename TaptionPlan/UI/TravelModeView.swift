import SwiftUI
import TaptionPlanStore

/// 여행 모드의 색(「여권 잉크」, 대표 결정 2026-11-11). 계획은 남색, 실제는 주홍.
enum TravelInk {
    static let space = Color(hex: "#1B2440")
    static let sea = Color(hex: "#D9E4EC")
    static let land = Color(hex: "#F6F1E4")
    static let border = Color(hex: "#C9C2AE")
    static let grid = Color(hex: "#C3CEDA")
    static let plan = Color(hex: "#2F3E6B")
    static let planTint = Color(hex: "#E3E7F2")
    static let actual = Color(hex: "#C8442E")
    /// 지도 위에 뜨는 판(머리말·돈 줄). 땅 색과 겹쳐 묻히지 않게 더 밝다.
    static let panel = Color.white.opacity(0.94)
    /// 깃발 기본 색. 여행 순서대로 돌려 쓴다(대표 지시: 사용자가 정하되 기본은 테마 색 순서).
    static let flagHexes = ["#C8442E", "#2F3E6B", "#C58B1B", "#2E7D6B", "#8A4F9E", "#D9722B"]

    static func flagHex(_ trip: TravelTrip, order: Int) -> String {
        trip.flagColorHex ?? flagHexes[max(0, order) % flagHexes.count]
    }

    /// 깃발 색 견본(메뉴용): 그 색으로 칠한 동그라미. 고른 색이면 가운데 흰 체크.
    static func swatch(_ hex: String, isChosen: Bool, side: CGFloat = 22) -> UIImage {
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            UIColor(Color(hex: hex)).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 1, y: 1, width: side - 2, height: side - 2))
            guard isChosen else { return }
            UIColor.white.setStroke()
            let check = UIBezierPath()
            check.move(to: CGPoint(x: side * 0.30, y: side * 0.52))
            check.addLine(to: CGPoint(x: side * 0.45, y: side * 0.67))
            check.addLine(to: CGPoint(x: side * 0.72, y: side * 0.36))
            check.lineWidth = 2.2
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.stroke()
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    static func flagName(_ hex: String, language: MapHomeLanguage) -> String {
        switch hex {
        case "#C8442E": language.text("주홍 깃발", "Vermilion flag")
        case "#2F3E6B": language.text("남색 깃발", "Navy flag")
        case "#C58B1B": language.text("겨자색 깃발", "Mustard flag")
        case "#2E7D6B": language.text("청록 깃발", "Teal flag")
        case "#8A4F9E": language.text("자주 깃발", "Purple flag")
        default: language.text("주황 깃발", "Orange flag")
        }
    }
}

/// 앱에 넣은 나라·시도 경계(`ne-regions.bin`). 처음 쓸 때 한 번 읽는다.
enum TravelModeRegions {
    static let bundled: [TravelGlobeRegion] = {
        guard let url = Bundle.main.url(forResource: "ne-regions", withExtension: "bin"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? TravelGlobeRegions.decode(data)) ?? []
    }()

    static let countries = bundled.filter { $0.kind == .country }
    static let provinces = bundled.filter { $0.kind == .province }

    /// 경계 점을 지구 위 단위 벡터로 미리 바꿔 둔 것(곳 코드 → 고리들). 그릴 때마다 삼각함수를 다시 계산하지 않는다.
    static let vectors: [String: [[SIMD3<Double>]]] = Dictionary(
        bundled.map { region in (region.code, region.rings.map { ring in ring.map { unitVector(longitude: $0.x, latitude: $0.y) } }) },
        uniquingKeysWith: { first, _ in first }
    )

    /// 고리마다 가로·세로 가운데 큰 쪽의 크기(도). 화면에서 점 하나보다 작은 섬은 그리지 않는 데 쓴다.
    static let spans: [String: [Double]] = Dictionary(
        bundled.map { region in
            (region.code, region.rings.map { ring in
                let xs = ring.map(\.x), ys = ring.map(\.y)
                return max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
            })
        },
        uniquingKeysWith: { first, _ in first }
    )

    static func unitVector(longitude: Double, latitude: Double) -> SIMD3<Double> {
        let lambda = longitude * .pi / 180, phi = latitude * .pi / 180
        return SIMD3(cos(phi) * cos(lambda), cos(phi) * sin(lambda), sin(phi))
    }

    /// 그 나라의 통화(ISO 4217). 모르면 nil.
    static func currency(forCountry code: String) -> String? {
        Locale(identifier: "und_\(code)").currency?.identifier
    }
}

/// 여행 하나가 지구본에서 가리키는 곳.
struct TravelModeDestination {
    var country: TravelGlobeRegion?
    var province: TravelGlobeRegion?
    /// 깃발 자리(경도, 위도).
    var point: SIMD2<Double>?
    /// 그 여행의 지도 핀(날짜·순서대로).
    var stops: [TravelPlanStop]

    init(trip: TravelTrip, stops allStops: [TravelPlanStop]) {
        stops = allStops.filter { $0.tripID == trip.id }.sorted { ($0.day, $0.order) < ($1.day, $1.order) }
        var point: SIMD2<Double>?
        if let latitude = trip.latitude, let longitude = trip.longitude {
            point = SIMD2(longitude, latitude)
        } else if !stops.isEmpty {
            let sum = stops.reduce(SIMD2<Double>(0, 0)) { $0 + SIMD2($1.longitude, $1.latitude) }
            point = sum / Double(stops.count)
        }
        country = trip.countryCode.flatMap { code in TravelModeRegions.countries.first { $0.code == code } }
            ?? point.flatMap { TravelGlobeRegions.region(in: TravelModeRegions.countries, kind: .country, longitude: $0.x, latitude: $0.y) }
        if country?.code == "KR" {
            province = trip.regionName.flatMap { name in TravelModeRegions.provinces.first { $0.nameKo == name || $0.nameEn == name } }
                ?? point.flatMap { TravelGlobeRegions.region(in: TravelModeRegions.provinces, kind: .province, longitude: $0.x, latitude: $0.y) }
        }
        self.point = point ?? province?.anchor ?? country?.anchor
    }
}

/// 지구본 그리기. 나라 경계 자료만으로 그려 인터넷 없이도 같은 그림이 나온다.
enum TravelGlobeRenderer {
    struct Pin {
        var longitude: Double
        var latitude: Double
        var label: String
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

    static func draw(
        _ context: inout GraphicsContext, size: CGSize, camera: TravelGlobeCamera, highlight: Set<String>,
        flags: [Flag], pins: [Pin]
    ) {
        let center = center(in: size)
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
        drawPins(&context, pins: pins, camera: camera, center: center)
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

    private static func drawPins(_ context: inout GraphicsContext, pins: [Pin], camera: TravelGlobeCamera, center: CGPoint) {
        let places = pins.map { (point(camera, center, $0.longitude, $0.latitude), $0.label) }.filter { $0.0.1 }
        guard !places.isEmpty else { return }
        var route = Path()
        for (index, place) in places.enumerated() {
            if index == 0 { route.move(to: place.0.0) } else { route.addLine(to: place.0.0) }
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
    @State private var entryTarget: TravelQuickEntrySheet.Target?
    @State private var didEnter = false
    /// 계획표 시트가 올라와 있는지. 올라오면 작은 시간 막대는 사라진다(대표 결정).
    @State private var isPlanUp = false
    /// 계획표와 시간 막대가 함께 보는 날(`YYYY-MM-DD`). nil이면 여행 중엔 오늘, 아니면 첫날.
    @State private var planDayKey: String?

    private var book: LedgerBook { LedgerBook.shared }

    private var entries: [TravelTripDirectory.Entry] {
        model.travelTripEntries(names: Dictionary(book.trips.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
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
                        pins: openedID == nil ? [] : pins(destination)
                    )
                }
            }
            // 그리는 크기와 누른 자리를 재는 크기가 같아야 깃발이 눌린다. 그래서 안전 영역까지 포함한 이 크기 하나만 쓴다.
            .gesture(globeGestures(entries, size: proxy.size), isEnabled: openedID == nil && flight == nil)
            .onAppear { viewSize = proxy.size; enter(entries) }
            .onChange(of: proxy.size) { _, size in viewSize = size }
        }
        .ignoresSafeArea()
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
            if let focused, openedID != nil { planSheet(focused) } else { globeFooter }
        }
        .task(id: flightStart) { await finishFlight() }
        .task { await book.load() }
        .sheet(item: $newTripDraft) { draft in
            TravelNewTripSheet(model: model, language: language, draft: draft) { trip in
                fly(to: TravelTripDirectory.entry(trip, isStored: true, today: today()))
            }
        }
        .sheet(item: Binding(get: { ledgerTripID.map(TravelLedgerTarget.init) }, set: { ledgerTripID = $0?.id })) { target in
            LedgerSheet(language: language, tripID: target.id, plannedTrips: LedgerBook.plannedTrips(
                stops: model.settings.travelPlanStops, items: model.settings.travelTripItems ?? [], trips: model.settings.travelTrips ?? []
            ))
        }
        .sheet(item: $entryTarget) { target in TravelQuickEntrySheet(model: model, language: language, target: target) }
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
        guard let active = entries.first(where: { $0.state == .active }) else { return }
        focusedID = active.id
        let destination = TravelModeDestination(trip: active.trip, stops: model.settings.travelPlanStops)
        if let last = cameras(for: destination).last { camera = last }
        openedID = active.id
    }

    private func fit(_ box: (west: Double, south: Double, east: Double, north: Double)) -> TravelGlobeCamera {
        TravelGlobeCamera.fitting(
            west: box.west, south: box.south, east: box.east, north: box.north, width: Double(viewSize.width), height: Double(viewSize.height),
            padding: 56, minimumRadius: restRadius, maximumRadius: 60_000
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
                opacity: entry.state == .past && !chosen ? 0.45 : 1, showsLabel: chosen
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
        (destination?.stops ?? []).enumerated().map { .init(longitude: $1.longitude, latitude: $1.latitude, label: "\($0 + 1)") }
    }

    // MARK: 글

    private func tag(_ entry: TravelTripDirectory.Entry) -> String {
        switch entry.state {
        case .active: language.text("여행 중", "On trip")
        case .upcoming: "D-\(entry.daysUntilStart ?? 0)"
        case .past: language.text("지난 여행", "Past")
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
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 150)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(entry.id == (flyingID ?? focusedID) ? flagColor : .clear, lineWidth: 2.5) }
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
            }
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
        VStack(spacing: 8) {
            moneyBar(entry)
            HStack(spacing: 8) {
                Button(action: backToGlobe) {
                    Image(systemName: "globe.asia.australia.fill").font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40)
                        .background(TravelInk.land, in: Circle())
                }
                .accessibilityLabel(language.text("지구본으로", "Back to globe"))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(entry)).font(.headline).lineLimit(1)
                    Text(subtitle(entry)).font(.caption).opacity(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(TravelInk.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(TravelInk.border, lineWidth: 1) }
        }
        .foregroundStyle(TravelInk.plan)
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private func subtitle(_ entry: TravelTripDirectory.Entry) -> String {
        let state: String = switch entry.state {
        case .active: language.runtimeText("\(entry.dayNumber ?? 1)일차", "Day \(entry.dayNumber ?? 1)")
        case .upcoming: "D-\(entry.daysUntilStart ?? 0)"
        case .past: language.text("지난 여행", "Past")
        }
        return "\(length(entry)) · \(state)"
    }

    /// 맨 위 돈 표시줄의 자리. 지금은 예산 대비 남은 돈과 쓴 돈만 보인다(통화별 칸은 지갑 단계에서).
    private func moneyBar(_ entry: TravelTripDirectory.Entry) -> some View {
        let sheet = book.trip(entry.id).map { LedgerTripMath.sheet($0, entries: book.entries) }
        return Button { ledgerTripID = entry.id } label: {
            HStack(spacing: 8) {
                if let sheet {
                    Label(LedgerMoney.text(sheet.leftover, language: language), systemImage: "wonsign.circle.fill")
                        .foregroundStyle(sheet.leftover < 0 ? TravelInk.actual : TravelInk.plan)
                    Spacer(minLength: 0)
                    Text(language.runtimeText("쓴 돈 \(LedgerMoney.text(sheet.myCost, language: language))", "Spent \(LedgerMoney.text(sheet.myCost, language: language))"))
                        .opacity(0.8)
                } else {
                    Label(language.text("여행 장부 만들기", "Start trip ledger"), systemImage: "wonsign.circle")
                    Spacer(minLength: 0)
                }
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(TravelInk.panel, in: Capsule())
            .overlay { Capsule().stroke(TravelInk.border, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("travelMoneyBar")
    }

    private func tripFooter(_ entry: TravelTripDirectory.Entry) -> some View {
        let items = (model.settings.travelTripItems ?? []).filter { $0.tripID == entry.id }.sorted { $0.start < $1.start }
        let next = items.first { $0.end > .now } ?? items.first
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(next.map { language.runtimeText("다음: \($0.title)", "Next: \($0.title)") } ?? language.text("아직 일정이 없습니다", "No plans yet"))
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(language.runtimeText("일정 \(items.count)개", "\(items.count) plans")).font(.caption).opacity(0.8)
            }
            Spacer(minLength: 0)
            Menu {
                Button(language.text("일정 넣기", "Add plan"), systemImage: "calendar.badge.plus") { addEntry(entry) }
                Button(language.text("지도에서 일정 보기", "View plans on the map"), systemImage: "map") { openPlan(planDay(entry, items: items)) }
                Button(language.text("지출 넣기", "Add expense"), systemImage: "wonsign") { ledgerTripID = entry.id }
            } label: {
                Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(TravelInk.land).frame(width: 46, height: 46)
                    .background(TravelInk.plan, in: Circle())
            }
            .accessibilityLabel(language.text("추가", "Add"))
        }
        .foregroundStyle(TravelInk.plan)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
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
            actual: MapHomeTimeRailSegmentEngine.segments(from: model.snapshot.actuals, on: day), now: .now
        )
    }

    /// 아래 시트: 내려 있으면 다음 일정 한 줄, 끌어올리면 계획표.
    private func planSheet(_ entry: TravelTripDirectory.Entry) -> some View {
        VStack(spacing: 0) {
            Capsule().fill(TravelInk.border).frame(width: 44, height: 5).padding(.top, 7).padding(.bottom, 3)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy(duration: 0.25)) { isPlanUp.toggle() } }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(isPlanUp ? language.text("계획표 내리기", "Close plan table") : language.text("계획표 올리기", "Open plan table"))
                .accessibilityIdentifier("travelPlanHandle")
            if isPlanUp {
                dayChips(entry)
                TravelPlanTable(
                    table: table(entry), language: language,
                    onSelect: { block in editEntry(entry, itemID: block.id) },
                    onAdd: { column, minute in addEntry(entry, column: column, minute: minute) }
                )
                    .id(dayKey(entry))
                    .frame(height: viewSize.height * 0.5)
                    .padding(.horizontal, 8)
            }
            tripFooter(entry)
        }
        .background(TravelInk.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(TravelInk.border, lineWidth: 1) }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
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

    /// 일정 넣기. 빈 곳을 눌렀으면 그 열·그 시각, 「+」면 그날 마지막 일정 끝에서 잇는다.
    private func addEntry(_ entry: TravelTripDirectory.Entry, column: Int? = nil, minute: Int? = nil) {
        let key = dayKey(entry), table = table(entry)
        let last = table.blocks.max { $0.endMinute < $1.endMinute }
        let kind = column.map(TravelQuickEntry.kind(forColumn:)).flatMap(TripImportItem.Kind.init(rawValue:)) ?? .sight
        entryTarget = .new(
            trip: entry.trip, dayKey: key, dayLabel: dayLabel(entry, key: key),
            startMinute: minute ?? TravelQuickEntry.nextStart(lastEndMinute: last?.endMinute, nowMinute: table.nowMinute), kind: kind
        )
    }

    private func editEntry(_ entry: TravelTripDirectory.Entry, itemID: String) {
        guard let item = (model.settings.travelTripItems ?? []).first(where: { $0.tripID == entry.id && $0.itemID == itemID }) else { return }
        entryTarget = .edit(item, dayLabel: dayLabel(entry, key: TravelTripDay.string(for: item.start, offsetSeconds: item.startOffsetSeconds)))
    }

    private func dayChips(_ entry: TravelTripDirectory.Entry) -> some View {
        let selected = dayKey(entry)
        return ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(TravelPlanDays.days(of: entry.trip), id: \.key) { day in
                    Button { planDayKey = day.key } label: {
                        Text(dayLabel(entry, key: day.key))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .foregroundStyle(day.key == selected ? TravelInk.land : TravelInk.plan)
                            .background(day.key == selected ? TravelInk.plan : TravelInk.planTint, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 4)
    }

    /// 예전 지도 여행 모드에서 열 날: 여행 중이면 오늘, 아니면 여행 첫날.
    private func planDay(_ entry: TravelTripDirectory.Entry, items: [TravelTripItem]) -> Date {
        if entry.state == .active { return .now }
        let calendar = Calendar.autoupdatingCurrent
        return TravelTripDay.components(entry.trip.startDay).flatMap(calendar.date(from:)) ?? items.first?.start ?? .now
    }
}

private struct TravelLedgerTarget: Identifiable {
    let id: String
}

/// 새 여행 만들기: 이름·기간·여행지. 당일치기와 지난 날짜도 된다.
struct TravelNewTripSheet: View {
    struct Draft: Identifiable {
        let id = UUID()
        var isDayTrip: Bool
    }

    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let draft: Draft
    let onCreate: (TravelTrip) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var isDayTrip = false
    @State private var start = Date.now
    @State private var end = Date.now
    @State private var countryCode = "KR"
    @State private var provinceCode = ""
    @State private var isSaving = false

    private var countries: [TravelGlobeRegion] {
        TravelModeRegions.countries.filter { $0.code.count == 2 }.sorted { name($0) < name($1) }
    }

    private func name(_ region: TravelGlobeRegion) -> String {
        language == .korean && !region.nameKo.isEmpty ? region.nameKo : region.nameEn
    }

    private var currency: String? {
        countryCode == "KR" ? nil : TravelModeRegions.currency(forCountry: countryCode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(language.text("여행 이름", "Trip name"), text: $title)
                    Toggle(language.text("당일치기", "Day trip"), isOn: $isDayTrip)
                    DatePicker(isDayTrip ? language.text("날짜", "Date") : language.text("첫날", "First day"), selection: $start, displayedComponents: .date)
                    if !isDayTrip {
                        DatePicker(language.text("마지막 날", "Last day"), selection: $end, in: start..., displayedComponents: .date)
                    }
                } footer: {
                    Text(language.text("지난 날짜로 만들면 그날의 기록이 이 여행의 실제 기록이 됩니다.", "A past date turns that day's records into this trip's actual records."))
                }
                Section(language.text("여행지", "Destination")) {
                    Picker(language.text("나라", "Country"), selection: $countryCode) {
                        ForEach(countries) { Text(name($0)).tag($0.code) }
                    }
                    if countryCode == "KR" {
                        Picker(language.text("지역", "Region"), selection: $provinceCode) {
                            Text(language.text("정하지 않음", "Not set")).tag("")
                            ForEach(TravelModeRegions.provinces) { Text(name($0)).tag($0.code) }
                        }
                    }
                    LabeledContent(language.text("여행지 통화", "Trip currency"), value: currency ?? language.text("원화만", "Home currency only"))
                }
            }
            .navigationTitle(language.text("새 여행", "New trip"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(language.text("취소", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("만들기", "Create")) { Task { await create() } }.disabled(isSaving)
                }
            }
            .onAppear { isDayTrip = draft.isDayTrip }
            .onChange(of: start) { _, value in if end < value { end = value } }
        }
    }

    private func day(_ date: Date) -> String {
        let parts = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: date)
        return TravelTripDay.string(year: parts.year ?? 0, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    private func create() async {
        isSaving = true
        defer { isSaving = false }
        let country = TravelModeRegions.countries.first { $0.code == countryCode }
        let province = TravelModeRegions.provinces.first { $0.code == provinceCode && countryCode == "KR" }
        let place = province ?? country
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trip = TravelTrip(
            id: "trip-\(UUID().uuidString.lowercased())",
            title: trimmed.isEmpty ? (place.map(name) ?? "") : trimmed,
            startDay: day(start), endDay: day(isDayTrip ? start : max(start, end)),
            countryCode: country?.code, regionName: province?.nameKo,
            latitude: place?.anchor.y, longitude: place?.anchor.x, currencyCode: currency
        )
        guard await model.saveTravelTrip(trip) else { return }
        dismiss()
        onCreate(trip)
    }
}

/// 지구본 손가락 조작의 계산(TVE1112A01).
enum TravelGlobeTouch {
    /// 손가락이 간 만큼 지구가 따라 돈다(확대할수록 같은 거리에 덜 돈다). 극을 넘지 않게 위도 ±80°에서 멈춘다.
    static func rotated(_ camera: TravelGlobeCamera, by translation: CGSize) -> TravelGlobeCamera {
        let degreesPerPoint = 180 / (Double.pi * max(1, camera.radius))
        var longitude = camera.longitude - Double(translation.width) * degreesPerPoint
        longitude = (longitude + 180).truncatingRemainder(dividingBy: 360)
        if longitude < 0 { longitude += 360 }
        return TravelGlobeCamera(
            longitude: longitude - 180,
            latitude: min(80, max(-80, camera.latitude + Double(translation.height) * degreesPerPoint)),
            radius: camera.radius
        )
    }

    /// 벌린 배율만큼 확대. 지구본 기본 크기의 0.6배보다 작아지거나 거리 단위보다 가까워지지 않는다.
    static func zoomed(_ radius: Double, by magnification: CGFloat, rest: Double) -> Double {
        min(60_000, max(rest * 0.6, radius * Double(magnification)))
    }

    /// 누른 자리의 깃발. 깃대(발에서 위로 32pt)와 깃발 천 둘레 22pt 안이면 그 깃발이다. 여럿이면 가까운 것.
    static func flag(at location: CGPoint, flags: [TravelGlobeRenderer.Flag], camera: TravelGlobeCamera, size: CGSize) -> String? {
        var best: (id: String, distance: CGFloat)?
        for flag in flags {
            guard let foot = TravelGlobeRenderer.foot(of: flag, camera: camera, size: size) else { continue }
            let nearestX = min(max(location.x, foot.x), foot.x + 20)
            let nearestY = min(max(location.y, foot.y - 32), foot.y)
            let distance = hypot(location.x - nearestX, location.y - nearestY)
            if distance <= 22, distance < (best?.distance ?? .infinity) { best = (flag.id, distance) }
        }
        return best?.id
    }
}
