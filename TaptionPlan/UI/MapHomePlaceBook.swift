import SwiftUI
import TaptionPlanCore

/// 장소 도감 한 칸(INK1108A01). 가 본 곳은 색 있는 그림과 도장, 아직이면 먹빛 그림과 점선 도장.
struct MapHomePlaceBookEntry: Identifiable, Equatable {
    enum Kind: Equatable { case registered, landmark }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let glyph: String
    let artworkName: String
    let firstVisit: Date?

    var isVisited: Bool { firstVisit != nil }
    var stamp: MapHomePlaceStampMark { MapHomePlaceStampMark(glyph: glyph, isStamped: isVisited) }
}

/// 도감 상태. 원본 머묾에서 매번 다시 구하고 저장하지 않는다.
struct MapHomePlaceBookState: Equatable {
    var registered: [MapHomePlaceBookEntry]
    var landmarks: [MapHomePlaceBookEntry]

    var entries: [MapHomePlaceBookEntry] { registered + landmarks }
    var stampedCount: Int { entries.filter(\.isVisited).count }
    var remainingCount: Int { entries.count - stampedCount }

    /// 등록 장소는 그 장소 키로 머문 기록이 한 번이라도 있으면, 랜드마크는 머문 자리가 반경 안이면 가 본 곳이다.
    /// 위치를 정하지 않은 기본 장소는 도감에 넣지 않는다.
    static func make(
        frequentPlaces: [FrequentPlace],
        stays: [PlaceStay],
        language: MapHomeLanguage,
        country: String = defaultCountry
    ) -> Self {
        let placed = frequentPlaces.filter { $0.point != nil }
        let firstArrivals = MapHomePlaceStampPolicy.firstArrivals(
            stays: stays, keys: Set(placed.map(\.stablePlaceKey))
        )
        let registered = placed.map { place in
            let destination = MapHomeLocationDestination(placeKind: place.kind) ?? .user
            return MapHomePlaceBookEntry(
                id: place.stablePlaceKey,
                kind: .registered,
                title: place.displayName,
                subtitle: language.runtimeText(destination.koreanName, destination.englishName),
                glyph: MapHomePlaceStampPolicy.glyph(kind: place.kind, name: place.displayName),
                artworkName: destination.iconAssetName,
                firstVisit: firstArrivals[place.stablePlaceKey]
            )
        }
        let landmarks = candidates(in: country).map { candidate in
            let title = language.runtimeText(candidate.name, candidate.englishName)
            return MapHomePlaceBookEntry(
                id: candidate.id,
                kind: .landmark,
                title: title,
                subtitle: countryName(country, language: language),
                // "N서울타워"처럼 로마자로 시작하면 첫 한글을 쓴다.
                glyph: (candidate.name.first { !$0.isASCII } ?? candidate.name.first).map(String.init) ?? "印",
                artworkName: candidate.artworkName,
                firstVisit: MapHomeLandmarkSites.site(for: candidate.id).flatMap { $0.firstVisit(in: stays) }
            )
        }
        return Self(registered: registered, landmarks: landmarks)
    }

    /// 처음 여는 나라(PLB1108A02). 나라는 랜드마크 id 앞의 소문자 지역 코드다.
    static let defaultCountry = "kr"

    /// 카탈로그 순서대로 겹치지 않는 나라 코드.
    static let countries: [String] = {
        var seen = Set<String>()
        return MapHomeLandmarkCatalog.candidates.compactMap { candidate in
            let code = countryCode(of: candidate)
            return seen.insert(code).inserted ? code : nil
        }
    }()

    static func candidates(in country: String) -> [MapHomeLandmarkCandidate] {
        MapHomeLandmarkCatalog.candidates.filter { countryCode(of: $0) == country }
    }

    static func countryName(_ country: String, language: MapHomeLanguage) -> String {
        language.locale.localizedString(forRegionCode: country.uppercased()) ?? country.uppercased()
    }

    private static func countryCode(of candidate: MapHomeLandmarkCandidate) -> String {
        String(candidate.id.prefix { $0 != "." })
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

        var radiusMeters: Double {
            switch self {
            case .building: 500
            case .area: 2_000
            case .nature: 5_000
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
    let frequentPlaces: [FrequentPlace]
    let stays: [PlaceStay]
    let language: MapHomeLanguage

    @State private var state: MapHomePlaceBookState?
    @State private var country = MapHomePlaceBookState.defaultCountry
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                countryPicker
                if let state {
                    if !state.registered.isEmpty {
                        section(language.text("등록한 곳", "My places"), entries: state.registered)
                    }
                    section(language.text("랜드마크", "Landmarks"), entries: state.landmarks)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
        .background(Color.tpBackground)
        .onAppear {
            guard state == nil else { return }
            reload()
        }
        .onChange(of: country) { reload() }
    }

    private func reload() {
        state = MapHomePlaceBookState.make(
            frequentPlaces: frequentPlaces, stays: stays, language: language, country: country
        )
    }

    private var countryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MapHomePlaceBookState.countries, id: \.self) { code in
                    let isSelected = code == country
                    Button {
                        country = code
                    } label: {
                        Text(MapHomePlaceBookState.countryName(code, language: language))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                            .foregroundStyle(isSelected ? Color.tpBackground : Color.tpInk)
                            .padding(.horizontal, 12)
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
            Text(language.text("장소 도감", "Place book"))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.headline), weight: .bold))
                .foregroundStyle(Color.tpInk)
            if let state {
                Text(language.text(
                    "찍은 도장 \(state.stampedCount) · 남은 곳 \(state.remainingCount)",
                    "Stamps \(state.stampedCount) · To go \(state.remainingCount)"
                ))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.body), weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func section(_ title: String, entries: [MapHomePlaceBookEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
                .foregroundStyle(Color.tpInk)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(entries) { card($0) }
            }
        }
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
                    MapHomePlaceSeal(mark: entry.stamp, size: 24).offset(x: 4, y: -4)
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
                    entry.isVisited ? Color(hex: MapHomeInkWash.sealHex).opacity(0.5) : Color.tpLine,
                    style: StrokeStyle(lineWidth: 1, dash: entry.isVisited ? [] : [4, 3])
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.isVisited
            ? language.text("\(entry.title), 도장 찍음", "\(entry.title), stamped")
            : language.text("\(entry.title), 아직 가 보지 않음", "\(entry.title), not visited yet"))
    }
}
