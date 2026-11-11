import AppIntents
import SwiftUI

/// 단축어·Siri 연결 안내(SHT1111A01): 결제 문자 자동, 결제 앱 알림 자동(iOS 27 「알림 › 앱 푸시」), Siri로 BOKKI Plan에 넣기.
/// 메뉴 › 연결, 가계부, 튜토리얼이 같은 내용을 쓴다.
struct BokkiShortcutsGuideSections: View {
    let language: MapHomeLanguage
    @Environment(\.openURL) private var openURL
    @State private var copied: String?

    var body: some View {
        Group {
            // 앱은 자동화를 대신 만들거나 넣어 줄 수 없다(iOS 제한). 단계를 셋으로 줄이고 열기·복사 단추를 둔다(SCA1111A01).
            guideSection(
                title: language.text("결제 문자 자동으로 넣기", "Payment texts, automatically"),
                steps: [
                    language.text("「단축어 앱 열기」 → 「자동화」 → + → 「메시지」", "Open Shortcuts → Automation → + → Message"),
                    language.text("「메시지 내용에 포함」에 복사한 「원」 붙여 넣기 → 「즉시 실행」 → 다음", "Paste the copied word into \"Message Contains\" → Run Immediately → Next"),
                    language.text("「새로운 빈 자동화」 → BOKKI Plan 「결제 문자 넣기」 → 완료", "New Blank Automation → BOKKI Plan \"Add payment text\" → Done"),
                ],
                copyText: "원",
                footer: language.text("앱이 결제 문자만 골라 가계부에 넣고, 나머지 문자는 넣지도 AI에 보내지도 않아요. 같은 결제가 문자·앱 알림으로 두 번 와도 한 번만 넣고, 연결된 AI가 가게 이름·분류를 다듬어요.", "The app picks out payment texts only; other texts are neither saved nor sent to AI. A payment that arrives as both a text and an app alert is saved once, and your connected AI tidies the shop name and category.")
            )
            guideSection(
                title: language.text("결제 앱 알림 자동으로 넣기", "Payment app alerts, automatically"),
                steps: [
                    language.text("「단축어 앱 열기」 → 「자동화」 → + → 「알림」 → 「앱 푸시」에서 은행·카드 앱(iOS 27부터)", "Open Shortcuts → Automation → + → Notification → App Push → your bank and card apps (iOS 27 or later)"),
                    language.text("내용 조건은 비워 두고 「즉시 실행」 → 다음", "Leave the content filter empty → Run Immediately → Next"),
                    language.text("「새로운 빈 자동화」 → BOKKI Plan 「결제 알림 넣기」 → 완료", "New Blank Automation → BOKKI Plan \"Add payment alert\" → Done"),
                ],
                copyText: nil,
                footer: language.text("문자가 오지 않는 카드·은행도 앱 알림으로 들어와요. 광고 알림은 넣지 않아요.", "Cards and banks that don't text you still come in through app alerts. Ads are skipped.")
            )
            Section {
                ForEach(Self.siriExamples(language), id: \.self) { phrase in
                    Label(phrase, systemImage: "mic")
                }
            } header: {
                Text(language.text("Siri로 BOKKI Plan에 넣기", "Add to BOKKI Plan with Siri"))
            } footer: {
                Text(language.text("「시리야」 다음에 그대로 말하면 앱을 열지 않고 들어가요. 금액을 말하면 가계부에도 들어가요. 「보키 플랜」이라고 불러도 돼요.", "Say these after \"Hey Siri\"; they go in without opening the app. Say an amount and it goes into the ledger too."))
            }
            Section {
                Button {
                    if let url = URL(string: "shortcuts://") { openURL(url) }
                } label: { Label(language.text("단축어 앱 열기", "Open Shortcuts"), systemImage: "square.2.layers.3d") }
                ShortcutsLink()
            }
        }
        .listRowBackground(Color.tpSurface)
    }

    static func siriExamples(_ language: MapHomeLanguage) -> [String] {
        [
            language.text("BOKKI Plan에 저장 → 커피 4500원", "Save to BOKKI Plan → coffee 4,500 won"),
            language.text("BOKKI Plan 출근 기록 · 퇴근 · 기상 · 귀가", "Log arrived at work in BOKKI Plan"),
            language.text("BOKKI Plan 지출 기록", "Add an expense in BOKKI Plan"),
            language.text("BOKKI Plan 오늘 얼마 썼어", "How much did I spend today in BOKKI Plan"),
            language.text("BOKKI Plan 오늘 몇 걸음", "Steps today in BOKKI Plan"),
            language.text("BOKKI Plan 지금 뭐로 기록돼", "What is BOKKI Plan recording now"),
            language.text("BOKKI Plan 가계부 열어", "Open ledger in BOKKI Plan"),
            language.text("BOKKI Plan AI에게 맡겨", "Ask BOKKI Plan AI"),
        ]
    }

    private func guideSection(title: String, steps: [String], copyText: String?, footer: String) -> some View {
        Section {
            HStack(spacing: 10) {
                Button {
                    if let url = URL(string: "shortcuts://") { openURL(url) }
                } label: { Label(language.text("단축어 앱 열기", "Open Shortcuts"), systemImage: "square.2.layers.3d") }
                if let copyText {
                    Button {
                        UIPasteboard.general.string = copyText
                        copied = title
                    } label: {
                        Label(copied == title ? language.text("복사했어요", "Copied") : language.text("「\(copyText)」 복사", "Copy \"\(copyText)\""),
                              systemImage: copied == title ? "checkmark" : "doc.on.doc")
                    }
                }
            }
            .buttonStyle(.bordered)
            .font(.taptionStyle(.subheadline, weight: .semibold))
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Label { Text(step) } icon: { Text(verbatim: "\(index + 1)").font(.taptionStyle(.headline)) }
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }
}

/// 메뉴 › 연결 「단축어 · Siri」와 가계부의 안내 창.
struct BokkiShortcutsGuide: View {
    let language: MapHomeLanguage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List { BokkiShortcutsGuideSections(language: language) }
                .tpListStyle()
                .navigationTitle(language.text("단축어 · Siri", "Shortcuts · Siri"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(language.text("완료", "Done")) { dismiss() } } }
        }
    }
}
