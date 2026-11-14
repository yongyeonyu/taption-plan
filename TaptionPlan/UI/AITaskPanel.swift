import SwiftUI

/// 메모 패널 「AI」 탭(AIQ1111A01): AI에게 맡긴 일과 상태(대기·처리중·완료·실패), 끝난 것 지우기.
/// 앱이 못 읽은 결제 문자·영수증, 메모 다듬기처럼 AI가 처리할 것이 여기 쌓이고, 처리됐는지 이 목록으로 본다.
struct AITaskPanel: View {
    /// 「내역」 탭은 받은 문자·알림, 「AI」 탭은 맡긴 일과 AI가 한 일(INB1114A01). 둘 다 고른 날 것만.
    enum Section { case inbox, ai }

    let language: MapHomeLanguage
    let day: Date
    var section: Section = .ai
    @State private var log: [AssistantLogEntry] = []

    @State private var tasks: [AITaskQueue.Task] = []
    @State private var isLoading = false
    @State private var inbox: [PaymentInbox.Item] = []
    @State private var opened: PaymentInbox.Item?
    @State private var requestNote: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch section {
            case .inbox: inboxSection
            case .ai: aiSection
            }
        }
        .task {
            tasks = Self.merged()
            inbox = PaymentInbox.items().reversed()
            log = AssistantActionLog.load()
            await reload()
        }
        .sheet(item: $opened, onDismiss: { inbox = PaymentInbox.items().reversed(); tasks = Self.merged() }) {
            PaymentInboxDetail(language: language, item: $0)
        }
    }

    @ViewBuilder
    private var inboxSection: some View {
        let items = inbox.filter { Self.isOn(day, $0.receivedAt) }
        if items.isEmpty {
            note(language.text("그날 받은 결제 문자·알림이 없어요.", "No payment texts or alerts that day."))
        } else {
            ScrollView(showsIndicators: false) {
                PaymentInboxList(language: language, items: items) { opened = $0 }
            }
            .frame(maxHeight: 360)
        }
    }

    @ViewBuilder
    private var aiSection: some View {
        let shown = Self.tasks(tasks, on: day)
        let done = log.filter { Self.isOn(day, $0.appliedAt) }
        AssistantQuestionList(language: language)
        if !MemoPolishQueue.hasConnection() {
            note(language.text("AI 연결이 없어요. 메뉴 › AI 연결에서 연결하면 앱이 못한 일을 AI가 처리해요.",
                               "No AI is connected. Connect one in Menu › AI connection to let it handle what the app couldn't."))
        } else if shown.isEmpty, done.isEmpty, AssistantQuestionStore.shared.items.isEmpty {
            note(isLoading ? language.text("불러오는 중…", "Loading…") : language.text("그날 AI에게 맡긴 일이 없어요.", "Nothing was handed to your AI that day."))
        }
        // 서버는 AI를 깨울 수 없다. 그날 기다리는 일이 있으면 눌러서 연결된 AI 앱을 열고 요청 글을 붙여 넣게 한다(AIG1114A01).
        if shown.contains(where: { $0.status == .waiting || $0.status == .processing }) {
            Button { requestAI() } label: {
                Label(language.text("AI에게 요청하기", "Ask your AI now"), systemImage: "paperplane.fill")
                    .font(.taptionStyle(.caption, weight: .semibold))
                    .foregroundStyle(Color.tpAccent)
            }
            .buttonStyle(.plain)
            if let requestNote { note(requestNote) }
        }
        if !shown.isEmpty || !done.isEmpty {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shown) { row($0) }
                    if !done.isEmpty {
                        Text(language.text("AI가 한 일", "What the AI did"))
                            .font(.taptionStyle(.caption, weight: .semibold))
                            .foregroundStyle(Color.tpSecondary)
                        ForEach(done) { logRow($0) }
                    }
                }
            }
            .frame(maxHeight: 320)
            .refreshable { await reload() }
        }
        if shown.contains(where: { $0.status == .done || $0.status == .failed }) {
            Button {
                Task {
                    if await AITaskQueue.deleteFinished() { tasks = Self.merged() }
                }
            } label: {
                Label(language.text("끝난 일 지우기", "Clear finished"), systemImage: "trash")
                    .font(.taptionStyle(.caption, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    /// 「AI가 한 일」 한 줄: 무엇을, 전 → 후, 어느 AI가, 언제. 되돌리기는 메뉴 › AI가 한 일에서 한다.
    private func logRow(_ entry: AssistantLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.kind.title(language)).font(.taptionStyle(.caption, weight: .semibold)).foregroundStyle(Color.tpInk)
                Spacer(minLength: 0)
                Text(entry.appliedAt.formatted(date: .omitted, time: .shortened)).font(.taptionStyle(.caption2)).foregroundStyle(Color.tpSecondary)
            }
            Text("\(entry.before.isEmpty ? language.text("새로", "New") : entry.before) → \(entry.after)")
                .font(.taptionStyle(.caption)).foregroundStyle(Color.tpInk).lineLimit(2)
            if let connection = AssistantConnectionName.shown(entry) {
                Text(connection + (entry.undoneAt == nil ? "" : " · " + language.text("되돌렸어요", "Undone")))
                    .font(.taptionStyle(.caption2)).foregroundStyle(Color.tpSecondary)
            }
        }
        .padding(8)
        .background(Color.tpCard.opacity(0.9), in: RoundedRectangle(cornerRadius: TaptionCorner.small, style: .continuous))
    }

    nonisolated static func isOn(_ day: Date, _ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        calendar.isDate(date, inSameDayAs: day)
    }

    /// 그날 맡긴 일. 맡긴 때를 모르는 것(아직 못 올린 것)은 오늘로 본다.
    nonisolated static func tasks(_ tasks: [AITaskQueue.Task], on day: Date, now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> [AITaskQueue.Task] {
        tasks.filter { isOn(day, $0.createdAt ?? now, calendar: calendar) }
    }


    private func requestAI() {
        AssistantClipboard.copy(AITaskRequest.prompt)
        let provider = AITaskRequest.provider()
        requestNote = language.text("요청 글을 복사했어요. \(provider.title(language))에 붙여 넣고 보내 주세요.", "Request copied. Paste it into \(provider.title(language)) and send.")
        if let url = AITaskRequest.chatURL(provider) ?? provider.destination(installed: provider.isInstalled) { openURL(url) }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        await AITaskQueue.refresh()
        let next = Self.merged()
        if next != tasks { tasks = next }
    }

    /// 서버 목록 + 아직 못 올린 항목 + 메모 다듬기 목록(따로 `/polish`로 간다).
    private static func merged() -> [AITaskQueue.Task] {
        let pending = AITaskQueue.pendingUploads().map {
            AITaskQueue.Task(id: $0.id, kind: $0.kind, text: $0.text, date: $0.date, status: .waiting)
        }
        let polish = MemoPolishQueue.items().map {
            AITaskQueue.Task(id: "polish-" + $0.memoID.uuidString, kind: .memoPolish, text: $0.text, date: $0.date, status: .waiting)
        }
        let order: [AITaskQueue.Status: Int] = [.processing: 0, .waiting: 1, .failed: 2, .done: 3]
        return (pending + polish + AITaskQueue.cached()).sorted {
            (order[$0.status] ?? 9, -($0.createdAt?.timeIntervalSince1970 ?? .infinity))
                < (order[$1.status] ?? 9, -($1.createdAt?.timeIntervalSince1970 ?? .infinity))
        }
    }

    private func row(_ task: AITaskQueue.Task) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(task.kind))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.tpAccent)
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.9), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title(task.kind))
                        .font(.taptionStyle(.subheadline, weight: .medium))
                        .foregroundStyle(Color.tpInk)
                    Spacer(minLength: 0)
                    statusChip(task.status)
                }
                if let detail = task.result ?? task.reason ?? task.text {
                    Text(detail)
                        .font(.taptionStyle(.caption))
                        .foregroundStyle(task.status == .failed ? Color.tpHoliday : Color.tpSecondary)
                        .lineLimit(3)
                }
                if let date = task.updatedAt ?? task.createdAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.taptionStyle(.caption2))
                        .foregroundStyle(Color.tpSecondary)
                }
            }
        }
        .padding(10)
        .background(Color.tpCard.opacity(0.9), in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous).stroke(Color.tpBorder, lineWidth: TaptionBorder.width) }
    }

    private func statusChip(_ status: AITaskQueue.Status) -> some View {
        let (text, color): (String, Color) = switch status {
        case .waiting: (language.text("대기", "Waiting"), Color.tpSecondary)
        case .processing: (language.text("처리중", "Working"), Color.tpReferenceBlue)
        case .done: (language.text("완료", "Done"), Color.tpReferenceMint)
        case .failed: (language.text("실패", "Failed"), Color.tpHoliday)
        }
        return Text(text)
            .font(.taptionStyle(.caption2, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.taptionStyle(.caption))
            .foregroundStyle(Color.tpSecondary)
            .padding(.horizontal, 4)
    }

    private func title(_ kind: AITaskQueue.Kind) -> String {
        switch kind {
        case .paymentText: language.text("결제 문자 확인", "Payment text")
        case .receiptText: language.text("영수증 확인", "Receipt")
        case .memoPolish: language.text("메모 다듬기", "Polish memo")
        case .routeCheck: language.text("경로 확인", "Route check")
        case .fareCheck: language.text("교통비 확인", "Fare check")
        case .mergeReview: language.text("조각 합침 검토", "Merge review")
        case .stayPlace: language.text("머문 장소 확인", "Stay place")
        case .paymentRule: language.text("결제 문자 규칙 요청", "Payment rule request")
        case .other: language.text("기타 확인", "Other")
        }
    }

    private static func symbol(_ kind: AITaskQueue.Kind) -> String {
        switch kind {
        case .paymentText: "message"
        case .receiptText: "doc.text.viewfinder"
        case .memoPolish: "wand.and.stars"
        case .routeCheck: "point.topleft.down.to.point.bottomright.curvepath"
        case .fareCheck: "creditcard"
        case .mergeReview: "rectangle.compress.vertical"
        case .stayPlace: "mappin.and.ellipse"
        case .paymentRule: "text.badge.plus"
        case .other: "questionmark.bubble"
        }
    }
}

/// AI가 보낸 객관식 질문(ASK1112A01). 「AI」 탭 맨 위와 알림을 눌러 연 시트가 함께 쓴다.
/// 답하면 기기에 적고 서버에 올려 AI가 읽어 간다. 질문과 보기는 AI가 쓴 글이라 글로만 보인다(링크로 만들지 않는다).
struct AssistantQuestionList: View {
    let language: MapHomeLanguage
    var showsFinished = true
    private var store: AssistantQuestionStore { .shared }

    var body: some View {
        let waiting = store.waiting, finished = showsFinished ? Array(store.finished.suffix(3).reversed()) : []
        if !waiting.isEmpty || !finished.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(waiting) { question in
                    if let approval = question.approval {
                        AssistantApprovalCard(question: question, approval: approval, language: language)
                    } else {
                        AssistantQuestionCard(question: question, language: language)
                    }
                }
                ForEach(finished) { answered($0) }
                if !finished.isEmpty {
                    Button {
                        store.clearFinished()
                        Task { await store.uploadIfNeeded() }
                    } label: {
                        Label(language.text("끝난 질문 지우기", "Clear answered questions"), systemImage: "trash")
                            .font(.taptionStyle(.caption, weight: .semibold))
                            .foregroundStyle(Color.tpSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func answered(_ question: AssistantQuestion) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: question.approval?.title(language) ?? question.question)
                .font(.taptionStyle(.caption))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(2)
            Text(verbatim: question.status == .skipped
                ? language.text("건너뜀", "Skipped")
                : question.approval != nil
                    ? (question.choices == [AssistantApproval.approved] ? language.text("승인함", "Approved") : language.text("거절함", "Declined"))
                    : (question.choices + [question.text].compactMap { $0 }).joined(separator: " · "))
                .font(.taptionStyle(.subheadline, weight: .medium))
                .foregroundStyle(Color.tpInk)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.tpCard.opacity(0.9), in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous).stroke(Color.tpBorder, lineWidth: TaptionBorder.width) }
    }
}

/// 질문 하나. 하나만 고르는 질문은 보기를 누르면 바로 답하고, 여러 개 고르는 질문과 직접 입력은 「답하기」로 보낸다.
private struct AssistantQuestionCard: View {
    let question: AssistantQuestion
    let language: MapHomeLanguage
    @State private var picked: Set<String> = []
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(language.text("AI 질문", "AI question"), systemImage: "questionmark.bubble")
                .font(.taptionStyle(.caption2, weight: .semibold))
                .foregroundStyle(Color.tpAccent)
            Text(verbatim: question.question)
                .font(.taptionStyle(.subheadline, weight: .medium))
                .foregroundStyle(Color.tpInk)
                .fixedSize(horizontal: false, vertical: true)
            if question.multiSelect {
                Text(language.text("여러 개 고를 수 있어요.", "You can pick more than one."))
                    .font(.taptionStyle(.caption2))
                    .foregroundStyle(Color.tpSecondary)
            }
            ForEach(question.options, id: \.self) { option($0) }
            HStack(spacing: 6) {
                TextField(language.text("직접 입력", "Type your own answer"), text: $typed)
                    .font(.taptionStyle(.caption))
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit(send)
                Button(language.text("답하기", "Answer"), action: send)
                    .font(.taptionStyle(.caption, weight: .semibold))
                    .foregroundStyle(canSend ? Color.tpAccent : Color.tpSecondary)
                    .disabled(!canSend)
            }
            Button(language.text("건너뛰기", "Skip")) {
                AssistantQuestionStore.shared.skip(question.id)
                upload()
            }
            .font(.taptionStyle(.caption2))
            .foregroundStyle(Color.tpSecondary)
        }
        .buttonStyle(.plain)
        .padding(10)
        .background(Color.tpCard.opacity(0.9), in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous).stroke(Color.tpAccent.opacity(0.5), lineWidth: TaptionBorder.width) }
    }

    private var canSend: Bool {
        !picked.isEmpty || !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func option(_ text: String) -> some View {
        Button {
            if question.multiSelect {
                if !picked.insert(text).inserted { picked.remove(text) }
            } else {
                picked = [text]
                send()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: picked.contains(text) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(picked.contains(text) ? Color.tpAccent : Color.tpSecondary)
                Text(verbatim: text)
                    .font(.taptionStyle(.subheadline))
                    .foregroundStyle(Color.tpInk)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(picked.contains(text) ? .isSelected : [])
    }

    private func send() {
        guard AssistantQuestionStore.shared.answer(question.id, choices: Array(picked), text: typed) else { return }
        upload()
    }

    private func upload() {
        Task { await AssistantQuestionStore.shared.uploadIfNeeded() }
    }
}

/// 승인 요청 카드(ACD1112A01). 문구는 앱이 쓰고, 「승인」을 눌러야 실행된다. 결과는 AI가 읽어 간다.
private struct AssistantApprovalCard: View {
    let question: AssistantQuestion
    let approval: AssistantApproval
    let language: MapHomeLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(language.text("AI 승인 요청", "AI approval request"), systemImage: "hand.raised")
                .font(.taptionStyle(.caption2, weight: .semibold))
                .foregroundStyle(Color.tpHoliday)
            Text(verbatim: approval.title(language))
                .font(.taptionStyle(.subheadline, weight: .medium))
                .foregroundStyle(Color.tpInk)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: approval.detail(language))
                .font(.taptionStyle(.caption))
                .foregroundStyle(Color.tpSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(language.text("승인", "Approve")) { answer(AssistantApproval.approved) }
                    .font(.taptionStyle(.subheadline, weight: .semibold))
                    .foregroundStyle(Color.tpHoliday)
                Button(language.text("거절", "Decline")) { answer(AssistantApproval.declined) }
                    .font(.taptionStyle(.subheadline, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.tpCard.opacity(0.9), in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous).stroke(Color.tpHoliday.opacity(0.5), lineWidth: TaptionBorder.width) }
    }

    private func answer(_ choice: String) {
        guard AssistantQuestionStore.shared.answer(question.id, choices: [choice], text: nil) else { return }
        Task {
            if choice == AssistantApproval.approved { await approval.perform(model: AssistantCommandRefresh.model) }
            await AssistantQuestionStore.shared.uploadIfNeeded()
        }
    }
}

/// 새 질문이 오면 잠깐 알리고, 누르면 답하는 시트를 연다(ASK1112A01). 사생활 잠금 중에는 알리지 않는다.
struct AssistantQuestionHost: View {
    let language: MapHomeLanguage
    @Environment(\.scenePhase) private var scenePhase
    @State private var isPresented = false
    private var store: AssistantQuestionStore { .shared }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            if let question = store.announced, !TaptionExternalPrivacyStore.isLocked {
                Button {
                    store.announced = nil
                    isPresented = true
                } label: {
                    Label {
                        Text(verbatim: question.approval.map { language.text("AI 승인 요청", "AI approval request") + ": " + $0.title(language) }
                            ?? language.text("AI 질문", "AI question") + ": " + question.question).lineLimit(2)
                    } icon: {
                        Image(systemName: "questionmark.bubble")
                    }
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .mapHomeGlass(in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 144)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // 띠는 누를 때까지 남는다. 앱이 앞으로 올 때 답하지 않은 질문이 있으면 다시 알린다(ASN1112A01).
        .task(id: scenePhase == .active) {
            if scenePhase == .active, !isPresented { store.reannounce() }
        }
        .sheet(isPresented: $isPresented) {
            ScrollView {
                AssistantQuestionList(language: language, showsFinished: false)
                    .padding(16)
                if store.waiting.isEmpty {
                    Text(language.text("답할 질문이 없어요.", "No questions to answer."))
                        .font(.taptionStyle(.caption))
                        .foregroundStyle(Color.tpSecondary)
                        .padding(16)
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

/// 「AI에게 요청하기」(AIG1114A01): 붙여 넣을 글과 열 AI 앱.
enum AITaskRequest {
    /// AI가 읽는 글이라 영어로 둔다. 개인 정보는 없다.
    static let prompt = "Check BOKKI Plan now: call get_ai_tasks, handle every task as its kind says, then call complete_ai_task for each one, one at a time. Also check get_polish_requests and get_command_results. Reply in Korean with a short list of what you did."

    /// 요청 글이 채워진 새 대화 주소(앱이 있으면 앱에서, 없으면 웹에서 열린다). 주소가 없는 AI는 nil이라 앱만 연다.
    static func chatURL(_ provider: AssistantAIProvider, prompt: String = prompt) -> URL? {
        let base: String
        switch provider {
        case .claude: base = "https://claude.ai/new"
        case .chatGPT: base = "https://chatgpt.com/"
        default: return nil
        }
        var parts = URLComponents(string: base)
        parts?.queryItems = [URLQueryItem(name: "q", value: prompt)]
        return parts?.url
    }

    /// 연결된 AI 가운데 앱이 있는 것. 고른 AI → OAuth 앱 이름 순으로 찾고, 없으면 Claude.
    static func provider(defaults: UserDefaults = .standard) -> AssistantAIProvider {
        let chosen = (defaults.dictionary(forKey: AssistantKeyProviders.defaultsKey) as? [String: String] ?? [:]).values.compactMap(AssistantAIProvider.init(rawValue:))
        let clients = (defaults.dictionary(forKey: AssistantKeyLabels.clientsKey) as? [String: String] ?? [:]).values
        let named = AssistantAIProvider.featured.filter { provider in clients.contains(where: provider.matchesClient) }
        return (chosen + named).first { $0.scheme != nil } ?? .claude
    }
}
