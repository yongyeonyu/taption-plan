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
}

@MainActor
enum AssistantGuidePlan {
    /// AI마다 단계. 값(코드·PIN·키)이 아직 없으면 그 단계 버튼은 앞 단계를 먼저 하라고 막힌다.
    static func steps(
        _ provider: AssistantAIProvider, host: String, token: String?, code: String?, pin: String?, language: MapHomeLanguage
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
                      detail: language.text("앱 비밀번호를 넣으면 이 GPT에만 쓰는 연결 키를 만들어요.", "Enter your app password to make a key just for this GPT."),
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
                      detail: language.text("앱 비밀번호를 넣으면 키를 만들고 연결 안내를 복사해요(키 대신 1회용 주소).", "Enter your app password to make a key and copy the setup (a one-time link instead of the key)."),
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
                    if step.action == .check, isConnected {
                        Label(language.text("연결됨", "Connected"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 4)
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
