import SwiftUI

/// 처음 실행 튜토리얼 「AI 연결」 단계(AIR1110A04, AIT1116A01에서 첫 소개 바로 뒤로·내용 교체).
/// 위: 「대화 → AI가 올림 → 앱이 보여 줌」 3컷 시연, 아래: 연결하면 되는 일 3가지.
/// 「지금 연결」·「나중에」 단추는 튜토리얼 아래쪽이 맡고, 이 화면은 설득만 한다.
struct FirstRunAIConnectPage: View {
    let language: MapHomeLanguage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AIConnectDemo(language: language)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.benefits(language), id: \.symbol) { benefit in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: benefit.symbol)
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.body), weight: .semibold))
                                .foregroundStyle(Color.tpAccent)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(benefit.title)
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.body), weight: .bold))
                                    .foregroundStyle(Color.tpInk)
                                Text(benefit.detail)
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .medium))
                                    .foregroundStyle(Color.tpSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Text(language.text("연결하지 않아도 앱은 쓸 수 있어요. 다만 이 기능들은 쓸 수 없어요. 나중에 메뉴 › 연결에서도 할 수 있어요.",
                                   "The app works without it, but these features won't. You can also connect later in Menu › Connections."))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .accessibilityIdentifier("firstRunAIConnect")
    }

    struct Benefit { let symbol: String; let title: String; let detail: String }

    /// 연결하면 되는 일 3가지(대표 지시: 줄여서 말하기).
    static func benefits(_ language: MapHomeLanguage) -> [Benefit] {
        [
            Benefit(symbol: "airplane", title: language.text("여행 일정 받기", "Get trip plans"),
                    detail: language.text("AI와 대화로 짠 일정이 일정표·지도로 바로 와요.", "Plans you chat out with an AI arrive as a schedule and map.")),
            Benefit(symbol: "wonsign.circle", title: language.text("지출·기록 정리", "Tidy spending and records"),
                    detail: language.text("못 읽은 결제 문자와 애매한 기록을 AI가 정리해 줘요.", "The AI sorts payment texts and unclear records the app couldn't read.")),
            Benefit(symbol: "pencil.line", title: language.text("일정 고치기", "Edit plans by chatting"),
                    detail: language.text("「점심을 한 시간 늦춰 줘」처럼 말하면 일정이 바뀌어요.", "Say \"push lunch back an hour\" and the plan changes.")),
        ]
    }
}

/// 3컷 시연: ① AI와 대화 ② AI가 정리해 올림 ③ 앱이 보여 줌. 컷이 바뀔 때만 그린다(2.4초마다).
struct AIConnectDemo: View {
    let language: MapHomeLanguage

    @State private var cut = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<AIConnectDemoCuts.count, id: \.self) { index in
                    Text(AIConnectDemoCuts.caption(index, language))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .bold))
                        .foregroundStyle(index == cut ? Color.white : Color.tpSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(index == cut ? Color.tpAccent : Color.tpBorder.opacity(0.25), in: Capsule())
                        .frame(maxWidth: .infinity)
                }
            }
            ZStack {
                switch cut {
                case 0: chatCut
                case 1: sendCut
                default: appCut
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .padding(12)
            .background(Color.tpBackground, in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
            .id(cut)
            .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .snappy, value: cut)
        .task {
            // 동작 줄이기를 켠 사람에게는 멈춰 둔 채 마지막 컷(결과)을 보인다.
            if reduceMotion { cut = AIConnectDemoCuts.count - 1; return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.4))
                cut = AIConnectDemoCuts.next(after: cut)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language.text("AI와 대화하고, AI가 정리해 올리면, 앱이 일정표·지도·가계부로 보여 줘요.",
                                          "Chat with an AI, it sends the result, and the app shows it as schedule, map and ledger."))
    }

    private func bubble(_ text: String, isUser: Bool) -> some View {
        Text(text)
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .medium))
            .foregroundStyle(isUser ? Color.white : Color.tpInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isUser ? Color.tpAccent : Color.tpCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var chatCut: some View {
        VStack(spacing: 8) {
            bubble(language.text("부산 1박 2일, 바다 보고 국밥 먹고 싶어", "A night in Busan — sea view and a good soup"), isUser: true)
            bubble(language.text("1일차는 해운대 산책 뒤 점심은 국밥 어때요?", "Day 1: a walk at Haeundae, then soup for lunch?"), isUser: false)
            bubble(language.text("좋아, 그렇게 짜 줘", "Great, plan it that way"), isUser: true)
        }
    }

    private var sendCut: some View {
        VStack(spacing: 10) {
            bubble(language.text("정리해서 BOKKI Plan으로 올릴게요", "I'll tidy it up and send it to BOKKI Plan"), isUser: false)
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Color.tpAccent)
                Image(systemName: "arrow.right").foregroundStyle(Color.tpSecondary)
                Image(systemName: "icloud.and.arrow.up").foregroundStyle(Color.tpAccent)
                Image(systemName: "arrow.right").foregroundStyle(Color.tpSecondary)
                Image(systemName: "iphone").foregroundStyle(Color.tpInk)
            }
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.headline), weight: .semibold))
        }
    }

    private var appCut: some View {
        VStack(spacing: 8) {
            appRow(symbol: "calendar", title: language.text("11:00 해운대 산책", "11:00 Haeundae walk"), tag: language.text("일정표", "Schedule"))
            appRow(symbol: "fork.knife", title: language.text("13:00 국밥", "13:00 Soup lunch"), tag: language.text("지도", "Map"))
            appRow(symbol: "wonsign.circle", title: language.text("예상 지출 12,000원", "Estimated ₩12,000"), tag: language.text("가계부", "Ledger"))
        }
    }

    private func appRow(symbol: String, title: String, tag: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Color.tpAccent).frame(width: 22)
            Text(title)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                .foregroundStyle(Color.tpInk)
            Spacer(minLength: 0)
            Text(tag)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .bold))
                .foregroundStyle(Color.tpSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.tpCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 시연 컷의 순서와 이름. 화면 없이 시험한다.
enum AIConnectDemoCuts {
    static let count = 3

    static func next(after cut: Int) -> Int { (cut + 1) % count }

    static func caption(_ index: Int, _ language: MapHomeLanguage) -> String {
        switch index {
        case 0: language.text("① AI와 대화", "① Chat")
        case 1: language.text("② 정리해 올림", "② AI sends")
        default: language.text("③ 앱에서 보기", "③ See it here")
        }
    }
}

/// 「지금 연결」을 누르면 뜨는 AI 고르기. 「AI 연결」 메뉴와 같은 줄·배지를 쓰고, 「연결」은 같은 AI별 연결 화면을 연다.
struct FirstRunAIProviderChooser: View {
    let language: MapHomeLanguage
    let store: AssistantConnectionStore
    let onClose: () -> Void

    @State private var selected: AssistantAIProvider?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(language.text("어떤 AI를 쓰세요?", "Which AI do you use?"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.headline), weight: .bold))
                        .foregroundStyle(Color.tpInk)
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
                    .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
                    Text(AssistantAIProvider.planFootnote(language))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .medium))
                        .foregroundStyle(Color.tpSecondary)
                }
                .padding(18)
            }
            .background(Color.tpBackground)
            .navigationDestination(item: $selected) { provider in
                AssistantProviderView(provider: provider, language: language, store: store)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(language.text("완료", "Done"), action: onClose) }
            }
            .accessibilityIdentifier("firstRunAIChooser")
        }
    }
}
