import SwiftUI
import UIKit

/// 키 화면에서 함께 쓰는 문구(SEC1110A01).
enum AssistantKeyText {
    static func rotationFailed(_ language: MapHomeLanguage) -> String {
        language.text(
            "서버에 닿지 않아 키를 바꾸지 못했어요. 잠시 뒤 다시 해 주세요.",
            "Couldn't reach the server, so the key wasn't replaced. Try again in a moment."
        )
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    /// 끊기 확인 문구(CUE1110A01). 서버는 끊은 키가 보내 둔 대기 명령을 함께 지운다.
    static func revokeWarning(_ name: String, language: MapHomeLanguage) -> String {
        language.text(
            "「\(name)」 연결을 끊으면 그 AI가 더는 기록을 읽거나 보낼 수 없어요. 그 AI가 보내 두고 아직 앱에 반영되지 않은 명령도 함께 지워져요. 다시 쓰려면 새로 연결해야 해요.",
            "Disconnecting \"\(name)\" stops that AI from reading or sending anything. Commands it sent that the app hasn't applied yet are deleted too. To use it again, connect anew."
        )
    }
}

/// AI 연결마다 키 하나(SEC1110A01·AIR1110A02). 추가·목록·폐기·연장·권한 바꾸기·연결 안내 복사.
/// 연결 안내에는 그 연결의 키만 넣고 주 키는 넣지 않는다.
/// 권한·기간은 같은 키를 다시 올려 바로 바꾼다. 화면을 닫아도 예전 권한의 키가 남지 않는다(REV1110A06).
struct AssistantConnectionsSection: View {
    let language: MapHomeLanguage
    let host: String
    /// 주 키가 바뀌면 목록을 다시 읽는다.
    let masterKey: String
    let store: AssistantConnectionStore

    /// PIN을 물은 뒤 할 일: 새 연결 또는 연장·권한 바꾸기(SEC1110A02).
    private enum PINTask: Identifiable {
        case create(label: String, scope: AssistantKeyScope, period: AssistantKeyPeriod)
        case replace(AssistantScopedKey, scope: AssistantKeyScope)

        var id: String {
            switch self {
            case let .create(label, scope, period): "c.\(label).\(scope.rawValue).\(period.rawValue)"
            case let .replace(key, scope): "r.\(key.id).\(scope.rawValue)"
            }
        }
    }

    private var keys: [AssistantScopedKey]? { store.keys }
    @State private var isWorking = false
    @State private var isAdding = false
    @State private var copiedID: String?
    @State private var message: String?
    @State private var pinTask: PINTask?
    /// 추가 시트가 닫힌 뒤에 PIN 시트를 띄운다. 같은 순간에 닫고 띄우면 PIN 시트가 빠질 수 있다.
    @State private var queuedTask: PINTask?
    /// 키체인에 글자가 남아 있는 연결. 목록을 읽을 때만 키체인을 본다.
    @State private var copyableIDs: Set<String> = []
    /// 끊기 전 확인(CUE1110A01). 끊으면 그 AI가 보내 두고 아직 반영되지 않은 명령도 서버에서 지워진다.
    @State private var pendingRevoke: AssistantScopedKey?

    var body: some View {
        Section {
            if let keys {
                if keys.isEmpty {
                    Text(language.text("AI 연결이 없어요", "No AI connections")).foregroundStyle(.secondary)
                }
                ForEach(keys) { row($0) }
            } else {
                ProgressView()
            }
            Button(language.text("AI 연결 추가", "Add AI connection")) { isAdding = true }.disabled(isWorking)
            if let message { Text(message).font(.taptionStyle(.footnote)).foregroundStyle(.secondary) }
        } header: {
            Text(language.text("연결 키 관리", "Connection keys"))
        } footer: {
            Text(language.text(
                "AI에는 여기서 만든 연결 키만 건네세요. 「기록 수정 허용」을 끄면 기록을 읽기만 해요. 연결을 만들면 연결 안내가 복사돼요.",
                "Give the AI only connection keys made here. With \"Allow record edits\" off it can only read. Creating a connection copies the setup."
            ))
        }
        .task(id: masterKey) { await reload() }
        .sheet(isPresented: $isAdding, onDismiss: {
            pinTask = queuedTask
            queuedTask = nil
        }) {
            AssistantConnectionForm(language: language) { label, scope, period in
                queuedTask = .create(label: label, scope: scope, period: period)
                isAdding = false
            }
        }
        .sheet(item: $pinTask) { task in
            AssistantPINSheet.gate(language: language) { pin in await run(task, pin: pin) }
        }
        .confirmationDialog(
            language.text("이 연결을 끊을까요?", "Disconnect this AI?"), isPresented: revokeDialog, titleVisibility: .visible, presenting: pendingRevoke
        ) { key in
            Button(language.text("연결 끊기", "Disconnect"), role: .destructive) { revoke(key.id) }
            Button(language.text("취소", "Cancel"), role: .cancel) {}
        } message: { key in
            Text(AssistantKeyText.revokeWarning(label(key), language: language))
        }
    }

    private func label(_ key: AssistantScopedKey) -> String {
        AssistantKeyLabels.label(key.id) ?? key.client ?? language.text("이름 없는 연결", "Unnamed connection")
    }

    private func expiryText(_ key: AssistantScopedKey) -> String {
        guard let expiresAt = key.expiresAt else { return language.text("만료 없음", "No expiry") }
        return expiresAt <= .now
            ? language.text("끝남", "Expired")
            : language.text("\(AssistantKeyText.date(expiresAt))까지", "Until \(AssistantKeyText.date(expiresAt))")
    }

    private func row(_ key: AssistantScopedKey) -> some View {
        let expired = key.expiresAt.map { $0 <= .now } ?? false
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(label(key), systemImage: key.scope == .write ? "pencil.circle" : "eye")
                Spacer()
                Text(key.scope.title(language)).font(.taptionStyle(.footnote)).foregroundStyle(.secondary)
            }
            if let host = key.host, !host.isEmpty { Text(host).font(.footnote.monospaced()).foregroundStyle(.secondary) }
            Text(expiryText(key)).font(.taptionStyle(.footnote)).foregroundStyle(expired || key.expiresSoon() ? .red : .secondary)
            // OAuth 연결의 권한은 승인 화면에서 정해져 여기서 바꾸지 않는다.
            if key.source != "oauth" {
                Toggle(language.text("기록 수정 허용", "Allow record edits"), isOn: Binding(
                    get: { key.scope == .write },
                    set: { ask(key, scope: $0 ? .write : .read) }
                ))
            }
            HStack {
                if copyableIDs.contains(key.id), !expired {
                    Button(copiedID == key.id ? language.text("복사했어요", "Copied") : language.text("연결 안내 복사", "Copy setup")) {
                        if let token = AssistantKeyStore.token(for: key.id) { Task { await copy(token: token, key: key) } }
                    }
                }
                if key.expiresSoon(), key.source != "oauth" {
                    Button(language.text("연장", "Extend")) { ask(key, scope: key.scope) }
                }
                Spacer()
                Button(language.text("연결 끊기", "Disconnect"), role: .destructive) { pendingRevoke = key }
            }
            .buttonStyle(.borderless)
        }
        .disabled(isWorking)
    }

    private func reload() async {
        await store.reload()
        let next = Set((store.keys ?? []).map(\.id).filter { AssistantKeyStore.token(for: $0) != nil })
        if next != copyableIDs { copyableIDs = next }
        if store.loadFailed { message = language.text("연결 목록을 읽지 못했어요.", "Couldn't load the connections.") }
    }

    private func ask(_ key: AssistantScopedKey, scope: AssistantKeyScope) {
        guard !isWorking else { return }
        pinTask = .replace(key, scope: scope)
    }

    /// PIN과 함께 키를 올린다. 연장·권한 바꾸기는 같은 키·이름·기간으로 다시 올려 서버의 권한을 바로 바꾼다.
    /// 기기에 키 글자가 없는 연결은 새 키를 만들고 예전 키를 곧바로 폐기한다.
    private func run(_ task: PINTask, pin: String) async -> String? {
        isWorking = true
        defer { isWorking = false }
        let label: String, scope: AssistantKeyScope, period: AssistantKeyPeriod, old: AssistantScopedKey?
        switch task {
        case let .create(name, chosen, length):
            (label, scope, period, old) = (name, chosen, length, nil)
        case let .replace(key, chosen):
            label = AssistantKeyLabels.label(key.id) ?? language.text("이름 없는 연결", "Unnamed connection")
            (scope, period, old) = (chosen, AssistantKeyLabels.period(key.id), key)
        }
        let kept = old.flatMap { AssistantKeyStore.token(for: $0.id) }
        let provider = old.flatMap { AssistantKeyProviders.provider($0.id) }
        switch await TripRelay.registerScopedKey(label: label, scope: scope, period: period, pin: pin, provider: provider, existing: kept) {
        case let .created(key, token):
            message = await finish(key, token: token, replacing: kept == nil ? old : nil, updated: kept != nil)
            await reload()
            return nil
        case let .refused(refusal):
            return refusal.text(language)
        case .failed:
            return old == nil ? language.text("연결을 만들지 못했어요.", "Couldn't create the connection.")
                : language.text("연결을 바꾸지 못했어요.", "Couldn't update the connection.")
        }
    }

    /// 만든 뒤 할 일과 보여 줄 문구. 새 키로 갈았으면 예전 키를 기다리지 않고 폐기한다.
    private func finish(_ key: AssistantScopedKey, token: String, replacing old: AssistantScopedKey?, updated: Bool) async -> String {
        if updated { return language.text("연결을 바꿨어요. AI에 다시 붙여 넣지 않아도 돼요.", "Connection updated. No need to paste it again.") }
        await copy(token: token, key: key)
        if let old, await !TripRelay.revokeScopedKey(old.id) {
            return language.text("새 연결 안내를 복사했어요. 예전 키는 폐기하지 못했으니 목록에서 폐기해 주세요.",
                                 "New setup copied. The old key couldn't be revoked; revoke it in the list.")
        }
        return language.text("연결 안내를 복사했어요. AI에 붙여 넣어 주세요.", "Setup copied. Paste it into the AI.")
    }

    private func copy(token: String, key: AssistantScopedKey) async {
        // 이 기기에만 10분 동안 둔다(SEC1110A02). 키 대신 1회용 주소를 먼저 쓴다(SET1110A01).
        // Cue는 MCP 주소와 키를 따로 넣으므로 키만 복사한다(CUE1110A01).
        if AssistantKeyProviders.provider(key.id) == .cue {
            AssistantClipboard.copy(token)
        } else {
            let full = TripRelay.assistantSetupText(host: host, key: token, scope: key.scope, expiresAt: key.expiresAt)
            AssistantClipboard.copy(await TripRelay.setupLinkText(for: full) ?? full)
        }
        copiedID = key.id
    }

    private var revokeDialog: Binding<Bool> {
        Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } })
    }

    private func revoke(_ id: String) {
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            if await TripRelay.revokeScopedKey(id) {
                await reload()
            } else {
                message = language.text("연결을 끊지 못했어요. 인터넷 연결을 확인하고 다시 해 주세요.", "Couldn't disconnect. Check your connection and try again.")
            }
        }
    }
}

/// 「AI 연결 추가」: 이름(필수, 20자까지), 기록 수정 허용(기본 켬), 기간(기본 90일).
struct AssistantConnectionForm: View {
    let language: MapHomeLanguage
    let onCreate: (String, AssistantKeyScope, AssistantKeyPeriod) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var allowsEdits = true
    @State private var period = AssistantKeyPeriod.quarter

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(language.text("이름 (예: 피클, ChatGPT)", "Name (e.g. Pickle, ChatGPT)"), text: $name)
                    if name.count > AssistantKeyLabels.maxLength {
                        Text(language.text("이름은 20자까지예요.", "Names can be up to 20 characters."))
                            .font(.taptionStyle(.footnote)).foregroundStyle(.red)
                    }
                    Toggle(language.text("기록 수정 허용", "Allow record edits"), isOn: $allowsEdits)
                    Picker(language.text("사용 기간", "Valid for"), selection: $period) {
                        ForEach(AssistantKeyPeriod.allCases) { Text($0.title(language)).tag($0) }
                    }
                    if period == .never {
                        Text(language.text("키가 새면 직접 폐기해야 해요.", "If the key leaks, you have to revoke it yourself."))
                            .font(.taptionStyle(.footnote)).foregroundStyle(.orange)
                    }
                } footer: {
                    Text(language.text("이름은 이 기기에만 저장돼요.", "The name is stored only on this device."))
                }
            }
            .navigationTitle(language.text("AI 연결 추가", "Add AI connection"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(language.text("취소", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("만들기", "Create")) {
                        if let label = AssistantKeyLabels.clean(name) { onCreate(label, allowsEdits ? .write : .read, period) }
                    }
                    .disabled(AssistantKeyLabels.clean(name) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// AI가 할 수 있는 일을 하나씩 켜고 끈다(AIR1110A02).
struct AssistantActionTogglesView: View {
    let language: MapHomeLanguage
    @State private var enabled: [AssistantActionKind: Bool] = Dictionary(
        uniqueKeysWithValues: AssistantActionKind.allCases.map { ($0, AssistantActionToggles.isEnabled($0)) }
    )

    var body: some View {
        Form {
            Section {
                ForEach(AssistantActionKind.allCases) { kind in
                    Toggle(kind.title(language), isOn: Binding(
                        get: { enabled[kind] ?? true },
                        set: { value in
                            enabled[kind] = value
                            AssistantActionToggles.set(kind, enabled: value)
                        }
                    ))
                }
            } footer: {
                Text(language.text(
                    "끈 일은 AI가 보내도 반영하지 않고 거절로 알려요.",
                    "Actions you turn off are not applied; the AI is told they were rejected."
                ))
            }
        }
        .navigationTitle(language.text("AI가 할 수 있는 일", "What the AI can do"))
    }
}

/// 「AI가 한 일」 최근 200개. 항목마다 되돌리기(AIR1110A02).
struct AssistantActionLogView: View {
    let model: AppModel
    let language: MapHomeLanguage
    @State private var entries: [AssistantLogEntry] = []
    @State private var workingID: UUID?
    @State private var failedID: UUID?

    var body: some View {
        List {
            if entries.isEmpty {
                Text(language.text("아직 AI가 한 일이 없어요", "The AI hasn't done anything yet")).foregroundStyle(.secondary)
            }
            ForEach(entries) { row($0) }
        }
        .navigationTitle(language.text("AI가 한 일", "What the AI did"))
        .onAppear { entries = AssistantActionLog.load() }
    }

    private func row(_ entry: AssistantLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.kind.title(language)).font(.taptionStyle(.subheadline, weight: .semibold))
                Spacer()
                Text(entry.appliedAt.formatted(date: .abbreviated, time: .shortened)).font(.taptionStyle(.caption)).foregroundStyle(.secondary)
            }
            Text("\(entry.before.isEmpty ? language.text("새로", "New") : entry.before) → \(entry.after)")
                .font(.taptionStyle(.footnote))
            if let connection = entry.connection {
                Text(language.text("보낸 연결: \(connection)", "From: \(connection)")).font(.taptionStyle(.caption)).foregroundStyle(.secondary)
            }
            if entry.undoneAt != nil {
                Text(language.text("되돌렸어요", "Undone")).font(.taptionStyle(.caption)).foregroundStyle(.secondary)
            } else {
                Button(language.text("되돌리기", "Undo")) { undo(entry) }
                    .buttonStyle(.borderless)
                    .disabled(workingID != nil)
            }
            if failedID == entry.id {
                Text(language.text("그 뒤에 바뀐 내용이 있어 되돌리지 못했어요.", "It changed afterwards, so it couldn't be undone."))
                    .font(.taptionStyle(.caption)).foregroundStyle(.red)
            }
        }
    }

    private func undo(_ entry: AssistantLogEntry) {
        workingID = entry.id
        Task { @MainActor in
            defer { workingID = nil }
            if await model.undoAssistantEntry(entry) {
                AssistantActionLog.markUndone(entry.id)
                failedID = nil
                entries = AssistantActionLog.load()
            } else {
                failedID = entry.id
            }
        }
    }
}

/// 기존 항목을 20개 넘게 바꾸는 묶음을 반영하기 전에 묻는다(AIR1110A02).
struct AssistantConfirmHost: View {
    let model: AppModel
    let language: MapHomeLanguage
    let onNotice: (String?) -> Void
    private var inbox: AssistantInbox { .current }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .sheet(isPresented: Binding(get: { inbox.pending != nil }, set: { if !$0 { inbox.pending = nil } })) {
                if let batch = inbox.pending { confirmSheet(batch) }
            }
    }

    private func confirmSheet(_ batch: AssistantCommandBatch) -> some View {
        let counts = Dictionary(grouping: batch.commands.filter { AssistantActionToggles.isEnabled($0.action.kind) }, by: \.action.kind)
        let total = AssistantBatchPolicy.changeCount(batch, plans: model.snapshot.plans)
        return NavigationStack {
            List {
                Section {
                    Text(language.text(
                        "AI 비서가 기존 항목 \(total)개를 한꺼번에 바꾸려고 해요. 반영할까요?",
                        "The AI assistant wants to change \(total) existing items at once. Apply?"
                    ))
                    ForEach(AssistantActionKind.allCases.filter { counts[$0] != nil }) { kind in
                        LabeledContent(kind.title(language), value: "\(counts[kind]?.count ?? 0)")
                    }
                }
                Section {
                    Button(language.text("모두 반영", "Apply all")) { finish(batch, apply: true) }
                    Button(language.text("반영하지 않기", "Don't apply"), role: .destructive) { finish(batch, apply: false) }
                } footer: {
                    Text(language.text("반영한 뒤에도 「AI가 한 일」에서 하나씩 되돌릴 수 있어요. 닫으면 다음에 다시 물어요.",
                                       "You can still undo each one in What the AI did. If you close this, you'll be asked again next time."))
                }
            }
            .navigationTitle(language.text("AI 비서 요청 확인", "Review AI assistant requests"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func finish(_ batch: AssistantCommandBatch, apply: Bool) {
        inbox.pending = nil
        Task { @MainActor in
            if apply {
                onNotice(await AssistantCommandRunner.apply(batch, model: model)?.notice(language))
            } else {
                await AssistantCommandRunner.decline(batch)
            }
        }
    }
}
