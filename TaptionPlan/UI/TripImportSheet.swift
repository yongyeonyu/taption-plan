import MapKit
import SwiftUI
import TaptionPlanCore

extension AppModel {
    /// AI 여행을 반영한다. 같은 여행이 있으면 지우고 새로 넣는다(대표 결정: 바뀐 것 표시 후 교체).
    /// 반영하지 못하면 false. 그때는 서버에 도착한 계획을 지우지 않는다(REV1110A06).
    @discardableResult
    func applyTripImport(_ incoming: TripImportPlan) async -> Bool {
        guard acceptsDataMutation() else { return false }
        // 다시 가져온 계획에 상태가 없으면 사용자가 정한 상태를 지킨다.
        let plan = incoming.keepingUserStatus(from: snapshot.settings.travelTripItems ?? [])
        // 핀이 없는 일정(수면·좌표 없음)도 계획이 있으니 여행 일정 쪽 planID까지 함께 지운다.
        let oldPlanIDs = Set(
            snapshot.settings.travelPlanStops.filter { $0.tripID == plan.tripID }.compactMap(\.planID)
                + (snapshot.settings.travelTripItems ?? []).filter { $0.tripID == plan.tripID }.compactMap(\.planID)
        )
        snapshot.settings.travelPlanStops = TravelPlanSchedule.renumbered(snapshot.settings.travelPlanStops.filter { $0.tripID != plan.tripID })
        await deletePlans(Array(oldPlanIDs))
        let calendar = Calendar.autoupdatingCurrent
        var stops = snapshot.settings.travelPlanStops
        // 같은 여행을 다시 가져와도 손으로 정한 색·예상 지출은 일정 번호로 이어 준다(TVU1113A01).
        let kept = Dictionary((snapshot.settings.travelTripItems ?? []).filter { $0.tripID == plan.tripID }.map { ($0.itemID, $0) }) { first, _ in first }
        var tripItems = (snapshot.settings.travelTripItems ?? []).filter { $0.tripID != plan.tripID }
        for item in plan.items {
            let planID = addPlan(
                title: item.title,
                categoryID: item.kind.categoryID,
                middleCategoryName: item.kind.planName,
                startAt: item.start,
                duration: item.end.timeIntervalSince(item.start)
            )
            tripItems.append(TravelTripItem(
                tripID: plan.tripID, itemID: item.id, kind: item.kind.rawValue, title: item.title,
                start: item.start, end: item.end,
                startOffsetSeconds: item.timeZone.secondsFromGMT(for: item.start),
                endOffsetSeconds: item.endTimeZone.secondsFromGMT(for: item.end), planID: planID, status: item.status.stored,
                note: item.note.isEmpty ? nil : item.note,
                colorHex: kept[item.id]?.colorHex, plannedSpendKRW: kept[item.id]?.plannedSpendKRW
            ))
            // 잠은 숙소 자리라 지도에 핀을 따로 찍지 않는다.
            guard item.kind != .sleep, let coordinate = item.coordinate else { continue }
            let day = item.localDay(calendar: calendar)
            stops.append(TravelPlanStop(
                id: UUID(), title: item.title, latitude: coordinate.latitude, longitude: coordinate.longitude,
                day: day, order: TravelPlanSchedule.stops(on: day, in: stops).count, planID: planID,
                tripID: plan.tripID, itemID: item.id, status: item.status.stored
            ))
        }
        snapshot.settings.travelPlanStops = stops
        snapshot.settings.travelTripItems = tripItems.isEmpty ? nil : tripItems
        // 여행 이름과 기간을 여행 단위에 남긴다(TVA1111A01). 사용자가 정한 여행지·통화는 그대로 둔다.
        let trips = TravelTripDirectory.upserting(snapshot.settings.travelTrips ?? [], id: plan.tripID, title: plan.title, items: tripItems)
        snapshot.settings.travelTrips = trips.isEmpty ? nil : trips
        return await persist()
    }

    // MARK: 여행 단위(TVA1111A01)

    /// 여행 목록: 저장한 여행과 일정에만 번호가 남은 옛 여행. `names`는 여행 번호별 이름(가계부 여행 장부)이다.
    func travelTripEntries(names: [String: String] = [:], now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> [TravelTripDirectory.Entry] {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return TravelTripDirectory.entries(
            stored: snapshot.settings.travelTrips ?? [], stops: snapshot.settings.travelPlanStops,
            items: snapshot.settings.travelTripItems ?? [], names: names,
            today: TravelTripDay.string(year: parts.year ?? 0, month: parts.month ?? 1, day: parts.day ?? 1)
        )
    }

    /// 여행을 더하거나 고친다. 번호가 비었거나 마지막 날이 첫날보다 앞이면 넣지 않는다. 같은 값이면 저장하지 않는다.
    /// 당일치기는 첫날과 마지막 날이 같다. 지난 날짜도 된다: 그날의 자동 기록이 그 여행의 「실제」가 된다.
    @discardableResult
    func saveTravelTrip(_ trip: TravelTrip) async -> Bool {
        // 언젠가 갈 여행은 날짜 없이 날 수만 있다(TVW1112A01).
        guard acceptsDataMutation(), !trip.id.isEmpty,
              trip.isWish || (TravelTripDay.days(from: trip.startDay, to: trip.endDay) ?? -1) >= 0 else { return false }
        var trips = snapshot.settings.travelTrips ?? []
        if let index = trips.firstIndex(where: { $0.id == trip.id }) {
            guard trips[index] != trip else { return true }
            trips[index] = trip
        } else {
            trips.append(trip)
        }
        snapshot.settings.travelTrips = trips
        return await persist()
    }

    /// 여행의 일정 전체를 `days`일만큼 한 덩어리로 옮긴다(대표 결정: 여행 날짜를 옮기면 일정도 함께).
    /// 일상 쪽 계획 기록과 지도 핀 날짜가 같이 옮겨진다. 캘린더 고정 일정에 묶인 것은 그 자리에 둔다.
    @discardableResult
    func shiftTravelTrip(_ tripID: String, byDays days: Int, calendar: Calendar = .autoupdatingCurrent) async -> Bool {
        guard acceptsDataMutation(), !tripID.isEmpty else { return false }
        guard days != 0 else { return true }
        let delta = TimeInterval(days * 86_400)
        var items = snapshot.settings.travelTripItems ?? []
        var kept: Set<String> = []
        for index in items.indices where items[index].tripID == tripID {
            if let planID = items[index].planID, let planIndex = snapshot.plans.firstIndex(where: { $0.id == planID }) {
                if snapshot.plans[planIndex].isFixed {
                    kept.insert(items[index].itemID)
                    continue
                }
                let span = snapshot.plans[planIndex].span
                snapshot.plans[planIndex].span = TimeSpan(start: span.start.addingTimeInterval(delta), end: span.end.addingTimeInterval(delta))
                snapshot.plans[planIndex].updatedAt = .now
            }
            items[index].start = items[index].start.addingTimeInterval(delta)
            items[index].end = items[index].end.addingTimeInterval(delta)
        }
        snapshot.plans.sort { $0.span.start < $1.span.start }
        snapshot.settings.travelTripItems = items.isEmpty ? nil : items
        var stops = snapshot.settings.travelPlanStops
        for index in stops.indices where stops[index].tripID == tripID && !kept.contains(stops[index].itemID ?? "") {
            stops[index].day = calendar.date(byAdding: .day, value: days, to: stops[index].day) ?? stops[index].day.addingTimeInterval(delta)
        }
        snapshot.settings.travelPlanStops = TravelPlanSchedule.renumbered(stops)
        if let trips = snapshot.settings.travelTrips {
            snapshot.settings.travelTrips = TravelTripDirectory.extended(trips, toCover: items)
        }
        return await persist()
    }

    /// 여행을 지운다: 그 여행의 일정과 일상 쪽 계획 기록, 지도 핀까지. 가계부의 여행 장부는 그대로 둔다.
    @discardableResult
    func deleteTravelTrip(_ tripID: String) async -> Bool {
        guard acceptsDataMutation(), !tripID.isEmpty else { return false }
        let items = snapshot.settings.travelTripItems ?? []
        let planIDs = Set(items.filter { $0.tripID == tripID }.compactMap(\.planID)
            + snapshot.settings.travelPlanStops.filter { $0.tripID == tripID }.compactMap(\.planID))
        await deletePlans(Array(planIDs))
        let left = items.filter { $0.tripID != tripID }
        snapshot.settings.travelTripItems = left.isEmpty ? nil : left
        snapshot.settings.travelPlanStops = TravelPlanSchedule.renumbered(snapshot.settings.travelPlanStops.filter { $0.tripID != tripID })
        let trips = (snapshot.settings.travelTrips ?? []).filter { $0.id != tripID }
        snapshot.settings.travelTrips = trips.isEmpty ? nil : trips
        return await persist()
    }

    /// 여행 일정 하나를 `delta`초 옮긴다. 일상 쪽 계획 기록과 지도 핀 날짜가 함께 바뀐다.
    @discardableResult
    func moveTripItem(tripID: String, itemID: String, by delta: TimeInterval, calendar: Calendar = .autoupdatingCurrent) async -> Bool {
        guard let items = TravelTripItemEditor.moved(snapshot.settings.travelTripItems ?? [], tripID: tripID, itemID: itemID, by: delta) else { return false }
        return await applyTripItemTimes(items, tripID: tripID, itemID: itemID, calendar: calendar)
    }

    /// 여행 일정의 시작·끝을 따로 옮긴다. 5분보다 짧아지면 바꾸지 않는다.
    @discardableResult
    func resizeTripItem(
        tripID: String, itemID: String, startDelta: TimeInterval? = nil, endDelta: TimeInterval? = nil, calendar: Calendar = .autoupdatingCurrent
    ) async -> Bool {
        guard let items = TravelTripItemEditor.resized(
            snapshot.settings.travelTripItems ?? [], tripID: tripID, itemID: itemID, startDelta: startDelta, endDelta: endDelta
        ) else { return false }
        return await applyTripItemTimes(items, tripID: tripID, itemID: itemID, calendar: calendar)
    }

    // MARK: 손으로 넣기(TVQ1112A01)

    /// 여행 일정 하나를 손으로 넣는다. 일상 쪽 계획 기록이 함께 생긴다. 넣은 일정 번호를 돌려준다.
    func addTripItem(
        tripID: String, kind: TripImportItem.Kind, title: String, start: Date, end: Date, offsetSeconds: Int,
        place: TravelItemPlace? = nil, note: String = "", colorHex: String? = nil, plannedSpendKRW: Double? = nil
    ) async -> String? {
        guard acceptsDataMutation(), !tripID.isEmpty, end > start else { return nil }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let planID = addPlan(
            title: name.isEmpty ? kind.planName : name, categoryID: kind.categoryID, middleCategoryName: kind.planName,
            startAt: start, duration: end.timeIntervalSince(start)
        ) else { return nil }
        let itemID = "m-" + UUID().uuidString.prefix(8).lowercased()
        let items = (snapshot.settings.travelTripItems ?? []) + [TravelTripItem(
            tripID: tripID, itemID: itemID, kind: kind.rawValue, title: name.isEmpty ? kind.planName : name, start: start, end: end,
            startOffsetSeconds: offsetSeconds, endOffsetSeconds: offsetSeconds, planID: planID,
            note: Self.cleanTripNote(note),
            colorHex: TravelTripItem.cleanColorHex(colorHex), plannedSpendKRW: TravelTripItem.cleanPlannedSpend(plannedSpendKRW)
        )]
        snapshot.settings.travelTripItems = items
        if let place, let item = items.last { setTripItemPlace(place, for: item) }
        if let trips = snapshot.settings.travelTrips {
            snapshot.settings.travelTrips = TravelTripDirectory.extended(trips, toCover: items)
        }
        return await persist() ? itemID : nil
    }

    /// 메모는 앞뒤 빈칸을 떼고 500자까지. 비면 nil(키를 쓰지 않는다).
    static func cleanTripNote(_ note: String) -> String? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(500))
    }

    /// 일정의 지도 핀을 그 장소로 놓는다(없으면 만들고, 있으면 옮긴다). nil이면 핀을 뗀다. 저장은 부른 쪽이 한다.
    private func setTripItemPlace(_ place: TravelItemPlace?, for item: TravelTripItem, calendar: Calendar = .autoupdatingCurrent) {
        var stops = snapshot.settings.travelPlanStops
        let index = stops.firstIndex { $0.tripID == item.tripID && $0.itemID == item.itemID }
        guard let place else {
            if let index { stops.remove(at: index) }
            snapshot.settings.travelPlanStops = TravelPlanSchedule.renumbered(stops)
            return
        }
        if let index {
            stops[index].latitude = place.latitude
            stops[index].longitude = place.longitude
            stops[index].title = item.title
        } else {
            let wall = TravelTripDay.components(TravelTripDay.string(for: item.start, offsetSeconds: item.startOffsetSeconds))
            let day = wall.flatMap(calendar.date(from:)).map(calendar.startOfDay(for:)) ?? calendar.startOfDay(for: item.start)
            stops.append(TravelPlanStop(
                id: UUID(), title: item.title, latitude: place.latitude, longitude: place.longitude, day: day,
                order: TravelPlanSchedule.stops(on: day, in: stops).count, planID: item.planID, tripID: item.tripID, itemID: item.itemID
            ))
        }
        snapshot.settings.travelPlanStops = stops
    }

    /// 여행 일정의 종류·이름·시각을 고친다. 일상 쪽 계획 기록과 지도 핀 이름이 함께 바뀐다.
    @discardableResult
    func updateTripItem(
        tripID: String, itemID: String, kind: TripImportItem.Kind, title: String, start: Date, end: Date,
        place: TravelItemPlace? = nil, replacesPlace: Bool = false, note: String? = nil,
        style: (colorHex: String?, plannedSpendKRW: Double?)? = nil, calendar: Calendar = .autoupdatingCurrent
    ) async -> Bool {
        var items = snapshot.settings.travelTripItems ?? []
        guard end > start, let index = items.firstIndex(where: { $0.tripID == tripID && $0.itemID == itemID }) else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? kind.planName : trimmed
        items[index].kind = kind.rawValue
        items[index].title = name
        items[index].start = start
        items[index].end = end
        // 메모는 넘겨준 때만 바꾼다(빈 글이면 지운다).
        if let note { items[index].note = Self.cleanTripNote(note) }
        // 색·예상 지출도 넘겨준 때만 바꾼다(nil이면 지운다).
        if let style {
            items[index].colorHex = TravelTripItem.cleanColorHex(style.colorHex)
            items[index].plannedSpendKRW = TravelTripItem.cleanPlannedSpend(style.plannedSpendKRW)
        }
        if let planID = items[index].planID, let planIndex = snapshot.plans.firstIndex(where: { $0.id == planID }) {
            guard !snapshot.plans[planIndex].isFixed else { return false }
            snapshot.plans[planIndex].title = name
            snapshot.plans[planIndex].categoryID = kind.categoryID
            snapshot.plans[planIndex].middleCategoryName = kind.planName
        }
        if let stopIndex = snapshot.settings.travelPlanStops.firstIndex(where: { $0.tripID == tripID && $0.itemID == itemID }) {
            snapshot.settings.travelPlanStops[stopIndex].title = name
        }
        if replacesPlace { setTripItemPlace(place, for: items[index], calendar: calendar) }
        return await applyTripItemTimes(items, tripID: tripID, itemID: itemID, calendar: calendar)
    }

    /// 여행 일정 하나를 지운다. 일상 쪽 계획 기록과 지도 핀도 함께 지운다.
    @discardableResult
    func deleteTripItem(tripID: String, itemID: String) async -> Bool {
        var items = snapshot.settings.travelTripItems ?? []
        guard acceptsDataMutation(), let index = items.firstIndex(where: { $0.tripID == tripID && $0.itemID == itemID }) else { return false }
        let removed = items.remove(at: index)
        if let planID = removed.planID { await deletePlans([planID]) }
        snapshot.settings.travelTripItems = items.isEmpty ? nil : items
        snapshot.settings.travelPlanStops = TravelPlanSchedule.renumbered(
            snapshot.settings.travelPlanStops.filter { !($0.tripID == tripID && $0.itemID == itemID) }
        )
        return await persist()
    }

    private func applyTripItemTimes(_ items: [TravelTripItem], tripID: String, itemID: String, calendar: Calendar) async -> Bool {
        guard acceptsDataMutation(), let item = items.first(where: { $0.tripID == tripID && $0.itemID == itemID }) else { return false }
        // 일상 쪽 계획 기록을 같은 시각으로 맞춘다. 캘린더 고정 일정이면 여행 일정도 그대로 둔다.
        if let planID = item.planID, let index = snapshot.plans.firstIndex(where: { $0.id == planID }) {
            guard !snapshot.plans[index].isFixed else { return false }
            snapshot.plans[index].span = TimeSpan(start: item.start, end: item.end)
            snapshot.plans[index].updatedAt = .now
            snapshot.plans.sort { $0.span.start < $1.span.start }
        }
        snapshot.settings.travelTripItems = items
        // 날짜가 넘어가면 지도 핀도 그날 맨 뒤로 옮긴다.
        var stops = snapshot.settings.travelPlanStops
        let wallDay = TravelTripDay.components(TravelTripDay.string(for: item.start, offsetSeconds: item.startOffsetSeconds))
        if let index = stops.firstIndex(where: { $0.tripID == tripID && $0.itemID == itemID }),
           let day = wallDay.flatMap(calendar.date(from:)).map(calendar.startOfDay(for:)),
           !TravelPlanSchedule.isSameDay(stored: stops[index].day, local: day, calendar: calendar) {
            stops[index].day = day
            stops[index].order = Int.max
            snapshot.settings.travelPlanStops = TravelPlanSchedule.renumbered(stops)
        }
        // 일정이 여행 기간 밖으로 나가면 기간을 늘린다.
        if let trips = snapshot.settings.travelTrips {
            snapshot.settings.travelTrips = TravelTripDirectory.extended(trips, toCover: items)
        }
        return await persist()
    }

    func tripImportDiff(for plan: TripImportPlan) -> TripImportDiff? {
        TripImportDiff.make(plan: plan, existing: snapshot.settings.travelTripItems ?? [])
    }
}

/// 여행 일정을 시간 막대에 놓는다. 각 일정은 그곳의 벽시계 시각에 놓여, 항공편 도착부터 현지 시각이 된다.
/// 손으로 넣는 일정에 붙이는 장소(TVX1112A01). 지도 핀이 된다.
struct TravelItemPlace: Equatable, Identifiable {
    var name: String
    var latitude: Double
    var longitude: Double
    var id: String { "\(name)|\(latitude)|\(longitude)" }
}

enum TravelTripRail {
    static func segments(_ items: [TravelTripItem], day: Date, calendar: Calendar = .autoupdatingCurrent) -> [MapHomeTimeRailSegment] {
        let target = calendar.dateComponents([.year, .month, .day], from: day)
        return items.compactMap { item in
            let start = wallClock(item.start, offset: item.startOffsetSeconds)
            let end = wallClock(item.end, offset: item.endOffsetSeconds)
            let startMinute = start.day == target ? start.minute : start.day < target ? 0 : nil
            let endMinute = end.day == target ? end.minute : end.day > target ? 1_440 : nil
            guard let startMinute, let endMinute, endMinute > startMinute else { return nil }
            var segment = MapHomeTimeRailSegment(
                startMinute: startMinute, endMinute: endMinute,
                categoryID: railCategory(item.kind), title: item.title, sourceID: item.planID
            )
            segment.tripStatus = TripItemStatus(raw: item.status) // 계획은 그대로 그린다(TRP1110A09).
            return segment
        }
        .sorted { $0.startMinute < $1.startMinute }
    }

    private struct WallClock {
        let day: DateComponents
        let minute: Int
    }

    private static func wallClock(_ date: Date, offset: Int) -> WallClock {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(secondsFromGMT: offset) ?? .current
        let parts = local.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return WallClock(day: DateComponents(year: parts.year, month: parts.month, day: parts.day), minute: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    static func railCategory(_ kind: String) -> String {
        switch TripImportItem.Kind(rawValue: kind) ?? .other {
        case .flight, .transfer: "movement"
        case .sleep: "sleep"
        case .meal, .cafe: "eating"
        case .activity: "exercise"
        case .sight, .photo, .shopping: "hobby"
        case .lodging, .rest, .other: "activity"
        }
    }
}

private func < (lhs: DateComponents, rhs: DateComponents) -> Bool {
    (lhs.year ?? 0, lhs.month ?? 0, lhs.day ?? 0) < (rhs.year ?? 0, rhs.month ?? 0, rhs.day ?? 0)
}

private func > (lhs: DateComponents, rhs: DateComponents) -> Bool { rhs < lhs }

extension MapHomeView {
    /// 여행 모드에서 그날의 여행 일정(시간 막대의 계획 띠).
    var travelSidebarSegments: [MapHomeTimeRailSegment]? {
        guard isTravelMode, let items = model.settings.travelTripItems, !items.isEmpty else { return nil }
        let segments = TravelTripRail.segments(items, day: model.selectedDate)
        return segments.isEmpty ? nil : segments
    }

    /// 여행 모드의 시간 막대는 계획과 실제 기록을 나란히 그린다(TVC1112A01). 계획이 없는 날은 비어 있어 예전 모습 그대로다.
    var travelPlanBand: [MapHomeRailPlanSpan] {
        guard let plan = travelSidebarSegments else { return [] }
        return TravelPlanBand.spans(plan: plan, actual: timeRailSegments, day: model.selectedDate, now: .now)
    }
}

/// 여행 모드에서 실제 기록 옆에 나란히 그리는 계획 한 칸(TVC1112A01).
struct MapHomeRailPlanSpan: Hashable {
    var startMinute: Int
    var endMinute: Int
    /// 예약은 진하게, 미정은 옅게.
    var opacity: Double
    /// 계획과 실제의 비교 결과. 건너뛰었거나 늦은 일정에 표시를 단다.
    var status: TravelPlanComparison.Status
}

/// 시간 막대 왼쪽 반의 계획 띠(남색). 건너뛴 일정은 주홍 테두리, 늦은 일정은 위쪽 주홍 줄.
struct MapHomeRailPlanBandView: View {
    let spans: [MapHomeRailPlanSpan]
    let window: ClosedRange<Int>
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ForEach(spans, id: \.self) { span in
            let start = max(min(span.startMinute, window.upperBound), window.lowerBound)
            let end = min(max(span.endMinute, window.lowerBound), window.upperBound)
            if start < end {
                let barHeight = max(1, height * MapHomeTimeSidebarMath.spanFraction(start: start, end: end, window: window))
                Rectangle()
                    .fill(TravelInk.plan.opacity(span.opacity))
                    .overlay(alignment: .top) {
                        if span.status == .skipped {
                            Rectangle().strokeBorder(TravelInk.actual, lineWidth: 1.5)
                        } else if span.status == .late {
                            Rectangle().fill(TravelInk.actual).frame(height: min(3, barHeight))
                        }
                    }
                    .frame(width: width - 1, height: barHeight)
                    .position(x: width / 2, y: height * MapHomeTimeSidebarMath.segmentCenterPosition(start: start, end: end, window: window))
            }
        }
    }
}

/// 계획 띠 만들기: 그날의 계획과 실제 기록을 견줘 일정마다 상태를 붙인다.
enum TravelPlanBand {
    static func spans(
        plan: [MapHomeTimeRailSegment], actual: [MapHomeTimeRailSegment], day: Date, now: Date, calendar: Calendar = .autoupdatingCurrent
    ) -> [MapHomeRailPlanSpan] {
        let nowMinute: Int
        if calendar.isDate(day, inSameDayAs: now) {
            let parts = calendar.dateComponents([.hour, .minute], from: now)
            nowMinute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        } else {
            nowMinute = day < now ? 1_440 : 0
        }
        func span(_ segment: MapHomeTimeRailSegment) -> TravelPlanComparison.Span {
            .init(id: segment.id, start: segment.startMinute, end: segment.endMinute, isMove: segment.categoryID == "movement")
        }
        let result = TravelPlanComparison.compare(
            plan: plan.map(span), actual: actual.filter { $0.categoryID != "unconfirmed" }.map(span), nowMinute: nowMinute
        )
        return plan.map {
            MapHomeRailPlanSpan(
                startMinute: $0.startMinute, endMinute: $0.endMinute,
                opacity: $0.tripStatus == .tentative ? 0.4 : ($0.tripStatus == .booked ? 1 : 0.75),
                status: result.statuses[$0.id] ?? .pending
            )
        }
    }
}

extension TripImportItem.Kind {
    var planName: String {
        let language = MapHomeLanguage.current
        switch self {
        case .flight: return language.text("항공편", "Flight")
        case .lodging: return language.text("숙소", "Lodging")
        case .meal: return language.text("식사", "Meal")
        case .cafe: return language.text("카페", "Cafe")
        case .photo: return language.text("사진 명소", "Photo spot")
        case .activity: return language.text("활동", "Activity")
        case .rest: return language.text("휴식", "Rest")
        case .sleep: return language.text("수면", "Sleep")
        case .sight: return language.text("관광", "Sightseeing")
        case .shopping: return language.text("쇼핑", "Shopping")
        case .transfer: return language.text("이동", "Transfer")
        case .other: return language.text("기타", "Other")
        }
    }

    /// 시간표 줄. 잠은 수면, 휴식은 휴식, 이동은 이동 줄에 놓인다.
    var categoryID: String {
        switch self {
        case .flight, .transfer: "movement"
        case .sleep: "sleep"
        case .rest: "rest"
        default: "travel"
        }
    }

    var symbol: String {
        switch self {
        case .flight: "airplane"
        case .lodging: "bed.double.fill"
        case .meal: "fork.knife"
        case .cafe: "cup.and.saucer.fill"
        case .photo: "camera.viewfinder"
        case .activity: "figure.pool.swim"
        case .rest: "sofa.fill"
        case .sleep: "moon.zzz.fill"
        case .sight: "camera.fill"
        case .shopping: "bag.fill"
        case .transfer: "tram.fill"
        case .other: "mappin"
        }
    }
}

/// 여행 모드 → 추가 → AI로 만들기(TRP1110A01). AI 앱에서 대화하고, 받은 JSON을 붙여 넣어 미리 본 뒤 반영한다.
struct MapHomeTripImportSheet: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    /// 앱으로 돌아와 배너에서 붙여 넣은 글. 있으면 열자마자 미리보기를 보인다.
    var initialText: String?
    var onApplied: (Date) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var pasted = ""
    @State private var plan: TripImportPlan?
    @State private var diff: TripImportDiff?
    @State private var message: String?
    @State private var copiedFor: TripImportAIApp?
    /// 피클을 누른 뒤 안내. 중계 구역에서 눌렀으면 그 아래에 보인다(TRP1110A08).
    @State private var pickleNote: (text: String, inRelay: Bool)?
    /// 복사한 뒤 AI를 열기 전에 「붙여 넣어 주세요」를 보이는 창. PIN 시트가 떠 있으면 닫힌 뒤에 띄운다.
    @State private var pasteGuide: TripPasteGuide?
    @State private var pendingPasteGuide: TripPasteGuide?
    @State private var isResolving = false
    /// AI 좌표가 지도 검색과 멀리 다른 일정(TRP1110A01).
    @State private var mismatches: [String: TripImportCoordinateCheck.Mismatch] = [:]
    @State private var isApplying = false
    @State private var applyMessage: String?

    @State private var isLoadingRelay = false
    /// 프롬프트에 넣은 그 AI의 연결 키. 주 키는 넣지 않는다(SEC1110A02).
    @State private var promptKey: String?
    @State private var store = AssistantConnectionStore()
    /// 연결 키가 없어 PIN을 묻는 중인 AI. 취소하면 키 없이 복사한다.
    @State private var pinApp: TripImportAIApp?
    @State private var pendingApp: (app: TripImportAIApp, inRelay: Bool)?

    private func prompt(key: String?) -> String {
        let base = TripImportPrompt.text(languageCode: TripImportPrompt.currentLanguageCode)
        guard let endpoint = TripRelay.endpoint, let key else { return base }
        return base + TripRelay.deliveryInstruction(endpoint: endpoint, key: key)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(language.text("AI로 여행 계획 만들기", "Plan a trip with AI"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.headline), weight: .bold))
                talkStep
                if TripRelay.isAvailable { relayStep }
                pasteStep
                if let plan { preview(plan) }
            }
            .padding(20)
        }
        .background(Color.tpBackground)
        .onAppear {
            guard plan == nil, let initialText else { return }
            read(initialText)
        }
        .alert(language.text("프롬프트를 복사했어요", "Prompt copied"), isPresented: Binding(
            get: { pasteGuide != nil }, set: { if !$0 { pasteGuide = nil } }
        ), presenting: pasteGuide) { guide in
            Button(language.text("\(guide.name) 열기", "Open \(guide.name)")) { openURL(guide.url) }
            Button(language.text("취소", "Cancel"), role: .cancel) {}
        } message: { guide in
            Text(guide.hasKey
                 ? language.text("\(guide.name) 채팅창에 붙여 넣고 보내 주세요. 연결 키가 들어 있어 계획이 앱으로 바로 와요. 클립보드는 10분 뒤 지워져요.",
                                 "Paste it into the \(guide.name) chat and send. It includes a connection key, so the plan comes straight to the app. The clipboard is cleared in 10 minutes.")
                 : language.text("\(guide.name) 채팅창에 붙여 넣고 보내 주세요.", "Paste it into the \(guide.name) chat and send."))
        }
        .sheet(item: $pinApp, onDismiss: {
            if let pendingPasteGuide {
                pasteGuide = pendingPasteGuide
                self.pendingPasteGuide = nil
            }
            // PIN을 넣지 않고 닫으면 키 없이 복사하고 연다.
            if let pending = pendingApp { finishOpen(pending.app, key: nil, inRelay: pending.inRelay) }
        }) { app in
            let name = app.title(language)
            AssistantPINSheet.gate(language: language, purpose: language.text(
                "\(name)에 넣을 연결 키를 만들어요. 취소하면 키 없이 복사해요.",
                "Creates a connection key for \(name). Cancel to copy without a key."
            )) { pin in
                switch await store.create(for: app.provider, pin: pin, language: language) {
                case let .failure(text): return text
                case let .key(_, token):
                    let inRelay = pendingApp?.inRelay ?? false
                    pendingApp = nil
                    finishOpen(app, key: token, inRelay: inRelay)
                    return nil
                }
            }
        }
        #if DEBUG
        // 시뮬레이터 시험용: SIMCTL_CHILD_TRIP_IMPORT_SAMPLE=<파일>로 붙여 넣은 것처럼 읽는다.
        .onAppear {
            guard plan == nil, let path = ProcessInfo.processInfo.environment["TRIP_IMPORT_SAMPLE"],
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            read(text)
        }
        #endif
    }

    private var talkStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle("1", language.text("AI와 대화하기", "Talk with an AI"))
            caption(language.text(
                "AI 앱이 열리면 객관식 질문에 답하며 항공편·숙소·관광지를 정해요. 마지막에 나오는 JSON을 복사해 돌아오세요.",
                "In the AI app, answer multiple-choice questions to pick flights, hotels and places. Copy the JSON it gives you at the end and come back."
            ))
            ForEach(TripImportAIApp.allCases) { app in
                let name = app.title(language)
                wideButton(app == .pickle
                    ? language.text("피클에서 계획 세우기 (자동 연동)", "Plan in Pickle (Auto Sync)")
                    : language.text("\(name)에서 계획 세우기", "Plan in \(name)"), prominent: app == .pickle) { open(app) }
                if app == .pickle, let pickleNote, !pickleNote.inRelay { caption(pickleNote.text) }
            }
            if let copiedFor, copiedFor != .pickle, !copiedFor.prefillsPrompt || promptKey != nil {
                let name = copiedFor.title(language)
                caption(language.text("프롬프트를 복사했어요. \(name)에 붙여 넣고 보내 주세요.", "The prompt is copied. Paste it into \(name) and send."))
            }
            wideButton(language.text("프롬프트만 복사", "Copy prompt only"), prominent: false) {
                // 키 없는 프롬프트. 키를 넣으려면 AI를 골라 연다.
                UIPasteboard.general.string = prompt(key: nil)
                TripClipboardWatch.promptCopied()
                message = language.text("프롬프트를 복사했어요.", "Prompt copied.")
            }
        }
    }

    /// AI 비서 자동 연결. 키를 만들면 프롬프트에 전달 주소가 붙고, 계획은 앱을 열 때 도착한다.
    private var relayStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(language.text("AI 비서가 앱으로 바로 보내기", "Let the AI send it to the app"), systemImage: "paperplane.fill")
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
                .foregroundStyle(Color.tpInk)
            caption(language.text(
                "웹 요청을 할 수 있는 AI 비서는 복사하지 않아도 계획을 보낼 수 있어요. AI를 고르면 그 AI의 연결 키가 프롬프트에 들어가고, 없으면 PIN을 물어 만들어요. 계획은 서버에 최대 3일 머물고 앱이 받으면 바로 지워져요.",
                "AI assistants that can make web requests can send the plan without copying. Pick an AI and its connection key goes into the prompt; if it has none, you're asked for your PIN to make one. Plans stay on the server for up to 3 days and are deleted as soon as the app receives them."
            ))
            wideButton(language.text("도착한 계획 불러오기", "Load the delivered plan"), prominent: false) { loadRelayPlan() }
                .disabled(isLoadingRelay)
            wideButton(language.text("피클 열기 / 받기", "Open / Get Pickle"), prominent: false) { open(.pickle, inRelay: true) }
            if let pickleNote, pickleNote.inRelay { caption(pickleNote.text) }
        }
    }

    private var pasteStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle("2", language.text("받은 JSON 붙여 넣기", "Paste the JSON"))
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in read(text) }
            }
            .buttonBorderShape(.capsule)
            TextEditor(text: $pasted)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .background(Color.tpCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            wideButton(language.text("확인", "Check"), prominent: false) { read(pasted) }
                .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            // 못 읽은 까닭은 경고색으로 보인다(회색 보조 글자는 눈에 안 띈다, PLN1111A01 제안 7-5).
            if let message { caption(message, color: .tpHoliday) }
        }
    }

    private func preview(_ plan: TripImportPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle("3", language.text("확인하고 반영하기", "Review and add"))
            Text(plan.title).font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
            if let diff {
                caption(language.text(
                    "같은 여행이 있어 바꿉니다 · 추가 \(diff.added) · 변경 \(diff.changed) · 삭제 \(diff.removed)",
                    "Replaces the same trip · added \(diff.added) · changed \(diff.changed) · removed \(diff.removed)"
                ))
            }
            if isResolving { ProgressView().frame(maxWidth: .infinity) }
            let warnings = TripImportTimingCheck.warnings(plan.items)
            let fares = TravelFareEstimate.fares(plan.items)
            ForEach(plan.days(), id: \.day) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.day, format: .dateTime.month().day().weekday())
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .bold))
                    ForEach(group.items) { item in row(item, warning: warnings[item.id], fare: fares[item.id]) }
                }
            }
            wideButton(language.text("여행 계획에 반영", "Add to trip plan"), prominent: true) {
                isApplying = true
                applyMessage = nil
                let appliedText = pasted
                Task { @MainActor in
                    let applied = await model.applyTripImport(plan)
                    isApplying = false
                    guard applied else {
                        // 반영하지 못했으면 닫지 않고, 서버의 계획도 그대로 둔다.
                        applyMessage = language.text("지금은 반영하지 못했어요. 잠시 뒤 다시 해 주세요.", "Couldn't add it right now. Try again in a moment.")
                        return
                    }
                    TripClipboardWatch.clear()
                    // 중계에서 받은 바로 그 계획일 때만 서버에서 지운다. 기다리지 않는다.
                    if TripRelay.isLastReceived(appliedText) { Task { await TripRelay.clear() } }
                    onApplied(plan.items.first?.localDay() ?? .now)
                    dismiss()
                }
            }
            .disabled(isResolving || isApplying)
            if let applyMessage { caption(applyMessage) }
        }
    }

    private func row(_ item: TripImportItem, warning: TripImportTimingCheck.Warning? = nil, fare: Int? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.symbol).frame(width: 22).foregroundStyle(Color.tpInk)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(localTime(item.start, item.timeZone))–\(localTime(item.end, item.endTimeZone)) \(item.title)")
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                TripItemStatusBadge(status: item.status, language: language)
                if let minutes = item.travelMinutes, minutes > 0 {
                    caption(language.text("앞에서 이동 \(Int(minutes))분", "\(Int(minutes)) min from previous"))
                }
                if let fare {
                    caption(language.text("예상 요금 \(fare.formatted())원", "Estimated fare ₩\(fare.formatted())"))
                }
                if let warning {
                    Text(warningText(warning))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .semibold))
                        .foregroundStyle(.orange)
                }
                if let mismatch = mismatches[item.id] {
                    HStack(spacing: 8) {
                        Text(language.text("AI 위치가 지도 검색과 \(distanceText(mismatch.meters)) 달라요", "AI location is \(distanceText(mismatch.meters)) from the map search"))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .semibold))
                            .foregroundStyle(.orange)
                        Button(language.text("검색 위치로", "Use search")) { useSearchedCoordinate(item.id) }
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                }
                if item.coordinate == nil {
                    Text(language.text("위치를 찾지 못해 지도에는 표시되지 않아요", "Location not found; not shown on the map"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .semibold))
                        .foregroundStyle(.orange)
                }
                if let url = item.mapsURL {
                    Link(language.text("구글 지도에서 보기", "Open in Google Maps"), destination: url)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .semibold))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.tpCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func warningText(_ warning: TripImportTimingCheck.Warning) -> String {
        switch warning {
        case let .tightMove(need): language.text("이동 시간이 빠듯해요(약 \(need)분 필요)", "Tight move (about \(need) min needed)")
        case let .afterFlight(need): language.text("도착 뒤 입국·짐 찾기로 \(need)분은 두세요", "Allow \(need) min after landing for arrival")
        }
    }

    private func distanceText(_ meters: Int) -> String {
        Measurement(value: Double(meters) / 1_000, unit: UnitLength.kilometers)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    /// 현지 시각으로 보여 준다(방콕 도착은 방콕 시각).
    private func localTime(_ date: Date, _ timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// 그 AI의 연결 키를 찾고, 없으면 PIN을 물어 만든다(SEC1110A02). 중계가 없으면 키 없이 연다.
    private func open(_ app: TripImportAIApp, inRelay: Bool = false) {
        guard TripRelay.isAvailable else { return finishOpen(app, key: nil, inRelay: inRelay) }
        Task { @MainActor in
            if store.keys == nil { await store.reload() }
            if let found = store.token(for: app.provider), found.key.scope == .write {
                finishOpen(app, key: found.token, inRelay: inRelay)
            } else {
                pendingApp = (app, inRelay)
                pinApp = app
            }
        }
    }

    private func finishOpen(_ app: TripImportAIApp, key: String?, inRelay: Bool) {
        pendingApp = nil
        promptKey = key
        let text = prompt(key: key)
        Task { @MainActor in
            // 복사를 끝낸 뒤에 복사 표시·붙여넣기 안내를 띄운다(늦게 복사되면 앱의 프롬프트를 계획으로 묻거나 옛 글을 붙여 넣게 된다).
            await copyPrompt(text, key: key)
            TripClipboardWatch.promptCopied()
            copiedFor = app
            presentAfterCopy(app, text: text, key: key, inRelay: inRelay)
        }
    }

    /// 키는 글에 넣지 않고 1회용 주소(10분·3번)로 건넨다(SET1110A01). 서버에 닿지 못하면 키가 든 글을 이 기기에만 10분 둔다.
    private func copyPrompt(_ text: String, key: String?) async {
        guard let key else { UIPasteboard.general.string = text; return }
        if let endpoint = TripRelay.endpoint {
            let base = TripImportPrompt.text(languageCode: TripImportPrompt.currentLanguageCode)
            let delivery = TripRelay.deliveryInstruction(endpoint: endpoint, key: key)
            if let link = await TripRelay.setupLinkText(for: delivery) { return AssistantClipboard.copy(base + "\n\n" + link) }
        }
        AssistantClipboard.copy(text)
    }

    private func presentAfterCopy(_ app: TripImportAIApp, text: String, key: String?, inRelay: Bool) {
        guard app == .pickle else {
            let prefills = app.prefillsPrompt && key == nil
            guard let url = app.url(prompt: prefills ? text : nil) else { return }
            // 프롬프트가 채워져 열리면 붙여 넣을 일이 없다.
            if prefills { openURL(url) } else { showPasteGuide(TripPasteGuide(name: app.title(language), url: url, hasKey: key != nil)) }
            return
        }
        // 피클은 앱이 없으면 App Store를 연다(TRP1110A08).
        let installed = AssistantAIProvider.pickle.isInstalled
        let note = !installed
            ? language.text("피클이 없어서 App Store를 열었어요. 설치한 뒤 다시 눌러 주세요.", "Pickle isn't installed, so the App Store opened. Install it and tap again.")
            : key != nil
                ? language.text("프롬프트와 피클 연결 키를 복사했어요. 피클 채팅창에 붙여 넣으면 계획이 앱으로 바로 와요.", "The prompt and Pickle's connection key are copied. Paste them into the Pickle chat and the plan comes straight to the app.")
                : language.text("프롬프트를 복사했어요. 피클에 붙여 넣고 보내 주세요.", "The prompt is copied. Paste it into Pickle and send.")
        pickleNote = (note, inRelay)
        guard let url = AssistantAIProvider.pickle.destination(installed: installed) else { return }
        // 피클이 없으면 붙여 넣을 곳이 없으니 App Store를 바로 연다.
        if installed { showPasteGuide(TripPasteGuide(name: AssistantAIProvider.pickle.title(language), url: url, hasKey: key != nil)) } else { openURL(url) }
    }

    private func showPasteGuide(_ guide: TripPasteGuide) {
        if pinApp != nil { pendingPasteGuide = guide } else { pasteGuide = guide }
    }

    /// 반영하지 않고 닫았던 계획도 서버에 남아 있으면(최대 3일) 다시 불러온다.
    private func loadRelayPlan() {
        isLoadingRelay = true
        Task { @MainActor in
            let text = await TripRelay.fetch()
            isLoadingRelay = false
            if let text {
                _ = TripRelay.isNew(text)
                read(text)
            } else {
                message = language.text("도착한 계획이 없어요.", "No plan has arrived.")
            }
        }
    }

    private func read(_ text: String) {
        pasted = text
        switch TripImportParser.parse(text) {
        case .success(let parsed):
            message = nil
            plan = parsed
            diff = model.tripImportDiff(for: parsed)
            mismatches = [:]
            Task { @MainActor in
                await resolveMissingPlaces()
                await checkAICoordinates()
            }
        case .failure(let error):
            plan = nil
            message = describe(error)
        }
    }

    /// AI가 좌표를 비운 곳은 이름·주소로 찾는다. 못 찾으면 시간 일정만 넣는다.
    private func resolveMissingPlaces() async {
        guard var current = plan, current.items.contains(where: { $0.coordinate == nil }) else { return }
        isResolving = true
        let anchor = current.items.compactMap(\.coordinate).first
        for index in current.items.indices where current.items[index].coordinate == nil {
            let item = current.items[index]
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = [item.placeName, item.address].filter { !$0.isEmpty }.joined(separator: " ")
            if let anchor { request.region = MKCoordinateRegion(center: anchor, latitudinalMeters: 200_000, longitudinalMeters: 200_000) }
            current.items[index].coordinate = try? await MKLocalSearch(request: request).start().mapItems.first?.placemark.coordinate
        }
        if plan?.tripID == current.tripID { plan = current }
        isResolving = false
    }

    /// AI가 준 좌표를 이름 검색과 견준다. 검색은 그 좌표 둘레 20km 안에서 한다.
    private func checkAICoordinates() async {
        guard let current = plan else { return }
        var found: [String: TripImportCoordinateCheck.Mismatch] = [:]
        for item in current.items.filter(TripImportCoordinateCheck.shouldCheck).prefix(TripImportCoordinateCheck.checkLimit) {
            guard let ai = item.coordinate else { continue }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = item.placeName
            request.region = MKCoordinateRegion(center: ai, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
            let searched = try? await MKLocalSearch(request: request).start().mapItems.first?.placemark.coordinate
            if let mismatch = TripImportCoordinateCheck.mismatch(ai: ai, searched: searched) { found[item.id] = mismatch }
        }
        if plan?.tripID == current.tripID { mismatches = found }
    }

    private func useSearchedCoordinate(_ itemID: String) {
        guard let mismatch = mismatches[itemID], let index = plan?.items.firstIndex(where: { $0.id == itemID }) else { return }
        plan?.items[index].coordinate = mismatch.searched
        mismatches[itemID] = nil
    }

    private func describe(_ error: TripImportError) -> String {
        switch error {
        case .noJSON, .notTripFormat:
            return language.text("여행 계획 JSON이 아니에요. AI가 마지막에 준 JSON 전체를 복사해 주세요.", "This isn't trip JSON. Copy the whole JSON the AI gave at the end.")
        case .unreadable:
            return language.text("JSON 일부가 잘렸거나 형식이 달라요. AI에게 JSON을 다시 출력해 달라고 해 주세요.", "Part of the JSON is cut off or malformed. Ask the AI to output the JSON again.")
        case .unsupportedVersion:
            return language.text("앱보다 새 형식이에요. 앱을 업데이트해 주세요.", "This format is newer than the app. Please update the app.")
        case .empty:
            return language.text("일정이 비어 있어요.", "The trip has no items.")
        case .badTime(let itemID):
            return language.text("\(itemID) 항목의 시각을 읽지 못했어요.", "Couldn't read the time of item \(itemID).")
        }
    }

    private func stepTitle(_ number: String, _ title: String) -> some View {
        Text(verbatim: "\(number). \(title)")
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
            .foregroundStyle(Color.tpInk)
    }

    private func caption(_ text: String, color: Color = .tpSecondary) -> some View {
        Text(text)
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .medium))
            .foregroundStyle(color)
    }

    private func wideButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                .foregroundStyle(prominent ? Color.tpBackground : Color.tpInk)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(prominent ? Color.tpInk : Color.tpCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 여행 프롬프트를 복사한 뒤 열 AI.
struct TripPasteGuide: Equatable {
    var name: String
    var url: URL
    var hasKey: Bool
}
