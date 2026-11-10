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
        for code in currencyCodes {
            if let regex = try? Regex("\(code)\\s*([0-9][0-9,]*(?:\\.[0-9]{1,2})?)|([0-9][0-9,]*(?:\\.[0-9]{1,2})?)\\s*\(code)"),
               let match = line.firstMatch(of: regex) {
                let digits = (match.output[1].substring ?? match.output[2].substring).map(String.init) ?? ""
                if let value = LedgerMessageParser.number(digits), value > 0 { return found(value, code, income, line, String(line[match.range])) }
            }
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
            guard let value = LedgerMessageParser.number(String(match.output)), value >= 1_000, value <= 1e10,
                  // 쉼표 없는 1900~2100은 연도로 본다.
                  match.output.contains(",") || !(1_900...2_100).contains(value) else { continue }
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

    func removeMemo(_ id: UUID) async {
        await load()
        if let existing = entry(forMemo: id) { await delete(existing.id) }
    }
}
