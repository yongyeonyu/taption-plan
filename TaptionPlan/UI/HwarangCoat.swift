import CoreGraphics
import SwiftUI

/// 고양이 캐릭터의 털과 눈. 화랑이(수컷, 흰 털), 춘향이(암컷, 삼색, 호박색 눈), 윤복이(암컷, 갈색 줄무늬, 흰 가슴·양말).
struct HwarangCoat {
    struct Patch { var color: UInt32, x: CGFloat, y: CGFloat, rx: CGFloat, ry: CGFloat }

    var fur: UInt32 = 0xFFFFFF
    var far: UInt32 = 0xEFE9E0
    var outline: UInt32 = 0x5A4033
    var iris: UInt32 = 0x2474D6
    var irisLight: UInt32 = 0x74C6FF
    var headPatches: [Patch] = []
    var bodyPatches: [Patch] = []
    /// 암컷 표시: 속눈썹과 귀 옆 리본.
    var lashes = false
    var bow: UInt32?
    var chest: UInt32?
    var socks: UInt32?
    /// 몸통 높이 비율. 암컷 둘은 조금 날씬하다.
    var bodyHeight: CGFloat = 1
    /// 동작 차이: 빠르기, 시작 시점, 고개 기울기.
    var tempo: CGFloat = 1
    var phase: CGFloat = 0
    var headTilt: CGFloat = 0

    static let white = HwarangCoat()
    /// 앱 화면에 그릴 캐릭터. 지도 마커는 SwiftUI 환경을 물려받지 못하는 곳이 있어 한곳에 둔다.
    @MainActor static var selected = HwarangCoat.white
    @MainActor static var selectedName = "화랑이"

    /// 앱에서 고를 수 있는 캐릭터. 옛 설정의 다른 털색은 기존 그림을 그대로 쓴다.
    static let characters = ["white", "calico", "mackerel"]

    /// 회의 장면의 상대: 화랑이에게는 춘향이, 춘향이에게는 윤복이, 윤복이에게는 화랑이.
    var meetingRival: HwarangCoat {
        if fur == Self.white.fur { return Self.chunhyang }
        return fur == Self.chunhyang.fur ? Self.yunbok : Self.white
    }

    static func named(_ style: String) -> HwarangCoat {
        switch style {
        case "calico": return chunhyang
        case "mackerel": return yunbok
        default: return .white
        }
    }

    private static let chunhyang: HwarangCoat = {
        let orange: UInt32 = 0xE8964A, dark: UInt32 = 0x4A403A
        return HwarangCoat(
            fur: 0xFFF9F0, iris: 0xD98A1F, irisLight: 0xFFCB5E,
            headPatches: [Patch(color: orange, x: -15, y: -13, rx: 12, ry: 10), Patch(color: dark, x: 15, y: -13, rx: 11, ry: 9)],
            bodyPatches: [Patch(color: orange, x: 34, y: 74, rx: 17, ry: 12), Patch(color: dark, x: 58, y: 80, rx: 11, ry: 9), Patch(color: orange, x: 16, y: 98, rx: 12, ry: 9)],
            lashes: true, bow: 0xE5487A, bodyHeight: 0.9, tempo: 0.88, phase: 1.3, headTilt: 0.07
        )
    }()

    private static let yunbok: HwarangCoat = {
        let stripe: UInt32 = 0x4C3F33
        return HwarangCoat(
            fur: 0x9A8873, far: 0x857561, outline: 0x3E3229, iris: 0x8A9A3C, irisLight: 0xCDD272,
            headPatches: [
                Patch(color: 0xC8A077, x: -9, y: 10, rx: 8, ry: 6), Patch(color: 0xC8A077, x: 9, y: 10, rx: 8, ry: 6),
                Patch(color: 0xF7F0E4, x: 0, y: 11, rx: 6, ry: 6),
                Patch(color: stripe, x: 0, y: -12, rx: 1.3, ry: 5), Patch(color: stripe, x: -5, y: -12, rx: 1.2, ry: 4.5), Patch(color: stripe, x: 5, y: -12, rx: 1.2, ry: 4.5),
                Patch(color: stripe, x: -19, y: 4, rx: 4, ry: 1.2), Patch(color: stripe, x: 19, y: 4, rx: 4, ry: 1.2)
            ],
            bodyPatches: [24, 34, 44, 54, 64].map { Patch(color: stripe, x: $0, y: 76, rx: 2.6, ry: 15) },
            lashes: true, bow: 0xB58BD8, chest: 0xFFFDF8, socks: 0xFFFDF8, bodyHeight: 0.88, tempo: 1.12, phase: 2.6, headTilt: -0.05
        )
    }()
}

extension HwarangPainter {
    /// 바깥 눈꼬리에 속눈썹 세 가닥. 눈 모양에 따라 시작 높이만 다르다.
    func lashes(side: CGFloat, ex: CGFloat, ey: CGFloat, eye: Eye) {
        let y = eye == .open ? ey - 2.6 : ey + (eye == .happy ? 1.2 : 0)
        let x = ex + side * (eye == .open ? 5.6 : 4.4)
        stroke(outline, 1.3); c.setLineCap(.round); c.beginPath()
        for (dx, dy) in [(CGFloat(3.1), CGFloat(-0.6)), (2.6, -2.5), (1.4, -3.8)] {
            c.move(to: P(x, y)); c.addLine(to: P(x + side * dx, y + dy))
        }
        c.strokePath()
    }

    /// 오른쪽 귀 옆 작은 리본.
    func bow_(_ color: UInt32, lineWidth: CGFloat) {
        let q = P(-15.5, -9.5)
        fill(color); stroke(outline, lineWidth * 0.55); c.setLineJoin(.round)
        poly([q, P(q.x - 6, q.y - 3.2), P(q.x - 6, q.y + 3.2)]); c.drawPath(using: .fillStroke)
        poly([q, P(q.x + 6, q.y - 3.2), P(q.x + 6, q.y + 3.2)]); c.drawPath(using: .fillStroke)
        c.beginPath(); circle(q.x, q.y, 1.7); c.drawPath(using: .fillStroke)
    }

    /// 윤복이의 하얀 가슴. 목 아래 몸통 위에 얹고 머리가 윗부분을 덮는다.
    func paintChest(head: CGPoint, shoulder: CGPoint) {
        guard let chest = coat.chest else { return }
        fill(chest); c.beginPath(); oval(lerp(head.x, shoulder.x, 0.45), lerp(head.y, shoulder.y, 0.7) + 2, 8.5, 10); c.fillPath()
    }

    func paintPatches(_ patches: [HwarangCoat.Patch], clip: () -> Void) {
        guard !patches.isEmpty else { return }
        c.saveGState(); clip(); c.clip()
        for patch in patches { fill(patch.color); c.beginPath(); oval(patch.x, patch.y, patch.rx, patch.ry); c.fillPath() }
        c.restoreGState()
    }

    func paintSocks() {
        guard let socks = coat.socks else { return }
        fill(socks); c.beginPath(); for t in toes { oval(t.x + 0.4, t.y - 0.6, 4.6, 3.6) }; c.fillPath()
        stroke(outline, 1.2 * lineScale)
    }
}

/// 메뉴 머리글의 고양이를 눌러 캐릭터를 바꾼다(CHR1103A01).
struct MapHomeMenuCatPicker: View {
    let selected: CatCoat
    let language: MapHomeLanguage
    let onSelect: (CatCoat) -> Void

    var body: some View {
        Menu {
            ForEach(CatCoat.characters) { coat in
                Button { onSelect(coat) } label: {
                    // 메뉴 항목에는 걸어가는 고양이를 작게 그려 넣는다.
                    Label {
                        Text(language.runtimeText(coat.displayName, coat.englishName) + (selected == coat ? " ✓" : ""))
                    } icon: {
                        Image(uiImage: HwarangDiagnostics.frame(scene: .walkLoop, sec: 0.7, side: 44, small: true, coat: .named(coat.catStyle.rawValue)))
                    }
                }
            }
        } label: {
            // 그림이 칸 아래쪽에 서 있어, 명언·닫기 단추와 세로 가운데가 맞도록 올린다.
            MapHomeMenuHeaderCat(size: 58)
                .offset(y: -11)
        }
        .accessibilityLabel(language.text("고양이 바꾸기", "Change cat"))
    }
}

/// 메뉴 머리글의 시간 명언 한 개. 주마다 바뀌고 영어로만 보여 준다(출처가 분명한 문장만 둔다).
struct MapHomeMenuHeaderTitle: View {
    let language: MapHomeLanguage

    static let quotes: [(text: String, author: String)] = [
        ("Lost time is never found again.", "Benjamin Franklin"),
        ("You may delay, but time will not.", "Benjamin Franklin"),
        ("Time is money.", "Benjamin Franklin"),
        ("Better three hours too soon than a minute too late.", "William Shakespeare"),
        ("I wasted time, and now doth time waste me.", "William Shakespeare"),
        ("It is not that we have a short time to live, but that we waste a lot of it.", "Seneca"),
        ("Time flies over us, but leaves its shadow behind.", "Nathaniel Hawthorne"),
        ("The two most powerful warriors are patience and time.", "Leo Tolstoy"),
        ("Time is the most valuable thing a man can spend.", "Theophrastus")
    ]

    static func quote(on date: Date, calendar: Calendar = .autoupdatingCurrent) -> (text: String, author: String) {
        let week = calendar.component(.weekOfYear, from: date) + calendar.component(.yearForWeekOfYear, from: date) * 53
        return quotes[week % quotes.count]
    }

    var body: some View {
        let quote = Self.quote(on: .now)
        Text("“\(quote.text)” — \(quote.author)")
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
            .foregroundStyle(Color.tpInk)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
