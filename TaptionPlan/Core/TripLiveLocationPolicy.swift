import CoreLocation
import Foundation
import TaptionTripShare

/// 여행 중 동행 위치 공유(LOC1116S01)의 순수한 판단들: 보낼지, 기본 기간, 받은 위치의 표시값. 설계는 `docs/TRIP_LIVE_LOCATION_PLAN.md`.
enum TripLiveLocationPolicy {
    /// 앞 화면: 움직임이 20m 이상이고 15초 이상 지났을 때, 멈춰 있어도 5분마다 한 번.
    static let foregroundGap: TimeInterval = 15
    static let foregroundMeters: CLLocationDistance = 20
    static let heartbeat: TimeInterval = 300
    /// 뒤: iOS가 위치를 줄 때만, 60초·50m 이상.
    static let backgroundGap: TimeInterval = 60
    static let backgroundMeters: CLLocationDistance = 50
    /// 이보다 나쁜 정확도(m)는 보내지 않는다.
    static let worstAccuracy: CLLocationAccuracy = 200
    /// 이보다 오래된 도움 요청용 위치는 쓰지 않는다.
    static let freshForHelp: TimeInterval = 120
    static let helpNoteLimit = ShareLocationPayload.noteLimit

    struct Fix: Equatable {
        var latitude: Double
        var longitude: Double
        var accuracy: Double
        var at: Date

        init(latitude: Double, longitude: Double, accuracy: Double, at: Date) {
            self.latitude = latitude
            self.longitude = longitude
            self.accuracy = accuracy
            self.at = at
        }

        init(_ location: CLLocation, at: Date = .now) {
            self.init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, accuracy: location.horizontalAccuracy, at: at)
        }

        func meters(to other: Fix) -> CLLocationDistance {
            ShareLocationMath.distanceMeters((latitude, longitude), (other.latitude, other.longitude))
        }
    }

    static func shouldSend(_ fix: Fix, last: Fix?, isForeground: Bool) -> Bool {
        guard fix.accuracy >= 0, fix.accuracy <= worstAccuracy, fix.latitude.isFinite, fix.longitude.isFinite else { return false }
        guard let last else { return true }
        let elapsed = fix.at.timeIntervalSince(last.at)
        let moved = fix.meters(to: last)
        if isForeground { return (elapsed >= foregroundGap && moved >= foregroundMeters) || elapsed >= heartbeat }
        return elapsed >= backgroundGap && moved >= backgroundMeters
    }

    /// 기본 기간: 시작일 0시 ~ 종료일 24시(여행지 시간대). 날짜를 못 읽거나 40일을 넘으면 nil(주인이 직접 정한다).
    static func defaultWindow(startDay: String, endDay: String, timeZoneID: String?) -> ShareLocWindow? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        let parser = DateFormatter()
        parser.calendar = calendar
        parser.timeZone = calendar.timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let start = parser.date(from: startDay), let end = parser.date(from: endDay), end >= start,
              let after = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) else { return nil }
        let window = ShareLocWindow(from: millis(calendar.startOfDay(for: start)), until: millis(after))
        return window.until - window.from <= 40 * 86_400_000 ? window : nil
    }

    static func millis(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded()) }

    /// 서버 시각(ms)을 기기 시계 값으로 옮긴 「몇 분 전」의 분.
    static func minutesAgo(receivedAt: Int, serverNow: Int) -> Int { ShareLocationMath.minutesAgo(nowMs: serverNow, receivedAtMs: receivedAt) }

    static func agoText(minutes: Int, _ language: MapHomeLanguage) -> String {
        minutes < 1 ? language.text("방금", "just now") : language.runtimeText("\(minutes)분 전", "\(minutes) min ago")
    }

    /// 지도 표시 농도: 신선 1, 5분 넘으면 흐림, 15분 넘으면 더 흐림.
    static func opacity(_ freshness: ShareLocationFreshness) -> Double {
        switch freshness {
        case .fresh: 1
        case .dim: 0.7
        case .old: 0.45
        case .lost: 0.35
        }
    }
}

/// 여행마다 이 기기에서 정한 위치 공유 상태. 동행에게도 서버에도 올리지 않는다(켜면 위치가 가는 것이 곧 신호).
struct TripLiveLocationConsent: Codable, Equatable {
    var enabled = false
    var hiddenUntil: Date?
    var enabledAt: Date?

    func isSending(at now: Date) -> Bool { enabled && (hiddenUntil.map { $0 <= now } ?? true) }
    func isHidden(at now: Date) -> Bool { enabled && (hiddenUntil.map { $0 > now } ?? false) }
}
