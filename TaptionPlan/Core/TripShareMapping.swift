import Foundation
import TaptionLedgerCore
import TaptionPlanStore
import TaptionTripShare

/// 방 사람들의 이름표(TSH1114A26): 참여자 번호·앱 없는 일행 ⇄ 가계부가 쓰는 이름 글자.
/// 같은 닉네임은 번호 순으로 「가을」「가을 (2)」처럼 가른다. 나는 가계부에서 `LedgerTrip.me`다.
/// 나간 사람은 서버가 카드를 지우므로 `former`(방에서 본 지난 이름)로 찾는다. 새로 고를 사람(`parties`)에는 넣지 않는다.
struct TripShareNames: Equatable, Sendable {
    let me: Int
    private(set) var names: [ShareParty: String] = [:]
    /// 지금 방에 있는 사람(카드가 있는 참여자와 앱 없는 일행).
    private var present: Set<ShareParty> = []

    init(me: Int, cards: [Int: ShareMemberCard], guests: [ShareGuest] = [], former: [Int: String] = [:]) {
        self.me = me
        var seen: [String: Int] = [:]
        let people = cards.map { (ShareParty.member($0.key), $0.value.name) } + guests.map { (ShareParty.guest($0.id), $0.name) }
        present = Set(people.map(\.0))
        let gone = former.filter { cards[$0.key] == nil }.map { (ShareParty.member($0.key), $0.value) }
        for (party, raw) in (people + gone).sorted(by: { $0.0 < $1.0 }) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty || trimmed == LedgerTrip.me ? party.code : trimmed
            seen[name, default: 0] += 1
            names[party] = seen[name] == 1 ? name : "\(name) (\(seen[name] ?? 2))"
        }
    }

    /// 지금 방에 있는 사람: 참여자 번호 순, 그다음 앱 없는 일행.
    var parties: [ShareParty] { present.sorted() }

    /// 화면에 보일 이름(나도 내 닉네임).
    func name(_ party: ShareParty) -> String { names[party] ?? party.code }

    /// 가계부에 적는 이름: 나는 `@me`.
    func ledgerName(_ party: ShareParty) -> String { party == .member(me) ? LedgerTrip.me : name(party) }

    /// 가계부의 이름에서 사람을 찾는다. 비었거나 `@me`면 나. 이름이 없던 때 적힌 번호(`m3`)도 읽는다.
    func party(ledgerName: String?) -> ShareParty? {
        guard let ledgerName, !ledgerName.isEmpty, ledgerName != LedgerTrip.me else { return .member(me) }
        return names.first { $0.value == ledgerName }?.key ?? ShareParty(code: ledgerName)
    }

    /// `LedgerTrip.members`에 투영할 이름들(나 빼고).
    var others: [String] { parties.filter { $0 != .member(me) }.map(name) }
}

/// 여행 공유(TSH1114A26)의 순수 변환: 로컬 자료 ⇄ 방 평문, id 계산. 저장·통신을 모른다.
/// **좌표는 어느 방향으로도 싣지 않는다**(대표 결정: 장소는 이름만). 로컬의 핀·깃발 좌표는 그 기기에만 남는다.
enum TripShareMapping {
    // MARK: id

    /// 초대로 들어온 여행의 로컬 여행 번호.
    static func joinedTripID(roomID: String) -> String { "s-" + roomID }

    /// 일정의 방 항목 id. 방에서 처음 만든 일정은 로컬 번호가 곧 방 id(무작위 16바이트의 22자)이고,
    /// 공유 전부터 있던 일정(`m-…`·AI가 준 번호)은 `SHA256(tripID|itemID)` 앞 16바이트로 늘 같은 id가 나온다.
    static func roomItemID(tripID: String, itemID: String) -> String {
        ShareIdentifiers.uuid(itemID: itemID) != nil ? itemID : ShareIdentifiers.itemID(tripID: tripID, itemID: itemID)
    }

    /// 방 항목 id에 맞는 로컬 일정 번호. 이 기기에 그 일정이 없으면 방 id를 그대로 쓴다(표를 두지 않는다).
    static func localItemID(roomItemID: String, tripID: String, items: [TravelTripItem]) -> String {
        items.first { $0.tripID == tripID && self.roomItemID(tripID: tripID, itemID: $0.itemID) == roomItemID }?.itemID ?? roomItemID
    }

    /// 지출의 방 항목 id ⇄ `LedgerEntry.id`. 공유 ↔ 개인을 바꾸면 지우고 새로 만드므로 새 UUID가 된다.
    static func roomItemID(entryID: UUID) -> String { ShareIdentifiers.itemID(uuid: entryID) }
    static func entryID(roomItemID: String) -> UUID? { ShareIdentifiers.uuid(itemID: roomItemID) }

    // MARK: 일정

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    private static func midnight(_ day: String) -> Date? { TravelTripDay.components(day).flatMap(utc.date(from:)) }

    /// 방에서 받아 로컬에 넣을 일정 하나. `planID`는 투영할 때 붙는다. `place`는 이름뿐이다.
    struct PlanDraft: Equatable, Sendable {
        var item: TravelTripItem
        var place: String?
    }

    /// 방에 싣는 메모의 바이트 한도. 이모지로 500자를 채워도 방 한 칸(4KB, 잠근 뒤)에 들어가게 한다.
    static let memoBytes = 2_000

    /// 글자(문자소)를 자르지 않고 UTF-8 `bytes` 안으로 줄인다.
    static func clipped(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var out = "", used = 0
        for character in text {
            let size = character.utf8.count
            guard used + size <= bytes else { break }
            out.append(character)
            used += size
        }
        return out
    }

    /// 일정 → 방 평문. `place`는 그 일정의 장소 이름(핀 이름)만 넘긴다.
    /// 분은 `day`(시작의 현지 날짜) 0시부터 센 벽시계 분이고, 끝은 끝 쪽 시차의 벽시계라 자정을 넘으면 1,440을 넘는다.
    static func plan(_ item: TravelTripItem, place: String? = nil, order: Int? = nil, by: Int? = nil) -> SharePlanContent {
        let day = TravelTripDay.string(for: item.start, offsetSeconds: item.startOffsetSeconds)
        let base = midnight(day) ?? item.start
        func minute(_ date: Date, _ offset: Int) -> Int {
            Int((date.addingTimeInterval(TimeInterval(offset)).timeIntervalSince(base) / 60).rounded())
        }
        let name = place?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SharePlanContent(
            day: day, start: minute(item.start, item.startOffsetSeconds), end: minute(item.end, item.endOffsetSeconds),
            startOffset: item.startOffsetSeconds / 60, endOffset: item.endOffsetSeconds / 60, title: item.title,
            place: name?.isEmpty == false ? name : nil, memo: item.note.map { clipped($0, bytes: memoBytes) },
            cost: item.plannedSpendKRW.map { Int($0.rounded()) }, currency: item.plannedSpendKRW == nil ? nil : ShareSettlementCalculator.baseCurrency,
            order: order, planKind: item.kind, status: item.status, colorHex: item.colorHex,
            parentItemID: item.parentItemID.map { roomItemID(tripID: item.tripID, itemID: $0) }, by: by
        )
    }

    /// 방 평문 → 로컬 일정. 이미 있는 일정이면 그 번호와 `planID`를 지킨다. 날짜를 못 읽거나 끝이 시작보다 앞이면 nil.
    /// - Parameter fallbackOffsetSeconds: 평문에 시차가 없을 때 쓸 값(여행 시간대).
    static func draft(
        _ content: SharePlanContent, roomItemID: String, tripID: String, existing: [TravelTripItem], fallbackOffsetSeconds: Int = 0
    ) -> PlanDraft? {
        guard let base = midnight(content.day) else { return nil }
        // 방의 값은 믿지 않는다: 분·시차가 하루 안팎의 상식 범위를 벗어나면 읽지 않는다(곱셈이 넘치지 않게).
        let minutes = [content.start, content.end, content.startOffset, content.endOffset].compactMap { $0 }
        guard minutes.allSatisfy({ abs($0) <= 10_000_000 }) else { return nil }
        let startOffset = content.startOffset.map { $0 * 60 } ?? fallbackOffsetSeconds
        let endOffset = content.endOffset.map { $0 * 60 } ?? startOffset
        let startMinute = content.start ?? 0
        let endMinute = content.end ?? startMinute + 60
        let start = base.addingTimeInterval(TimeInterval(startMinute * 60 - startOffset))
        let end = base.addingTimeInterval(TimeInterval(endMinute * 60 - endOffset))
        guard end > start else { return nil }
        let localID = localItemID(roomItemID: roomItemID, tripID: tripID, items: existing)
        let old = existing.first { $0.tripID == tripID && $0.itemID == localID }
        let kind = content.planKind.flatMap { TravelPlanColumns.allKinds.contains($0) ? $0 : nil } ?? "other"
        let title = content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let memo = content.memo?.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = TravelTripItem(
            tripID: tripID, itemID: localID, kind: kind, title: title.isEmpty ? kind : title, start: start, end: end,
            startOffsetSeconds: startOffset, endOffsetSeconds: endOffset, planID: old?.planID,
            status: content.status.flatMap { TravelVisitMark.isStorable($0) ? $0 : nil },
            note: memo?.isEmpty == false ? memo.map { String($0.prefix(500)) } : nil,
            colorHex: TravelTripItem.cleanColorHex(content.colorHex),
            plannedSpendKRW: TravelTripItem.cleanPlannedSpend(content.cost.map(Double.init)),
            parentItemID: content.parentItemID.map { localItemID(roomItemID: $0, tripID: tripID, items: existing) }
        )
        return PlanDraft(item: item, place: content.place)
    }

    // MARK: 지출

    /// 소수 자리가 없는 통화(가장 작은 단위가 1). 그 밖은 1/100.
    private static let wholeCurrencies: Set<String> = ["KRW", "JPY", "VND", "IDR", "CLP", "ISK", "HUF", "TWD", "PYG", "UGX", "XAF", "XOF", "XPF"]

    static func minorUnits(_ amount: Double, currency: String) -> Int {
        clampedWhole(amount * (wholeCurrencies.contains(currency.uppercased()) ? 1 : 100))
    }

    /// 정수로 바꾼다. 유한하지 않거나 터무니없이 크면 정산이 거르는 상한으로 맞춘다(`Int(inf)`는 앱을 멈춘다).
    static func clampedWhole(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let limit = Double(ShareSettlementCalculator.maxAmount)
        return Int(min(max(value.rounded(), -limit), limit))
    }

    static func amount(minorUnits: Int, currency: String) -> Double {
        Double(minorUnits) / (wholeCurrencies.contains(currency.uppercased()) ? 1 : 100)
    }

    private static func milliseconds(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(milliseconds: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000) }

    /// 공유 여행의 비공개·개인 지출이 가져야 하는 몫: 나만(비워 두면 기존 계산이 「다 같이」로 나눈다).
    static let privateShare = [LedgerTrip.me]

    /// 지출 → 공유 지출 평문. 수입·짝 기록·취소한 결제는 올리지 않고(nil), 모르는 이름이 있으면 nil.
    /// 「다 같이」(`shareNames == nil`)는 **지금의 사람들**을 그대로 적는다(나중에 들어온 사람에게 몫이 생기지 않게).
    static func sharedExpense(_ entry: LedgerEntry, names: TripShareNames, by: Int? = nil) -> ShareExpenseContent? {
        guard entry.kind == .expense, entry.transfer == nil, entry.canceledAt == nil, let payer = names.party(ledgerName: entry.payer) else { return nil }
        let split = entry.shareNames.map { $0.compactMap(names.party(ledgerName:)) } ?? names.parties
        guard split.count == (entry.shareNames?.count ?? names.parties.count), !split.isEmpty else { return nil }
        return ShareExpenseContent(
            title: entry.title, amount: minorUnits(entry.amount, currency: entry.currency), currency: entry.currency,
            amountKRW: entry.amountKRW.map(clampedWhole), payer: payer, split: split.sorted(),
            category: entry.category.rawValue, memo: entry.note, at: milliseconds(entry.occurredAt), by: by
        )
    }

    /// 공유 지출 평문 → 가계부 기록. 방 id가 UUID 모양이 아니면 nil. 이미 있는 기록이면 로컬에만 있는 칸(장소·메모 연결·출처)을 지킨다.
    static func entry(_ content: ShareExpenseContent, roomItemID: String, tripID: String, names: TripShareNames, existing: LedgerEntry? = nil) -> LedgerEntry? {
        guard let id = entryID(roomItemID: roomItemID) else { return nil }
        var entry = existing ?? LedgerEntry(id: id, occurredAt: date(milliseconds: content.at), amount: 0, title: "")
        entry.occurredAt = date(milliseconds: content.at)
        entry.amount = amount(minorUnits: content.amount, currency: content.currency)
        entry.currency = content.currency
        entry.amountKRW = content.amountKRW.map(Double.init)
        entry.kind = .expense
        entry.category = content.category.flatMap(LedgerCategory.init(rawValue:)) ?? .other
        entry.title = content.title ?? ""
        entry.note = content.memo
        entry.tripID = tripID
        entry.payer = content.payer == .member(names.me) ? nil : names.name(content.payer)
        // 나눌 사람이 비면 낸 사람 혼자 진 것이다(패키지 정산과 같게).
        entry.shareNames = (content.split.isEmpty ? [content.payer] : content.split).map(names.ledgerName)
        return entry
    }

    /// 내 개인 지출 가운데 공개한 것 → 평문. 제목은 메모 칸에 싣는다(평문에 제목 칸이 없다).
    static func ownExpense(_ entry: LedgerEntry, by: Int? = nil) -> ShareOwnExpenseContent? {
        guard entry.kind == .expense, entry.transfer == nil, entry.canceledAt == nil else { return nil }
        return ShareOwnExpenseContent(
            amount: minorUnits(entry.amount, currency: entry.currency), currency: entry.currency,
            category: entry.category.rawValue, memo: entry.title.isEmpty ? entry.note : entry.title, at: milliseconds(entry.occurredAt), by: by
        )
    }

    /// **내** 공개 개인 지출을 가계부 기록으로(다른 기기에서 넣은 내 것). 남의 개인 지출은 가계부에 넣지 않고 곁 파일에서만 읽는다.
    static func entry(_ content: ShareOwnExpenseContent, roomItemID: String, tripID: String, existing: LedgerEntry? = nil) -> LedgerEntry? {
        guard let id = entryID(roomItemID: roomItemID) else { return nil }
        var entry = existing ?? LedgerEntry(id: id, occurredAt: date(milliseconds: content.at), amount: 0, title: content.memo ?? "")
        entry.occurredAt = date(milliseconds: content.at)
        entry.amount = amount(minorUnits: content.amount, currency: content.currency)
        entry.currency = content.currency
        if content.currency == ShareSettlementCalculator.baseCurrency { entry.amountKRW = entry.amount }
        entry.kind = .expense
        entry.category = content.category.flatMap(LedgerCategory.init(rawValue:)) ?? .other
        entry.tripID = tripID
        entry.payer = nil
        entry.shareNames = privateShare
        return entry
    }

    // MARK: 여행 정보

    /// 열 구성 한 줄: `종류,종류:이름`.
    private static func columnText(_ column: TravelTripColumn) -> String { column.kinds.joined(separator: ",") + ":" + column.name }

    private static func column(_ text: String) -> TravelTripColumn? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let kinds = text[..<colon].split(separator: ",").map(String.init)
        return kinds.isEmpty ? nil : TravelTripColumn(name: String(text[text.index(after: colon)...]), kinds: kinds)
    }

    /// 여행 → `meta`. 깃발 좌표·깃발 색은 싣지 않는다. 공유 예산·앱 없는 일행·정산 안 함은 방에만 있는 값이라 따로 받는다.
    static func meta(
        _ trip: TravelTrip, budget: Int? = nil, guests: [ShareGuest] = [], settlementOff: Bool? = nil, shareAllExpenses: Bool? = nil
    ) -> ShareTripMeta {
        ShareTripMeta(
            name: trip.title, startDay: trip.startDay, endDay: trip.endDay, currency: trip.currencyCode ?? ShareSettlementCalculator.baseCurrency,
            budget: budget, guests: guests, settlementOff: settlementOff, country: trip.countryCode, region: trip.regionName,
            timeZone: trip.timeZoneID, columns: trip.columns?.map(columnText), shareAllExpenses: shareAllExpenses
        )
    }

    /// `meta` → 로컬 여행. 이미 있는 여행이면 이 기기의 깃발 좌표·색을 지킨다. 원화 여행은 통화 칸을 비운다(국내 여행과 같은 뜻).
    static func trip(_ meta: ShareTripMeta, id: String, existing: TravelTrip? = nil) -> TravelTrip {
        var trip = existing ?? TravelTrip(id: id, title: meta.name, startDay: meta.startDay, endDay: meta.endDay)
        trip.title = meta.name
        trip.startDay = meta.startDay
        trip.endDay = meta.endDay
        if !meta.startDay.isEmpty { trip.wishDays = nil }
        trip.currencyCode = meta.currency == ShareSettlementCalculator.baseCurrency ? nil : meta.currency
        trip.countryCode = meta.country
        trip.regionName = meta.region
        trip.timeZoneID = meta.timeZone
        let columns = meta.columns?.compactMap(column)
        trip.columns = columns?.isEmpty == false ? columns : nil
        return trip
    }
}
