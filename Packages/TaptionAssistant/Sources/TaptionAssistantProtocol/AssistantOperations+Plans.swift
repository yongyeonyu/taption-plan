import Foundation

// 등록부 동작 2·3묶음 — 일정·기록 (ACT1114A07)의 읽기 쪽. 적용(`apply`)은 앱의 `AssistantActivitySync.swift`에 있다(RMN1114A25).

extension AssistantOperations {
    public static let plans: [any AssistantOperationReading.Type] = [PlanQuickAction.self, AddTripItem.self, UpdateTripItem.self, DeleteTripItem.self]

    /// 여행 일정 종류 이름. 앱의 `TripImportItem.Kind`와 같아야 한다(앱 시험이 본다).
    public static let tripItemKinds = ["flight", "lodging", "meal", "cafe", "sight", "photo", "shopping", "activity", "rest", "sleep", "transfer", "other"]

    /// ISO 시각 글의 오프셋(초). `Z`는 0.
    public static func offsetSeconds(_ text: String?) -> Int? {
        guard let text, text.count >= 6 else { return nil }
        if text.hasSuffix("Z") { return 0 }
        let tail = text.suffix(6), parts = tail.dropFirst().split(separator: ":").map { Int($0) }
        guard let sign = tail.first, sign == "+" || sign == "-", parts.count == 2, let hours = parts[0], let minutes = parts[1] else { return nil }
        return (sign == "-" ? -1 : 1) * (hours * 3_600 + minutes * 60)
    }

    /// 위젯·잠금 화면의 빠른 동작과 같은 `performQuickAction`.
    public struct PlanQuickAction: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "planQuickAction", fields: ["planId", "quickAction"], counter: .schedules,
            title: { $0.text("일정 완료·미루기·옮기기", "Complete, postpone or move plans") },
            guide: #""planId":"<plans[].id>","quickAction":"complete|postpone30|moveToNextFree|stop"} (the widget's quick actions on one plan: complete marks it done, postpone30 moves it 30 minutes later, moveToNextFree moves it to my next free time, stop ends it while it is running)"#
        )
        /// 받는 이름. 앱이 위젯 동작(`WidgetAction`)으로 잇는다.
        public static let actionNames = ["complete", "postpone30", "moveToNextFree", "stop"]

        public let planID: UUID
        public let actionName: String

        public init?(fields: AssistantFields) {
            guard let planID = fields.uuid("planId"), let action = fields.choice("quickAction", among: Self.actionNames) else { return nil }
            self.planID = planID
            actionName = action
        }
    }

    /// 시간 있는 여행 일정 하나를 넣는다(여행 계획표의 손으로 넣기와 같은 `addTripItem`). 일상 쪽 계획도 함께 생긴다.
    public struct AddTripItem: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "addTripItem", fields: ["tripId", "title", "start", "end", "kind", "note"], counter: .schedules, changes: 0,
            title: { $0.text("시간 있는 여행 일정 더하기", "Add timed trip items") },
            guide: #""tripId":"<trips[].id>","title":"Dinner","start":"YYYY-MM-DDTHH:MM+09:00","end":"YYYY-MM-DDTHH:MM+09:00","kind":"meal","note":"..."} (adds one timed item to a trip's plan; start and end carry the local offset of the place; kind optional: flight|lodging|meal|cafe|sight|photo|shopping|activity|rest|sleep|transfer|other, default activity; note optional; the new itemId appears in GET /activity trips[].items[])"#
        )

        public let tripID: String
        public let title: String
        public let start: Date
        public let end: Date
        public let offset: Int
        /// 종류 이름(`tripItemKinds` 가운데 하나). 주지 않으면 activity.
        public let kindName: String
        public let note: String

        public init?(fields: AssistantFields) {
            let kind = fields.choice("kind", among: AssistantOperations.tripItemKinds), note = fields.string("note", max: 500)
            guard let tripID = fields.string("tripId", max: 100), let title = fields.string("title", max: 200),
                  let start = fields.instant("start"), let end = fields.instant("end"), end > start,
                  let offset = AssistantOperations.offsetSeconds(fields.raw("start")), fields.ok("kind", kind), fields.ok("note", note) else { return nil }
            self.tripID = tripID
            self.title = title
            self.start = start
            self.end = end
            self.offset = offset
            kindName = kind ?? "activity"
            self.note = note ?? ""
        }
    }

    /// 여행 일정의 이름·종류·시각·메모를 고친다(일정 편집 시트와 같은 `updateTripItem`). 시작만 주면 길이를 지킨다.
    public struct UpdateTripItem: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "updateTripItem", fields: ["tripId", "itemId", "title", "start", "end", "kind", "note"], counter: .schedules,
            title: { $0.text("시간 있는 여행 일정 고치기", "Edit timed trip items") },
            guide: #""tripId":"<trips[].tripId>","itemId":"<items[].itemId>","start":"YYYY-MM-DDTHH:MM+09:00"} (give at least one of title, start, end, kind, note; moving start alone keeps the length; the linked plan and map pin follow)"#
        )

        public let tripID: String
        public let itemID: String
        public let title: String?
        public let start: Date?
        public let end: Date?
        /// 종류 이름(`tripItemKinds` 가운데 하나).
        public let kindName: String?
        public let note: String?

        public init?(fields: AssistantFields) {
            let title = fields.string("title", max: 200), start = fields.instant("start"), end = fields.instant("end")
            let kind = fields.choice("kind", among: AssistantOperations.tripItemKinds), note = fields.string("note", max: 500)
            guard let tripID = fields.string("tripId", max: 100), let itemID = fields.string("itemId", max: 100),
                  fields.ok("title", title), fields.ok("start", start), fields.ok("end", end), fields.ok("kind", kind), fields.ok("note", note),
                  title != nil || start != nil || end != nil || kind != nil || note != nil else { return nil }
            if let start, let end, end <= start { return nil }
            self.tripID = tripID
            self.itemID = itemID
            self.title = title
            self.start = start
            self.end = end
            kindName = kind
            self.note = note
        }
    }

    /// 여행 일정을 딸린 세부 계획·일상 쪽 계획·지도 핀과 함께 지운다(계획표의 지우기와 같은 `deleteTripItemWithDetails`).
    public struct DeleteTripItem: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "deleteTripItem", fields: ["tripId", "itemId"], counter: .schedules, deletes: true,
            title: { $0.text("시간 있는 여행 일정 지우기", "Delete timed trip items") },
            guide: #""tripId":"<trips[].tripId>","itemId":"<items[].itemId>"} (deletes a timed trip item with its detail items, linked plan and map pin; only when I asked)"#
        )

        public let tripID: String
        public let itemID: String

        public init?(fields: AssistantFields) {
            guard let tripID = fields.string("tripId", max: 100), let itemID = fields.string("itemId", max: 100) else { return nil }
            self.tripID = tripID
            self.itemID = itemID
        }
    }
}

extension AssistantOperations {
    public static let records: [any AssistantOperationReading.Type] = [DeleteManualRecord.self, LinkRecordToPlan.self, ResolveBoarding.self]

    /// 사용자가 직접 넣은 기록만 지운다(기록 상세의 지우기와 같은 `deleteActual`). 자동 기록은 가리기로만 고친다.
    public struct DeleteManualRecord: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "deleteManualRecord", fields: ["recordId"], counter: .edits, deletes: true,
            title: { $0.text("직접 넣은 기록 지우기", "Delete records I added") },
            guide: #""recordId":"<records[].id>"} (deletes one record I added by hand; automatic records cannot be deleted, use hideRecord for those; only when I asked)"#
        )

        public let recordID: UUID

        public init?(fields: AssistantFields) {
            guard let recordID = fields.uuid("recordId") else { return nil }
            self.recordID = recordID
        }
    }

    /// 기록을 일정이나 루틴에 잇는다(기록 연결 화면과 같은 `connectActualRecord`).
    public struct LinkRecordToPlan: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "linkRecordToPlan", fields: ["recordId", "planId"], counter: .edits,
            title: { $0.text("기록을 일정·루틴에 잇기", "Link records to plans or routines") },
            guide: #""recordId":"<records[].id>","planId":"<plans[].id or goals[].id>"} (counts one record as time spent on a plan or goal; the record must overlap the plan's time, and repeating segments or calendar events cannot be targets)"#
        )

        public let recordID: UUID
        public let planID: UUID

        public init?(fields: AssistantFields) {
            guard let recordID = fields.uuid("recordId"), let planID = fields.uuid("planId") else { return nil }
            self.recordID = recordID
            self.planID = planID
        }
    }

    /// 앱이 찾은 탑승 후보에 답한다(지도의 탑승 확인 카드와 같은 `confirmTransitBoarding`·`deleteTransitBoardingCandidate`).
    public struct ResolveBoarding: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "resolveBoarding", fields: ["candidateId", "decision"], counter: .edits,
            title: { $0.text("탑승 확인·거절", "Confirm or reject boardings") },
            guide: #""candidateId":"<boarding[].id>","decision":"confirm|reject"} (answers a boarding the app detected and is waiting to have confirmed, boarding in GET /app: confirm sets that ride's mode, reject drops the candidate; only when I told you)"#
        )

        public let candidateID: String
        public let confirms: Bool

        public init?(fields: AssistantFields) {
            guard let candidateID = fields.raw("candidateId"), candidateID.count == 16, candidateID.allSatisfy(\.isHexDigit),
                  let decision = fields.raw("decision"), decision == "confirm" || decision == "reject" else { return nil }
            self.candidateID = candidateID
            confirms = decision == "confirm"
        }
    }
}
