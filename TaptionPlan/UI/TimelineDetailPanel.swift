import SwiftUI
import UIKit
import MapKit

enum TimelineDetailSection: String, CaseIterable, Identifiable {
    case schedule = "일정"
    case location = "위치"
    case movement = "이동"
    case sleep = "수면"
    case activity = "활동"
    case appUsage = "어플"
    case weather = "날씨"
    case routine = "루틴"
    case action = "액션·메모"
    case photo = "사진"
    case memo = "메모"
    case event = "이벤트"
    case map = "지도"

    var id: Self { self }

    /// 시간표 줄과 같은 기호를 쓴다. 표를 두 벌 두면 한쪽만 바뀐다.
    var rowKind: TimelineRowKind? {
        switch self {
        case .schedule: .calendar
        case .location: .location
        case .movement: .movement
        case .sleep: .sleep
        case .activity: .activity
        case .appUsage: .appUsage
        case .weather: .weather
        case .photo: .photo
        case .memo: .memo
        case .routine, .action, .event, .map: nil
        }
    }

    var systemImage: String {
        if let rowKind { return rowKind.systemImage }
        switch self {
        case .routine: return "repeat.circle"
        case .action: return "checklist.checked"
        case .event: return "sparkles"
        case .map: return "map"
        default: return "circle"
        }
    }

    static let defaultOrder: [Self] = [
        .schedule,
        .location,
        .movement,
        .sleep,
        .activity,
        .appUsage,
        .weather,
        .photo,
        .memo,
        .map,
        .routine,
        .action,
        .event,
    ]
}

