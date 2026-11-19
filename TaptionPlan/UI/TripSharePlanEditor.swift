import SwiftUI
import TaptionPlanStore
import TaptionTripShare

// 공유 여행의 계획 편집(TSH1114A26 묶음 B).
//
// - `route`는 문지기다: 공유하지 않는 여행은 그대로 통과, 공유 여행은 「보기만」·남의 잠금·되돌리기·주인만을 여기서 막는다.
//   있는 일정의 편집기는 그 칸의 잠금을 잡은 뒤에 열고(`.open`), 편집기가 닫히면 푼다(`endEditing`).
// - 실제로 바꾸는 일은 `addItem`·`updateItem`·`moveItem`·`resizeItem`·`deleteItem`·`applyStep`·`saveTrip`이 한다.
//   공유하지 않는 여행이면 앱 모델의 같은 함수를 그대로 부르고, 공유 여행이면
//   잠금 → 방에 쓰기 → (받아 주면) 로컬 정본에 투영 → 풀기 순서다. **서버가 받아 주기 전에는 로컬을 바꾸지 않는다**:
//   거절·충돌이면 로컬은 그대로이고(충돌이면 방의 최신본으로 바뀜) 안내 글만 남는다.
// - 장소는 이름만 올린다. 좌표(핀)는 고친 기기에만 남는다.

/// 공유 여행의 계획 편집에서 보이는 글.
enum TripSharePlanText {
    static func lockedBy(_ name: String, _ language: MapHomeLanguage) -> String {
        name.isEmpty
            ? language.text("다른 사람이 고치는 중이에요. 잠시 뒤에 다시 해 주세요.", "Someone else is editing this. Try again in a moment.")
            : language.runtimeText("\(name) 님이 고치는 중이에요. 잠시 뒤에 다시 해 주세요.", "\(name) is editing this. Try again in a moment.")
    }

    static func editing(_ name: String, _ language: MapHomeLanguage) -> String {
        name.isEmpty ? language.text("고치는 중", "Editing") : language.runtimeText("\(name) 고치는 중", "\(name) editing")
    }

    static func conflict(_ language: MapHomeLanguage) -> String {
        language.text("다른 사람이 먼저 고쳤어요. 최신 내용으로 바꿨으니 확인하고 다시 고쳐 주세요.", "Someone else changed this first. It now shows the latest version, so check it and edit again.")
    }

    static func lockLost(_ language: MapHomeLanguage) -> String {
        language.text("편집 시간이 지나 잠금이 풀렸어요. 다시 열어서 고쳐 주세요.", "Your edit lock expired. Open it again to edit.")
    }

    static func tooBig(_ language: MapHomeLanguage) -> String {
        language.text("일정이 너무 많거나 길어서 올리지 못했어요.", "Couldn't upload: too many plans or too much text.")
    }

    static func failed(_ language: MapHomeLanguage) -> String {
        language.text("함께 쓰는 여행에 올리지 못했어요. 잠시 뒤에 다시 해 주세요.", "Couldn't update the shared trip. Try again in a moment.")
    }

    static func ownerOnly(_ language: MapHomeLanguage) -> String {
        language.text("여행 이름·나라·열 구성은 공유를 만든 사람만 고칠 수 있어요.", "Only the person who started sharing can change the trip's name, country, and columns.")
    }

    static func datesBlocked(_ language: MapHomeLanguage) -> String {
        language.text("함께 쓰는 여행은 날짜를 통째로 옮길 수 없어요. 일정을 하나씩 옮겨 주세요.", "A shared trip's dates can't be moved all at once. Move its plans one by one.")
    }
}

/// 공유 여행의 편집을 받는 곳.
@MainActor
enum TripSharePlanEditor {
    private static var store: TripShareStore { .shared }

    // MARK: 문지기

    static func route(model: AppModel, tripID: String, edit: TripSharePlanEdit, local: @escaping () -> Void) {
        guard model.isSharedTrip(tripID) else { return local() }
        if edit == .history { return store.notice = TripShareText.undoBlocked(.current) }
        guard store.canEdit(tripID) else { return store.notice = TripShareText.viewOnly(.current) }
        switch edit {
        case .add, .addStop, .reorder, .history:
            local()
        case .tripInfo:
            guard store.view(tripID: tripID)?.isOwner == true else { return store.notice = TripSharePlanText.ownerOnly(.current) }
            local()
        case .move(let itemID, _), .resize(let itemID, _), .delete(let itemID), .status(let itemID):
            guard !rejectsLocked(tripID: tripID, itemID: itemID) else { return }
            local()
        case .open(let itemID):
            guard !rejectsLocked(tripID: tripID, itemID: itemID) else { return }
            Task { if await beginEditing(tripID: tripID, itemID: itemID) { local() } }
        }
    }

    /// 남이 잡은 칸이면 누가 고치는 중인지 알리고 true.
    private static func rejectsLocked(tripID: String, itemID: String) -> Bool {
        guard case .other(let by, _) = store.lockState(tripID: tripID, itemID: itemID) else { return false }
        store.notice = TripSharePlanText.lockedBy(memberName(tripID: tripID, member: by), .current)
        return true
    }

    private static func memberName(tripID: String, member: Int) -> String {
        store.names(tripID: tripID)?.name(.member(member)) ?? ""
    }

    // MARK: 칸 잠금(편집기가 열려 있는 동안)

    /// 편집기를 열기 전에 그 칸을 잡는다. 임대는 2분이고 잡고 있는 동안 세션이 60초마다 연장한다.
    static func beginEditing(tripID: String, itemID: String) async -> Bool {
        guard let session = store.session(tripID: tripID) else {
            store.notice = TripShareText.viewOnly(.current)
            return false
        }
        do {
            try await session.lock(items: [TripShareMapping.roomItemID(tripID: tripID, itemID: itemID)])
            await store.refresh(tripID: tripID)
            return true
        } catch {
            await store.refresh(tripID: tripID)
            store.notice = message(for: error, tripID: tripID)
            return false
        }
    }

    /// 편집기가 닫혔다: 잡아 둔 칸을 푼다. 공유하지 않는 여행·새 일정이면 아무것도 하지 않는다.
    static func endEditing(_ item: TravelTripItem?) {
        guard let item, let session = store.session(tripID: item.tripID) else { return }
        let roomID = TripShareMapping.roomItemID(tripID: item.tripID, itemID: item.itemID)
        Task {
            try? await session.unlock(items: [roomID])
            await store.refresh(tripID: item.tripID)
        }
    }

    /// 방에 적힌 그 일정의 장소 이름(핀 없이 이름만 온 것). 공유하지 않는 여행이면 nil.
    static func placeName(tripID: String, itemID: String) -> String? {
        guard let view = store.view(tripID: tripID) else { return nil }
        let roomID = TripShareMapping.roomItemID(tripID: tripID, itemID: itemID)
        guard case .plan(let content)? = view.items.first(where: { $0.id == roomID })?.content else { return nil }
        return content.place
    }

    // MARK: 화면이 부르는 편집(공유하지 않는 여행이면 앱 모델 그대로)

    static func addItem(
        model: AppModel, tripID: String, kind: TripImportItem.Kind, title: String, start: Date, end: Date, offsetSeconds: Int, endOffsetSeconds: Int? = nil,
        place: TravelItemPlace? = nil, note: String = "", colorHex: String? = nil, plannedSpendKRW: Double? = nil, parentItemID: String? = nil,
        flight: TravelFlightFields? = nil
    ) async -> String? {
        guard model.isSharedTrip(tripID) else {
            return await model.addTripItem(
                tripID: tripID, kind: kind, title: title, start: start, end: end, offsetSeconds: offsetSeconds, endOffsetSeconds: endOffsetSeconds, place: place, note: note,
                colorHex: colorHex, plannedSpendKRW: plannedSpendKRW, parentItemID: parentItemID, flight: flight
            )
        }
        guard end > start else { return nil }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 방에서 처음 만드는 일정은 방 항목 id가 곧 로컬 번호다.
        var item = TravelTripItem(
            tripID: tripID, itemID: ShareIdentifiers.itemID(), kind: kind.rawValue, title: name.isEmpty ? kind.planName : name, start: start, end: end,
            startOffsetSeconds: offsetSeconds, endOffsetSeconds: endOffsetSeconds ?? offsetSeconds, planID: nil, note: AppModel.cleanTripNote(note),
            colorHex: TravelTripItem.cleanColorHex(colorHex), plannedSpendKRW: TravelTripItem.cleanPlannedSpend(plannedSpendKRW), parentItemID: parentItemID
        )
        if let flight { item.apply(flight) }
        guard await commit(model: model, tripID: tripID, upserts: [item], places: [item.itemID: place?.name]) else { return nil }
        if let place { await pin(model: model, item: item, kind: kind, place: place) }
        return item.itemID
    }

    static func updateItem(
        model: AppModel, tripID: String, itemID: String, kind: TripImportItem.Kind, title: String, start: Date, end: Date,
        place: TravelItemPlace? = nil, replacesPlace: Bool = false, note: String? = nil, style: (colorHex: String?, plannedSpendKRW: Double?)? = nil
    ) async -> Bool {
        guard model.isSharedTrip(tripID) else {
            return await model.updateTripItem(
                tripID: tripID, itemID: itemID, kind: kind, title: title, start: start, end: end, place: place, replacesPlace: replacesPlace, note: note, style: style
            )
        }
        guard end > start, var item = localItem(model, tripID, itemID), !isFixed(model, item) else { return false }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.kind = kind.rawValue
        item.title = name.isEmpty ? kind.planName : name
        item.start = start
        item.end = end
        if let note { item.note = AppModel.cleanTripNote(note) }
        if let style {
            item.colorHex = TravelTripItem.cleanColorHex(style.colorHex)
            item.plannedSpendKRW = TravelTripItem.cleanPlannedSpend(style.plannedSpendKRW)
        }
        guard await commit(model: model, tripID: tripID, upserts: [item], places: replacesPlace ? [itemID: place?.name] : [:]) else { return false }
        if replacesPlace { await pin(model: model, item: item, kind: kind, place: place) }
        return true
    }

    static func moveItem(model: AppModel, tripID: String, itemID: String, by delta: TimeInterval) async -> Bool {
        guard model.isSharedTrip(tripID) else { return await model.moveTripItem(tripID: tripID, itemID: itemID, by: delta) }
        guard let moved = moved(model, tripID: tripID, moves: [itemID: delta]) else { return false }
        return await commit(model: model, tripID: tripID, upserts: moved)
    }

    static func resizeItem(model: AppModel, tripID: String, itemID: String, endDelta: TimeInterval) async -> Bool {
        guard model.isSharedTrip(tripID) else { return await model.resizeTripItem(tripID: tripID, itemID: itemID, endDelta: endDelta) }
        guard let old = localItem(model, tripID, itemID), !isFixed(model, old),
              let item = TravelTripItemEditor.resized([old], tripID: tripID, itemID: itemID, endDelta: endDelta)?.first else { return false }
        return await commit(model: model, tripID: tripID, upserts: [item])
    }

    /// 지난 일정의 갔음·건너뜀을 상태 칸에 적는다(nil이면 되돌린다, TVZ1116C01).
    @discardableResult
    static func setVisitMark(model: AppModel, tripID: String, itemID: String, mark: TravelVisitMark?) async -> Bool {
        guard model.isSharedTrip(tripID) else {
            await model.setTripVisitMark(mark, tripID: tripID, itemID: itemID)
            return true
        }
        guard var item = localItem(model, tripID, itemID) else { return false }
        let next = TravelVisitMark.stored(mark, over: item.status)
        guard next != item.status else { return true }
        item.status = next
        return await commit(model: model, tripID: tripID, upserts: [item])
    }

    /// 일정을 지운다(코스 곳이면 딸린 세부 계획도 함께, 방에는 한 번에). 지웠으면 그 걸음을 돌려준다.
    static func deleteItem(model: AppModel, tripID: String, itemID: String) async -> TravelPlanHistory.Step? {
        guard model.isSharedTrip(tripID) else { return await model.deleteTripItemWithDetails(tripID: tripID, itemID: itemID) }
        let items = model.settings.travelTripItems ?? []
        guard let item = items.first(where: { $0.tripID == tripID && $0.itemID == itemID }) else { return nil }
        let targets = TravelTripItem.details(of: itemID, tripID: tripID, in: items) + [item]
        let steps = targets.map { TravelPlanHistory.Step.existence($0, place: TravelPlanHistory.place(of: $0, stops: model.settings.travelPlanStops), exists: false) }
        guard await commit(model: model, tripID: tripID, removed: targets.map(\.itemID)), let last = steps.last else { return nil }
        return steps.count == 1 ? last : TravelPlanHistory.Step(tripID: tripID, itemID: "", move: 0, resize: 0, summary: last.summary, group: steps)
    }

    /// 코스 순서 바꾸기처럼 여러 일정이 함께 옮겨지는 걸음. 공유 여행이면 그날 묶음을 잠그고 **한 번에** 쓴다(전부 되거나 전부 안 됨).
    @discardableResult
    static func applyStep(model: AppModel, _ step: TravelPlanHistory.Step) async -> Bool {
        guard model.isSharedTrip(step.tripID) else {
            await model.applyTravelHistory(step)
            return true
        }
        let parts = step.group.isEmpty ? [step] : step.group
        guard parts.allSatisfy({ $0.group.isEmpty && $0.exists == nil && $0.resize == 0 }) else { return false }
        var moves: [String: TimeInterval] = [:]
        for part in parts where part.move != 0 { moves[part.itemID, default: 0] += TimeInterval(part.move * 60) }
        guard !moves.isEmpty, let moved = moved(model, tripID: step.tripID, moves: moves) else { return false }
        let before = (model.settings.travelTripItems ?? []).filter { item in item.tripID == step.tripID && moved.contains { $0.itemID == item.itemID } }
        return await commit(model: model, tripID: step.tripID, upserts: moved, lockDays: Set((before + moved).map(day)).sorted())
    }

    /// 여행 정보(이름·나라·열)를 고친다. 공유 여행이면 날짜는 그대로 두고, 방의 여행 정보는 주인만 쓴다. 저장한 여행을 돌려준다.
    static func saveTrip(model: AppModel, trip: TravelTrip) async -> TravelTrip? {
        guard model.isSharedTrip(trip.id), let old = model.settings.travelTrips?.first(where: { $0.id == trip.id }) else {
            return await model.saveTravelTrip(trip) ? trip : nil
        }
        var next = trip
        let movesDates = next.startDay != old.startDay || next.endDay != old.endDay || next.wishDays != old.wishDays
        (next.startDay, next.endDay, next.wishDays) = (old.startDay, old.endDay, old.wishDays)
        let view = store.view(tripID: trip.id), shared = view?.meta
        func meta(_ trip: TravelTrip) -> ShareTripMeta {
            TripShareMapping.meta(
                trip, budget: shared?.budget, guests: shared?.guests ?? [], settlementOff: shared?.settlementOff, shareAllExpenses: shared?.shareAllExpenses
            )
        }
        // 깃발 색·자리처럼 이 기기에만 있는 값이면 방에 쓰지 않는다.
        if meta(next) != meta(old) {
            guard store.canEdit(trip.id), let session = store.session(tripID: trip.id) else {
                store.notice = TripShareText.viewOnly(.current)
                return nil
            }
            guard view?.isOwner == true else {
                store.notice = TripSharePlanText.ownerOnly(.current)
                return nil
            }
            do {
                guard case .done = try await session.publish(meta: meta(next)) else {
                    store.notice = TripSharePlanText.conflict(.current)
                    return nil
                }
            } catch {
                store.notice = message(for: error, tripID: trip.id)
                return nil
            }
            await store.refresh(tripID: trip.id)
        }
        guard await model.saveTravelTrip(next) else { return nil }
        if movesDates { store.notice = TripSharePlanText.datesBlocked(.current) }
        return next
    }

    // MARK: 방에 쓰기

    private static func localItem(_ model: AppModel, _ tripID: String, _ itemID: String) -> TravelTripItem? {
        (model.settings.travelTripItems ?? []).first { $0.tripID == tripID && $0.itemID == itemID }
    }

    /// 캘린더 고정 일정에 묶인 것은 로컬 편집과 같이 고치지 않는다.
    private static func isFixed(_ model: AppModel, _ item: TravelTripItem) -> Bool {
        item.planID.flatMap { id in model.snapshot.plans.first { $0.id == id } }?.isFixed ?? false
    }

    private static func day(_ item: TravelTripItem) -> String { TravelTripDay.string(for: item.start, offsetSeconds: item.startOffsetSeconds) }

    /// 옮긴 뒤의 일정들. 코스 곳을 옮기면 딸린 세부 계획도 같은 만큼 옮긴다. 없는 일정·고정 일정이 끼면 nil.
    private static func moved(_ model: AppModel, tripID: String, moves: [String: TimeInterval]) -> [TravelTripItem]? {
        let items = (model.settings.travelTripItems ?? []).filter { $0.tripID == tripID }
        var deltas: [String: TimeInterval] = [:]
        func add(_ itemID: String, _ delta: TimeInterval, depth: Int) {
            deltas[itemID, default: 0] += delta
            guard depth < 4 else { return }
            for detail in TravelTripItem.details(of: itemID, tripID: tripID, in: items) { add(detail.itemID, delta, depth: depth + 1) }
        }
        for (itemID, delta) in moves { add(itemID, delta, depth: 0) }
        var out: [TravelTripItem] = []
        for (itemID, delta) in deltas.sorted(by: { $0.key < $1.key }) where delta != 0 {
            guard var item = items.first(where: { $0.itemID == itemID }), delta.isFinite else { return nil }
            // 딸린 세부가 고정 일정이면 로컬 편집처럼 그것만 그 자리에 둔다.
            if isFixed(model, item) {
                if moves[itemID] != nil { return nil }
                continue
            }
            item.start = item.start.addingTimeInterval(delta)
            item.end = item.end.addingTimeInterval(delta)
            out.append(item)
        }
        return out.isEmpty ? nil : out
    }

    /// 이 기기에서 고른 장소의 핀을 놓는다(없애기 포함). 좌표는 이 기기에만 남는다.
    private static func pin(model: AppModel, item: TravelTripItem, kind: TripImportItem.Kind, place: TravelItemPlace?) async {
        await model.updateTripItem(
            tripID: item.tripID, itemID: item.itemID, kind: kind, title: item.title, start: item.start, end: item.end, place: place, replacesPlace: true
        )
    }

    /// 바뀐 뒤의 일정들과 지울 번호들을 방에 한 번에 쓰고, 받아 주면 로컬에 한 번에 반영한다.
    /// - Parameters:
    ///   - places: 장소 이름을 바꿀 일정(값이 nil이면 장소를 뗀다). 없는 일정은 방에 적힌 이름을 지킨다.
    ///   - lockDays: 함께 잠글 날(순서 바꾸기). 그날 묶음을 남이 고치는 중이면 아무것도 쓰지 않는다.
    private static func commit(
        model: AppModel, tripID: String, upserts: [TravelTripItem] = [], places: [String: String?] = [:], removed: [String] = [], lockDays: [String] = []
    ) async -> Bool {
        guard store.canEdit(tripID), let session = store.session(tripID: tripID) else {
            store.notice = TripShareText.viewOnly(.current)
            return false
        }
        let view = await session.view()
        var inRoom: [String: SharePlanContent] = [:]
        for item in view.items { if case .plan(let content) = item.content { inRoom[item.id] = content } }
        var edits: [ShareEdit] = [], guarded: [String] = []
        for item in upserts {
            let id = TripShareMapping.roomItemID(tripID: tripID, itemID: item.itemID)
            let group = store.groupName(tripID: tripID, day: day(item))
            let old = inRoom[id]
            let place = places[item.itemID] ?? old?.place
            let content = ShareContent.plan(TripShareMapping.plan(item, place: place, order: old?.order, by: view.me))
            if old == nil {
                edits.append(.create(id: id, content: content, group: group))
            } else {
                edits.append(.update(id: id, content: content, group: group.map(ShareGroupChange.set) ?? .keep))
                guarded.append(id)
            }
        }
        var removedRoomIDs: [String] = []
        for itemID in removed {
            let id = TripShareMapping.roomItemID(tripID: tripID, itemID: itemID)
            guard inRoom[id] != nil else { continue }
            edits.append(.delete(id: id))
            guarded.append(id)
            removedRoomIDs.append(id)
        }
        // 편집기가 이미 잡아 둔 칸은 다시 잡지 않고, 여기서 잡은 것만 끝나고 푼다.
        var locks: [String] = []
        for id in guarded {
            switch await session.lockState(item: id) {
            case .mine: continue
            case .other(let by, _):
                await store.refresh(tripID: tripID)
                store.notice = TripSharePlanText.lockedBy(memberName(tripID: tripID, member: by), .current)
                return false
            case .free: locks.append(id)
            }
        }
        var groups = lockDays.compactMap { store.groupName(tripID: tripID, day: $0) }
        // 한 사람 잠금 한도를 넘으면 그 일정들의 날 묶음 잠금으로 바꾼다(세부 계획이 20개 넘는 곳, TSA1117A01).
        if locks.count + groups.count > view.limits.locksPerMember {
            guard let fallback = Self.dayLocks(items: locks, groups: groups, view: view) else {
                store.notice = TripSharePlanText.tooBig(.current)
                return false
            }
            (locks, groups) = fallback
        }
        var done = false
        do {
            if !locks.isEmpty || !groups.isEmpty { try await session.lock(items: locks, groups: groups) }
            switch try await session.write(edits) {
            case .done:
                let fresh = await session.view()
                done = await TripSharePlanProjector.apply(
                    model: model, tripID: tripID, view: fresh, changed: edits.map(\.id), removedRoomIDs: removedRoomIDs, removedLocalIDs: removed
                )
            case .conflict(let conflicts):
                // 잡기 전에 남이 고쳤다. 방의 최신본을 로컬에 놓고 다시 고치게 한다.
                let fresh = await session.view()
                await TripSharePlanProjector.apply(model: model, tripID: tripID, view: fresh, changed: conflicts.map(\.id), removedRoomIDs: conflicts.map(\.id))
                store.notice = TripSharePlanText.conflict(.current)
            }
        } catch {
            store.notice = message(for: error, tripID: tripID)
        }
        if !locks.isEmpty || !groups.isEmpty { try? await session.unlock(items: locks, groups: groups) }
        await store.refresh(tripID: tripID)
        return done
    }

    /// 항목 잠금을 그 항목의 날 묶음 잠금으로 바꾼다. 묶음이 없는 항목만 항목 잠금으로 남는다. 그래도 한도를 넘으면 nil.
    static func dayLocks(items: [String], groups: [String], view: ShareRoomView) -> (items: [String], groups: [String])? {
        let groupOf = Dictionary(view.items.map { ($0.id, $0.group) }, uniquingKeysWith: { first, _ in first })
        var days = Set(groups), single: [String] = []
        for id in items {
            if let group = groupOf[id] ?? nil { days.insert(group) } else { single.append(id) }
        }
        guard single.count + days.count <= view.limits.locksPerMember else { return nil }
        return (single, days.sorted())
    }

    /// 거절한 까닭을 사람 말로.
    private static func message(for error: any Error, tripID: String) -> String {
        guard let error = error as? ShareError else { return TripSharePlanText.failed(.current) }
        switch error {
        case .offline, .transport, .interrupted, .readOnly(.offline), .readOnly(.notStarted), .readOnly(.replaced), .readOnly(.needsRekey), .readOnly(.ended):
            return TripShareText.viewOnly(.current)
        case .itemTooLarge:
            return TripSharePlanText.tooBig(.current)
        case .server(let failure):
            switch failure.code {
            case .locked: return TripSharePlanText.lockedBy((failure.detail.locks?.first).map { memberName(tripID: tripID, member: $0.by) } ?? "", .current)
            case .lockRequired: return TripSharePlanText.lockLost(.current)
            case .conflict: return TripSharePlanText.conflict(.current)
            case .roomFull, .tooLarge, .itemTooLarge, .tooManyLocks: return TripSharePlanText.tooBig(.current)
            case .forbidden, .ownerOnly: return TripSharePlanText.ownerOnly(.current)
            default: return TripSharePlanText.failed(.current)
            }
        default:
            return TripSharePlanText.failed(.current)
        }
    }
}

/// 일정 편집기에 붙인다: 닫히면 잡아 둔 칸을 풀고, 시트 위에서도 공유 안내 글이 보이게 한다.
private struct TripSharePlanEditing: ViewModifier {
    let item: TravelTripItem?
    let language: MapHomeLanguage

    func body(content: Content) -> some View {
        let store = TripShareStore.shared
        content
            .onDisappear { TripSharePlanEditor.endEditing(item) }
            .alert(store.notice ?? "", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
                Button(language.text("확인", "OK")) { store.notice = nil }
            }
    }
}

extension View {
    func tripSharePlanEditing(_ item: TravelTripItem?, language: MapHomeLanguage) -> some View {
        modifier(TripSharePlanEditing(item: item, language: language))
    }
}
