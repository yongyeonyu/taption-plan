import SwiftUI

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

/// 가계부 기록의 아이콘: 고속도로 통행료면 노선 표지, 아니면 분류 아이콘.
struct LedgerEntryIcon: View {
    let entry: LedgerEntry
    var size: CGFloat = 24

    var body: some View {
        if let number = LedgerHighway.number(for: entry) {
            LedgerHighwayShield(number: number, size: size)
        } else {
            Image(systemName: entry.category.symbol).foregroundStyle(Color.tpAccent)
        }
    }
}
