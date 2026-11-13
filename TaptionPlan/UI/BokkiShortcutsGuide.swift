import AppIntents
import SwiftUI

/// 단축어·Siri 연결 안내(SHT1111A01): 결제 문자 자동, 결제 앱 알림 자동(iOS 27 「알림 › 앱 푸시」), Siri로 BOKKI Plan에 넣기.
/// 메뉴 › 연결, 가계부, 튜토리얼이 같은 내용을 쓴다.
struct BokkiShortcutsGuideSections: View {
    let language: MapHomeLanguage
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            // 결제 낱말 트리거까지 든 단축어를 iCloud 링크로 한 번에 넣는다(SCB1112A01, iOS 27).
            // 파일로 넣으면 iOS가 트리거를 빼므로 링크가 없을 때만 파일을 쓴다. 결제 앱 알림도 링크가 있으면 링크로, 없으면 따라 하기로.
            Section {
                BokkiPaymentShortcutButton(language: language)
                BokkiPaymentAutomationRow(language: language)
                PaymentAlertSourcesRow(language: language)
            } header: {
                Text(language.text("결제 문자·알림 자동으로 넣기", "Payments, automatically"))
            } footer: {
                Text(BokkiPaymentShortcut.hasAutomationLink
                     ? language.text("「BOKKI 결제」를 추가한 뒤 단축어 앱 › 자동화에서 「메시지를 받을 때」 스위치를 켜면 끝이에요. 앱이 결제만 골라 가계부에 넣고, 나머지 문자는 넣지도 AI에 보내지도 않아요.", "Add BOKKI Payment, then turn on its \"When I get a message\" switch in Shortcuts › Automation. The app keeps payments only; other texts are neither saved nor sent to AI.")
                     : language.text("「BOKKI 결제」를 넣은 뒤 따라 하기로 자동화를 만들어요. 앱이 결제만 골라 가계부에 넣고, 나머지는 넣지도 AI에 보내지도 않아요.", "Add BOKKI Payment, then follow the steps to make the automation. The app keeps payments only; nothing else is saved or sent to AI."))
            }
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

/// 「BOKKI 결제」 단축어(SCA1112A01·SCB1112A01). 받은 문자·알림을 그대로 「결제 알림 넣기」에 넘긴다.
/// iCloud 링크판에는 「원이 든 메시지를 받을 때」 트리거가 들어 있다. ID는 git에 넣지 않는 `AppSecrets.local.xcconfig`의
/// `PAYMENT_SHORTCUT_ICLOUD_ID`. 링크가 없으면 Assets 데이터 `Shortcuts/BokkiShortcutPayment`(트리거 없음)를 공유 시트로 넘긴다.
/// 파일은 `scripts/shortcuts/build.py`가 만든다.
enum BokkiPaymentShortcut {
    static func title(_ language: MapHomeLanguage) -> String { language.text("BOKKI 결제", "BOKKI Payment") }

    static func alertTitle(_ language: MapHomeLanguage) -> String { language.text("BOKKI 결제 알림", "BOKKI Payment Alerts") }

    /// 링크판 「BOKKI 결제」의 메시지 트리거 낱말. 하나라도 들어 있으면 앱으로 넘어온다. 링크를 다시 만들면 여기도 맞춘다.
    static let triggerWords = ["원", "승인", "출금", "취소", "입금", "결제", "일시불", "할부"]

    /// 결제 낱말 여덟 개 가운데 하나라도 든 메시지를 받을 때.
    static var automationLink: URL? { link("PAYMENT_SHORTCUT_ICLOUD_ID") }
    /// 은행·카드 앱의 알림을 받을 때(NTF1112A01). 앱 목록은 받은 뒤 고칠 수 있다.
    static var alertLink: URL? { link("PAYMENT_ALERT_SHORTCUT_ICLOUD_ID") }

    private static func link(_ key: String) -> URL? {
        let id = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard id.count == 32, id.allSatisfy(\.isHexDigit) else { return nil }
        return URL(string: "https://www.icloud.com/shortcuts/\(id)")
    }

    static var hasAutomationLink: Bool { automationLink != nil }

    /// 공유 시트용 사본. 단축어 앱은 파일 이름을 단축어 이름으로 쓴다. 같은 파일이 있으면 다시 쓰지 않는다(뷰 본문에서 불린다).
    static func file(_ language: MapHomeLanguage) -> URL? {
        guard let data = NSDataAsset(name: "BokkiShortcutPayment")?.data else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(title(language) + ".shortcut")
        if (try? Data(contentsOf: url)) == data { return url }
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }
}

/// 「BOKKI 결제」 추가 단추. iCloud 링크가 있으면 먼저 사진 두 장으로 할 일을 보여 준 뒤 링크를 연다.
struct BokkiPaymentShortcutButton: View {
    let language: MapHomeLanguage
    @State private var isPresented = false

    var body: some View {
        let title = BokkiPaymentShortcut.title(language)
        // 아래 「결제 앱 알림」 줄과 같은 글자 크기로 둔다(목록 기본 글꼴).
        let label = Label(language.text("「\(title)」 자동화 추가", "Add the \"\(title)\" automation"), systemImage: "square.and.arrow.down")
        if let link = BokkiPaymentShortcut.automationLink {
            Button { isPresented = true } label: { label }
                .sheet(isPresented: $isPresented) { BokkiPaymentAddPopup(link: link, language: language) }
        } else if let file = BokkiPaymentShortcut.file(language) {
            ShareLink(item: file) { label }
        }
    }
}

/// 추가 튜토리얼(SCB1112A01): 아이폰 11에서 찍은 실제 단축어 앱 화면 다섯 장에 누를 곳을 빨갛게 표시했다.
/// ① 「단축어 추가」 → ② 「<」로 보관함 → ③ 「자동화」 → ④ 스위치 켜기 → ⑤ 켜진 모습. 가져온 자동화는 iOS가 꺼 두므로 ④가 꼭 필요하다.
/// 단축어 앱에 다녀와도 시트와 단계가 남는다.
struct BokkiPaymentAddPopup: View {
    let link: URL
    let language: MapHomeLanguage
    var isAlert = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var page = 0

    private var pages: [(image: String, text: String)] {
        // 알림 자동화(NTF1112A01): 아이폰 18에서 링크로 받아 본 실제 화면.
        if isAlert {
            return [
                ("BokkiShortcutGuideAlertAdd", language.text("단축어 앱이 열리면 「단축어 추가」를 눌러요.", "When Shortcuts opens, tap Add Shortcut.")),
                ("BokkiShortcutGuideBack", language.text("추가가 끝나면 왼쪽 위 「<」를 눌러요.", "Then tap < at the top left.")),
                ("BokkiShortcutGuideLibrary", language.text("보관함에서 「자동화」를 눌러요.", "In the library, tap Automation.")),
                ("BokkiShortcutGuideAlertSwitch", language.text("「BOKKI 결제 알림」 스위치를 켜요. 내 은행·카드 앱이 빠져 있으면 이 줄을 눌러 앱 이름 옆 「+」로 넣어요.", "Turn on the BOKKI Payment Alerts switch. If your bank or card app is missing, tap the row and add it with + next to the app names.")),
                ("BokkiShortcutGuideAlertDone", language.text("이렇게 초록색이 되면 끝이에요. 이제 결제 앱 알림이 저절로 가계부에 들어가요.", "Green means done. Payment app alerts now go into the ledger by themselves.")),
            ]
        }
        return [
            ("BokkiShortcutGuideAdd", language.text("단축어 앱이 열리면 「단축어 추가」를 눌러요.", "When Shortcuts opens, tap Add Shortcut.")),
            ("BokkiShortcutGuideBack", language.text("추가가 끝나면 왼쪽 위 「<」를 눌러요.", "Then tap < at the top left.")),
            ("BokkiShortcutGuideLibrary", language.text("보관함에서 「자동화」를 눌러요.", "In the library, tap Automation.")),
            ("BokkiShortcutGuideSwitch", language.text("「BOKKI 결제」라고 적힌 줄의 스위치를 모두 켜요(낱말마다 한 줄). iOS는 가져온 자동화를 꺼진 채로 넣어요.", "Turn on every switch labelled BOKKI Payment (one row per word). iOS adds shared automations switched off.")),
            ("BokkiShortcutGuideDone", language.text("이렇게 초록색이 되면 끝이에요. 이제 결제 문자가 저절로 가계부에 들어가요.", "Green means done. Payment texts now go into the ledger by themselves.")),
        ]
    }

    var body: some View {
        let all = pages
        NavigationStack {
            VStack(spacing: 16) {
                TabView(selection: $page) {
                    ForEach(all.indices, id: \.self) { index in
                        VStack(spacing: 14) {
                            Image(all[index].image)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: TaptionCorner.large, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: TaptionCorner.large, style: .continuous).stroke(Color.tpBorder, lineWidth: TaptionBorder.width))
                                .frame(maxHeight: 420)
                                .accessibilityHidden(true)
                            Text(all[index].text)
                                .font(.taptionStyle(.body, weight: .semibold))
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 20)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                actions(last: all.count - 1)
                    .padding(.horizontal, 20)
            }
            .padding(.vertical, 12)
            .navigationTitle(Text(verbatim: "\(page + 1) / \(all.count)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(language.text("닫기", "Close")) { dismiss() } } }
        }
    }

    @ViewBuilder
    private func actions(last: Int) -> some View {
        VStack(spacing: 10) {
            if page == 0 {
                Button {
                    openURL(link)
                    page = 1
                } label: { Text(language.text("단축어 앱에서 추가하기", "Add in Shortcuts")).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button {
                    if let url = URL(string: "shortcuts://") { openURL(url) }
                } label: { Text(language.text("단축어 앱 열기", "Open Shortcuts")).frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                HStack {
                    Button(language.text("이전", "Back")) { page -= 1 }
                    Spacer()
                    if page == last {
                        Button(language.text("스위치를 켰어요", "I turned it on")) { dismiss() }.buttonStyle(.borderedProminent)
                    } else {
                        Button(language.text("다음", "Next")) { page += 1 }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .font(.taptionStyle(.subheadline, weight: .semibold))
    }
}

/// 결제 앱 알림 따라 하기 줄. 시트를 이 줄에 단다(Group에 달면 줄마다 겹쳐 뜬다).
struct BokkiPaymentAutomationRow: View {
    let language: MapHomeLanguage
    @State private var isPresented = false

    var body: some View {
        if let link = BokkiPaymentShortcut.alertLink {
            let title = BokkiPaymentShortcut.alertTitle(language)
            Button { isPresented = true } label: {
                Label(language.text("「\(title)」 자동화 추가", "Add the \"\(title)\" automation"), systemImage: "app.badge")
            }
            .sheet(isPresented: $isPresented) { BokkiPaymentAddPopup(link: link, language: language, isAlert: true) }
        } else {
            Button { isPresented = true } label: {
                Label(language.text("결제 앱 알림 자동화 따라 하기", "Set up payment app alerts"), systemImage: "app.badge")
            }
            .sheet(isPresented: $isPresented) { BokkiPaymentAutomationSetup(language: language) }
        }
    }
}

/// 결제 앱 알림 자동화 만들기를 아이폰 단축어 앱 화면(iOS 27, SCB1112A01 캡처)대로 한 단계씩 보여 준다.
/// 단축어 앱에 다녀와도 단계가 남는다.
struct BokkiPaymentAutomationSetup: View {
    let language: MapHomeLanguage
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @SceneStorage("bokkiPaymentSetupStep") private var step = 0

    private struct Step {
        var title: String
        var screen: String
        var rows: [String]
        var pick: Int
        var note: String
    }

    private var steps: [Step] {
        [
            Step(title: language.text("자동화 › +", "Automation › +"),
                 screen: language.text("자동화", "Automation"),
                 rows: [language.text("개인용", "Personal"), "+"], pick: 1,
                 note: language.text("단축어 앱 › 자동화에서 아래 + 를 누르면 새 단축어 편집 화면이 열려요.", "In Shortcuts › Automation, tap + at the bottom. A new shortcut editor opens.")),
            Step(title: language.text("「자동화」 › 「알림」", "Automation › Notification"),
                 screen: language.text("자동화", "Automation"),
                 rows: [language.text("특정 시간", "Time of Day"), language.text("메시지", "Message"), language.text("알림", "Notification")], pick: 2,
                 note: language.text("아래 목록 위의 「자동화」를 누르고 「알림」을 고른 뒤, 은행·카드 앱을 골라요.", "Tap Automation above the list, choose Notification, then pick your bank and card apps.")),
            Step(title: language.text("「결제 알림 넣기」 넣기", "Add \"Add payment alert\""),
                 screen: language.text("검색: BOKKI", "Search: BOKKI"),
                 rows: [language.text("결제 알림 넣기", "Add payment alert"), language.text("알림 내용: 입력", "Alert text: Input")], pick: 0,
                 note: language.text("아래 검색에 BOKKI를 적어 「결제 알림 넣기」를 넣고, 「알림 내용」 칸을 눌러 「단축어 입력」을 골라요.", "Search BOKKI, add \"Add payment alert\", tap its text field and choose Shortcut Input.")),
            Step(title: language.text("「실행 시 보기」 끄기 · 완료", "Turn off Show When Run · Done"),
                 screen: language.text("결제 알림 넣기", "Add payment alert"),
                 rows: [language.text("실행 시 보기", "Show When Run"), language.text("실행 전에 확인", "Ask Before Running")], pick: 0,
                 note: language.text("두 스위치를 끄고 왼쪽 위 「<」로 저장하면 끝이에요.", "Turn both switches off and tap < to save.")),
        ]
    }

    var body: some View {
        let all = steps
        let index = min(max(step, 0), all.count - 1)
        let current = all[index]
        NavigationStack {
            VStack(spacing: 18) {
                Text(verbatim: "\(index + 1) / \(all.count)")
                    .font(.taptionStyle(.subheadline, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(current.title)
                    .font(.taptionStyle(.title3, weight: .bold))
                    .multilineTextAlignment(.center)
                mockScreen(current)
                Text(current.note)
                    .font(.taptionStyle(.subheadline))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    if let url = URL(string: "shortcuts://") { openURL(url) }
                } label: { Label(language.text("단축어 앱 열기", "Open Shortcuts"), systemImage: "square.2.layers.3d") }
                    .buttonStyle(.bordered)
                    .font(.taptionStyle(.subheadline, weight: .semibold))
                Spacer(minLength: 0)
                HStack {
                    Button(language.text("이전", "Back")) { step = index - 1 }.disabled(index == 0)
                    Spacer()
                    if index == all.count - 1 {
                        Button(language.text("다 했어요", "All done")) { step = 0; dismiss() }.buttonStyle(.borderedProminent)
                    } else {
                        Button(language.text("다음", "Next")) { step = index + 1 }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(20)
            .navigationTitle(language.text("결제 앱 알림 자동화", "Payment alert automation"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(language.text("닫기", "Close")) { dismiss() } } }
        }
    }

    /// 단축어 앱 화면을 흉내 낸 그림. 눌러야 할 줄만 강조한다.
    private func mockScreen(_ step: Step) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(step.screen)
                .font(.taptionStyle(.headline))
                .padding(.horizontal, 14).padding(.vertical, 10)
            ForEach(Array(step.rows.enumerated()), id: \.offset) { offset, row in
                HStack {
                    Text(row).font(.taptionStyle(.body, weight: offset == step.pick ? .semibold : .regular))
                    Spacer()
                    if offset == step.pick { Image(systemName: "hand.tap.fill").foregroundStyle(Color.accentColor) }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(offset == step.pick ? Color.accentColor.opacity(0.14) : Color.clear)
                .overlay(alignment: .top) { Rectangle().fill(Color.tpBorder).frame(height: 0.5) }
            }
        }
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous).stroke(Color.tpBorder, lineWidth: TaptionBorder.width))
        .accessibilityHidden(true)
    }
}
