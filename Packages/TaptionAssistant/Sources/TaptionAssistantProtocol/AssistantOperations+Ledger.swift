import Foundation
import TaptionLedgerCore
import TaptionRules

// 등록부 동작 1묶음 — 가계부 (ACT1114A07)의 읽기 쪽. 적용(`apply`)은 앱의 `LedgerMessageRules.swift`에 있다(RMN1114A25).

extension AssistantOperations {
    public static let ledger: [any AssistantOperationReading.Type] = [
        ClassifyInboxItem.self, SetFxRate.self, SetPaymentSource.self, SetSkipWords.self,
        AddLedgerTrip.self, UpdateLedgerTrip.self, DeleteLedgerTrip.self,
    ]

    /// 결제 알림을 보낸 앱 이름을 다듬는다: 앞뒤 공백을 떼고 1~40자. 그 밖이면 모르는 앱이다.
    public static func paymentSourceName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...40).contains(name.count) ? name : nil
    }

    /// 함께 간 사람 이름: 1~30자, 20명까지, 「나」를 가리키는 이름은 받지 않는다.
    static func members(_ fields: AssistantFields, count: ClosedRange<Int>) -> [String]? {
        fields.texts("members", max: 30, count: count).flatMap { $0.contains(LedgerTrip.me) ? nil : $0 }
    }

    /// 받은 결제 문자 하나의 종류를 정한다. 화면의 「이 알림은」 칸과 같은 함수를 쓴다.
    public struct ClassifyInboxItem: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "classifyInboxItem", fields: ["inboxId", "choice"], counter: .ledger,
            title: { $0.text("받은 결제 문자 종류 정하기", "Classify received payment texts") },
            guide: #""inboxId":"<inbox[].id>","choice":"expense|income|ignore|internal"} (settles one received payment text like my own tap: expense or income adds it to the ledger when the amount can be read, ignore drops it from the inbox, internal is a transfer between my own accounts or a card top-up and removes the entry the app added for it)"#
        )

        public let inboxID: UUID
        public let choice: String

        public init?(fields: AssistantFields) {
            guard let inboxID = fields.uuid("inboxId"), let choice = fields.raw("choice"),
                  choice == "internal" || LedgerMessageRule.Kind(rawValue: choice) != nil else { return nil }
            self.inboxID = inboxID
            self.choice = choice
        }
    }

    /// 직접 넣는 환율(가계부 기록 편집의 「직접 넣는 환율」과 같은 값).
    public struct SetFxRate: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "setFxRate", fields: ["currency", "krwPerUnit"], counter: .ledger,
            title: { $0.text("환율 직접 정하기", "Set exchange rates") },
            guide: #""currency":"USD","krwPerUnit":1400} (my own exchange rate for one currency, KRW per unit; the ledger uses it for new entries instead of the fetched rate; current ones are in GET /app settings.fxRates)"#
        )

        public let currency: String
        public let rate: Double

        public init?(fields: AssistantFields) {
            guard let currency = fields.raw("currency"), currency.count == 3, currency.allSatisfy({ $0.isASCII && $0.isUppercase }), currency != "KRW",
                  let rate = fields.number("krwPerUnit"), rate > 0, rate <= 1e7 else { return nil }
            self.currency = currency
            self.rate = rate
        }
    }

    /// 결제 알림을 보낸 앱마다의 지출·수입 스위치(「결제 알림 받기」 화면과 같은 함수).
    public struct SetPaymentSource: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "setPaymentSource", fields: ["name", "expense", "income", "remove"], counter: .settings,
            title: { $0.text("결제 알림 앱 스위치 바꾸기", "Change payment alert app switches") },
            guide: #""name":"<settings.paymentSources[].name>","expense":true,"income":false} (what the ledger keeps from one app's payment alerts; give expense, income or both, or "remove":true alone to take the app off the list; the name "문자" stands for text messages)"#
        )

        public let name: String
        public let expense: Bool?
        public let income: Bool?
        public let removes: Bool

        public init?(fields: AssistantFields) {
            let expense = fields.flag("expense"), income = fields.flag("income"), remove = fields.flag("remove")
            guard let name = AssistantOperations.paymentSourceName(fields.raw("name")), fields.ok("expense", expense), fields.ok("income", income), fields.ok("remove", remove),
                  remove == true ? expense == nil && income == nil : expense != nil || income != nil else { return nil }
            self.name = name
            self.expense = expense
            self.income = income
            removes = remove == true
        }
    }

    /// 넣지 않을 낱말(「결제 알림 받기」 화면 아래 칸과 같은 함수).
    public struct SetSkipWords: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "setSkipWords", fields: ["add", "remove"], counter: .settings,
            title: { $0.text("넣지 않을 낱말 고치기", "Edit words to skip") },
            guide: #""add":["광고"],"remove":["자동이체"]} (words in settings.skipWords: a payment text or alert containing one is not added to the ledger; add, remove or both, each word 1 to 20 characters)"#
        )

        public let adds: [String]
        public let removes: [String]

        public init?(fields: AssistantFields) {
            let adds = fields.texts("add", max: 20, count: 1...10), removes = fields.texts("remove", max: 20, count: 1...10)
            guard fields.ok("add", adds), fields.ok("remove", removes), adds != nil || removes != nil else { return nil }
            self.adds = adds ?? []
            self.removes = removes ?? []
        }
    }

    /// 계획 없는 여행 장부를 만든다(가계부의 「여행 더하기」와 같은 `saveTrip`).
    public struct AddLedgerTrip: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "addLedgerTrip", fields: ["name", "start", "end", "members"], counter: .ledger, changes: 0,
            title: { $0.text("여행 가계부 만들기", "Create trip ledgers") },
            guide: #""name":"Jeju","start":"YYYY-MM-DD","end":"YYYY-MM-DD","members":["Mina"]} (creates a trip ledger that has no planned trip; end and members optional, members are my companions without me; for a planned trip use setTripBudget instead; the new id appears in GET /app ledger.trips)"#
        )

        public let name: String
        public let start: Date
        public let end: Date
        public let members: [String]

        public init?(fields: AssistantFields) {
            let end = fields.day("end"), members = AssistantOperations.members(fields, count: 1...20)
            guard let name = fields.string("name", max: 40), let start = fields.day("start"), fields.ok("end", end), fields.ok("members", members),
                  (end ?? start) >= start else { return nil }
            self.name = name
            self.start = start
            self.end = end ?? start
            self.members = members ?? []
        }
    }

    /// 여행 장부의 이름·기간·동행·정산을 고친다(여행 장부 편집·정산 짝 기록 편집과 같은 `saveTrip`·`resetSettlement`).
    public struct UpdateLedgerTrip: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "updateLedgerTrip",
            fields: ["tripId", "name", "start", "end", "members", "settlementKRW", "autoSettlement", "fundingDate", "settlementDate"], counter: .ledger,
            title: { $0.text("여행 가계부 고치기", "Edit trip ledgers") },
            guide: #""tripId":"<ledger.trips[].id>","members":["Mina","Jun"],"settlementKRW":-30000,"settlementDate":"YYYY-MM-DD"} (give at least one of name, start, end, members (the whole companion list, [] for none), fundingDate (the day the budget moves), settlementKRW (fixes the settlement by hand: + returned to my daily ledger, - extra cost, 0 none), settlementDate, or "autoSettlement":true to go back to the automatic settlement)"#
        )

        public let tripID: String
        public let name: String?
        public let start: Date?
        public let end: Date?
        public let members: [String]?
        public let settlementKRW: Double?
        public let autoSettlement: Bool
        public let fundingDate: Date?
        public let settlementDate: Date?

        public init?(fields: AssistantFields) {
            let name = fields.string("name", max: 40), start = fields.day("start"), end = fields.day("end")
            let members = AssistantOperations.members(fields, count: 0...20), settlement = fields.number("settlementKRW"), auto = fields.flag("autoSettlement")
            let funding = fields.day("fundingDate"), settled = fields.day("settlementDate")
            guard let tripID = fields.string("tripId", max: 100), fields.ok("name", name), fields.ok("start", start), fields.ok("end", end),
                  fields.ok("members", members), fields.ok("settlementKRW", settlement), fields.ok("fundingDate", funding), fields.ok("settlementDate", settled),
                  !fields.has("autoSettlement") || (auto == true && settlement == nil), settlement.map({ abs($0) <= 1e12 }) ?? true,
                  fields.values.count > 1 else { return nil }
            if let start, let end, end < start { return nil }
            self.tripID = tripID
            self.name = name
            self.start = start
            self.end = end
            self.members = members
            settlementKRW = settlement?.rounded()
            autoSettlement = auto == true
            fundingDate = funding
            // 자동 정산과 같은 때(그날 아침 9시)에 둔다.
            settlementDate = settled.map { $0.addingTimeInterval(9 * 3_600) }
        }
    }

    /// 여행 장부를 지운다(여행 장부 화면의 지우기와 같은 `deleteTrip`). 안의 기록은 일상 장부로 돌아간다.
    public struct DeleteLedgerTrip: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "deleteLedgerTrip", fields: ["tripId"], counter: .ledger, deletes: true,
            title: { $0.text("여행 가계부 지우기", "Delete trip ledgers") },
            guide: #""tripId":"<ledger.trips[].id>"} (deletes a trip ledger: its budget and settlement transfers go, the entries inside stay and return to my daily ledger; only when I asked)"#
        )

        public let tripID: String

        public init?(fields: AssistantFields) {
            guard let tripID = fields.string("tripId", max: 100) else { return nil }
            self.tripID = tripID
        }
    }
}
