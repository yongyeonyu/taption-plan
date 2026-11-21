import SwiftUI

/// 앱을 열 때 묻는 고르기 질문의 앱 시트(대표 지시 2026-11-21). 시스템 회색 확인 대화상자 대신 달력 시트와 같은 크림 배경,
/// 앱 카드 모양의 줄, 분류 색·아이콘으로 보인다. 고르면 `action`이 불리고, 시트 밖을 쓸어 내리면 「나중에 확인」과 같다.
struct LaunchChoiceOption: Identifiable {
    enum Kind { case normal, suggested, quiet }

    var id: String
    var title: String
    var systemImage: String?
    var tint: Color?
    var kind: Kind = .normal
    /// 다음 단계가 이어질 때 오른쪽에 「›」를 둔다.
    var showsChevron = false
    var action: () -> Void
}

struct LaunchChoiceSheet: View {
    let title: String
    var message: String?
    let options: [LaunchChoiceOption]
    let laterTitle: String
    let onLater: () -> Void

    private var primary: [LaunchChoiceOption] { options.filter { $0.kind != .quiet } }
    private var quiet: [LaunchChoiceOption] { options.filter { $0.kind == .quiet } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.taptionStyle(.title3, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message, !message.isEmpty {
                        Text(message)
                            .font(.taptionStyle(.subheadline))
                            .foregroundStyle(Color.tpSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(spacing: 8) {
                    ForEach(primary) { option in
                        Button(action: option.action) { LaunchChoiceRow(option: option) }
                            .buttonStyle(LaunchChoicePressStyle())
                    }
                }
                if !quiet.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(quiet) { option in
                            Button(action: option.action) { LaunchChoiceRow(option: option) }
                                .buttonStyle(LaunchChoicePressStyle())
                        }
                    }
                }
                Button(action: onLater) {
                    Text(laterTitle)
                        .font(.taptionStyle(.subheadline, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                        .frame(maxWidth: .infinity, minHeight: TaptionControl.primary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 12)
        }
        .background(Color.tpBackground)
        .tint(Color.tpAccent)
    }
}

private struct LaunchChoiceRow: View {
    let option: LaunchChoiceOption

    var body: some View {
        let accent = option.tint ?? Color.tpAccent
        let isSuggested = option.kind == .suggested
        HStack(spacing: 12) {
            if let image = option.systemImage {
                Image(systemName: image)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 32, height: 32)
                    .background(accent.opacity(0.16), in: Circle())
                    .accessibilityHidden(true)
            }
            Text(option.title)
                .font(.taptionStyle(.body, weight: .semibold))
                .foregroundStyle(option.kind == .quiet ? Color.tpSecondary : Color.tpInk)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: option.kind == .quiet ? .center : .leading)
            if option.showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: TaptionControl.primary + 4)
        .background(
            isSuggested ? accent.opacity(0.12) : Color.tpSurface,
            in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous)
                .stroke(isSuggested ? accent : Color.tpLine.opacity(0.68), lineWidth: isSuggested ? 1.2 : 0.7)
        }
        .contentShape(RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
    }
}

/// 누르는 동안 살짝 작아지고 흐려진다(앱 단추와 같은 반응).
private struct LaunchChoicePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

extension View {
    /// 앱 스타일 고르기 시트. 시트 밖으로 닫으면 `onLater`가 불린다(고른 뒤 프로그램이 닫을 때는 불리지 않는다).
    func launchChoiceSheet(
        isPresented: Binding<Bool>,
        title: String,
        message: String? = nil,
        options: [LaunchChoiceOption],
        laterTitle: String,
        onLater: @escaping () -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            LaunchChoiceSheet(title: title, message: message, options: options, laterTitle: laterTitle, onLater: onLater)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color.tpBackground)
                .presentationCornerRadius(TaptionCorner.sheet)
        }
    }
}
