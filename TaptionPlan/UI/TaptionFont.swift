import os
import SwiftUI
import UIKit

/// 앱 글꼴. 메뉴 > 화면에서 고른다(대표 결정, UIK1102A01). 라이선스는 `Fonts/Fonts-OFL.txt`.
/// 위젯·워치는 시스템 글꼴을 그대로 쓴다.
enum TaptionFont: String, CaseIterable, Identifiable, Sendable {
    case suit, pretendard, sunflower, jua

    static let storageKey = "taptionFontFamily"
    private static let cached = OSAllocatedUnfairLock<TaptionFont?>(initialState: nil)

    var id: String { rawValue }

    /// 본문이 프레임마다 읽을 수 있어 처음 한 번만 설정을 읽는다.
    static var current: TaptionFont {
        cached.withLock { value in
            if let value { return value }
            let stored = UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .suit
            value = stored
            return stored
        }
    }

    static func select(_ font: TaptionFont) {
        cached.withLock { $0 = font }
        UserDefaults.standard.set(font.rawValue, forKey: storageKey)
    }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .suit: language.text("스위트", "SUIT")
        case .pretendard: language.text("프리텐다드", "Pretendard")
        case .sunflower: language.text("선플라워", "Sunflower")
        case .jua: language.text("주아", "Jua")
        }
    }

    func name(for weight: Font.Weight) -> String {
        switch self {
        case .suit:
            switch weight {
            case .black, .heavy: "SUIT-ExtraBold"
            case .bold: "SUIT-Bold"
            case .semibold: "SUIT-SemiBold"
            case .medium: "SUIT-Medium"
            default: "SUIT-Regular"
            }
        case .pretendard:
            switch weight {
            case .black, .heavy, .bold: "Pretendard-Bold"
            case .semibold: "Pretendard-SemiBold"
            default: "Pretendard-Regular"
            }
        case .sunflower:
            switch weight {
            case .black, .heavy, .bold, .semibold: "Sunflower-Bold"
            default: "Sunflower-Medium"
            }
        case .jua:
            "Jua-Regular"
        }
    }
}

extension Font {
    /// `Font.system(size:)`처럼 고정 크기다. 앱의 글자 크기는 `TaptionType.scaled`가 정한다.
    static func taptionFixed(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(TaptionFont.current.name(for: weight), fixedSize: size)
    }
}

/// 글꼴을 고르면 화면을 다시 만들어 모든 글자에 바로 적용한다.
struct TaptionFontRoot<Content: View>: View {
    @AppStorage(TaptionFont.storageKey) private var selection = TaptionFont.suit.rawValue
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.taptionFixed(size: 17))
            .id(selection)
    }
}

/// 메뉴의 글꼴 고르기 행. 각 항목은 자기 글꼴로 보여 준다.
struct TaptionFontMenuRow: View {
    let language: MapHomeLanguage
    @AppStorage(TaptionFont.storageKey) private var selection = TaptionFont.suit.rawValue

    private var current: TaptionFont { TaptionFont(rawValue: selection) ?? .suit }

    var body: some View {
        Menu {
            ForEach(TaptionFont.allCases) { font in
                Button {
                    TaptionFont.select(font)
                    selection = font.rawValue
                } label: {
                    if font == current {
                        Label(font.title(language), systemImage: "checkmark")
                    } else {
                        Text(font.title(language))
                    }
                }
            }
        } label: {
            HStack(spacing: 13) {
                MapHomeMenuIconChip(systemImage: "textformat", tint: .tpMenuChip("#B5654A"))
                Text(language.text("글꼴", "Font"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                Spacer()
                Text(current.title(language))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.tpInk)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
        }
        .accessibilityLabel(language.text("글꼴 선택", "Choose font"))
    }
}
