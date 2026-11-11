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
        var longitude: Double
        var latitude: Double
        var text: String
        /// 0 = 아직 없음, 1 = 꽂힘.
        var progress: Double
    }

    static func center(in size: CGSize) -> CGPoint { CGPoint(x: size.width / 2, y: size.height * 0.54) }

    static func draw(
        _ context: inout GraphicsContext, size: CGSize, camera: TravelGlobeCamera, highlight: Set<String>,
        flag: Flag?, pins: [Pin]
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
        if let flag, flag.progress > 0 { drawFlag(&context, flag: flag, camera: camera, center: center) }
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
        layer.opacity = min(1, flag.progress * 2)
        let foot = CGPoint(x: base.x, y: base.y - (1 - flag.progress) * 60)
        var pole = Path()
        pole.move(to: foot)
        pole.addLine(to: CGPoint(x: foot.x, y: foot.y - 32))
        layer.stroke(pole, with: .color(TravelInk.actual), lineWidth: 2)
        var cloth = Path()
        cloth.move(to: CGPoint(x: foot.x, y: foot.y - 32))
        cloth.addLine(to: CGPoint(x: foot.x + 20, y: foot.y - 26))
        cloth.addLine(to: CGPoint(x: foot.x, y: foot.y - 20))
        cloth.closeSubpath()
        layer.fill(cloth, with: .color(TravelInk.actual))
        layer.fill(Path(ellipseIn: CGRect(x: foot.x - 3, y: foot.y - 3, width: 6, height: 6)), with: .color(TravelInk.actual))
        guard flag.progress >= 1, !flag.text.isEmpty else { return }
        let label = layer.resolve(Text(flag.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(TravelInk.land))
        let textSize = label.measure(in: CGSize(width: 200, height: 40))
        let pill = CGRect(x: foot.x + 24, y: foot.y - 36, width: textSize.width + 16, height: textSize.height + 6)
        layer.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(TravelInk.actual))
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
    @State private var viewSize = CGSize(width: 390, height: 760)
    @State private var newTripDraft: TravelNewTripSheet.Draft?
    @State private var ledgerTripID: String?
    @State private var didEnter = false

    private var book: LedgerBook { LedgerBook.shared }

    private var entries: [TravelTripDirectory.Entry] {
        model.travelTripEntries(names: Dictionary(book.trips.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
    }

    private var restRadius: Double { Double(min(viewSize.width, viewSize.height)) * 0.38 }

    var body: some View {
        let entries = self.entries
        let focused = entries.first { $0.id == (openedID ?? flyingID) }
        let destination = focused.map { TravelModeDestination(trip: $0.trip, stops: model.settings.travelPlanStops) }
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: flight == nil)) { timeline in
                let elapsed = timeline.date.timeIntervalSince(flightStart)
                let now = flight.map { $0.camera(at: elapsed) } ?? camera
                Canvas { context, size in
                    TravelGlobeRenderer.draw(
                        &context, size: size, camera: now, highlight: highlight(destination),
                        flag: flag(for: focused, destination: destination, progress: flight.map { $0.flagProgress(at: elapsed) } ?? 1),
                        pins: openedID == nil ? [] : pins(destination)
                    )
                }
            }
            .ignoresSafeArea()
            .onAppear { viewSize = proxy.size; enter(entries) }
            .onChange(of: proxy.size) { _, size in viewSize = size }
        }
        .overlay(alignment: .topLeading) {
            if openedID == nil { cardColumn(entries) }
        }
        .overlay(alignment: .top) {
            if let focused, openedID != nil { tripHeader(focused) }
        }
        .overlay(alignment: .bottom) {
            if let focused, openedID != nil { tripFooter(focused) } else { globeFooter }
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

    private func fly(to entry: TravelTripDirectory.Entry) {
        guard flight == nil else { return }
        let destination = TravelModeDestination(trip: entry.trip, stops: model.settings.travelPlanStops)
        guard let point = destination.point else {
            // 어디인지 모르는 여행은 지구를 돌리지 않고 바로 연다.
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
            openedID = entry.id
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
        openedID = id
    }

    private func backToGlobe() {
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

    private func flag(for entry: TravelTripDirectory.Entry?, destination: TravelModeDestination?, progress: Double) -> TravelGlobeRenderer.Flag? {
        guard let entry, openedID == nil, let point = destination?.point else { return nil }
        return .init(longitude: point.x, latitude: point.y, text: tag(entry), progress: progress)
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
                        .background(TravelInk.land, in: Circle())
                }
                .accessibilityLabel(language.text("일상으로 돌아가기", "Back to everyday"))
                Text(language.text("여행", "Trips")).font(.title3.weight(.semibold)).foregroundStyle(TravelInk.land)
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
        Button { fly(to: entry) } label: {
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
                .background(entry.state == .active ? TravelInk.actual : TravelInk.plan)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(entry)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(length(entry)).font(.caption).opacity(0.8)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 150)
            .background(TravelInk.land)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(flyingID == entry.id ? TravelInk.actual : .clear, lineWidth: 2) }
        }
        .buttonStyle(.plain)
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
                .background(TravelInk.land, in: Capsule())
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
                Button(language.text("일정 보기·고치기", "View and edit plans"), systemImage: "calendar") { openPlan(planDay(entry, items: items)) }
                Button(language.text("지출 넣기", "Add expense"), systemImage: "wonsign") { ledgerTripID = entry.id }
            } label: {
                Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(TravelInk.land).frame(width: 46, height: 46)
                    .background(TravelInk.plan, in: Circle())
            }
            .accessibilityLabel(language.text("추가", "Add"))
        }
        .foregroundStyle(TravelInk.plan)
        .padding(12)
        .background(TravelInk.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(TravelInk.border, lineWidth: 1) }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
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
