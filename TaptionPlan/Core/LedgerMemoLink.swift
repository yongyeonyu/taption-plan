import Foundation

/// 메모와 가계부를 한 입력으로(LED1111A03, 대표 결정: 화면만 합치기·금액은 자동으로 지출).
/// 메모 글에서 금액을 알아보면 그 메모에 이어진 가계부 기록을 만들거나 고친다. 저장은 가계부 기록 그대로다.
enum LedgerMemoAmount {
    struct Found: Equatable, Sendable {
        var amount: Double
        var currency: String
        var kind: LedgerEntry.Kind
        var title: String
    }

    private static let currencyCodes = ["USD", "JPY", "EUR", "CNY", "TWD", "HKD", "THB", "VND", "SGD", "PHP", "IDR", "GBP", "AUD", "CAD"]
    /// 숫자 뒤에 붙으면 금액이 아니다(시각·차례·층·사람 수·거리 등).
    /// 이 낱말이 있으면 통화 표시 없는 숫자를 금액으로 보지 않는다.
    private static let notMoneyWords = ["비번", "비밀번호", "번호", "코드", "계좌", "주문", "인증", "우편", "사번", "학번", "버스", "호선", "출구", "좌석", "게이트"]
    /// 늘 숫자가 금액이 아닌 낱말(비번·코드·계좌 등). 「주문」·「버스」는 둥근 값이면 금액으로 본다(「커피 주문 4500」·「버스비 1500」).
    private static let codeWords = ["비번", "비밀번호", "번호", "코드", "계좌", "인증", "우편", "사번", "학번", "호선", "출구", "좌석", "게이트"]
    private static let notMoneyUnits = ["시", "분", "초", "번", "층", "호", "명", "개", "살", "세", "km", "m", "kg", "g", "%", "일", "월", "년", "차", "회", "점", "등", "위", "cm", "mm", "ml", "l", "보", "걸음", "kcal", "칼로리", "장", "권", "곡", "편", "p"]

    static func find(_ text: String) -> Found? {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        guard line.count <= 200 else { return nil }
        let income = line.hasPrefix("+") || ["월급", "급여", "수입", "용돈 받"].contains(where: line.contains)
        // 1) 통화 표시가 붙은 금액
        if let match = line.firstMatch(of: /([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)\s*원/), let value = LedgerMessageParser.number(String(match.1)), value > 0 {
            return found(value, "KRW", income, line, String(match.0))
        }
        if let match = line.firstMatch(of: /₩\s*([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)/), let value = LedgerMessageParser.number(String(match.1)), value > 0 {
            return found(value, "KRW", income, line, String(match.0))
        }
        if let match = line.firstMatch(of: /\$\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)/), let value = LedgerMessageParser.number(String(match.1)), value > 0 {
            return found(value, "USD", income, line, String(match.0))
        }
        // 글자 단위 정규식 하나로 「USD 12」·「1200 JPY」를 찾는다(글자를 칠 때마다 정규식을 새로 만들지 않게).
        for match in line.matches(of: /([A-Z]{3})\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)|([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*([A-Z]{3})/) {
            guard let code = (match.1 ?? match.4).map(String.init), currencyCodes.contains(code),
                  let digits = (match.2 ?? match.3).map(String.init), let value = LedgerMessageParser.number(digits), value > 0 else { continue }
            return found(value, code, income, line, String(match.0))
        }
        // 2) 통화 표시 없는 숫자: 1,000 이상이고 날짜·시각·전화번호·단위가 아닌 낱말 하나
        // 전화번호가 든 글에서는 통화 표시 없는 숫자를 금액으로 보지 않는다.
        if line.contains(/01[016789][ \-]?[0-9]{3,4}[ \-]?[0-9]{4}/) { return nil }
        let joiners: Set<Character> = [":", "/", ".", "-"]
        for match in line.matches(of: /[0-9]{1,3}(?:,[0-9]{3})+|[0-9]{3,}/) {
            // 앞뒤가 숫자·:·/·.·-로 이어지면 시각·날짜·전화번호다.
            let before = match.range.lowerBound > line.startIndex ? line[line.index(before: match.range.lowerBound)] : " "
            let next = match.range.upperBound < line.endIndex ? line[match.range.upperBound] : " "
            guard !joiners.contains(before), !joiners.contains(next), !before.isNumber, match.output.count <= 13 else { continue }
            // 단위는 숫자에 붙어 있을 때만 본다(「4500 시원한 커피」·「4500 latte」는 금액). 영문 단위는 낱말이 끝나야 단위다.
            let after = line[match.range.upperBound...].lowercased()
            let isUnit = notMoneyUnits.contains { unit in
                guard after.hasPrefix(unit) else { return false }
                guard unit.first?.isASCII == true, let next = after.dropFirst(unit.count).first else { return true }
                return !next.isLetter
            }
            guard !isUnit else { continue }
            // 번호·비번·코드·계좌 같은 낱말이 숫자 바로 앞(여덟 글자 안)에 있으면 금액이 아니다(「현관 비번 482915」).
            // 낱말이 멀리 있으면 금액이다(「커피 주문 4500」은 주문 뒤에 바로 숫자가 와도 원 단위 값이라 아래에서 다시 본다).
            let lead = String(line[..<match.range.lowerBound].suffix(8)).lowercased()
            if notMoneyWords.contains(where: lead.contains), !match.output.contains(","),
               !(match.output.count <= 6 && (LedgerMessageParser.number(String(match.output)) ?? 1).truncatingRemainder(dividingBy: 100) == 0 && !Self.codeWords.contains(where: lead.contains)) { continue }
            guard let value = LedgerMessageParser.number(String(match.output)), value >= 1_000, value <= 1e10 else { continue }
            // 쉼표 없는 숫자는 원 단위 값처럼 10으로 나눠떨어지고 일곱 자리 이하일 때만 금액이다(편의점 4950은 금액, 7016·482915·연도 2026은 아님).
            if !match.output.contains(",") {
                guard value.truncatingRemainder(dividingBy: 10) == 0, value < 10_000_000, !(1_900...2_100).contains(value) else { continue }
            }
            return found(value, "KRW", income, line, String(match.0))
        }
        return nil
    }

    private static func found(_ amount: Double, _ currency: String, _ income: Bool, _ line: String, _ token: String) -> Found? {
        var title = line.replacingOccurrences(of: token, with: " ")
        if title.hasPrefix("+") { title.removeFirst() }
        title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        guard !title.isEmpty else { return nil }
        return Found(amount: amount, currency: currency, kind: income ? .income : .expense, title: String(title.prefix(60)))
    }
}

/// 메모마다 「메모로만」을 고른 것. 기기에만 둔다.
enum LedgerMemoOptOut {
    static let key = "ledgerMemoOptOut"

    static func contains(_ id: UUID, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(id.uuidString)
    }

    /// 편집 중에 누른 칩의 값. 저장할 때만 반영하고, 취소하면 버린다(리뷰: 취소해도 남던 것).
    @MainActor static var pending: [UUID: Bool] = [:]

    @MainActor static func commitPending(_ id: UUID, defaults: UserDefaults = .standard) {
        guard let value = pending.removeValue(forKey: id) else { return }
        set(id, optedOut: value, defaults: defaults)
    }

    static func set(_ id: UUID, optedOut: Bool, defaults: UserDefaults = .standard) {
        var ids = Set(defaults.stringArray(forKey: key) ?? [])
        if optedOut { ids.insert(id.uuidString) } else { ids.remove(id.uuidString) }
        defaults.set(Array(ids).sorted(), forKey: key)
    }
}

extension LedgerBook {
    func entry(forMemo id: UUID) -> LedgerEntry? { entries.first { $0.memoID == id } }

    /// 메모를 저장한 뒤 부른다. 금액이 있으면 이어진 기록을 만들거나 고치고, 없거나 「메모로만」이면 지운다.
    @discardableResult
    func syncMemo(id: UUID, text: String, occurredAt: Date, source: LedgerEntry.Source = .manual) async -> LedgerEntry? {
        await queued(id) { await self.syncMemoNow(id: id, text: text, occurredAt: occurredAt, source: source) }
    }

    func removeMemo(_ id: UUID) async {
        _ = await queued(id) { () -> LedgerEntry? in
            await self.load()
            if let existing = self.entry(forMemo: id) { await self.delete(existing.id) }
            return nil
        }
    }

    /// 같은 메모의 앞 작업이 끝난 뒤에 이 작업을 한다.
    private func queued(_ id: UUID, _ work: @escaping @MainActor () async -> LedgerEntry?) async -> LedgerEntry? {
        let previous = memoQueues[id]
        let task = Task { @MainActor () -> LedgerEntry? in
            await previous?.value
            return await work()
        }
        memoQueues[id] = Task { _ = await task.value }
        return await task.value
    }

    private func syncMemoNow(id: UUID, text: String, occurredAt: Date, source: LedgerEntry.Source) async -> LedgerEntry? {
        await load()
        let existing = entry(forMemo: id)
        guard !LedgerMemoOptOut.contains(id), let found = LedgerMemoAmount.find(text) else {
            if let existing { await delete(existing.id) }
            return nil
        }
        var value = existing ?? LedgerEntry(occurredAt: occurredAt, amount: found.amount, title: found.title, source: source)
        let amountChanged = value.amount != found.amount || value.currency != found.currency
        value.memoID = id
        value.occurredAt = occurredAt
        value.amount = found.amount
        value.currency = found.currency
        value.kind = found.kind
        if existing == nil || value.title != found.title {
            value.title = found.title
            value.category = found.kind == .income ? (found.title.contains("월급") || found.title.contains("급여") ? .salary : .other) : LedgerCategory.guess(found.title)
        }
        if amountChanged || existing == nil { value.amountKRW = nil }
        return await save(value)
    }

}

extension AppModel {
    /// 시험에서 넣는 장부. 시험 앱은 실제 장부를 건드리지 않고, 이 값이 있으면 여기에 맞춘다.
    @MainActor static var memoLedgerBookForTests: LedgerBook?

    var memoLedgerBook: LedgerBook? { AssistantRegistration.isTestHost ? Self.memoLedgerBookForTests : .shared }

    /// 메모를 더하고·고치고·지우는 모든 길(지도 편집·메모 상세·목표·AI·되돌리기)이 여기를 지나 가계부와 맞춘다(LED1111A03 리뷰).
    /// 메모가 없으면(지움) 이어진 기록을 지우고, 있으면 글의 금액대로 만들거나 고친다. 같은 메모는 차례로 처리한다.
    func syncMemoLedger(_ memoID: UUID) {
        guard let book = memoLedgerBook else { return }
        let memo = snapshot.memos.first { $0.id == memoID }
        let isDraft = isMemoDraft(memoID)
        Task { @MainActor in
            guard let memo, !isDraft else { return await book.removeMemo(memoID) }
            await book.syncMemo(id: memoID, text: memo.text, occurredAt: memo.occurredAt)
        }
    }

    /// 메모를 저장한 뒤에만 가계부를 맞춘다(리뷰: 저장이 실패해 되돌려져도 가계부만 바뀌던 것).
    func persistThenSyncMemoLedger(_ memoID: UUID) {
        Task { @MainActor in
            if await persist() { syncMemoLedger(memoID) }
        }
    }

    /// 앞뒤 메모 목록에서 글·시각이 바뀌었거나 생기고 사라진 메모.
    nonisolated static func changedMemoIDs(_ before: [ActionMemo], _ after: [ActionMemo]) -> Set<UUID> {
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(old.keys).union(new.keys).filter { id in
            old[id]?.text != new[id]?.text || old[id]?.occurredAt != new[id]?.occurredAt
        }
    }

    /// 되돌리기처럼 메모 여러 개가 한꺼번에 바뀐 뒤 부른다. 바뀐 메모와 가계부에 이어진 메모를 모두 맞춘다.
    func resyncMemoLedger(changed ids: Set<UUID>) {
        guard let book = memoLedgerBook else { return }
        let linked = Set(book.entries.compactMap(\.memoID))
        for id in ids.union(linked.subtracting(Set(snapshot.memos.map(\.id)))) { syncMemoLedger(id) }
    }
}
