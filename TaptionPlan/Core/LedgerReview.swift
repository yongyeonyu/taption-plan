import Foundation
import Observation

/// 가계부 「확인 필요」(LRV1111A01, 대표 결정). 가게 이름이 없거나 중복·이체가 의심되는 결제는 조용히 넣지 않고
/// 여기 모아 사용자가 넣거나 버린다. 문자 원문은 두지 않고 읽어 낸 기록만 기기에 둔다.
@MainActor
@Observable
final class LedgerReviewStore {
    enum Reason: String, Codable, Sendable { case noMerchant, duplicate, transfer }

    struct Item: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var entry: LedgerEntry
        var reason: Reason
        var receivedAt = Date()
    }

    static let shared = LedgerReviewStore()
    static let key = "ledgerReviewItems"
    static let limit = 50

    private(set) var items: [Item]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
    }

    func add(_ entry: LedgerEntry, reason: Reason, now: Date = .now) {
        // 같은 결제가 문자·앱 알림으로 두 번 와도 한 줄만 둔다.
        guard !items.contains(where: { LedgerMessageParser.isSamePayment($0.entry, entry) }) else { return }
        items.append(Item(entry: entry, reason: reason, receivedAt: now))
        if items.count > Self.limit { items.removeFirst(items.count - Self.limit) }
        persist()
    }

    /// 버린다.
    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    /// 가계부에 넣고 목록에서 뺀다.
    func accept(_ id: UUID, into book: LedgerBook = .shared) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        await book.save(item.entry)
        remove(id)
    }

    /// 되돌리기(ACX1112A01): AI가 넣거나 버린 것을 받은 순서 자리에 다시 둔다.
    func restore(_ item: Item) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
        items.sort { $0.receivedAt < $1.receivedAt }
        if items.count > Self.limit { items.removeFirst(items.count - Self.limit) }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: Self.key) }
    }
}

/// 내 계좌 이름(LIN1111A01, 대표 결정). 기기에만 두고, 이 이름이 든 이체·출금 문자는 지출로 넣지 않는다.
enum LedgerOwnAccounts {
    static let key = "ledgerOwnAccountNames"
    static let transferWords = ["이체", "송금", "출금", "충전", "적금"]

    static func names(_ defaults: UserDefaults = .standard) -> [String] { defaults.stringArray(forKey: key) ?? [] }

    static func set(_ names: [String], defaults: UserDefaults = .standard) {
        var seen = Set<String>()
        let clean = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 2 && seen.insert($0).inserted }
        defaults.set(Array(clean.prefix(20)), forKey: key)
    }

    /// 내 계좌로 옮기는 돈인가: 등록한 이름과 이체 낱말이 함께 있을 때.
    static func isOwnTransfer(_ text: String, names: [String]) -> Bool {
        names.contains { $0.count >= 2 && text.contains($0) } && transferWords.contains(where: text.contains)
    }
}

extension LedgerMessageParser {
    enum DuplicateVerdict: Equatable { case none, same, suspect }

    static let duplicateWindow: TimeInterval = 600
    static let cancelWindow: TimeInterval = 30 * 86_400
    static let salaryWords = ["급여", "월급", "상여"]

    /// 같은 금액·통화·종류가 10분 안에 있는가.
    static func isSamePayment(_ lhs: LedgerEntry, _ rhs: LedgerEntry) -> Bool {
        lhs.amount == rhs.amount && lhs.currency == rhs.currency && lhs.kind == rhs.kind
            && abs(lhs.occurredAt.timeIntervalSince(rhs.occurredAt)) <= duplicateWindow
    }

    /// 가게 이름을 읽지 못해 카드 이름이나 「결제」가 제목이 된 기록.
    static func lacksMerchant(_ entry: LedgerEntry) -> Bool { entry.title == entry.note || entry.title == "결제" }

    /// 문자와 앱 알림이 같은 결제를 넘긴 것(same)과, 10분 안 같은 금액의 다른 가게 결제(suspect)를 가른다(LRV1111A01).
    /// 어느 한쪽이 가게 이름을 못 읽었거나 이름이 서로를 품으면 같은 결제로 본다.
    static func duplicateVerdict(_ entry: LedgerEntry, in entries: [LedgerEntry]) -> DuplicateVerdict {
        let near = entries.filter { $0.source == .message && isSamePayment($0, entry) }
        guard !near.isEmpty else { return .none }
        let name = normalizedName(entry.title)
        let same = lacksMerchant(entry) || near.contains { other in
            let otherName = normalizedName(other.title)
            return lacksMerchant(other) || otherName == name || otherName.contains(name) || name.contains(otherName)
        }
        return same ? .same : .suspect
    }

    static func normalizedName(_ title: String) -> String {
        title.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    /// 취소 문자가 가리키는 원래 결제(LCN1111A01): 30일 안, 같은 금액·통화, 아직 취소되지 않은 지출. 가게가 같은 것을 먼저, 그다음 가장 최근 것.
    static func canceledOriginal(for cancel: LedgerEntry, in entries: [LedgerEntry]) -> LedgerEntry? {
        let candidates = entries.filter {
            $0.kind == .expense && $0.canceledAt == nil && $0.transfer == nil && $0.amount == cancel.amount && $0.currency == cancel.currency
                && $0.occurredAt <= cancel.occurredAt.addingTimeInterval(3_600) && cancel.occurredAt.timeIntervalSince($0.occurredAt) <= cancelWindow
        }.sorted { $0.occurredAt > $1.occurredAt }
        let name = normalizedName(cancel.title)
        return candidates.first { !lacksMerchant(cancel) && normalizedName($0.title) == name } ?? candidates.first
    }

    /// 급여 입금 문자(LIN1111A01): 「입금」과 급여 낱말, 금액이 있고 광고·안내가 아닐 때만 수입으로 넣는다.
    static func salaryDeposit(_ text: String, now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> LedgerEntry? {
        let flat = text.replacingOccurrences(of: "\r", with: "\n")
        guard flat.count <= 1_000, flat.contains("입금"), let word = salaryWords.first(where: flat.contains),
              !isNotice(flat), !flat.contains("취소"), let money = amount(flat) else { return nil }
        return LedgerEntry(
            occurredAt: when(flat, now: now, calendar: calendar)?.date ?? now, amount: money.value, currency: money.currency,
            kind: .income, category: .salary, title: word, note: card(flat).map { $0 + "은행" }, source: .message
        )
    }

    /// 가게 없이 이체·송금·충전 낱말만 있는 결제 문자.
    static func looksLikeTransfer(_ text: String) -> Bool {
        ["이체", "송금", "충전", "적금"].contains(where: text.contains)
    }
}
