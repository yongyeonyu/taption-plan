import Observation
import SwiftUI

/// AI 연결을 한 단계씩(GDE1111A01, 대표 지시). 다른 앱(Claude·ChatGPT·피클)에 다녀와 화면이 다시 만들어져도
/// 보던 AI·단계·연결 코드·승인 PIN을 앱이 켜져 있는 동안만 메모리에 기억해 그대로 잇는다. 기기에 저장하지 않는다.
@MainActor
@Observable
final class AssistantGuideMemory {
    static let shared = AssistantGuideMemory()
    /// 이보다 오래 손대지 않았으면 처음부터 한다(연결 코드도 10분이면 끝난다).
    static let lifetime: TimeInterval = 30 * 60

    private(set) var provider: AssistantAIProvider?
    private(set) var step = 0
    private(set) var code: AssistantOAuthCode?
    private(set) var approvalPIN: String?
    @ObservationIgnored private var touchedAt = Date.distantPast

    /// 진행 중인 AI. 오래됐으면 nil.
    func activeProvider(now: Date = .now) -> AssistantAIProvider? {
        now.timeIntervalSince(touchedAt) < Self.lifetime ? provider : nil
    }

    func begin(_ next: AssistantAIProvider, now: Date = .now) {
        guard activeProvider(now: now) != next else { touchedAt = now; return }
        provider = next
        step = 0
        code = nil
        approvalPIN = nil
        touchedAt = now
    }

    /// 그 AI의 단계를 보던 중이면 그대로, 아니면 처음.
    func step(for provider: AssistantAIProvider, now: Date = .now) -> Int {
        activeProvider(now: now) == provider ? step : 0
    }

    func go(to index: Int, now: Date = .now) {
        step = max(0, index)
        touchedAt = now
    }

    func keep(code: AssistantOAuthCode?, pin: String?, now: Date = .now) {
        self.code = code
        approvalPIN = pin
        touchedAt = now
    }

    /// 목록으로 돌아가면 잊는다.
    func end() {
        provider = nil
        step = 0
        code = nil
        approvalPIN = nil
    }
}

/// 한 단계. `action`을 누르면 할 일을 하고 다음 단계로 간다.
struct AssistantGuideStep: Identifiable, Equatable {
    enum Action: Equatable {
        /// 앱 비밀번호로 연결 키를 만든다(연결 안내 복사 포함).
        case makeKey
        /// 앱 비밀번호로 연결 코드와 승인 PIN을 받는다.
        case getCode
        case copy(String)
        case open(URL)
        /// 상태를 다시 읽어 연결됐는지 본다.
        case check
    }

    var id: String
    var title: String
    var detail: String
    var button: String
    var action: Action?
    /// 이 단계의 화면 사진 자리(MUS1120A03). 에셋이 없으면 캡션만 든 빈 칸을 보인다.
    var shot: Shot?

    struct Shot: Equatable {
        var asset: String
        var caption: String
    }
}

@MainActor
enum AssistantGuidePlan {
    /// AI마다 단계. 값(코드·PIN·키)이 아직 없으면 그 단계 버튼은 앞 단계를 먼저 하라고 막힌다.
    static func steps(
        _ provider: AssistantAIProvider, host: String, token: String?, code: String?, pin: String?, language: MapHomeLanguage,
        scope: AssistantKeyScope = .read, expiresAt: Date? = nil
    ) -> [AssistantGuideStep] {
        let check = AssistantGuideStep(
            id: "check", title: language.text("연결 확인", "Check the connection"),
            detail: language.text("다 했으면 눌러 연결됐는지 확인해요. 「연결됨」이 보이면 끝이에요.", "When you're done, tap to check. You're finished when it says Connected."),
            button: language.text("연결 확인", "Check"), action: .check
        )
        switch provider {
        case .claude:
            return [
                .init(id: "code", title: language.text("연결 코드 받기", "Get a connection code"),
                      detail: language.text("앱 비밀번호를 넣으면 연결 코드(글자)와 승인 PIN(숫자)이 나와요. 10분 안에 끝내 주세요.", "Enter your app password to get a code (letters) and an approval PIN (digits). Finish within 10 minutes."),
                      button: language.text("코드 받기", "Get code"), action: .getCode),
                .init(id: "open", title: language.text("Claude에서 추가", "Add in Claude"),
                      detail: language.text("Claude가 열리면 「Add」를 누르세요. 승인 화면이 열리면 이 앱으로 돌아와요.", "When Claude opens, tap Add. When the approval page opens, come back here."),
                      button: language.text("Claude 열기", "Open Claude"), action: TripRelay.claudeAddConnectorURL(host: host).map(AssistantGuideStep.Action.open)),
                .init(id: "copyCode", title: language.text("연결 코드 넣기", "Enter the code"),
                      detail: language.text("코드를 복사해 승인 화면 첫 칸(연결 코드)에 붙여 넣고 돌아와요.", "Copy the code, paste it into the first field (connection code), then come back."),
                      button: code.map { language.text("코드 복사 \($0)", "Copy code \($0)") } ?? language.text("코드 복사", "Copy code"), action: code.map(AssistantGuideStep.Action.copy)),
                .init(id: "copyPIN", title: language.text("PIN 넣고 승인", "Enter the PIN and approve"),
                      detail: language.text("PIN을 복사해 승인 화면 둘째 칸(PIN)에 붙여 넣고 「승인」을 눌러요.", "Copy the PIN, paste it into the second field (PIN) and tap Approve."),
                      button: pin.map { language.text("PIN 복사 \($0)", "Copy PIN \($0)") } ?? language.text("PIN 복사", "Copy PIN"), action: pin.map(AssistantGuideStep.Action.copy)),
                check,
            ]
        case .chatGPT:
            return [
                .init(id: "key", title: language.text("연결 키 만들기", "Make a key"),
                      detail: language.text("권한·기간을 고르고 앱 비밀번호를 넣으면 이 GPT에만 쓰는 연결 키를 만들어요. 다시 하면 새 키가 만들어지고 옛 키는 끊겨요.", "Pick access and period, then enter your app password to make a key just for this GPT. Doing it again makes a new key and cuts the old one."),
                      button: language.text("키 만들기", "Make key"), action: .makeKey),
                .init(id: "open", title: language.text("GPT 만들기 열기", "Open the GPT builder"),
                      detail: language.text("ChatGPT에서 「구성」 → 「작업 추가」까지 가요. 맞춤 GPT는 Plus 이상이에요.", "In ChatGPT, go to Configure → Create new action. Custom GPTs need Plus or higher."),
                      button: language.text("ChatGPT 열기", "Open ChatGPT"), action: URL(string: "https://chatgpt.com/gpts/editor").map(AssistantGuideStep.Action.open)),
                .init(id: "schema", title: language.text("스키마 넣기", "Import the schema"),
                      detail: language.text("스키마 주소를 복사해 「URL에서 가져오기」에 붙여 넣어요.", "Copy the schema URL and paste it into Import from URL."),
                      button: language.text("스키마 주소 복사", "Copy schema URL"), action: .copy(TripRelay.openAPIURL(host: host))),
                .init(id: "auth", title: language.text("인증에 키 넣기", "Add the key"),
                      detail: language.text("인증 → API 키 → Bearer를 고르고 키를 붙여 넣은 뒤 저장해요.", "Under Authentication choose API key → Bearer, paste the key and save."),
                      button: language.text("연결 키 복사", "Copy key"), action: token.map(AssistantGuideStep.Action.copy)),
                check,
            ]
        // Muse에는 「MCP 서버 추가」 화면이 없다(MUS1120A04). 키 만들기 → 키 없는 안내 복사 → 채팅에 붙여 넣기 → 보안 입력에 키 → 연결 확인.
        // 한국 App Store에는 Muse가 없어 「열기」 단추가 없다.
        case .muse:
            let setup = TripRelay.museSetupText(host: host, language: language, scope: scope, expiresAt: expiresAt)
            return [
                .init(id: "key", title: language.text("연결 키 만들기", "Make a key"),
                      detail: language.text("권한·기간을 고르고 앱 비밀번호를 넣으면 Muse에만 쓰는 연결 키를 만들어요. 다시 하면 새 키가 만들어지고 옛 키는 끊겨요.", "Pick access and period, then enter your app password to make a key just for Muse. Doing it again makes a new key and cuts the old one."),
                      button: language.text("키 만들기", "Make key"), action: .makeKey,
                      shot: .init(asset: "MuseGuide1Key", caption: language.text("1. 앱에서 연결 키 만들기", "1. Make a key in the app"))),
                .init(id: "copySetup", title: language.text("설정 안내 복사", "Copy the setup"),
                      detail: language.text("Muse 채팅에 붙여 넣을 설정 안내를 복사해요. 키는 들어 있지 않아요.", "Copy the setup to paste into the Muse chat. It doesn't contain the key."),
                      button: language.text("설정 안내 복사", "Copy setup"), action: .copy(setup),
                      shot: .init(asset: "MuseGuide2Copy", caption: language.text("2. 앱에서 설정 안내 복사", "2. Copy the setup in the app"))),
                .init(id: "paste", title: language.text("Muse 채팅에 붙여 넣기", "Paste into the Muse chat"),
                      detail: language.text("복사한 안내를 Muse 채팅에 붙여 넣고 보내서 커스텀 커넥터를 만들어 달라고 해요. 한국 App Store에는 아직 Muse 앱이 없어서 앱이 없으면 웹으로 이용해요.", "Paste the copied setup into the Muse chat and send it to ask for a custom connector. Muse isn't on the Korean App Store yet, so use the web version if you don't have the app."),
                      button: language.text("안내 다시 복사", "Copy setup again"), action: .copy(setup),
                      shot: .init(asset: "MuseGuide3Paste", caption: language.text("3. Muse 채팅에 안내를 붙여 넣은 화면", "3. The setup pasted into the Muse chat"))),
                .init(id: "auth", title: language.text("보안 입력에 키 넣기", "Enter the key securely"),
                      detail: language.text("키를 복사한 뒤, Muse가 보여주는 보안 입력 화면에 붙여 넣어주세요. 키를 채팅에 직접 적지 마세요.", "Copy the key, then paste it into the secure input screen Muse shows. Never type the key directly in the chat."),
                      button: language.text("연결 키 복사", "Copy key"), action: token.map(AssistantGuideStep.Action.copy),
                      shot: .init(asset: "MuseGuide4Secure", caption: language.text("4. Muse 보안 키 입력 화면", "4. Muse's secure key input"))),
                .init(id: "check", title: check.title,
                      detail: language.text("Muse가 도구 목록과 읽기 시험을 마치고 연결됐다고 알려 주면, 눌러 앱에서도 연결됐는지 확인해요.", "When Muse finishes listing tools and a read test and says it's connected, tap to check in the app too."),
                      button: check.button, action: .check,
                      shot: .init(asset: "MuseGuide5Done", caption: language.text("5. Muse 연결 완료 메시지", "5. Muse's connected message"))),
            ]
        default:
            let appStep: [AssistantGuideStep] = provider.destination(installed: provider.isInstalled).map { url in
                [.init(id: "open", title: language.text("\(provider.title(language)) 열기", "Open \(provider.title(language))"),
                       detail: provider == .gemini
                           ? language.text("~/.gemini/settings.json에 붙여 넣고 gemini를 다시 시작해요.", "Paste into ~/.gemini/settings.json and restart gemini.")
                           : language.text("채팅창에 붙여 넣고 보내요. 앱이 없으면 App Store가 열려요.", "Paste into the chat and send. The App Store opens if it isn't installed."),
                       button: language.text("열기", "Open"), action: .open(url))]
            } ?? []
            return [
                .init(id: "key", title: language.text("연결 키 만들기", "Make a key"),
                      detail: language.text("권한·기간을 고르고 앱 비밀번호를 넣으면 키를 만들고 연결 안내를 복사해요(키 대신 1회용 주소). 다시 하면 새 키가 만들어지고 옛 키는 끊겨요.", "Pick access and period, then enter your app password to make a key and copy the setup (a one-time link instead of the key). Doing it again makes a new key and cuts the old one."),
                      button: language.text("키 만들기", "Make key"), action: .makeKey),
            ] + appStep + [check]
        }
    }
}

/// 지금 단계 카드. 이전·다음으로 오가고, 버튼을 누르면 그 일을 한 뒤 다음으로 간다.
struct AssistantGuideSection: View {
    let provider: AssistantAIProvider
    let steps: [AssistantGuideStep]
    let language: MapHomeLanguage
    let isConnected: Bool
    let perform: (AssistantGuideStep.Action) -> Void
    /// 키 만들기 단계 안에 넣을 권한·기간 칸(KEY1120A01). 키를 쓰지 않는 AI는 nil.
    var keyOptions: AnyView?

    private var memory: AssistantGuideMemory { .shared }

    var body: some View {
        let index = min(memory.step(for: provider), max(0, steps.count - 1))
        Section {
            if let step = steps.indices.contains(index) ? steps[index] : nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text(language.text("\(index + 1) / \(steps.count) 단계", "Step \(index + 1) of \(steps.count)"))
                        .font(.taptionStyle(.caption, weight: .semibold)).foregroundStyle(.secondary)
                    Text(step.title).font(.taptionStyle(.headline))
                    Text(step.detail).font(.taptionStyle(.footnote)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let shot = step.shot { AssistantGuideShotView(shot: shot, language: language) }
                    if step.action == .check, isConnected {
                        Label(language.text("연결됨", "Connected"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 4)
                if step.id == "key", let keyOptions { keyOptions }
                Button(step.button) {
                    if let action = step.action { perform(action) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(step.action == nil)
                .accessibilityIdentifier("assistantGuide.\(step.id)")
                if step.action == nil {
                    Text(language.text("앞 단계를 먼저 해 주세요.", "Do the previous step first.")).font(.taptionStyle(.caption)).foregroundStyle(.orange)
                }
                HStack {
                    Button(language.text("이전", "Back")) { memory.go(to: index - 1) }.disabled(index == 0)
                    Spacer()
                    Button(language.text("다음", "Next")) { memory.go(to: index + 1) }.disabled(index >= steps.count - 1)
                }
                .buttonStyle(.borderless)
            }
        } header: {
            Text(language.text("단계별 연결", "Step by step"))
        }
    }
}

/// 단계 화면 사진. 에셋이 아직 없으면 캡션만 든 빈 칸을 보인다.
struct AssistantGuideShotView: View {
    let shot: AssistantGuideStep.Shot
    let language: MapHomeLanguage

    var body: some View {
        VStack(spacing: 4) {
            if let image = UIImage(named: shot.asset) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityLabel(shot.caption)
            } else {
                RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(.secondary).frame(height: 120)
                    .overlay(Text(language.text("화면 사진 준비 중", "Screenshot coming soon")).font(.taptionStyle(.caption)).foregroundStyle(.secondary))
            }
            Text(shot.caption).font(.taptionStyle(.caption)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
