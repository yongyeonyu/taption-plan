import SwiftUI

/// 그림 위 글자 칸(연도·메모). 숫자는 그림에 굽지 않고 앱이 그 해 숫자를 그린다. 해가 바뀌면 위에서 아래로 굴러 내려온다.
public struct SeasonPackTextSlotView: View {
    private let slot: SeasonPackManifest.TextSlot
    private let packID: String
    private let text: String
    private let year: Int
    private let defaults: SeasonPackDefaults
    @State private var rolling: SeasonPackYearRoll?
    @State private var progress: Double = 1

    public init(slot: SeasonPackManifest.TextSlot, packID: String, year: Int, memoLine: String? = nil, defaults: SeasonPackDefaults = SeasonPackDefaults()) {
        self.slot = slot; self.packID = packID; self.year = year; self.defaults = defaults
        text = SeasonPackTextSlots.text(for: slot, year: year, memoLine: memoLine)
    }

    private var storageKey: String { "seasonPack.shownYear.\(packID).\(slot.id)" }

    public var body: some View {
        GeometryReader { proxy in
            let rect = slot.rect.count == 4 ? slot.rect : [0, 0, 1, 1]
            let frame = CGRect(x: rect[0] * proxy.size.width, y: rect[1] * proxy.size.height, width: rect[2] * proxy.size.width, height: rect[3] * proxy.size.height)
            ZStack {
                if let rolling, rolling.needsRoll, let from = rolling.from {
                    label(String(from)).offset(y: progress * frame.height).opacity(1 - progress)
                    label(String(rolling.to)).offset(y: (progress - 1) * frame.height).opacity(progress)
                } else {
                    label(text)
                }
            }
            .frame(width: frame.width, height: frame.height)
            .clipped()
            .position(x: frame.midX, y: frame.midY)
        }
        .allowsHitTesting(false)
        .task(id: year) { await rollIfNeeded() }
    }

    private func label(_ value: String) -> some View {
        Text(value)
            .font(.system(size: slot.font?.size ?? 16, weight: Self.weight(slot.font?.weight), design: Self.design(slot.font?.design)))
            .monospacedDigit()
            .foregroundStyle(Color(seasonHex: slot.color ?? "#FFFFFF"))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private func rollIfNeeded() async {
        guard slot.content == "year" else { return }
        let shown = defaults.string(storageKey).flatMap(Int.init)
        let plan = SeasonPackYearRoll.plan(shownYear: shown, currentYear: year)
        defaults.set(String(year), storageKey)
        guard plan.needsRoll, slot.transition == "roll" else { return }
        rolling = plan
        progress = 0
        withAnimation(.easeInOut(duration: 0.9)) { progress = 1 }
        try? await Task.sleep(for: .seconds(1))
        rolling = nil
    }

    static func weight(_ name: String?) -> Font.Weight {
        switch name {
        case "bold": .bold
        case "semibold": .semibold
        case "heavy": .heavy
        case "black": .black
        case "light": .light
        case "medium": .medium
        default: .regular
        }
    }

    static func design(_ name: String?) -> Font.Design {
        switch name {
        case "rounded": .rounded
        case "serif": .serif
        case "monospaced": .monospaced
        default: .default
        }
    }
}

extension Color {
    init(seasonHex hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
