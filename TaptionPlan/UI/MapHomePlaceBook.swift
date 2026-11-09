import MapKit
import SwiftUI
import TaptionPlanCore

/// 장소 도감 한 칸(INK1108A01). 가 본 곳은 색 있는 그림과 도장, 아직이면 먹빛 그림과 점선 도장.
struct MapHomePlaceBookEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let glyph: String
    let artworkName: String
    let firstVisit: Date?
    /// 지도에 표시할 자리. 해외 도시는 직항 공항마다 하나씩이다.
    var pins: [MapHomePlaceBookPin] = []
    /// 공항·해외 도시는 여권 입국 도장을 찍는다.
    var usesPassportStamp = false
    var stampCountry = "kr"

    var isVisited: Bool { firstVisit != nil }
    var stamp: MapHomePlaceStampMark { MapHomePlaceStampMark(glyph: glyph, isStamped: isVisited) }
}

/// 도감 상태. 원본 머묾에서 매번 다시 구하고 저장하지 않는다.
struct MapHomePlaceBookState: Equatable {
    var landmarks: [MapHomePlaceBookEntry]

    var entries: [MapHomePlaceBookEntry] { landmarks }
    var stampedCount: Int { entries.filter(\.isVisited).count }
    var remainingCount: Int { entries.count - stampedCount }

    /// 머문 자리가 반경 안이거나(드라이브길은 지나가면) 가 본 곳이다. 등록 장소는 도감에 넣지 않는다(대표 지시).
    static func make(
        stays: [PlaceStay],
        language: MapHomeLanguage,
        region: String = defaultRegion,
        drivePasses: [String: Date] = [:]
    ) -> Self {
        let regionNames = Dictionary(uniqueKeysWithValues: regions.map { ($0.id, language.runtimeText($0.name, $0.englishName)) })
        let landmarks = places(in: region).map { place in
            MapHomePlaceBookEntry(
                id: place.id,
                title: language.runtimeText(place.name, place.englishName),
                subtitle: place.countryCode.map { MapHomePlaceBookMenu.countryName($0, language: language) } ?? regionNames[place.region] ?? "",
                // "N서울타워"·"5·18기념공원"처럼 한글로 시작하지 않으면 첫 한글을 쓴다.
                glyph: (place.name.first { $0.isLetter && !$0.isASCII } ?? place.name.first).map(String.init) ?? "印",
                artworkName: place.artworkName,
                firstVisit: [place.firstVisit(in: stays), drivePasses[place.id]].compactMap { $0 }.min(),
                pins: place.pins(language: language),
                usesPassportStamp: place.usesPassportStamp,
                stampCountry: place.countryCode ?? "kr"
            )
        }
        return Self(landmarks: landmarks)
    }

    /// 처음 여는 시·도(PLB1109A01).
    static let defaultRegion = "seoul"
    static var regions: [MapHomeKoreaRegion] { MapHomeKoreaPlaceBookData.regions }

    /// 시·도 id, 종류 id, 또는 소문자 나라 코드로 고른다.
    static func places(in selection: String) -> [MapHomeKoreaPlace] {
        MapHomeKoreaPlaceBookData.places.filter {
            $0.region == selection || $0.theme == selection || $0.countryCode?.lowercased() == selection
        }
    }
}

/// 도감의 세 줄 메뉴(PLB1109A01). 1줄 나라, 2줄 지역별·종류별, 3줄 시·도 또는 종류.
struct MapHomePlaceBookMenu: Equatable {
    enum Browse: Equatable { case region, theme }

    struct Item: Identifiable, Equatable {
        let id: String
        let name: String
        let englishName: String

        func title(_ language: MapHomeLanguage) -> String {
            MapHomePlaceBookMenu.isCountry(id)
                ? MapHomePlaceBookMenu.countryName(id, language: language)
                : language.runtimeText(name, englishName)
        }
    }

    static let korea = "kr"
    static let byRegion = "by-region"
    static let byTheme = "by-theme"

    var country = korea
    var browse = Browse.region
    var region = MapHomePlaceBookState.defaultRegion
    var theme = MapHomeKoreaPlaceBookData.themes.first?.id ?? ""

    /// 카드로 보여 줄 목록.
    var selected: String {
        guard showsKoreaRows else { return country }
        return browse == .region ? region : theme
    }

    var showsKoreaRows: Bool { country == Self.korea }

    static let countries: [String] = {
        var seen = Set<String>()
        return MapHomeKoreaPlaceBookData.places.compactMap { $0.countryCode?.lowercased() }.filter { seen.insert($0).inserted }
    }()

    static func isCountry(_ id: String) -> Bool { countries.contains(id) }

    /// iOS가 홍콩·마카오와 나란히 둘 때 "중국 본토"로 부르는 지역 이름을 "중국"으로 쓴다.
    static func countryName(_ code: String, language: MapHomeLanguage) -> String {
        if code.lowercased() == "cn" { return language.runtimeText("중국", "China") }
        return language.locale.localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()
    }

    var countryItems: [Item] {
        [Item(id: Self.korea, name: "한국", englishName: "Korea")]
            + Self.countries.map { Item(id: $0, name: $0, englishName: $0) }
    }

    var browseItems: [Item] {
        [
            Item(id: Self.byRegion, name: "지역별", englishName: "By region"),
            Item(id: Self.byTheme, name: "종류별", englishName: "By type"),
        ]
    }

    var listItems: [Item] {
        (browse == .region ? MapHomeKoreaPlaceBookData.regions : MapHomeKoreaPlaceBookData.themes)
            .map { Item(id: $0.id, name: $0.name, englishName: $0.englishName) }
    }

    var selectedBrowseID: String { browse == .region ? Self.byRegion : Self.byTheme }
    var selectedListID: String { browse == .region ? region : theme }

    mutating func selectBrowse(_ id: String) { browse = id == Self.byTheme ? .theme : .region }

    mutating func selectList(_ id: String) {
        if browse == .region { region = id } else { theme = id }
    }
}

struct MapHomeKoreaRegion: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let englishName: String
}

/// 드라이브길은 머물지 않아도 지나가면 도장을 찍는다(대표 결정 2026-11-09).
enum MapHomePlaceBookDrivePass {
    static let places = MapHomeKoreaPlaceBookData.places.filter { $0.theme == "drive" }
    static let maximumAccuracyMeters = 100.0

    /// 경로 표본이 반경 안에 든 첫 시각. 이미 찾은 곳은 다시 보지 않는다.
    static func merge(readings: [SensorReading], into passes: inout [String: Date]) {
        let remaining = places.filter { passes[$0.id] == nil }.map { ($0.id, $0.site) }
        guard !remaining.isEmpty else { return }
        for reading in readings.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let point = reading.point, point.horizontalAccuracy >= 0, point.horizontalAccuracy <= maximumAccuracyMeters else { continue }
            for (id, site) in remaining where passes[id] == nil && site.contains(point) {
                passes[id] = reading.timestamp
            }
        }
    }
}

extension AppModel {
    /// 차·버스 등 이동 구간의 GPS만 읽어 드라이브길 통과를 찾는다. 지하철과 걷기는 도로를 달린 것이 아니다.
    func placeBookDrivePasses() async -> [String: Date] {
        var passes: [String: Date] = [:]
        let spans = snapshot.travel.filter { $0.mode != .walking && $0.mode != .subway }.map(\.span)
        for span in spans {
            guard !Task.isCancelled, passes.count < MapHomePlaceBookDrivePass.places.count else { break }
            let readings = await sensorReadings(in: span)
            MapHomePlaceBookDrivePass.merge(readings: readings, into: &passes)
            await Task.yield()
        }
        return passes
    }
}

struct MapHomeAirport: Equatable, Sendable {
    let name: String
    let englishName: String
    let latitude: Double
    let longitude: Double

    /// 공항 터미널·활주로를 덮는 반경.
    var site: MapHomeLandmarkSite { MapHomeLandmarkSite(latitude: latitude, longitude: longitude, radiusMeters: 3_000) }
}

/// 도감에서 지도로 넘기는 한 자리.
struct MapHomePlaceBookPin: Equatable, Hashable {
    let title: String
    let subtitle: String
    let latitude: Double
    let longitude: Double
}

/// 국내 도감 명소 한 곳. 자료는 `scripts/place-book/build.py`가 만든다.
struct MapHomeKoreaPlace: Identifiable, Equatable, Sendable {
    let id: String
    let region: String
    let name: String
    let englishName: String
    /// 시·도 탭과 함께 보일 묶음 탭(산·절·섬·드라이브길).
    let theme: String?
    let kind: MapHomeLandmarkSites.Kind
    let latitude: Double
    let longitude: Double
    /// 해외 도시의 직항 공항. 두 곳 이상이면 모두 든다.
    var airports: [MapHomeAirport] = []

    /// 해외 도시 id(`intl.jp.tokyo`)의 지역 코드.
    var countryCode: String? {
        let parts = id.split(separator: ".")
        return parts.first == "intl" && parts.count == 3 ? parts[1].uppercased() : nil
    }

    /// 도시 반경 또는 어느 직항 공항에든 머물면 가 본 곳이다.
    func firstVisit(in stays: [PlaceStay]) -> Date? {
        ([site] + airports.map(\.site)).compactMap { $0.firstVisit(in: stays) }.min()
    }

    func pins(language: MapHomeLanguage) -> [MapHomePlaceBookPin] {
        let title = language.runtimeText(name, englishName)
        guard !airports.isEmpty else {
            return [MapHomePlaceBookPin(title: title, subtitle: "", latitude: latitude, longitude: longitude)]
        }
        return airports.map { airport in
            let airportName = language.runtimeText(airport.name, airport.englishName)
            return MapHomePlaceBookPin(
                title: airportName.isEmpty
                    ? language.runtimeText("\(title) 공항", "\(title) Airport")
                    : language.runtimeText("\(title) \(airportName) 공항", "\(title) \(airportName) Airport"),
                subtitle: "", latitude: airport.latitude, longitude: airport.longitude
            )
        }
    }

    var usesPassportStamp: Bool { countryCode != nil || kind == .airport }

    var artworkName: String { "PlaceBook_" + id.replacingOccurrences(of: ".", with: "_") }

    var site: MapHomeLandmarkSite {
        MapHomeLandmarkSite(latitude: latitude, longitude: longitude, radiusMeters: kind.radiusMeters)
    }
}

/// 랜드마크 중심 좌표와 반경(공개 지도의 대략 좌표, 반경은 종류별 기본값).
struct MapHomeLandmarkSite: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double

    func contains(_ point: GeoPoint) -> Bool {
        // 위도 차로 먼저 거른다. 1도 ≈ 111 km.
        guard abs(point.latitude - latitude) * 111_000 <= radiusMeters else { return false }
        return Self.distance(point.latitude, point.longitude, latitude, longitude) <= radiusMeters
    }

    func firstVisit(in stays: [PlaceStay]) -> Date? {
        stays.lazy.filter { $0.point.map(contains) == true }.map(\.span.start).min()
    }

    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0, p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = p2 - p1, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

enum MapHomeLandmarkSites {
    /// 가 본 곳으로 치는 반경. 종류별 기본값(대표 결정 2026-11-08).
    enum Kind: Sendable {
        /// 건물·궁궐·다리·탑
        case building
        /// 동네·해변·마을·섬 한 곳
        case area
        /// 산·국립공원·해안처럼 넓은 자연
        case nature
        /// 해외는 한국 직항 도시 단위로만 찍는다(대표 결정 2026-11-09).
        case city
        /// 거제도처럼 넓은 섬 하나
        case largeIsland
        /// 국내 공항
        case airport

        var radiusMeters: Double {
            switch self {
            case .building: 500
            case .area: 2_000
            case .nature: 5_000
            case .city: 30_000
            case .largeIsland: 15_000
            case .airport: 3_000
            }
        }
    }

    static func site(for id: String) -> MapHomeLandmarkSite? {
        table[id].map { MapHomeLandmarkSite(latitude: $0.0, longitude: $0.1, radiusMeters: $0.2.radiusMeters) }
    }

    /// 랜드마크 id → (위도, 경도, 종류).
    static let table: [String: (Double, Double, Kind)] = [
        "kr.gyeongbokgung": (37.5796, 126.9770, .building),
        "kr.bulguksa": (35.7900, 129.3320, .building),
        "kr.seongsan": (33.4580, 126.9425, .area),
        "kr.haeundae": (35.1587, 129.1604, .area),
        "kr.hahoe": (36.5390, 128.5180, .area),
        "kr.namsan": (37.5512, 126.9882, .building),
        "kr.hallasan": (33.3617, 126.5292, .nature),
        "jp.fuji": (35.3606, 138.7274, .nature),
        "jp.himeji": (34.8394, 134.6939, .building),
        "jp.fushimi": (34.9671, 135.7727, .building),
        "jp.itsukushima": (34.2959, 132.3198, .building),
        "jp.arashiyama": (35.0094, 135.6668, .area),
        "us.liberty": (40.6892, -74.0445, .building),
        "us.grandcanyon": (36.1069, -112.1129, .nature),
        "us.golden_gate": (37.8199, -122.4783, .area),
        "us.yosemite": (37.8651, -119.5383, .nature),
        "us.mount_rushmore": (43.8791, -103.4591, .area),
        "gb.bigben": (51.5007, -0.1246, .building),
        "gb.stonehenge": (51.1789, -1.8262, .building),
        "gb.edinburgh": (55.9486, -3.1999, .building),
        "gb.lake_district": (54.4609, -3.0886, .nature),
        "gb.tower_bridge": (51.5055, -0.0754, .building),
        "fr.eiffel": (48.8584, 2.2945, .building),
        "fr.mont_saint_michel": (48.6361, -1.5115, .area),
        "fr.louvre": (48.8606, 2.3376, .building),
        "fr.versailles": (48.8049, 2.1204, .building),
        "fr.alps": (45.8326, 6.8652, .nature),
        "it.colosseum": (41.8902, 12.4922, .building),
        "it.venice": (45.4408, 12.3155, .area),
        "it.pisa": (43.7230, 10.3966, .building),
        "it.dolomites": (46.4102, 11.8440, .nature),
        "it.amalfi": (40.6340, 14.6027, .nature),
        "cn.great_wall": (40.4319, 116.5704, .area),
        "cn.forbidden_city": (39.9163, 116.3972, .building),
        "cn.zhangjiajie": (29.3150, 110.4343, .nature),
        "cn.terracotta": (34.3841, 109.2785, .building),
        "cn.li_river": (24.7780, 110.4960, .nature),
        "es.sagrada": (41.4036, 2.1744, .building),
        "es.alhambra": (37.1761, -3.5881, .building),
        "es.park_guell": (41.4145, 2.1527, .building),
        "es.camino": (42.8806, -8.5446, .area),
        "es.teide": (28.2724, -16.6425, .nature),
        "th.grand_palace": (13.7500, 100.4913, .building),
        "th.phiphi": (7.7407, 98.7784, .nature),
        "th.ayutthaya": (14.3532, 100.5689, .area),
        "th.doi_inthanon": (18.5883, 98.4861, .nature),
        "th.wat_arun": (13.7437, 100.4888, .building),
        "au.opera": (-33.8568, 151.2153, .building),
        "au.great_barrier": (-16.5000, 146.2000, .nature),
        "au.uluru": (-25.3444, 131.0369, .nature),
        "au.twelve_apostles": (-38.6662, 143.1051, .area),
        "au.harbour_bridge": (-33.8523, 151.2108, .building),
    ]
}

/// 장소 도감 시트. 메뉴 > 기록 > 장소 도감에서 연다.
struct MapHomePlaceBookSheet: View {
    let stays: [PlaceStay]
    let language: MapHomeLanguage
    /// 여행 계획을 담을 때 쓴다. 미리보기에는 없다.
    var model: AppModel?
    var currentCoordinate: CLLocationCoordinate2D?
    /// 펼친 지도의 「큰 지도에서 보기」.
    var onSelect: (MapHomePlaceBookPin) -> Void = { _ in }
    var loadDrivePasses: () async -> [String: Date] = { [:] }

    @State private var state: MapHomePlaceBookState?
    @State private var menu = MapHomePlaceBookMenu()
    @State private var airportChoice: MapHomePlaceBookEntry?
    /// 카드 줄 사이에 지도를 펼친 명소.
    @State private var expandedID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var isTestMode = MapHomePlaceBookTestMode.isEnabled
    @State private var isRequestPresented = false
    @State private var isTripPresented = false
    @State private var tripEntry: MapHomePlaceBookEntry?
    @State private var tripDay = Calendar.autoupdatingCurrent.startOfDay(for: .now)
    @State private var drivePasses: [String: Date] = [:]
    private static let columnCount = 3

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    menuRows
                    if let state {
                        section(
                            MapHomePlaceBookMenu.isCountry(menu.selected) ? language.runtimeText("도시", "Cities") : language.text("랜드마크", "Landmarks"),
                            entries: state.landmarks,
                            proxy: proxy
                        )
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
            }
        }
        .background(Color.tpBackground)
        .onAppear {
            guard state == nil else { return }
            reload()
        }
        .onChange(of: menu.selected) {
            expandedID = nil
            reload()
        }
        .task {
            let passes = await loadDrivePasses()
            guard passes != drivePasses else { return }
            drivePasses = passes
            reload()
        }
        .sheet(isPresented: $isRequestPresented) {
            MapHomePlaceRequestSheet(language: language, currentCoordinate: currentCoordinate)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $isTripPresented) {
            if let model {
                MapHomeTripPlanSheet(model: model, language: language, onSelect: onSelect)
                    .presentationDetents([.large])
            }
        }
        .sheet(item: $tripEntry) { entry in
            VStack(spacing: 14) {
                Text(entry.title).font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
                DatePicker(language.text("날짜", "Date"), selection: $tripDay, displayedComponents: .date)
                toolButton(language.text("여행에 추가", "Add to trip")) {
                    if let pin = entry.pins.first {
                        model?.addTravelStop(title: entry.title, latitude: pin.latitude, longitude: pin.longitude, day: tripDay)
                    }
                    tripEntry = nil
                }
            }
            .padding(20)
            .presentationDetents([.height(240)])
        }
        .confirmationDialog(
            airportChoice?.title ?? "",
            isPresented: Binding(get: { airportChoice != nil }, set: { if !$0 { airportChoice = nil } }),
            titleVisibility: .visible
        ) {
            ForEach(airportChoice?.pins ?? [], id: \.self) { pin in
                Button(pin.title) { onSelect(pin) }
            }
        }
    }

    private func reload() {
        state = MapHomePlaceBookState.make(
            stays: stays, language: language, region: menu.selected,
            drivePasses: drivePasses.merging(MapHomePlaceBookTestMode.visits) { _, test in test }
        )
    }

    /// 다른 나라를 골라도 2·3줄 자리는 비워 둬 카드 시작 위치가 오르내리지 않는다(대표 지시).
    private var menuRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            chipRow(menu.countryItems, selectedID: menu.showsKoreaRows ? MapHomePlaceBookMenu.korea : menu.country) { menu.country = $0 }
            Group {
                chipRow(menu.browseItems, selectedID: menu.selectedBrowseID) { menu.selectBrowse($0) }
                chipRow(menu.listItems, selectedID: menu.selectedListID) { menu.selectList($0) }
                    .id(menu.browse)
            }
            .opacity(menu.showsKoreaRows ? 1 : 0)
            .allowsHitTesting(menu.showsKoreaRows)
            .accessibilityHidden(!menu.showsKoreaRows)
        }
    }

    private func chipRow(
        _ items: [MapHomePlaceBookMenu.Item],
        selectedID: String,
        action: @escaping (String) -> Void
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    let isSelected = item.id == selectedID
                    Button { action(item.id) } label: {
                        Text(item.title(language))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                            .foregroundStyle(isSelected ? Color.tpBackground : Color.tpInk)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(isSelected ? Color.tpInk : Color.tpCard, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(language.text("장소 도감", "Place book"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.headline), weight: .bold))
                    .foregroundStyle(Color.tpInk)
                    .onTapGesture(count: 5) {
                        MapHomePlaceBookTestMode.isEnabled.toggle()
                        isTestMode = MapHomePlaceBookTestMode.isEnabled
                    }
                Spacer()
                if model != nil {
                    Button { isTripPresented = true } label: { Image(systemName: "airplane.departure").frame(width: 44, height: 44) }
                        .accessibilityLabel(language.text("여행 계획", "Trip plan"))
                }
                Button { isRequestPresented = true } label: { Image(systemName: "mappin.and.ellipse").frame(width: 44, height: 44) }
                    .accessibilityLabel(language.text("장소 등록 요청", "Request a place"))
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel(language.text("닫기", "Close"))
            }
            .foregroundStyle(Color.tpInk)
            if isTestMode {
                Text(language.runtimeText("테스트 모드 · 기록에 저장되지 않음", "Test mode · not saved"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .bold))
                    .foregroundStyle(Color(hex: MapHomeInkWash.sealHex))
            }
            if let state {
                Text(language.text(
                    "찍은 도장 \(state.stampedCount) · 남은 곳 \(state.remainingCount)",
                    "Stamps \(state.stampedCount) · To go \(state.remainingCount)"
                ))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.body), weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
            }
        }
    }

    private func section(_ title: String, entries: [MapHomePlaceBookEntry], proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
                .foregroundStyle(Color.tpInk)
            LazyVStack(spacing: 10) {
                ForEach(Array(stride(from: 0, to: entries.count, by: Self.columnCount)), id: \.self) { start in
                    let row = Array(entries[start..<min(start + Self.columnCount, entries.count)])
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(row) { entry in
                            Button { toggle(entry, proxy: proxy) } label: { card(entry) }
                                .buttonStyle(.plain)
                                .disabled(entry.pins.isEmpty)
                        }
                        ForEach(row.count..<Self.columnCount, id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                    if let expanded = row.first(where: { $0.id == expandedID }) {
                        inlineMap(expanded)
                            .id(Self.mapAnchor)
                            .transition(.opacity)
                    }
                }
            }
        }
    }

    private static let mapAnchor = "place-book-inline-map"

    /// 카드를 누르면 그 줄 아래가 벌어지며 지도가 뜨고, 다시 누르면 닫힌다(대표 지시).
    private func toggle(_ entry: MapHomePlaceBookEntry, proxy: ScrollViewProxy) {
        let opens = expandedID != entry.id
        withAnimation(.easeInOut(duration: 0.25)) { expandedID = opens ? entry.id : nil }
        guard opens else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(Self.mapAnchor, anchor: .center) }
        }
    }

    private func inlineMap(_ entry: MapHomePlaceBookEntry) -> some View {
        VStack(spacing: 8) {
            Map(initialPosition: mapPosition(entry)) {
                ForEach(entry.pins, id: \.self) { pin in
                    Marker(pin.title, coordinate: CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude))
                        .tint(Color(hex: MapHomeInkWash.sealHex))
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: TaptionRadius.card, style: .continuous))
            .id(entry.id)
            Button {
                if entry.pins.count > 1 { airportChoice = entry } else if let pin = entry.pins.first { onSelect(pin) }
            } label: {
                Text(language.text("큰 지도에서 보기", "Open in full map"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionRadius.card, style: .continuous))
            }
            .buttonStyle(.plain)
            if entry.id.hasPrefix("intl."), model != nil {
                toolButton(language.text("여행에 추가", "Add to trip")) { tripEntry = entry }
            }
            if isTestMode {
                toolButton(language.runtimeText("가상 방문 찍기·지우기", "Toggle test visit")) {
                    MapHomePlaceBookTestMode.toggleVisit(entry.id)
                    reload()
                }
            }
        }
    }

    private func toolButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                .foregroundStyle(Color.tpInk)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func mapPosition(_ entry: MapHomePlaceBookEntry) -> MapCameraPosition {
        guard entry.pins.count == 1, let pin = entry.pins.first else { return .automatic }
        return .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude),
            latitudinalMeters: 2_500,
            longitudinalMeters: 2_500
        ))
    }

    private func card(_ entry: MapHomePlaceBookEntry) -> some View {
        VStack(spacing: 6) {
            Image(entry.artworkName)
                .resizable()
                .scaledToFit()
                .saturation(entry.isVisited ? 1 : 0)
                .opacity(entry.isVisited ? 1 : 0.5)
                .frame(height: 54)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) {
                    if entry.usesPassportStamp {
                        MapHomePassportStamp(visitDate: entry.firstVisit, countryCode: entry.stampCountry, size: entry.isVisited ? 46 : 26).offset(x: 6, y: -6)
                    } else {
                        MapHomePlaceSeal(mark: entry.stamp, size: 24).offset(x: 4, y: -4)
                    }
                }
            Text(entry.title)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                .foregroundStyle(entry.isVisited ? Color.tpInk : Color.tpSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(entry.subtitle == entry.title ? " " : entry.subtitle)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TaptionRadius.card, style: .continuous)
                .stroke(
                    entry.id == expandedID
                        ? Color(hex: MapHomeInkWash.sealHex)
                        : entry.isVisited ? Color(hex: MapHomeInkWash.sealHex).opacity(0.5) : Color.tpLine,
                    style: StrokeStyle(lineWidth: entry.id == expandedID ? 2 : 1, dash: entry.isVisited || entry.id == expandedID ? [] : [4, 3])
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.isVisited
            ? language.text("\(entry.title), 도장 찍음", "\(entry.title), stamped")
            : language.text("\(entry.title), 아직 가 보지 않음", "\(entry.title), not visited yet"))
    }
}
