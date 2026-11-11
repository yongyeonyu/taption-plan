import SwiftUI
import UIKit

enum MapHomeWBSTripStyle {
    static let paperHex = "#FCF9F4"
    static let actualRouteHex = "#458B88"
    static let transitRouteHex = "#9A6A2D"
    static let forecastRouteHex = "#C65D4D"
    static let actualRouteOpacity = 0.96
    static let forecastRouteOpacity = 0.78
    static let actualRouteLineWidth: CGFloat = 2.2
    static let forecastRouteLineWidth: CGFloat = 1.8
    static let routeDash: [NSNumber] = [4, 3]
    /// 「백자」 지도에서만 쓰는 경로 색(RTC1111A01, 대표 결정). 가라앉힌 땅 위에서 대비 5.14.
    static let porcelainRouteHex = "#A8442F"

    /// 지도 모양별 내 경로 색. 「백자」만 테라코타이고 나머지는 그대로 청록이다.
    static func actualRouteHex(for style: MapDisplayStyle) -> String {
        style == .mapLibrePorcelain ? porcelainRouteHex : actualRouteHex
    }
}

/// 글자 크기 8단계. 화면마다 흩어져 있던 27가지 크기를 이 여덟 값으로 모은다.
/// 새 코드는 이 이름을 쓰고, 예전 호출부는 `snapped`가 가까운 단계로 맞춘다.
enum TaptionType {
    static let caption: CGFloat = 11
    static let label: CGFloat = 12
    static let body: CGFloat = 14
    static let bodyStrong: CGFloat = 15
    static let title: CGFloat = 17
    static let headline: CGFloat = 20
    static let display: CGFloat = 24
    static let hero: CGFloat = 34

    static let steps: [CGFloat] = [caption, label, body, bodyStrong, title, headline, display, hero]

    /// 8단계 중 가장 가까운 값으로 맞춘다.
    /// 11pt 아래는 올리고(읽히지 않는 크기), 24pt 위는 그대로 둔다(아이콘·큰 숫자라 단계에 묶을 이유가 없다).
    static func snapped(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return body }
        if value <= caption { return caption }
        if value >= display { return value }
        return steps.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    /// 시스템 글자 크기 설정을 반영한다.
    ///
    /// 고정 크기만 쓰던 화면이라 설정을 키워도 글자가 그대로였다. 접근성 최대 크기에서
    /// 고정 높이 레이아웃이 깨지지 않도록 1.3배에서 멈춘다(전체 레이아웃 감사는 별도 작업).
    static func scaled(_ size: CGFloat, textStyle: UIFont.TextStyle = .body) -> CGFloat {
        let scaled = UIFontMetrics(forTextStyle: textStyle).scaledValue(for: size)
        return min(scaled, size * 1.3)
    }
}

extension Font {
    /// 예전 호출부가 넘기던 값에는 +2가 숨어 있었다(12를 넘기면 14로 그려졌다).
    /// 그 +2를 여기서 더한 뒤 8단계에 맞추므로, 이미 단계에 있던 글자는 크기가 바뀌지 않는다.
    static func taption(
        size: CGFloat,
        weight: Font.Weight = .regular
    ) -> Font {
        .taptionFixed(size: TaptionType.scaled(TaptionType.snapped(size + 2)), weight: weight)
    }
}

extension View {
    /// 글자 바깥에 테마 배경색 테두리(기본 1.5pt, 8방향)를 둘러 지도·색 띠 위에서도 읽히게 한다(UIX1101B02·B04, 대표).
    func taptionTextOutline(_ color: Color = .tpBackground, width: CGFloat = 1.5) -> some View {
        let d = width * 0.7
        return shadow(color: color, radius: 0, x: width, y: 0)
            .shadow(color: color, radius: 0, x: -width, y: 0)
            .shadow(color: color, radius: 0, x: 0, y: width)
            .shadow(color: color, radius: 0, x: 0, y: -width)
            .shadow(color: color, radius: 0, x: d, y: d)
            .shadow(color: color, radius: 0, x: -d, y: d)
            .shadow(color: color, radius: 0, x: d, y: -d)
            .shadow(color: color, radius: 0, x: -d, y: -d)
    }
}

/// 지도 스타일이 정하는 앱 색 테마(THM1101A01, 대표). 지도 하나에 테마 하나이고 따로 고르지 않는다.
/// 핵심 색(글자·보조 글자·배경·면·선·강조)만 바꾸고 활동 분류 색은 그대로 둔다.
enum TaptionUITheme: String, CaseIterable, Identifiable, Sendable {
    case classic
    case navy
    case purple
    case brown
    /// 수묵(INK1108A01): 한지 바탕·먹 글자·붉은 인주 강조 하나.
    case ink

    struct Palette: Sendable {
        let background: Color
        let surface: Color
        let line: Color
        let accent: Color
        let secondary: Color
        let ink: Color
    }

    static let storageKey = "taptionUITheme"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: TaptionUITheme?

    /// 색을 읽을 때마다 저장소를 열지 않도록 한 번 읽은 값을 쓴다. 바꿀 때는 `apply`로 함께 고친다.
    static var current: TaptionUITheme {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let value = UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .classic
        cached = value
        return value
    }

    static func apply(_ theme: TaptionUITheme) {
        lock.lock()
        cached = theme
        lock.unlock()
        UserDefaults.standard.set(theme.rawValue, forKey: storageKey)
    }

    var id: String { rawValue }

    /// 어두운 테마는 유리·시트도 어둡게 그려야 밝은 글자가 읽힌다.
    var isDark: Bool { self == .navy || self == .brown }
    var colorScheme: ColorScheme { isDark ? .dark : .light }

    /// 판타지·애플맵·위성은 기본 양피지, 야간은 남색, 계절은 보고 있는 날짜의 계절 색, 실외(고대비)는 갈색, 수묵은 한지.
    static func forMap(_ style: MapDisplayStyle) -> TaptionUITheme {
        switch style.runtimeStyle {
        case .mapLibreNight: .navy
        case .mapLibreCasual: .purple
        case .mapLibreContrast: .brown
        case .mapLibreInk: .ink
        case .mapLibreRPG, .mapLibrePorcelain, .standard, .hybrid: .classic
        }
    }

    /// 타일을 붙이는 동안 잠깐 산책 지도로 바뀌는 때(`mapHomeAutoLandStyleState`)는 테마를 그대로 둔다.
    static func follow(mapStyle: MapDisplayStyle) {
        guard UserDefaults.standard.string(forKey: "mapHomeAutoLandStyleState")?.isEmpty != false else { return }
        let theme = forMap(mapStyle)
        if theme != current { apply(theme) }
    }

    /// 6단 색상표: 배경·면·선·강조·보조 글자·글자. 각 지도의 물·도로 색 계열에 맞췄다.
    /// 강조 색은 흰 글자 4.5:1 이상, 면 위 3:1 이상을 지킨다.
    var palette: Palette? {
        switch self {
        case .classic: nil
        case .navy: Self.palette("#0A101E", "#141D33", "#2A3D63", "#2A74C6", "#A9C4E0", "#F5F9FF")
        case .purple: TaptionSeasonStore.current.palette
        case .brown: Self.palette("#17130E", "#2A241C", "#54483A", "#99690F", "#D8CBB4", "#FFFBF4")
        case .ink: Self.palette(MapHomeInkWash.uiHexes)
        }
    }

    private static func palette(_ hexes: String...) -> Palette { palette(hexes) }

    static func palette(_ hexes: [String]) -> Palette {
        Palette(
            background: Color(hex: hexes[0]), surface: Color(hex: hexes[1]), line: Color(hex: hexes[2]),
            accent: Color(hex: hexes[3]), secondary: Color(hex: hexes[4]), ink: Color(hex: hexes[5])
        )
    }
}

extension Color {
    // Tokyo postcard palette: a cool sky, warm paper and soft botanical
    // accents keep the timeline calm without lowering text contrast.
    // RA 웜 양피지: RPG 양피지 지도와 통일. 크림 배경·세피아 잉크·테라코타 액센트.
    static var tpInk: Color { TaptionUITheme.current.palette?.ink ?? classicInk }
    /// 9~10pt 보조 글자에 쓰이므로 배경 대비 5.3:1을 지킨다(예전 #7A6C50은 4.29:1이었다).
    static var tpSecondary: Color { TaptionUITheme.current.palette?.secondary ?? classicSecondary }
    static var tpBackground: Color { TaptionUITheme.current.palette?.background ?? classicBackground }
    static var tpSurface: Color { TaptionUITheme.current.palette?.surface ?? classicSurface }
    static let classicInk = Color(red: 62 / 255, green: 51 / 255, blue: 32 / 255)
    static let classicSecondary = Color(red: 107 / 255, green: 94 / 255, blue: 69 / 255)
    static let classicBackground = Color(red: 243 / 255, green: 234 / 255, blue: 214 / 255)
    static let classicSurface = Color(red: 253 / 255, green: 250 / 255, blue: 243 / 255)
    static var tpSurfaceBlue: Color { TaptionUITheme.current.palette?.surface ?? Color(red: 241 / 255, green: 248 / 255, blue: 252 / 255) }
    static var tpSurfacePink: Color { TaptionUITheme.current.palette?.surface ?? Color(red: 255 / 255, green: 242 / 255, blue: 245 / 255) }
    static var tpSurfaceSage: Color { TaptionUITheme.current.palette?.surface ?? Color(red: 241 / 255, green: 248 / 255, blue: 240 / 255) }
    static var tpSurfaceLavender: Color { TaptionUITheme.current.palette?.surface ?? Color(red: 247 / 255, green: 243 / 255, blue: 251 / 255) }
    static var tpSurfaceCream: Color { TaptionUITheme.current.palette?.surface ?? Color(red: 255 / 255, green: 249 / 255, blue: 236 / 255) }
    static var tpSky: Color { TaptionUITheme.current.palette?.line ?? Color(red: 185 / 255, green: 221 / 255, blue: 237 / 255) }
    static var tpLine: Color { TaptionUITheme.current.palette?.line ?? classicLine }
    static let classicLine = Color(red: 227 / 255, green: 214 / 255, blue: 184 / 255)
    /// 홈 화면 테두리 한 가지 색(BRD1111A01, 대표: 진한 회색으로 통일). 어두운 테마는 면 위에서 보이는 테마 선 색.
    static var tpBorder: Color {
        TaptionUITheme.current.isDark ? tpLine : classicBorder
    }
    static let classicBorder = Color(hex: "#8C8C8C")
    static let tpHoliday = Color(red: 0.86, green: 0.27, blue: 0.30)
    static let tpSaturday = Color(red: 0.24, green: 0.47, blue: 0.77)
    /// 강조 글자·배지에 쓰인다. 흰 글자를 얹어도 5.9:1이 되도록 명도를 낮췄다.
    static var tpAccent: Color { TaptionUITheme.current.palette?.accent ?? classicAccent }
    static let classicAccent = Color(red: 168 / 255, green: 68 / 255, blue: 47 / 255)
    /// 사이드바 시간 글자. 어두운 테마에서는 투명도 때문에 회색으로 가라앉아 흰 톤으로 올린다(UIX1101B05, 대표).
    static func tpSidebarTime(_ opacity: Double) -> Color {
        TaptionUITheme.current.isDark ? Color.white.opacity(0.8 + opacity * 0.2) : tpInk.opacity(opacity)
    }
    /// 날짜 배지·날짜 줄의 토요일·일요일 글자. 어두운 테마에서는 밝은 파랑·밝은 분홍(UIX1101B06, 대표).
    static var tpSaturdayText: Color { TaptionUITheme.current.isDark ? Color(hex: "#8CCBFF") : tpReferenceBlue }
    static var tpSundayText: Color { TaptionUITheme.current.isDark ? Color(hex: "#FF9EC4") : tpHoliday }
    /// 카운터 창 아이콘. 어두운 테마의 액센트는 면과 대비가 2.6~2.9:1이라 보조 글자 색(5.7~6.3:1)을 쓴다.
    static var tpCounterIcon: Color { TaptionUITheme.current.palette?.secondary ?? classicAccent }

    /// 카드·입력 칸처럼 흰색이던 면. 어두운 테마에서는 테마 면 색을 쓴다.
    static var tpCard: Color { TaptionUITheme.current.palette?.surface ?? .white }
    /// 흰 글자를 얹는 주요 단추. 어두운 테마의 글자 색은 밝아서 강조 색을 쓴다.
    static var tpPrimaryFill: Color { TaptionUITheme.current.palette?.accent ?? classicInk }
    /// 지도 위 유리에 입히는 테마 색.
    static var tpGlassTint: Color {
        TaptionUITheme.current.palette.map { $0.surface.opacity(0.97) } ?? classicSurface.opacity(0.42)
    }
    /// 날씨 칩의 남은 시간대 칸. 흰 글자를 얹는다.
    static var tpWeatherActiveFill: Color { TaptionUITheme.current.palette?.accent ?? classicSecondary }

    // The original product guide's ten-color set, softened by the postcard
    // surfaces above. Map Home uses these as accents rather than repainting
    // every legacy surface.
    /// 메뉴 아이콘 색. 지도 양피지와 어울리는 흙빛 계열이고, 어두운 테마에서는 면과 대비가 나도록 밝혀 쓴다.
    static func tpMenuChip(_ hex: String) -> Color {
        TaptionUITheme.current.isDark ? Color(hex: hex).mix(with: .white, by: 0.42) : Color(hex: hex)
    }
    static let tpReferenceBlue = Color(hex: "#2D9BF0")
    static let tpReferenceRose = Color(hex: "#F15C80")
    static let tpReferenceMint = Color(hex: "#48B38C")
    static let tpReferenceGray = Color(hex: "#777777")
    static let tpReferenceGold = Color(hex: "#E1C453")
    static let tpReferencePurple = Color(hex: "#B965C8")
    static let tpReferenceCyan = Color(hex: "#45CFD5")
    static let tpReferenceSand = Color(hex: "#D7A77F")
    static let tpReferenceBlush = Color(hex: "#FBBEBE")
    static let tpReferenceLeaf = Color(hex: "#8ED97E")

    static let tpPastelRose = Color(hex: "#F28FA9")
    static let tpPastelMint = Color(hex: "#8FD9C5")
    static let tpPastelSky = Color(hex: "#A9CFF0")
    static let tpPastelLavender = Color(hex: "#C2B4E9")
    static let tpPastelButter = Color(hex: "#F2D58D")
    static let tpPastelPeach = Color(hex: "#F2B18D")
    static let tpPastelGray = Color(hex: "#CBD5E1")

    static let tpProject = Color(red: 190 / 255, green: 218 / 255, blue: 227 / 255)
    static let tpHobby = Color(red: 196 / 255, green: 233 / 255, blue: 218 / 255)
    static let tpExercise = Color(red: 254 / 255, green: 213 / 255, blue: 207 / 255)
    static let tpMovement = Color(red: 232 / 255, green: 211 / 255, blue: 179 / 255)
    static let tpStudy = Color(red: 211 / 255, green: 199 / 255, blue: 230 / 255)
    static let tpSleep = Color(red: 217 / 255, green: 221 / 255, blue: 234 / 255)
    static let tpRoutine = Color(red: 243 / 255, green: 230 / 255, blue: 184 / 255)
    static let tpRelationship = Color(red: 244 / 255, green: 215 / 255, blue: 231 / 255)
    static let tpRest = Color(red: 220 / 255, green: 233 / 255, blue: 226 / 255)
    static let tpTravel = Color(red: 241 / 255, green: 181 / 255, blue: 152 / 255)
    static let tpHealthArea = Color(red: 200 / 255, green: 223 / 255, blue: 195 / 255)
    static let tpEvent = Color(red: 245 / 255, green: 221 / 255, blue: 238 / 255)
    static let tpWeather = Color(red: 221 / 255, green: 234 / 255, blue: 248 / 255)
    static let tpPhoto = Color(red: 231 / 255, green: 215 / 255, blue: 238 / 255)
    static let tpPlace = Color(red: 216 / 255, green: 232 / 255, blue: 242 / 255)
    static let tpTransit = Color(red: 243 / 255, green: 223 / 255, blue: 192 / 255)

    static let tpProjectDark = Color(red: 74 / 255, green: 144 / 255, blue: 176 / 255)
    static let tpHobbyDark = Color(red: 63 / 255, green: 169 / 255, blue: 124 / 255)
    static let tpExerciseDark = Color(red: 226 / 255, green: 96 / 255, blue: 76 / 255)
    static let tpMovementDark = Color(red: 157 / 255, green: 117 / 255, blue: 61 / 255)
    static let tpStudyDark = Color(red: 123 / 255, green: 94 / 255, blue: 167 / 255)
    static let tpSleepDark = Color(red: 98 / 255, green: 106 / 255, blue: 131 / 255)
    static let tpRoutineDark = Color(red: 162 / 255, green: 122 / 255, blue: 22 / 255)
    static let tpRelationshipDark = Color(red: 180 / 255, green: 91 / 255, blue: 136 / 255)
    static let tpRestDark = Color(red: 77 / 255, green: 128 / 255, blue: 104 / 255)
    static let tpTravelDark = Color(red: 217 / 255, green: 123 / 255, blue: 47 / 255)
    static let tpHealthDark = Color(red: 95 / 255, green: 141 / 255, blue: 91 / 255)
    static let tpEventDark = Color(red: 157 / 255, green: 93 / 255, blue: 134 / 255)
    static let tpWeatherDark = Color(red: 79 / 255, green: 120 / 255, blue: 151 / 255)
    static let tpPhotoDark = Color(red: 142 / 255, green: 90 / 255, blue: 168 / 255)
    static let tpPlaceDark = Color(red: 53 / 255, green: 124 / 255, blue: 165 / 255)
    static let tpTransitDark = Color(red: 154 / 255, green: 106 / 255, blue: 45 / 255)
    /// 지금 시각 표시. 흰 글자를 얹으므로 5.6:1이 되도록 어둡게 잡는다.
    static let tpNow = Color(red: 198 / 255, green: 40 / 255, blue: 40 / 255)

    // Neutral control surfaces shared by the non-home screens.
    static var tpControlFill: Color { TaptionUITheme.current.palette.map { $0.line.opacity(0.55) } ?? Color(red: 0.94, green: 0.94, blue: 0.95) }
    static var tpControlFillSoft: Color { TaptionUITheme.current.palette.map { $0.line.opacity(0.4) } ?? Color(red: 0.95, green: 0.95, blue: 0.96) }
    static var tpFieldFill: Color { TaptionUITheme.current.palette.map { $0.line.opacity(0.3) } ?? Color(red: 0.965, green: 0.965, blue: 0.975) }
    static var tpControlStroke: Color { TaptionUITheme.current.palette?.line ?? Color(red: 0.89, green: 0.89, blue: 0.91) }
    static var tpTrackFill: Color { TaptionUITheme.current.palette.map { $0.line.opacity(0.6) } ?? Color(red: 0.93, green: 0.93, blue: 0.94) }
    static var tpWarningTint: Color { TaptionUITheme.current.isDark ? Color(hex: "#4A3A16") : Color(red: 1.00, green: 0.95, blue: 0.85) }
    static var tpSuccessTint: Color { TaptionUITheme.current.isDark ? Color(hex: "#1F3A24") : Color(red: 0.93, green: 0.96, blue: 0.91) }

    init(hex: String) {
        let clean = hex
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&value)
        let red: Double
        let green: Double
        let blue: Double
        switch clean.count {
        case 3:
            red = Double((value >> 8) * 17) / 255
            green = Double((value >> 4 & 0xF) * 17) / 255
            blue = Double((value & 0xF) * 17) / 255
        default:
            red = Double(value >> 16 & 0xFF) / 255
            green = Double(value >> 8 & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        }
        self.init(red: red, green: green, blue: blue)
    }

    var hexRGBString: String? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

/// 모서리 반경 토큰. 화면에서 실제로 쓰이던 값을 이름만 붙여 모았다.
enum TaptionRadius {
    static let tight: CGFloat = 7
    static let small: CGFloat = 8
    static let control: CGFloat = 9
    static let field: CGFloat = 10
    static let compact: CGFloat = 11
    static let panel: CGFloat = 12
    static let tile: CGFloat = 13
    static let card: CGFloat = 14
}

/// 모서리 네 단계(UIR1111A01, 대표 결정). 새로 다듬는 화면은 이 넷만 쓴다: 작은 단추·칩 8, 카드·띠 12, 묶음 패널 16, 시트 24.
/// 안쪽 면은 바깥보다 한 단계 작게 써서 모서리가 나란히 돈다.
enum TaptionCorner {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let sheet: CGFloat = 24
}

/// 그림자 세 높이(UIR1111A01): 지도 위에 뜬 것, 시트 안 카드, 없음.
enum TaptionShadowLevel {
    case floating, card, none
}

extension View {
    @ViewBuilder
    func taptionShadow(_ level: TaptionShadowLevel) -> some View {
        switch level {
        // 지도 위 칩·카드·패널이 모두 같은 높이로 떠 보이게 한 값(3묶음에서 지도 화면 21곳을 이것으로 모음).
        case .floating: shadow(color: .black.opacity(0.14), radius: 5, y: 2)
        case .card: shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        case .none: self
        }
    }
}

/// 스택 간격 토큰. 화면에서 실제로 쓰이던 값을 이름만 붙여 모았다.
enum TaptionSpacing {
    static let tight: CGFloat = 4
    static let compact: CGFloat = 5
    static let snug: CGFloat = 6
    static let cozy: CGFloat = 7
    static let regular: CGFloat = 8
}

/// 메뉴 화면이 공유하는 여백·컨트롤 토큰. 터치 영역은 각 화면의 최소 높이를
/// 유지하고, 시각적 패딩과 아이콘만 줄여 정보 밀도를 높인다.
enum TaptionMenuMetrics {
    static let contentInset: CGFloat = 12
    static let sectionSpacing: CGFloat = 8
    static let compactSpacing: CGFloat = 6
    static let tightSpacing: CGFloat = 5
    static let compactRowVerticalPadding: CGFloat = 7
    static let minimumHitSize: CGFloat = 44
    static let topBarIconSize: CGFloat = 30
    static let topBarIconHitSize: CGFloat = 44
    static let topBarNavigationButtonSize: CGFloat = 26
    static let topBarNavigationHitSize: CGFloat = 44
    static let chipHorizontalPadding: CGFloat = 8
    static let suggestionButtonHorizontalPadding: CGFloat = 12
    static let chipVerticalPadding: CGFloat = 5.25
    static let compactButtonVerticalPadding: CGFloat = 6
    static let sectionHeaderVerticalPadding: CGFloat = 8
    static let scaleControlVerticalPadding: CGFloat = 4.5
}

extension View {
    /// 보이는 크기와 배치는 그대로 두고 터치 영역만 최소 44pt까지 넓힌다.
    nonisolated func taptionTouchTarget(visualWidth: CGFloat, visualHeight: CGFloat) -> some View {
        let minimum = TaptionMenuMetrics.minimumHitSize
        return taptionHitOutset(
            horizontal: max(0, (minimum - visualWidth) / 2),
            vertical: max(0, (minimum - visualHeight) / 2)
        )
    }

    /// 이웃 컨트롤과 겹치지 않도록 방향별로 터치 영역을 직접 넓힐 때 쓴다.
    nonisolated func taptionHitOutset(horizontal: CGFloat = 0, vertical: CGFloat = 0) -> some View {
        padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .contentShape(Rectangle())
            .padding(.horizontal, -horizontal)
            .padding(.vertical, -vertical)
    }
}

/// 지도 홈·기록·설정이 같은 색을 쓰도록 묶은 자동 기록의 대분류 팔레트다.
enum CanonicalCategoryPalette {
    static let orderedIDs = [
        "activity", "work", "study", "hobby",
        "sleep", "movement", "eating", "exercise", "health", "housework", "unconfirmed",
    ]

    static let hexes: [String: String] = [
        "activity": "#29A383",
        "work": "#2563EB",
        "study": "#00A2C7",
        "hobby": "#8B5CF6",
        "sleep": "#5B5BD6",
        "movement": "#F76B15",
        "eating": "#E1C453",
        "exercise": "#DC2626",
        "health": "#C0268E",
        "shower": "#38BDF8",
        "housework": "#92400E",
        "unconfirmed": "#94A3B8",
    ]

    static func hex(_ id: String) -> String {
        hexes[id] ?? hexes["activity"] ?? "#29A383"
    }

    static func color(_ id: String) -> Color {
        Color(hex: hex(id))
    }
}

enum MapHomePastelPalette {
    // 기본 분류는 색상(hue)이 겹치지 않게 골랐다: 초록·파랑·청록·보라·남색·주황·노랑·빨강·분홍·하늘·갈색·회색.
    static let hexes: [String: String] = [
        "activity": "#43A047",
        "work": "#2E6FDB",
        "study": "#00ACC1",
        "hobby": "#9C4DCC",
        "sleep": "#3F3D99",
        "movement": "#F57C00",
        "eating": "#E5B800",
        "exercise": "#D32F2F",
        "health": "#EC407A",
        "shower": "#4FC3F7",
        "housework": "#8D6E63",
        "unconfirmed": "#8D8D8D",
    ]

    static func hex(_ id: String) -> String {
        hexes[id] ?? hexes["activity"] ?? "#5B8C6E"
    }

    static func color(_ id: String) -> Color {
        Color(hex: hex(id))
    }
}

/// 기록 시간표와 바로 아래 범례·아이콘이 함께 쓰는 단일 색상표.
/// 해시 팔레트는 서로 다른 항목이 같은 칸에 충돌할 수 있으므로, 자동 기록과
/// 내장 카테고리는 고정 색을 갖는다.
enum RecordTimelinePalette {
    static let categoryHexes: [String: String] = [
        "calendar": "#52525B", "location": "#0284C7",
        "appUsage": "#0891B2", "weather": "#0EA5E9",
        "photo": "#9333EA", "memo": "#6B7280",
        "project": "#0F766E", "routine": "#CA8A04",
        "relationship": "#DB2777", "rest": "#7E868F",
        "travel": "#EA580C", "health": "#0D9488", "event": "#C026D3",
        "family": "#E11D48", "parenting": "#F97316",
        "finance": "#65A30D", "housing": "#78716C", "career": "#7C3AED",
        "creative": "#BE185D", "pet": "#A16207", "community": "#15803D",
        "student": "#0369A1", "exam": "#B45309", "military": "#3F6212",
        "athlete": "#B91C1C", "pregnancy": "#C2418C",
        "caregiver": "#6D28D9", "government": "#334155", "food": "#C2410C",
    ].merging(CanonicalCategoryPalette.hexes, uniquingKeysWith: { _, canonical in
        canonical
    })

    static let sleepStageHexes: [String: String] = [
        SleepStage.inBed.rawValue: "#8B8D98",
        SleepStage.awake.rawValue: "#D5A300",
        SleepStage.core.rawValue: "#3E63DD",
        SleepStage.deep.rawValue: "#4A3F8F",
        SleepStage.rem.rawValue: "#D6409F",
        SleepStage.asleepUnspecified.rawValue: "#12A594",
    ]

    static let travelHexes: [String: String] = [
        TravelMode.walking.rawValue: "#29A383",
        TravelMode.running.rawValue: "#E54666",
        TravelMode.cycling.rawValue: "#00A2C7",
        TravelMode.bus.rawValue: "#F76B15",
        TravelMode.subway.rawValue: "#8E4EC6",
        TravelMode.taxi.rawValue: "#D5A300",
        TravelMode.car.rawValue: "#3E63DD",
        TravelMode.train.rawValue: "#D6409F",
        TravelMode.airplane.rawValue: "#0C7792",
        TravelMode.ship.rawValue: "#12A594",
    ]

    static let dayPhaseHexes: [String: String] = [
        DayPhase.unconfirmed.rawValue: CanonicalCategoryPalette.hex("unconfirmed"),
        DayPhase.sleep.rawValue: CanonicalCategoryPalette.hex("sleep"),
        DayPhase.movement.rawValue: CanonicalCategoryPalette.hex("movement"),
        DayPhase.exercise.rawValue: CanonicalCategoryPalette.hex("exercise"),
        DayPhase.hobby.rawValue: CanonicalCategoryPalette.hex("hobby"),
        DayPhase.activity.rawValue: CanonicalCategoryPalette.hex("activity"),
        DayPhase.appointment.rawValue: "#8E4EC6",
        DayPhase.commuteToWork.rawValue: "#E8792F",
        DayPhase.commuteToSchool.rawValue: "#0090FF",
        DayPhase.commuteToAcademy.rawValue: "#7C66DC",
        DayPhase.activityDeparture.rawValue: "#46A758",
        DayPhase.work.rawValue: CanonicalCategoryPalette.hex("work"),
        DayPhase.study.rawValue: CanonicalCategoryPalette.hex("study"),
        DayPhase.commuteHomeFromWork.rawValue: "#E54D2E",
        DayPhase.commuteHomeFromSchool.rawValue: "#12A594",
        DayPhase.commuteHomeFromAcademy.rawValue: "#D6409F",
        DayPhase.activityReturn.rawValue: "#56A68A",
        DayPhase.evening.rawValue: "#D5A300",
    ]

    static func categoryColor(_ id: String, fallbackHex: String? = nil) -> Color {
        Color(hex: categoryHexes[id] ?? fallbackHex ?? "#475569")
    }

    static func detailColor(_ kind: RecordClockDetailKind, token: String) -> Color {
        let hex = switch kind {
        case .dayPhase: dayPhaseHexes[token]
        case .sleepStage: sleepStageHexes[token]
        case .travel: travelHexes[token]
        case .weather:
            switch WeatherClockToken.airGrade(token) {
            case .good: "#29A383"
            case .moderate: "#D5A300"
            case .bad: "#F76B15"
            case .veryBad: "#E54666"
            case nil: "#00A2C7"
            }
        case .location: "#0090FF"
        }
        return Color(hex: hex ?? "#475569")
    }
}

extension CategoryIcon {
    var systemImage: String {
        switch self {
        case .briefcase: "briefcase"
        case .building: "building.2"
        case .book: "book"
        case .graduation: "graduationcap"
        case .target: "target"
        case .award: "medal"
        case .stroller: "stroller"
        case .family: "person.2"
        case .shield: "shield"
        case .health: "heart.text.square"
        case .exercise: "dumbbell"
        case .sleep: "moon.zzz"
        case .performance: "theatermasks"
        case .music: "music.note"
        case .travel: "airplane"
        case .location: "mappin.and.ellipse"
        case .photo: "photo"
        case .home: "house"
        case .meal: "fork.knife"
        case .cafe: "cup.and.saucer"
        case .pet: "pawprint"
        case .shopping: "bag"
        case .nature: "leaf"
        case .calendar: "calendar"
        case .event: "sparkles"
        case .memo: "note.text"
        case .movement: "figure.walk.motion"
        case .activity: "figure.run"
        case .relationship: "heart"
        case .work: "desktopcomputer"
        case .community: "person.3"
        case .student: "person.crop.rectangle"
        case .exam: "checkmark.seal"
        case .military: "shield.lefthalf.filled"
        case .athlete: "figure.strengthtraining.traditional"
        case .pregnancy: "figure.and.child.holdinghands"
        case .caregiver: "hands.sparkles"
        case .government: "building.columns"
        case .food: "takeoutbag.and.cup.and.straw"
        }
    }
}

extension PlanCategory {
    var color: Color {
        switch self {
        case .movement: .tpMovement
        case .location: .tpPlace
        case .activity: .tpHealthArea
        case .photo: .tpPhoto
        case .project: .tpProject
        case .exercise: .tpExercise
        case .study: .tpStudy
        case .hobby: .tpHobby
        case .sleep: .tpSleep
        case .routine: .tpRoutine
        case .relationship: .tpRelationship
        case .rest: .tpRest
        case .travel: .tpTravel
        case .health: .tpHealthArea
        case .event: .tpEvent
        }
    }

    var darkColor: Color {
        switch self {
        case .movement: .tpMovementDark
        case .location: .tpPlaceDark
        case .activity: .tpHealthDark
        case .photo: .tpPhotoDark
        case .project: .tpProjectDark
        case .exercise: .tpExerciseDark
        case .study: .tpStudyDark
        case .hobby: .tpHobbyDark
        case .sleep: .tpSleepDark
        case .routine: .tpRoutineDark
        case .relationship: .tpRelationshipDark
        case .rest: .tpRestDark
        case .travel: .tpTravelDark
        case .health: .tpHealthDark
        case .event: .tpEventDark
        }
    }

    var systemImage: String {
        switch self {
        case .movement: "figure.walk"
        case .location: "mappin.and.ellipse"
        case .activity: "figure.run"
        case .photo: "photo"
        case .project: "briefcase"
        case .exercise: "figure.run"
        case .study: "book"
        case .hobby: "paintpalette"
        case .sleep: "moon.zzz"
        case .routine: "house"
        case .relationship: "person.2"
        case .rest: "cup.and.saucer"
        case .travel: "airplane"
        case .health: "heart.text.square"
        case .event: "sparkles"
        }
    }
}

extension View {
    func draftCard(radius: CGFloat = TaptionRadius.card) -> some View {
        self
            .background(
                LinearGradient(
                    colors: [Color.tpSurface, Color.tpSurfaceBlue.opacity(0.58)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.tpLine.opacity(0.72), lineWidth: 0.7)
            }
            .shadow(color: Color.tpSky.opacity(0.16), radius: 4, y: 2)
    }

    /// A lightweight pastel surface for the record and timeline cards. It
    /// avoids material blur so continuous timeline gestures stay on budget.
    func tpCardSurface(
        radius: CGFloat = TaptionRadius.card,
        tint: Color = .tpSurfaceBlue
    ) -> some View {
        self
            .background(
                LinearGradient(
                    colors: [Color.tpSurface, tint.opacity(0.62)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.tpLine.opacity(0.68), lineWidth: 0.7)
            }
    }
}


extension View {
    /// 앱 시트 스타일: 시스템 회색 배경 대신 달력 시트와 같은 크림 배경, 강조색 틴트.
    /// 행 배경은 내용을 `Group { }.listRowBackground(Color.tpSurface)`로 감싸 맞춘다.
    func tpListStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Color.tpBackground)
            .tint(Color.tpAccent)
    }
}

/// 홈 화면 테두리 한 가지 두께(BRD1111A01).
enum TaptionBorder {
    static let width: CGFloat = 1
}
