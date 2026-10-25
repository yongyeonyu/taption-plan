import SwiftUI

/// 달력 지표 칩에 붙는 값 한 줄.
///
/// 칩이 이름만 보여 주면 "무엇을 볼 수 있는지"만 알 뿐 "오늘 얼마였는지"는 알 수 없다.
/// 시간·거리·개수를 같은 규칙으로 적어, 칩을 누르기 전에 값부터 읽히게 한다.
enum MapHomeCalendarChipValue {
    static func text(
        kind: MapHomeCalendarTimeKind,
        value: TimeInterval,
        language: MapHomeLanguage
    ) -> String? {
        guard value.isFinite, value > 0 else { return nil }
        if kind.isCount {
            return MapHomeCalendarTimeTotalsPolicy.countText(count: value, kind: kind, language: language)
        }
        if kind.isDistance {
            return MapHomeCalendarTimeTotalsPolicy.distanceText(meters: value)
        }
        return MapHomeCalendarTimeTotalsPolicy.durationText(seconds: value, language: language)
    }
}
