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

// MARK: - 계획표 판 높이(TVU1113A01, Trip 원본의 지도/일정 3단계)

/// 계획표 판의 높이: 내림(지도 넓게) · 반반(처음 높이) · 지도 접기(일정 넓게). 손잡이를 끌어 그 사이 높이로도 둘 수 있고 기기에 기억한다.
enum TravelPlanSheetHeight {
    /// 지도 접기에서도 머리말·돈 줄·일차 칩·하단 막대가 보이게 남기는 높이.
    static let chrome: CGFloat = 330

    /// 손잡이로 고를 수 있는 범위. 넓은 화면·가로는 오른쪽 판이라 높이를 바꾸지 않는다.
    static func range(_ size: CGSize) -> ClosedRange<CGFloat> {
        let base = TravelModeView.planTableHeight(size)
        guard !TravelModeView.isWide(size) else { return base...base }
        return min(220, base)...max(base, size.height - chrome)
    }

    /// 기억한 높이(없으면 0)를 지금 화면에 맞춘 값. 없으면 반반 높이.
    static func height(_ size: CGSize, stored: Double) -> CGFloat {
        let range = range(size)
        return stored > 0 ? min(max(CGFloat(stored), range.lowerBound), range.upperBound) : TravelModeView.planTableHeight(size)
    }

    /// 손잡이를 끈 만큼 바뀐 높이(위로 끌면 커진다). 화면 갱신이 드물게 4pt 단위로 맞춘다.
    static func dragged(from height: CGFloat, translation: CGFloat, size: CGSize) -> CGFloat {
        let range = range(size)
        return min(max(((height - translation) / 4).rounded() * 4, range.lowerBound), range.upperBound)
    }

    /// 지도가 접힌(일정이 넓은) 높이인지: 반반과 끝의 가운데보다 크면.
    static func isMapFolded(_ height: CGFloat, size: CGSize) -> Bool {
        let range = range(size)
        return range.upperBound > range.lowerBound && height > (TravelModeView.planTableHeight(size) + range.upperBound) / 2
    }

    /// 「지도 접기 / 지도 펼치기」 단추를 눌렀을 때의 높이.
    static func toggled(_ height: CGFloat, size: CGSize) -> CGFloat {
        isMapFolded(height, size: size) ? TravelModeView.planTableHeight(size) : range(size).upperBound
    }
}

/// 계획표 판 위의 막대: 가운데 손잡이(누르면 내리고 끌면 높이 조절), 오른쪽에 「지도 접기 / 지도 펼치기」.
struct TravelPlanHandleBar: View {
    let language: MapHomeLanguage
    let isMapFolded: Bool
    /// 높이를 바꿀 수 없는 배치(넓은 화면)면 단추를 숨긴다.
    let canResize: Bool
    let onLower: () -> Void
    let onToggleMap: () -> Void
    /// 끄는 동안의 이동량과, 손을 뗐는지.
    let onDrag: (CGFloat, Bool) -> Void

    var body: some View {
        Capsule().fill(TravelInk.border).frame(width: 44, height: 5).padding(.top, 7).padding(.bottom, 3)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onLower)
            .highPriorityGesture(DragGesture(minimumDistance: 6)
                .onChanged { onDrag($0.translation.height, false) }
                .onEnded { onDrag($0.translation.height, true) }, isEnabled: canResize)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(language.text("계획표 내리기", "Close plan table"))
            .accessibilityIdentifier("travelPlanHandle")
            .overlay(alignment: .trailing) {
                if canResize {
                    Button(action: onToggleMap) {
                        Image(systemName: isMapFolded ? "rectangle.split.1x2" : "rectangle.expand.vertical")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(TravelInk.plan).frame(width: 44, height: 22)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                    .accessibilityLabel(isMapFolded ? language.text("지도 펼치기", "Expand map") : language.text("지도 접기", "Collapse map"))
                    .accessibilityIdentifier("travelPlanMapToggle")
                }
            }
    }
}
