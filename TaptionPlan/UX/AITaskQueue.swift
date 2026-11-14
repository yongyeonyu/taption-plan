import Foundation
import UserNotifications

/// 앱 설정·알림·진단을 쓰는 쪽과 지금 앱의 환경으로 부르는 길(PKG1114A19).
extension AITaskQueue {
    static func upload() async { await upload(env: .live) }

    static func deleteFinished() async -> Bool { await deleteFinished(env: .live) }

    /// 넣고 올린다. 연결된 AI가 없으면 넣지 않는다(맡길 곳이 없다).
    @discardableResult
    static func enqueue(_ kind: Kind, text: String, day: Date? = nil, context: [String: String]? = nil,
                        id: String = UUID().uuidString, defaults: UserDefaults = .standard) -> Bool {
        let masked = mask(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !masked.isEmpty, MemoPolishQueue.hasConnection(defaults) else { return false }
        var list = pendingUploads(defaults)
        list.append(Upload(id: id, kind: kind, text: String(masked.prefix(2_000)), date: day.map(dayText), context: context))
        if list.count > uploadLimit { list.removeFirst(list.count - uploadLimit) }
        save(list, defaults)
        TaptionPlanDiagnosticsLogger.shared.record("ai_task_enqueued", fields: ["kind": kind.rawValue])
        if defaults === UserDefaults.standard { _Concurrency.Task { await upload() } }
        return true
    }

    /// 서버 목록을 받아 둔다. 없으면 빈 목록.
    @discardableResult
    static func refresh(env: AssistantRegistration.Environment = .live) async -> [Task]? {
        await upload(env: env)
        guard let master = env.secrets.read(.master),
              let reply = await TripRelay.send(TripRelay.relayRequest("/tasks", method: "GET", query: [URLQueryItem(name: "v", value: "2")], token: master, host: env.host, client: env.client()), session: env.session)
        else { return nil }
        let tasks: [Task]
        switch reply.status {
        case 204: tasks = []
        case 200..<300: tasks = decodeList(reply.data)
        default: return nil
        }
        if let data = try? encoder.encode(tasks) { env.defaults.set(data, forKey: cacheKey) }
        // 서버 목록에 있는 일은 상태와 상관없이 이미 받은 것이다. 큐에 남아 있으면 지운다.
        acknowledge(tasks.map(\.id), defaults: env.defaults)
        ReceiptPhotoMarks.noteReviewed(tasks.filter { $0.status == .done }.map(\.id), defaults: env.defaults)
        // 지난번 뒤로 끝난 일을 한 번에 묶어 알린다. 시험 저장소는 알리지 않는다.
        let news = noteFinished(tasks, defaults: env.defaults)
        if env.defaults === UserDefaults.standard { AITaskNotice.announce(news) }
        return tasks
    }
}

extension AssistantQuestionStore {
    func uploadIfNeeded() async { await uploadIfNeeded(env: .live) }
}

/// 승인 요청의 앱 쪽: 값 검사, 카드 문구, 실행. 값 타입은 `TaptionAssistantProtocol`에 있다.
extension AssistantApproval {
    /// 서버와 같은 규칙으로 다시 본다.
    static func make(request: String?, value: AssistantLooseValue?) -> Self? {
        guard let request = request.flatMap(Request.init(rawValue:)) else { return nil }
        switch (request, value) {
        case let (.shareLevel, .text(level)) where AssistantShareLevel(rawValue: level) != nil: return Self(request: request, value: level)
        case let (.retentionDays, .number(days)) where days == days.rounded() && AssistantRetention(rawValue: Int(days)) != nil:
            return Self(request: request, value: String(Int(days)))
        case (.healthOff, nil), (.eraseAllData, nil), (.backup, nil), (.restore, nil), (.changePin, nil): return Self(request: request, value: nil)
        default: return nil
        }
    }

    /// 승인하면 열 화면. 값을 바로 적용하는 요청은 nil.
    var screen: AssistantScreen? {
        switch request {
        case .eraseAllData: .settings
        case .backup, .restore: .dataProtection
        case .changePin: .aiConnection
        case .shareLevel, .retentionDays, .healthOff: nil
        }
    }

    func title(_ language: MapHomeLanguage) -> String {
        switch request {
        case .shareLevel:
            let level = value.flatMap(AssistantShareLevel.init(rawValue:)) ?? .summary
            return language.text("AI 공유 수준을 「\(level.title(language))」(으)로 바꿀까요?", "Change AI sharing to “\(level.title(language))”?")
        case .retentionDays:
            let days = value.flatMap(Int.init).flatMap(AssistantRetention.init(rawValue:)) ?? .week
            return language.text("서버 보관 기간을 \(days.title(language))로 바꿀까요?", "Change server retention to \(days.title(language))?")
        case .healthOff: return language.text("건강 연동을 끌까요?", "Turn off Health sync?")
        case .eraseAllData: return language.text("모든 데이터 삭제 화면을 열까요?", "Open the screen to erase all data?")
        case .backup: return language.text("백업 화면을 열까요?", "Open the backup screen?")
        case .restore: return language.text("복원 화면을 열까요?", "Open the restore screen?")
        case .changePin: return language.text("AI 연결 화면에서 PIN을 바꿀까요?", "Change the PIN in AI connections?")
        }
    }

    /// 승인하면 무슨 일이 생기는지.
    func detail(_ language: MapHomeLanguage) -> String {
        switch request {
        case .shareLevel, .retentionDays:
            language.text("승인하면 바로 바뀝니다. 덜 보내거나 기간을 줄이면 서버에 올린 기록을 지웁니다.",
                          "It changes as soon as you approve. Sharing less or keeping it shorter deletes what the server holds.")
        case .healthOff:
            language.text("승인하면 건강·Apple Watch에서 가져온 기록이 앱에서 지워집니다.",
                          "Approving removes the records brought from Health and Apple Watch from the app.")
        case .eraseAllData, .backup, .restore, .changePin:
            language.text("승인하면 그 화면만 엽니다. 실제 실행과 비밀번호 입력은 직접 하세요.",
                          "Approving only opens that screen. You do the action and enter any password yourself.")
        }
    }

    /// 승인된 요청을 실행한다. 값 설정은 여기서 적용하고, 화면이 필요한 것은 열어 달라고 맡긴다.
    @MainActor
    func perform(model: AppModel?, defaults: UserDefaults = .standard, screens: AssistantScreenRequest = .shared) async {
        switch request {
        case .shareLevel:
            guard let level = value.flatMap(AssistantShareLevel.init(rawValue:)) else { return }
            let old = AssistantShareLevel.current(defaults)
            defaults.set(level.rawValue, forKey: AssistantShareLevel.defaultsKey)
            if AssistantShareLevel.isDowngrade(from: old, to: level) { AssistantActivitySync.requestClear(defaults: defaults) }
        case .retentionDays:
            guard let days = value.flatMap(Int.init), AssistantRetention(rawValue: days) != nil else { return }
            let old = AssistantRetention.current(defaults).rawValue
            defaults.set(days, forKey: AssistantRetention.defaultsKey)
            if days < old { AssistantActivitySync.requestClear(defaults: defaults) }
        case .healthOff:
            await model?.setHealthEnabled(false)
        case .eraseAllData, .backup, .restore, .changePin:
            if let screen { screens.request(screen) }
        }
        if let model, defaults === UserDefaults.standard, request == .shareLevel || request == .retentionDays {
            await AssistantActivitySync.run(model: model)
        }
    }
}

extension AssistantQuestionNotice {
    /// 알림에 실을 제목과 본문. 잠금 중이면 본문은 앱에서 보라는 말뿐이다.
    static func content(_ question: AssistantQuestion, language: MapHomeLanguage, locked: Bool) -> (title: String, body: String) {
        let title = question.approval == nil ? language.text("AI 질문", "AI question") : language.text("AI 승인 요청", "AI approval request")
        let body = locked ? language.text("앱에서 확인해 주세요.", "Open the app to see it.") : (question.approval?.title(language) ?? question.question)
        return (title, body)
    }

    @MainActor
    static func post(_ question: AssistantQuestion, language: MapHomeLanguage, enabled: Bool) {
        guard enabled else { return }
        let text = content(question, language: language, locked: TaptionExternalPrivacyStore.isLocked)
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = text.title
            content.body = text.body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: identifier(question.id), content: content, trigger: nil))
        }
    }
}

/// 맡긴 일이 끝나면 한 번에 묶어 알린다(AIP1114A05). 앱이 앞에 있으면 화면 띠로, 아니면 iOS 알림 하나로.
/// 알림에는 건수만 싣고 일의 내용은 싣지 않는다.
@MainActor
enum AITaskNotice {
    static let identifier = "ai-task-finished"
    /// 화면 띠에 띄운 글. 같은 확인에서 명령 반영 알림이 덮지 않게 `AssistantCommandRefresh`가 가져가 함께 보인다.
    private static var banner: String?

    static func takeBanner() -> String? {
        defer { banner = nil }
        return banner
    }

    /// 완료가 있으면 그 수를 제목에, 실패는 본문에 따로 센다. 실패뿐이면 제목이 실패 수다.
    static func content(_ news: AITaskQueue.FinishedNews, language: MapHomeLanguage) -> (title: String, body: String)? {
        guard !news.isEmpty else { return nil }
        let done = news.done, failed = news.failed
        let open = language.text("앱에서 확인해 주세요.", "Open the app to see it.")
        guard done > 0 else { return (language.text("AI가 끝내지 못한 일이 \(failed)건 있어요", "Your AI couldn't finish \(failed) task(s)"), open) }
        return (language.text("AI가 \(done)건을 처리했어요", "Your AI handled \(done) task(s)"), failed > 0 ? language.text("실패 \(failed)건", "\(failed) failed") : open)
    }

    static func announce(_ news: AITaskQueue.FinishedNews, language: MapHomeLanguage = .current) {
        guard let text = content(news, language: language), let model = AssistantCommandRefresh.model else { return }
        if model.isSceneActive {
            let line = news.done > 0 && news.failed > 0 ? text.title + " · " + text.body : text.title
            banner = line
            AssistantInbox.current.show(line)
        } else if model.settings.notificationsEnabled {
            post(text)
        }
    }

    /// 같은 식별자로 보내 알림이 쌓이지 않고 하나만 남는다.
    private static func post(_ text: (title: String, body: String)) {
        Task {
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = text.title
            content.body = text.body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }
}
