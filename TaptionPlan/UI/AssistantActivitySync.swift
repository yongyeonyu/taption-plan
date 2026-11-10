import CryptoKit
import Foundation
import TaptionPlanCore
import UIKit

/// 날마다 마지막으로 올린 내용의 해시(TRP1110A07). 바뀐 날만 다시 올린다.
enum AssistantActivityUploadGate {
    static let defaultsKey = "assistantActivityHashes"
    static let dayLimit = 40

    /// `updatedAt`은 매번 바뀌므로 빼고 잰다.
    static func hash(_ day: AssistantActivityDay) -> String {
        var stable = day
        stable.updatedAt = nil
        let data = (try? encoder.encode(stable)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func changed(_ days: [AssistantActivityDay], defaults: UserDefaults = .standard) -> [AssistantActivityDay] {
        let sent = stored(defaults)
        return days.filter { sent[$0.date] != hash($0) }
    }

    static func markSent(_ days: [AssistantActivityDay], defaults: UserDefaults = .standard) {
        var sent = stored(defaults)
        for day in days { sent[day.date] = hash(day) }
        let kept = sent.keys.sorted().suffix(dayLimit)
        defaults.set(sent.filter { kept.contains($0.key) }, forKey: defaultsKey)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    private static func stored(_ defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    static func sentHashes(_ defaults: UserDefaults = .standard) -> [String: String] { stored(defaults) }

    /// 하루 기록 만들기·해시·JSON 묶기는 메인 액터 밖에서 한다(REV1110A06). 바뀐 날만 묶어 돌려준다.
    nonisolated static func prepare(
        _ inputs: [AssistantActivityInput], level: AssistantShareLevel, stamp: String, sent: [String: String], retentionDays: Int
    ) async -> [(days: [AssistantActivityDay], body: Data)] {
        var changed: [AssistantActivityDay] = []
        for input in inputs {
            guard var day = AssistantActivityBuilder.make(input, level: level) else { continue }
            day.updatedAt = stamp
            if sent[day.date] != hash(day) { changed.append(day) }
            await Task.yield()
        }
        return bodies(changed, retentionDays: retentionDays)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private struct Upload: Encodable {
        var format = "bokki-activity"
        var version = 1
        var retentionDays: Int
        var days: [AssistantActivityDay]
    }

    /// 64KB 제한 안에 들도록 여러 날을 나눠 담는다. 하루가 혼자 넘으면 그날은 뺀다.
    static func bodies(_ days: [AssistantActivityDay], retentionDays: Int, limit: Int = 60_000) -> [(days: [AssistantActivityDay], body: Data)] {
        var result: [(days: [AssistantActivityDay], body: Data)] = []
        var current: [AssistantActivityDay] = []
        func encode(_ group: [AssistantActivityDay]) -> Data? {
            try? encoder.encode(Upload(retentionDays: retentionDays, days: group))
        }
        for day in days {
            if let body = encode(current + [day]), body.count <= limit, current.count < 7 {
                current.append(day)
                continue
            }
            if let body = encode(current), !current.isEmpty { result.append((current, body)) }
            current = encode([day]).map { $0.count <= limit } == true ? [day] : []
        }
        if let body = encode(current), !current.isEmpty { result.append((current, body)) }
        return result
    }
}

/// 하루 기록을 중계 서버에 올린다. 앱을 열 때·떠날 때·기록이 저장된 뒤(5분에 한 번) 돈다. 실패는 진단 기록만 남긴다.
@MainActor
enum AssistantActivitySync {
    static let minimumInterval: TimeInterval = 5 * 60
    static let sharedKey = "assistantActivityShared"
    /// 공유 수준을 낮추거나 보관 기간을 줄여 서버 기록을 지워야 한다는 표시. 지울 때까지 올리지 않는다(REV1110A06).
    static let pendingClearKey = "assistantActivityPendingClear"
    private static var lastRunAt = Date.distantPast
    private static var trailing: Task<Void, Never>?
    private static var isRunning = false
    /// 서버가 잠시 뒤 다시 하라고 했으면(옮기는 중·쓰기 한도) 그때까지 올리지 않는다.
    private static var uploadsBlockedUntil = Date.distantPast

    /// 저장 뒤 부른다. 5분 안에 이미 올렸으면 남은 시간 뒤 한 번만 오늘을 올린다.
    static func requestSoon(model: AppModel) {
        guard trailing == nil, TripRelay.isAvailable else { return }
        let wait = max(0, minimumInterval - Date.now.timeIntervalSince(lastRunAt))
        trailing = Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            trailing = nil
            await run(model: model, dayCount: 1)
        }
    }

    /// 오늘과 지난 `dayCount - 1`일 중 바뀐 날을 올린다. 공유를 껐으면 서버 기록을 한 번 지운다.
    static func run(
        model: AppModel, dayCount: Int = 7, defaults: UserDefaults = .standard, env: AssistantRegistration.Environment = .live
    ) async {
        guard env.host != nil, AssistantRegistration.isReady(env), !isRunning, AssistantRelayGate.begin() else { return }
        isRunning = true
        defer {
            isRunning = false
            AssistantRelayGate.end()
        }
        lastRunAt = .now
        let level = AssistantShareLevel.current(defaults)
        guard level != .off else {
            if defaults.bool(forKey: sharedKey) || defaults.bool(forKey: pendingClearKey) { await clearRemote(defaults: defaults, env: env) }
            return
        }
        // 더 자세한 예전 기록이 서버에 남아 있으면 먼저 지운다. 못 지우면 다음에 다시 한다.
        if defaults.bool(forKey: pendingClearKey), await !clearRemote(defaults: defaults, env: env) { return }
        guard !TaptionExternalPrivacyStore.isLocked, Date.now >= uploadsBlockedUntil || env.session !== URLSession.shared else { return }
        let now = Date.now, calendar = Calendar.autoupdatingCurrent
        let retention = AssistantRetention.current(defaults).rawValue
        var inputs: [AssistantActivityInput] = []
        for offset in 0..<max(1, min(dayCount, retention, 7)) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)),
                  let input = await model.assistantActivityInput(for: date, now: now, calendar: calendar) else { continue }
            inputs.append(input)
        }
        let sent = AssistantActivityUploadGate.sentHashes(defaults)
        let stamp = AssistantActivityBuilder.Stamp(calendar: calendar).instant(now)
        let batches = await AssistantActivityUploadGate.prepare(inputs, level: level, stamp: stamp, sent: sent, retentionDays: retention)
        guard let master = env.secrets.read(.master) else { return }
        var count = 0
        for batch in batches {
            let request = TripRelay.relayRequest("/activity", method: "POST", body: batch.body, token: master, host: env.host)
            let reply = await TripRelay.send(request, session: env.session)
            guard reply?.status == 201 else {
                record("assistant_activity_upload_failed", status: reply?.status ?? -1, days: batch.days.count)
                if let reply, reply.status == 429 || reply.status == 503 {
                    uploadsBlockedUntil = now.addingTimeInterval(TripRelay.retryDelay(header: nil, body: reply.data))
                }
                return
            }
            AssistantActivityUploadGate.markSent(batch.days, defaults: defaults)
            defaults.set(true, forKey: sharedKey)
            count += batch.days.count
        }
        if count > 0 { record("assistant_activity_uploaded", status: 201, days: count) }
    }

    /// 공유 수준을 낮추거나 보관 기간을 줄였다. 서버의 날들을 지우도록 적어 둔다(다음 `run`이 지운 뒤 다시 올린다).
    static func requestClear(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: pendingClearKey)
        AssistantActivityUploadGate.reset(defaults: defaults)
    }

    /// 서버의 날들을 지운다. 지웠을 때만 true이고, 다음 실행이 새 설정으로 다시 올린다.
    @discardableResult
    static func clearRemote(defaults: UserDefaults = .standard, env: AssistantRegistration.Environment = .live) async -> Bool {
        let request = env.secrets.read(.master).flatMap { TripRelay.relayRequest("/activity", method: "DELETE", token: $0, host: env.host) }
        let reply = await TripRelay.send(request, session: env.session)
        guard let reply, (200..<300).contains(reply.status) else {
            record("assistant_activity_clear_failed", status: reply?.status ?? -1, days: 0)
            return false
        }
        defaults.set(false, forKey: sharedKey)
        defaults.set(false, forKey: pendingClearKey)
        AssistantActivityUploadGate.reset(defaults: defaults)
        return true
    }

    /// 백그라운드로 갈 때도 올릴 수 있게 잠깐 시간을 받는다.
    static func runInBackground(model: AppModel) {
        let application = UIApplication.shared
        let box = BackgroundTaskBox()
        box.id = application.beginBackgroundTask(withName: "assistant-activity") {
            MainActor.assumeIsolated { box.end(application) }
        }
        Task { @MainActor in
            await run(model: model)
            box.end(application)
        }
    }

    @MainActor
    private final class BackgroundTaskBox {
        var id = UIBackgroundTaskIdentifier.invalid

        func end(_ application: UIApplication) {
            guard id != .invalid else { return }
            application.endBackgroundTask(id)
            id = .invalid
        }
    }

    private static func record(_ event: String, status: Int, days: Int) {
        TaptionPlanDiagnosticsLogger.shared.record(event, metrics: ["status": Double(status), "days": Double(days)])
    }
}

extension AppModel {
    /// 하루 기록의 재료. 지도 카운터·잠금 화면 요약과 같은 계산을 쓴다. 읽지 못한 날은 nil.
    func assistantActivityInput(for day: Date, now: Date, calendar: Calendar) async -> AssistantActivityInput? {
        let data = await planDayDataSnapshot(for: day, forceReload: false)
        if data.sourceRevision == 0, data.actuals.isEmpty, data.travel.isEmpty, data.places.isEmpty { return nil }
        let span = MapHomeCounterTimelinePolicy.daySpan(of: day)
        let language = MapHomeLanguage.current
        let seconds = TaptionSealedDayBuilder.categoryDurations(
            actuals: data.actuals, travel: data.travel, stays: data.places,
            placeKinds: FrequentPlaceResolutionEngine().kindsByPlaceKey(settings.frequentPlaces),
            day: span, asOf: now
        )
        var titles: [String: String] = [:]
        for id in Set(seconds.keys).union(data.actuals.map(\.categoryID)) { titles[id] = assistantCategoryTitle(id, language: language) }
        let categories = seconds
            .filter { $0.key != "unconfirmed" && $0.value >= 60 }
            .sorted { ($1.value, $0.key) < ($0.value, $1.key) }
            .map { AssistantActivityDay.Category(id: $0.key, title: titles[$0.key] ?? $0.key, minutes: Int($0.value / 60)) }
        let plans = TaptionWatchDaySummaryFactory.make(plans: snapshot.plans, actuals: [], at: day, calendar: calendar)
        return AssistantActivityInput(
            day: day, calendar: calendar, language: language, categories: categories,
            steps: MapHomeCounterTimelinePolicy.stepCount(readings: data.readings, cutoff: nil),
            plansScheduled: plans.scheduledCount, plansCompleted: plans.completedCount,
            actuals: data.actuals, categoryTitles: titles,
            memos: snapshot.memos.filter { $0.occurredAt >= span.start && $0.occurredAt < span.end },
            stays: data.places, travel: data.travel,
            registeredNames: Dictionary(settings.frequentPlaces.map { ($0.stablePlaceKey, $0.displayName) }, uniquingKeysWith: { first, _ in first }),
            now: now,
            plans: snapshot.plans.filter { $0.span.end > span.start && $0.span.start < span.end },
            goals: snapshot.plans.filter { GoalRecordPolicy.isGoal($0) && $0.span.end > span.start && $0.span.start < span.end },
            tripStops: settings.travelPlanStops, tripItems: settings.travelTripItems ?? []
        )
    }

    func assistantCategoryTitle(_ id: String, language: MapHomeLanguage) -> String {
        if let major = MapHomeSidebarMajorCategory.all().first(where: { $0.id == id }) { return major.localizedTitle(language) }
        return snapshot.categories.first { $0.id == id }?.name ?? id
    }
}
