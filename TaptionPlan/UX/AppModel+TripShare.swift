import Foundation
import SwiftUI
import TaptionPlanCore
import TaptionPlanStore
import TaptionTripShare

/// 여행 화면이 공유 편집기에 넘기는 편집 한 건(TSH1114A26). 공유하지 않는 여행이면 편집기는 그대로 통과시킨다.
enum TripSharePlanEdit: Equatable, Sendable {
    /// 새 일정 편집기를 연다(`parentItemID`가 있으면 그 코스 곳의 세부 계획).
    case add(dayKey: String, parentItemID: String?)
    /// 코스에 곳을 바로 붙인다(편집기 없이).
    case addStop(dayKey: String)
    /// 있는 일정의 편집기를 연다. 잠금을 잡을 자리다.
    case open(itemID: String)
    case move(itemID: String, minutes: Int)
    case resize(itemID: String, minutes: Int)
    case delete(itemID: String)
    /// 그날 코스의 순서 바꾸기(날 묶음 잠금).
    case reorder(dayKey: String)
    /// 계획표 되돌리기·다시 하기. 공유 여행에서는 막는다(대표 결정).
    case history
    /// 여행 이름·기간·나라 고치기(`meta`는 주인만 쓴다).
    case tripInfo
}

/// 공유 여행에서 막은 일을 알리는 글.
enum TripShareText {
    static func editBlocked(_ language: MapHomeLanguage) -> String {
        language.text(
            "함께 쓰는 여행이라 이 방법으로는 바꿀 수 없어요. 여행 화면에서 일정을 하나씩 고쳐 주세요.",
            "This trip is shared, so it can't be changed this way. Edit its plans one by one on the trip screen."
        )
    }

    static func undoBlocked(_ language: MapHomeLanguage) -> String {
        language.text("함께 쓰는 여행에서는 되돌리기를 쓸 수 없어요.", "Undo isn't available in a shared trip.")
    }

    static func viewOnly(_ language: MapHomeLanguage) -> String {
        language.text("지금은 보기만 할 수 있어요. 인터넷에 연결되면 다시 고칠 수 있어요.", "View only for now. You can edit again once you're back online.")
    }
}

extension AppModel {
    /// 지금 함께 쓰는 여행인가(TSH1114A26). 공유 편집기를 거치지 않는 편집 경로는 이것으로 거절한다.
    func isSharedTrip(_ tripID: String) -> Bool { TripShareStore.shared.isShared(tripID) }

    /// 공유 여행이면 안내 글을 남기고 true. 다시 가져오기·날짜 통째 옮기기·상태 바꾸기가 쓴다.
    func rejectsSharedTripEdit(_ tripID: String) -> Bool {
        guard isSharedTrip(tripID) else { return false }
        userFacingError = TripShareText.editBlocked(.current)
        return true
    }

    /// 방에서 받은 일정 변화를 로컬 정본에 **한 번에** 투영한다: 여러 건을 고치고 저장은 한 번.
    /// 서버가 받아 준 내 편집과 남의 변경이 모두 이 길로 들어온다. 값이 그대로면 저장하지 않는다.
    /// - Parameters:
    ///   - upserts: 넣거나 고칠 일정(`TripShareMapping.draft`가 만든 것). 장소는 이름뿐이라 핀을 새로 만들지 않는다.
    ///   - removedItemIDs: 지울 **로컬** 일정 번호. 딸린 일상 계획과 핀도 함께 지운다.
    ///   - trip: 여행 정보(`meta`)가 바뀌었으면 그 값.
    @discardableResult
    func applySharedPlanChanges(
        tripID: String, upserts: [TripShareMapping.PlanDraft] = [], removedItemIDs: [String] = [], trip: TravelTrip? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) async -> Bool {
        guard acceptsDataMutation(), !tripID.isEmpty else { return false }
        var items = snapshot.settings.travelTripItems ?? []
        var stops = snapshot.settings.travelPlanStops
        var plans = snapshot.plans
        var trips = snapshot.settings.travelTrips ?? []
        let removed = Set(removedItemIDs)
        let gone = Set(items.filter { $0.tripID == tripID && removed.contains($0.itemID) }.compactMap(\.planID))
        items.removeAll { $0.tripID == tripID && removed.contains($0.itemID) }
        stops.removeAll { $0.tripID == tripID && $0.itemID.map(removed.contains) == true }
        for draft in upserts where draft.item.tripID == tripID && !removed.contains(draft.item.itemID) && draft.item.end > draft.item.start {
            var item = draft.item
            let kind = TripImportItem.Kind(rawValue: item.kind) ?? .other
            if let index = items.firstIndex(where: { $0.tripID == tripID && $0.itemID == item.itemID }) {
                item.planID = items[index].planID
                guard items[index] != item else { continue }
                // 캘린더 고정 일정에 묶인 계획 기록은 그대로 두고 여행 일정만 방을 따른다.
                if let planID = item.planID, let planIndex = plans.firstIndex(where: { $0.id == planID }), !plans[planIndex].isFixed {
                    plans[planIndex].title = item.title
                    plans[planIndex].categoryID = kind.categoryID
                    plans[planIndex].middleCategoryName = kind.planName
                    plans[planIndex].span = TimeSpan(start: item.start, end: item.end)
                    plans[planIndex].updatedAt = .now
                }
                items[index] = item
            } else {
                let plan = PlanRecord(
                    title: item.title, span: TimeSpan(start: item.start, end: item.end), categoryID: kind.categoryID, middleCategoryName: kind.planName
                )
                plans.append(plan)
                item.planID = plan.id
                items.append(item)
            }
            // 핀의 좌표는 이 기기에만 있다. 이름·상태·날짜만 일정을 따라간다.
            guard let stopIndex = stops.firstIndex(where: { $0.tripID == tripID && $0.itemID == item.itemID }) else { continue }
            stops[stopIndex].title = item.title
            stops[stopIndex].status = item.status
            let wall = TravelTripDay.components(TravelTripDay.string(for: item.start, offsetSeconds: item.startOffsetSeconds))
            if let day = wall.flatMap(calendar.date(from:)).map(calendar.startOfDay(for:)),
               !TravelPlanSchedule.isSameDay(stored: stops[stopIndex].day, local: day, calendar: calendar) {
                stops[stopIndex].day = day
                stops[stopIndex].order = Int.max
            }
        }
        if let trip, trip.id == tripID {
            if let index = trips.firstIndex(where: { $0.id == tripID }) { trips[index] = trip } else { trips.append(trip) }
        }
        trips = TravelTripDirectory.extended(trips, toCover: items)
        stops = TravelPlanSchedule.renumbered(stops)
        plans.sort { $0.span.start < $1.span.start }
        let newItems = items.isEmpty ? nil : items, newTrips = trips.isEmpty ? nil : trips
        let livePlans = gone.filter { id in plans.contains { $0.id == id } }
        guard newItems != snapshot.settings.travelTripItems || newTrips != snapshot.settings.travelTrips
            || stops != snapshot.settings.travelPlanStops || plans != snapshot.plans || !livePlans.isEmpty else { return true }
        snapshot.plans = plans
        snapshot.settings.travelTripItems = newItems
        snapshot.settings.travelPlanStops = stops
        snapshot.settings.travelTrips = newTrips
        guard !livePlans.isEmpty else { return await persist() }
        // 지운 일정의 계획 기록은 기존 지우기가 딸린 메모·실제 기록 연결까지 정리하고, 위에서 고친 것과 함께 한 번 저장한다.
        await deletePlans(Array(livePlans))
        return !snapshot.plans.contains { livePlans.contains($0.id) }
    }
}

extension View {
    /// 여행 화면에 공유를 붙인다(TSH1114A26): 앱 모델을 창구에 잇고, 시트·상태 알림은 `TripShareHost`가 맡는다.
    func tripShare(model: AppModel, language: MapHomeLanguage, openedID: String?, route: Binding<TripShareRoute?>) -> some View {
        modifier(TripShareHost(model: model, language: language, openedID: openedID, route: route))
            .task { TripShareStore.shared.attach(model) }
    }
}
