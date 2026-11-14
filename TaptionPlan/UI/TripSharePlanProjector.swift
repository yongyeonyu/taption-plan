import Foundation
import TaptionTripShare

// 묶음 B가 채운다(TSH1114A26). 0단계는 컴파일되는 뼈대와 아래 약속만 둔다.
//
// 0단계가 약속한 것
// - `TripShareStore`가 세션의 변화(방송·따라잡기·상태)마다 `roomChanged(model:link:view:event:)`를 부른다(잠금 변화 포함).
// - `view`는 그 순간의 불변 값이다. 일정은 `view.items(of: .plan)`, 여행 정보는 `view.meta`.
// - 로컬에는 `model.applySharedPlanChanges(tripID:upserts:removedItemIDs:trip:)` **한 번**으로 넣는다(저장 한 번).
//   평문 → 로컬은 `TripShareMapping.draft(_:roomItemID:tripID:existing:)`, 여행 정보는 `TripShareMapping.trip(_:id:existing:)`.
// - `link.phase == .uploading`인 동안(주인이 기존 일정을 올리는 중)은 방에 없는 로컬 일정을 지우지 않는다.
// - 장소는 이름뿐이라 핀을 만들지 않는다. 이름은 방 사본(`view`)에만 있으니 화면이 필요하면 `SharePlanContent.place`를 읽는다.
//
// B가 할 일: `.items(changed:removed:)`면 그 id들만, 처음 따라잡은 뒤나 `.status(.live)`면 통째로 맞춘다(방이 이긴다).
//   지워진 항목(묘비)은 로컬 일정과 일상 계획을 지운다. 참여자 기기에서는 `meta`로 로컬 여행을 만든다.

/// 방의 일정·여행 정보를 로컬 정본에 투영한다.
@MainActor
enum TripSharePlanProjector {
    static func roomChanged(model: AppModel, link: TripShareLink, view: ShareRoomView, event: ShareSessionEvent) async {}
}
