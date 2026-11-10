import SwiftUI

/// 처음 실행 튜토리얼 「AI 연결」 단계(AIR1110A04). 「AI 연결」 메뉴와 같은 줄·배지를 쓰고,
/// 「연결」은 같은 AI별 연결 화면을 시트로 띄운 뒤 이 단계로 돌아온다.
struct FirstRunAIConnectPage: View {
    let language: MapHomeLanguage

    @State private var store = AssistantConnectionStore()
    @State private var selected: AssistantAIProvider?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 0) {
                    ForEach(AssistantAIProvider.featured) { provider in
                        AssistantProviderRow(provider: provider, language: language, isConnected: store.isConnected(provider)) {
                            selected = provider
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        if provider != AssistantAIProvider.featured.last { Divider().padding(.leading, 14) }
                    }
                }
                .background(Color.tpCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(AssistantAIProvider.planFootnote(language))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            }
            .padding(18)
        }
        .accessibilityIdentifier("firstRunAIConnect")
        .task { if TripRelay.isAvailable { await store.reload() } }
        .sheet(item: $selected, onDismiss: { Task { await store.reload() } }) { provider in
            NavigationStack {
                AssistantProviderView(provider: provider, language: language, store: store)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button(language.text("완료", "Done")) { selected = nil } }
                    }
            }
        }
    }
}
