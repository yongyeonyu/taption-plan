import Foundation
import Observation
import UIKit

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

    /// 결과와 따로 「AI가 한 일」에만 적는다(거절한 명령).
    func log(_ entries: [AssistantLogEntry]) { AssistantActionLog.append(entries, to: logFile) }

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
        let applied = AssistantActionLog.load(from: logFile).contains { $0.commandID == id && $0.rejectedReason == nil }
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
    /// `force`(푸시로 깨어남, PSH1114A06)면 5분 간격을 보지 않고 바로 돌고, 질문·답도 올린다. 앨범은 보지 않는다.
    static func runInBackground(model: AppModel, budget: TimeInterval = 12, force: Bool = false) async {
        guard TripRelay.isAvailable, AssistantRegistration.isReady(), !model.isSceneActive,
              takeBackgroundTurn(minimum: force ? 0 : AssistantActivitySync.minimumInterval) else { return }
        // 지도 화면이 뜨지 않은 깨어남에서도 끝난 일 알림이 설정을 읽을 수 있게 한다(AIP1114A05).
        if AssistantCommandRefresh.model == nil { AssistantCommandRefresh.model = model }
        let deadline = Date.now.addingTimeInterval(budget)
        // 시간이 짧아 429는 기다리지 않는다.
        await TripRelay.$singleAttempt.withValue(true) {
            if case .needsConfirmation = await run(model: model) {
                TaptionPlanDiagnosticsLogger.shared.record("assistant_background_batch_deferred")
            }
            if force, Date.now < deadline, !Task.isCancelled { await AssistantQuestionStore.shared.uploadIfNeeded() }
            guard Date.now < deadline, !Task.isCancelled else { return }
            await AssistantActivitySync.run(model: model)
            // 규칙 묶음과 맡긴 일의 상태도 함께 맞춘다(AIX1114A01 P3·P5).
            guard Date.now < deadline, !Task.isCancelled else { return }
            await AssistantRuleStore.sync()
            guard Date.now < deadline, !Task.isCancelled else { return }
            await AITaskQueue.refresh()
        }
        // 남은 시간에 앨범의 새 영수증을 본다(RPA1114A01).
        if !force, Date.now < deadline, !Task.isCancelled { await ReceiptPhotoScanner.scan(deadline: deadline) }
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
        Self(commands: commands.filter { !ids.contains($0.id) }, invalidIDs: invalidIDs.filter { !ids.contains($0) }, invalidInfo: invalidInfo)
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
        guard let model else {
            // 모델이 아직 없어도 못 올린 일은 다시 올린다(AIP1114A05).
            await AITaskQueue.upload()
            return false
        }
        await AssistantPush.syncRegistration()
        let result = await TripRelay.$singleAttempt.withValue(true) { await AssistantCommandRunner.run(model: model) }
        // 새 질문(답 기다림)과 아직 못 올린 답을 올린다(ASK1112A01).
        await AssistantQuestionStore.shared.uploadIfNeeded()
        // 규칙 묶음을 서버와 맞추고, 맡긴 일의 상태도 「AI」 탭을 열지 않아도 갱신한다(AIX1114A01 P3·P5).
        await AssistantRuleStore.sync()
        await AITaskQueue.refresh()
        ReceiptPhotoWatcher.shared.startIfNeeded()
        await ReceiptPhotoScanner.scan()
        // 끝난 일 알림이 이번 확인에서 떴으면 명령 반영 알림과 한 줄로 보인다(AIP1114A05).
        let taskNotice = AITaskNotice.takeBanner()
        switch result {
        case let .applied(outcome):
            AssistantInbox.current.show([outcome.notice(language), taskNotice].compactMap { $0 }.joined(separator: " · "))
            return true
        case let .needsConfirmation(batch):
            AssistantInbox.current.pending = batch
            return true
        case .nothing:
            return false
        }
    }
}

/// 푸시(APNs, PSH1114A06). 외부 AI가 무언가 하면 서버가 종류만 실어 깨우고, 앱은 평소 확인과 같은 일을 바로 한다.
/// 푸시가 오지 않아도 5분 확인이 같은 일을 하므로, 푸시에 기대는 것은 빠르기뿐이다.
@MainActor
enum AssistantPush {
    enum Kind: String { case cmd, q, task, rules }

    nonisolated static let uploadedKey = "assistantPushUploaded"
    nonisolated static let uploadedAtKey = "assistantPushUploadedAt"
    /// 서버가 토큰을 지웠을 수 있어(만료·모두 끊기) 이만큼 지나면 다시 올린다.
    nonisolated static let reuploadAfter: TimeInterval = 7 * 86_400
    private static var requested = false
    /// 이번 실행에서 iOS가 준 토큰. 올리지 못했으면 다음 확인 때 다시 올린다.
    private static var token: String?

    nonisolated static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    nonisolated static func kind(from userInfo: [AnyHashable: Any]) -> Kind? {
        (userInfo["k"] as? String).flatMap(Kind.init(rawValue:))
    }

    nonisolated static func hex(_ deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func needsUpload(token: String, environment: String, defaults: UserDefaults, now: Date = .now) -> Bool {
        guard defaults.string(forKey: uploadedKey) == "\(environment):\(token)" else { return true }
        let elapsed = now.timeIntervalSince1970 - defaults.double(forKey: uploadedAtKey)
        return elapsed < 0 || elapsed >= reuploadAfter
    }

    /// AI 연결이 있으면 iOS에 토큰을 청하고(실행마다 한 번), 연결이 없어졌으면 서버에 올려 둔 토큰을 지운다.
    static func syncRegistration(env: AssistantRegistration.Environment = .live) async {
        if MemoPolishQueue.hasConnection(env.defaults) {
            if let token { return await upload(token: token, env: env) }
            guard !requested, env.defaults === UserDefaults.standard else { return }
            requested = true
            UIApplication.shared.registerForRemoteNotifications()
            return
        }
        requested = false
        guard env.defaults.string(forKey: uploadedKey) != nil, let master = env.secrets.read(.master),
              let reply = await TripRelay.send(TripRelay.relayRequest("/push/token", method: "DELETE", token: master, host: env.host, client: env.client()), session: env.session),
              (200..<300).contains(reply.status) else { return }
        env.defaults.removeObject(forKey: uploadedKey)
        env.defaults.removeObject(forKey: uploadedAtKey)
    }

    static func registered(_ deviceToken: Data) async {
        let value = hex(deviceToken)
        token = value
        await upload(token: value)
    }

    /// 주인 키로 `POST /push/token`. 같은 토큰은 다시 올리지 않는다.
    static func upload(token: String, environment: String = AssistantPush.environment, env: AssistantRegistration.Environment = .live) async {
        guard MemoPolishQueue.hasConnection(env.defaults), needsUpload(token: token, environment: environment, defaults: env.defaults),
              let master = env.secrets.read(.master) else { return }
        var payload = ["token": token, "env": environment]
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, !build.isEmpty, build.count <= 8, build.allSatisfy({ ("0"..."9").contains($0) }) {
            payload["build"] = build
        }
        let body = try? JSONSerialization.data(withJSONObject: payload)
        let request = body.flatMap { TripRelay.relayRequest("/push/token", method: "POST", body: $0, token: master, host: env.host, client: env.client()) }
        guard let reply = await TripRelay.send(request, session: env.session), (200..<300).contains(reply.status) else { return }
        env.defaults.set("\(environment):\(token)", forKey: uploadedKey)
        env.defaults.set(Date.now.timeIntervalSince1970, forKey: uploadedAtKey)
    }

    /// 푸시를 받았다. 앱이 앞에 있으면 평소 확인을, 아니면 백그라운드 확인을 간격 제한 없이 바로 돈다. `budget`초에서 끊는다.
    static func receive(_ userInfo: [AnyHashable: Any], budget: TimeInterval = 20) async -> UIBackgroundFetchResult {
        guard let kind = kind(from: userInfo), TripRelay.isAvailable, AssistantRegistration.isReady() else { return .noData }
        TaptionPlanDiagnosticsLogger.shared.record("assistant_push_received", fields: ["kind": kind.rawValue])
        let work = Task { @MainActor () -> Bool in
            if let model = AssistantCommandRefresh.model, model.isSceneActive {
                await AssistantCommandRefresh.now()
                return true
            }
            guard await TaptionProAccessController.currentAccessGranted() else { return false }
            await AssistantCommandRunner.runInBackground(model: AppModel.backgroundTaskInstance(), budget: budget * 0.75, force: true)
            return true
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(budget))
            work.cancel()
        }
        let ran = await work.value
        timeout.cancel()
        return ran ? .newData : .noData
    }
}

// MARK: 동작 등록부 (ACT1114A07) — 새 파일을 늘리지 않으려고 여기 둔다.
// 새 동작은 (1) 서버 `server/trip-relay/src/actions.js`에 `.add(...)`, (2) 앱에 `AssistantOperation` 형 하나,
// (3) 아래 `AssistantOperations.all`에 한 줄. 토글·알림 수·안내문·로그 이름은 `spec`에서 만들어진다.
// 서버와 이름·칸이 같은지는 `server/trip-relay/test/fixtures/actions.json`으로 시험한다.

/// 등록부 동작 하나. 읽기에 더해 `apply`가 화면이 쓰는 함수를 부른다.
protocol AssistantOperation: AssistantOperationReading {
    @MainActor func apply(host: AssistantOperationHost) async -> AssistantEditResult
}

/// 동작이 쓰는 것들: 앱 모델과 기기 저장소(시험은 따로 만든 것).
@MainActor
struct AssistantOperationHost {
    let model: AppModel
    let preferences: AssistantPreferenceStore

    var language: MapHomeLanguage { .current }
    var defaults: UserDefaults { preferences.defaults }
    var book: LedgerBook { preferences.ledger }
    var deleted: String { language.text("지움", "Deleted") }

    /// UserDefaults 값 하나를 바꾸고 전·후를 담는다. 바뀌지 않았으면 nil.
    func changing(_ key: String, _ body: () -> Void) -> AssistantAppChange.Stored? {
        let before = defaults.object(forKey: key)
        body()
        let after = defaults.object(forKey: key)
        guard !AssistantAppChange.Stored.same(before, after) else { return nil }
        return .init(key: key, before: AssistantAppChange.Stored.pack(before), after: AssistantAppChange.Stored.pack(after))
    }
}

enum AssistantOperations {
    /// 앱이 아는 등록부 동작 전부. 여기 차례가 「AI가 할 수 있는 일」과 안내문의 차례다.
    static let all: [any AssistantOperation.Type] = ledger + plans + records + photos + catalog + system + direct

    private static let byName = Dictionary(all.map { ($0.spec.name, $0) }, uniquingKeysWith: { first, _ in first })

    static func spec(_ name: String) -> AssistantOperationSpec? { byName[name]?.spec }

    /// 형식·버전을 보고, 그 동작의 칸만 남겨 읽는다.
    static func parse(_ fields: AssistantFields) -> AssistantParsedOperation? {
        guard fields.raw("format") == "bokki-command", fields.values["version"] == .number(1),
              let name = fields.name, let type = byName[name] else { return nil }
        var kept = fields
        kept.values = fields.values.filter { type.spec.fields.contains($0.key) && $0.value != .null }
        return type.init(fields: kept).map { AssistantParsedOperation(name: name, values: kept.values, operation: $0) }
    }

    /// 연결 안내에 붙는 줄들.
    static func guide(command: String) -> String {
        // 칸이 없는 동작의 안내는 `}`로 시작한다.
        all.map { "  \(command)\"\($0.spec.name)\"\($0.spec.fields.isEmpty ? "" : ",")\($0.spec.guide)" }.joined(separator: "\n")
    }
}

// MARK: 등록부 동작 6묶음 — 시스템 (ACT1114A09). 권한 켜기·앱 잠금·PIN·전부 지우기는 넣지 않는다(대표 결정).

extension AssistantOperations {
    static let system: [any AssistantOperation.Type] = [RefreshNow.self, StopTracking.self, DisconnectCalendar.self, RestoreFromBackup.self]

    /// 새로고침 단추와 iCloud 「지금 동기화」가 하는 일. 바뀌는 설정이 없어 되돌릴 것도 없다.
    struct RefreshNow: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "refreshNow", fields: ["target"], counter: .settings, changes: 0,
            title: { $0.text("새로고침·iCloud 동기화 실행", "Refresh or run the iCloud sync") },
            guide: #""target":"records|cloud"} (what the refresh buttons do: records re-reads today's connected data, cloud starts an iCloud sync; changes no settings, nothing to undo)"#
        )

        enum Target: String { case records, cloud }
        let target: Target

        init?(fields: AssistantFields) {
            guard let target: Target = fields.choice("target") else { return nil }
            self.target = target
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            let language = host.language
            var result: AssistantEditResult
            switch target {
            case .records:
                // 시험 저장소로는 기기 자료를 다시 읽지 않는다.
                if host.preferences.isLive { await host.model.refreshConnectedRecordsNow() }
                result = AssistantEditResult(after: language.text("기록 새로고침", "Records refreshed"))
            case .cloud:
                guard host.model.cloudSyncService != nil else { return .rejected("not_available") }
                host.model.startManualCloudSync()
                result = AssistantEditResult(after: language.text("iCloud 동기화 시작", "iCloud sync started"))
            }
            result.cannotUndo = true
            return result
        }
    }

    /// 걷기·달리기 추적 끝내기(설정과 상세 패널의 「종료」와 같은 함수). 끝낸 기록은 남고 되돌릴 수 없다.
    struct StopTracking: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "stopTracking", fields: [], counter: .edits,
            title: { $0.text("걷기·달리기 추적 끝내기", "Stop walk or run tracking") },
            guide: #"} (ends the walk or run I am tracking and saves it as a record; only when I asked; cannot be undone)"#
        )

        init?(fields: AssistantFields) {}

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            guard let session = host.model.activeTrackingSession else { return .rejected("no_tracking") }
            await host.model.stopTracking()
            guard host.model.activeTrackingSession == nil else { return .rejected("edit_failed") }
            var result = AssistantEditResult(before: AssistantEditText.clock(session.startedAt), after: host.language.text("추적 끝냄", "Tracking stopped"))
            result.cannotUndo = true
            return result
        }
    }

    /// 캘린더 연결 끊기: 기기 캘린더는 설정의 스위치를 끄는 것과, 구글은 「연결 끊기」와 같은 함수. 다시 잇기는 사용자가 한다.
    struct DisconnectCalendar: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "disconnectCalendar", fields: ["calendar"], counter: .settings, deletes: true,
            title: { $0.text("캘린더 연결 끊기", "Disconnect calendars") },
            guide: #""calendar":"device|google"} (stops reading a calendar: device removes every iOS calendar from the app, google signs my Google account out; the events stay in the calendars; connecting again is done by me in the app; only when I asked; cannot be undone)"#
        )

        enum Source: String { case device, google }
        let source: Source

        init?(fields: AssistantFields) {
            guard let source: Source = fields.choice("calendar") else { return nil }
            self.source = source
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            let language = host.language
            var result: AssistantEditResult
            switch source {
            case .device:
                guard !host.model.settings.selectedCalendarIDs.isEmpty else { return .rejected("no_change") }
                await host.model.setCalendarEnabled(false)
                result = AssistantEditResult(before: language.text("기기 캘린더", "Device calendars"), after: language.text("연결 끊음", "Disconnected"))
            case .google:
                // 시험 저장소로는 실제 계정을 건드리지 않는다.
                guard host.preferences.isLive, GoogleCalendarAccount.shared.isConnected else { return .rejected("no_change") }
                await host.model.disconnectGoogleCalendar()
                result = AssistantEditResult(before: language.text("구글 캘린더", "Google Calendar"), after: language.text("연결 끊음", "Disconnected"))
            }
            result.cannotUndo = true
            return result
        }
    }

    /// 백업에서 복원(대표 결정 2026-11-14): 백업 비밀번호가 필요하므로 AI는 「데이터 보호」 화면만 열고, 복원은 사용자가 그 화면에서 한다.
    /// 「지우는 일」 묶음에 있고 사용자가 켜기 전에는 꺼져 있다.
    struct RestoreFromBackup: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "restoreFromBackup", fields: [], counter: .settings, deletes: true, startsOff: true, changes: 0,
            title: { $0.text("백업에서 복원 화면 열기", "Open restore from backup") },
            guide: #"} (opens the data protection screen so I can restore from a backup myself; I type the backup password in the app, never ask me for it; off until I switch it on under what the AI may do)"#
        )

        init?(fields: AssistantFields) {}

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            host.preferences.screens.request(.dataProtection)
            var result = AssistantEditResult(after: AssistantScreen.dataProtection.title(host.language))
            result.appChange = AssistantAppChange(screen: .dataProtection)
            return result
        }
    }
}

// MARK: 등록부 동작 — 승인 항목을 바로 실행으로 (APV1114A16). 승인 요청(`requestApproval`)의 종류마다 하나씩이고 스위치가 꺼져 있으면 거절된다.
// 자료 공유를 넓히거나 보관을 늘리거나 되돌릴 수 없는 것은 사용자가 켜기 전에는 꺼져 있다. 전부 지우기·PIN 바꾸기는 승인 요청으로만 한다(대표 결정).

extension AssistantOperations {
    static let direct: [any AssistantOperation.Type] = [
        LowerShareLevel.self, RaiseShareLevel.self, ShortenRetention.self, ExtendRetention.self, TurnOffHealth.self, OpenBackup.self,
    ]

    /// 되돌리면 서버의 날들도 돌아간 설정으로 다시 맞춰야 하는 값.
    static let sharingKeys: Set<String> = [AssistantShareLevel.defaultsKey, AssistantRetention.defaultsKey]

    private static let ifOff = "if this is rejected as disabled I switched it off, so use requestApproval instead"
    private static let startsOffNote = "off until I switch it on under what the AI may do"

    /// 공유 수준을 한쪽 방향으로만 바꾼다. 낮추면 서버에 올린 날들을 지우게 적어 둔다(설정 화면·승인과 같다).
    @MainActor
    private static func share(_ level: AssistantShareLevel, lowering: Bool, host: AssistantOperationHost) -> AssistantEditResult {
        let old = AssistantShareLevel.current(host.defaults)
        guard level != old else { return .rejected("no_change") }
        guard AssistantShareLevel.isDowngrade(from: old, to: level) == lowering else { return .rejected(lowering ? "not_lower" : "not_higher") }
        let change = host.changing(AssistantShareLevel.defaultsKey) { host.defaults.set(level.rawValue, forKey: AssistantShareLevel.defaultsKey) }
        if lowering { AssistantActivitySync.requestClear(defaults: host.defaults) }
        var result = AssistantEditResult(before: old.title(host.language), after: level.title(host.language))
        result.appChange = AssistantAppChange(stored: change.map { [$0] } ?? [])
        return result
    }

    /// 보관 기간을 한쪽 방향으로만 바꾼다. 줄이면 서버의 날들을 지우고, 늘리면 새 기간으로 다시 올리게 한다.
    @MainActor
    private static func retain(_ days: AssistantRetention, shortening: Bool, host: AssistantOperationHost) -> AssistantEditResult {
        let old = AssistantRetention.current(host.defaults)
        guard days != old else { return .rejected("no_change") }
        guard (days.rawValue < old.rawValue) == shortening else { return .rejected(shortening ? "not_shorter" : "not_longer") }
        let change = host.changing(AssistantRetention.defaultsKey) { host.defaults.set(days.rawValue, forKey: AssistantRetention.defaultsKey) }
        if shortening { AssistantActivitySync.requestClear(defaults: host.defaults) } else { AssistantActivityUploadGate.reset(defaults: host.defaults) }
        var result = AssistantEditResult(before: old.title(host.language), after: days.title(host.language))
        result.appChange = AssistantAppChange(stored: change.map { [$0] } ?? [])
        return result
    }

    struct LowerShareLevel: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "lowerShareLevel", fields: ["level"], counter: .settings,
            title: { $0.text("AI 공유 수준 낮추기", "Lower AI sharing") },
            guide: #""level":"off|summary"} (shares less with you right away, no approval card; must be lower than settings.shareLevel; the days the server holds are deleted and sent again at the new level; only when I asked; undoable; \#(ifOff) with request shareLevel)"#
        )

        let level: AssistantShareLevel

        init?(fields: AssistantFields) {
            guard let level: AssistantShareLevel = fields.choice("level"), level != .visits else { return nil }
            self.level = level
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult { AssistantOperations.share(level, lowering: true, host: host) }
    }

    /// 더 많이 보내게 하는 일이라 사용자가 켜기 전에는 꺼져 있다.
    struct RaiseShareLevel: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "raiseShareLevel", fields: ["level"], counter: .settings, startsOff: true,
            title: { $0.text("AI 공유 수준 높이기", "Raise AI sharing") },
            guide: #""level":"summary|visits"} (shares more with you right away; must be higher than settings.shareLevel; only when I asked; undoable; \#(startsOffNote); \#(ifOff) with request shareLevel)"#
        )

        let level: AssistantShareLevel

        init?(fields: AssistantFields) {
            guard let level: AssistantShareLevel = fields.choice("level"), level != .off else { return nil }
            self.level = level
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult { AssistantOperations.share(level, lowering: false, host: host) }
    }

    struct ShortenRetention: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "shortenRetention", fields: ["days"], counter: .settings,
            title: { $0.text("서버 보관 기간 줄이기", "Shorten server retention") },
            guide: #""days":7} (keeps my days on the server for a shorter time, 1 or 7; must be shorter than settings.retentionDays; the days the server holds are deleted and sent again; only when I asked; undoable; \#(ifOff) with request retentionDays)"#
        )

        let days: AssistantRetention

        init?(fields: AssistantFields) {
            guard let days = fields.integer("days", in: 1...7).flatMap(AssistantRetention.init(rawValue:)) else { return nil }
            self.days = days
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult { AssistantOperations.retain(days, shortening: true, host: host) }
    }

    /// 서버에 더 오래 두는 일이라 사용자가 켜기 전에는 꺼져 있다.
    struct ExtendRetention: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "extendRetention", fields: ["days"], counter: .settings, startsOff: true,
            title: { $0.text("서버 보관 기간 늘리기", "Extend server retention") },
            guide: #""days":30} (keeps my days on the server for a longer time, 7 or 30; must be longer than settings.retentionDays; only when I asked; undoable; \#(startsOffNote); \#(ifOff) with request retentionDays)"#
        )

        let days: AssistantRetention

        init?(fields: AssistantFields) {
            guard let days = fields.integer("days", in: 7...30).flatMap(AssistantRetention.init(rawValue:)) else { return nil }
            self.days = days
        }

        func apply(host: AssistantOperationHost) async -> AssistantEditResult { AssistantOperations.retain(days, shortening: false, host: host) }
    }

    /// 건강 연동 끄기(설정의 스위치와 같은 함수). 가져온 기록이 지워지고 다시 켜기는 사용자가 하므로 되돌릴 수 없다.
    struct TurnOffHealth: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "turnOffHealth", fields: [], counter: .settings, deletes: true, startsOff: true,
            title: { $0.text("건강 연동 끄기(가져온 기록 삭제)", "Turn off Health sync (removes imported records)") },
            guide: #"} (stops the Health sync right away and removes the records brought from Health and Apple Watch from the app; turning it on again is done by me; only when I asked; cannot be undone; \#(startsOffNote); \#(ifOff) with request healthOff)"#
        )

        init?(fields: AssistantFields) {}

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            guard host.model.settings.healthEnabled else { return .rejected("no_change") }
            await host.model.setHealthEnabled(false)
            guard !host.model.settings.healthEnabled else { return .rejected("edit_failed") }
            var result = AssistantEditResult(after: host.language.text("건강 연동 끔", "Health sync off"))
            result.cannotUndo = true
            return result
        }
    }

    /// 백업은 비밀번호가 필요하므로 AI는 「데이터 보호」 화면만 열고, 백업은 사용자가 그 화면에서 한다.
    struct OpenBackup: AssistantOperation {
        static let spec = AssistantOperationSpec(
            name: "openBackup", fields: [], counter: .settings, changes: 0,
            title: { $0.text("백업 화면 열기", "Open the backup screen") },
            guide: #"} (opens the data protection screen so I can make a backup myself; I type the backup password in the app, never ask me for it; changes no data; \#(ifOff) with request backup)"#
        )

        init?(fields: AssistantFields) {}

        func apply(host: AssistantOperationHost) async -> AssistantEditResult {
            host.preferences.screens.request(.dataProtection)
            var result = AssistantEditResult(after: AssistantScreen.dataProtection.title(host.language))
            result.appChange = AssistantAppChange(screen: .dataProtection)
            return result
        }
    }
}
