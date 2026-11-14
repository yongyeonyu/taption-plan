import CoreLocation
import Foundation
import UserNotifications

/// 앱이 꺼져 있어도 울리도록 iOS에 맡길 도착 알림을 고르는 순수 규칙(ARN1114A17).
enum ArrivalAlertPlan {
    /// iOS가 앱 하나에 허용하는 감시 지역 수.
    static let regionBudget = 20
    static let spareRegions = 1
    /// 근처 메모(최대 10곳)와 머무름 영역(1곳)이 다 차도 8곳은 남는다. 그쪽이 덜 쓰면 10곳까지 쓴다.
    static let maximumSlots = 10
    static let duplicateDistance: CLLocationDistance = 60
    static let minimumRadius: CLLocationDistance = 100
    /// 창이 열리기 이만큼 전보다 일찍 울린 알림은 도착으로 치지 않고 다시 건다.
    static let earlyGrace: TimeInterval = 60 * 60

    static func slots(otherRegions: Int) -> Int {
        max(0, min(maximumSlots, regionBudget - spareRegions - max(0, otherRegions)))
    }

    /// 기기가 감시할 수 있는 범위 안으로 맞춘 반경. 상한을 모르면(0 이하) 아래쪽만 맞춘다.
    static func radius(maximum: CLLocationDistance) -> CLLocationDistance {
        let radius = max(ArrivalDetector.radius, minimumRadius)
        return maximum > 0 ? min(radius, maximum) : radius
    }

    static func identifier(for stopID: UUID) -> String {
        ArrivalCardManager.identifierPrefix + stopID.uuidString
    }

    /// 예약할 일정. 시각 창이 오늘에 걸친 것만 그날 하루 걸어 두고(전날 밤에는 걸지 않는다, 대표 결정 2026-11-14), 끝났거나 이미 보인 일정은 빼고, 창이 열린 일정(가까운 순) 다음에 곧 열릴 일정(이른 순)을 둔다.
    /// 같은 곳의 일정은 앞선 하나만 건다. 위치 알림에는 시각 조건이 없어 창이 열리기 전에 지나가도 울릴 수 있다.
    static func selection(
        candidates: [ArrivalCandidate],
        near coordinate: CLLocationCoordinate2D?,
        now: Date,
        shown: Set<UUID>,
        slots: Int,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ArrivalCandidate] {
        guard slots > 0 else { return [] }
        let startOfToday = calendar.startOfDay(for: now)
        let horizon = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday.addingTimeInterval(86_400)
        let here = coordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let ranked = candidates
            .filter {
                !shown.contains($0.stopID) && $0.closesAt > now && $0.opensAt < horizon
                    && CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
            }
            .map { candidate -> (candidate: ArrivalCandidate, isOpen: Bool, distance: CLLocationDistance) in
                let place = CLLocation(latitude: candidate.latitude, longitude: candidate.longitude)
                return (candidate, candidate.opensAt <= now, here?.distance(from: place) ?? 0)
            }
            .sorted { left, right in
                if left.isOpen != right.isOpen { return left.isOpen }
                let leftID = left.candidate.stopID.uuidString, rightID = right.candidate.stopID.uuidString
                return left.isOpen
                    ? (left.distance, left.candidate.opensAt, leftID) < (right.distance, right.candidate.opensAt, rightID)
                    : (left.candidate.opensAt, left.distance, leftID) < (right.candidate.opensAt, right.distance, rightID)
            }
        var chosen: [ArrivalCandidate] = []
        for entry in ranked where chosen.count < slots {
            let place = CLLocation(latitude: entry.candidate.latitude, longitude: entry.candidate.longitude)
            let isDuplicate = chosen.contains {
                place.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= duplicateDistance
            }
            if !isDuplicate { chosen.append(entry.candidate) }
        }
        return chosen
    }

    /// 걸어 둔 일회성 알림이 대기 목록에서 사라졌으면 iOS가 전달한 것이다. 전달 시각은 알림 센터에 남아 있을 때만 안다.
    /// 창이 열리기 한참 전에 울린 것은 넣지 않아 제때 다시 알릴 수 있게 한다.
    static func firedStops(
        registered: Set<String>,
        pending: Set<String>,
        delivered: [String: Date],
        candidates: [ArrivalCandidate],
        now: Date
    ) -> [UUID: Date] {
        var result: [UUID: Date] = [:]
        for identifier in registered.subtracting(pending) {
            guard identifier.hasPrefix(ArrivalCardManager.identifierPrefix),
                  let stopID = UUID(uuidString: String(identifier.dropFirst(ArrivalCardManager.identifierPrefix.count))) else { continue }
            let date = delivered[identifier] ?? now
            if let candidate = candidates.first(where: { $0.stopID == stopID }),
               date < candidate.opensAt.addingTimeInterval(-earlyGrace) { continue }
            result[stopID] = date
        }
        return result
    }
}

struct ArrivalAlertSyncSummary: Equatable, Sendable {
    var availability: NearbyMemoAvailability
    var slots: Int
    var pending: Int
    var failed: Int
    var fired: [UUID: Date]
}

/// iOS가 지역 진입을 감시하고 알림까지 전달한다. 앱은 걸어 둘 일정만 맞춘다.
actor ArrivalAlertScheduler {
    struct Request: Sendable {
        var candidates: [ArrivalCandidate]
        var shown: Set<UUID>
        var availability: NearbyMemoAvailability
        var latitude: Double?
        var longitude: Double?
        /// 이 앱이 `CLLocationManager`로 직접 감시하는 지역 수.
        var monitoredRegions: Int
        var radius: CLLocationDistance
        var hidesTitle: Bool
        var now: Date
    }

    static let shared = ArrivalAlertScheduler()
    private static let registeredKey = "arrivalCard.alertRegistered"

    private let center = UNUserNotificationCenter.current()
    private var latest: Request?
    private var isRunning = false

    func synchronize(_ request: Request) async -> ArrivalAlertSyncSummary? {
        latest = request
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }
        var summary: ArrivalAlertSyncSummary?
        while let next = latest {
            latest = nil
            let result = await run(next)
            // 이어 돈 판의 전달 기록을 잃지 않는다.
            summary = ArrivalAlertSyncSummary(
                availability: result.availability, slots: result.slots, pending: result.pending, failed: result.failed,
                fired: (summary?.fired ?? [:]).merging(result.fired) { old, _ in old }
            )
        }
        return summary
    }

    func cancelAll() async {
        latest = nil
        await removeManaged()
    }

    private func run(_ request: Request) async -> ArrivalAlertSyncSummary {
        guard request.availability == .active else {
            await removeManaged()
            return ArrivalAlertSyncSummary(availability: request.availability, slots: 0, pending: 0, failed: 0, fired: [:])
        }
        let located = await center.pendingNotificationRequests().filter { $0.trigger is UNLocationNotificationTrigger }
        let managed = located.filter { $0.identifier.hasPrefix(ArrivalCardManager.identifierPrefix) }
        let pendingIDs = Set(managed.map(\.identifier))
        let delivered = await center.deliveredNotifications()
            .filter { $0.request.identifier.hasPrefix(ArrivalCardManager.identifierPrefix) }
            .reduce(into: [String: Date]()) { $0[$1.request.identifier] = $1.date }
        let fired = ArrivalAlertPlan.firedStops(
            registered: Set(UserDefaults.standard.stringArray(forKey: Self.registeredKey) ?? []),
            pending: pendingIDs, delivered: delivered, candidates: request.candidates, now: request.now
        )
        let slots = ArrivalAlertPlan.slots(otherRegions: located.count - managed.count + request.monitoredRegions)
        var coordinate: CLLocationCoordinate2D?
        if let latitude = request.latitude, let longitude = request.longitude {
            coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        let desired = ArrivalAlertPlan.selection(
            candidates: request.candidates, near: coordinate, now: request.now,
            shown: request.shown.union(fired.keys), slots: slots
        )
        let obsolete = pendingIDs.subtracting(desired.map { ArrivalAlertPlan.identifier(for: $0.stopID) })
        if !obsolete.isEmpty { center.removePendingNotificationRequests(withIdentifiers: Array(obsolete)) }

        let existing = Dictionary(managed.map { ($0.identifier, $0) }) { first, _ in first }
        var active: [String] = []
        var failed = 0
        for candidate in desired {
            let identifier = ArrivalAlertPlan.identifier(for: candidate.stopID)
            let content = ArrivalCardManager.content(for: candidate, hidesTitle: request.hidesTitle)
            // 같은 곳·같은 문구로 이미 걸려 있으면 다시 걸지 않는다.
            if let current = existing[identifier], Self.matches(current, candidate: candidate, radius: request.radius, title: content.title) {
                active.append(identifier)
                continue
            }
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: candidate.latitude, longitude: candidate.longitude),
                radius: request.radius, identifier: identifier
            )
            region.notifyOnEntry = true
            region.notifyOnExit = false
            do {
                try await center.add(UNNotificationRequest(
                    identifier: identifier, content: content, trigger: UNLocationNotificationTrigger(region: region, repeats: false)
                ))
                active.append(identifier)
            } catch {
                failed += 1
            }
        }
        UserDefaults.standard.set(active, forKey: Self.registeredKey)
        return ArrivalAlertSyncSummary(availability: .active, slots: slots, pending: active.count, failed: failed, fired: fired)
    }

    /// 바로 보낸 도착 알림과 식별자가 같아, 위치 조건이 붙은 예약만 지운다.
    private func removeManaged() async {
        let identifiers = await center.pendingNotificationRequests()
            .filter { $0.trigger is UNLocationNotificationTrigger && $0.identifier.hasPrefix(ArrivalCardManager.identifierPrefix) }
            .map(\.identifier)
        if !identifiers.isEmpty { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
        UserDefaults.standard.removeObject(forKey: Self.registeredKey)
    }

    private static func matches(_ request: UNNotificationRequest, candidate: ArrivalCandidate, radius: CLLocationDistance, title: String) -> Bool {
        guard let region = (request.trigger as? UNLocationNotificationTrigger)?.region as? CLCircularRegion else { return false }
        let distance = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
            .distance(from: CLLocation(latitude: candidate.latitude, longitude: candidate.longitude))
        return distance < 1 && abs(region.radius - radius) < 1 && request.content.title == title
    }
}

extension ArrivalCardManager {
    /// 앱 시작·앞으로 올 때·저장 뒤·날이 바뀔 때·카드를 보였을 때·스위치를 바꿨을 때 부른다. 이어진 요청은 마지막 한 번만 맞춘다.
    func scheduleAlertSync(model: AppModel? = AppModel.applicationInstance) {
        observeDayChange()
        alertSyncTask?.cancel()
        alertSyncTask = Task { @MainActor [weak self, weak model] in
            // 근처 메모가 먼저 맞춘 뒤 남은 자리를 센다.
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, let model else { return }
            await self.syncAlerts(model: model)
        }
    }

    /// 권한은 읽기만 한다. 알림과 「앱 사용 중」 이상의 정확한 위치 권한이 이미 있을 때만 걸고, 없으면 모두 지운다.
    func syncAlerts(model: AppModel, now: Date = .now) async {
        // 불러오기 전의 빈 일정으로 맞추면 걸어 둔 알림이 모두 지워진다.
        guard model.isBootstrapped, !model.repositoryLoadFailed, !model.isDeletingUserData else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let location = CLLocationManager()
        let availability = NearbyMemoAvailability.resolve(
            isEnabled: isEnabled,
            notificationsGranted: status == .authorized || status == .provisional || status == .ephemeral,
            locationStatus: location.authorizationStatus,
            hasFullAccuracy: location.accuracyAuthorization == .fullAccuracy
        )
        let here = availability == .active ? location.location?.coordinate : nil
        let security = model.securityStatus.settings
        guard let summary = await ArrivalAlertScheduler.shared.synchronize(ArrivalAlertScheduler.Request(
            candidates: availability == .active ? candidates(model) : [],
            shown: shownStopIDs(now: now),
            availability: availability,
            latitude: here?.latitude,
            longitude: here?.longitude,
            monitoredRegions: location.monitoredRegions.count,
            radius: ArrivalAlertPlan.radius(maximum: location.maximumRegionMonitoringDistance),
            hidesTitle: security.lockOnLaunch || security.lockOnForeground,
            now: now
        )) else { return }
        markShown(summary.fired, now: now)
        TaptionPlanDiagnosticsLogger.shared.record(
            "arrival_alert_sync",
            level: summary.failed > 0 ? .error : .info,
            fields: ["availability": String(describing: summary.availability)],
            metrics: [
                "slots": Double(summary.slots),
                "pending": Double(summary.pending),
                "failed": Double(summary.failed),
                "fired": Double(summary.fired.count)
            ]
        )
    }

    private func observeDayChange() {
        guard dayChangeTask == nil else { return }
        dayChangeTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged).map({ _ in () }) {
                self?.scheduleAlertSync()
            }
        }
    }
}
