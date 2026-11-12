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
