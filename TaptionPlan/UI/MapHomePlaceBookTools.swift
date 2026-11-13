import CoreImage.CIFilterBuiltins
import MapKit
import SwiftUI
import TaptionPlanCore

/// 도감 시험 모드(PLB1109A03). 제목을 다섯 번 누르면 켜진다. 앱을 끄면 사라지고 기록에는 저장하지 않는다.
@MainActor
enum MapHomePlaceBookTestMode {
    static var isEnabled = false
    static var visits: [String: [Date]] = [:]

    /// 누를 때마다 하루씩 다른 날의 방문을 더해 도장이 쌓이는 모습을 본다.
    static func addVisit(_ id: String, now: Date = .now) {
        let count = visits[id, default: []].count
        visits[id, default: []].append(now.addingTimeInterval(Double(-count) * 86_400))
    }
}

/// 나라별 입국 도장의 외곽 모양과 잉크 색(이미지 검색 사진을 보고 정함, 대표 지시 2026-11-09).
/// 국장·기관명·실제 문구는 쓰지 않는다. 자료가 없는 나라는 기본값을 쓴다.
struct MapHomePassportStampStyle: Equatable {
    enum Shape: Equatable { case rectangle, roundedRectangle, circle, oval, hexagon, octagon, triangle, pointedEnds, notched }
    enum Border: Equatable { case single, double, thickThin, dotted, ticks, beaded }
    /// 도장 안의 칸막이 줄.
    enum Rule: Equatable { case none, topBand, bands, sideBars, leftColumn }
    enum Mark: Equatable { case plane, arrow }

    let shape: Shape
    let colorHex: String
    var border = Border.single
    var rule = Rule.none
    var mark = Mark.plane

    static let standard = MapHomePassportStampStyle(shape: .circle, colorHex: "#2F5D8A")

    /// 입국 스티커·종이 쪽지를 쓰는 나라의 종이 색. nil이면 잉크 도장이다.
    var paperHex: String?
    /// 틀과 다른 날짜 잉크.
    var dateHex: String?
    /// 나라 이름 양옆의 별.
    var hasStars = false
    /// 날짜를 감싼 칸.
    var hasDateBox = false
    /// 양옆 세로 글자(공항·나라 코드 자리).
    var hasSideCodes = false
    /// 솅겐형: 왼쪽 위 코드 원, 오른쪽 위 비행기 칸, 왼쪽 아래 화살표 칸.
    var entryCode: String?
    /// 일본 입국 스티커의 산 그림.
    var hasMountain = false

    var inkColor: Color { Color(hex: colorHex) }
    var dateColor: Color { dateHex.map { Color(hex: $0) } ?? inkColor }

    /// 도장에 찍는 영어 나라 이름. 공식 기관명은 쓰지 않는다.
    static func countryLabel(_ code: String) -> String {
        switch code.lowercased() {
        case "kr": return "KOREA"
        case "us": return "USA"
        case "gb": return "UK"
        case "ae": return "UAE"
        case "hk": return "HONG KONG"
        case "mo": return "MACAU"
        case "tw": return "TAIWAN"
        case "cz": return "CZECHIA"
        case "cn": return "CHINA"
        case "mm": return "MYANMAR"
        case "tr": return "TURKEY"
        case "gu": return "GUAM"
        case "mp": return "SAIPAN"
        default:
            return (Locale(identifier: "en_US_POSIX").localizedString(forRegionCode: code.uppercased()) ?? code).uppercased()
        }
    }

    static func style(forCountry code: String) -> MapHomePassportStampStyle { table[code.lowercased()] ?? standard }

    private static let table: [String: MapHomePassportStampStyle] = [
        "ae": .init(shape: .oval, colorHex: "#2D4FA0", border: .double, rule: .sideBars, mark: .plane),
        "at": .init(shape: .roundedRectangle, colorHex: "#2B2B2B", border: .single, rule: .none, mark: .arrow, dateHex: "#C0453F", entryCode: "A"),
        "au": .init(shape: .octagon, colorHex: "#3A3A3A", border: .thickThin, rule: .none, mark: .plane),
        "bd": .init(shape: .rectangle, colorHex: "#333333", border: .double, rule: .none, mark: .arrow, dateHex: "#C0453F", hasDateBox: true),
        "ca": .init(shape: .oval, colorHex: "#4A6F9A", border: .double, rule: .none, mark: .plane),
        "ch": .init(shape: .roundedRectangle, colorHex: "#2B2B2B", border: .single, rule: .none, mark: .arrow, dateHex: "#C0453F", entryCode: "CH"),
        "cn": .init(shape: .oval, colorHex: "#B23A35", border: .thickThin, rule: .none, mark: .plane),
        "cz": .init(shape: .roundedRectangle, colorHex: "#2B2B2B", border: .single, rule: .none, mark: .arrow, dateHex: "#C0453F", entryCode: "CZ"),
        "de": .init(shape: .roundedRectangle, colorHex: "#2B2B2B", border: .single, rule: .none, mark: .arrow, dateHex: "#C0453F", entryCode: "D"),
        "es": .init(shape: .roundedRectangle, colorHex: "#2B2B2B", border: .single, rule: .none, mark: .arrow, dateHex: "#C0453F", entryCode: "E"),
        "et": .init(shape: .oval, colorHex: "#3D6FA0", border: .dotted, rule: .none, mark: .plane),
        "fi": .init(shape: .roundedRectangle, colorHex: "#2B2B2B", border: .single, rule: .none, mark: .arrow, dateHex: "#C0453F", entryCode: "FIN"),
        "fr": .init(shape: .roundedRectangle, colorHex: "#2B2B2B", border: .single, rule: .none, mark: .arrow, dateHex: "#C0453F", entryCode: "F"),
        "gb": .init(shape: .notched, colorHex: "#333333", border: .single, rule: .topBand, mark: .plane, hasStars: true),
        "gr": .init(shape: .roundedRectangle, colorHex: "#2B2B2B", border: .single, rule: .none, mark: .arrow, dateHex: "#C0453F", entryCode: "GR"),
        "gu": .init(shape: .oval, colorHex: "#3F5FA8", border: .dotted, rule: .none, mark: .plane, dateHex: "#C0453F"),
        "hk": .init(shape: .rectangle, colorHex: "#3F8FA8", border: .single, rule: .none, mark: .plane, paperHex: "#FFFFFF"),
        "hu": .init(shape: .roundedRectangle, colorHex: "#2B2B2B", border: .single, rule: .none, mark: .arrow, dateHex: "#C0453F", entryCode: "H"),
        "id": .init(shape: .triangle, colorHex: "#3D8F73", border: .thickThin, rule: .none, mark: .plane),
        "il": .init(shape: .rectangle, colorHex: "#3E7FA8", border: .single, rule: .none, mark: .plane, paperHex: "#CFE3EE"),
        "in": .init(shape: .oval, colorHex: "#4A4FA0", border: .beaded, rule: .none, mark: .plane, dateHex: "#C0453F"),
        "it": .init(shape: .roundedRectangle, colorHex: "#2B2B2B", border: .single, rule: .none, mark: .arrow, dateHex: "#C0453F", entryCode: "I"),
        "jp": .init(shape: .rectangle, colorHex: "#3F8FA8", border: .single, rule: .none, mark: .plane, paperHex: "#DCEBF0", hasMountain: true),
        "kh": .init(shape: .roundedRectangle, colorHex: "#3457A0", border: .double, rule: .none, mark: .plane, dateHex: "#C0453F"),
        "kr": .init(shape: .circle, colorHex: "#2F7A8F", border: .thickThin, rule: .none, mark: .plane),
        "kz": .init(shape: .rectangle, colorHex: "#B6404A", border: .single, rule: .bands, mark: .arrow),
        "la": .init(shape: .roundedRectangle, colorHex: "#C0453F", border: .single, rule: .none, mark: .plane, dateHex: "#32508F", hasStars: true),
        "mm": .init(shape: .rectangle, colorHex: "#32508F", border: .double, rule: .none, mark: .plane),
        "mn": .init(shape: .pointedEnds, colorHex: "#2F8F6B", border: .single, rule: .none, mark: .plane),
        "mo": .init(shape: .rectangle, colorHex: "#6FA36A", border: .single, rule: .none, mark: .plane, paperHex: "#DDEBC8"),
        "mp": .init(shape: .oval, colorHex: "#3F5FA8", border: .dotted, rule: .none, mark: .plane, dateHex: "#C0453F"),
        "mx": .init(shape: .rectangle, colorHex: "#3B9A5A", border: .single, rule: .bands, mark: .plane),
        "my": .init(shape: .rectangle, colorHex: "#3F3F9E", border: .single, rule: .topBand, mark: .arrow),
        "nl": .init(shape: .roundedRectangle, colorHex: "#2B2B2B", border: .single, rule: .none, mark: .arrow, dateHex: "#C0453F", entryCode: "NL"),
        "no": .init(shape: .roundedRectangle, colorHex: "#2B2B2B", border: .single, rule: .none, mark: .arrow, dateHex: "#C0453F", entryCode: "N"),
        "np": .init(shape: .rectangle, colorHex: "#4560A8", border: .single, rule: .topBand, mark: .plane, dateHex: "#C0453F"),
        "nz": .init(shape: .rectangle, colorHex: "#333333", border: .single, rule: .topBand, mark: .plane, hasSideCodes: true),
        "ph": .init(shape: .rectangle, colorHex: "#3E8E6E", border: .single, rule: .none, mark: .plane, hasDateBox: true),
        "pl": .init(shape: .roundedRectangle, colorHex: "#2B2B2B", border: .single, rule: .none, mark: .arrow, dateHex: "#C0453F", entryCode: "PL"),
        "pt": .init(shape: .roundedRectangle, colorHex: "#2B2B2B", border: .single, rule: .none, mark: .arrow, dateHex: "#C0453F", entryCode: "P"),
        "qa": .init(shape: .roundedRectangle, colorHex: "#2E4F9E", border: .double, rule: .sideBars, mark: .plane),
        "sg": .init(shape: .octagon, colorHex: "#333333", border: .ticks, rule: .none, mark: .plane),
        "th": .init(shape: .rectangle, colorHex: "#B8404A", border: .double, rule: .topBand, mark: .plane),
        "tr": .init(shape: .roundedRectangle, colorHex: "#333333", border: .single, rule: .none, mark: .arrow, entryCode: "TR"),
        "tw": .init(shape: .octagon, colorHex: "#3A5FA0", border: .dotted, rule: .none, mark: .plane),
        "us": .init(shape: .oval, colorHex: "#3F5FA8", border: .dotted, rule: .none, mark: .plane, dateHex: "#C0453F"),
        "uz": .init(shape: .rectangle, colorHex: "#3B8E70", border: .single, rule: .bands, mark: .arrow),
        "vn": .init(shape: .rectangle, colorHex: "#3B4A9C", border: .single, rule: .topBand, mark: .arrow, hasDateBox: true, hasSideCodes: true),
    ]


    /// 도장의 일련번호 느낌만 내는 숫자. 날짜와 나라로 정해 같은 날 같은 나라는 늘 같다. 실제 번호가 아니다.
    static func stampNumber(country: String, date: Date, digits: Int, calendar: Calendar = .autoupdatingCurrent) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let key = "\(country.lowercased())-\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
        let hash = key.unicodeScalars.reduce(UInt32(2_166_136_261)) { ($0 ^ $1.value) &* 16_777_619 }
        var limit: UInt32 = 1
        for _ in 0..<digits { limit *= 10 }
        let text = String(hash % limit)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }

    /// 손으로 찍은 듯 나라마다 다른 기울기(-14~+7도).
    static func stampAngle(country: String) -> Double {
        let hash = country.lowercased().unicodeScalars.reduce(UInt32(2_166_136_261)) { ($0 ^ $1.value) &* 16_777_619 }
        return Double(hash % 22) - 14
    }

    /// 사진에서 본 번호 자리 수. 영국·방글라데시·뉴질랜드는 네 자리다.
    static func numberDigits(country: String) -> Int {
        ["gb", "bd", "nz"].contains(country.lowercased()) ? 4 : 3
    }

    /// 앱 언어와 관계없이 영어 일·월·년(09 NOV 2026).
    /// 공유 포매터의 시간대를 매번 바꾸면 여러 스레드에서 부를 때 섞인다. 값 형식을 쓴다(REV1110A03).
    static func dateText(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let style = Date.VerbatimFormatStyle(
            format: "\(day: .twoDigits) \(month: .abbreviated) \(year: .defaultDigits)",
            locale: Locale(identifier: "en_US_POSIX"), timeZone: calendar.timeZone, calendar: gregorian
        )
        return date.formatted(style).uppercased()
    }

    var outline: AnyShape {
        switch shape {
        case .rectangle: AnyShape(Rectangle())
        case .roundedRectangle: AnyShape(RoundedRectangle(cornerRadius: 6))
        case .circle: AnyShape(Circle())
        case .oval: AnyShape(Ellipse())
        case .hexagon: AnyShape(MapHomePassportPolygon(sides: 6))
        case .octagon: AnyShape(MapHomePassportPolygon(sides: 8))
        case .triangle: AnyShape(MapHomePassportTriangle())
        case .pointedEnds: AnyShape(MapHomePassportPointedEnds())
        case .notched: AnyShape(MapHomePassportNotched())
        }
    }

    var isWide: Bool { shape != .circle && shape != .octagon }
}

/// 양끝이 화살표처럼 뾰족한 틀(몽골).
private struct MapHomePassportPointedEnds: Shape {
    func path(in rect: CGRect) -> Path {
        let tip = rect.width * 0.09
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tip, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tip, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - tip, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + tip, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

/// 네 모서리가 안으로 파인 틀(영국).
private struct MapHomePassportNotched: Shape {
    func path(in rect: CGRect) -> Path {
        let cut = min(rect.width, rect.height) * 0.1
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + cut), control: CGPoint(x: rect.maxX - cut, y: rect.minY + cut))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - cut, y: rect.maxY), control: CGPoint(x: rect.maxX - cut, y: rect.maxY - cut))
        path.addLine(to: CGPoint(x: rect.minX + cut, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - cut), control: CGPoint(x: rect.minX + cut, y: rect.maxY - cut))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
        path.addQuadCurve(to: CGPoint(x: rect.minX + cut, y: rect.minY), control: CGPoint(x: rect.minX + cut, y: rect.minY + cut))
        path.closeSubpath()
        return path
    }
}

private struct MapHomePassportTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct MapHomePassportPolygon: Shape {
    let sides: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<sides {
            let angle = (Double(index) + 0.5) / Double(sides) * 2 * .pi
            let point = CGPoint(x: rect.midX + rect.width / 2 * cos(angle), y: rect.midY + rect.height / 2 * sin(angle))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// 입국 스티커의 QR. 실제 입국 정보 대신 회사 홈페이지로 연결한다(대표 지시).
enum MapHomePassportHomepageQR {
    static let url = "https://bokkiyaw.com"

    static let image: UIImage? = {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }()
}

/// 잉크가 군데군데 빠진 질감. 나라 코드로 항상 같은 무늬가 나온다.
private struct MapHomePassportInkWear: View {
    let seed: String

    var body: some View {
        Canvas { context, canvas in
            context.fill(Path(CGRect(origin: .zero, size: canvas)), with: .color(.black))
            context.blendMode = .destinationOut
            var value = seed.unicodeScalars.reduce(UInt32(2_166_136_261)) { ($0 ^ $1.value) &* 16_777_619 }
            func next() -> CGFloat {
                value = value &* 1_664_525 &+ 1_013_904_223
                return CGFloat(value >> 8 & 0xFFFF) / 65_535
            }
            for _ in 0..<14 {
                let radius = canvas.width * (0.008 + next() * 0.02)
                let rect = CGRect(x: next() * canvas.width, y: next() * canvas.height, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(.black))
            }
        }
    }
}

/// 공항·해외 도시의 여권 입국 도장(대표 결정 2026-11-09).
struct MapHomePassportStamp: View {
    let visitDate: Date?
    var countryCode = "kr"
    /// 도장에 찍을 도시·공항 이름.
    var place = ""
    var size: CGFloat = 46
    /// 쌓인 도장마다 기울기를 달리한다.
    var angleOffset: Double = 0

    var body: some View {
        let style = MapHomePassportStampStyle.style(forCountry: countryCode)
        let ink = style.inkColor
        let width = style.isWide ? size * 1.3 : size
        ZStack {
            if let visitDate, let paperHex = style.paperHex {
                sticker(style: style, paperHex: paperHex, date: visitDate)
            } else if let visitDate {
                ZStack {
                    stampFrame(style: style, ink: ink, width: width)
                        .frame(width: width, height: size)
                        .mask(MapHomePassportInkWear(seed: countryCode))
                    if let code = style.entryCode {
                        entryBoxText(style: style, code: code, ink: ink, width: width, date: visitDate)
                    } else {
                        stampText(style: style, ink: ink, width: width, date: visitDate)
                    }
                    pawMark(style: style, ink: ink, width: width)
                }
                .frame(width: width, height: size)
                .blur(radius: size * 0.003)
                .opacity(0.95)
            } else {
                Circle().stroke(Color.tpBorder, style: StrokeStyle(lineWidth: TaptionBorder.width, dash: [3, 3]))
                Image(systemName: "airplane").font(.system(size: size * 0.3)).foregroundStyle(Color.tpSecondary.opacity(0.6))
            }
        }
        .frame(width: visitDate == nil ? size : width, height: size)
        .rotationEffect(.degrees(visitDate == nil ? 0 : style.paperHex == nil ? MapHomePassportStampStyle.stampAngle(country: countryCode) + angleOffset : -4 + angleOffset))
        .accessibilityHidden(true)
    }

    private var placeText: String { place.isEmpty ? "ARRIVAL" : place.uppercased() }

    /// 화랑이 분홍 발바닥(대표 지시).
    private static let pawHex = "#E9A0AE"

    /// 화랑이 도장: 원 안의 분홍 발바닥. 도장 위에 겹쳐도 된다(대표 지시).
    private func pawSeal(diameter: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Color.black, lineWidth: max(1, diameter * 0.06))
            Image(systemName: "pawprint.fill")
                .font(.system(size: diameter * 0.66))
                .foregroundStyle(.black)
            Image(systemName: "pawprint.fill")
                .font(.system(size: diameter * 0.56))
                .foregroundStyle(Color(hex: Self.pawHex))
        }
        .frame(width: diameter, height: diameter)
        .rotationEffect(.degrees(18))
        .opacity(0.7)
    }

    private func pawMark(style: MapHomePassportStampStyle, ink: Color, width: CGFloat) -> some View {
        pawSeal(diameter: size * (style.isWide ? 0.48 : 0.42))
            .position(x: width * 0.84, y: size * 0.74)
    }

    private func numberText(_ date: Date) -> String {
        MapHomePassportStampStyle.stampNumber(
            country: countryCode, date: date,
            digits: MapHomePassportStampStyle.numberDigits(country: countryCode)
        )
    }

    /// 솅겐·터키형 배치. 왼쪽 위 코드 원, 오른쪽 위 비행기 칸, 가운데 날짜, 왼쪽 아래 화살표 칸, 아래 입국 지점.
    private func entryBoxText(style: MapHomePassportStampStyle, code: String, ink: Color, width: CGFloat, date: Date) -> some View {
        let box = RoundedRectangle(cornerRadius: size * 0.04)
        return ZStack {
            Circle().stroke(ink, style: StrokeStyle(lineWidth: size * 0.03, lineCap: .round, dash: [0.1, size * 0.05]))
                .frame(width: size * 0.3, height: size * 0.3)
                .overlay(Text(verbatim: code).font(.taptionFixed(size: size * 0.11, weight: .bold)).minimumScaleFactor(0.5).lineLimit(1).padding(size * 0.05).foregroundStyle(ink))
                .position(x: width * 0.2, y: size * 0.25)
            box.stroke(ink, lineWidth: max(0.9, size * 0.024))
                .frame(width: width * 0.36, height: size * 0.24)
                .overlay(Image(systemName: "airplane").font(.system(size: size * 0.16, weight: .bold)).foregroundStyle(ink))
                .position(x: width * 0.56, y: size * 0.24)
            Text(verbatim: MapHomePassportStampStyle.dateText(date))
                .font(.system(size: size * 0.17, weight: .heavy, design: .monospaced))
                .foregroundStyle(style.dateColor)
                .frame(width: width * 0.8)
                .position(x: width / 2, y: size * 0.54)
            box.stroke(ink, lineWidth: max(0.9, size * 0.024))
                .frame(width: size * 0.3, height: size * 0.22)
                .overlay(Image(systemName: "arrow.right.to.line").font(.system(size: size * 0.13, weight: .bold)).foregroundStyle(ink))
                .position(x: width * 0.2, y: size * 0.8)
            Text(verbatim: "\(placeText) \(numberText(date))")
                .font(.taptionFixed(size: size * 0.115, weight: .bold))
                .foregroundStyle(ink)
                .frame(width: width * 0.56)
                .position(x: width * 0.63, y: size * 0.8)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .frame(width: width, height: size)
    }

    /// 위 나라 이름, 가운데 큰 날짜, 아래 ARRIVAL과 표시. 칸막이 줄과 겹치지 않게 자리를 고정한다.
    private func stampText(style: MapHomePassportStampStyle, ink: Color, width: CGFloat, date: Date) -> some View {
        let isTriangle = style.shape == .triangle
        let isRound = style.shape == .circle || style.shape == .octagon
        let isOval = style.shape == .oval
        let hasColumn = style.rule == .leftColumn
        let hasBand = style.rule == .topBand || style.rule == .bands
        let centerX = hasColumn ? width * 0.63 : width / 2
        let sideInset: CGFloat = style.hasSideCodes ? 0.82 : 1
        let textWidth = sideInset * width * (hasColumn ? 0.58 : isTriangle ? 0.46 : isRound ? 0.58 : isOval ? 0.62 : style.rule == .sideBars ? 0.6 : 0.72)
        let rows: [CGFloat] = isTriangle
            ? [0.5, 0.68, 0.84]
            : isRound ? [0.3, 0.5, 0.71]
            : isOval ? [0.27, 0.51, 0.75]
            : hasBand ? [0.19, 0.51, 0.85]
            : [0.25, 0.51, 0.77]
        return ZStack {
            Text(verbatim: MapHomePassportStampStyle.countryLabel(countryCode))
                .font(.taptionFixed(size: size * 0.125, weight: .bold))
                .foregroundStyle(ink)
                .frame(width: isTriangle ? width * 0.3 : style.hasStars ? textWidth * 0.68 : textWidth)
                .position(x: centerX, y: size * rows[0])
            if style.hasStars {
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Image(systemName: "star.fill")
                        .font(.system(size: size * 0.09))
                        .foregroundStyle(ink)
                        .position(x: centerX + side * textWidth * 0.42, y: size * rows[0])
                }
            }
            Text(verbatim: MapHomePassportStampStyle.dateText(date))
                .font(.system(size: size * (isRound || isTriangle ? 0.125 : 0.165), weight: .heavy, design: .monospaced))
                .foregroundStyle(style.dateColor)
                .frame(width: textWidth * (style.hasDateBox ? 0.92 : 1))
                .position(x: centerX, y: size * rows[1])
            if style.hasDateBox {
                Rectangle().stroke(ink, lineWidth: max(0.8, size * 0.02))
                    .frame(width: textWidth, height: size * 0.27)
                    .position(x: centerX, y: size * rows[1])
            }
            if style.hasSideCodes {
                ForEach([0.07, 0.93], id: \.self) { x in
                    Text(verbatim: x < 0.5 ? numberText(date) : countryCode.uppercased())
                        .font(.taptionFixed(size: size * 0.1, weight: .bold))
                        .foregroundStyle(ink)
                        .rotationEffect(.degrees(x < 0.5 ? -90 : 90))
                        .position(x: width * x, y: size * 0.56)
                }
            }
            HStack(spacing: size * 0.04) {
                if !hasColumn {
                    Image(systemName: style.mark == .arrow ? "arrow.right.to.line" : "airplane")
                        .font(.system(size: size * 0.12, weight: .bold))
                }
                Text(verbatim: style.isWide && !style.hasSideCodes ? "\(placeText) \(numberText(date))" : placeText)
                    .font(.taptionFixed(size: size * 0.105, weight: .bold))
            }
            .foregroundStyle(ink)
            .frame(width: textWidth)
            .position(x: centerX, y: size * rows[2])
            if hasColumn {
                Image(systemName: "arrow.right.to.line")
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundStyle(ink)
                    .position(x: width * 0.15, y: size * 0.5)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .frame(width: width, height: size)
    }

    /// 외곽선과 칸막이. 사진에서 본 나라별 선의 특징을 옮겼다. 굵은 선이 잘리지 않게 안쪽으로 들여 그린다.
    private func stampFrame(style: MapHomePassportStampStyle, ink: Color, width: CGFloat) -> some View {
        let outline = style.outline
        let main = max(1.5, size * 0.04)
        let inset = size * 0.06
        let innerWidth = width - inset * 2
        let innerHeight = size - inset * 2
        return ZStack {
            switch style.border {
            case .single:
                outline.stroke(ink, style: StrokeStyle(lineWidth: main, lineJoin: .round))
            case .double:
                outline.stroke(ink, style: StrokeStyle(lineWidth: main, lineJoin: .round))
                outline.stroke(ink.opacity(0.85), lineWidth: max(0.8, size * 0.02)).scaleEffect(0.88)
            case .thickThin:
                outline.stroke(ink, style: StrokeStyle(lineWidth: main * 1.8, lineJoin: .round))
                outline.stroke(ink, lineWidth: max(0.7, size * 0.016)).scaleEffect(0.86)
            case .dotted:
                outline.stroke(ink, style: StrokeStyle(lineWidth: main, lineJoin: .round))
                outline.stroke(ink, style: StrokeStyle(lineWidth: size * 0.038, lineCap: .round, dash: [0.1, size * 0.08])).scaleEffect(0.87)
            case .ticks:
                outline.stroke(ink, style: StrokeStyle(lineWidth: size * 0.07, dash: [size * 0.022, size * 0.045]))
                outline.stroke(ink, lineWidth: max(0.9, size * 0.024)).scaleEffect(0.88)
            case .beaded:
                outline.stroke(ink, style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round, dash: [0.1, size * 0.095]))
                outline.stroke(ink, lineWidth: max(0.9, size * 0.024)).scaleEffect(0.87)
            }
            Path { path in
                func across(_ y: CGFloat) { path.move(to: CGPoint(x: 0, y: y - inset)); path.addLine(to: CGPoint(x: innerWidth, y: y - inset)) }
                func down(_ x: CGFloat) { path.move(to: CGPoint(x: x - inset, y: 0)); path.addLine(to: CGPoint(x: x - inset, y: innerHeight)) }
                switch style.rule {
                case .none: break
                case .topBand: across(size * 0.31)
                case .bands: across(size * 0.31); across(size * 0.72)
                case .sideBars: down(width * 0.14); down(width * 0.86)
                case .leftColumn: down(width * 0.28)
                }
            }
            .stroke(ink, lineWidth: max(0.8, size * 0.022))
            .clipShape(outline)
        }
        .frame(width: innerWidth, height: innerHeight)
    }

    /// 도장 대신 붙이는 입국 스티커·쪽지. 실제 코드 자리에는 홈페이지 QR을 넣는다.
    private func sticker(style: MapHomePassportStampStyle, paperHex: String, date: Date) -> some View {
        let ink = style.inkColor
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: paperHex))
            RoundedRectangle(cornerRadius: 2).stroke(ink.opacity(0.45), lineWidth: 0.8)
            VStack(alignment: .leading, spacing: size * 0.02) {
                Text(verbatim: MapHomePassportStampStyle.countryLabel(countryCode))
                    .font(.taptionFixed(size: size * 0.13, weight: .bold))
                Text(verbatim: placeText)
                    .font(.taptionFixed(size: size * 0.09, weight: .bold))
                    .opacity(0.8)
                Text(verbatim: MapHomePassportStampStyle.dateText(date))
                    .font(.system(size: size * 0.105, weight: .heavy, design: .monospaced))
                    .frame(maxWidth: size * 0.78, alignment: .leading)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(ink)
            .padding(size * 0.1)
            pawSeal(diameter: size * 0.42)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(size * 0.05)
            if style.hasMountain {
                Path { path in
                    let w = size * 0.5, h = size * 0.2
                    path.move(to: CGPoint(x: 0, y: h))
                    path.addLine(to: CGPoint(x: w * 0.4, y: 0))
                    path.addLine(to: CGPoint(x: w * 0.6, y: 0))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.closeSubpath()
                }
                .fill(ink.opacity(0.55))
                .frame(width: size * 0.5, height: size * 0.2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(size * 0.1)
            }
            if let qr = MapHomePassportHomepageQR.image {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size * 0.36, height: size * 0.36)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(size * 0.07)
            }
        }
        .taptionShadow(.floating)
    }
}

/// 개발자에게 보내는 장소 등록 요청. 메일 화면에서 사용자가 직접 보낸다.
struct MapHomePlaceRequest: Codable, Equatable {
    var name: String
    var memo: String
    var latitude: Double
    var longitude: Double
    var requestedAt: Date
    var appBuild: String

    func writeJSON(to directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent("BOKKI-place-request-\(Int(requestedAt.timeIntervalSince1970)).json")
        try encoder.encode(self).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

struct MapHomePlaceRequestSheet: View {
    let language: MapHomeLanguage
    let currentCoordinate: CLLocationCoordinate2D?

    @State private var name = ""
    @State private var memo = ""
    @State private var query = ""
    @State private var center: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .automatic
    @State private var attachment: MapHomeDeveloperAttachment?
    /// 사용자가 자리를 직접 골랐는가(지도 이동·검색·현재 위치 단추). 처음 열면 지도가 현재 위치라,
    /// 이름만 적고 보내면 집·회사 좌표가 그대로 메일로 갔다(REV1110A03).
    @State private var pinChosen = false
    @State private var sentFile: URL?

    private var canSend: Bool { pinChosen && center != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(language.text("장소 등록 요청", "Request a place"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.headline), weight: .bold))
                TextField(language.text("장소 이름", "Place name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField(language.text("설명", "Description"), text: $memo, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField(language.text("장소 검색", "Search places"), text: $query)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    if let currentCoordinate {
                        Button { move(to: currentCoordinate); pinChosen = true } label: {
                            Image(systemName: "location.fill").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(language.text("현재 위치", "Current location"))
                    }
                }
                Map(position: $position)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
                    .overlay {
                        Image(systemName: "mappin")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Color(hex: MapHomeInkWash.sealHex))
                            .offset(y: -15)
                            .allowsHitTesting(false)
                    }
                    .onMapCameraChange(frequency: .onEnd) { context in
                        center = context.camera.centerCoordinate
                        // 현재 위치를 모르면 처음 보이는 자리가 개인 위치가 아니다.
                        if currentCoordinate.map({ Self.distance($0, context.camera.centerCoordinate) > 30 }) ?? true { pinChosen = true }
                    }
                Text(pinChosen
                     ? language.text("지도를 움직여 핀을 맞춰 주세요.", "Move the map to place the pin.")
                     : language.text("지도를 움직이거나 검색해 핀을 맞춰 주세요. 지금 위치를 보내려면 위치 단추를 누르세요.", "Move the map or search to place the pin. To send where you are, tap the location button."))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                Button(action: send) {
                    Text(language.text("메일 보내기", "Send email"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                        .foregroundStyle(Color.tpBackground)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(canSend ? Color.tpInk : Color.tpSecondary, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(20)
        }
        .background(Color.tpBackground)
        .onAppear { if let currentCoordinate { move(to: currentCoordinate) } }
        // 보낸 뒤 임시 JSON을 남기지 않는다.
        .sheet(item: $attachment, onDismiss: { sentFile.map { try? FileManager.default.removeItem(at: $0) }; sentFile = nil }) {
            MapHomeDeveloperMailSheet(attachment: $0)
        }
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private func move(to coordinate: CLLocationCoordinate2D) {
        position = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1_200, longitudinalMeters: 1_200))
        center = coordinate
    }

    private func search() async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return }
        move(to: item.placemark.coordinate)
        pinChosen = true
        if name.isEmpty { name = item.name ?? "" }
    }

    private func send() {
        guard let center else { return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let request = MapHomePlaceRequest(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            memo: memo.trimmingCharacters(in: .whitespacesAndNewlines),
            latitude: center.latitude, longitude: center.longitude, requestedAt: .now, appBuild: build
        )
        guard let url = try? request.writeJSON() else { return }
        sentFile = url
        attachment = MapHomeDeveloperAttachment(url: url, subject: "BOKKI Plan place request: \(request.name)", mimeType: "application/json")
    }
}

extension AppModel {
    /// 여행 일정 한 곳을 더하고 그날 계획에도 넣는다. 정본은 설정의 일정 목록이다.
    @discardableResult
    func addTravelStop(title: String, latitude: Double, longitude: Double, day: Date) -> TravelPlanStop? {
        guard acceptsDataMutation() else { return nil }
        let start = Calendar.autoupdatingCurrent.startOfDay(for: day)
        let order = TravelPlanSchedule.stops(on: start, in: snapshot.settings.travelPlanStops).count
        let planStart = start.addingTimeInterval(Double(9 + min(order * 2, 12)) * 3_600)
        let planID = addPlan(title: title, categoryID: "movement", startAt: planStart, duration: 3_600)
        let stop = TravelPlanStop(id: UUID(), title: title, latitude: latitude, longitude: longitude, day: start, order: order, planID: planID)
        snapshot.settings.travelPlanStops.append(stop)
        Task { await persist() }
        return stop
    }

    func removeTravelStop(_ id: UUID) async {
        guard acceptsDataMutation(), let stop = snapshot.settings.travelPlanStops.first(where: { $0.id == id }) else { return }
        snapshot.settings.travelPlanStops.removeAll { $0.id == id }
        snapshot.settings.travelPlanStops = TravelPlanSchedule.renumbered(snapshot.settings.travelPlanStops)
        if let planID = stop.planID { await deletePlan(planID) } else { await persist() }
    }

    func moveTravelStop(_ id: UUID, by offset: Int) {
        guard acceptsDataMutation() else { return }
        snapshot.settings.travelPlanStops = TravelPlanSchedule.moved(snapshot.settings.travelPlanStops, id: id, by: offset)
        Task { await persist() }
    }
}

/// 날짜별 순서 계산.
/// 저장된 `day`는 만들 때 기기 시간대의 자정이다. 여행지에서 시간대가 바뀌어도 같은 날로 보도록 연·월·일로 비교한다(REV1110A02).
enum TravelPlanSchedule {
    /// 저장된 자정을 연·월·일로 읽는다. 자정에 12시간을 더해 UTC로 읽으면 UTC−11~+12 어디서 만든 날짜든 그날이 된다.
    static func dayKey(stored day: Date) -> DateComponents {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return utc.dateComponents([.year, .month, .day], from: day.addingTimeInterval(12 * 3_600))
    }

    /// 지금 기기 달력에서 그날의 자정.
    static func localDay(stored day: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.date(from: dayKey(stored: day)).map { calendar.startOfDay(for: $0) } ?? day
    }

    static func isSameDay(stored: Date, local day: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        dayKey(stored: stored) == calendar.dateComponents([.year, .month, .day], from: day)
    }

    /// 일정이 있는 날(지금 기기 달력의 자정).
    static func days(_ stops: [TravelPlanStop], calendar: Calendar = .autoupdatingCurrent) -> [Date] {
        Array(Set(stops.map { localDay(stored: $0.day, calendar: calendar) })).sorted()
    }

    /// `day`는 지금 기기 달력의 날짜다.
    static func stops(on day: Date, in stops: [TravelPlanStop], calendar: Calendar = .autoupdatingCurrent) -> [TravelPlanStop] {
        stops.filter { isSameDay(stored: $0.day, local: day, calendar: calendar) }.sorted { $0.order < $1.order }
    }

    static func renumbered(_ stops: [TravelPlanStop]) -> [TravelPlanStop] {
        days(stops).flatMap { day in
            self.stops(on: day, in: stops).enumerated().map { index, stop in
                var copy = stop
                copy.order = index
                return copy
            }
        }
    }

    static func moved(_ all: [TravelPlanStop], id: UUID, by offset: Int) -> [TravelPlanStop] {
        guard let stop = all.first(where: { $0.id == id }) else { return all }
        let key = dayKey(stored: stop.day)
        var day = all.filter { dayKey(stored: $0.day) == key }.sorted { $0.order < $1.order }
        guard let from = day.firstIndex(where: { $0.id == id }), day.indices.contains(from + offset) else { return all }
        day.swapAt(from, from + offset)
        let ordered = day.enumerated().map { index, item in
            var copy = item
            copy.order = index
            return copy
        }
        return all.filter { dayKey(stored: $0.day) != key } + ordered
    }
}

/// 여행 계획: 날짜별 핀과 순서대로 이은 경로.
struct MapHomeTripPlanSheet: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    var initialDay = Date.now
    var onSelect: (MapHomePlaceBookPin) -> Void

    @State private var query = ""
    @State private var day = Calendar.autoupdatingCurrent.startOfDay(for: .now)

    private var stops: [TravelPlanStop] { model.settings.travelPlanStops }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(language.text("여행 계획", "Trip plan"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.headline), weight: .bold))
                DatePicker(language.text("날짜", "Date"), selection: $day, in: Calendar.autoupdatingCurrent.startOfDay(for: .now)..., displayedComponents: .date)
                TextField(language.text("장소 검색", "Search places"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit { Task { await addFromSearch() } }
                if stops.isEmpty {
                    Text(language.text("아직 담은 곳이 없습니다.", "No stops yet."))
                        .foregroundStyle(Color.tpSecondary)
                }
                ForEach(TravelPlanSchedule.days(stops), id: \.self) { date in
                    daySection(date, TravelPlanSchedule.stops(on: date, in: stops))
                }
                TripUnpinnedItemStatusList(model: model, language: language)
            }
            .padding(20)
        }
        .background(Color.tpBackground)
        .onAppear { day = max(initialDay, day) }
    }

    private func addFromSearch() async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return }
        model.addTravelStop(
            title: item.name ?? query,
            latitude: item.placemark.coordinate.latitude,
            longitude: item.placemark.coordinate.longitude,
            day: day
        )
        query = ""
    }

    /// 한 곳뿐이면 자동 맞춤이 최대로 확대해 빈 지도가 된다.
    private func dayPosition(_ dayStops: [TravelPlanStop]) -> MapCameraPosition {
        guard dayStops.count == 1, let stop = dayStops.first else { return .automatic }
        return .region(MKCoordinateRegion(center: stop.coordinate, latitudinalMeters: 20_000, longitudinalMeters: 20_000))
    }

    private func daySection(_ date: Date, _ dayStops: [TravelPlanStop]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(date, format: .dateTime.month().day().weekday())
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .semibold))
            Map(initialPosition: dayPosition(dayStops)) {
                ForEach(Array(TravelGreatCircleAdapter.paths(dayStops.map(\.coordinate)).enumerated()), id: \.offset) { _, path in
                    MapPolyline(coordinates: path).stroke(Color(hex: MapHomeInkWash.sealHex), lineWidth: 3)
                }
                ForEach(Array(dayStops.enumerated()), id: \.element.id) { index, stop in
                    Marker(stop.title, monogram: Text(verbatim: "\(index + 1)"), coordinate: stop.coordinate)
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
            .id(dayStops.map(\.id))
            ForEach(Array(dayStops.enumerated()), id: \.element.id) { index, stop in
                HStack {
                    Text(verbatim: "\(index + 1). \(stop.title)").lineLimit(1)
                    Spacer()
                    Button { model.moveTravelStop(stop.id, by: -1) } label: { Image(systemName: "chevron.up").frame(width: 36, height: 44) }
                        .disabled(index == 0)
                    Button { model.moveTravelStop(stop.id, by: 1) } label: { Image(systemName: "chevron.down").frame(width: 36, height: 44) }
                        .disabled(index == dayStops.count - 1)
                    Button { Task { await model.removeTravelStop(stop.id) } } label: { Image(systemName: "trash").frame(width: 36, height: 44) }
                        .accessibilityLabel(language.text("삭제", "Delete"))
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect(MapHomePlaceBookPin(title: stop.title, subtitle: "", latitude: stop.latitude, longitude: stop.longitude))
                }
                TripItemStatusPicker(language: language, status: TripItemStatus(raw: stop.status)) { model.setTravelStopStatus($0, stopID: stop.id) }
            }
        }
    }
}

extension TravelPlanStop {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// 메인 지도의 여행 일정 번호 핀.
struct MapHomeTravelStopPin: View {
    let number: Int
    var status: TripItemStatus = .planned

    var body: some View {
        Text(verbatim: "\(number)")
            .font(.system(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Color(hex: MapHomeInkWash.sealHex), in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .tripStatusPinStyle(status)
    }
}

extension MapHomeView {
    /// 지금 고른 날의 여행 일정(PLB1109A03).
    var travelStopsOnSelectedDay: [TravelPlanStop] {
        TravelPlanSchedule.stops(
            on: Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate),
            in: model.settings.travelPlanStops
        )
    }

    func travelStopMarkerID(_ stop: TravelPlanStop) -> String { "travel-stop-\(stop.id.uuidString)" }

    private var travelRouteSignature: Int {
        var hasher = Hasher()
        for stop in travelStopsOnSelectedDay {
            hasher.combine(stop.latitude)
            hasher.combine(stop.longitude)
        }
        return hasher.finalize()
    }

    var vectorTravelRoutes: [MapHomeVectorRoute] {
        let stops = travelStopsOnSelectedDay
        guard stops.count >= 2 else { return [] }
        return [MapHomeVectorRoute(
            id: "travel-plan-route",
            coordinates: stops.map(\.coordinate),
            geometrySignature: travelRouteSignature,
            colorHex: MapHomeInkWash.sealHex,
            opacity: 0.85
        )]
    }

    var appleTravelRoutes: [MapHomeAppleRoute] {
        let stops = travelStopsOnSelectedDay
        guard stops.count >= 2 else { return [] }
        return [MapHomeAppleRoute(
            id: "travel-plan-route",
            coordinates: stops.map(\.coordinate),
            geometrySignature: travelRouteSignature,
            colorHex: MapHomeInkWash.sealHex,
            opacity: 0.85,
            phase: .forecast,
            transport: nil
        )]
    }
}

extension MapHomeView {
    /// 여권 도장으로 온 날짜에서 보던 쪽으로 돌아간다(대표 지시).
    var passportBackButton: some View {
        Button {
            passportStartPage = passportReturnPage ?? 0
            passportReturnPage = nil
            isPassportPresented = true
        } label: {
            Image(systemName: "chevron.backward")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.tpInk)
                .frame(width: 40, height: 40)
                .background { TaptionStickerDisc() }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.text("여권으로 돌아가기", "Back to passport"))
    }

    /// 여행 모드 하단. 가운데 추가만 두고 양쪽 세 칸은 비워 둔다(대표 지시).
    @ViewBuilder var travelBottomBarItems: some View {
        ForEach(0..<3, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
        bottomBarButton("plus", language.text("추가", "Add")) { isTravelAddChoicePresented = true }
        ForEach(3..<6, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
    }

    /// 돋보기 옆 여행 모드 전환. 지금 모드를 보여 준다: 현실은 집, 여행은 비행기(대표 지시).
    var travelModeButton: some View {
        Button {
            // 집 단추는 여행 화면(지구본)을 연다. 지도 여행 모드에 있을 때는 일상으로 돌아간다(TVB1112A01).
            if isTravelMode {
                withAnimation(.easeInOut(duration: 0.2)) { isTravelMode = false }
                model.selectedDate = .now
            } else {
                isTravelHomePresented = true
            }
        } label: {
            TaptionBarIcon(systemImage: isTravelMode ? "airplane" : "house.fill", size: 25)
                .frame(width: 40, height: 40)
                .background { TaptionStickerDisc() }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isTravelMode
            ? language.runtimeText("현실 모드로 돌아가기", "Back to everyday mode")
            : language.text("여행 계획", "Trip plan"))
    }

    /// 여행 모드에서는 오늘 이후만 고른다.
    func keepSelectedDateInFuture() {
        guard isTravelMode, let minimum = travelModeMinimumDay, model.selectedDate < minimum else { return }
        model.selectedDate = .now
    }

    var travelPlanDays: Set<Date> {
        Set(TravelPlanSchedule.days(model.settings.travelPlanStops))
    }

    /// 여행 모드에서 고를 수 있는 첫날. 오늘이 기본이고, 이미 시작해 아직 끝나지 않은 여행이 있으면 그 첫날까지 연다.
    var travelModeMinimumDay: Date? {
        guard isTravelMode else { return nil }
        return TravelTripSchedule.earliestSelectableDay(items: model.settings.travelTripItems ?? [], now: .now)
    }
}

enum TravelTripSchedule {
    /// 오늘, 또는 진행 중인 여행의 첫날(그곳 현지 날짜를 기기 달력의 같은 날짜로) 가운데 이른 쪽.
    static func earliestSelectableDay(items: [TravelTripItem], now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let today = calendar.startOfDay(for: now)
        let ongoingStarts = Dictionary(grouping: items, by: \.tripID).values.compactMap { trip -> Date? in
            guard let last = trip.map(\.end).max(), last >= today, let first = trip.min(by: { $0.start < $1.start }) else { return nil }
            var local = Calendar(identifier: .gregorian)
            local.timeZone = TimeZone(secondsFromGMT: first.startOffsetSeconds) ?? calendar.timeZone
            return calendar.date(from: local.dateComponents([.year, .month, .day], from: first.start)).map(calendar.startOfDay)
        }
        return min(today, ongoingStarts.min() ?? today)
    }
}
