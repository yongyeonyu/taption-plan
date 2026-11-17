import SwiftUI

/// 「공통 규칙」(SRL1116A01): 운영자가 검토해 서명한 규칙을 서버에서 받아 쓴다. 전체·규칙별로 끌 수 있다.
/// 약관·개인정보처리방침 문구는 초안이며 최종 확정은 대표가 한다(`PRIVACY.md`, `TERMS.md`).
struct SharedRulesView: View {
    let language: MapHomeLanguage
    @State private var receiving = SharedRuleStore.isReceiving()
    @State private var rules: [Rule] = []
    @State private var off: Set<String> = []

    var body: some View {
        List {
            Section {
                Toggle(language.text("공통 규칙 받기", "Receive shared rules"), isOn: Binding(get: { receiving }, set: { on in
                    receiving = on
                    SharedRuleStore.setReceiving(on)
                    if on { Task { await SharedRuleStore.sync(force: true); reload() } }
                }))
            } footer: {
                Text(language.text("운영자가 확인한 규칙(문자·알림 읽기, 가게 분류 등)을 서버에서 내려받아 써요. 내가 정한 규칙과 내 AI가 만든 규칙이 먼저예요. 내려받기만 하고 내 정보는 보내지 않아요.",
                                   "Rules checked by the operator (reading texts and alerts, shop categories, …) are downloaded and used. Your own rules and your AI's rules come first. This only downloads; nothing about you is sent."))
            }
            .listRowBackground(Color.tpSurface)
            Section {
                Text(language.text("""
                    • 받기: 하루 한 번 서버에서 내려받아요. 내 기록·문자·위치는 보내지 않아요.
                    • 보내기(AI 연결 화면, 기본 꺼짐): 켠 경우에만 내 AI가 만든 규칙의 조건과 분류를, 개인 정보를 지워 운영자에게 보내요. 받은 글 원문·금액·이름·계좌·위치·내가 정한 규칙은 보내지 않아요.
                    • 서버는 후보마다 몇 대에서 올라왔는지와 날짜만 세요. 같은 규칙을 두 번 세지 않도록 내가 보낸 규칙의 지문(규칙 내용으로 만든 짧은 값, 기기를 알아볼 수 없어요)만 내 서버 자리에 남기고, 후보에는 누가 보냈는지 적지 않아요. 후보는 90일 뒤 지워요.
                    • 운영자가 직접 확인해 승인한 것만 모든 사용자의 공통 규칙이 돼요. 승인 전에는 아무에게도 가지 않아요.
                    (초안 · 확정 전, 자세한 내용은 개인정보처리방침)
                    """, """
                    • Receiving: downloaded from the server once a day. Your records, texts and location are not sent.
                    • Sending (AI connections screen, off by default): only if you turn it on, the conditions and categories of rules your AI made are sent to the operator with personal details removed. Original texts, amounts, names, accounts, locations and rules you set yourself are never sent.
                    • For each candidate the server only counts how many devices and which day. So the same rule isn't counted twice, it keeps a fingerprint of the rules you sent (a short value made from the rule that can't identify your device) in your own space on the server; candidates don't record who sent them. Candidates are deleted after 90 days.
                    • Only what the operator reviews and approves becomes a shared rule for everyone. Nothing goes out before approval.
                    (Draft · not final; see the privacy policy for details)
                    """))
                .font(.taptionStyle(.footnote)).foregroundStyle(.secondary)
            } header: {
                Text(language.text("개인정보 처리 요약", "Privacy summary"))
            }
            .listRowBackground(Color.tpSurface)
            Section {
                if rules.isEmpty { Text(language.text("받은 공통 규칙이 아직 없어요.", "No shared rules yet.")).foregroundStyle(.secondary) }
                ForEach(rules) { rule in
                    Toggle(isOn: Binding(get: { !off.contains(rule.id) }, set: { on in
                        SharedRuleStore.setEnabled(rule.id, on)
                        reload()
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AssistantRuleListView.title(rule.type, language)).font(.taptionStyle(.subheadline, weight: .semibold))
                            Text(verbatim: AssistantRuleListView.summary(rule)).font(.taptionStyle(.footnote)).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            } footer: {
                if let version = SharedRuleStore.stored()?.version {
                    Text(language.text("공통 규칙 버전 \(version)", "Shared rules version \(version)"))
                }
            }
            .listRowBackground(Color.tpSurface)
        }
        .tpListStyle()
        .font(.taptionStyle(.subheadline))
        .navigationTitle(language.text("공통 규칙", "Shared rules"))
        .task {
            reload()
            await SharedRuleStore.sync(force: true)
            reload()
        }
    }

    private func reload() {
        receiving = SharedRuleStore.isReceiving()
        rules = SharedRuleStore.all()
        off = SharedRuleStore.disabledIDs()
    }
}

/// AI 연결 화면의 「공통 규칙에 보태기」 동의(기본 꺼짐, 대표 결정 2026-11-16). 켜도 올리는 것은 규칙의 조건·분류뿐이다.
struct SharedRulesContributeSection: View {
    let language: MapHomeLanguage
    @State private var on = SharedRuleStore.isContributing()

    var body: some View {
        Section {
            Toggle(language.text("내 AI가 만든 규칙을 공통 규칙 후보로 보내기", "Send my AI's rules as shared-rule candidates"), isOn: Binding(get: { on }, set: { value in
                on = value
                SharedRuleStore.setContributing(value)
                if value { Task { await SharedRuleStore.uploadCandidates() } }
            }))
        } footer: {
            Text(language.text("""
                켜면 내 AI가 만든 규칙 가운데 결제 문자·알림 읽기, 가게 분류, 영수증 판정만 개인 정보를 지운 조건과 분류로 운영자에게 보내요. \
                받은 글 원문, 금액, 이름, 계좌, 위치, 내가 정한 규칙은 보내지 않아요. 운영자가 확인해 쓸 만한 것만 모든 사용자의 공통 규칙으로 내보내요. \
                언제든 끌 수 있고, 이미 보낸 것은 지워 달라고 요청할 수 있어요. (초안)
                """, """
                When on, only the conditions and categories of rules your AI made for reading payment texts and alerts, shop categories and receipt checks are sent to the operator, with personal details removed. \
                Original texts, amounts, names, accounts, locations and rules you set yourself are never sent. Only what the operator reviews and approves becomes a shared rule for everyone. \
                You can turn it off anytime and ask for what was sent to be deleted. (Draft)
                """))
        }
        .listRowBackground(Color.tpSurface)
    }
}
