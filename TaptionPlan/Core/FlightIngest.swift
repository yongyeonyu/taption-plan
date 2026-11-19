import Foundation
import Observation
import TaptionPlanEngine
import TaptionPlanStore

/// 항공 알림 한 건을 읽어 여행 일정 칸에 반영한다(FLT1119A01). 읽기만 하고 결제·예약·취소는 하지 않는다.
/// 모호하면(후보 2개 이상) 자동으로 붙이지 않고 묻는다. 이름·예약번호는 기기 안에서만 쓰고 로그·오류 문구에 남기지 않는다.
enum FlightIngest {
    /// 한 번 처리한 결과.
    enum Reply: Equatable {
        /// 카드를 만들거나 기존 카드에 붙였다.
        case attached(created: Int, merged: Int)
        /// 어느 카드에 붙일지 사용자가 골라야 한다.
        case needsConfirmation(Confirmation)
        /// 항공편 알림으로 읽지 못했다.
        case unreadable
        /// 그 날짜에 맞는 여행이 없다. 글은 기기 안 보관함에 두었다가 여행이 생기면 다시 시도한다.
        case noTrip
        /// 붙일 카드가 없어 보류했다(체크인·현장 안내·지연 글은 새 카드를 만들지 않는다).
        case deferred
        /// 편명으로 조회하려 했지만 시간표를 받지 못했다.
        case lookupFailed
        /// 여행 부가 예약(eSIM·숙소·면세점)을 준비물 카드로 넣었다.
        case prepAdded(created: Int, updated: Int)
    }

    struct Candidate: Equatable, Identifiable {
        var cardID: String
        var title: String
        var dateText: String
        var id: String { cardID }
    }

    /// 사용자에게 묻는 내용. `text`는 원문이라 다시 처리할 때만 쓰고 화면·로그에 보이지 않는다.
    struct Confirmation: Equatable, Identifiable {
        var id = UUID()
        var text: String
        var candidates: [Candidate]
        /// 새 카드로 만들 수 있는가(안내형은 만들 수 없다).
        var allowsNew: Bool
    }

    /// 계획 결과(순수 계산): 새로 만들 카드, 바뀐 카드, 엔진이 돌려준 결과들.
    struct Plan: Equatable {
        var newCards: [FlightCard]
        var updatedCards: [FlightCard]
        var outcomes: [FlightMergeOutcome]
    }

    nonisolated static let newPrefix = "new-"

    /// 글 → 반영할 것. `onlyCards`가 있으면 그 카드들만 후보로 본다(확인 팝업에서 고른 뒤 다시 처리할 때, 빈 배열이면 새로 만든다).
    nonisolated static func plan(
        alert: FlightAlert, items: [TravelTripItem], onlyCards: [String]? = nil, receivedAt: Date, calendar: Calendar, source: FlightFieldSource
    ) -> Plan {
        let all = items.compactMap(FlightCardMapping.card(from:))
        let cards = onlyCards.map { ids in all.filter { ids.contains($0.id) } } ?? all
        var counter = 0
        let result = FlightAlertMerge.apply(alert, to: cards, receivedAt: receivedAt, calendar: calendar, source: source, makeID: {
            counter += 1
            return newPrefix + String(counter)
        })
        let before = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        let newCards = result.cards.filter { before[$0.id] == nil }
        let updated = result.cards.filter { card in before[card.id].map { $0 != card } ?? false }
        return Plan(newCards: newCards, updatedCards: updated, outcomes: result.outcomes)
    }

    /// 후보 카드를 화면에 보일 글로.
    nonisolated static func candidates(_ ids: [String], items: [TravelTripItem]) -> [Candidate] {
        ids.compactMap { id in
            guard let split = FlightCardMapping.split(cardID: id),
                  let item = items.first(where: { $0.tripID == split.tripID && $0.itemID == split.itemID }), let card = FlightCardMapping.card(from: item) else { return nil }
            return Candidate(cardID: id, title: item.title, dateText: card.date ?? "")
        }
    }

    /// 날짜(`YYYY-MM-DD`)를 덮는 여행 하나. 앞뒤 하루는 봐 준다(밤 비행·시차). 여럿이면 가장 먼저 시작하는 것, 없으면 nil.
    nonisolated static func trip(on date: String?, in trips: [TravelTrip]) -> TravelTrip? {
        guard let date, TravelTripDay.components(date) != nil else { return nil }
        let covering = trips.filter { trip in
            guard TravelTripDay.components(trip.startDay) != nil, TravelTripDay.components(trip.endDay) != nil else { return false }
            let before = TravelTripDay.days(from: trip.startDay, to: date) ?? -99
            let after = TravelTripDay.days(from: date, to: trip.endDay) ?? -99
            return before >= -1 && after >= -1
        }
        return covering.sorted { $0.startDay < $1.startDay }.first
    }

    /// 알림 글이 항공편 알림(또는 여행 부가 예약)으로 읽히는가. 붙여넣기 경로가 여행 JSON 가져오기와 가르는 데 쓴다.
    nonisolated static func looksLikeFlightAlert(_ text: String, now: Date = .now) -> Bool {
        if case .alert = FlightAlertParser.parse(text, receivedAt: now) { return true }
        return false
    }

    // MARK: 결과 문구(단축어 답변·붙여넣기 안내)

    static func message(for reply: Reply, language: MapHomeLanguage = .current) -> String {
        switch reply {
        case .attached(let created, let merged):
            if created > 0, merged > 0 { return language.text("항공편 카드를 만들고 붙였어요.", "Created and attached the flight cards.") }
            return created > 0 ? language.text("항공편 카드를 만들었어요.", "Created the flight card.") : language.text("카드에 붙였어요.", "Attached to the card.")
        case .needsConfirmation: return language.text("어느 카드인지 확인해 주세요.", "Please confirm which card this belongs to.")
        case .unreadable: return language.text("항공편 알림으로 읽지 못했어요.", "Could not read this as a flight notice.")
        case .noTrip: return language.text("그 날짜의 여행이 없어요. 여행을 만든 뒤 다시 열면 이어서 붙일게요.", "No trip covers that date. Create the trip and reopen the app to attach it.")
        case .deferred: return language.text("붙일 카드가 없어 보류했어요.", "No card to attach it to, so it is on hold.")
        case .lookupFailed: return language.text("편명으로 시간표를 찾지 못했어요. 직접 넣어 주세요.", "Could not find the timetable for that flight. Please add it manually.")
        case .prepAdded: return language.text("여행 준비물 카드로 넣었어요.", "Added it as a trip prep card.")
        }
    }
}

/// 마지막 처리 결과를 화면에 알리는 곳(붙여넣기 배너가 보여 준다). 원문은 들고 있지 않는다.
@MainActor
@Observable
final class FlightAlertCenter {
    static let shared = FlightAlertCenter()
    private(set) var message: String?
    var confirmation: FlightIngest.Confirmation?

    func show(_ reply: FlightIngest.Reply) {
        if case .needsConfirmation(let request) = reply { confirmation = request; message = nil; return }
        message = FlightIngest.message(for: reply)
    }

    func clearMessage() { message = nil }
}

extension AppModel {
    /// 항공 알림 글을 반영한다. `onlyCards`는 확인 팝업에서 고른 카드(빈 배열 = 새로 만들기).
    @MainActor
    func ingestFlightAlert(
        _ raw: String, source: FlightFieldSource = .paste, onlyCards: [String]? = nil, now: Date = .now, calendar: Calendar = .autoupdatingCurrent
    ) async -> FlightIngest.Reply {
        guard case .alert(let alert) = FlightAlertParser.parse(raw, receivedAt: now) else { return .unreadable }
        if alert.kind == .travelExtra { return await applyTravelExtra(alert, now: now, calendar: calendar, raw: raw) }
        let items = snapshot.settings.travelTripItems ?? []
        let plan = FlightIngest.plan(alert: alert, items: items, onlyCards: onlyCards, receivedAt: now, calendar: calendar, source: source)
        // 모호하면 아무것도 바꾸지 않고 묻는다.
        for outcome in plan.outcomes {
            if case .needsConfirmation(let ids) = outcome {
                let allowsNew = alert.kind == .bookingNotice || alert.kind == .itinerary || alert.kind == .airlineNameBody
                return .needsConfirmation(.init(text: raw, candidates: FlightIngest.candidates(ids, items: items), allowsNew: allowsNew))
            }
        }
        var created = 0, merged = 0, noTrip = false, lookupFailed = false
        for card in plan.newCards {
            if await createTripFlight(card: card) { created += 1 } else { noTrip = true }
        }
        for card in plan.updatedCards where await updateTripFlight(card: card) { merged += 1 }
        for outcome in plan.outcomes {
            guard case .lookupNeeded(let flight, let date) = outcome else { continue }
            if await createFromLookup(flight: flight, date: date, receivedAt: now, calendar: calendar) { created += 1 } else { lookupFailed = true }
        }
        if created + merged > 0 {
            await syncFlightBriefings(now: now)
            // 지연 글이면 바로 알린다(앱을 닫아 두었을 때도 단축어로 들어오면 알림이 온다).
            for card in plan.updatedCards where card.currentDelayMinutes > 0 {
                guard let ids = FlightCardMapping.split(cardID: card.id),
                      let item = (snapshot.settings.travelTripItems ?? []).first(where: { $0.tripID == ids.tripID && $0.itemID == ids.itemID }),
                      let briefing = FlightBriefingPolicy.delayBriefing(item: item, delayMinutes: card.currentDelayMinutes, now: now) else { continue }
                await FlightBriefingScheduler.shared.notifyDelay(briefing)
            }
            return .attached(created: created, merged: merged)
        }
        if noTrip { FlightInbox.stash(raw, now: now); return .noTrip }
        if lookupFailed { return .lookupFailed }
        return .deferred
    }

    /// 새 카드를 그 날짜의 여행에 넣는다. 맞는 여행이 없거나 일정 칸을 만들 수 없으면 false.
    @MainActor
    private func createTripFlight(card: FlightCard) async -> Bool {
        guard let trip = FlightIngest.trip(on: card.date, in: snapshot.settings.travelTrips ?? []), let schedule = FlightCardMapping.schedule(for: card) else { return false }
        guard let itemID = await addTripItem(
            tripID: trip.id, kind: .flight, title: FlightCardMapping.title(for: card), start: schedule.start, end: schedule.end,
            offsetSeconds: schedule.startOffsetSeconds, endOffsetSeconds: schedule.endOffsetSeconds, place: card.destination.flatMap(FlightPlacement.arrivalPlace)
        ) else { return false }
        var items = snapshot.settings.travelTripItems ?? []
        guard let index = items.firstIndex(where: { $0.tripID == trip.id && $0.itemID == itemID }) else { return true }
        FlightCardMapping.apply(card, to: &items[index])
        snapshot.settings.travelTripItems = items
        return await persist()
    }

    /// 기존 일정 칸에 카드 값을 쓴다. 시각이 바뀌었으면 시작·끝(길이는 유지)과 일상 쪽 계획 기록도 함께 옮긴다.
    @MainActor
    @discardableResult
    func updateTripFlight(card: FlightCard) async -> Bool {
        guard acceptsDataMutation(), let ids = FlightCardMapping.split(cardID: card.id) else { return false }
        var items = snapshot.settings.travelTripItems ?? []
        guard let index = items.firstIndex(where: { $0.tripID == ids.tripID && $0.itemID == ids.itemID }) else { return false }
        FlightCardMapping.apply(card, to: &items[index])
        if card.time != nil, let schedule = FlightCardMapping.schedule(for: card), schedule.start != items[index].start {
            let length = items[index].end.timeIntervalSince(items[index].start)
            items[index].start = schedule.start
            items[index].end = schedule.start.addingTimeInterval(max(60, length))
            items[index].startOffsetSeconds = schedule.startOffsetSeconds
        }
        snapshot.settings.travelTripItems = items
        let item = items[index]
        return await updateTripItem(tripID: item.tripID, itemID: item.itemID, kind: .flight, title: item.title, start: item.start, end: item.end)
    }

    /// 편명·날짜로 시간표(인천 출·도착)를 찾아 카드를 만든다. 못 찾으면 false.
    @MainActor
    private func createFromLookup(flight: String, date: String, receivedAt: Date, calendar: Calendar) async -> Bool {
        for direction in [FlightLookup.Direction.dep, .arr] {
            guard case .found(let result) = await FlightLookup.fetch(.schedule, airport: "ICN", day: date, direction: direction, flight: flight),
                  let row = result.flights.first(where: { $0.flight == flight }),
                  let draft = FlightPlacement.draft(from: row, day: date, direction: direction),
                  let trip = FlightIngest.trip(on: date, in: snapshot.settings.travelTrips ?? []) else { continue }
            let id = await addTripItem(
                tripID: trip.id, kind: .flight, title: draft.title, start: draft.start, end: draft.end,
                offsetSeconds: draft.startOffsetSeconds, endOffsetSeconds: draft.endOffsetSeconds, place: draft.arrivalPlace, flight: draft.fields
            )
            if id != nil { return true }
        }
        return false
    }

    /// 확인 팝업에서 고른 뒤 다시 처리한다. `cardID`가 nil이면 새 카드로 만든다.
    @MainActor
    func resolveFlightConfirmation(_ request: FlightIngest.Confirmation, attachTo cardID: String?) async -> FlightIngest.Reply {
        await ingestFlightAlert(request.text, source: .paste, onlyCards: cardID.map { [$0] } ?? [])
    }
}

/// 여행이 아직 없어 붙이지 못한 알림 글을 기기 안에 잠깐 둔다(최대 20건, 30일). 서버·백업으로 가지 않는다.
enum FlightInbox {
    static let key = "flightInboxPending"
    static let maximum = 20
    static let lifetime: TimeInterval = 30 * 86_400

    struct Entry: Codable, Equatable {
        var text: String
        var at: Date
    }

    static func pending(_ defaults: UserDefaults = .standard) -> [Entry] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    static func stash(_ text: String, now: Date = .now, defaults: UserDefaults = .standard) {
        var list = pending(defaults).filter { now.timeIntervalSince($0.at) < lifetime && $0.text != text }
        list.append(Entry(text: text, at: now))
        if let data = try? JSONEncoder().encode(Array(list.suffix(maximum))) { defaults.set(data, forKey: key) }
    }

    /// 앱이 열릴 때 다시 시도한다. 붙은 글은 지우고, 아직 여행이 없는 글은 남긴다.
    @MainActor
    static func drain(into model: AppModel, now: Date = .now, defaults: UserDefaults = .standard) async {
        let list = pending(defaults).filter { now.timeIntervalSince($0.at) < lifetime }
        guard !list.isEmpty, model.isBootstrapped else { return }
        defaults.removeObject(forKey: key)
        for entry in list {
            // 같은 글이 다시 못 붙으면 `ingestFlightAlert`가 보관함에 다시 넣는다.
            let reply = await model.ingestFlightAlert(entry.text, source: .intent, now: entry.at)
            if case .needsConfirmation = reply { FlightAlertCenter.shared.show(reply) }
        }
    }
}
