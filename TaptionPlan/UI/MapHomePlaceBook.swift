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
        language: MapHomeLanguage
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
        let landmarks = MapHomeLandmarkCatalog.candidates.map { candidate in
            let title = language.runtimeText(candidate.name, candidate.englishName)
            return MapHomePlaceBookEntry(
                id: candidate.id,
                kind: .landmark,
                title: title,
                subtitle: language.runtimeText(candidate.country, "Landmark"),
                // "N서울타워"처럼 로마자로 시작하면 첫 한글을 쓴다.
                glyph: (candidate.name.first { !$0.isASCII } ?? candidate.name.first).map(String.init) ?? "印",
                artworkName: candidate.artworkName,
                firstVisit: MapHomeLandmarkSites.site(for: candidate.id).flatMap { $0.firstVisit(in: stays) }
            )
        }
        return Self(registered: registered, landmarks: landmarks)
    }
}

/// 랜드마크 중심 좌표와 반경. 넓은 자연 지형은 반경을 크게 잡았다(공개 지도의 대략 좌표).
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
    static func site(for id: String) -> MapHomeLandmarkSite? {
        table[id].map { MapHomeLandmarkSite(latitude: $0.0, longitude: $0.1, radiusMeters: $0.2) }
    }

    /// 랜드마크 id → (위도, 경도, 반경 m).
    static let table: [String: (Double, Double, Double)] = [
        "kr.gyeongbokgung": (37.5796, 126.9770, 600), "kr.bulguksa": (35.7900, 129.3320, 600),
        "kr.seongsan": (33.4580, 126.9425, 1_200), "kr.haeundae": (35.1587, 129.1604, 1_200),
        "kr.hahoe": (36.5390, 128.5180, 900), "kr.namsan": (37.5512, 126.9882, 700),
        "kr.hallasan": (33.3617, 126.5292, 6_000),
        "jp.fuji": (35.3606, 138.7274, 8_000), "jp.himeji": (34.8394, 134.6939, 600),
        "jp.fushimi": (34.9671, 135.7727, 800), "jp.itsukushima": (34.2959, 132.3198, 800),
        "jp.arashiyama": (35.0094, 135.6668, 1_500),
        "us.liberty": (40.6892, -74.0445, 500), "us.grandcanyon": (36.1069, -112.1129, 25_000),
        "us.golden_gate": (37.8199, -122.4783, 1_500), "us.yosemite": (37.8651, -119.5383, 20_000),
        "us.mount_rushmore": (43.8791, -103.4591, 1_500),
        "gb.bigben": (51.5007, -0.1246, 500), "gb.stonehenge": (51.1789, -1.8262, 800),
        "gb.edinburgh": (55.9486, -3.1999, 600), "gb.lake_district": (54.4609, -3.0886, 25_000),
        "gb.tower_bridge": (51.5055, -0.0754, 500),
        "fr.eiffel": (48.8584, 2.2945, 600), "fr.mont_saint_michel": (48.6361, -1.5115, 1_500),
        "fr.louvre": (48.8606, 2.3376, 500), "fr.versailles": (48.8049, 2.1204, 1_200),
        "fr.alps": (45.8326, 6.8652, 30_000),
        "it.colosseum": (41.8902, 12.4922, 500), "it.venice": (45.4408, 12.3155, 3_000),
        "it.pisa": (43.7230, 10.3966, 500), "it.dolomites": (46.4102, 11.8440, 30_000),
        "it.amalfi": (40.6340, 14.6027, 10_000),
        "cn.great_wall": (40.4319, 116.5704, 3_000), "cn.forbidden_city": (39.9163, 116.3972, 800),
        "cn.zhangjiajie": (29.3150, 110.4343, 15_000), "cn.terracotta": (34.3841, 109.2785, 800),
        "cn.li_river": (24.7780, 110.4960, 25_000),
        "es.sagrada": (41.4036, 2.1744, 500), "es.alhambra": (37.1761, -3.5881, 700),
        "es.park_guell": (41.4145, 2.1527, 500), "es.camino": (42.8806, -8.5446, 2_000),
        "es.teide": (28.2724, -16.6425, 10_000),
        "th.grand_palace": (13.7500, 100.4913, 600), "th.phiphi": (7.7407, 98.7784, 6_000),
        "th.ayutthaya": (14.3532, 100.5689, 4_000), "th.doi_inthanon": (18.5883, 98.4861, 10_000),
        "th.wat_arun": (13.7437, 100.4888, 400),
        "au.opera": (-33.8568, 151.2153, 500), "au.great_barrier": (-16.5000, 146.2000, 30_000),
        "au.uluru": (-25.3444, 131.0369, 5_000), "au.twelve_apostles": (-38.6662, 143.1051, 2_000),
        "au.harbour_bridge": (-33.8523, 151.2108, 500),
    ]
}

/// 장소 도감 시트. 메뉴 > 기록 > 장소 도감에서 연다.
struct MapHomePlaceBookSheet: View {
    let frequentPlaces: [FrequentPlace]
    let stays: [PlaceStay]
    let language: MapHomeLanguage

    @State private var state: MapHomePlaceBookState?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
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
            state = MapHomePlaceBookState.make(frequentPlaces: frequentPlaces, stays: stays, language: language)
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
