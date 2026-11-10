import SwiftUI

/// AI 연결 승인 PIN 입력·만들기·바꾸기(SEC1110A02). PIN 글자는 이 화면 상태에만 있고 닫으면 지운다.
/// 열 때 서버에 PIN이 있는지 물어 화면을 맞추고, 잊었으면 여기서 지우고 새로 정한다(REV1110A06).
struct AssistantPINSheet: View {
    enum Mode { case enter, create, change }

    let language: MapHomeLanguage
    /// 무엇을 승인하는지 한 줄.
    var purpose: String?
    /// 승인용으로 띄웠으면 PIN이 이미 있을 때 「바꾸기」가 아니라 「입력」으로 맞춘다.
    var isGate = false
    /// PIN을 받아 할 일. 실패 문구를 돌려주면 시트에 남고, nil이면 닫는다.
    let onSubmit: @MainActor (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode
    @State private var current = ""
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var message: String?
    @State private var isWorking = false
    @State private var isAskingReset = false
    @State private var work: Task<Void, Never>?

    init(language: MapHomeLanguage, mode: Mode, purpose: String? = nil, isGate: Bool = false, onSubmit: @escaping @MainActor (String) async -> String?) {
        self.language = language
        self.purpose = purpose
        self.isGate = isGate
        self.onSubmit = onSubmit
        _mode = State(initialValue: mode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if mode == .change { field(language.text("지금 PIN", "Current PIN"), $current) }
                    field(mode == .enter ? language.text("PIN 6자리", "6-digit PIN") : language.text("새 PIN 6자리", "New 6-digit PIN"), $pin)
                    if mode != .enter { field(language.text("한 번 더", "Once more"), $confirmation) }
                    if let message { Text(message).font(.footnote).foregroundStyle(.red) }
                } footer: {
                    Text(purpose ?? language.text(
                        "AI 연결을 만들거나 승인할 때 이 PIN을 물어요. PIN은 기기에 저장하지 않아요.",
                        "This PIN is asked whenever you create or approve an AI connection. The PIN itself is not stored."
                    ))
                }
                if mode != .create {
                    Section {
                        Button(language.text("PIN을 잊었어요", "I forgot my PIN"), role: .destructive) { isAskingReset = true }
                    }
                }
            }
            .disabled(isWorking)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(language.text("취소", "Cancel")) { close() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("확인", "OK")) { submit() }.disabled(!isComplete || isWorking)
                }
            }
        }
        .presentationDetents([.medium])
        .task { await syncMode() }
        .assistantPINReset(isPresented: $isAskingReset, language: language) { erased in
            if erased { show(.create) }
            message = erased ? AssistantPINText.resetDone(language) : AssistantPINText.resetFailed(language)
        }
        .onDisappear {
            work?.cancel()
            clear()
        }
    }

    private var title: String {
        switch mode {
        case .enter: language.text("PIN 입력", "Enter PIN")
        case .create: language.text("PIN 만들기", "Create PIN")
        case .change: language.text("PIN 바꾸기", "Change PIN")
        }
    }

    private var isComplete: Bool {
        AssistantPIN.isValid(pin) && (mode == .enter || AssistantPIN.isValid(confirmation)) && (mode != .change || AssistantPIN.isValid(current))
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

    /// 서버에 PIN이 없는데 입력을 묻거나, 있는데 만들기를 보이는 막다른 길을 없앤다.
    private func syncMode() async {
        guard let status = await AssistantPINStore.status() else { return }
        show(Self.mode(mode, isGate: isGate, serverHasPIN: status.isSet))
        if status.isLocked { message = AssistantServerRefusal(kind: .locked, retryAfterSeconds: status.retryAfterSeconds).text(language) }
    }

    static func mode(_ mode: Mode, isGate: Bool, serverHasPIN: Bool) -> Mode {
        guard serverHasPIN else { return .create }
        return mode == .create ? (isGate ? .enter : .change) : mode
    }

    private func show(_ next: Mode) {
        guard next != mode else { return }
        mode = next
        clear()
    }

    private func submit() {
        guard mode == .enter || pin == confirmation else {
            message = language.text("두 PIN이 달라요.", "The PINs don't match.")
            return
        }
        isWorking = true
        let entered = pin, old = current, submitted = mode
        work = Task { @MainActor in
            defer { isWorking = false }
            if submitted != .enter {
                switch await AssistantPINStore.set(pin: entered, current: submitted == .change ? old : nil) {
                case .saved: break
                case let .refused(refusal):
                    // 서버에 이미 PIN이 있으면 지금 PIN을 넣는 칸을 보인다.
                    if refusal.kind == .currentPINRequired { show(isGate ? .enter : .change) }
                    message = refusal.text(language)
                    return
                case .invalid, .failed:
                    message = language.text("PIN을 저장하지 못했어요. 잠시 뒤 다시 해 주세요.", "Couldn't save the PIN. Try again in a moment.")
                    return
                }
            }
            guard !Task.isCancelled else { return }
            if let failure = await onSubmit(entered) {
                pin = ""
                await syncMode()
                message = failure
                return
            }
            close()
        }
    }

    private func close() {
        work?.cancel()
        clear()
        dismiss()
    }

    private func clear() {
        current = ""
        pin = ""
        confirmation = ""
    }
}

/// PIN이 없으면 만들기, 있으면 입력으로 띄운다.
extension AssistantPINSheet {
    @MainActor
    static func gate(language: MapHomeLanguage, purpose: String? = nil, onSubmit: @escaping @MainActor (String) async -> String?) -> Self {
        Self(language: language, mode: AssistantPINStore.isSet() ? .enter : .create, purpose: purpose, isGate: true, onSubmit: onSubmit)
    }
}
