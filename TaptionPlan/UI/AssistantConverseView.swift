import SwiftUI

/// 앱 안 AI 대화(AI1121A01). 말이나 글로 계획을 이야기하면 답과 「넣을 것」 후보가 오고, 고른 것만 눌러서 반영한다.
/// 길: ① 「메모: …」는 모델 없이 → ② 메모 다듬기는 Apple 모델(PCC·기기) → ③ 나머지 대화·여행 짜기는 중계 서버의 Bedrock.
/// 음성은 기기 안 음성 인식(`MapHomeDictation`)으로 글자만 받는다. 좌표·카드번호는 보내기 전에 지운다.
struct AssistantConverseButton: View {
    let model: AppModel
    let language: MapHomeLanguage
    @State private var isOpen = false

    var body: some View {
        Button { isOpen = true } label: {
            Label(language.text("AI와 대화로 계획하기", "Plan by chatting with AI"), systemImage: "bubble.left.and.text.bubble.right")
                .font(.taptionStyle(.caption, weight: .semibold))
                .foregroundStyle(Color.tpAccent)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isOpen) { AssistantConverseView(model: model, language: language) }
    }
}

struct AssistantConverseView: View {
    let model: AppModel
    let language: MapHomeLanguage

    /// 화면에서 고를 후보. 반영하기 전에는 아무것도 바뀌지 않는다.
    struct Proposal {
        var batch: AssistantCommandBatch
        var selected: Set<String>
        var trip: String?
    }

    private struct TripDraft: Identifiable {
        let id = UUID()
        let text: String
    }

    @Environment(\.dismiss) private var dismiss
    @State private var messages: [AssistantConverse.Message] = []
    @State private var input = ""
    @State private var isSending = false
    @State private var proposal: Proposal?
    @State private var note: String?
    @State private var dictation = MapHomeDictation()
    @State private var tripDraft: TripDraft?
    @FocusState private var inputFocused: Bool

    private var serverReady: Bool { TripRelay.host != nil && AssistantRegistration.isReady(.live) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if messages.isEmpty { intro }
                            ForEach(Array(messages.enumerated()), id: \.offset) { _, message in bubble(message) }
                            if isSending { ProgressView().frame(maxWidth: .infinity) }
                            if let proposal { proposalCard(proposal) }
                            if let note { Text(note).font(.taptionStyle(.caption)).foregroundStyle(Color.tpSecondary) }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(16)
                    }
                    .onChange(of: messages.count) { _, _ in withAnimation { proxy.scrollTo("end") } }
                }
                inputBar
            }
            .navigationTitle(language.text("AI와 계획하기", "Plan with AI"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(language.text("닫기", "Close")) { dismiss() } }
            }
        }
        .onAppear { wireDictation() }
        .onDisappear { dictation.stop() }
        .sheet(item: $tripDraft) { draft in
            MapHomeTripImportSheet(model: model, language: language, initialText: draft.text)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(language.text("예: 「내일 3시 치과, 점심 12,000원 썼어」, 「다음 주 부산 2박 3일 짜 줘」",
                               "e.g. \"Dentist tomorrow at 3, spent 12,000 won on lunch\" or \"Plan a 3-day trip next week\""))
            Text(language.text("AI가 제안한 것은 아래에서 고른 뒤 「반영」을 눌러야 들어가요. 위치 좌표와 카드번호는 보내지 않아요.",
                               "Nothing changes until you pick suggestions and tap Apply. Coordinates and card numbers are never sent."))
                .foregroundStyle(Color.tpSecondary)
        }
        .font(.taptionStyle(.caption))
    }

    private func bubble(_ message: AssistantConverse.Message) -> some View {
        let mine = message.role == .user
        return HStack {
            if mine { Spacer(minLength: 40) }
            Text(message.text)
                .font(.taptionStyle(.body))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(mine ? Color.tpAccent.opacity(0.18) : Color.tpSurface, in: RoundedRectangle(cornerRadius: 14))
                .textSelection(.enabled)
            if !mine { Spacer(minLength: 40) }
        }
    }

    private func proposalCard(_ proposal: Proposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.text("넣을 것 고르기", "Pick what to add"))
                .font(.taptionStyle(.caption, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
            ForEach(proposal.batch.commands, id: \.id) { command in
                Toggle(isOn: Binding(
                    get: { self.proposal?.selected.contains(command.id) ?? false },
                    set: { on in
                        if on { self.proposal?.selected.insert(command.id) } else { self.proposal?.selected.remove(command.id) }
                    }
                )) {
                    Text(Self.describe(command, language: language)).font(.taptionStyle(.callout))
                }
            }
            if proposal.trip != nil {
                Button {
                    if let trip = proposal.trip { tripDraft = TripDraft(text: trip) }
                } label: {
                    Label(language.text("여행 계획 초안 미리 보기", "Preview trip plan draft"), systemImage: "airplane")
                }
            }
            if !proposal.batch.commands.isEmpty {
                HStack {
                    Button(language.text("반영", "Apply")) { apply(proposal) }
                        .buttonStyle(.borderedProminent)
                        .disabled(proposal.selected.isEmpty)
                    Button(language.text("넣지 않기", "Skip"), role: .destructive) { self.proposal = nil }
                }
            }
        }
        .padding(12)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button {
                if dictation.isListening { dictation.stop() } else {
                    Task { await dictation.start(localeIdentifier: MapHomeDictation.speechLocaleIdentifier()) }
                }
            } label: {
                Image(systemName: dictation.isListening ? "stop.circle.fill" : "mic.fill")
                    .font(.title3)
                    .foregroundStyle(dictation.isListening ? Color.red : Color.tpAccent)
            }
            .accessibilityLabel(language.text(dictation.isListening ? "받아쓰기 멈추기" : "말로 입력", dictation.isListening ? "Stop dictation" : "Dictate"))
            TextField(language.text("무엇을 계획할까요?", "What should we plan?"), text: $input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { send() }
            Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .disabled(isSending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(language.text("보내기", "Send"))
        }
        .padding(12)
        .background(.bar)
    }

    // MARK: 흐름

    private func wireDictation() {
        dictation.onPartial = { input = $0 }
        dictation.onTranscribed = { input = $0 }
        // 대화에는 녹음 파일이 필요 없다. 글자만 쓰고 바로 지운다.
        dictation.onRecorded = { try? FileManager.default.removeItem(at: $0) }
        if let error = dictation.errorMessage { note = error }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        if dictation.isListening { dictation.stop() }
        let intent = AssistantConverseRouter.intent(text, isFirstTurn: messages.isEmpty)
        messages.append(.init(role: .user, text: text))
        input = ""
        note = nil
        proposal = nil
        isSending = true
        Task { @MainActor in
            defer { isSending = false }
            await handle(intent)
        }
    }

    private func handle(_ intent: AssistantConverseIntent) async {
        var apple: AppleModelDecision?
        if case .polish(let body) = intent { apple = AppleModelRouter.decide(AppleModelEnvironment.conditions(.memoPolish, text: body)) }
        switch AssistantConverseRouter.route(intent, apple: apple, serverReady: serverReady) {
        case .local:
            if case .quickMemo(let body) = intent { proposeMemo(body, reply: language.text("이렇게 메모해 둘까요?", "Save this memo?")) }
        case .apple:
            if case .polish(let body) = intent, let polished = (try? await MemoTextPolisher.polish(body))?.text {
                proposeMemo(polished, reply: polished)
            } else if serverReady {
                await askServer()
            } else {
                say(language.text("지금은 다듬을 수 없어요.", "Can't polish that right now."))
            }
        case .server:
            await askServer()
        case .unavailable:
            say(serverReady || apple?.notice == .keepsCoordinates
                ? language.text("위치 좌표가 든 글은 기기 밖으로 보내지 않아요.", "Text with coordinates stays on this device.")
                : language.text("AI 연결이 아직 없어요. 메뉴 › AI 연결에서 이 기기를 등록해 주세요.", "No AI connection yet. Register this device in Menu › AI connection."))
        }
    }

    private func askServer() async {
        let context = AssistantConverse.Context.now(language: language == .english ? "en" : "ko")
        switch await AssistantConverse.send(messages, context: withCategories(context), env: .live) {
        case .success(let reply):
            say(reply.text.isEmpty ? language.text("제안을 확인해 주세요.", "Please review the suggestions.") : reply.text)
            var batch = AssistantCommandParser.parse(reply.commandsJSON) ?? AssistantCommandBatch(commands: [], invalidIDs: [])
            batch.commands = batch.commands.map { var command = $0; command.source = "bedrock"; return command }
            if !batch.commands.isEmpty || reply.tripJSON != nil {
                proposal = Proposal(batch: AssistantCommandBatch(commands: batch.commands, invalidIDs: []), selected: Set(batch.commands.map(\.id)), trip: reply.tripJSON)
            }
            if !reply.redacted.isEmpty { note = language.text("위치·카드번호 같은 정보는 빼고 보냈어요.", "Location and card numbers were removed before sending.") }
        case .failure(let failure):
            say(message(for: failure))
        }
    }

    private func withCategories(_ context: AssistantConverse.Context) -> AssistantConverse.Context {
        var context = context
        context.categories = model.snapshot.categories.filter { !$0.isHidden }.prefix(30).map { (id: $0.id, name: $0.name) }
        return context
    }

    private func proposeMemo(_ text: String, reply: String) {
        say(reply)
        let command = AssistantCommand(id: "app-\(UUID().uuidString.prefix(12))", action: .addMemo(text: text, at: .now), source: "app")
        proposal = Proposal(batch: AssistantCommandBatch(commands: [command], invalidIDs: []), selected: [command.id], trip: nil)
    }

    private func say(_ text: String) { messages.append(.init(role: .assistant, text: text)) }

    private func apply(_ proposal: Proposal) {
        let chosen = proposal.batch.commands.filter { proposal.selected.contains($0.id) }
        self.proposal = nil
        Task { @MainActor in
            // 「AI가 한 일」에 남겨 하나씩 되돌릴 수 있게 장부를 쓰되, 큐에서 온 명령이 아니므로 서버 결과 보내기에서는 뺀다.
            let journal = AssistantCommandJournal(defaults: .standard)
            let outcome = await model.applyAssistantCommands(AssistantCommandBatch(commands: chosen, invalidIDs: []), journal: journal)
            journal.delivered(chosen.map(\.id))
            note = outcome?.notice(language) ?? language.text("지금은 반영할 수 없어요. 잠시 뒤 다시 해 주세요.", "Can't apply right now. Try again shortly.")
        }
    }

    private func message(for failure: AssistantConverse.Failure) -> String {
        switch failure {
        case .notConnected: language.text("AI 연결이 아직 없어요. 메뉴 › AI 연결에서 이 기기를 등록해 주세요.", "No AI connection yet. Register this device in Menu › AI connection.")
        case .unavailable: language.text("서버 AI가 아직 켜져 있지 않아요.", "The server AI isn't turned on yet.")
        case .limited(_, let daily): daily
            ? language.text("오늘 쓸 수 있는 AI 대화를 다 썼어요. 내일 다시 해 주세요.", "You've used today's AI chats. Try again tomorrow.")
            : language.text("AI가 바빠요. 잠시 뒤 다시 해 주세요.", "The AI is busy. Try again shortly.")
        case .rejected: language.text("대화가 너무 길어요. 짧게 나눠 보내 주세요.", "That's too long. Please send it in shorter parts.")
        case .network: language.text("인터넷 연결을 확인해 주세요.", "Check your internet connection.")
        case .server: language.text("AI가 답하지 못했어요. 잠시 뒤 다시 해 주세요.", "The AI couldn't answer. Try again shortly.")
        }
    }

    static func describe(_ command: AssistantCommand, language: MapHomeLanguage) -> String {
        let day = Date.FormatStyle(date: .abbreviated, time: .omitted)
        let moment = Date.FormatStyle(date: .abbreviated, time: .shortened)
        switch command.action {
        case let .addMemo(text, _): return language.text("메모", "Memo") + " · " + text
        case let .addSchedule(title, start, _, _, _): return language.text("일정", "Schedule") + " · " + title + " · " + start.formatted(moment)
        case let .addExpense(entry):
            let amount = entry.amount.formatted(.number.precision(.fractionLength(0...2)))
            return language.text("가계부", "Ledger") + " · " + entry.title + " · " + amount + " " + entry.currency
        case let .addTripStop(title, date, _, _, _): return language.text("여행 일정", "Trip stop") + " · " + title + " · " + date.formatted(day)
        case let .addGoal(title, start, _, _): return language.text("목표", "Goal") + " · " + title + " · " + start.formatted(day)
        case let .addTrip(trip): return language.text("여행", "Trip") + " · " + trip.title + " · " + trip.startDay
        default: return command.action.kind.title(language)
        }
    }
}
