import Foundation
import TaptionPlanEngine
import TaptionPlanStore

/// 여행 부가 예약(eSIM·숙소·면세점) 알림을 준비물 카드로 만든다(FLT1119A01). 순수 계산이라 저장은 부른 쪽이 한다.
/// - 같은 건의 다음 알림은 예약번호·주문번호로 1:1로 찾아 갱신한다(숙소 접수 → 확정, 면세 주문 → 수령).
/// - 연도 없는 기간은 임의로 확정하지 않고 「날짜 확인 필요」로 표시한다.
/// - 출장 표시가 있으면 개인 경비와 섞지 않게 `isBusiness`로 가른다.
enum FlightPrep {
    enum Outcome: Equatable {
        case applied(items: [TravelPrepItem], created: Int, updated: Int)
        case noTrip
        case ignored
    }

    nonisolated static let kindESIM = "esim", kindLodging = "lodging", kindDutyFree = "dutyFree"
    nonisolated static let maximumItems = 200

    /// `now` 기준으로 알림을 붙일 여행. 면세는 출국일이 속한 여행을 먼저 본다. 없으면 끝나지 않은 여행 중 가장 먼저 시작하는 것(나라 이름이 맞으면 그것).
    nonisolated static func trip(for extra: FlightAlertExtra, in trips: [TravelTrip], now: Date, calendar: Calendar) -> TravelTrip? {
        let today = day(now, calendar)
        if extra.kind == .dutyFree, let resolved = extra.departureDate?.resolved(reference: now, calendar: calendar) {
            let key = String(format: "%04d-%02d-%02d", resolved.year, resolved.month, resolved.day)
            if let match = FlightIngest.trip(on: key, in: trips) { return match }
        }
        let open = trips.filter { TravelTripDay.components($0.startDay) != nil && TravelTripDay.components($0.endDay) != nil && $0.endDay >= today }.sorted { $0.startDay < $1.startDay }
        if let country = extra.country, let named = open.first(where: { ($0.regionName ?? "").contains(country) || $0.title.contains(country) }) { return named }
        return open.first
    }

    nonisolated static func apply(
        extra: FlightAlertExtra, pnr: String?, to items: [TravelPrepItem], trips: [TravelTrip], now: Date, calendar: Calendar,
        label: (String) -> String, makeID: () -> String = { "p-" + UUID().uuidString.prefix(8).lowercased() }
    ) -> Outcome {
        guard let trip = trip(for: extra, in: trips, now: now, calendar: calendar) else { return .noTrip }
        var items = items
        var created = 0, updated = 0
        let ref = referenceCode(extra, pnr: pnr)
        let existing = items.firstIndex { item in
            guard item.tripID == trip.id, item.kind == extra.kind.rawValue else { return false }
            if let ref { return item.refCode == ref }
            if let link = TravelPrepItem.cleanLink(extra.link) { return item.linkURL == link }
            return item.title == title(extra, label: label)
        }
        let link = TravelPrepItem.cleanLink(extra.link)
        let confirmDates = extra.ambiguousPeriod != nil
        let status = extra.status?.rawValue
        if let index = existing {
            var item = items[index]
            var changed = false
            func set<T: Equatable>(_ path: WritableKeyPath<TravelPrepItem, T?>, _ value: T?) {
                guard let value, item[keyPath: path] != value else { return }
                item[keyPath: path] = value
                changed = true
            }
            set(\.orderStatus, status)
            set(\.linkURL, link)
            set(\.detail, detail(extra))
            if extra.isBusiness { set(\.isBusiness, true) }
            if confirmDates { set(\.needsDateConfirmation, true) }
            if extra.status == .received, item.checked != true { item.checked = true; changed = true }
            if changed { items[index] = item; updated = 1 }
        } else {
            guard items.count < maximumItems else { return .ignored }
            items.append(TravelPrepItem(
                id: makeID(), tripID: trip.id, kind: extra.kind.rawValue, title: title(extra, label: label), detail: detail(extra), linkURL: link, orderStatus: status,
                checked: extra.status == .received ? true : nil, refCode: ref, isBusiness: extra.isBusiness ? true : nil, needsDateConfirmation: confirmDates ? true : nil, createdAt: now
            ))
            created = 1
        }
        return .applied(items: items, created: created, updated: updated)
    }

    /// 같은 건을 찾는 열쇠: 면세는 주문번호, 숙소는 예약번호.
    nonisolated static func referenceCode(_ extra: FlightAlertExtra, pnr: String?) -> String? {
        switch extra.kind {
        case .dutyFree: extra.orderNumber
        case .lodging: pnr
        case .esim: nil
        }
    }

    nonisolated static func title(_ extra: FlightAlertExtra, label: (String) -> String) -> String {
        switch extra.kind {
        case .esim: extra.product.map { String($0.prefix(60)) } ?? label(kindESIM)
        case .lodging: label(kindLodging)
        case .dutyFree: label(kindDutyFree)
        }
    }

    nonisolated static func detail(_ extra: FlightAlertExtra) -> String? {
        let text: String?
        switch extra.kind {
        case .esim: text = extra.validityNote
        case .dutyFree: text = [extra.product, extra.pickupPlace].compactMap { $0 }.joined(separator: " · ")
        case .lodging:
            text = extra.ambiguousPeriod.map { String(format: "%02d/%02d ~ %02d/%02d", $0.start.month, $0.start.day, $0.end.month, $0.end.day) }
        }
        guard let text, !text.isEmpty else { return nil }
        return String(text.prefix(200))
    }

    nonisolated private static func day(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 화면에 보일 종류 이름.
    static func label(_ kind: String, language: MapHomeLanguage = .current) -> String {
        switch kind {
        case kindESIM: language.text("eSIM·유심", "eSIM")
        case kindLodging: language.text("숙소 예약", "Lodging booking")
        case kindDutyFree: language.text("면세점 주문", "Duty-free order")
        default: language.text("준비물", "Prep item")
        }
    }
}

extension AppModel {
    /// 여행 부가 예약 알림을 준비물 카드로 저장한다.
    @MainActor
    func applyTravelExtra(_ alert: FlightAlert, now: Date, calendar: Calendar, raw: String) async -> FlightIngest.Reply {
        guard acceptsDataMutation(), let extra = alert.extra else { return .deferred }
        switch FlightPrep.apply(extra: extra, pnr: alert.pnr, to: snapshot.settings.travelPrepItems ?? [], trips: snapshot.settings.travelTrips ?? [], now: now, calendar: calendar,
                                label: { FlightPrep.label($0) }) {
        case .noTrip:
            FlightInbox.stash(raw, now: now)
            return .noTrip
        case .ignored:
            return .deferred
        case .applied(let items, let created, let updated):
            snapshot.settings.travelPrepItems = items
            return await persist() ? .prepAdded(created: created, updated: updated) : .deferred
        }
    }

    /// 준비물 카드 하나의 확인 표시를 바꾼다.
    @MainActor
    @discardableResult
    func setTravelPrepChecked(_ id: String, _ checked: Bool) async -> Bool {
        guard acceptsDataMutation(), var items = snapshot.settings.travelPrepItems, let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items[index].checked = checked ? true : nil
        snapshot.settings.travelPrepItems = items
        return await persist()
    }

    /// 준비물 카드를 지운다.
    @MainActor
    @discardableResult
    func deleteTravelPrep(_ id: String) async -> Bool {
        guard acceptsDataMutation(), var items = snapshot.settings.travelPrepItems, items.contains(where: { $0.id == id }) else { return false }
        items.removeAll { $0.id == id }
        snapshot.settings.travelPrepItems = items.isEmpty ? nil : items
        return await persist()
    }
}
