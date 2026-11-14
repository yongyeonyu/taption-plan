import Foundation
import TaptionTripShare

// 묶음 C가 채운다(TSH1114A26). 0단계는 컴파일되는 뼈대와 아래 약속만 둔다.
//
// 0단계가 약속한 것
// - `TripShareStore`가 세션의 변화마다 `roomChanged(model:link:view:event:)`를 부른다. 공지는 `view.items(of: .notice)`.
// - 알림은 **이미 허용한 경우에만** 예약하고 새 권한 창을 띄우지 않는다(`UX/AITaskQueue.swift`의 방식과 같게).
// - 내가 확인했거나(`item.acks[view.me] != nil`) 방이 끝나면(`link.phase == .ended`) 예약한 알림을 지운다.
//   공지를 고치면 확인이 비워지므로 다시 예약한다. 시각이 있는 공지(`ShareNoticeContent.due`)는 그 시각에 맞춘다.
// - 푸시가 없어 닫힌 앱은 공지를 받지 못한다(1차 범위 밖).

/// 공지의 로컬 알림.
@MainActor
enum TripShareNoticeAlerts {
    static func roomChanged(model: AppModel, link: TripShareLink, view: ShareRoomView, event: ShareSessionEvent) async {}
}
