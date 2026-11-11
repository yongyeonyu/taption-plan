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
    /// 예산 이체 날짜를 고쳤으면 그 날(LED1111A09). nil이면 여행 첫날.
    var fundingDate: Date?
    /// 정산을 손으로 고쳤으면 그 금액(+면 일상으로 반납, −면 추가 경비, 0이면 정산 없음). nil이면 자동 정산.
    var settlementKRW: Double?
    /// 정산 날짜를 고쳤으면 그 날. nil이면 여행 다음 날 아침.
    var settlementDate: Date?

    var everyone: [String] { [Self.me] + members }

    func hasEnded(asOf now: Date, calendar: Calendar) -> Bool {
        now >= calendar.startOfDay(for: end).addingTimeInterval(86_400)
    }
}

/// 읽기 안전망(LDS1111A01): id·이름·기간만 필수, 나머지는 없으면 기본값. 새 칸을 더하면 여기에도 더한다.
extension LedgerTrip {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        start = try values.decode(Date.self, forKey: .start)
        end = try values.decode(Date.self, forKey: .end)
        budgetKRW = try values.decodeIfPresent(Double.self, forKey: .budgetKRW)
        members = try values.decodeIfPresent([String].self, forKey: .members) ?? []
        fundingDate = try values.decodeIfPresent(Date.self, forKey: .fundingDate)
        settlementKRW = try values.decodeIfPresent(Double.self, forKey: .settlementKRW)
        settlementDate = try values.decodeIfPresent(Date.self, forKey: .settlementDate)
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
        // 모두 원 단위 정수로 센다: 지출마다 몫의 합이 그 지출과 같아 잔액 합이 늘 0이다(STL1111A01).
        var balances = Dictionary(uniqueKeysWithValues: people.map { ($0, 0) })
        var myPaid = 0, myCost = 0, shared = 0, received = 0, otherIncome = 0.0
        for entry in mine where entry.transfer == nil {
            let amount = entry.countedKRW
            let won = LedgerSplit.won(amount)
            guard entry.kind == .expense else {
                if let giver = entry.payer, giver != LedgerTrip.me {
                    balances[giver, default: 0] += won
                    balances[LedgerTrip.me, default: 0] -= won
                    received += won
                } else {
                    otherIncome += amount
                }
                continue
            }
            let payer = entry.payer ?? LedgerTrip.me
            let sharers = entry.shareNames ?? everyone
            let split = sharers.isEmpty ? [payer] : sharers
            balances[payer, default: 0] += won
            for (name, share) in zip(split, LedgerSplit.even(won, among: split, payer: payer)) {
                balances[name, default: 0] -= share
                if name == LedgerTrip.me { myCost += share }
            }
            if payer == LedgerTrip.me { myPaid += won }
            if split.count > 1 { shared += won }
        }
        let budget = mine.filter { $0.transfer?.kind == .funding }.reduce(0) { $0 + $1.countedKRW }
        let transfers = LedgerSplit.transfers(balances, order: people).map {
            LedgerTripSheet.Transfer(from: $0.from, to: $0.to, amountKRW: Double($0.amount))
        }
        return LedgerTripSheet(
            budget: budget, otherIncome: otherIncome, receivedFromOthers: Double(received), myPaid: Double(myPaid), myCost: Double(myCost),
            sharedTotal: Double(shared), balances: balances.mapValues(Double.init), transfers: transfers
        )
    }
}

/// 원 단위 나누기와 최소 송금(Taption Trip `TripSettlementEngine`에서 옮김, STL1111A01). 같은 입력이면 결과와 순서가 늘 같다.
enum LedgerSplit {
    struct Transfer: Equatable, Sendable {
        var from: String
        var to: String
        var amount: Int
    }

    /// 원화 금액을 원 단위로. 셀 수 없는 값은 0.
    static func won(_ amount: Double) -> Int {
        guard amount.isFinite, abs(amount) < 1e15 else { return 0 }
        return Int(amount.rounded())
    }

    /// `total`원을 `people` 자리마다 똑같이 원 단위로 나눈다. 남는 원은 낸 사람 자리부터, 그다음 목록 순서로 1원씩 준다. 합은 늘 `total`.
    static func even(_ total: Int, among people: [String], payer: String) -> [Int] {
        guard !people.isEmpty else { return [] }
        guard total >= 0 else { return even(-total, among: people, payer: payer).map { -$0 } }
        var shares = Array(repeating: total / people.count, count: people.count)
        var left = total % people.count
        let order = people.indices.filter { people[$0] == payer } + people.indices.filter { people[$0] != payer }
        for index in order where left > 0 {
            shares[index] += 1
            left -= 1
        }
        return shares
    }

    /// 송금 수를 줄인다. 큰 빚 ↔ 큰 받을 돈을 짝짓는 결과(같은 금액은 `order` 순서)를 기본으로 하고, 0이 아닌 사람이 4~12명이고
    /// 합이 0인 묶음 여럿으로 나뉠 때 묶음마다 짝지은 결과가 더 적을 때만 그것을 쓴다(k명 묶음은 k−1건).
    static func transfers(_ balances: [String: Int], order: [String]) -> [Transfer] {
        var seen = Set<String>()
        let names = (order + balances.keys.sorted()).filter { balances[$0] != nil && seen.insert($0).inserted }
        let nets = names.map { (name: $0, net: balances[$0] ?? 0) }
        let plain = greedy(nets)
        guard plain.count > 2, let groups = zeroSumGroups(nets), groups.count > 1 else { return plain }
        let grouped = groups.flatMap { greedy($0.map { nets[$0] }) }
        return grouped.count < plain.count ? grouped : plain
    }

    private typealias Side = (name: String, amount: Int, order: Int)

    static func greedy(_ nets: [(name: String, net: Int)]) -> [Transfer] {
        let first: (Side, Side) -> Bool = { $0.amount == $1.amount ? $0.order < $1.order : $0.amount > $1.amount }
        var creditors: [Side] = nets.enumerated().filter { $0.element.net > 0 }.map { ($0.element.name, $0.element.net, $0.offset) }.sorted(by: first)
        var debtors: [Side] = nets.enumerated().filter { $0.element.net < 0 }.map { ($0.element.name, -$0.element.net, $0.offset) }.sorted(by: first)
        var result: [Transfer] = []
        var creditor = 0, debtor = 0
        while creditor < creditors.count, debtor < debtors.count {
            let amount = min(creditors[creditor].amount, debtors[debtor].amount)
            result.append(Transfer(from: debtors[debtor].name, to: creditors[creditor].name, amount: amount))
            creditors[creditor].amount -= amount
            debtors[debtor].amount -= amount
            if creditors[creditor].amount == 0 { creditor += 1 }
            if debtors[debtor].amount == 0 { debtor += 1 }
        }
        return result
    }

    /// 0이 아닌 잔액을 합이 0인 묶음으로 가장 많이 나눈다(`nets` 자리 번호, 묶음 안은 목록 순서). 4~12명이 아니거나 합이 0이 아니면 nil.
    static func zeroSumGroups(_ nets: [(name: String, net: Int)]) -> [[Int]]? {
        let indices = nets.indices.filter { nets[$0].net != 0 }
        let units = indices.map { nets[$0].net }
        let count = indices.count
        guard count >= 4, count <= 12, units.reduce(0, +) == 0 else { return nil }
        let full = (1 << count) - 1
        var sums = [Int](repeating: 0, count: full + 1)
        for mask in 1...full { sums[mask] = sums[mask & (mask - 1)] + units[mask.trailingZeroBitCount] }
        // best[mask]: mask에서 한 명씩 빼 나갈 때 만날 수 있는 합 0 묶음의 최대 수.
        var best = [Int](repeating: 0, count: full + 1)
        for mask in 1...full {
            var value = 0, rest = mask
            while rest != 0 {
                let bit = rest & -rest
                value = max(value, best[mask ^ bit])
                rest ^= bit
            }
            best[mask] = value + (sums[mask] == 0 ? 1 : 0)
        }
        // 같은 사슬을 낮은 자리부터 거슬러 가며 합이 0이 될 때마다 묶음을 끊는다.
        var groups: [[Int]] = [], current: [Int] = [], mask = full
        while mask != 0 {
            let target = best[mask] - (sums[mask] == 0 ? 1 : 0)
            var rest = mask, chosen = -1
            while rest != 0 {
                let bit = rest & -rest
                if best[mask ^ bit] == target { chosen = bit.trailingZeroBitCount; break }
                rest ^= bit
            }
            guard chosen >= 0 else { return nil }
            current.append(chosen)
            mask ^= 1 << chosen
            if sums[mask] == 0 {
                groups.append(current.sorted().map { indices[$0] })
                current = []
            }
        }
        guard current.isEmpty else { return nil }
        return groups.sorted { ($0.first ?? 0) < ($1.first ?? 0) }
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
