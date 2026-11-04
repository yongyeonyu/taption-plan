import CoreLocation
import Foundation
import TaptionPlanCore
import UserNotifications

struct NearbyMemoCoordinate: Equatable, Sendable {
    var latitude: Double
    var longitude: Double

    func distance(to other: NearbyMemoCoordinate) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}

/// 가까운 메모를 묶은 한 장소. 키는 가장 먼저 쓴 메모의 ID라 메모가 늘어도 바뀌지 않는다.
struct NearbyMemoPlace: Equatable, Sendable {
    var key: UUID
    var coordinate: NearbyMemoCoordinate
    var latestAt: Date
    var latestText: String
    var memoCount: Int
}

enum NearbyMemoAvailability: Equatable, Sendable {
    case active
    case turnedOff
    case notificationsNotAllowed
    case locationNotAllowed
    case approximateLocation

    /// 권한은 읽기만 한다. 여기서 시스템 권한 창을 띄우지 않는다.
    static func resolve(
        isEnabled: Bool,
        notificationsGranted: Bool,
        locationStatus: CLAuthorizationStatus,
        hasFullAccuracy: Bool
    ) -> NearbyMemoAvailability {
        guard isEnabled else { return .turnedOff }
        guard notificationsGranted else { return .notificationsNotAllowed }
        guard locationStatus == .authorizedWhenInUse || locationStatus == .authorizedAlways else {
            return .locationNotAllowed
        }
        return hasFullAccuracy ? .active : .approximateLocation
    }

    /// 현재 권한과 마지막으로 알려진 위치. `CLLocationManager` 생성과 읽기는 권한 창을 띄우지 않는다.
    @MainActor
    static func current() async -> (availability: NearbyMemoAvailability, coordinate: NearbyMemoCoordinate?) {
        let isEnabled = UserDefaults.standard.object(forKey: NearbyMemoPolicy.enabledKey) as? Bool ?? true
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let manager = CLLocationManager()
        let availability = resolve(
            isEnabled: isEnabled,
            notificationsGranted: status == .authorized || status == .provisional || status == .ephemeral,
            locationStatus: manager.authorizationStatus,
            hasFullAccuracy: manager.accuracyAuthorization == .fullAccuracy
        )
        guard availability == .active, let location = manager.location else { return (availability, nil) }
        return (
            availability,
            NearbyMemoCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        )
    }
}

enum NearbyMemoPolicy {
    static let enabledKey = "nearbyMemo.enabled"
    static let identifierPrefix = "nearby-memo-"
    static let regionRadius: CLLocationDistance = 200
    static let groupingDistance: CLLocationDistance = 100
    /// 앱당 감시 지역과 예약 알림 수가 제한되어 일정 알림 상한과 함께 정한다.
    static let maximumPlaces = 10
    static let renotifyInterval: TimeInterval = 24 * 60 * 60

    /// 아이콘을 직접 고른 위치 메모만 대상이다. 기본 아이콘은 위치를 넣으면 자동으로 붙으므로 제외한다.
    static func isEligible(_ memo: ActionMemo, startOfToday: Date) -> Bool {
        guard memo.mapPoint != nil, memo.occurredAt < startOfToday,
              let symbol = memo.stickerSymbol else { return false }
        return symbol != StickerCatalog.defaultMemoSymbol
    }

    static func places(
        from memos: [ActionMemo],
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [NearbyMemoPlace] {
        let startOfToday = calendar.startOfDay(for: now)
        let ordered = memos
            .filter { isEligible($0, startOfToday: startOfToday) }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        var places: [NearbyMemoPlace] = []
        for memo in ordered {
            guard let point = memo.mapPoint else { continue }
            let coordinate = NearbyMemoCoordinate(latitude: point.latitude, longitude: point.longitude)
            if let index = places.firstIndex(where: {
                $0.coordinate.distance(to: coordinate) <= groupingDistance
            }) {
                places[index].memoCount += 1
                if memo.occurredAt >= places[index].latestAt {
                    places[index].latestAt = memo.occurredAt
                    places[index].latestText = memo.text
                }
            } else {
                places.append(NearbyMemoPlace(
                    key: memo.id,
                    coordinate: coordinate,
                    latestAt: memo.occurredAt,
                    latestText: memo.text,
                    memoCount: 1
                ))
            }
        }
        return places
    }

    /// 재알림 간격이 지난 장소 중 가까운 곳을 고른다. 위치를 모르면 최근 메모 순이다.
    static func selection(
        from places: [NearbyMemoPlace],
        near coordinate: NearbyMemoCoordinate?,
        lastFired: [String: Date],
        now: Date,
        limit: Int = maximumPlaces
    ) -> [NearbyMemoPlace] {
        let ready = places.filter { place in
            guard let fired = lastFired[identifier(for: place.key)] else { return true }
            return now.timeIntervalSince(fired) >= renotifyInterval
        }
        let sorted: [NearbyMemoPlace]
        if let coordinate {
            sorted = ready.sorted {
                $0.coordinate.distance(to: coordinate) < $1.coordinate.distance(to: coordinate)
            }
        } else {
            sorted = ready.sorted { $0.latestAt > $1.latestAt }
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// 등록해 둔 일회성 알림이 대기 목록에서 사라졌으면 iOS가 전달한 것이다. 앱이 직접 지운 것은 등록 목록에서 먼저 뺀다.
    static func updatedFireTimes(
        previous: [String: Date],
        registered: Set<String>,
        pending: Set<String>,
        delivered: [String: Date],
        now: Date
    ) -> [String: Date] {
        var result = previous
        for (identifier, date) in delivered {
            result[identifier] = max(result[identifier] ?? date, date)
        }
        for identifier in registered.subtracting(pending) where delivered[identifier] == nil {
            result[identifier] = now
        }
        return result.filter { now.timeIntervalSince($0.value) < renotifyInterval }
    }

    static func body(for place: NearbyMemoPlace) -> String {
        let trimmed = place.latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty
            ? AppLanguagePreference.text(korean: "이곳에 남긴 메모가 있어요.", english: "You left a memo here.")
            : String(trimmed.prefix(120))
        guard place.memoCount > 1 else { return text }
        let others = place.memoCount - 1
        return text + AppLanguagePreference.text(korean: " 외 \(others)개", english: " +\(others) more")
    }

    /// 앱 잠금을 켠 사용자에게는 잠금 화면에 메모 글자를 보이지 않는다.
    static func body(for place: NearbyMemoPlace, hidesText: Bool) -> String {
        hidesText
            ? AppLanguagePreference.text(korean: "이 근처에 지난 메모가 있어요.", english: "You left a memo near here.")
            : body(for: place)
    }

    static func identifier(for key: UUID) -> String {
        "\(identifierPrefix)\(key.uuidString)"
    }
}

struct NearbyMemoSyncSummary: Equatable, Sendable {
    var availability: NearbyMemoAvailability
    var desired: Int
    var pending: Int
    var failed: Int
    var fired: Int
}

/// iOS가 지역 진입을 감시하고 알림까지 전달한다. 앱은 앞으로 울릴 장소만 맞춰 둔다.
actor NearbyMemoNotificationScheduler {
    private struct Request: Sendable {
        var memos: [ActionMemo]
        var availability: NearbyMemoAvailability
        var coordinate: NearbyMemoCoordinate?
        var hidesText: Bool
        var now: Date
    }

    private static let registeredKey = "nearbyMemo.registered"
    private static let lastFiredKey = "nearbyMemo.lastFired"

    private let center = UNUserNotificationCenter.current()
    private var latest: Request?
    private var isRunning = false

    @discardableResult
    func synchronize(
        memos: [ActionMemo],
        availability: NearbyMemoAvailability,
        coordinate: NearbyMemoCoordinate?,
        hidesText: Bool,
        now: Date = .now
    ) async -> NearbyMemoSyncSummary? {
        latest = Request(
            memos: memos, availability: availability, coordinate: coordinate, hidesText: hidesText, now: now
        )
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }
        var summary: NearbyMemoSyncSummary?
        while let next = latest {
            latest = nil
            summary = await run(next)
        }
        return summary
    }

    func cancelAll() async {
        latest = nil
        await removeManagedRequests()
        UserDefaults.standard.removeObject(forKey: Self.registeredKey)
        UserDefaults.standard.removeObject(forKey: Self.lastFiredKey)
    }

    private func run(_ request: Request) async -> NearbyMemoSyncSummary {
        guard request.availability == .active else {
            await removeManagedRequests()
            UserDefaults.standard.removeObject(forKey: Self.registeredKey)
            return NearbyMemoSyncSummary(
                availability: request.availability, desired: 0, pending: 0, failed: 0, fired: 0
            )
        }

        let managed = await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(NearbyMemoPolicy.identifierPrefix) }
        let pendingIDs = Set(managed.map(\.identifier))
        let deliveredDates = await center.deliveredNotifications()
            .filter { $0.request.identifier.hasPrefix(NearbyMemoPolicy.identifierPrefix) }
            .reduce(into: [String: Date]()) { $0[$1.request.identifier] = $1.date }
        let registered = Set(UserDefaults.standard.stringArray(forKey: Self.registeredKey) ?? [])
        let fired = registered.subtracting(pendingIDs).count
        let lastFired = NearbyMemoPolicy.updatedFireTimes(
            previous: Self.loadLastFired(),
            registered: registered,
            pending: pendingIDs,
            delivered: deliveredDates,
            now: request.now
        )
        Self.saveLastFired(lastFired)

        let desired = NearbyMemoPolicy.selection(
            from: NearbyMemoPolicy.places(from: request.memos, now: request.now),
            near: request.coordinate,
            lastFired: lastFired,
            now: request.now
        )
        let desiredIDs = Set(desired.map { NearbyMemoPolicy.identifier(for: $0.key) })
        let obsolete = pendingIDs.subtracting(desiredIDs)
        if !obsolete.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(obsolete))
        }

        let existing = Dictionary(uniqueKeysWithValues: managed.map { ($0.identifier, $0) })
        var active: [String] = []
        var failed = 0
        for place in desired {
            let identifier = NearbyMemoPolicy.identifier(for: place.key)
            if let current = existing[identifier],
               Self.matches(current, place: place, hidesText: request.hidesText) {
                active.append(identifier)
                continue
            }
            do {
                try await center.add(Self.makeRequest(identifier: identifier, place: place, hidesText: request.hidesText))
                active.append(identifier)
            } catch {
                failed += 1
            }
        }
        UserDefaults.standard.set(active, forKey: Self.registeredKey)
        return NearbyMemoSyncSummary(
            availability: .active, desired: desired.count, pending: active.count, failed: failed, fired: fired
        )
    }

    private func removeManagedRequests() async {
        let identifiers = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(NearbyMemoPolicy.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private static func makeRequest(identifier: String, place: NearbyMemoPlace, hidesText: Bool) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = AppLanguagePreference.text(korean: "이곳에 남긴 메모", english: "A memo you left here")
        content.subtitle = place.latestAt.formatted(.dateTime.month().day())
        content.body = NearbyMemoPolicy.body(for: place, hidesText: hidesText)
        content.sound = .default
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(
                latitude: place.coordinate.latitude,
                longitude: place.coordinate.longitude
            ),
            radius: NearbyMemoPolicy.regionRadius,
            identifier: identifier
        )
        region.notifyOnEntry = true
        region.notifyOnExit = false
        return UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNLocationNotificationTrigger(region: region, repeats: false)
        )
    }

    private static func matches(_ request: UNNotificationRequest, place: NearbyMemoPlace, hidesText: Bool) -> Bool {
        guard let trigger = request.trigger as? UNLocationNotificationTrigger,
              let region = trigger.region as? CLCircularRegion else { return false }
        let center = NearbyMemoCoordinate(
            latitude: region.center.latitude,
            longitude: region.center.longitude
        )
        return center.distance(to: place.coordinate) < 1
            && request.content.body == NearbyMemoPolicy.body(for: place, hidesText: hidesText)
    }

    private static func loadLastFired() -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: lastFiredKey) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private static func saveLastFired(_ value: [String: Date]) {
        UserDefaults.standard.set(value.mapValues(\.timeIntervalSince1970), forKey: lastFiredKey)
    }
}
