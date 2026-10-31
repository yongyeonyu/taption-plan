import SwiftUI

/// 클립 편집기 아래쪽 도구 단추.
///
/// 예전에는 아이콘만 있어서 무엇을 하는 단추인지 눌러 봐야 알았다.
/// 이름을 아이콘 아래에 붙이고, 손가락이 닿는 높이를 44pt로 맞춘다.
struct NLEToolButton: View {
    let systemImage: String
    let title: String
    let isEnabled: Bool
    /// 되돌리기·다시처럼 '지금 쓸 수 있는지'가 중요한 단추는 켜졌을 때 색을 준다.
    var isHighlighted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
                Text(title)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(isHighlighted && isEnabled ? Color.tpAccent : Color.tpInk)
            .frame(minWidth: 44, minHeight: TaptionMenuMetrics.minimumHitSize)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.38)
        .accessibilityLabel(title)
    }
}

/// 확대 단계.
///
/// 하루 전체를 한눈에 보면 1시간짜리 클립도 몇 pt밖에 안 되어 경계를 잡을 수 없다.
/// 경계를 잡으려면 두 손가락으로 벌려야 하는데, 그 사실을 모르면 편집이 막힌다.
/// 그래서 '전체 → 4배 → 12배 → 전체'를 한 단추에서 돌린다.
enum NLEZoomPolicy {
    static let levels: [CGFloat] = [1, 4, 12]
    /// 1분을 손가락으로 잡을 수 있는 줄 높이(분당 pt). 단추의 마지막 단계다.
    static let minuteEditHeight: CGFloat = 32
    /// 두 손가락으로 벌릴 수 있는 최대 줄 높이(분당 pt).
    static let maxMinuteHeight: CGFloat = 48

    /// 하루 24시간이 화면 높이에 딱 들어가는 배율.
    static func fitMinuteHeight(height: CGFloat) -> CGFloat {
        max(0.22, height / CGFloat(NLETrack.dayMinutes))
    }

    /// 지금 배율에서 다음에 갈 배율. 배율은 '하루 전체 대비'다. 마지막 단계는 1분 편집 배율이다.
    static func nextLevel(currentMinuteHeight: CGFloat, fitMinuteHeight: CGFloat) -> CGFloat {
        guard fitMinuteHeight > 0.01, currentMinuteHeight.isFinite else { return 4 }
        let ratio = currentMinuteHeight / fitMinuteHeight
        let steps = levels + [minuteEditHeight / fitMinuteHeight]
        return steps.first { $0 > ratio * 1.15 } ?? 1
    }

    /// 다음 단추에 적을 이름. 이미 가장 크게 벌려 있으면 '전체'로 돌아간다.
    static func nextTitle(
        currentMinuteHeight: CGFloat,
        fitMinuteHeight: CGFloat,
        language: MapHomeLanguage
    ) -> String {
        switch nextLevel(currentMinuteHeight: currentMinuteHeight, fitMinuteHeight: fitMinuteHeight) {
        case 1: return language.text("전체", "Fit")
        case 4: return language.text("확대", "Zoom")
        case 12: return language.text("더 확대", "Zoom+")
        default: return language.text("1분", "1 min")
        }
    }

    /// 지금 화면이 하루 전체를 담고 있는가.
    static func isFitted(currentMinuteHeight: CGFloat, fitMinuteHeight: CGFloat) -> Bool {
        currentMinuteHeight <= fitMinuteHeight * 1.2
    }
}
