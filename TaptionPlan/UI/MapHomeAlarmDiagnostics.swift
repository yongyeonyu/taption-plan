import Foundation
import UserNotifications

/// 하루 카드 알림이 전달·탭됐는지 로그로 볼 수 있게 한다(ARC1030A03).
///
/// 앱이 받을 수 있는 것은 앞에 떠 있을 때의 전달(`willPresent`)과 사용자의 응답(`didReceive`)뿐이다.
/// 배경에서 전달만 되고 누르지 않은 알림은 iOS가 앱에 알리지 않으므로 기록하지 않는다.
enum MapHomeAlarmDiagnostics {
    static let dailyCardTapped = "daily_card_tapped"
    static let dailyCardPresented = "daily_card_presented"

    struct Record: Equatable {
        let event: String
        let fields: [String: String]
        let metrics: [String: Double]
    }

    static func tapped(kind: String?, actionIdentifier: String, deliveredAt: Date, now: Date) -> Record? {
        guard kind == MapHomeAlarmKind.dailyCard.rawValue else { return nil }
        return Record(
            event: dailyCardTapped,
            fields: ["action": action(actionIdentifier)],
            metrics: ["delivered_to_tap_s": max(0, now.timeIntervalSince(deliveredAt)).rounded()]
        )
    }

    static func presented(kind: String?) -> Record? {
        guard kind == MapHomeAlarmKind.dailyCard.rawValue else { return nil }
        return Record(event: dailyCardPresented, fields: ["state": "foreground"], metrics: [:])
    }

    static func action(_ identifier: String) -> String {
        switch identifier {
        case UNNotificationDefaultActionIdentifier: "open"
        case UNNotificationDismissActionIdentifier: "dismiss"
        default: "custom"
        }
    }

    static func log(_ record: Record?) {
        guard let record else { return }
        TaptionPlanDiagnosticsLogger.shared.record(record.event, fields: record.fields, metrics: record.metrics)
    }
}
