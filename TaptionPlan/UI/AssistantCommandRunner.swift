import Foundation
import Observation

/// 명령 처리 장부(REV1110A06). 반영 중인 명령 하나와, 아직 서버에 알리지 못한 결과를 기기에 둔다.
/// 결과를 서버가 받은 뒤에만 큐에서 지우므로, 도중에 앱이 꺼지거나 전송이 실패해도 AI가 결과를 잃지 않는다.
@MainActor
struct AssistantCommandJournal {
    static let inProgressKey = "assistantCommandInProgressID"
    static let outboxKey = "assistantCommandPendingResults"
    static let outboxLimit = 200
    /// 서버가 한 번에 받는 결과 수.
    static let chunk = 50

    var defaults: UserDefaults
    var logFile: URL

    /// 시험은 따로 만든 저장소마다 다른 「AI가 한 일」 파일을 쓴다.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        guard defaults !== UserDefaults.standard else {
            logFile = AssistantActionLog.url
            return
        }
        let name = defaults.string(forKey: "assistantLogTestFile") ?? UUID().uuidString
        defaults.set(name, forKey: "assistantLogTestFile")
        logFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-log.json")
    }

    func begin(_ id: String) { defaults.set(id, forKey: Self.inProgressKey) }

    /// 명령 하나를 마쳤다. 되돌리기 정보와 결과를 적고 처리한 id로 기억한다.
    func finish(_ result: AssistantCommandOutcome.Result, entry: AssistantLogEntry?) {
        if let entry { AssistantActionLog.append([entry], to: logFile) }
        record([result])
        defaults.removeObject(forKey: Self.inProgressKey)
    }

    func record(_ results: [AssistantCommandOutcome.Result]) {
        guard !results.isEmpty else { return }
        let ids = Set(results.map(\.id))
        save(pending.filter { !ids.contains($0.id) } + results)
        AssistantCommandLedger.remember(results.map(\.id), defaults: defaults)
    }

    var pending: [AssistantCommandOutcome.Result] {
        (defaults.array(forKey: Self.outboxKey) as? [[String: String]] ?? []).compactMap { value in
            value["id"].map { .init(id: $0, applied: value["status"] == "applied", reason: value["reason"]) }
        }
    }

    func delivered(_ ids: [String]) { save(pending.filter { !ids.contains($0.id) }) }

    /// 반영하다 앱이 꺼진 명령. 「AI가 한 일」에 남았으면 반영된 것이고, 아니면 알 수 없어 `interrupted`로 알린다.
    func resolveInterrupted() {
        guard let id = defaults.string(forKey: Self.inProgressKey) else { return }
        let applied = AssistantActionLog.load(from: logFile).contains { $0.commandID == id }
        record([.init(id: id, applied: applied, reason: applied ? nil : "interrupted")])
        defaults.removeObject(forKey: Self.inProgressKey)
    }

    private func save(_ results: [AssistantCommandOutcome.Result]) {
        defaults.set(results.suffix(Self.outboxLimit).map { result -> [String: String] in
            var value = ["id": result.id, "status": result.applied ? "applied" : "rejected"]
            if let reason = result.reason { value["reason"] = reason }
            return value
        }, forKey: Self.outboxKey)
    }
}

/// 명령 받기 → 반영 → 결과 보고 → 하루 기록 올리기. 앱을 열 때와 백그라운드 새로 고침이 함께 쓴다(AIR1110A02).
@MainActor
enum AssistantCommandRunner {
    enum Result {
        case nothing
        case applied(AssistantCommandOutcome)
        /// 기존 항목을 20개 넘게 바꾸는 묶음. 아무것도 반영하지 않았다.
        case needsConfirmation(AssistantCommandBatch)
    }

    private static var isRunning = false
    /// 지금 반영 중인 명령. 그동안 같은 확인이 또 돌아도 두 번 반영하지 않는다.
    private static var claimed: Set<String> = []

    static func run(
        model: AppModel, defaults: UserDefaults = .standard, env: AssistantRegistration.Environment = .live
    ) async -> Result {
        guard env.host != nil, AssistantRegistration.isReady(env), !isRunning, AssistantRelayGate.begin() else { return .nothing }
        isRunning = true
        defer {
            isRunning = false
            AssistantRelayGate.end()
        }
        let journal = AssistantCommandJournal(defaults: defaults)
        journal.resolveInterrupted()
        await deliver(journal, env: env)
        guard let fetched = await TripRelay.fetchCommands(env: env) else { return .nothing }
        let waiting = Set(journal.pending.map(\.id)).union(claimed)
        await deleteReported(fetched, waiting: waiting, defaults: defaults, env: env)
        var batch = AssistantCommandLedger.unseen(fetched, defaults: defaults).excluding(waiting)
        if !batch.commands.isEmpty {
            // 지금 살아 있는 연결 키가 보낸 것만 반영한다. 목록을 못 읽으면 다음에 다시 본다(SEC1110A02).
            guard let keys = await TripRelay.scopedKeys(env: env) else { return .nothing }
            let split = AssistantKeyFilter.split(batch, active: AssistantKeyFilter.activeIDs(keys))
            batch = split.kept
            journal.record(split.inactiveIDs.map { .init(id: $0, applied: false, reason: "revoked") })
            await deliver(journal, env: env)
        }
        guard !batch.commands.isEmpty || !batch.invalidIDs.isEmpty else { return .nothing }
        if AssistantBatchPolicy.needsConfirmation(batch, defaults: defaults, plans: model.snapshot.plans) { return .needsConfirmation(batch) }
        return await apply(batch, model: model, defaults: defaults, env: env).map(Result.applied) ?? .nothing
    }

    /// 확인 시트에서 「모두 반영」을 누르면 기준을 넘어도 반영한다.
    static func apply(
        _ batch: AssistantCommandBatch, model: AppModel, defaults: UserDefaults = .standard, env: AssistantRegistration.Environment = .live
    ) async -> AssistantCommandOutcome? {
        let ids = Set(batch.commands.map(\.id) + batch.invalidIDs)
        guard claimed.isDisjoint(with: ids) else { return nil }
        claimed.formUnion(ids)
        defer { claimed.subtract(ids) }
        let journal = AssistantCommandJournal(defaults: defaults)
        // 백그라운드 작업이 시간을 넘겨 취소돼도 반영 도중 저장이 끊기지 않게 따로 돌린다.
        let applying = Task { @MainActor in await model.applyAssistantCommands(batch, defaults: defaults, journal: journal) }
        guard let outcome = await applying.value else { return nil }
        await deliver(journal, env: env)
        await AssistantActivitySync.run(model: model, defaults: defaults, env: env)
        return outcome
    }

    /// 「반영하지 않기」. 거절로 알리고 큐에서 지운다.
    static func decline(
        _ batch: AssistantCommandBatch, defaults: UserDefaults = .standard, env: AssistantRegistration.Environment = .live
    ) async {
        let journal = AssistantCommandJournal(defaults: defaults)
        journal.record((batch.commands.map(\.id) + batch.invalidIDs).map { .init(id: $0, applied: false, reason: "declined") })
        await deliver(journal, env: env)
    }

    /// 밀린 결과를 보낸다. 서버가 받은 것만 장부와 큐에서 지우고, 못 보낸 것은 다음에 다시 보낸다.
    static func deliver(_ journal: AssistantCommandJournal, env: AssistantRegistration.Environment) async {
        var rest = journal.pending
        while !rest.isEmpty {
            let part = Array(rest.prefix(AssistantCommandJournal.chunk))
            rest.removeFirst(part.count)
            guard await TripRelay.postResults(part, env: env) else { return }
            journal.delivered(part.map(\.id))
            await TripRelay.deleteCommands(part.map(\.id), env: env)
        }
    }

    /// 결과까지 보냈는데 큐에 남은 것(지우기 실패·서버 캐시)은 조용히 지운다.
    private static func deleteReported(
        _ fetched: AssistantCommandBatch, waiting: Set<String>, defaults: UserDefaults, env: AssistantRegistration.Environment
    ) async {
        let handled = Set(AssistantCommandLedger.handled(defaults))
        let ids = (fetched.commands.map(\.id) + fetched.invalidIDs).filter { handled.contains($0) && !waiting.contains($0) }
        await TripRelay.deleteCommands(ids, env: env)
    }

    /// 앱을 열지 않아도 iOS가 허락한 새로 고침 때 명령을 반영하고 바뀐 날을 올린다.
    /// 대표 결정(2026-11-10): 백그라운드·기기 잠금 중에도 명령을 전부 반영한다. 화면 알림은 띄우지 않고, 사생활 잠금 중에는 올리기만 쉰다.
    /// 큰 묶음은 반영하지 않고 서버에 남겨 다음에 앱을 열 때 묻는다. 남은 시간이 없으면 올리기는 건너뛴다.
    /// 위치 이벤트로 다시 켜졌을 때도 부른다(AIC1112A01). 그런 깨어남은 잦을 수 있어 5분에 한 번만 돌고, 프로세스가 새로 떠도 지키도록 기기에 적어 둔다.
    static func runInBackground(model: AppModel, budget: TimeInterval = 12) async {
        guard TripRelay.isAvailable, AssistantRegistration.isReady(), !model.isSceneActive, takeBackgroundTurn() else { return }
        let deadline = Date.now.addingTimeInterval(budget)
        // 시간이 짧아 429는 기다리지 않는다.
        await TripRelay.$singleAttempt.withValue(true) {
            if case .needsConfirmation = await run(model: model) {
                TaptionPlanDiagnosticsLogger.shared.record("assistant_background_batch_deferred")
            }
            guard Date.now < deadline, !Task.isCancelled else { return }
            await AssistantActivitySync.run(model: model)
        }
        // 남은 시간에 앨범의 새 영수증을 본다(RPA1114A01).
        if Date.now < deadline, !Task.isCancelled { await ReceiptPhotoScanner.scan(deadline: deadline) }
    }
}

extension AssistantCommandRunner {
    static let backgroundRunKey = "assistantBackgroundRunAt"

    /// 마지막 백그라운드 실행에서 `minimum`이 지났으면 지금을 적고 true. 시계가 뒤로 갔으면 다시 허락한다.
    static func takeBackgroundTurn(
        now: Date = .now, defaults: UserDefaults = .standard, minimum: TimeInterval = AssistantActivitySync.minimumInterval
    ) -> Bool {
        let last = defaults.double(forKey: backgroundRunKey)
        let elapsed = now.timeIntervalSince1970 - last
        guard last == 0 || elapsed >= minimum || elapsed < 0 else { return false }
        defaults.set(now.timeIntervalSince1970, forKey: backgroundRunKey)
        return true
    }
}

extension AssistantCommandBatch {
    func excluding(_ ids: Set<String>) -> Self {
        Self(commands: commands.filter { !ids.contains($0.id) }, invalidIDs: invalidIDs.filter { !ids.contains($0) })
    }
}

/// 확인을 기다리는 큰 묶음과 잠깐 보이는 알림. 지도 화면 본문 상태를 늘리지 않게 따로 둔다(AIR1110A02).
@MainActor
@Observable
final class AssistantInbox {
    static let current = AssistantInbox()
    var pending: AssistantCommandBatch?
    private(set) var notice: String?

    /// 사생활 잠금 중에는 알림을 띄우지 않는다.
    func show(_ text: String?) {
        let next = TaptionExternalPrivacyStore.isLocked ? nil : text
        if next != notice { notice = next }
    }
}

/// 앱이 켜져 있는 동안 명령을 확인하는 간격(SYN1111A03, 대표 결정).
/// AI와 대화 중이면 빠르게(10초, 저전력 20초, 과열 60초), 그 밖에는 5분마다 본다(대표 결정).
/// 대화 중: AI가 5분 안에 왔고 「대화 끝」을 보내지 않았거나, 앱에서 직접 새로고침한 뒤 2분.
@MainActor
enum AssistantCommandPolling {
    /// 서버가 `GET /command` 응답 머리에 준 값.
    struct Signal: Equatable {
        /// AI가 마지막으로 온 지 몇 초. 온 적 없으면 nil.
        var seenAgo: TimeInterval?
        var ended: Bool
        var receivedAt: Date
    }

    nonisolated static let idleInterval: TimeInterval = 300
    nonisolated static let aiIdleTimeout: TimeInterval = 300
    nonisolated static let manualWindow: TimeInterval = 120

    static var signal: Signal?
    static var manualAt: Date?

    nonisolated static func signal(from response: HTTPURLResponse, now: Date = .now) -> Signal? {
        guard let text = response.value(forHTTPHeaderField: "x-ai-seen-ago"), let ago = TimeInterval(text) else { return nil }
        return Signal(seenAgo: ago < 0 ? nil : ago, ended: response.value(forHTTPHeaderField: "x-ai-ended") == "1", receivedAt: now)
    }

    nonisolated static func isConversation(signal: Signal?, manualAt: Date?, now: Date = .now) -> Bool {
        if let manualAt, now.timeIntervalSince(manualAt) < manualWindow { return true }
        guard let signal, !signal.ended, let ago = signal.seenAgo else { return false }
        return ago + now.timeIntervalSince(signal.receivedAt) < aiIdleTimeout
    }

    nonisolated static func interval(conversation: Bool, lowPower: Bool, thermal: ProcessInfo.ThermalState) -> TimeInterval {
        guard conversation else { return idleInterval }
        if thermal == .serious || thermal == .critical { return 60 }
        return lowPower ? 20 : 10
    }

    static func nextInterval(now: Date = .now, info: ProcessInfo = .processInfo) -> TimeInterval {
        interval(conversation: isConversation(signal: signal, manualAt: manualAt, now: now), lowPower: info.isLowPowerModeEnabled, thermal: info.thermalState)
    }
}

/// 주기 확인과 당겨서 새로고침이 함께 쓴다. 지도 화면이 모델을 넣어 둔다(SYN1111A01).
@MainActor
enum AssistantCommandRefresh {
    static weak var model: AppModel?

    /// 명령을 받아 반영하고 알림을 띄운다. 새 명령이 있었으면 true. 429는 기다리지 않는다.
    /// `manual`(현재 위치 단추·당겨서 새로고침)이면 빠른 확인을 다시 시작한다.
    @discardableResult
    static func now(language: MapHomeLanguage = .current, manual: Bool = false) async -> Bool {
        if manual { AssistantCommandPolling.manualAt = .now }
        guard let model else { return false }
        let result = await TripRelay.$singleAttempt.withValue(true) { await AssistantCommandRunner.run(model: model) }
        // 새 질문(답 기다림)과 아직 못 올린 답을 올린다(ASK1112A01).
        await AssistantQuestionStore.shared.uploadIfNeeded()
        ReceiptPhotoWatcher.shared.startIfNeeded()
        await ReceiptPhotoScanner.scan()
        switch result {
        case let .applied(outcome):
            AssistantInbox.current.show(outcome.notice(language))
            return true
        case let .needsConfirmation(batch):
            AssistantInbox.current.pending = batch
            return true
        case .nothing:
            return false
        }
    }
}
