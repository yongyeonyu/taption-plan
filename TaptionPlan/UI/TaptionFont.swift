import os
import SwiftUI
import UIKit

/// 앱 글꼴. 메뉴 > 화면에서 고른다(대표 결정, UIK1102A01). 라이선스는 `Fonts/Fonts-OFL.txt`.
/// 위젯·워치는 시스템 글꼴을 그대로 쓴다.
enum TaptionFont: String, CaseIterable, Identifiable, Sendable {
    case jua, suit, pretendard, sunflower

    static let storageKey = "taptionFontFamily"
    private static let cached = OSAllocatedUnfairLock<TaptionFont?>(initialState: nil)

    var id: String { rawValue }

    /// 번역 언어의 글꼴. 넣어 둔 글꼴은 한국어·영어용이라 악센트나 해당 문자가 빠져 있다.
    enum PackScript { case selected, latinFallback, system }

    static let packScript: PackScript = {
        guard let code = UITextPack.activeLanguageCode else { return .selected }
        let language = code.split(separator: "-").first.map(String.init) ?? code
        return ["ja", "zh", "th", "hi"].contains(language) ? .system : .latinFallback
    }()

    /// 글꼴을 고를 수 있는 언어인지. 번역 언어는 위 규칙이 정한다.
    static var isUserSelectable: Bool { packScript == .selected }

    /// 본문이 프레임마다 읽을 수 있어 처음 한 번만 설정을 읽는다.
    static var current: TaptionFont {
        cached.withLock { value in
            if let value { return value }
            let stored = UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .jua
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
        switch TaptionFont.packScript {
        case .selected: .custom(TaptionFont.current.name(for: weight), fixedSize: size)
        case .latinFallback: .custom(TaptionFont.pretendard.name(for: weight), fixedSize: size)
        case .system: .system(size: size, weight: weight)
        }
    }
}

extension Font {
    /// 시스템 글자 모양(`.caption`·`.footnote`·`.headline` 등)을 앱 글꼴로(FNT1111A01). 시스템 모양을 직접 쓰면
    /// 메뉴에서 글꼴을 바꿔도 그 글자만 시스템 글꼴로 남는다.
    static func taptionStyle(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        let size: CGFloat = switch style {
        case .caption2: 11
        case .caption: 12
        case .footnote: 13
        case .subheadline: 14
        case .headline: 17
        case .title3: 20
        case .title2: 22
        default: 15
        }
        return .taptionFixed(size: TaptionType.scaled(TaptionType.snapped(size)), weight: weight ?? (style == .headline ? .semibold : .regular))
    }
}

/// 글꼴을 고르면 화면을 다시 만들어 모든 글자에 바로 적용한다.
struct TaptionFontRoot<Content: View>: View {
    @AppStorage(TaptionFont.storageKey) private var selection = TaptionFont.jua.rawValue
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.taptionFixed(size: 17))
            .id(selection)
            // 단축어 앱에 「결제 문자 넣기」가 보이도록 첫 화면 뒤에 시스템에 다시 알린다(시작 경로에서 빼냄, 리뷰).
            .task { BokkiShortcuts.updateAppShortcutParameters() }
    }
}

/// 메뉴의 글꼴 고르기 행. 각 항목은 자기 글꼴로 보여 준다.
struct TaptionFontMenuRow: View {
    let language: MapHomeLanguage
    @AppStorage(TaptionFont.storageKey) private var selection = TaptionFont.jua.rawValue

    private var current: TaptionFont { TaptionFont(rawValue: selection) ?? .jua }

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
            .modifier(MapHomeMenuRowPadding())
            .padding(.horizontal, 12)
        }
        .accessibilityLabel(language.text("글꼴 선택", "Choose font"))
    }
}
