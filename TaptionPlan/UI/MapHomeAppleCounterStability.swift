import CoreText
import SwiftUI
import UIKit

/// Apple 지도 재생에서 화랑이·카운터를 화면에 놓는 자리(CTR1103A02).
///
/// 재생 카메라는 매 프레임 화랑이를 표적점에 놓으므로, 되읽은 점이 허용 오차 안이면 표적점에 고정해
/// 재생 중 `center` 쓰기 자체를 없앤다. 그 밖에는 실제 점을 픽셀에 맞춰 마커의 자식인 카운터 글자가
/// 소수점 위치로 합성되지 않게 한다. 시뮬레이터(기울기 0)에서 되읽은 오차는 0.00004pt였고,
/// 실제 렌더링 중 오차는 기기에서 확인해야 한다.
enum MapHomeAppleMarkerPlacement {
    /// 이보다 멀면 카메라가 표적점에 놓지 못한 것이므로(지도 가장자리 제한 등) 실제 점을 따른다.
    static let lockTolerance: CGFloat = 6

    static func center(
        actual: CGPoint,
        lockTarget: CGPoint?,
        offset: CGPoint,
        size: CGSize,
        scale: CGFloat
    ) -> CGPoint {
        let base: CGPoint
        if let lockTarget, hypot(actual.x - lockTarget.x, actual.y - lockTarget.y) <= lockTolerance {
            base = lockTarget
        } else {
            base = actual
        }
        return CGPoint(
            x: aligned(base.x + offset.x, length: size.width, scale: scale),
            y: aligned(base.y + offset.y, length: size.height, scale: scale)
        )
    }

    /// 뷰의 원점이 기기 픽셀에 오도록 중심을 맞춘다.
    private static func aligned(_ center: CGFloat, length: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return center }
        return ((center - length / 2) * scale).rounded() / scale + length / 2
    }
}

/// 카운터 숫자의 칸 폭을 고정한다(CTR1103A02).
///
/// 기본 글꼴 주아는 숫자 폭이 제각각(11pt에서 `1`은 4.52, `4`는 6.91)이고 고정폭 기능도 없어
/// `.monospacedDigit()`이 아무 일도 하지 않는다. 그래서 0.25초마다 값이 바뀔 때 글자가 좌우로 흔들렸다.
/// 그런 글꼴에서만 숫자 뒤에 자간을 넣어 모든 숫자를 가장 넓은 숫자의 폭으로 맞춘다.
enum MapHomeCounterDigits {
    /// 숫자별로 더할 자간. 폭이 같거나 비어 있으면 빈 값이다.
    static func kerns(digitWidths: [Character: CGFloat]) -> [Character: CGFloat] {
        guard let widest = digitWidths.values.max() else { return [:] }
        return digitWidths.compactMapValues { widest - $0 > 0.001 ? widest - $0 : nil }
    }

    static func attributed(_ text: String, kerns: [Character: CGFloat]) -> AttributedString {
        var result = AttributedString(text)
        guard !kerns.isEmpty else { return result }
        for index in result.characters.indices {
            guard let kern = kerns[result.characters[index]] else { continue }
            result[index..<result.characters.index(after: index)].swiftUI.kern = kern
        }
        return result
    }

    /// 글꼴이 스스로 고정폭 숫자를 낼 수 있으면 자간을 넣지 않는다. 시스템 글꼴을 쓰는 언어도 같다.
    @MainActor
    static func kerns(fontName: String?, size: CGFloat) -> [Character: CGFloat] {
        guard let fontName else { return [:] }
        let key = "\(fontName)|\(size)"
        if let cached = cache[key] { return cached }
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let measured = hasNumberSpacing(font) ? [:] : kerns(digitWidths: digitWidths(of: font))
        cache[key] = measured
        return measured
    }

    @MainActor
    static func attributed(_ text: String, size: CGFloat, weight: Font.Weight) -> AttributedString {
        attributed(text, kerns: kerns(fontName: fixedFontName(weight: weight), size: size))
    }

    /// 글꼴 넷·글자 크기 몇 가지뿐이라 상한 없이 둔다.
    @MainActor private static var cache: [String: [Character: CGFloat]] = [:]
    private static let numberSpacingFeature = 6

    private static func fixedFontName(weight: Font.Weight) -> String? {
        switch TaptionFont.packScript {
        case .selected: TaptionFont.current.name(for: weight)
        case .latinFallback: TaptionFont.pretendard.name(for: weight)
        case .system: nil
        }
    }

    private static func hasNumberSpacing(_ font: CTFont) -> Bool {
        let features = CTFontCopyFeatures(font) as? [[String: Any]] ?? []
        return features.contains {
            ($0[kCTFontFeatureTypeIdentifierKey as String] as? Int) == numberSpacingFeature
        }
    }

    private static func digitWidths(of font: CTFont) -> [Character: CGFloat] {
        var widths: [Character: CGFloat] = [:]
        for digit in "0123456789" {
            var unit = digit.utf16.first ?? 0
            var glyph: CGGlyph = 0
            guard CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1) else { continue }
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            widths[digit] = advance.width
        }
        return widths
    }
}
