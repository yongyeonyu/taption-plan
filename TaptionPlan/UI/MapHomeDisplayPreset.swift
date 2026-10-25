import SwiftUI

/// 메뉴 > 표시 맨 위에 두는 지도 프리셋 행.
///
/// 스타일 여섯 가지를 이름으로만 늘어놓으면 "실외에서 도로가 보이게" 하려는 사람이
/// 어느 것을 골라야 하는지 알 수 없다. 상황 하나를 한 번에 켜고 끄게 둔다.
struct MapHomeDisplayPresetRow: View {
    /// 지금 고대비(실외) 스타일인지.
    let isOutdoor: Bool
    let language: MapHomeLanguage
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Label(
                    language.text("실외에서 보기", "Outdoor mode"),
                    systemImage: "sun.max.fill"
                )
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold, design: .rounded))
                .foregroundStyle(Color.tpInk)
                Spacer(minLength: 4)
                if isOutdoor {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
                        .foregroundStyle(Color.tpAccent)
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.text("실외에서 보기, 고대비 지도", "Outdoor mode, high contrast map"))
        .accessibilityAddTraits(isOutdoor ? .isSelected : [])
    }
}
