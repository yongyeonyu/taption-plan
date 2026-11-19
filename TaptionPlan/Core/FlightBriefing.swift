import Foundation
import TaptionPlanEngine
import TaptionPlanStore
import UserNotifications

/// 출발 전 브리핑 알림 계획(FLT1119A01): 출발 전날 저녁 8시, 출발 4시간 전, 지연 글을 받은 즉시.
/// 로컬 알림만 쓴다(서버 푸시 APNs는 AI 비서용 길이라 쓰지 않는다). 순수 계산이라 시험할 수 있고, 예약된 알림은 `flight-` 접두어로 관리한다.
struct FlightBriefing: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable { case eve, fourHours, delay }

    var kind: Kind
    var tripID: String
    var itemID: String
    var fireAt: Date
    var title: String
    var body: String
    var id: String { "\(FlightBriefingPolicy.identifierPrefix)\(kind.rawValue)-\(tripID)-\(itemID)" }
}

enum FlightBriefingPolicy {
    static let identifierPrefix = "flight-"
    /// 출발 전날 저녁 알림 시각(그 공항의 현지 시각).
    static let eveHour = 20
    static let leadHours = 4
    /// 한 번에 예약해 두는 비행 수(시스템 알림 한도 64건 안에서 다른 알림과 나눠 쓴다).
    static let maximumFlights = 8

    /// 앞으로 출발할 비행 일정마다 알림 계획을 만든다. 이미 지난 시각은 뺀다.
    static func briefings(items: [TravelTripItem], now: Date, language: MapHomeLanguage = .current) -> [FlightBriefing] {
        let upcoming = items.filter { $0.isFlight && $0.start > now }.sorted { $0.start < $1.start }.prefix(maximumFlights)
        var out: [FlightBriefing] = []
        for item in upcoming {
            guard let arrive = arriveBy(item) else { continue }
            let body = language.runtimeText("공항에 \(clock(arrive, item))까지 도착하세요.", "Arrive at the airport by \(clock(arrive, item)).")
            if let eve = eveTime(item), eve > now {
                out.append(FlightBriefing(kind: .eve, tripID: item.tripID, itemID: item.itemID, fireAt: eve, title: language.runtimeText("내일 출발 \(item.title)", "Departing tomorrow \(item.title)"), body: body))
            }
            let four = item.start.addingTimeInterval(-Double(leadHours) * 3_600)
            if four > now {
                out.append(FlightBriefing(kind: .fourHours, tripID: item.tripID, itemID: item.itemID, fireAt: four, title: language.runtimeText("곧 출발 \(item.title)", "Departing soon \(item.title)"), body: body))
            }
        }
        return out
    }

    /// 지연 글을 받은 즉시 알림. 이미 출발한 비행이거나 지연이 없으면 nil.
    static func delayBriefing(item: TravelTripItem, delayMinutes: Int, now: Date, language: MapHomeLanguage = .current) -> FlightBriefing? {
        guard item.isFlight, delayMinutes > 0, item.start.addingTimeInterval(Double(delayMinutes) * 60) > now else { return nil }
        let local = localClock(item.start, offset: item.startOffsetSeconds)
        return FlightBriefing(
            kind: .delay, tripID: item.tripID, itemID: item.itemID, fireAt: now.addingTimeInterval(2),
            title: language.runtimeText("\(item.title) 지연 알림", "\(item.title) delay notice"),
            body: language.runtimeText("\(delayMinutes)분 지연, 새 출발 시각 \(local)", "Delayed \(delayMinutes) min, new departure \(local)")
        )
    }

    /// 공항에 도착해야 하는 시각: 국제선 180분·국내선 60분 전(현장 안내가 있으면 그 값).
    static func arriveBy(_ item: TravelTripItem) -> Date? {
        guard let origin = item.originCode, let destination = item.destinationCode else { return nil }
        let wall = Int(item.start.timeIntervalSince1970) + item.startOffsetSeconds
        let day = ((wall % 86_400) + 86_400) % 86_400
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(wall - day)))
        guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { return nil }
        let leg = FlightLeg(
            origin: origin, destination: destination,
            departure: FlightLocalTime(year: year, month: month, day: dayOfMonth, hour: day / 3_600, minute: day % 3_600 / 60)
        )
        let onsite = FlightCardMapping.log(of: item).onsiteArrive
        return FlightAirportArrival.recommendation(for: leg, onsiteGuidanceLeadMinutes: onsite)?.arriveBy
    }

    /// 출발 공항 현지 달력으로 출발 전날 저녁 `eveHour`시.
    static func eveTime(_ item: TravelTripItem) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: item.startOffsetSeconds) ?? .gmt
        guard let previous = calendar.date(byAdding: .day, value: -1, to: item.start) else { return nil }
        return calendar.date(bySettingHour: eveHour, minute: 0, second: 0, of: previous)
    }

    private static func clock(_ date: Date, _ item: TravelTripItem) -> String { localClock(date, offset: item.startOffsetSeconds) }

    private static func localClock(_ date: Date, offset: Int) -> String {
        let local = Int(date.timeIntervalSince1970) + offset
        let minute = ((local % 86_400) + 86_400) % 86_400 / 60
        return String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

/// 예약된 항공 알림을 계획에 맞춘다. 알림 권한이 이미 허용된 때만 예약하고 권한을 묻지 않는다.
actor FlightBriefingScheduler {
    static let shared = FlightBriefingScheduler()
    private let center = UNUserNotificationCenter.current()

    func synchronize(items: [TravelTripItem], now: Date = .now) async {
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
        let desired = FlightBriefingPolicy.briefings(items: items, now: now)
        let wanted = Set(desired.map(\.id))
        let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(FlightBriefingPolicy.identifierPrefix) && !$0.identifier.contains("delay-") }
        let obsolete = pending.map(\.identifier).filter { !wanted.contains($0) }
        if !obsolete.isEmpty { center.removePendingNotificationRequests(withIdentifiers: obsolete) }
        let existing = Set(pending.map(\.identifier))
        for briefing in desired where !existing.contains(briefing.id) { await schedule(briefing, now: now) }
    }

    func notifyDelay(_ briefing: FlightBriefing) async {
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
        await schedule(briefing, now: .now)
    }

    private func schedule(_ briefing: FlightBriefing, now: Date) async {
        let content = UNMutableNotificationContent()
        content.title = briefing.title
        content.body = briefing.body
        content.sound = .default
        content.userInfo = ["tripID": briefing.tripID, "itemID": briefing.itemID]
        let trigger: UNNotificationTrigger
        if briefing.kind == .delay {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, briefing.fireAt.timeIntervalSince(now)), repeats: false)
        } else {
            trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day, .hour, .minute, .second], from: briefing.fireAt), repeats: false)
        }
        try? await center.add(UNNotificationRequest(identifier: briefing.id, content: content, trigger: trigger))
    }
}

extension AppModel {
    /// 예약된 항공 알림을 지금 일정에 맞춘다.
    @MainActor
    func syncFlightBriefings(now: Date = .now) async {
        await FlightBriefingScheduler.shared.synchronize(items: snapshot.settings.travelTripItems ?? [], now: now)
    }
}
