import SwiftUI
import TaptionPlanCore
import UIKit

/// 여권 한 쪽에 찍히는 방문 한 번(PSP1109A01). 도감의 방문 기록에서 매번 다시 구하고 저장하지 않는다.
struct MapHomePassportVisa: Identifiable, Equatable, Sendable {
    let placeID: String
    let date: Date
    let countryCode: String
    let place: String
    let artworkName: String
    let usesPassportStamp: Bool

    var id: String { "\(placeID)|\(Int(date.timeIntervalSince1970))" }

    /// 장부에서 쪽을 만든다. 오래된 도장부터 앞쪽에 찍힌다.
    static func all(visits: [String: [Date]]) -> [Self] {
        MapHomeKoreaPlaceBookData.places.flatMap { place in
            (visits[place.id] ?? []).map {
                Self(
                    placeID: place.id, date: $0, countryCode: place.countryCode ?? "kr",
                    place: place.stampPlaceName, artworkName: place.artworkName, usesPassportStamp: place.usesPassportStamp
                )
            }
        }
        .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
    }
}

/// 쪽을 칸으로 나누고 칸 안에서 흩뜨린다. 입력이 같으면 언제 열어도 같은 자리다.
enum MapHomePassportLayout {
    static let columns = 2
    static let rows = 3
    static var stampsPerPage: Int { columns * rows }
    static let minimumPages = 8
    private static let jitter = 0.16

    struct Placement: Equatable {
        let x: Double
        let y: Double
        let degrees: Double
        let scale: Double
    }

    static func pages<T>(_ visas: [T]) -> [[T]] {
        let filled = stride(from: 0, to: visas.count, by: stampsPerPage).map {
            Array(visas[$0..<min($0 + stampsPerPage, visas.count)])
        }
        // 빈 쪽이 남아 있어야 더 모으고 싶어진다.
        return filled + Array(repeating: [], count: max(1, minimumPages - filled.count))
    }

    /// 쪽마다 칸 순서를 섞어, 시간순이어도 읽는 순서로 줄지어 보이지 않게 한다.
    static func placement(visaID: String, order: Int, page: Int) -> Placement {
        let cell = shuffledCells(page: page)[order % stampsPerPage]
        var random = Random(seed: hash("\(visaID)#\(page)"))
        let x = (Double(cell % columns) + 0.5 + random.next(in: -jitter...jitter)) / Double(columns)
        let y = (Double(cell / columns) + 0.5 + random.next(in: -jitter...jitter)) / Double(rows)
        return Placement(x: x, y: y, degrees: random.next(in: -18...18), scale: random.next(in: 0.92...1.12))
    }

    private static func shuffledCells(page: Int) -> [Int] {
        var cells = Array(0..<stampsPerPage)
        var random = Random(seed: hash("page-\(page)"))
        for index in cells.indices.dropLast() {
            let other = index + Int(random.next(in: 0...0.999_999) * Double(cells.count - index))
            cells.swapAt(index, other)
        }
        return cells
    }

    /// `Hasher`는 실행마다 값이 달라 쓰지 않는다.
    private static func hash(_ text: String) -> UInt64 {
        text.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }

    private struct Random {
        var seed: UInt64

        mutating func next(in range: ClosedRange<Double>) -> Double {
            seed &+= 0x9e37_79b9_7f4a_7c15
            var value = seed
            value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
            value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
            value ^= value >> 31
            return range.lowerBound + Double(value >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
        }
    }
}

/// 앱 언어별 여권 색과 글자. 색은 그 나라 여권을 따르되, 나라 이름·정부 문구는 쓰지 않고 앱 이름과
/// 「여행 여권」만 적는다. 공문서를 흉내 낸 것으로 보이지 않게 한다(REV1110A03).
struct MapHomePassportDesign: Equatable {
    let coverHex: String
    let top: [String]
    let bottom: [String]
    let pageHex: String
    let patternHex: String
    let visaTitle: String

    static func design(languageCode: String) -> Self {
        table[languageCode] ?? table[String(languageCode.prefix(2))] ?? table["en"]!
    }

    static func current(language: MapHomeLanguage) -> Self {
        design(languageCode: language == .korean ? "ko" : UITextPack.activeLanguageCode ?? "en")
    }

    static let languageCodes = ["ko", "en", "ja", "zh-Hans", "zh-Hant", "es", "fr", "de", "it", "pt-BR", "hi", "th", "vi", "id"]

    private static let navy = "#1B2A57", burgundy = "#6A1B2C", green = "#1E4A3C"
    private static let table: [String: Self] = [
        "ko": .init(coverHex: "#1A2B5E", top: [], bottom: ["보키 여행 여권", "BOKKI PLAN", "TRAVEL PASSPORT"], pageHex: "#F2F1E6", patternHex: "#6FA8A0", visaTitle: "사증 VISAS"),
        "en": .init(coverHex: navy, top: ["TRAVEL PASSPORT"], bottom: ["BOKKI PLAN"], pageHex: "#F3F0E4", patternHex: "#7E93B8", visaTitle: "VISAS"),
        "ja": .init(coverHex: burgundy, top: ["BOKKI PLAN"], bottom: ["旅のパスポート", "TRAVEL PASSPORT"], pageHex: "#F5EEE6", patternHex: "#C79AA6", visaTitle: "査証 VISAS"),
        "zh-Hans": .init(coverHex: "#7A1C26", top: ["BOKKI PLAN"], bottom: ["旅行护照", "TRAVEL PASSPORT"], pageHex: "#F6EFE3", patternHex: "#CF9B8E", visaTitle: "签证 VISAS"),
        "zh-Hant": .init(coverHex: green, top: ["BOKKI PLAN"], bottom: ["旅行護照", "TRAVEL PASSPORT"], pageHex: "#EEF1E4", patternHex: "#8DB39B", visaTitle: "簽證 VISAS"),
        "es": .init(coverHex: burgundy, top: ["BOKKI PLAN"], bottom: ["PASAPORTE DE VIAJE"], pageHex: "#F4EDE4", patternHex: "#C9A08C", visaTitle: "VISADOS"),
        "fr": .init(coverHex: burgundy, top: ["BOKKI PLAN"], bottom: ["PASSEPORT DE VOYAGE"], pageHex: "#F1EEE9", patternHex: "#9AA6C7", visaTitle: "VISAS"),
        "de": .init(coverHex: burgundy, top: ["BOKKI PLAN"], bottom: ["REISEPASS"], pageHex: "#F3EEE2", patternHex: "#BBA57E", visaTitle: "VISA"),
        "it": .init(coverHex: burgundy, top: ["BOKKI PLAN"], bottom: ["PASSAPORTO DI VIAGGIO"], pageHex: "#F0F0E4", patternHex: "#9FB893", visaTitle: "VISTI"),
        "pt": .init(coverHex: "#12305A", top: ["BOKKI PLAN"], bottom: ["PASSAPORTE DE VIAGEM"], pageHex: "#EFF1E3", patternHex: "#8FB58A", visaTitle: "VISTOS"),
        "hi": .init(coverHex: navy, top: ["BOKKI PLAN"], bottom: ["यात्रा पासपोर्ट", "TRAVEL PASSPORT"], pageHex: "#F4EFE2", patternHex: "#C9A673", visaTitle: "वीज़ा VISAS"),
        "th": .init(coverHex: "#5E1A2B", top: ["BOKKI PLAN"], bottom: ["หนังสือเดินทางท่องเที่ยว", "TRAVEL PASSPORT"], pageHex: "#F3EFE6", patternHex: "#A99BC7", visaTitle: "วีซ่า VISAS"),
        "vi": .init(coverHex: "#1E2C52", top: ["BOKKI PLAN"], bottom: ["HỘ CHIẾU DU LỊCH", "TRAVEL PASSPORT"], pageHex: "#F4EEE1", patternHex: "#CDA184", visaTitle: "THỊ THỰC VISAS"),
        "id": .init(coverHex: "#1C5044", top: ["BOKKI PLAN"], bottom: ["PASPOR PERJALANAN", "TRAVEL PASSPORT"], pageHex: "#EFF1E6", patternHex: "#8FB6A6", visaTitle: "VISA"),
    ]
}

private let passportGold = LinearGradient(
    stops: [
        .init(color: Color(hex: "#F7E7AE"), location: 0),
        .init(color: Color(hex: "#CFA94F"), location: 0.42),
        .init(color: Color(hex: "#94702A"), location: 0.62),
        .init(color: Color(hex: "#EBD48B"), location: 1),
    ],
    startPoint: .topLeading, endPoint: .bottomTrailing
)

/// 화랑이 얼굴 도면. `HwarangPainter.head`의 정면 좌표를 그대로 쓴다.
private enum MapHomeHwarangFace {
    static let width: CGFloat = 56
    static let height: CGFloat = 46
    private static let centerY: CGFloat = -3

    static func placed(_ path: Path, in rect: CGRect) -> Path {
        let scale = min(rect.width / width, rect.height / height)
        return path.applying(
            CGAffineTransform(translationX: rect.midX, y: rect.midY - centerY * scale).scaledBy(x: scale, y: scale)
        )
    }

    static let head: Path = {
        var path = Path()
        path.move(to: CGPoint(x: -20, y: 3))
        path.addCurve(to: CGPoint(x: 0, y: -15), control1: CGPoint(x: -20, y: -11), control2: CGPoint(x: -10, y: -15))
        path.addCurve(to: CGPoint(x: 20, y: 3), control1: CGPoint(x: 10, y: -15), control2: CGPoint(x: 20, y: -11))
        path.addQuadCurve(to: CGPoint(x: 20.2, y: 8), control: CGPoint(x: 22.5, y: 6))
        path.addQuadCurve(to: CGPoint(x: 18, y: 10.4), control: CGPoint(x: 21, y: 10.5))
        path.addCurve(to: CGPoint(x: 0, y: 15), control1: CGPoint(x: 13, y: 14.5), control2: CGPoint(x: 6, y: 15))
        path.addCurve(to: CGPoint(x: -18, y: 10.4), control1: CGPoint(x: -6, y: 15), control2: CGPoint(x: -13, y: 14.5))
        path.addQuadCurve(to: CGPoint(x: -20.2, y: 8), control: CGPoint(x: -21, y: 10.5))
        path.addQuadCurve(to: CGPoint(x: -20, y: 3), control: CGPoint(x: -22.5, y: 6))
        path.closeSubpath()
        return path
    }()

    private static func ear(side: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: -6.5, y: 4))
        path.addQuadCurve(to: CGPoint(x: 0, y: -8.6), control: CGPoint(x: -4.5, y: -8))
        path.addQuadCurve(to: CGPoint(x: 6.5, y: 4), control: CGPoint(x: 4.5, y: -8))
        path.move(to: CGPoint(x: -3.4, y: 2.6))
        path.addQuadCurve(to: CGPoint(x: 0, y: -5.2), control: CGPoint(x: -2.4, y: -4.8))
        path.addQuadCurve(to: CGPoint(x: 3.4, y: 2.6), control: CGPoint(x: 2.4, y: -4.8))
        let placed = path.applying(CGAffineTransform(translationX: side * 13, y: -10).rotated(by: side * 0.34))
        return Path(placed.cgPath.lineSubtracting(head.cgPath))
    }

    /// 선으로 긋는 부분: 머리·귀·이마 털·입·수염·눈 테두리.
    static let lines: Path = {
        var path = head
        path.addPath(ear(side: -1))
        path.addPath(ear(side: 1))
        for x: CGFloat in [-1.8, 1.8] {
            path.move(to: CGPoint(x: x, y: -14))
            path.addLine(to: CGPoint(x: x, y: -10.5))
        }
        path.move(to: CGPoint(x: -2.4, y: 8.2))
        path.addQuadCurve(to: CGPoint(x: 0, y: 8.2), control: CGPoint(x: -1.2, y: 9.8))
        path.addQuadCurve(to: CGPoint(x: 2.4, y: 8.2), control: CGPoint(x: 1.2, y: 9.8))
        for side: CGFloat in [-1, 1] {
            path.move(to: CGPoint(x: side * 19, y: 5.4))
            path.addLine(to: CGPoint(x: side * 24, y: 4.6))
            path.move(to: CGPoint(x: side * 19, y: 7.6))
            path.addLine(to: CGPoint(x: side * 24, y: 8.2))
            // 눈동자 없이 웃는 눈(대표 지시). `Eye.happy` 좌표다.
            path.move(to: CGPoint(x: side * 10.2 - 4.6, y: 4.6))
            path.addQuadCurve(to: CGPoint(x: side * 10.2 + 4.6, y: 4.6), control: CGPoint(x: side * 10.2, y: -1.2))
        }
        return path
    }()

    /// 면으로 채우는 부분: 코.
    static let solids: Path = {
        var path = Path()
        path.move(to: CGPoint(x: -1.3, y: 6.2))
        path.addQuadCurve(to: CGPoint(x: 1.3, y: 6.2), control: CGPoint(x: 0, y: 5.7))
        path.addQuadCurve(to: CGPoint(x: 0, y: 7.7), control: CGPoint(x: 0.6, y: 7.7))
        path.addQuadCurve(to: CGPoint(x: -1.3, y: 6.2), control: CGPoint(x: -0.6, y: 7.7))
        return path
    }()
}

private struct MapHomeHwarangFaceLines: Shape {
    func path(in rect: CGRect) -> Path { MapHomeHwarangFace.placed(MapHomeHwarangFace.lines, in: rect) }
}

private struct MapHomeHwarangFaceSolids: Shape {
    func path(in rect: CGRect) -> Path { MapHomeHwarangFace.placed(MapHomeHwarangFace.solids, in: rect) }
}

/// 나라 국장 자리에 넣는 화랑이 금박 문장(대표 결정).
struct MapHomeHwarangCrest<Fill: ShapeStyle>: View {
    let side: CGFloat
    let fill: Fill

    var body: some View {
        ZStack {
            Circle().stroke(fill, lineWidth: side * 0.018)
            Circle().stroke(fill, style: StrokeStyle(lineWidth: side * 0.022, lineCap: .round, dash: [0.1, side * 0.05]))
                .padding(side * 0.05)
            ForEach(Self.leafAngles, id: \.self) { angle in
                Capsule().fill(fill)
                    .frame(width: side * 0.032, height: side * 0.1)
                    .rotationEffect(.degrees(angle > 180 ? 28 : -28))
                    .offset(y: -side * 0.35)
                    .rotationEffect(.degrees(angle))
            }
            Group {
                MapHomeHwarangFaceLines()
                    .stroke(fill, style: StrokeStyle(lineWidth: side * 0.016, lineCap: .round, lineJoin: .round))
                MapHomeHwarangFaceSolids().fill(fill)
            }
            .frame(width: side * 0.6, height: side * 0.6 * MapHomeHwarangFace.height / MapHomeHwarangFace.width)
        }
        .frame(width: side, height: side)
    }

    /// 아래가 벌어진 월계관. 머리 위쪽은 비운다.
    private static var leafAngles: [Double] {
        stride(from: 62.0, through: 166, by: 13).flatMap { [$0, 360 - $0] }
    }
}

/// 전자여권 표지 아래의 표시.
private struct MapHomePassportChipMark<Fill: ShapeStyle>: View {
    let width: CGFloat
    let fill: Fill

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: width * 0.08).stroke(fill, lineWidth: width * 0.06)
            Circle().stroke(fill, lineWidth: width * 0.06).frame(width: width * 0.3)
            Rectangle().fill(fill).frame(height: width * 0.05)
        }
        .frame(width: width, height: width * 0.62)
    }
}

struct MapHomePassportCover: View {
    let design: MapHomePassportDesign

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack {
                Color(hex: design.coverHex)
                Canvas { context, size in
                    var random = SystemRandomStable(seed: 11)
                    for _ in 0..<1_800 {
                        let rect = CGRect(x: random.next() * size.width, y: random.next() * size.height, width: 1, height: 1)
                        context.fill(Path(rect), with: .color(.white.opacity(random.next() * 0.07)))
                    }
                }
                LinearGradient(colors: [.white.opacity(0.13), .clear, .black.opacity(0.28)], startPoint: .topLeading, endPoint: .bottomTrailing)
                // 책등 쪽 접힘.
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.42), .white.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: width * 0.075)
                    Spacer(minLength: 0)
                }
                VStack(spacing: width * 0.022) {
                    lines(design.top, width: width)
                    Spacer(minLength: 0)
                    MapHomeHwarangCrest(side: width * 0.54, fill: passportGold)
                    Spacer(minLength: 0)
                    lines(design.bottom, width: width)
                    MapHomePassportChipMark(width: width * 0.11, fill: passportGold)
                        .padding(.top, width * 0.03)
                }
                .padding(.vertical, width * 0.11)
                .padding(.leading, width * 0.13)
                .padding(.trailing, width * 0.08)
            }
        }
    }

    /// 첫 줄이 가장 크고, 다음 줄은 작은 영문 표기다.
    private func lines(_ lines: [String], width: CGFloat) -> some View {
        VStack(spacing: width * 0.016) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(verbatim: line)
                    .font(.system(size: width * (index == 0 ? 0.088 : 0.05), weight: .semibold, design: .serif))
                    .tracking(width * (index == 0 ? 0.008 : 0.006))
                    .foregroundStyle(passportGold)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
            }
        }
    }
}

/// 값이 항상 같은 표지 결·종이 결용 수열.
private struct SystemRandomStable {
    var seed: UInt64

    mutating func next() -> CGFloat {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat((seed >> 33) & 0xFFFF) / 0xFFFF
    }
}

/// 은은한 보안 무늬. 실제 속지처럼 잔선이 물결치며 겹친다.
private struct MapHomePassportGuilloche: View {
    let hex: String

    var body: some View {
        Canvas { context, size in
            let color = Color(hex: hex)
            for row in 0..<34 {
                let base = size.height * CGFloat(row) / 33
                for phase in [0.0, 1.9] {
                    var path = Path()
                    for step in stride(from: 0, through: size.width, by: 4) {
                        let wave = sin(step / size.width * .pi * 5 + CGFloat(row) * 0.42 + phase) * size.height * 0.018
                        let point = CGPoint(x: step, y: base + wave)
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(color.opacity(0.22)), lineWidth: 0.5)
                }
            }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = size.width * 0.42
            var rosette = Path()
            for step in 0...720 {
                let angle = CGFloat(step) / 720 * .pi * 2
                let length = radius * (0.72 + 0.28 * sin(angle * 18))
                let point = CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length)
                if step == 0 { rosette.move(to: point) } else { rosette.addLine(to: point) }
            }
            context.stroke(rosette, with: .color(color.opacity(0.3)), lineWidth: 0.6)
        }
    }
}

struct MapHomePassportPage: View {
    let design: MapHomePassportDesign
    let language: MapHomeLanguage
    let visas: [MapHomePassportVisa]
    let pageIndex: Int
    /// 도장을 누르면 그 날짜 기록으로 간다.
    var onSelect: (Date) -> Void = { _ in }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // 좌우를 넉넉히 비워 도장 글자가 쪽 밖으로 잘리지 않게 한다.
            let area = CGRect(x: size.width * 0.09, y: size.height * 0.07, width: size.width * 0.82, height: size.height * 0.86)
            ZStack {
                Color(hex: design.pageHex)
                MapHomePassportGuilloche(hex: design.patternHex)
                pageIcon(size: size)
                LinearGradient(colors: [.black.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: size.width * 0.07)
                    .frame(maxWidth: .infinity, alignment: .leading)
                pageMarks(size: size)
                ForEach(Array(visas.enumerated()), id: \.element.id) { order, visa in
                    let place = MapHomePassportLayout.placement(visaID: visa.id, order: order, page: pageIndex)
                    Button { onSelect(visa.date) } label: { stamp(visa, size: size.width * 0.3 * place.scale) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: visa.date.formatted(date: .long, time: .omitted)))
                        .rotationEffect(.degrees(place.degrees))
                        .position(x: area.minX + place.x * area.width, y: area.minY + place.y * area.height)
                }
            }
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(language.text("도장 \(visas.count)개", "\(visas.count) stamps"))
    }

    /// 쪽을 넘길 때마다 화랑이 아이콘이 순서대로 바뀐다(대표 지시).
    private func pageIcon(size: CGSize) -> some View {
        let scene = HwarangScene.allCases[pageIndex % HwarangScene.allCases.count]
        return HwarangSceneView(
            scene: scene, sec: Double(scene.totalDuration) * 0.4,
            width: size.width * 0.82, anchorHeight: size.width * 0.62, showsBackdrop: false
        )
        .saturation(0)
        .colorMultiply(Color(hex: design.patternHex))
        .opacity(0.42)
        .frame(width: size.width * 0.82, height: size.width * 0.82)
    }

    private func pageMarks(size: CGSize) -> some View {
        VStack {
            Text(verbatim: design.visaTitle)
                .font(.system(size: size.width * 0.035, weight: .medium, design: .serif))
                .tracking(size.width * 0.008)
            Spacer()
            Text(verbatim: "\(pageIndex + 1)")
                .font(.system(size: size.width * 0.04, weight: .medium, design: .serif))
        }
        .foregroundStyle(Color(hex: design.patternHex).opacity(0.95))
        .padding(.vertical, size.width * 0.04)
    }

    @ViewBuilder
    private func stamp(_ visa: MapHomePassportVisa, size: CGFloat) -> some View {
        if visa.usesPassportStamp {
            MapHomePassportStamp(visitDate: visa.date, countryCode: visa.countryCode, place: visa.place, size: size)
        } else {
            MapHomePassportPlaceStamp(artworkName: visa.artworkName, date: visa.date, size: size)
        }
    }
}

/// 국내 명소 도장. 글자 대신 도감 그림을 찍고 아래에 날짜를 적는다(대표 지시).
private struct MapHomePassportPlaceStamp: View {
    let artworkName: String
    let date: Date
    let size: CGFloat

    var body: some View {
        let ink = Color(hex: MapHomeInkWash.sealHex)
        ZStack {
            Circle().stroke(ink, lineWidth: size * 0.035)
            Circle().stroke(ink, lineWidth: size * 0.012).padding(size * 0.05)
            Image(artworkName)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.62, height: size * 0.56)
                .offset(y: -size * 0.09)
            Text(verbatim: MapHomePassportStampStyle.dateText(date))
                .font(.system(size: size * 0.095, weight: .heavy, design: .monospaced))
                .foregroundStyle(ink)
                .offset(y: size * 0.3)
        }
        .frame(width: size, height: size)
    }
}

/// 책장을 말아 넘긴다. 첫 쪽이 표지다.
private struct MapHomePassportPageCurl: UIViewControllerRepresentable {
    let pageCount: Int
    var initialPage = 0
    /// 바뀌면 지금 보는 쪽을 새 내용으로 다시 그린다.
    var revision = 0
    let page: (Int) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        controller.isDoubleSided = false
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        context.coordinator.controller = controller
        controller.view.backgroundColor = .clear
        // 쪽 가장자리를 눌러도 넘어가면 도장을 누를 수 없다. 넘기기는 밀어서만 한다.
        controller.gestureRecognizers.filter { $0 is UITapGestureRecognizer }.forEach { $0.isEnabled = false }
        controller.setViewControllers([context.coordinator.controller(at: min(initialPage, pageCount - 1))], direction: .forward, animated: false)
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refreshIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: MapHomePassportPageCurl
        weak var controller: UIPageViewController?
        private var drawnRevision: Int
        private var isTurning = false
        /// 처음 열 때 아직 쪽이 모자라 가지 못한 쪽. 장부가 와서 쪽이 늘면 그리로 간다(REV1110A02).
        private var pendingPage: Int?

        init(parent: MapHomePassportPageCurl) {
            self.parent = parent
            drawnRevision = parent.revision
            pendingPage = parent.initialPage >= parent.pageCount ? parent.initialPage : nil
        }

        /// 넘기는 도중에 바꾸면 UIKit 상태가 어긋나므로 끝난 뒤에 한다.
        func refreshIfNeeded() {
            guard !isTurning, drawnRevision != parent.revision, let controller,
                  let current = controller.viewControllers?.first else { return }
            drawnRevision = parent.revision
            var index = min(current.view.tag, parent.pageCount - 1)
            if let pendingPage, pendingPage < parent.pageCount {
                index = pendingPage
                self.pendingPage = nil
            }
            controller.setViewControllers([self.controller(at: index)], direction: .forward, animated: false)
        }

        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            isTurning = true
            // 사용자가 직접 넘기기 시작하면 예약한 쪽으로 끌고 가지 않는다.
            pendingPage = nil
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            isTurning = false
            refreshIfNeeded()
        }

        func controller(at index: Int) -> UIViewController {
            let controller = UIHostingController(rootView: parent.page(index))
            controller.view.tag = index
            controller.view.backgroundColor = .clear
            return controller
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            let index = viewController.view.tag
            return index > 0 ? controller(at: index - 1) : nil
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            let index = viewController.view.tag
            return index + 1 < parent.pageCount ? controller(at: index + 1) : nil
        }
    }
}

/// 장소 도감 아래의 여권(PSP1109A01).
struct MapHomePassportSheet: View {
    let source: MapHomeVisitSource
    let language: MapHomeLanguage
    var initialPage = 0
    /// 누른 도장의 날짜와 지금 쪽 번호(표지가 0).
    var onSelectDay: (Date, Int) -> Void = { _, _ in }

    /// 표지는 자료를 기다리지 않는다. 빈 쪽으로 먼저 열고 장부가 오면 채운다.
    @State private var pages = MapHomePassportLayout.pages([MapHomePassportVisa]())
    @State private var revision = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width - 40, (proxy.size.height - 110) * 88 / 125)
            ZStack {
                book(pages, width: width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            RadialGradient(colors: [Color(hex: "#4A3A2C"), Color(hex: "#1E1712")], center: .center, startRadius: 40, endRadius: 520)
                .ignoresSafeArea()
        )
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").foregroundStyle(.white).frame(width: 44, height: 44)
            }
            .accessibilityLabel(language.text("닫기", "Close"))
            .padding(.trailing, 8)
        }
        .task {
            let tests = MapHomePlaceBookTestMode.visits
            func show(_ visits: [String: [Date]]) {
                let next = MapHomePassportLayout.pages(MapHomePassportVisa.all(visits: MapHomeVisitLedger.merged(visits, extra: tests)))
                guard next != pages else { return }
                pages = next
                revision += 1
            }
            show(await source.cached())
            show(await source.refreshed())
        }
    }

    private func book(_ pages: [[MapHomePassportVisa]], width: CGFloat) -> some View {
        let design = MapHomePassportDesign.current(language: language)
        return VStack(spacing: 14) {
            MapHomePassportPageCurl(pageCount: pages.count + 1, initialPage: initialPage, revision: revision) { index in
                index == 0
                    ? AnyView(MapHomePassportCover(design: design))
                    : AnyView(MapHomePassportPage(design: design, language: language, visas: pages[index - 1], pageIndex: index - 1) { onSelectDay($0, index) })
            }
            .frame(width: width, height: width * 125 / 88)
            .clipShape(RoundedRectangle(cornerRadius: width * 0.04, style: .continuous))
            .shadow(color: .black.opacity(0.55), radius: 18, y: 12)
            Text(language.text("옆으로 넘겨 보세요", "Swipe to turn the page"))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

#if DEBUG
/// `-passportBook`: 시험 방문으로 도장 누르기를 확인한다(Debug 전용).
struct MapHomePassportTapPreviewHost: View {
    @State private var tapped = "-"

    init() {
        MapHomeKoreaPlaceBookData.places.prefix(6).forEach { MapHomePlaceBookTestMode.addVisit($0.id) }
    }

    var body: some View {
        MapHomePassportSheet(source: .fixed(stays: []), language: .korean, onSelectDay: { day, page in tapped = "\(page) \(day.formatted(date: .numeric, time: .omitted))" })
            .overlay(alignment: .bottom) { Text(verbatim: tapped).foregroundStyle(.white).padding(.bottom, 40) }
    }
}

/// `-passportPreview`로 여는 표지·속지 견본(Debug 전용).
struct MapHomePassportPreviewHost: View {
    private let visas: [MapHomePassportVisa] = MapHomeKoreaPlaceBookData.places
        .enumerated()
        .filter { $0.offset % 37 == 0 }
        .prefix(6)
        .enumerated()
        .map { index, item in
            MapHomePassportVisa(
                placeID: item.element.id, date: Date(timeIntervalSince1970: 1_750_000_000 + Double(index) * 864_000),
                countryCode: index % 2 == 0 ? "jp" : "de", place: item.element.stampPlaceName,
                artworkName: item.element.artworkName, usesPassportStamp: index != 4
            )
        }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)

    var body: some View {
        ScrollView {
            MapHomePassportPage(design: .design(languageCode: "ko"), language: .korean, visas: visas, pageIndex: 0)
                .frame(width: 320, height: 320 * 125 / 88)
            HStack(spacing: 6) {
                ForEach(1..<5, id: \.self) { page in
                    MapHomePassportPage(design: .design(languageCode: "ko"), language: .korean, visas: [], pageIndex: page)
                        .aspectRatio(88 / 125, contentMode: .fit)
                }
            }
            .padding(.horizontal, 8)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(MapHomePassportDesign.languageCodes, id: \.self) { code in
                    MapHomePassportCover(design: .design(languageCode: code))
                        .aspectRatio(88 / 125, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(8)
        }
        .background(Color.black)
    }
}
#endif
