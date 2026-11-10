import SwiftUI

/// AI 연결 승인(SEC1110A02). PIN은 앱 비밀번호 6자리로 묻는다(대표 결정 2026-11-10, PIN1110A01).
/// 기기에서 앱 비밀번호를 먼저 확인하고, 서버에는 `AssistantPINDerivation`이 만든 다른 6자리만 보낸다.
/// 예전에 따로 정한 AI PIN이 서버에 있으면 한 번만 그 PIN을 받아 옮긴다. 글자는 이 화면 상태에만 있고 닫으면 지운다.
struct AssistantPINSheet: View {
    enum Mode { case enter, migrate }

    let language: MapHomeLanguage
    /// 무엇을 승인하는지 한 줄.
    var purpose: String?
    /// 서버에 맞춘 PIN(앱 비밀번호에서 만든 값)을 받아 할 일. 실패 문구를 돌려주면 시트에 남고, nil이면 닫는다.
    let onSubmit: @MainActor (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .enter
    @State private var password = ""
    @State private var oldPIN = ""
    @State private var message: String?
    @State private var isWorking = false
    @State private var isAskingReset = false
    @State private var work: Task<Void, Never>?

    init(language: MapHomeLanguage, purpose: String? = nil, onSubmit: @escaping @MainActor (String) async -> String?) {
        self.language = language
        self.purpose = purpose
        self.onSubmit = onSubmit
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if AssistantAppPassword.isSet() {
                        field(language.text("앱 비밀번호 6자리", "6-digit app password"), $password)
                        if mode == .migrate { field(language.text("예전 AI 연결 PIN 6자리", "Old 6-digit AI PIN"), $oldPIN) }
                    } else {
                        Text(language.text("먼저 메뉴에서 앱 비밀번호(6자리)를 만들어 주세요.", "Create an app password (6 digits) in the menu first."))
                    }
                    if let message { Text(message).font(.taptionStyle(.footnote)).foregroundStyle(.red) }
                } footer: {
                    Text([purpose, footnote].compactMap { $0 }.joined(separator: "\n"))
                }
                if mode == .migrate {
                    Section {
                        Button(language.text("예전 PIN을 잊었어요", "I forgot the old PIN"), role: .destructive) { isAskingReset = true }
                    }
                }
            }
            .disabled(isWorking)
            .navigationTitle(language.text("앱 비밀번호", "App password"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(language.text("취소", "Cancel")) { close() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("확인", "OK")) { submit() }.disabled(!isComplete || isWorking)
                }
            }
        }
        .presentationDetents([.medium])
        .assistantPINReset(isPresented: $isAskingReset, language: language) { erased in
            if erased { show(.enter) }
            message = erased ? AssistantPINText.resetDone(language) : AssistantPINText.resetFailed(language)
        }
        .onDisappear {
            work?.cancel()
            clear()
        }
    }

    private var footnote: String {
        mode == .migrate
            ? language.text("예전에 따로 정한 AI PIN을 한 번만 넣으면 앱 비밀번호로 바꿔요.", "Enter the AI PIN you set before once, and it switches to your app password.")
            : language.text("메뉴의 앱 비밀번호와 같아요. AI 서버에는 비밀번호 대신 따로 만든 값만 보내요.", "Same as your app password in the menu. The AI server only gets a separate value, never the password.")
    }

    private var isComplete: Bool {
        PlanPINVerifier.isValid(password) && (mode == .enter || AssistantPIN.isValid(oldPIN))
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        SecureField(title, text: text)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .onChange(of: text.wrappedValue) { _, value in
                let digits = String(value.filter(\.isNumber).prefix(6))
                if digits != value { text.wrappedValue = digits }
            }
    }

    private func show(_ next: Mode) {
        guard next != mode else { return }
        mode = next
        oldPIN = ""
    }

    private func submit() {
        switch AssistantAppPassword.verify(password) {
        case .matched: break
        case .wrong:
            password = ""
            message = language.text("앱 비밀번호가 맞지 않아요.", "Wrong app password.")
            return
        case let .blocked(retryAfter):
            message = language.text("여러 번 틀려 \(max(1, Int(retryAfter.rounded(.up))))초 동안 막혔어요.", "Too many tries. Wait \(max(1, Int(retryAfter.rounded(.up)))) s.")
            return
        case .notSet:
            message = language.text("먼저 메뉴에서 앱 비밀번호를 만들어 주세요.", "Create an app password in the menu first.")
            return
        }
        guard let derived = AssistantPINDerivation.pin(appPassword: password) else {
            message = language.text("기기에 값을 저장하지 못했어요. 잠시 뒤 다시 해 주세요.", "Couldn't save on this device. Try again in a moment.")
            return
        }
        isWorking = true
        let old = mode == .migrate ? oldPIN : nil
        work = Task { @MainActor in
            defer { isWorking = false }
            if let failure = await Self.align(derived, old: old, language: language) {
                if case .needsOldPIN = failure { show(.migrate) }
                message = failure.text(language)
                return
            }
            guard !Task.isCancelled else { return }
            if let failure = await onSubmit(derived) {
                message = failure
                return
            }
            close()
        }
    }

    enum AlignFailure: Equatable {
        case needsOldPIN
        case refused(AssistantServerRefusal)
        case failed

        func text(_ language: MapHomeLanguage) -> String {
            switch self {
            case .needsOldPIN:
                language.text("예전에 따로 정한 AI PIN이 있어요. 그 PIN을 한 번만 넣어 주세요.", "An AI PIN you set before is on the server. Enter it once.")
            case let .refused(refusal): refusal.text(language)
            case .failed: language.text("AI 서버에 연결하지 못했어요. 잠시 뒤 다시 해 주세요.", "Couldn't reach the AI server. Try again in a moment.")
            }
        }
    }

    /// 서버 PIN을 앱 비밀번호에서 만든 값으로 맞춘다. 없으면 만들고, 있으면 같은 값을 다시 넣어 맞는지 본다.
    /// 다르면(예전에 따로 정한 PIN) 예전 PIN을 받아 바꾼다.
    static func align(_ derived: String, old: String?, language: MapHomeLanguage, env: AssistantRegistration.Environment = .live) async -> AlignFailure? {
        guard await AssistantRegistration.prepare(env), let status = await AssistantPINStore.status(env: env) else { return .failed }
        let current: String? = status.isSet ? (old ?? derived) : nil
        switch await AssistantPINStore.set(pin: derived, current: current, env: env) {
        case .saved: return nil
        case let .refused(refusal):
            if refusal.kind == .wrongPIN, old == nil { return .needsOldPIN }
            return .refused(refusal)
        case .invalid, .failed: return .failed
        }
    }

    private func close() {
        work?.cancel()
        clear()
        dismiss()
    }

    private func clear() {
        password = ""
        oldPIN = ""
    }
}

extension AssistantPINSheet {
    @MainActor
    static func gate(language: MapHomeLanguage, purpose: String? = nil, onSubmit: @escaping @MainActor (String) async -> String?) -> Self {
        Self(language: language, purpose: purpose, onSubmit: onSubmit)
    }
}
