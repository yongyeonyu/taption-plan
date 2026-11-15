import Foundation
import TaptionLedgerCore
import TaptionPlanStore
import TaptionTripShare

// 여행 공유의 가계부(TSH1114A26 묶음 C).
// - 정본은 로컬 가계부(`LedgerEntry`)다. 방의 공유 지출과 **내** 공개 개인 지출만 가계부에 투영하고,
//   남의 개인 지출은 방 사본에서만 읽는다(가계부·백업에 넣지 않는다).
// - **방에 올리는 것은 사용자가 지출 폼에서 고른 범위뿐이다.** 문자·알림·AI가 자동으로 넣은 지출은
//   `LedgerBook.save`로만 들어오고 이 파일의 `save`를 거치지 않으므로 올라가지 않는다(대표 결정).
// - 서버가 받아 준 뒤에만 로컬에 쓴다. 공유 ↔ 개인을 바꾸면 방에서는 지우고 새로 만들므로 로컬 번호도 새 UUID가 된다.
// - 공유 예산은 `view.meta?.budget`이고 `LedgerTrip.budgetKRW`(내 일상에서 보낸 돈)는 건드리지 않는다.

/// 지출의 공개 범위. 비공개는 방에 올리지 않는다.
enum TripShareExpenseScope: String, CaseIterable, Sendable {
    /// 공유 지출: 정산에 들어간다.
    case shared
    /// 개인 지출, 일행에게 보임. 정산에는 들어가지 않는다.
    case ownOpen
    /// 개인 지출, 이 기기에만.
    case ownHidden
}

/// 일행이 공개한 개인 지출 한 줄(방 사본에서만 읽는다).
struct TripShareOpenExpense: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let title: String
    let amount: Double
    let currency: String
    let at: Date
}

/// 방의 지출을 가계부에 투영하고, 가계부의 지출을 범위에 맞게 방에 올린다.
@MainActor
enum TripShareLedger {
    enum Failure: Equatable, Sendable {
        /// 인터넷이 없거나 방을 열지 못했다(보기만).
        case viewOnly
        /// 주인이 정산을 마감했다.
        case closed
        /// 다른 사람이 고치는 중이다.
        case locked
        /// 낸 사람·나눌 사람 가운데 방에 없는 이름이 있다.
        case unknownPerson
        /// 그 사이 다른 기기가 고쳤다. 화면은 이미 최신본이다.
        case conflict
        case failed
    }

    /// 투영할 장부. 시험이 바꿔 넣는다.
    static var book: LedgerBook = .shared
    /// 지난번에 본 방의 지출 항목(방 번호 → 항목 id). 사라진 것을 가계부에서도 지우는 데 쓴다.
    private static var known: [String: Set<String>] = [:]
    /// 지금 내가 방에서 내리거나 옮기는 기록. 그 사이의 투영이 먼저 지우지 않게 한다.
    private static var moving: Set<UUID> = []

    private static var store: TripShareStore { .shared }

    // MARK: 읽기

    /// 공유 여행의 기록인가. 그러면 지출 폼은 저장·지움을 여기로 보낸다.
    static func handles(_ entry: LedgerEntry) -> Bool {
        entry.transfer == nil && (entry.tripID.map(store.isShared) ?? false)
    }

    /// 방에 올릴 수 있는 기록인가: 지출만(수입·짝 기록·취소한 결제는 이 기기에만).
    static func canShare(_ entry: LedgerEntry) -> Bool {
        entry.kind == .expense && entry.transfer == nil && entry.canceledAt == nil
    }

    /// 지금 그 지출이 놓인 범위. 방 사본에 대응이 없으면 비공개다.
    static func scope(of entry: LedgerEntry) -> TripShareExpenseScope {
        guard let tripID = entry.tripID, let view = store.view(tripID: tripID) else { return .ownHidden }
        let id = TripShareMapping.roomItemID(entryID: entry.id)
        switch view.items.first(where: { $0.id == id })?.kind {
        case ShareKind.expenseShared.rawValue: return .shared
        case ShareKind.expenseOwn.rawValue: return .ownOpen
        default: return .ownHidden
        }
    }

    /// 새 지출 폼이 처음 보일 범위. **자동으로 들어온 지출은 늘 비공개**이고, 직접 넣는 지출만 여행 기본값(「내 지출 전부 공유」)을 따른다.
    static func defaultScope(for entry: LedgerEntry) -> TripShareExpenseScope {
        guard entry.source == .manual, canShare(entry), let tripID = entry.tripID, let view = store.view(tripID: tripID),
              view.meta?.shareAllExpenses == true, !view.closed else { return .ownHidden }
        return .shared
    }

    /// 일행이 공개한 개인 지출(내 것 빼고, 새것부터).
    static func openExpenses(of view: ShareRoomView, names: TripShareNames) -> [TripShareOpenExpense] {
        view.items(of: .expenseOwn).compactMap { item -> TripShareOpenExpense? in
            guard item.createdBy != view.me, case .ownExpense(let content) = item.content else { return nil }
            return TripShareOpenExpense(
                id: item.id, name: names.name(.member(item.createdBy)), title: content.memo ?? "",
                amount: TripShareMapping.amount(minorUnits: content.amount, currency: content.currency), currency: content.currency,
                at: Date(timeIntervalSince1970: TimeInterval(content.at) / 1000)
            )
        }
        .sorted { ($0.at, $0.id) > ($1.at, $1.id) }
    }

    // MARK: 쓰기

    /// 방을 연다(이미 열려 있으면 그것). 가계부만 열었을 때도 범위를 읽고 올릴 수 있게 한다.
    @discardableResult
    static func open(tripID: String) async -> (session: ShareRoomSession, view: ShareRoomView)? {
        guard store.isShared(tripID) else { return nil }
        if store.session(tripID: tripID) == nil, let session = await store.open(tripID: tripID) {
            try? await session.catchUp()
            // 연결이 맺어지는 동안만 잠깐(많아야 2초) 기다린다. 인터넷이 없으면 바로 보기만으로 넘어간다.
            for _ in 0..<20 where await session.view().status == .connecting { try? await Task.sleep(for: .milliseconds(100)) }
            await store.refresh(tripID: tripID)
        }
        guard let session = store.session(tripID: tripID), let view = store.view(tripID: tripID) else { return nil }
        return (session, view)
    }

    /// 지출을 고른 범위로 저장한다. 방에 올리거나 내릴 것이 있으면 서버가 받아 준 뒤에만 가계부에 쓴다.
    /// 공유하지 않는 여행이면 그대로 가계부에 쓴다.
    @discardableResult
    static func save(_ entry: LedgerEntry, scope wanted: TripShareExpenseScope) async -> Failure? {
        guard let tripID = entry.tripID, handles(entry) else {
            await keep(entry)
            return nil
        }
        let room = await open(tripID: tripID)
        let scope = canShare(entry) ? wanted : .ownHidden
        let current = Self.scope(of: entry)
        var value = entry
        if value.amountKRW == nil { value.amountKRW = book.krw(value.amount, currency: value.currency) }
        guard scope != .ownHidden || current != .ownHidden else {
            // 방과 상관없는 기록: 인터넷이 없어도 된다.
            if canShare(value) { privatize(&value) }
            await keep(value)
            return nil
        }
        guard let room, room.view.canWrite, let names = store.names(tripID: tripID) else { return .viewOnly }
        let oldID = TripShareMapping.roomItemID(entryID: entry.id)
        var edits: [ShareEdit] = []
        if current != .ownHidden, current != scope {
            // 범위가 바뀌면 방의 종류가 바뀐다: 지우고 새 번호로 만든다(지운 번호는 다시 쓰지 못한다).
            edits.append(.delete(id: oldID))
            value.id = UUID()
        }
        let newID = TripShareMapping.roomItemID(entryID: value.id)
        switch scope {
        case .shared:
            guard !room.view.closed else { return .closed }
            guard let content = TripShareMapping.sharedExpense(value, names: names, by: room.view.me) else { return .unknownPerson }
            edits.append(current == .shared ? .update(id: oldID, content: .sharedExpense(content)) : .create(id: newID, content: .sharedExpense(content), group: nil))
            value = TripShareMapping.entry(content, roomItemID: newID, tripID: tripID, names: names, existing: value) ?? value
        case .ownOpen:
            guard let content = TripShareMapping.ownExpense(value, by: room.view.me) else { return .failed }
            edits.append(current == .ownOpen ? .update(id: oldID, content: .ownExpense(content)) : .create(id: newID, content: .ownExpense(content), group: nil))
            value = TripShareMapping.entry(content, roomItemID: newID, tripID: tripID, existing: value) ?? value
        case .ownHidden:
            privatize(&value)
        }
        moving.insert(entry.id)
        defer { moving.remove(entry.id) }
        if let failure = await send(edits, locking: current == .shared ? [oldID] : [], session: room.session, tripID: tripID) { return failure }
        if value.id != entry.id { await book.delete(entry.id) }
        await keep(value)
        return nil
    }

    /// 지출을 지운다. 방에 있는 것이면 방에서 먼저 지운다.
    @discardableResult
    static func remove(_ entry: LedgerEntry) async -> Failure? {
        guard let tripID = entry.tripID, handles(entry) else {
            await book.remove(entry)
            return nil
        }
        let room = await open(tripID: tripID)
        let current = scope(of: entry)
        if current != .ownHidden {
            guard let room, room.view.canWrite else { return .viewOnly }
            guard current != .shared || !room.view.closed else { return .closed }
            let id = TripShareMapping.roomItemID(entryID: entry.id)
            moving.insert(entry.id)
            defer { moving.remove(entry.id) }
            if let failure = await send([.delete(id: id)], locking: current == .shared ? [id] : [], session: room.session, tripID: tripID) { return failure }
        }
        await book.remove(entry)
        return nil
    }

    /// 목록에서 밀어 지울 때: 못 지웠으면 까닭을 공유 안내 글로 남긴다.
    static func remove(_ entry: LedgerEntry, alertingIn language: MapHomeLanguage) async {
        if let failure = await remove(entry) { store.notice = failure.message(language) }
    }

    /// 공유 예산(원)을 고친다. 주인만 된다. **내 여행 장부의 예산(`LedgerTrip.budgetKRW`)은 그대로다.**
    @discardableResult
    static func setSharedBudget(_ budget: Int?, tripID: String) async -> Failure? {
        guard let room = await open(tripID: tripID), room.view.canWrite, room.view.isOwner, var meta = room.view.meta else { return .viewOnly }
        meta.budget = budget.flatMap { $0 > 0 ? $0 : nil }
        do {
            guard try await room.session.publish(meta: meta) == .done else { return .conflict }
        } catch { return failure(error) }
        await store.refresh(tripID: tripID)
        return nil
    }

    /// 비공개·개인 지출의 몫은 나만이다. 비워 두면 기존 계산이 「다 같이」로 나눈다.
    private static func privatize(_ entry: inout LedgerEntry) {
        entry.payer = nil
        entry.shareNames = TripShareMapping.privateShare
    }

    private static func keep(_ entry: LedgerEntry) async {
        await book.save(entry)
        if let tripID = entry.tripID { await book.syncTrip(tripID) }
    }

    /// 공유 지출을 고치거나 지울 때는 그 항목을 잠그고 쓴 뒤 푼다. 한 번에 보낸 것은 전부 되거나 전부 안 된다.
    private static func send(_ edits: [ShareEdit], locking ids: [String], session: ShareRoomSession, tripID: String) async -> Failure? {
        guard !edits.isEmpty else { return nil }
        var result: Failure?
        do {
            if !ids.isEmpty { try await session.lock(items: ids) }
            if try await session.write(edits) != .done { result = .conflict }
        } catch { result = failure(error) }
        if !ids.isEmpty { try? await session.unlock(items: ids) }
        await store.refresh(tripID: tripID)
        return result
    }

    static func failure(_ error: any Error) -> Failure {
        guard let error = error as? ShareError else { return .failed }
        switch error {
        case .readOnly(.settlementClosed): return .closed
        case .readOnly, .offline, .transport, .interrupted: return .viewOnly
        default: break
        }
        switch error.serverCode {
        case .settlementClosed: return .closed
        case .locked, .lockRequired: return .locked
        case .conflict: return .conflict
        default: return .failed
        }
    }

    // MARK: 투영

    static func roomChanged(model: AppModel, link: TripShareLink, view: ShareRoomView, event: ShareSessionEvent) async {
        guard link.phase != .ended else {
            known[link.roomID] = nil
            return
        }
        var removed: [String] = []
        switch event {
        case .locks: return
        case .status(let status) where status != .live:
            if known[link.roomID] == nil { known[link.roomID] = expenseIDs(view) }
            return
        case .items(_, let gone): removed = gone
        default: break
        }
        await project(tripID: link.tripID, roomID: link.roomID, view: view, removed: removed)
    }

    private static func expenseIDs(_ view: ShareRoomView) -> Set<String> {
        Set(view.items.filter { projects($0, me: view.me) }.map(\.id))
    }

    /// 가계부에 넣는 방 항목: 공유 지출 전부와 내 공개 개인 지출.
    private static func projects(_ item: ShareLocalItem, me: Int) -> Bool {
        item.kind == ShareKind.expenseShared.rawValue || (item.kind == ShareKind.expenseOwn.rawValue && item.createdBy == me)
    }

    /// 방의 지출을 가계부에 맞춘다: 넣고, 고치고, 방에서 사라진 것은 지운다. 닉네임이 바뀌었으면 이름도 다시 쓴다.
    /// 값이 그대로면 쓰지 않는다. **방에 없는 로컬 기록(비공개·자동 기록)은 지우지도 올리지도 않는다.**
    static func project(tripID: String, roomID: String, view: ShareRoomView, removed: [String] = []) async {
        await book.load()
        let names = TripShareNames(me: view.me, cards: view.cards, guests: view.meta?.guests ?? [])
        var touched = false
        for item in view.items where projects(item, me: view.me) {
            guard let id = TripShareMapping.entryID(roomItemID: item.id), !moving.contains(id) else { continue }
            let existing = book.entries.first { $0.id == id }
            var projected: LedgerEntry?
            switch item.content {
            case .sharedExpense(let content): projected = TripShareMapping.entry(content, roomItemID: item.id, tripID: tripID, names: names, existing: existing)
            case .ownExpense(let content): projected = TripShareMapping.entry(content, roomItemID: item.id, tripID: tripID, existing: existing)
            default: break
            }
            // 원화 환산이 방에 없으면 이 기기가 채워 둔 값을 지킨다(매번 다시 쓰지 않게).
            if projected?.amountKRW == nil { projected?.amountKRW = existing?.amountKRW }
            guard let projected, projected != existing else { continue }
            await ensureTrip(tripID, view: view)
            await book.save(projected)
            touched = true
        }
        let live = expenseIDs(view)
        let gone = (known[roomID] ?? []).subtracting(live).union(removed).subtracting(live)
        known[roomID] = live
        for id in gone.compactMap(TripShareMapping.entryID(roomItemID:)) where !moving.contains(id) {
            guard let entry = book.entries.first(where: { $0.id == id && $0.tripID == tripID }) else { continue }
            await book.delete(entry.id)
            touched = true
        }
        // 방에 없는 지출은 내 것이다: 「다 같이」로 비어 있으면 나만으로 고정한다.
        for entry in book.tripEntries(tripID) where entry.shareNames == nil && canShare(entry) && !moving.contains(entry.id)
            && !live.contains(TripShareMapping.roomItemID(entryID: entry.id)) {
            var value = entry
            value.shareNames = TripShareMapping.privateShare
            await book.save(value)
            touched = true
        }
        guard var trip = book.trip(tripID) else { return }
        // 동행은 방 사람들의 이름표를 따른다. 공유 전에 적어 둔 이름은 그 이름을 쓰는 기록이 남아 있는 동안만 둔다.
        let used = Set(book.tripEntries(tripID).flatMap { [$0.payer].compactMap { $0 } + ($0.shareNames ?? []) })
        let members = names.others + trip.members.filter { !names.others.contains($0) && used.contains($0) }
        if trip.members != members {
            trip.members = members
            await book.saveTrip(trip)
        } else if touched, trip.hasEnded(asOf: .now, calendar: .autoupdatingCurrent) {
            // 끝난 여행이면 정산 짝 기록을 다시 맞춘다. 여행 중에는 예산 이체가 그대로라 맞출 것이 없다.
            await book.syncTrip(tripID)
        }
    }

    /// 투영할 지출이 있는데 여행 장부가 없으면 여행 정보로 만든다(초대로 들어온 사람). 예산은 넣지 않는다.
    private static func ensureTrip(_ tripID: String, view: ShareRoomView, calendar: Calendar = .autoupdatingCurrent) async {
        guard book.trip(tripID) == nil, let meta = view.meta else { return }
        let start = TravelTripDay.components(meta.startDay).flatMap(calendar.date(from:)) ?? .now
        let end = TravelTripDay.components(meta.endDay).flatMap(calendar.date(from:)) ?? start
        await book.saveTrip(LedgerTrip(id: tripID, name: meta.name, start: start, end: max(start, end)))
    }
}

extension TripShareLedger.Failure {
    func message(_ language: MapHomeLanguage) -> String {
        switch self {
        case .viewOnly: TripShareText.viewOnly(language)
        case .closed: language.text("정산을 마감해서 공동 지출은 바꿀 수 없어요.", "Settlement is closed, so shared expenses can't be changed.")
        case .locked: language.text("다른 사람이 고치는 중이에요. 잠시 뒤에 다시 해 주세요.", "Someone else is editing this. Try again in a moment.")
        case .unknownPerson: language.text("낸 사람이나 나눌 사람 가운데 이 여행에 없는 이름이 있어요.", "Someone in Paid by or For whom isn't in this trip.")
        case .conflict: language.text("그 사이 다른 사람이 고쳤어요. 최신 내용을 확인하고 다시 해 주세요.", "Someone else changed this meanwhile. Check the latest and try again.")
        case .failed: language.text("저장하지 못했어요. 잠시 뒤에 다시 해 주세요.", "Couldn't save. Try again in a moment.")
        }
    }
}
