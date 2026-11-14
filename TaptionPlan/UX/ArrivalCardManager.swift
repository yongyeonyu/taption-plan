import Foundation
import Observation
import TaptionPlanCore
import UserNotifications

/// 일정 장소에 도착하면 카드를 띄운다(ARC1114A14). 앱이 받은 위치 기록에서만 판정하고, 일정 하나에 한 번만 보인다.
@MainActor
@Observable
final class ArrivalCardManager {
    static let shared = ArrivalCardManager()
    static let enabledKey = "arrivalCard.enabled"
    nonisolated static let userInfoStopID = "arrivalStopID"
    nonisolated static let identifierPrefix = "arrival-card-"
    private static let shownKey = "arrivalCard.shown"
    private static let checkedKey = "arrivalCard.checked"
    private static let evaluationInterval: TimeInterval = 10
    private static let checkedRetention: TimeInterval = 90 * 24 * 60 * 60

    private(set) var card: ArrivalCard?
    private(set) var checked: Set<String>

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastEvaluatedAt: Date?
    /// 화면이 꺼져 있거나 잠겨 있어 아직 못 보인 도착. `fromTap`이면 알림을 눌러 연 것이라 시각이 지나도 보인다.
    @ObservationIgnored private var pending: (stopID: UUID, fromTap: Bool)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        checked = Set(Self.loadDates(Self.checkedKey, defaults: defaults).keys)
    }

    var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// 앱이 받은 위치 기록 하나를 본다. 10초에 한 번만 판정한다.
    func observe(_ reading: SensorReading, model: AppModel, now: Date = .now) {
        guard let point = reading.point, isEnabled, model.isBootstrapped,
              !model.settings.travelPlanStops.isEmpty,
              lastEvaluatedAt.map({ now.timeIntervalSince($0) >= Self.evaluationInterval }) ?? true else { return }
        lastEvaluatedAt = now
        var shown = ArrivalDetector.pruned(Self.loadDates(Self.shownKey, defaults: defaults), now: now)
        let fix = ArrivalFix(
            latitude: point.latitude, longitude: point.longitude,
            horizontalAccuracy: point.horizontalAccuracy, timestamp: reading.timestamp
        )
        guard let hit = ArrivalDetector.arrival(
            fix: fix, now: now, candidates: candidates(model),
            shown: Set(shown.keys.compactMap(UUID.init(uuidString:)))
        ) else { return }
        let isVisible = model.isSceneActive && !model.isAppLocked && !TaptionExternalPrivacyStore.isLocked
        // 앞에 있는데 잠겨 있으면 풀린 뒤의 위치에서 다시 본다.
        guard isVisible || !model.isSceneActive else { return }
        shown[hit.stopID.uuidString] = now
        Self.saveDates(shown, key: Self.shownKey, defaults: defaults)
        TaptionPlanDiagnosticsLogger.shared.record("arrival_card", fields: ["foreground": isVisible ? "1" : "0"])
        if isVisible {
            present(hit, model: model)
        } else {
            pending = (hit.stopID, false)
            let hidesTitle = model.securityStatus.settings.lockOnLaunch || model.securityStatus.settings.lockOnForeground
            Task { await Self.notify(hit, hidesTitle: hidesTitle) }
        }
    }

    /// 알림을 눌러 열었다. 기록을 다 읽은 뒤 화면이 `presentPending`으로 보인다.
    func open(stopID: UUID) {
        pending = (stopID, true)
        if let model = AppModel.applicationInstance { presentPending(model: model) }
    }

    /// 앱이 앞으로 왔을 때 못 보인 도착을 보인다. 알림을 누르지 않았으면 일정이 끝나기 전에만 보인다.
    func presentPending(model: AppModel, now: Date = .now) {
        guard let pending, model.isBootstrapped, !model.isAppLocked, !TaptionExternalPrivacyStore.isLocked else { return }
        self.pending = nil
        guard let hit = candidates(model).first(where: { $0.stopID == pending.stopID }),
              pending.fromTap || now <= hit.closesAt else { return }
        present(hit, model: model)
    }

    func dismiss() {
        if card != nil { card = nil }
    }

    /// 세부 계획 완료 표시. 여행 일정 모델에 완료 칸이 없어 이 기기에만 둔다.
    func toggle(_ id: String, now: Date = .now) {
        var dates = Self.loadDates(Self.checkedKey, defaults: defaults).filter { now.timeIntervalSince($0.value) < Self.checkedRetention }
        dates[id] = dates[id] == nil ? now : nil
        Self.saveDates(dates, key: Self.checkedKey, defaults: defaults)
        checked = Set(dates.keys)
    }

    private func candidates(_ model: AppModel) -> [ArrivalCandidate] {
        ArrivalDetector.candidates(
            stops: model.settings.travelPlanStops,
            items: model.settings.travelTripItems ?? [],
            plans: model.snapshot.plans
        )
    }

    private func present(_ hit: ArrivalCandidate, model: AppModel) {
        let budget = hit.tripID.flatMap { id in LedgerBook.shared.trips.first { $0.id == id }?.budgetKRW }
        let next = ArrivalCard.make(candidate: hit, items: model.settings.travelTripItems ?? [], tripBudgetKRW: budget)
        if next != card { card = next }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.identifierPrefix + hit.stopID.uuidString])
    }

    /// 알림 권한이 이미 있을 때만 보낸다. 권한을 새로 묻지 않는다.
    private nonisolated static func notify(_ hit: ArrivalCandidate, hidesTitle: Bool) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        let content = UNMutableNotificationContent()
        // 앱 잠금을 켠 사용자에게는 잠금 화면에 장소 이름을 보이지 않는다.
        content.title = hidesTitle
            ? AppLanguagePreference.text(korean: "일정 장소에 도착했어요", english: "You arrived at a planned place")
            : hit.title
        content.body = AppLanguagePreference.text(
            korean: "도착했어요. 눌러서 메모와 체크리스트를 보세요.",
            english: "You're here. Tap to see your notes and checklist."
        )
        content.sound = .default
        content.userInfo = [userInfoStopID: hit.stopID.uuidString]
        try? await center.add(UNNotificationRequest(
            identifier: identifierPrefix + hit.stopID.uuidString, content: content, trigger: nil
        ))
    }

    private static func loadDates(_ key: String, defaults: UserDefaults) -> [String: Date] {
        (defaults.dictionary(forKey: key) as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }

    private static func saveDates(_ value: [String: Date], key: String, defaults: UserDefaults) {
        defaults.set(value.mapValues(\.timeIntervalSince1970), forKey: key)
    }
}
