import SwiftUI

/// AI 연결을 건너뛴 사람에게 「AI로 만들기」 창에서 딱 한 번 알려 준다(AIT1116A01).
/// 닫거나 눌러서 한 번 보이면 다시 보이지 않는다. 이미 연결했으면 보이지 않는다.
enum AIConnectNudgePolicy {
    static let shownKey = "aiConnectNudgeShown"

    static func shouldShow(isConnected: Bool, alreadyShown: Bool) -> Bool {
        !isConnected && !alreadyShown
    }

    static func alreadyShown(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: shownKey) }
    static func markShown(defaults: UserDefaults = .standard) { defaults.set(true, forKey: shownKey) }
}

struct AIConnectNudgeBanner: View {
    let language: MapHomeLanguage
    let onConnect: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Color.tpAccent).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(language.text("AI를 연결하면 대화로 짠 일정이 이 앱에 바로 와요", "Connect an AI and plans you chat out arrive here directly"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button(language.text("AI 연결하기", "Connect an AI"), action: onConnect)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .bold))
                    .foregroundStyle(Color.tpAccent)
                    .buttonStyle(.plain)
                    .frame(minHeight: 32)
                    .accessibilityIdentifier("aiConnectNudgeConnect")
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) { Image(systemName: "xmark").frame(width: 32, height: 44) }
                .buttonStyle(.plain)
                .foregroundStyle(Color.tpSecondary)
                .accessibilityLabel(language.text("닫기", "Close"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
        .accessibilityIdentifier("aiConnectNudge")
    }
}

/// 「AI로 만들기」 창 맨 위에 붙이는 한 줄. 연결 상태를 한 번 읽고, 보인 뒤에는 다시 안 보인다.
struct AIConnectNudgeSlot: View {
    let model: AppModel
    let language: MapHomeLanguage

    @State private var isVisible = false
    @State private var isConnectPresented = false
    @State private var store = AssistantConnectionStore()

    var body: some View {
        Group {
            if isVisible {
                AIConnectNudgeBanner(language: language, onConnect: { isConnectPresented = true }, onDismiss: hide)
            }
        }
        .task {
            guard TripRelay.isAvailable, !AIConnectNudgePolicy.alreadyShown() else { return }
            await store.reload()
            let connected = AssistantProviderConnections.hasAny(store)
            if AIConnectNudgePolicy.shouldShow(isConnected: connected, alreadyShown: false) {
                AIConnectNudgePolicy.markShown()
                isVisible = true
            }
        }
        .sheet(isPresented: $isConnectPresented, onDismiss: hide) {
            AssistantSettingsView(model: model, language: language)
                .presentationDetents([.medium, .large])
        }
    }

    private func hide() { if isVisible { withAnimation(.snappy) { isVisible = false } } }
}

@MainActor
enum AssistantProviderConnections {
    /// 지원하는 AI 중 하나라도 연결돼 있는가.
    static func hasAny(_ store: AssistantConnectionStore) -> Bool {
        AssistantAIProvider.allCases.contains { store.isConnected($0) }
    }
}
