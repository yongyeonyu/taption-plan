import Foundation

/// 정산에 들어가는 공유 지출 한 건(항목 id와 내용).
public struct ShareSettlementEntry: Sendable, Equatable {
    public var id: String
    public var expense: ShareExpenseContent

    public init(id: String, expense: ShareExpenseContent) {
        self.id = id
        self.expense = expense
    }
}

public struct ShareBalance: Sendable, Equatable {
    public var party: ShareParty
    /// 낸 돈.
    public var paid: Int
    /// 내 몫.
    public var owed: Int
    /// 차액 = 낸 돈 − 몫. 양수면 받을 돈, 음수면 보낼 돈.
    public var net: Int { paid - owed }
}

public struct ShareTransfer: Sendable, Equatable {
    public var from: ShareParty
    public var to: ShareParty
    public var amount: Int
    public var currency: String

    /// 송금 완료 표시에 쓰는 이름(`ShareMemberCard.sent`).
    public var key: String { "\(from.code)>\(to.code):\(currency):\(amount)" }
}

/// 한 통화의 정산.
public struct ShareSettlement: Sendable, Equatable {
    public var currency: String
    /// 사람 순(참여자 번호 → 앱 없는 일행 id).
    public var balances: [ShareBalance]
    public var transfers: [ShareTransfer]
}

/// 정산 계산. 순수 함수이고 같은 입력이면 어느 기기에서나 같은 결과다(12절).
///
/// 규칙
/// - 공유 지출만 넣는다. 금액이 0 이하인 지출은 세지 않는다.
/// - 금액은 `amountKRW`(넣을 때의 원화 환산)가 있으면 그것을 쓰고 통화는 `KRW`로 본다. 없으면 원래 금액·통화.
///   통화가 다른 지출은 섞지 않는다.
/// - 지출은 항목 id 순으로 본다. 나눌 사람(`split`)은 겹친 것을 걷어 낸 뒤 사람 순(참여자 번호 → 앱 없는 일행 id)으로 본다.
///   **비어 있으면 낸 사람 혼자 진다**(지금의 참여자로 채우지 않는다. 사람이 드나들어도 결과가 달라지지 않게).
/// - 몫 = 금액 ÷ 사람 수의 몫(가장 작은 단위에서 버림). **나머지는 사람 순으로 앞에서부터 1씩** 더 진다.
/// - `parties`는 결과에 0으로라도 넣을 사람들이다. 거기 없는 사람(나간 참여자)도 지출에 나오면 넣는다. 차액의 합은 늘 0이다.
/// - 송금 목록은 「보낼 돈이 가장 큰 사람 → 받을 돈이 가장 큰 사람」을 되풀이해 만든다(같으면 사람 순).
///   송금 수는 많아야 (차액이 있는 사람 수 − 1)이다.
public enum ShareSettlementCalculator {
    public static let baseCurrency = "KRW"

    public static func settle(_ entries: [ShareSettlementEntry], parties: [ShareParty]) -> [ShareSettlement] {
        let everyone = Array(Set(parties)).sorted()
        var ledgers: [String: [ShareParty: ShareBalance]] = [:]
        for entry in entries.sorted(by: { $0.id < $1.id }) {
            let expense = entry.expense
            let amount = expense.amountKRW ?? expense.amount
            guard amount > 0 else { continue }
            let currency = expense.amountKRW == nil ? expense.currency : baseCurrency
            var ledger = ledgers[currency] ?? [:]
            for party in everyone where ledger[party] == nil { ledger[party] = ShareBalance(party: party, paid: 0, owed: 0) }
            ledger[expense.payer, default: ShareBalance(party: expense.payer, paid: 0, owed: 0)].paid += amount
            for (party, share) in shares(of: amount, payer: expense.payer, split: expense.split) {
                ledger[party, default: ShareBalance(party: party, paid: 0, owed: 0)].owed += share
            }
            ledgers[currency] = ledger
        }
        return ledgers.keys.sorted().map { currency in
            let balances = ledgers[currency, default: [:]].values.sorted { $0.party < $1.party }
            return ShareSettlement(currency: currency, balances: balances, transfers: transfers(for: balances, currency: currency))
        }
    }

    /// 금액을 사람별 몫으로 나눈다. 몫의 합은 금액과 같다.
    public static func shares(of amount: Int, payer: ShareParty, split: [ShareParty]) -> [(party: ShareParty, share: Int)] {
        let people = split.isEmpty ? [payer] : Array(Set(split)).sorted()
        let base = amount / people.count
        let rest = amount % people.count
        return people.enumerated().map { index, party in (party, base + (index < rest ? 1 : 0)) }
    }

    /// 차액에서 송금 목록을 만든다.
    public static func transfers(for balances: [ShareBalance], currency: String) -> [ShareTransfer] {
        var debtors = balances.filter { $0.net < 0 }.map { (party: $0.party, amount: -$0.net) }
        var creditors = balances.filter { $0.net > 0 }.map { (party: $0.party, amount: $0.net) }
        var out: [ShareTransfer] = []
        while let from = largest(debtors), let to = largest(creditors) {
            let amount = min(debtors[from].amount, creditors[to].amount)
            out.append(ShareTransfer(from: debtors[from].party, to: creditors[to].party, amount: amount, currency: currency))
            debtors[from].amount -= amount
            creditors[to].amount -= amount
        }
        return out
    }

    /// 남은 돈이 가장 큰 사람의 자리. 같으면 사람 순으로 앞선 쪽. 남은 돈이 없으면 nil.
    private static func largest(_ list: [(party: ShareParty, amount: Int)]) -> Int? {
        var best: Int?
        for index in list.indices where list[index].amount > 0 {
            guard let current = best else {
                best = index
                continue
            }
            if list[index].amount > list[current].amount || (list[index].amount == list[current].amount && list[index].party < list[current].party) {
                best = index
            }
        }
        return best
    }
}
