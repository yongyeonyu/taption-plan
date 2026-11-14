import Foundation
import TaptionLedgerCore
import TaptionPlanCore
import TaptionPlanStore
import TaptionRules
import TaptionWatchSync

// 명령과 명령 묶음(RMN1114A25). 읽기(`AssistantCommandParser.parse`)와 반영은 아직 앱에 있다.

/// AI 비서가 보낸 명령 하나(TRP1110A07). 앱이 열릴 때 묻지 않고 반영하고 알림만 남긴다(대표 결정).
public struct AssistantCommand: Identifiable, Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case addMemo(text: String, at: Date)
        case addSchedule(title: String, start: Date, end: Date?, note: String?, extras: AssistantScheduleExtras = .init())
        /// 하루 안의 기록 하나를 고친다. id가 없으면 `startTime`을 덮는 기록을 찾는다.
        case updateActivity(day: Date, recordID: String?, startTime: Date?, title: String?, categoryID: String?)
        /// 자동 기록을 미확인(유령)으로 교정해 가린다. 원본 행은 남는다(CLN1110A01).
        case hideRecord(day: Date, recordID: String?, startTime: Date?)
        /// 이어진 기록 2~20개를 사용자 덮개 기록 하나로 합친다(CLN1110A01).
        case mergeRecords(day: Date, recordIDs: [String], title: String?, categoryID: String?)
        /// 표시 시간만 교정표로 바꾼다. 시각은 그날의 HH:mm(CLN1110A01).
        case updateRecordTime(day: Date, recordID: String, start: Date?, end: Date?)
        case updateSchedule(
            target: AssistantPlanTarget, title: String?, start: AssistantScheduleTime?, end: AssistantScheduleTime?, note: String?,
            extras: AssistantScheduleExtras = .init()
        )
        case deleteSchedule(target: AssistantPlanTarget)
        /// ACT1114A07: `text`가 nil이면 글은 그대로 두고 때만 옮긴다.
        case updateMemo(memoID: String, text: String?, when: AssistantWhenChange = .init())
        case deleteMemo(memoID: String)
        /// 루틴(상위 계획)·여행 일정·수면·안전한 표시 설정(AIR1110A03). 모두 되돌릴 수 있는 사용자 편집이다.
        case addGoal(title: String, start: Date, end: Date, categoryID: String?)
        case updateGoal(goalID: String, title: String?, start: Date?, end: Date?, categoryID: String?)
        case deleteGoal(goalID: String)
        /// 좌표가 없으면 이름으로 찾는다. `tripID`를 주면 그 여행에 붙인다(REV1110A06).
        case addTripStop(title: String, day: Date, coordinate: AssistantCoordinate?, status: TripItemStatus?, tripID: String?)
        case updateTripStop(stopID: String, title: String?, day: Date?, order: Int?, status: TripItemStatus?)
        case deleteTripStop(stopID: String)
        case setTripItemStatus(tripID: String, itemID: String, status: TripItemStatus)
        case updateSleep(recordID: String, start: AssistantScheduleTime?, end: AssistantScheduleTime?)
        case setLanguage(AppLanguagePreference)
        case setMapStyle(MapDisplayStyle)
        case setDisplayOption(AssistantDisplayOption, enabled: Bool)
        /// 그날 그 시각 사이 화랑이 말풍선 글(BUB1110A01). 기록은 바꾸지 않는다.
        case setBubble(start: Date, end: Date, text: String, kind: AssistantBubbleKind = .routine)
        /// 가계부 기록 하나(LED1110A01). 되돌리면 지운다.
        case addExpense(LedgerEntry)
        /// AIQ1111A01: 있는 가계부 기록 고치기·지우기. nil인 칸은 그대로 둔다.
        case updateExpense(entryID: UUID, change: AssistantExpenseChange)
        /// ACT1111A01: 앱이 분류하지 못한 시간을 분류로 채운다. 아직 미확인인 부분만 사용자 기록으로 남는다.
        case classifyUnconfirmed(start: Date, end: Date, title: String?, categoryID: String)
        /// ACT1111A01: 이동 구간 하나의 수단을 사용자 교정으로 바꾼다.
        /// RDQ1114A01: `line`은 버스 번호나 지하철 노선(없어도 됨).
        case setTravelMode(moveID: UUID, mode: TravelMode, line: String? = nil)
        /// PRL1112A01: 결제 문자 읽기 규칙. 견본과 맞는지 본 것만 담는다.
        case addPaymentRule(LedgerMessageRule)
        /// ACX1112A01: 가계부 설정과 정리, 화면 열기. 0원은 그 달 예산을 없앤다.
        case setBudget(month: String, amountKRW: Double)
        case addOwnAccount(String)
        case removeOwnAccount(String)
        case deletePaymentRule(UUID)
        /// 「확인 필요」 하나를 가계부에 넣거나(`add`) 버린다.
        case resolveReview(UUID, add: Bool)
        case deleteInboxItem(UUID)
        /// 앱이 앞에 있을 때 화면을 띄운다. 자료는 바꾸지 않는다.
        case openScreen(AssistantScreen)
        /// ASK1112A01: 앱에서 객관식으로 묻는다. 기록은 바꾸지 않고, 답은 앱이 서버에 올린다.
        case askUser(AssistantQuestion)
        /// ACA1112A01: 자주 가는 장소와 분류. nil인 칸은 그대로 둔다. 좌표는 받기만 한다.
        case addPlace(name: String, coordinate: AssistantCoordinate?, radius: Double?, autoRecord: Bool?)
        case updatePlace(placeID: UUID, name: String?, coordinate: AssistantCoordinate?, radius: Double?, autoRecord: Bool?)
        case deletePlace(UUID)
        case addCategory(name: String, color: String, icon: CategoryIcon?)
        case updateCategory(categoryID: String, name: String?, color: String?, icon: CategoryIcon?, hidden: Bool?)
        /// ACB1112A01: 여행 만들기·고치기·지우기와 기기 설정 하나 바꾸기(값은 정해진 글자 꼴).
        case addTrip(TravelTrip)
        case updateTrip(tripID: String, title: String?, start: String?, end: String?)
        case deleteTrip(tripID: String)
        case setSetting(AssistantSetting, value: String)
        /// ACD1112A01: 혼자 할 수 없는 일의 승인 요청. 앱에서 승인해야 실행된다.
        case requestApproval(AssistantQuestion)
        /// HND1112A01: 앱의 「확인할 것」을 끝낸다 — 자주 머무는 곳 제안, 내 차, 일정 제목 분류(`detailID` nil은 분류 안 함).
        case resolvePlaceSuggestion(register: Bool, name: String?, kind: FrequentPlaceKind?)
        case setCarAudio(name: String, isMyCar: Bool)
        case setCalendarTitleDetail(title: String, detailID: String?)
        /// TBG1112A01: 여행 예산(원). 0이면 예산 없음.
        case setTripBudget(tripID: String, budgetKRW: Double)
        /// ACT1114A07: 등록부(`AssistantOperations`)의 동작. 새 동작은 이 한 줄로 다 받는다.
        case operation(AssistantParsedOperation)
    }

    public let id: String
    public let action: Action
    /// 보낸 연결 키 id(키 해시 앞 8글자)와 방식 "rest"·"mcp"·"oauth"(SEC1110A02).
    public var keyID: String? = nil
    public var source: String? = nil
    /// 이 명령이 어느 맡긴 일 때문에 온 것인지(AIP1114A05). AI가 붙여 보낸 일 id.
    public var taskID: String? = nil

    public init(id: String, action: Action, keyID: String? = nil, source: String? = nil, taskID: String? = nil) {
        self.id = id
        self.action = action
        self.keyID = keyID
        self.source = source
        self.taskID = taskID
    }
}

public struct AssistantCommandBatch: Equatable, Sendable {
    public var commands: [AssistantCommand]
    /// 형식이 틀린 명령. 반영하지 않고 거절로 알린다.
    public var invalidIDs: [String]
    /// 형식이 틀린 명령 가운데 종류를 아는 것(AIP1114A05). 「AI가 한 일」에 거절로 남길 때 쓴다.
    public var invalidInfo: [String: Invalid] = [:]

    public struct Invalid: Equatable, Sendable {
        public var kind: AssistantActionKind
        public var keyID: String?
        public var source: String?
        public var taskID: String?

        public init(kind: AssistantActionKind, keyID: String? = nil, source: String? = nil, taskID: String? = nil) {
            self.kind = kind
            self.keyID = keyID
            self.source = source
            self.taskID = taskID
        }
    }

    public init(commands: [AssistantCommand], invalidIDs: [String], invalidInfo: [String: Invalid] = [:]) {
        self.commands = commands
        self.invalidIDs = invalidIDs
        self.invalidInfo = invalidInfo
    }

    public func excluding(_ ids: Set<String>) -> Self {
        Self(commands: commands.filter { !ids.contains($0.id) }, invalidIDs: invalidIDs.filter { !ids.contains($0) }, invalidInfo: invalidInfo)
    }
}

extension AssistantCommand.Action {
    public var kind: AssistantActionKind {
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
        case .setTripBudget: .setTripBudget
        case let .operation(parsed): .operation(parsed.name)
        }
    }
}
