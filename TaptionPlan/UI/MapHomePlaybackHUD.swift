import SwiftUI

/// 재생 중임을 화면이 말하게 하는 얇은 진행 바.
///
/// 지금까지는 44pt 시간 레일의 분홍 칩 하나가 재생 중이라는 사실을 알리는 전부였다.
/// 이 띠는 현재 시각·배속·남은 시간과 하루 중 위치를 한 줄로 보여 주고,
/// 손가락 입력은 받지 않아 지도 제스처를 막지 않는다.
struct MapHomePlaybackHUD: View {
    /// 지금 재생 시각(자정부터의 분). 소수점을 유지해 진행 바가 부드럽게 흐른다.
    let minute: Double
    /// 재생이 끝나는 분(오늘이면 지금 시각, 지난 날이면 1440).
    let endMinute: Double
    let language: MapHomeLanguage

    private var progress: Double {
        guard endMinute > 0 else { return 0 }
        return min(1, max(0, minute / endMinute))
    }

    private var clockText: String {
        let total = Int(minute.rounded(.down))
        return String(format: "%02d:%02d", (total / 60) % 24, total % 60)
    }

    /// 배속은 정책값 그대로 적는다. 하루를 24초에 지나가므로 이동 구간은 초당 2.5분,
    /// 정지 구간은 초당 120분이다(프레임마다 구간을 다시 계산하지 않도록 한 값만 보여 준다).
    private var speedText: String {
        let seconds = Int(MapHomeDayPlaybackMath.durationSeconds.rounded())
        return language.text("하루 \(seconds)초", "full day in \(seconds)s")
    }

    private var remainingText: String {
        let minutes = max(0, Int((endMinute - minute).rounded()))
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return language.text("\(rest)분 남음", "\(rest) min left") }
        if rest == 0 { return language.text("\(hours)시간 남음", "\(hours) h left") }
        return language.text("\(hours)시간 \(rest)분 남음", "\(hours) h \(rest) min left")
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(clockText)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.tpInk)
                Text(speedText)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
                Spacer(minLength: 4)
                Text(remainingText)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.tpSecondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.tpLine.opacity(0.55))
                    Capsule()
                        .fill(Color.tpAccent)
                        .frame(width: max(2, proxy.size.width * progress))
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tpSurface.opacity(0.96), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.tpLine.opacity(0.8), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            language.text(
                "재생 중 \(clockText), \(speedText), \(remainingText)",
                "Playing \(clockText), \(speedText), \(remainingText)"
            )
        )
    }
}
