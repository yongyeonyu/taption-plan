import Foundation
import TaptionTripShare
import UserNotifications

// 공지의 로컬 알림(TSH1114A26 묶음 C).
// - 푸시가 없다: 방이 열려 있을 때(소켓)와 앱을 열 때(따라잡기) 받은 공지만 알린다.
// - 알림은 **이미 허용한 경우에만** 올리고 새 권한 창을 띄우지 않는다. 허용하지 않았으면 여행 머리줄의 공지 띠만 보인다.
// - 내가 확인했거나 공지가 지워졌거나 방이 끝나면 올린 알림을 걷는다. 공지를 고치면(확인이 비워짐) 다시 알린다.
// - 시각이 있는 공지는 그 시각 10분 전에 한 번 더 알린다(아직 확인 전일 때만 남는다).

/// 공지의 로컬 알림.
@MainActor
enum TripShareNoticeAlerts {
    /// 올릴 알림 하나. `fireAt`이 nil이면 바로.
    struct Alert: Equatable, Sendable {
        var identifier: String
        var text: String
        var important: Bool
        var fireAt: Date?
    }

    struct Plan: Equatable, Sendable {
        var post: [Alert] = []
        var cancel: [String] = []
        /// 알린 공지(항목 id → 그때의 개정 번호).
        var seen: [String: Int] = [:]
    }

    /// 알림을 실제로 올리고 걷는 곳. 시험이 바꿔 넣는다.
    struct Center: Sendable {
        var isAllowed: @Sendable () async -> Bool
        var add: @Sendable (Alert, _ title: String, _ body: String) async -> Void
        var remove: @Sendable ([String]) -> Void

        static let system = Center(
            isAllowed: {
                let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                return status == .authorized || status == .provisional
            },
            add: { alert, title, body in
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let trigger = alert.fireAt.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0.timeIntervalSinceNow), repeats: false) }
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.identifier, content: content, trigger: trigger))
            },
            remove: { identifiers in
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        )
    }

    static var center = Center.system
    static var defaults = UserDefaults.standard
    static let seenKey = "tripShareNoticeSeen"
    static let dueLead: TimeInterval = 600

    static func identifier(_ noticeID: String) -> String { "trip-share-notice-" + noticeID }
    static func dueIdentifier(_ noticeID: String) -> String { identifier(noticeID) + "-due" }

    /// 내가 확인해야 하는 공지: 남이 쓴 것 가운데 아직 확인하지 않은 것. 중요한 것, 새것부터.
    static func pending(in view: ShareRoomView) -> [(item: ShareLocalItem, notice: ShareNoticeContent)] {
        view.items(of: .notice).compactMap { item -> (item: ShareLocalItem, notice: ShareNoticeContent)? in
            guard item.createdBy != view.me, item.acks[view.me] == nil, case .notice(let notice) = item.content else { return nil }
            return (item, notice)
        }
        .sorted { ($0.notice.important ? 1 : 0, $0.notice.createdAt, $0.item.id) > ($1.notice.important ? 1 : 0, $1.notice.createdAt, $1.item.id) }
    }

    /// 방의 지금 상태에서 올릴 알림과 걷을 알림. 순수 계산이다.
    static func plan(view: ShareRoomView, ended: Bool, seen: [String: Int], now: Date) -> Plan {
        var plan = Plan()
        let waiting = ended ? [] : pending(in: view)
        for (item, notice) in waiting {
            plan.seen[item.id] = item.rev
            guard seen[item.id] != item.rev else { continue }
            plan.post.append(Alert(identifier: identifier(item.id), text: notice.text, important: notice.important, fireAt: nil))
            guard let due = notice.due.map({ Date(timeIntervalSince1970: TimeInterval($0) / 1000) }), due > now else { continue }
            plan.post.append(Alert(identifier: dueIdentifier(item.id), text: notice.text, important: notice.important, fireAt: max(now.addingTimeInterval(1), due.addingTimeInterval(-dueLead))))
        }
        plan.cancel = seen.keys.filter { plan.seen[$0] == nil }.sorted().flatMap { [identifier($0), dueIdentifier($0)] }
        return plan
    }

    /// 알림의 제목과 본문. 잠금 중이면 본문은 앱에서 보라는 말뿐이다.
    static func content(_ alert: Alert, language: MapHomeLanguage, locked: Bool) -> (title: String, body: String) {
        let title = alert.important ? language.text("중요한 여행 공지", "Important trip notice") : language.text("여행 공지", "Trip notice")
        return (title, locked ? language.text("앱에서 확인해 주세요.", "Open the app to see it.") : alert.text)
    }

    static func roomChanged(model: AppModel, link: TripShareLink, view: ShareRoomView, event: ShareSessionEvent) async {
        switch event {
        case .items, .status: break
        default: return
        }
        var all = (defaults.dictionary(forKey: seenKey) as? [String: [String: Int]]) ?? [:]
        let plan = Self.plan(view: view, ended: link.phase == .ended, seen: all[link.roomID] ?? [:], now: .now)
        guard plan.seen != all[link.roomID] ?? [:] || !plan.post.isEmpty else { return }
        all[link.roomID] = plan.seen.isEmpty ? nil : plan.seen
        defaults.set(all, forKey: seenKey)
        if !plan.cancel.isEmpty { center.remove(plan.cancel) }
        guard !plan.post.isEmpty, await center.isAllowed() else { return }
        let language = MapHomeLanguage.current, locked = TaptionExternalPrivacyStore.isLocked
        for alert in plan.post {
            let text = content(alert, language: language, locked: locked)
            await center.add(alert, text.title, text.body)
        }
    }
}
