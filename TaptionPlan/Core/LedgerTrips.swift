import Foundation

extension LedgerBook {
    /// 일상 장부: 여행 안 기록은 빼고 여행과 오간 짝 기록만 남는다.
    var dailyEntries: [LedgerEntry] {
        // 여행 번호는 한 번만 모아 둔다. 기록마다 여행 목록을 훑으면 기록 수 × 여행 수가 된다(LGP1113A01).
        let tripIDs = Set(trips.map(\.id))
        return entries.filter { $0.tripID.map { !tripIDs.contains($0) } ?? true }
    }

    /// 일상 장부 기록인가. 여행 번호가 있어도 그 여행 장부가 없으면(예전 여행 모드 기록·지운 장부) 일상으로 본다(리뷰).
    func isDaily(_ entry: LedgerEntry) -> Bool {
        guard let tripID = entry.tripID else { return true }
        return !trips.contains { $0.id == tripID }
    }

    /// 이월잔액: 그때까지 일상 장부의 수입 − 지출(LED1111A07).
    func carryOver(before date: Date) -> Double {
        dailyEntries.filter { $0.occurredAt < date }.reduce(0) { $0 + $1.signedKRW }
    }

    func tripEntries(_ tripID: String) -> [LedgerEntry] { entries.filter { $0.tripID == tripID } }

    func trip(_ id: String) -> LedgerTrip? { trips.first { $0.id == id } }

    func saveTrip(_ trip: LedgerTrip, now: Date = .now, calendar: Calendar = .autoupdatingCurrent) async {
        await load()
        if let index = trips.firstIndex(where: { $0.id == trip.id }) { trips[index] = trip } else { trips.append(trip) }
        trips.sort { $0.start > $1.start }
        if let store = storeFactory(), let body = try? JSONEncoder().encode(trip), let text = String(data: body, encoding: .utf8) {
            try? await store.upsertRecords([TaptionStoreRecord(id: trip.id, kind: LedgerTrip.kind, updatedAt: .now, origin: .user, isDeleted: false, body: text)])
        }
        await syncTrip(trip.id, now: now, calendar: calendar)
    }

    /// 여행 장부를 지운다(리뷰). 일상↔여행 짝 기록은 지우고, 여행 안 기록은 남겨 일상 장부로 돌아간다.
    func deleteTrip(_ id: String) async {
        await load()
        for entry in entries where entry.transfer?.tripID == id { await delete(entry.id) }
        guard let trip = trip(id) else { return }
        trips.removeAll { $0.id == id }
        if let store = storeFactory(), let body = try? JSONEncoder().encode(trip), let text = String(data: body, encoding: .utf8) {
            try? await store.upsertRecords([TaptionStoreRecord(id: id, kind: LedgerTrip.kind, updatedAt: .now, origin: .user, isDeleted: true, body: text)])
        }
    }

    /// 여행의 짝 기록을 맞춘다: 예산 이체는 늘, 정산은 여행이 끝난 뒤에(대표 결정: 자동 정산·모자라면 추가 이체).
    func syncTrip(_ id: String, now: Date = .now, calendar: Calendar = .autoupdatingCurrent) async {
        await load()
        guard let trip = trip(id) else { return }
        let budget = max(0, trip.budgetKRW ?? 0)
        let language = MapHomeLanguage.current
        await setPair(trip: trip, kind: .funding, dailyIsExpense: true, amount: budget, at: trip.fundingDate ?? calendar.startOfDay(for: trip.start),
                      dailyTitle: language.text("\(trip.name) 여행 경비", "\(trip.name) trip budget"), tripTitle: language.text("경비 받음", "Budget received"))
        guard trip.hasEnded(asOf: now, calendar: calendar) else {
            await setPair(trip: trip, kind: .settlement, dailyIsExpense: false, amount: 0, at: now, dailyTitle: "", tripTitle: "")
            return
        }
        let leftover = trip.settlementKRW ?? LedgerTripMath.sheet(trip, entries: entries).leftover
        let settleDay = trip.settlementDate ?? calendar.startOfDay(for: trip.end).addingTimeInterval(86_400 + 9 * 3_600)
        if leftover >= 0 {
            await setPair(trip: trip, kind: .settlement, dailyIsExpense: false, amount: leftover, at: settleDay,
                          dailyTitle: language.text("\(trip.name) 여행 정산", "\(trip.name) trip refund"), tripTitle: language.text("정산 반납", "Returned to daily"))
        } else {
            await setPair(trip: trip, kind: .settlement, dailyIsExpense: true, amount: -leftover, at: settleDay,
                          dailyTitle: language.text("\(trip.name) 여행 추가 경비", "\(trip.name) extra trip cost"), tripTitle: language.text("추가 경비 받음", "Extra budget received"))
        }
    }

    /// 짝 기록을 고친다(LED1111A09). 금액·날짜를 여행 값에 담아 일상 쪽·여행 쪽을 함께 맞춘다.
    /// 정산은 고친 쪽의 수입·지출로 방향을 정한다(일상 쪽 수입이면 반납, 지출이면 추가 경비).
    func saveTransfer(_ entry: LedgerEntry) async {
        await load()
        guard let transfer = entry.transfer, var trip = trip(transfer.tripID) else { return }
        let amount = max(0, (entry.amountKRW ?? entry.amount).rounded())
        switch transfer.kind {
        case .funding:
            trip.budgetKRW = amount > 0 ? amount : nil
            trip.fundingDate = entry.occurredAt
        case .settlement:
            let isDailySide = entry.tripID == nil
            let returned = isDailySide ? entry.kind == .income : entry.kind == .expense
            trip.settlementKRW = returned ? amount : -amount
            trip.settlementDate = entry.occurredAt
        }
        // 고친 기록의 장소·메모는 짝 기록이 다시 만들어져도 남게 먼저 담는다.
        if var kept = entries.first(where: { $0.id == entry.id }), kept.place != entry.place || kept.note != entry.note {
            kept.place = entry.place
            kept.note = entry.note
            await save(kept)
        }
        await saveTrip(trip)
    }

    /// 짝 기록을 지운다(LED1111A09): 예산은 없음, 정산은 0으로 고정해 다시 생기지 않게 한다.
    func deleteTransfer(_ entry: LedgerEntry) async {
        await load()
        guard let transfer = entry.transfer, var trip = trip(transfer.tripID) else { return await delete(entry.id) }
        switch transfer.kind {
        case .funding:
            trip.budgetKRW = nil
            trip.fundingDate = nil
        case .settlement:
            trip.settlementKRW = 0
            trip.settlementDate = nil
        }
        await saveTrip(trip)
    }

    /// 손으로 고친 정산을 다시 자동으로 돌린다.
    func resetSettlement(_ tripID: String) async {
        await load()
        guard var trip = trip(tripID) else { return }
        trip.settlementKRW = nil
        trip.settlementDate = nil
        await saveTrip(trip)
    }

    /// 기록 하나를 지운다. 짝 기록은 여행 값으로, 메모에서 생긴 기록은 그 메모를 「메모로만」으로 바꿔 다시 생기지 않게 한다.
    func remove(_ entry: LedgerEntry) async {
        if entry.transfer != nil { return await deleteTransfer(entry) }
        if let memoID = entry.memoID { LedgerMemoOptOut.set(memoID, optedOut: true) }
        await delete(entry.id)
        if let tripID = entry.tripID { await syncTrip(tripID) }
    }

    /// 끝난 여행을 모두 정산한다(가계부·카운터를 열 때).
    func syncEndedTrips(now: Date = .now, calendar: Calendar = .autoupdatingCurrent) async {
        await load()
        for trip in trips where trip.hasEnded(asOf: now, calendar: calendar) { await syncTrip(trip.id, now: now, calendar: calendar) }
    }

    /// 짝 기록 두 개(일상 쪽·여행 쪽)를 금액에 맞게 만들거나 고치거나(0이면) 지운다.
    private func setPair(
        trip: LedgerTrip, kind: LedgerTransfer.Kind, dailyIsExpense: Bool, amount: Double, at date: Date,
        dailyTitle: String, tripTitle: String
    ) async {
        let existing = entries.filter { $0.transfer == LedgerTransfer(kind: kind, tripID: trip.id) }
        guard amount >= 1 else {
            for entry in existing { await delete(entry.id) }
            return
        }
        let transfer = LedgerTransfer(kind: kind, tripID: trip.id)
        let daily = existing.first { $0.tripID == nil }
        let inTrip = existing.first { $0.tripID == trip.id }
        func make(_ old: LedgerEntry?, tripID: String?, isExpense: Bool, title: String) -> LedgerEntry {
            var value = old ?? LedgerEntry(occurredAt: date, amount: amount, title: title)
            value.occurredAt = date
            value.amount = amount.rounded()
            value.amountKRW = amount.rounded()
            value.currency = "KRW"
            value.kind = isExpense ? .expense : .income
            value.category = .travel
            value.title = title
            value.tripID = tripID
            value.transfer = transfer
            return value
        }
        let dailyEntry = make(daily, tripID: nil, isExpense: dailyIsExpense, title: dailyTitle)
        let tripEntry = make(inTrip, tripID: trip.id, isExpense: !dailyIsExpense, title: tripTitle)
        if dailyEntry != daily { await save(dailyEntry) }
        if tripEntry != inTrip { await save(tripEntry) }
    }

    /// 앱 여행 계획에서 고를 여행: 여행 번호별 첫날·마지막 날과 이름.
    /// 저장한 여행(`trips`, TVA1111A01)이 있으면 그 이름과 기간을 쓰고, 없으면 일정에서 알아낸다(이름은 첫 일정).
    static func plannedTrips(
        stops: [TravelPlanStop], items: [TravelTripItem], trips: [TravelTrip] = [], calendar: Calendar = .autoupdatingCurrent
    ) -> [LedgerTrip] {
        var days: [String: (start: Date, end: Date, name: String)] = [:]
        for stop in stops {
            guard let id = stop.tripID else { continue }
            let old = days[id]
            days[id] = (min(old?.start ?? stop.day, stop.day), max(old?.end ?? stop.day, stop.day), old?.name ?? stop.title)
        }
        for item in items {
            let old = days[item.tripID]
            days[item.tripID] = (min(old?.start ?? item.start, item.start), max(old?.end ?? item.end, item.end), old?.name ?? item.title)
        }
        for trip in trips {
            let old = days[trip.id]
            let first = TravelTripDay.components(trip.startDay).flatMap(calendar.date(from:)) ?? old?.start
            guard let start = first else { continue }
            let end = TravelTripDay.components(trip.endDay).flatMap(calendar.date(from:)) ?? old?.end ?? start
            days[trip.id] = (start, max(start, end), trip.title.isEmpty ? (old?.name ?? "") : trip.title)
        }
        return days.map { LedgerTrip(id: $0.key, name: $0.value.name, start: $0.value.start, end: $0.value.end) }.sorted { $0.start > $1.start }
    }
}
