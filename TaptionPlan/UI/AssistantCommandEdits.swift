import Foundation
import TaptionPlanCore

/// AI 비서 명령 종류. 「AI 비서」 메뉴에서 하나씩 끌 수 있고 기본은 모두 켠다(AIR1110A02).
enum AssistantActionKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case addMemo, addSchedule, updateActivity
    case hideRecord, mergeRecords, updateRecordTime
    case updateSchedule, deleteSchedule, updateMemo, deleteMemo
    // AIR1110A03
    case addGoal, updateGoal, deleteGoal
    case addTripStop, updateTripStop, deleteTripStop, setTripItemStatus
    case updateSleep, setLanguage, setMapStyle, setDisplayOption, setBubble
    case addExpense
    // AIQ1111A01: 앱이 넣은 결제 문자 기록을 AI가 다듬는다.
    case updateExpense
    // ACT1111A01
    case classifyUnconfirmed, setTravelMode
    // PRL1112A01
    case addPaymentRule
    // ACX1112A01
    case setBudget, addOwnAccount, removeOwnAccount, deletePaymentRule, resolveReview, deleteInboxItem, openScreen
    // ASK1112A01
    case askUser
    // ACA1112A01
    case addPlace, updatePlace, deletePlace, addCategory, updateCategory
    // ACB1112A01
    case addTrip, updateTrip, deleteTrip, setSetting
    // ACD1112A01
    case requestApproval
    // HND1112A01
    case resolvePlaceSuggestion, setCarAudio, setCalendarTitleDetail

    var id: String { rawValue }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .addMemo: language.text("메모 더하기", "Add memos")
        case .addSchedule: language.text("일정 더하기", "Add schedules")
        case .updateActivity: language.text("기록 이름·분류 고치기", "Rename or reclassify records")
        case .hideRecord: language.text("기록 가리기", "Hide records")
        case .mergeRecords: language.text("기록 합치기", "Merge records")
        case .updateRecordTime: language.text("기록 시간 고치기", "Change record times")
        case .updateSchedule: language.text("일정 고치기", "Edit schedules")
        case .deleteSchedule: language.text("일정 지우기", "Delete schedules")
        case .updateMemo: language.text("메모 고치기", "Edit memos")
        case .deleteMemo: language.text("메모 지우기", "Delete memos")
        case .addGoal: language.text("루틴 더하기", "Add routines")
        case .updateGoal: language.text("루틴 고치기", "Edit routines")
        case .deleteGoal: language.text("루틴 지우기", "Delete routines")
        case .addTripStop: language.text("여행 일정 더하기", "Add trip stops")
        case .updateTripStop: language.text("여행 일정 고치기", "Edit trip stops")
        case .deleteTripStop: language.text("여행 일정 지우기", "Delete trip stops")
        case .setTripItemStatus: language.text("여행 일정 상태 바꾸기", "Change trip stop status")
        case .updateSleep: language.text("수면 시간 고치기", "Correct sleep times")
        case .setLanguage: language.text("앱 언어 바꾸기", "Change app language")
        case .setMapStyle: language.text("지도 스타일 바꾸기", "Change map style")
        case .setDisplayOption: language.text("지도 표시 켜고 끄기", "Toggle map display")
        case .setBubble: language.text("AI 말풍선", "AI speech bubbles")
        case .addExpense: language.text("가계부 기록 더하기", "Add ledger entries")
        case .updateExpense: language.text("가계부 기록 고치기", "Edit ledger entries")
        case .classifyUnconfirmed: language.text("미확인 시간 분류하기", "Classify unconfirmed time")
        case .setTravelMode: language.text("이동 수단 고치기", "Correct travel modes")
        case .addPaymentRule: language.text("결제 문자 읽기 규칙 더하기", "Add payment text rules")
        case .setBudget: language.text("가계부 예산 정하기", "Set the ledger budget")
        case .addOwnAccount: language.text("내 계좌 이름 더하기", "Add own account names")
        case .removeOwnAccount: language.text("내 계좌 이름 지우기", "Remove own account names")
        case .deletePaymentRule: language.text("결제 문자 읽기 규칙 지우기", "Delete payment text rules")
        case .resolveReview: language.text("확인 필요 결제 넣기·버리기", "Add or discard payments to review")
        case .deleteInboxItem: language.text("받은 결제 문자 지우기", "Delete received payment texts")
        case .openScreen: language.text("앱 화면 열기", "Open app screens")
        case .askUser: language.text("앱에서 질문하기", "Ask questions in the app")
        case .addPlace: language.text("자주 가는 장소 더하기", "Add frequent places")
        case .updatePlace: language.text("자주 가는 장소 고치기", "Edit frequent places")
        case .deletePlace: language.text("자주 가는 장소 지우기", "Delete frequent places")
        case .addCategory: language.text("분류 더하기", "Add categories")
        case .updateCategory: language.text("분류 고치기", "Edit categories")
        case .addTrip: language.text("여행 만들기", "Create trips")
        case .updateTrip: language.text("여행 고치기", "Edit trips")
        case .deleteTrip: language.text("여행 지우기", "Delete trips")
        case .setSetting: language.text("급여·통행료 차종 설정 바꾸기", "Change pay and toll vehicle settings")
        case .requestApproval: language.text("승인 요청 받기(공유 수준·삭제·백업 등)", "Receive approval requests (sharing, erase, backup…)")
        case .resolvePlaceSuggestion: language.text("자주 머무는 곳 제안 등록·거절", "Register or dismiss suggested places")
        case .setCarAudio: language.text("내 차 등록·빼기", "Register or remove my car")
        case .setCalendarTitleDetail: language.text("일정 제목 분류 정하기", "Classify calendar event titles")
        }
    }
}

/// 종류별 켜기·끄기. 값이 없으면 켠 것으로 본다(AIR1110A02).
enum AssistantActionToggles {
    static func key(_ kind: AssistantActionKind) -> String { "assistantAction.\(kind.rawValue)" }

    static func isEnabled(_ kind: AssistantActionKind, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key(kind)) as? Bool ?? true
    }

    static func set(_ kind: AssistantActionKind, enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key(kind))
    }
}

/// 고칠 일정. `planId`가 없으면 그날 `startTime`에 시작하는 일정을 찾는다.
struct AssistantPlanTarget: Equatable, Sendable {
    var planID: String?
    var startTime: Date?
}

/// 일정의 새 시각. ISO 시각이거나, 그 일정 날의 HH:mm.
enum AssistantScheduleTime: Equatable, Sendable {
    case instant(Date)
    case clock(hour: Int, minute: Int)

    init?(text: String) {
        if let date = AssistantCommandParser.instant(text) {
            self = .instant(date)
            return
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 2, let hour = parts[0], let minute = parts[1],
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        self = .clock(hour: hour, minute: minute)
    }

    func resolve(on day: Date, calendar: Calendar) -> Date? {
        switch self {
        case let .instant(date): date
        case let .clock(hour, minute): calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        }
    }
}

extension AssistantCommand.Action {
    var kind: AssistantActionKind {
        switch self {
        case .addMemo: .addMemo
        case .addSchedule: .addSchedule
        case .updateActivity: .updateActivity
        case .hideRecord: .hideRecord
        case .mergeRecords: .mergeRecords
        case .updateRecordTime: .updateRecordTime
        case .updateSchedule: .updateSchedule
        case .deleteSchedule: .deleteSchedule
        case .updateMemo: .updateMemo
        case .deleteMemo: .deleteMemo
        case .addGoal: .addGoal
        case .updateGoal: .updateGoal
        case .deleteGoal: .deleteGoal
        case .addTripStop: .addTripStop
        case .updateTripStop: .updateTripStop
        case .deleteTripStop: .deleteTripStop
        case .setTripItemStatus: .setTripItemStatus
        case .updateSleep: .updateSleep
        case .setLanguage: .setLanguage
        case .setMapStyle: .setMapStyle
        case .setDisplayOption: .setDisplayOption
        case .setBubble: .setBubble
        case .addExpense: .addExpense
        case .updateExpense: .updateExpense
        case .classifyUnconfirmed: .classifyUnconfirmed
        case .setTravelMode: .setTravelMode
        case .addPaymentRule: .addPaymentRule
        case .setBudget: .setBudget
        case .addOwnAccount: .addOwnAccount
        case .removeOwnAccount: .removeOwnAccount
        case .deletePaymentRule: .deletePaymentRule
        case .resolveReview: .resolveReview
        case .deleteInboxItem: .deleteInboxItem
        case .openScreen: .openScreen
        case .askUser: .askUser
        case .addPlace: .addPlace
        case .updatePlace: .updatePlace
        case .deletePlace: .deletePlace
        case .addCategory: .addCategory
        case .updateCategory: .updateCategory
        case .addTrip: .addTrip
        case .updateTrip: .updateTrip
        case .deleteTrip: .deleteTrip
        case .setSetting: .setSetting
        case .requestApproval: .requestApproval
        case .resolvePlaceSuggestion: .resolvePlaceSuggestion
        case .setCarAudio: .setCarAudio
        case .setCalendarTitleDetail: .setCalendarTitleDetail
        }
    }

    /// 이 명령이 바꾸는 기존 기록·일정·메모 수. 새로 더하는 것은 0.
    /// 루틴을 지우면 하위 일정도 함께 지워지므로 `plans`를 주면 그 수까지 센다(REV1110A06).
    func existingChangeCount(plans: [PlanRecord] = []) -> Int {
        switch self {
        case .addMemo, .addSchedule, .addGoal, .addTripStop, .setBubble, .addExpense, .classifyUnconfirmed, .addPaymentRule, .addOwnAccount, .openScreen, .askUser, .addPlace, .addCategory, .addTrip, .requestApproval: 0
        case let .mergeRecords(_, ids, _, _): ids.count
        case let .deleteGoal(goalID):
            1 + (UUID(uuidString: goalID).flatMap { try? PlanHierarchy.descendants(of: $0, in: plans) }?.count ?? 0)
        default: 1
        }
    }

    var existingChangeCount: Int { existingChangeCount() }
}

/// 한 묶음이 기존 항목을 이만큼 넘게 바꾸면 자동으로 반영하지 않고 묻는다(AIR1110A02).
enum AssistantBatchPolicy {
    static let confirmThreshold = 20

    static func changeCount(_ batch: AssistantCommandBatch, defaults: UserDefaults = .standard, plans: [PlanRecord] = []) -> Int {
        batch.commands
            .filter { AssistantActionToggles.isEnabled($0.action.kind, defaults: defaults) }
            .reduce(0) { $0 + $1.action.existingChangeCount(plans: plans) }
    }

    static func needsConfirmation(_ batch: AssistantCommandBatch, defaults: UserDefaults = .standard, plans: [PlanRecord] = []) -> Bool {
        changeCount(batch, defaults: defaults, plans: plans) > confirmThreshold
    }
}

/// 명령 하나의 결과. 거절이면 `reason`, 반영이면 사람이 읽는 전·후.
struct AssistantEditResult: Equatable, Sendable {
    var reason: String?
    var before = ""
    var after = ""
    /// 되돌리기에 담을 자동·수동 기록 id.
    var actualIDs: Set<UUID> = []
    /// 기기 설정 전·후(AIR1110A03).
    var preferences: [AssistantPreferenceChange] = []
    /// 더한 말풍선(BUB1110A01). 되돌리면 지운다.
    var bubbleID: UUID?
    /// 더한 가계부 기록(LED1110A01). 되돌리면 지운다.
    var ledgerEntryID: UUID?
    var ledgerEntry: LedgerEntry?
    /// 고치거나 지우기 전 가계부 기록(AIQ1111A01). 되돌리면 이것으로 돌린다.
    var ledgerBefore: LedgerEntry?
    /// 고치기 전 이동 구간과 수단 교정표(ACT1111A01). 되돌리면 이것으로 돌린다.
    var movementBefore: AssistantMovementChange.State?
    /// 더한 결제 문자 규칙(PRL1112A01). 되돌리면 지운다.
    var paymentRuleID: UUID?
    /// 가계부 설정·정리·화면 열기의 전·후(ACX1112A01).
    var appChange: AssistantAppChange?

    static func rejected(_ reason: String) -> Self { Self(reason: reason) }
}

/// 일정 찾기. 같은 분에 시작하는 일정이 여럿이면 사용자가 만든 것을 고른다.
enum AssistantPlanLookup {
    static func plan(_ target: AssistantPlanTarget, in plans: [PlanRecord]) -> PlanRecord? {
        if let planID = target.planID {
            return UUID(uuidString: planID).flatMap { id in plans.first { $0.id == id } }
        }
        guard let startTime = target.startTime else { return nil }
        let matches = plans.filter { abs($0.span.start.timeIntervalSince(startTime)) < 60 }
        return matches.first { isEditable($0) && !GoalRecordPolicy.isGoal($0) } ?? matches.first(where: isEditable) ?? matches.first
    }

    /// 캘린더·자동으로 생긴 일정은 고치지 않는다.
    static func isEditable(_ plan: PlanRecord) -> Bool {
        !plan.isFixed && (plan.origin == .user || plan.origin == .repeatRule)
    }
}

/// 「AI가 한 일」에 보이는 전·후 글.
enum AssistantEditText {
    static func clock(_ date: Date) -> String { format(date, "HH:mm") }

    static func record(_ actual: ActualRecord) -> String {
        let end = actual.endedAt.map(clock) ?? "…"
        return "\(clock(actual.startedAt))–\(end) \(actual.title)"
    }

    static func plan(_ plan: PlanRecord) -> String {
        "\(format(plan.span.start, "M/d HH:mm"))–\(clock(plan.span.end)) \(plan.title)"
    }

    static func memo(_ text: String) -> String { String(text.prefix(80)) }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

extension AppModel {
    /// 명령 하나를 앱의 기존 편집 경로로 반영한다(AIR1110A02·CLN1110A01).
    /// 기록은 교정표·사용자 덮개 기록으로만 고쳐 자동 원본과 센서 원본은 지우지 않는다.
    func applyAssistantAction(_ action: AssistantCommand.Action, preferences: AssistantPreferenceStore = .live) async -> AssistantEditResult {
        let language = MapHomeLanguage.current
        switch action {
        case let .addMemo(text, at):
            // 서버도 1,000자(메모 저장 한도)로 막는다. 예전 서버 큐에 남은 더 긴 글은 화면 오류 없이 거절로만 알린다.
            guard text.count <= TaptionPlanMemoRecord.maximumTextLength else { return .rejected("memo_too_long") }
            guard let memoID = addMemo(text: text, kind: .idea, categoryID: MemoTimelineEngine.categoryID, on: at) else { return .rejected("memo_failed") }
            var result = AssistantEditResult(after: AssistantEditText.memo(text))
            // 금액이 든 메모는 화면의 메모처럼 가계부에도 이어진다(LED1111A03). 되돌리면 함께 지운다.
            if let entry = await preferences.ledger.syncMemo(id: memoID, text: text, occurredAt: at, source: .assistant) {
                result.ledgerEntryID = entry.id
                result.ledgerEntry = entry
            }
            return result
        case let .addSchedule(title, start, end, note):
            // 분류를 알 수 없으니 일반 활동에 둔다.
            if let note, note.count > TaptionPlanMemoRecord.maximumTextLength { return .rejected("note_too_long") }
            guard let planID = addPlan(title: title, categoryID: "activity", startAt: start, duration: end.map { $0.timeIntervalSince(start) } ?? 3_600)
            else { return .rejected("schedule_failed") }
            if let note { addMemo(text: note, kind: .idea, to: planID) }
            return AssistantEditResult(after: snapshot.plans.first { $0.id == planID }.map(AssistantEditText.plan) ?? title)
        case let .updateActivity(day, recordID, startTime, title, categoryID):
            if let categoryID, !isAssistantCategory(categoryID) { return .rejected("unknown_category") }
            guard let actual = AssistantActivityTarget.record(id: recordID, at: startTime, day: day, in: snapshot.actuals) else { return .rejected("no_record") }
            // 교정표로만 고쳐 되돌릴 수 있고 자동 원본·근거는 남는다.
            let option = AssistantActivityTarget.option(for: actual, title: title, categoryID: categoryID)
            await updateActualActivity(actual.id, with: option)
            // 교정이 실제로 남았는지 본 뒤에만 반영했다고 알린다(REV1110A06).
            let correction = snapshot.settings.activityCorrections[actual.id]
            guard correction?.title == option.title, correction?.categoryID == option.categoryID else { return .rejected("edit_failed") }
            return recordResult(before: actual)
        case let .hideRecord(day, recordID, startTime):
            guard let actual = AssistantActivityTarget.record(id: recordID, at: startTime, day: day, in: snapshot.actuals),
                  actual.categoryID != ActivitySectionOverrideEngine.unconfirmedOption.categoryID else { return .rejected("no_record") }
            // 지우지 않고 미확인(유령)으로 교정한다. 교정표만 바뀌어 되돌릴 수 있다.
            await updateActualActivity(actual.id, with: ActivitySectionOverrideEngine.unconfirmedOption)
            guard snapshot.settings.activityCorrections[actual.id]?.categoryID == ActivitySectionOverrideEngine.unconfirmedOption.categoryID
            else { return .rejected("edit_failed") }
            return AssistantEditResult(
                before: AssistantEditText.record(actual), after: language.text("가림", "Hidden"), actualIDs: [actual.id]
            )
        case let .mergeRecords(day, recordIDs, title, categoryID):
            return await mergeAssistantRecords(day: day, recordIDs: recordIDs, title: title, categoryID: categoryID)
        case let .updateRecordTime(_, recordID, start, end):
            return await retimeAssistantRecord(recordID, start: start, end: end)
        case let .updateSchedule(target, title, start, end, note):
            return updateAssistantSchedule(target, title: title, start: start, end: end, note: note)
        case let .deleteSchedule(target):
            guard let plan = AssistantPlanLookup.plan(target, in: snapshot.plans) else { return .rejected("no_plan") }
            guard AssistantPlanLookup.isEditable(plan) else { return .rejected("not_editable") }
            // 루틴은 루틴 동작으로만 지운다. 「루틴 지우기」를 꺼 두면 이 길로도 지워지지 않는다(REV1110A06).
            guard !GoalRecordPolicy.isGoal(plan) else { return .rejected("is_goal") }
            // 하위 일정까지 함께 지워지는 루틴은 앱에서 직접 지우게 한다.
            guard ((try? PlanHierarchy.descendants(of: plan.id, in: snapshot.plans)) ?? []).isEmpty else { return .rejected("has_children") }
            await deletePlans([plan.id])
            guard !snapshot.plans.contains(where: { $0.id == plan.id }) else { return .rejected("schedule_failed") }
            return AssistantEditResult(before: AssistantEditText.plan(plan), after: language.text("지움", "Deleted"))
        case let .updateMemo(memoID, text):
            guard let memo = assistantMemo(memoID) else { return .rejected("no_memo") }
            guard text.count <= TaptionPlanMemoRecord.maximumTextLength else { return .rejected("memo_too_long") }
            updateMemo(memo.id, text: text, kind: memo.kind)
            guard snapshot.memos.first(where: { $0.id == memo.id })?.text == text else { return .rejected("memo_failed") }
            return AssistantEditResult(before: AssistantEditText.memo(memo.text), after: AssistantEditText.memo(text))
        case let .deleteMemo(memoID):
            guard let memo = assistantMemo(memoID) else { return .rejected("no_memo") }
            deleteMemo(memo.id)
            guard !snapshot.memos.contains(where: { $0.id == memo.id }) else { return .rejected("memo_failed") }
            return AssistantEditResult(before: AssistantEditText.memo(memo.text), after: language.text("지움", "Deleted"))
        default:
            return await applyAssistantDataAction(action, preferences: preferences)
        }
    }

    func isAssistantCategory(_ id: String) -> Bool {
        id != "unconfirmed" && snapshot.categories.contains { $0.id == id }
    }

    private func recordResult(before actual: ActualRecord) -> AssistantEditResult {
        let after = snapshot.actuals.first { $0.id == actual.id }
        return AssistantEditResult(
            before: AssistantEditText.record(actual), after: after.map(AssistantEditText.record) ?? "",
            actualIDs: [actual.id]
        )
    }

    func assistantMemo(_ memoID: String) -> ActionMemo? {
        guard let id = UUID(uuidString: memoID), !isMemoDraft(id) else { return nil }
        return snapshot.memos.first { $0.id == id }
    }

    /// 이어진 기록을 구간 편집과 같은 사용자 덮개 기록 하나로 덮는다. 아래 자동 기록은 그대로 남는다.
    private func mergeAssistantRecords(day: Date, recordIDs: [String], title: String?, categoryID: String?) async -> AssistantEditResult {
        if let categoryID, !isAssistantCategory(categoryID) { return .rejected("unknown_category") }
        let found = recordIDs.compactMap { id in
            UUID(uuidString: id).flatMap { uuid in snapshot.actuals.first { $0.id == uuid } }
        }
        guard found.count == recordIDs.count, found.allSatisfy({ $0.endedAt != nil && $0.categoryID != "unconfirmed" })
        else { return .rejected("no_record") }
        guard let span = AssistantMergePlan.span(found) else { return .rejected("not_consecutive") }
        let main = found.max { $0.span(asOf: .now).duration < $1.span(asOf: .now).duration } ?? found[0]
        let newTitle = title ?? main.title
        let option = ActivityCorrectionOption(
            id: "assistant.merge.\(newTitle)", title: newTitle, behavior: title == nil ? main.behavior : nil,
            categoryID: categoryID ?? main.categoryID, systemImage: "tag.fill", isAutomatic: false, isCustom: false
        )
        let request = ActivitySectionEditRequest(
            sourceIDs: found.map(\.id), originalSpan: span, originalOption: option,
            mode: .replace(editedSpan: span, option: option)
        )
        guard let saved = await saveActivitySectionEdit(request) else { return .rejected("edit_failed") }
        let merged = snapshot.actuals.first { saved.recordIDs.contains($0.id) }
        return AssistantEditResult(
            before: found.sorted { $0.startedAt < $1.startedAt }.map(AssistantEditText.record).joined(separator: " · "),
            after: merged.map(AssistantEditText.record) ?? newTitle,
            actualIDs: Set(found.map(\.id)).union(saved.recordIDs)
        )
    }

    /// 교정표에 표시 시간만 적는다(타임라인 시간 조정과 같은 경로).
    private func retimeAssistantRecord(_ recordID: String, start: Date?, end: Date?) async -> AssistantEditResult {
        guard let uuid = UUID(uuidString: recordID),
              let actual = snapshot.actuals.first(where: { $0.id == uuid }), actual.categoryID != "unconfirmed"
        else { return .rejected("no_record") }
        guard let currentEnd = actual.endedAt else { return .rejected("record_running") }
        guard let span = AssistantMergePlan.retimed(start: actual.startedAt, end: currentEnd, newStart: start, newEnd: end)
        else { return .rejected("invalid_time") }
        await updateActualSpan(uuid, startAt: span.start, endAt: span.end)
        let correction = snapshot.settings.activityCorrections[uuid]
        guard correction?.startedAt == span.start, correction?.endedAt == span.end else { return .rejected("edit_failed") }
        return recordResult(before: actual)
    }

    private func updateAssistantSchedule(
        _ target: AssistantPlanTarget, title: String?, start: AssistantScheduleTime?, end: AssistantScheduleTime?, note: String?
    ) -> AssistantEditResult {
        guard let plan = AssistantPlanLookup.plan(target, in: snapshot.plans) else { return .rejected("no_plan") }
        guard AssistantPlanLookup.isEditable(plan) else { return .rejected("not_editable") }
        guard !GoalRecordPolicy.isGoal(plan) else { return .rejected("is_goal") }
        if let note, note.count > TaptionPlanMemoRecord.maximumTextLength { return .rejected("note_too_long") }
        let calendar = Calendar.autoupdatingCurrent
        guard let newStart = start.map({ $0.resolve(on: plan.span.start, calendar: calendar) }) ?? plan.span.start,
              let newEnd = end.map({ $0.resolve(on: plan.span.start, calendar: calendar) })
                ?? (start == nil ? plan.span.end : newStart.addingTimeInterval(plan.span.duration)),
              newEnd > newStart, newEnd.timeIntervalSince(newStart) <= 7 * 86_400
        else { return .rejected("invalid_time") }
        let span = TimeSpan(start: newStart, end: newEnd)
        let newTitle = title ?? plan.title
        if newTitle != plan.title || span != plan.span {
            let errorBefore = userFacingError
            updatePlan(
                plan.id, title: newTitle, categoryID: plan.categoryID,
                middleCategoryName: plan.middleCategoryName, subCategoryName: plan.subCategoryName,
                span: span, parentID: plan.parentID, isImportant: plan.isImportant, repeatRules: plan.repeatRules
            )
            guard let updated = snapshot.plans.first(where: { $0.id == plan.id }), updated.title == newTitle, updated.span == span else {
                // 상위 일정 범위 밖 같은 실패는 AI 결과로만 알린다.
                userFacingError = errorBefore
                return .rejected("schedule_failed")
            }
        }
        if let note {
            if let memo = snapshot.memos.first(where: { $0.planID == plan.id && !$0.isSticker }) {
                updateMemo(memo.id, text: note, kind: memo.kind)
            } else {
                addMemo(text: note, kind: .idea, to: plan.id)
            }
        }
        let updated = snapshot.plans.first { $0.id == plan.id } ?? plan
        return AssistantEditResult(before: AssistantEditText.plan(plan), after: AssistantEditText.plan(updated))
    }
}

/// 합칠 구간과 새 시간 계산. 화면 없이 시험한다.
enum AssistantMergePlan {
    /// 기록 사이가 이만큼 넘게 비면 이어진 것으로 보지 않는다.
    static let maximumGap: TimeInterval = 15 * 60

    static func span(_ records: [ActualRecord]) -> TimeSpan? {
        let sorted = records.sorted { $0.startedAt < $1.startedAt }
        guard var end = sorted.first?.endedAt, let start = sorted.first?.startedAt else { return nil }
        for record in sorted.dropFirst() {
            guard let recordEnd = record.endedAt, record.startedAt.timeIntervalSince(end) <= maximumGap else { return nil }
            end = max(end, recordEnd)
        }
        guard end > start, end.timeIntervalSince(start) <= 86_400 else { return nil }
        return TimeSpan(start: start, end: end)
    }

    /// 둘 다 주었는데 끝이 시작보다 이르면 다음 날로 넘긴다(자정을 넘는 수면 등).
    static func retimed(start: Date, end: Date, newStart: Date?, newEnd: Date?) -> TimeSpan? {
        let from = newStart ?? start
        var to = newEnd ?? end
        if newStart != nil, newEnd != nil, to <= from { to = to.addingTimeInterval(86_400) }
        guard to > from, to.timeIntervalSince(from) <= 86_400 else { return nil }
        return TimeSpan(start: from, end: to)
    }
}
