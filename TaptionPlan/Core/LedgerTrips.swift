import Foundation

/// 일상↔여행 짝 기록의 종류(LED1111A05).
struct LedgerTransfer: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// 여행 예산: 일상 지출 「○○ 여행 경비」 ↔ 여행 수입 「경비 받음」.
        case funding
        /// 여행이 끝난 뒤 정산: 남으면 여행 지출 「정산 반납」 ↔ 일상 수입, 모자라면 일상 지출 「추가 경비」 ↔ 여행 수입.
        case settlement
    }

    var kind: Kind
    var tripID: String
}

/// 여행 장부 하나. 앱의 여행 계획(여행 번호)과 같은 id를 쓰고, 계획 없는 여행은 가계부에서 만든 id다.
struct LedgerTrip: Codable, Equatable, Identifiable, Sendable {
    static let kind = "ledger-trip"
    /// 나를 가리키는 이름. 화면에는 「나」로 보인다.
    static let me = "@me"

    var id: String
    var name: String
    var start: Date
    var end: Date
    /// 일상에서 이 여행으로 보낸 예산(원). nil이면 예산 없이 쓰고 끝난 뒤 모두 정산한다.
    var budgetKRW: Double?
    /// 함께 간 사람(나 빼고). 이름만 기기에 둔다.
    var members: [String] = []

    var everyone: [String] { [Self.me] + members }

    func hasEnded(asOf now: Date, calendar: Calendar) -> Bool {
        now >= calendar.startOfDay(for: end).addingTimeInterval(86_400)
    }
}

/// 여행 장부 맨 아래 정산(내 기준 대차대조).
struct LedgerTripSheet: Equatable, Sendable {
    struct Transfer: Equatable, Sendable {
        var from: String
        var to: String
        var amountKRW: Double
    }

    /// 일상에서 받은 예산.
    var budget: Double
    /// 예산 밖 내 수입(환불 등). 짝 기록과 친구에게 받은 돈은 뺀다.
    var otherIncome: Double
    /// 친구에게 미리 받은 돈(총무일 때). 내 손에 있지만 내 돈이 아니라 정산에서 그 사람이 낸 돈으로 친다.
    var receivedFromOthers: Double = 0
    /// 내가 실제로 낸 돈.
    var myPaid: Double
    /// 내 몫(나만 쓴 것 + 나눈 것의 내 몫). 여행이 내게 든 진짜 비용.
    var myCost: Double
    /// 함께 쓴 돈 전체(공금).
    var sharedTotal: Double
    /// 사람별 차액(+면 받을 돈, −면 줄 돈).
    var balances: [String: Double]
    /// 최소 송금 경로.
    var transfers: [Transfer]

    /// 지금 손에 남은 돈(친구 정산 전). 친구에게 미리 받은 돈도 손에 있다.
    var cashLeft: Double { budget + otherIncome + receivedFromOthers - myPaid }
    /// 친구와 정산까지 끝났을 때 남는 돈. +면 일상으로 반납, −면 일상에서 더 보냄.
    var leftover: Double { budget + otherIncome - myCost }
    var receivable: Double { transfers.filter { $0.to == LedgerTrip.me }.reduce(0) { $0 + $1.amountKRW } }
    var payable: Double { transfers.filter { $0.from == LedgerTrip.me }.reduce(0) { $0 + $1.amountKRW } }
    var mine: [Transfer] { transfers.filter { $0.from == LedgerTrip.me || $0.to == LedgerTrip.me } }
}

enum LedgerTripMath {
    /// 공금은 따로 두지 않는다(대표 결정): 「다 같이」는 n분의 1, 낸 사람은 비면 나, 몫은 비면 다 같이.
    /// 여행 수입에 낸 사람(A)이 있으면 「A에게 미리 받은 돈」이다(총무): A가 낸 돈으로 치고 내 쪽에서 뺀다.
    static func sheet(_ trip: LedgerTrip, entries: [LedgerEntry]) -> LedgerTripSheet {
        let mine = entries.filter { $0.tripID == trip.id }
        let everyone = trip.everyone
        // 동행 목록에서 빠지거나 이름이 바뀐 사람도 자기 줄로 남긴다(리뷰: 그 사람이 낸 돈이 「내가 낸 돈」이 되던 것).
        var people = everyone
        for entry in mine {
            for name in [entry.payer].compactMap({ $0 }) + (entry.shareNames ?? []) where !people.contains(name) { people.append(name) }
        }
        var balances = Dictionary(uniqueKeysWithValues: people.map { ($0, 0.0) })
        var myPaid = 0.0, myCost = 0.0, shared = 0.0, otherIncome = 0.0, received = 0.0
        for entry in mine where entry.transfer == nil {
            let amount = entry.amountKRW ?? 0
            guard entry.kind == .expense else {
                if let giver = entry.payer, giver != LedgerTrip.me {
                    balances[giver, default: 0] += amount
                    balances[LedgerTrip.me, default: 0] -= amount
                    received += amount
                } else {
                    otherIncome += amount
                }
                continue
            }
            let payer = entry.payer ?? LedgerTrip.me
            let sharers = entry.shareNames ?? everyone
            let split = sharers.isEmpty ? [payer] : sharers
            balances[payer, default: 0] += amount
            for name in split { balances[name, default: 0] -= amount / Double(split.count) }
            if payer == LedgerTrip.me { myPaid += amount }
            if split.contains(LedgerTrip.me) { myCost += amount / Double(split.count) }
            if split.count > 1 { shared += amount }
        }
        let budget = mine.filter { $0.transfer?.kind == .funding }.reduce(0) { $0 + ($1.amountKRW ?? 0) }
        return LedgerTripSheet(
            budget: budget, otherIncome: otherIncome, receivedFromOthers: received, myPaid: myPaid, myCost: myCost.rounded(),
            sharedTotal: shared, balances: balances, transfers: transfers(balances)
        )
    }

    /// 받을 사람과 줄 사람을 큰 금액부터 짝지어 송금 수를 줄인다.
    static func transfers(_ balances: [String: Double]) -> [LedgerTripSheet.Transfer] {
        var debtors = balances.filter { $0.value < -0.5 }.map { ($0.key, -$0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        var creditors = balances.filter { $0.value > 0.5 }.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        var result: [LedgerTripSheet.Transfer] = []
        while let debtor = debtors.first, let creditor = creditors.first {
            let amount = min(debtor.1, creditor.1)
            result.append(.init(from: debtor.0, to: creditor.0, amountKRW: amount.rounded()))
            debtors[0].1 -= amount
            creditors[0].1 -= amount
            if debtors[0].1 < 0.5 { debtors.removeFirst() }
            if creditors[0].1 < 0.5 { creditors.removeFirst() }
        }
        return result
    }
}

extension LedgerBook {
    /// 일상 장부: 여행 안 기록은 빼고 여행과 오간 짝 기록만 남는다.
    var dailyEntries: [LedgerEntry] { entries.filter(isDaily) }

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
        await setPair(trip: trip, kind: .funding, dailyIsExpense: true, amount: budget, at: calendar.startOfDay(for: trip.start),
                      dailyTitle: language.text("\(trip.name) 여행 경비", "\(trip.name) trip budget"), tripTitle: language.text("경비 받음", "Budget received"))
        guard trip.hasEnded(asOf: now, calendar: calendar) else {
            await setPair(trip: trip, kind: .settlement, dailyIsExpense: false, amount: 0, at: now, dailyTitle: "", tripTitle: "")
            return
        }
        let leftover = LedgerTripMath.sheet(trip, entries: entries).leftover
        let settleDay = calendar.startOfDay(for: trip.end).addingTimeInterval(86_400 + 9 * 3_600)
        if leftover >= 0 {
            await setPair(trip: trip, kind: .settlement, dailyIsExpense: false, amount: leftover, at: settleDay,
                          dailyTitle: language.text("\(trip.name) 여행 정산", "\(trip.name) trip refund"), tripTitle: language.text("정산 반납", "Returned to daily"))
        } else {
            await setPair(trip: trip, kind: .settlement, dailyIsExpense: true, amount: -leftover, at: settleDay,
                          dailyTitle: language.text("\(trip.name) 여행 추가 경비", "\(trip.name) extra trip cost"), tripTitle: language.text("추가 경비 받음", "Extra budget received"))
        }
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

    /// 앱 여행 계획에서 고를 여행: 여행 번호별 첫날·마지막 날과 첫 일정 이름.
    static func plannedTrips(stops: [TravelPlanStop], items: [TravelTripItem]) -> [LedgerTrip] {
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
        return days.map { LedgerTrip(id: $0.key, name: $0.value.name, start: $0.value.start, end: $0.value.end) }.sorted { $0.start > $1.start }
    }
}
