import Foundation
import TaptionPlanStore
import TaptionTripShare

// 방 → 로컬 정본(TSH1114A26 묶음 B).
//
// - `TripShareStore`가 세션의 변화마다 `roomChanged`를 부른다. 내 편집도 서버가 받아 준 뒤 같은 `apply`로 들어온다.
// - 여러 건이 와도 `model.applySharedPlanChanges` **한 번**(저장 한 번)이고, 값이 그대로면 저장하지 않는다.
// - 지우는 것은 방이 「지워졌다」고 알린 항목뿐이다. 연결 직후(`.status(.live)`)는 아직 따라잡기 전이라
//   방 사본이 덜 찼을 수 있으므로, 그때는 가진 것을 넣고 고치기만 하고 로컬 일정을 지우지 않는다.
// - 풀지 못한 항목(키·판이 다름)은 로컬 사본을 그대로 둔다.
// - 장소는 이름뿐이라 핀을 만들지 않는다. 이름은 방 사본에 있고 화면은 `TripSharePlanEditor.placeName`으로 읽는다.

/// 방의 일정·여행 정보를 로컬 정본에 투영한다.
@MainActor
enum TripSharePlanProjector {
    static func roomChanged(model: AppModel, link: TripShareLink, view: ShareRoomView, event: ShareSessionEvent) async {
        guard link.phase != .ended else { return }
        switch event {
        case .items(let changed, let removed):
            await apply(model: model, tripID: link.tripID, view: view, changed: changed, removedRoomIDs: removed)
        case .status(.live):
            await apply(model: model, tripID: link.tripID, view: view, changed: view.items(of: .plan).map(\.id))
        default:
            break
        }
    }

    /// 방 사본의 그 항목들을 로컬에 놓는다.
    /// - Parameters:
    ///   - changed: 넣거나 고칠 방 항목 id(일정이 아닌 것은 건너뛴다).
    ///   - removedRoomIDs: 방에서 지워진 항목 id. 방 사본에 아직 있거나 풀지 못한 것은 지우지 않는다.
    ///   - removedLocalIDs: 방에는 없던 로컬 일정 번호(내 기기에서 지운 것).
    @discardableResult
    static func apply(
        model: AppModel, tripID: String, view: ShareRoomView, changed: [String], removedRoomIDs: [String] = [], removedLocalIDs: [String] = []
    ) async -> Bool {
        let local = model.settings.travelTripItems ?? []
        var plans: [String: SharePlanContent] = [:]
        var present: Set<String> = []
        for item in view.items {
            present.insert(item.id)
            if case .plan(let content) = item.content { plans[item.id] = content }
        }
        let stored = model.settings.travelTrips?.first { $0.id == tripID }
        let trip = view.meta.map { TripShareMapping.trip($0, id: tripID, existing: stored) }
        let zoneID = trip?.timeZoneID ?? stored?.timeZoneID
        let fallback = zoneID.flatMap(TimeZone.init(identifier:))?.secondsFromGMT() ?? 0
        var upserts: [TripShareMapping.PlanDraft] = []
        for id in changed {
            guard let content = plans[id],
                  let draft = TripShareMapping.draft(content, roomItemID: id, tripID: tripID, existing: local, fallbackOffsetSeconds: fallback) else { continue }
            upserts.append(draft)
        }
        let unreadable = Set(view.unreadable.map(\.id))
        let mine = Set(local.filter { $0.tripID == tripID }.map(\.itemID))
        var removed = Set(removedLocalIDs.filter(mine.contains))
        for id in removedRoomIDs where !present.contains(id) && !unreadable.contains(id) {
            let itemID = TripShareMapping.localItemID(roomItemID: id, tripID: tripID, items: local)
            if mine.contains(itemID) { removed.insert(itemID) }
        }
        guard !upserts.isEmpty || !removed.isEmpty || (trip != nil && trip != stored) else { return true }
        return await model.applySharedPlanChanges(tripID: tripID, upserts: upserts, removedItemIDs: removed.sorted(), trip: trip)
    }
}
