import SwiftUI

/// 통행료 종류(HWY1111A02): 고속도로(노선 번호)·유료 다리·유료 터널.
enum LedgerToll: Equatable {
    case highway(Int)
    case bridge
    case tunnel

    static let bridges = ["인천대교", "영종대교", "광안대교", "일산대교", "거가대교", "마창대교", "을숙도대교", "부산항대교"]
    static let tunnels = ["남산1호터널", "남산3호터널", "미시령", "수정산터널", "구덕터널", "백양터널", "천마산터널", "우면산터널"]
    private static let cues = ["통행료", "요금", "하이패스", "톨"]

    /// 다리·터널을 먼저 본다(영종대교는 인천공항고속도로 위에 있다).
    static func kind(in text: String) -> LedgerToll? {
        let compact = text.replacingOccurrences(of: " ", with: "")
        let paid = cues.contains { compact.localizedCaseInsensitiveContains($0) }
        if bridges.contains(where: compact.contains) || (paid && (compact.contains("대교") || compact.contains("다리"))) { return .bridge }
        if tunnels.contains(where: compact.contains) || (paid && compact.contains("터널")) { return .tunnel }
        return LedgerHighway.number(in: text).map(LedgerToll.highway)
    }

    static func kind(for entry: LedgerEntry) -> LedgerToll? {
        kind(in: [entry.title, entry.place, entry.note].compactMap { $0 }.joined(separator: " "))
    }
}

/// 고속도로 통행료 기록의 노선 번호(HWY1111A01). 국내 고속도로 이름 → 노선 번호.
enum LedgerHighway {
    /// 긴 이름을 먼저 찾는다(「제2경인」이 「경인」보다, 「중부내륙」이 「중부」보다 먼저).
    static let routes: [(name: String, number: Int)] = [
        ("수도권제1순환", 100), ("수도권제2순환", 400), ("서울외곽", 100), ("인천국제공항", 130), ("인천공항", 130),
        ("제2경인", 110), ("제2중부", 37), ("중부내륙", 45), ("새만금포항", 20), ("익산포항", 20),
        ("광주대구", 12), ("달빛", 12), ("무안광주", 12), ("서해안", 15), ("평택시흥", 17), ("순천완주", 27),
        ("당진영덕", 30), ("청주영덕", 30), ("통영대전", 35), ("평택제천", 40), ("광주원주", 52), ("서울양양", 60),
        ("부산외곽", 600), ("대구외곽", 700), ("경부", 1), ("남해", 10), ("울산", 16), ("호남", 25), ("중부", 35),
        ("영동", 50), ("중앙", 55), ("동해", 65), ("경인", 120),
    ]
    private static let cues = ["고속", "요금소", "톨게이트", "통행료", "하이패스", "IC", "JC"]

    /// 고속도로 통행료로 보이면 노선 번호.
    static func number(in text: String) -> Int? {
        let compact = text.replacingOccurrences(of: " ", with: "")
        guard cues.contains(where: { compact.localizedCaseInsensitiveContains($0) }) else { return nil }
        return routes.first { compact.contains($0.name) }?.number
    }

    static func number(for entry: LedgerEntry) -> Int? {
        number(in: [entry.title, entry.place, entry.note].compactMap { $0 }.joined(separator: " "))
    }
}

/// 국내 고속도로 노선 표지: 파란 방패, 빨간 윗띠, 흰 번호.
struct LedgerHighwayShield: View {
    let number: Int
    var size: CGFloat = 26

    var body: some View {
        let shape = ShieldShape()
        ZStack(alignment: .top) {
            shape.fill(Color(red: 0.0, green: 0.30, blue: 0.62))
            Rectangle().fill(Color(red: 0.84, green: 0.11, blue: 0.13)).frame(height: size * 0.24)
            Text(verbatim: "\(number)")
                .font(.system(size: size * (number >= 100 ? 0.36 : 0.46), weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, size * 0.08)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, size * 0.2)
        }
        .clipShape(shape)
        .overlay { shape.stroke(.white, lineWidth: size * 0.06) }
        .frame(width: size, height: size * 1.05)
        .accessibilityLabel(Text(verbatim: "\(number)"))
    }

    private struct ShieldShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let h = rect.height
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.55))
            path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.minY + h * 0.88))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.55), control: CGPoint(x: rect.minX, y: rect.minY + h * 0.88))
            path.closeSubpath()
            return path
        }
    }
}

/// 통행료 표지: 고속도로는 노선 번호 방패, 다리는 아치, 터널은 입구 모양(HWY1111A02).
struct LedgerTollIcon: View {
    let toll: LedgerToll
    var size: CGFloat = 24

    var body: some View {
        switch toll {
        case let .highway(number): LedgerHighwayShield(number: number, size: size)
        case .bridge: badge { BridgeShape().stroke(.white, style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round, lineJoin: .round)) }
        case .tunnel: badge { TunnelShape().fill(Color(red: 0.12, green: 0.12, blue: 0.14)) }
        }
    }

    private func badge(@ViewBuilder _ glyph: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
            .fill(Color(red: 0.05, green: 0.45, blue: 0.30))
            .overlay { glyph().padding(size * 0.16) }
            .overlay { RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).stroke(.white, lineWidth: size * 0.06) }
            .frame(width: size, height: size)
    }

    /// 주탑 둘에 늘어진 줄과 상판.
    private struct BridgeShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let deck = rect.minY + rect.height * 0.72
            path.move(to: CGPoint(x: rect.minX, y: deck))
            path.addLine(to: CGPoint(x: rect.maxX, y: deck))
            for x in [rect.minX + rect.width * 0.28, rect.minX + rect.width * 0.72] {
                path.move(to: CGPoint(x: x, y: rect.minY + rect.height * 0.1))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.5))
            path.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.1), control: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.45))
            path.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.72, y: rect.minY + rect.height * 0.1), control: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.75))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.5), control: CGPoint(x: rect.minX + rect.width * 0.82, y: rect.minY + rect.height * 0.45))
            return path
        }
    }

    /// 산에 뚫린 반원 입구.
    private struct TunnelShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let radius = rect.width * 0.36
            let base = rect.maxY
            path.move(to: CGPoint(x: rect.midX - radius, y: base))
            path.addLine(to: CGPoint(x: rect.midX - radius, y: base - rect.height * 0.3))
            path.addArc(center: CGPoint(x: rect.midX, y: base - rect.height * 0.3), radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: rect.midX + radius, y: base))
            path.closeSubpath()
            return path
        }
    }
}

/// 가계부 기록의 아이콘: 통행료면 그 표지, 아니면 분류 아이콘.
struct LedgerEntryIcon: View {
    let entry: LedgerEntry
    var size: CGFloat = 24

    var body: some View {
        if let toll = LedgerToll.kind(for: entry) {
            LedgerTollIcon(toll: toll, size: size)
        } else {
            Image(systemName: entry.category.symbol).foregroundStyle(Color.tpAccent)
        }
    }
}
