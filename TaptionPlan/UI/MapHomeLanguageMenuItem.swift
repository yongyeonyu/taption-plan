import SwiftUI
import TaptionPlanCore

/// 메뉴의 언어 고르기.
struct MapHomeLanguageMenuItem: View {
    let language: MapHomeLanguage
    let onChange: () -> Void

    @AppStorage(
        AppLanguagePreference.sharedDefaultsKey,
        store: UserDefaults(suiteName: AppLanguagePreference.appGroupIdentifier)
    ) private var languageRawValue = AppLanguagePreference.current.rawValue

    private var languagePreference: AppLanguagePreference {
        AppLanguagePreference(rawValue: languageRawValue) ?? .automatic
    }

    var body: some View {
        Menu {
            ForEach(AppLanguagePreference.allCases) { option in
                Button {
                    guard languageRawValue != option.rawValue else { return }
                    languageRawValue = option.rawValue
                    AppLanguagePreference.save(option)
                    onChange()
                } label: {
                    if option == languagePreference {
                        Label(
                            languagePreferenceTitle(option),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(languagePreferenceTitle(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 13) {
                MapHomeMenuIconChip(systemImage: "globe", tint: .tpMenuChip("#4E9C8F"))
                Text(language.text("언어", "Language"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .semibold))
                Spacer()
                Text(languagePreferenceTitle(languagePreference))
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
        .accessibilityLabel(language.text("언어 선택", "Choose language"))
    }

    private func languagePreferenceTitle(
        _ preference: AppLanguagePreference
    ) -> String {
        // 언어 이름은 그 언어 글자로 보여 준다. 지금 언어를 못 읽어도 찾을 수 있어야 한다.
        preference == .automatic ? language.text("자동", "Automatic") : preference.displayName
    }
}
