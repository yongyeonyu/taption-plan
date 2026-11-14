import CryptoKit
import Foundation
import TaptionPlanCore

/// 하루 기록에 더하는 루틴·여행·수면 칸(AIR1110A03). 공유 수준이 「보내지 않음」이면 하루 기록째 보내지 않는다.
/// 좌표·주소는 넣지 않는다.
extension AssistantActivityDay {
    /// 그날에 걸친 루틴. `id`로 `updateGoal`·`deleteGoal`을 고른다. 날짜는 끝 날짜를 포함한다.
    struct Goal: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var start: String
        var end: String
    }

    struct Trip: Codable, Equatable, Sendable {
        struct Item: Codable, Equatable, Sendable {
            var stopId: String?
            var itemId: String?
            var title: String
            var order: Int?
            var start: String?
            var end: String?
            var status: String
        }

        /// 직접 만든 여행 일정은 null.
        var tripId: String?
        var items: [Item]
    }

    /// 수면 기록. `recordId`로 `updateSleep`을 고른다.
    struct Sleep: Codable, Equatable, Sendable {
        var recordId: String
        var start: String
        var end: String
        var minutes: Int
        var source: String
    }

    /// 가계부 기록(LED1110A01). 금액과 통화, 원화 환산. 장소·낸 사람·메모는 보내지 않는다.
    struct Expense: Codable, Equatable, Sendable {
        var id: String
        var time: String
        var title: String
        var category: String
        var kind: String
        var amount: Double
        var currency: String
        var amountKRW: Double?
    }

    /// 이 달 예산과 지금까지 쓴 돈(PLN1111A01 제안 4, T0 읽기). 오늘 날짜에만 싣는다.
    struct Budget: Codable, Equatable, Sendable {
        var month: String
        var amountKRW: Double
        var spentKRW: Double
    }

    /// 앱이 분류하지 못한 시간(아무 기록도 덮지 않은 틈). `classifyUnconfirmed`가 그 시각으로 채운다. 10분 넘는 것만.
    struct Unconfirmed: Codable, Equatable, Sendable {
        var start: String
        var end: String
        var minutes: Int
    }
}

extension AssistantActivityBuilder {
    static let goalLimit = 50
    static let tripLimit = 100

    static func addExtras(to result: inout AssistantActivityDay, _ input: AssistantActivityInput, day: TimeSpan, stamp: Stamp) {
        let goals = input.goals
            .filter { GoalRecordPolicy.isGoal($0) && $0.span.end > day.start && $0.span.start < day.end }
            .sorted { $0.span.start < $1.span.start }
            .prefix(goalLimit)
            .map { plan in
                AssistantActivityDay.Goal(
                    id: plan.id.uuidString, title: String(plan.title.prefix(200)),
                    start: stamp.date(plan.span.start), end: stamp.date(plan.span.end.addingTimeInterval(-1))
                )
            }
        if !goals.isEmpty { result.goals = Array(goals) }
        let trips = tripGroups(input, day: day, stamp: stamp)
        if !trips.isEmpty { result.trips = trips }
        let sleep = input.actuals
            .filter { $0.categoryID == "sleep" && $0.endedAt != nil }
            .compactMap { actual -> AssistantActivityDay.Sleep? in
                guard let span = actual.span(asOf: input.now).intersection(with: day), span.duration >= 60 else { return nil }
                let whole = actual.span(asOf: input.now)
                return AssistantActivityDay.Sleep(
                    recordId: actual.id.uuidString, start: stamp.instant(whole.start), end: stamp.instant(whole.end),
                    minutes: Int((whole.duration / 60).rounded()), source: isUserRecord(actual) ? "user" : "auto"
                )
            }
            .sorted { $0.start < $1.start }
        if !sleep.isEmpty { result.sleep = sleep }
        let expenses = input.ledger
            .filter { $0.occurredAt >= day.start && $0.occurredAt < day.end }
            .sorted { $0.occurredAt < $1.occurredAt }
            .prefix(memoLimit)
            .map {
                AssistantActivityDay.Expense(
                    id: $0.id.uuidString, time: stamp.instant($0.occurredAt), title: String($0.title.prefix(60)), category: $0.category.rawValue,
                    kind: $0.kind.rawValue, amount: $0.amount, currency: $0.currency, amountKRW: $0.amountKRW
                )
            }
        if !expenses.isEmpty { result.expenses = Array(expenses) }
        if let budget = input.budget, input.calendar.isDate(input.day, inSameDayAs: input.now) { result.budget = budget }
        // 아무 기록도 덮지 않은 틈만(화면의 미확인과 같은 계산). 사용자가 가린 기록은 기록이 있는 시간이라 틈이 아니다.
        let until = min(day.end, input.now)
        if until > day.start {
            let unconfirmed = ReviewCoverageEngine.unconfirmedRecords(actuals: input.actuals, in: [TimeSpan(start: day.start, end: until)], asOf: input.now)
                .compactMap { gap -> AssistantActivityDay.Unconfirmed? in
                    let span = gap.span(asOf: input.now)
                    guard span.duration >= unconfirmedMinimum else { return nil }
                    return AssistantActivityDay.Unconfirmed(
                        start: stamp.instant(span.start), end: stamp.instant(span.end), minutes: Int((span.duration / 60).rounded())
                    )
                }
                .sorted { $0.start < $1.start }
                .prefix(goalLimit)
            if !unconfirmed.isEmpty { result.unconfirmed = Array(unconfirmed) }
        }
    }

    static let unconfirmedMinimum: TimeInterval = 10 * 60

    /// 그날의 여행 핀과, 핀 없이 시간만 있는 여행 일정을 여행 번호로 묶는다.
    private static func tripGroups(_ input: AssistantActivityInput, day: TimeSpan, stamp: Stamp) -> [AssistantActivityDay.Trip] {
        let stops = TravelPlanSchedule.stops(on: day.start, in: input.tripStops, calendar: input.calendar)
        var groups: [String?: [AssistantActivityDay.Trip.Item]] = [:]
        var order: [String?] = []
        func add(_ tripID: String?, _ item: AssistantActivityDay.Trip.Item) {
            if groups[tripID] == nil { order.append(tripID) }
            groups[tripID, default: []].append(item)
        }
        var covered = Set<String>()
        for stop in stops.prefix(tripLimit) {
            let linked = input.tripItems.first { $0.tripID == stop.tripID && $0.itemID == stop.itemID && stop.itemID != nil }
            if let itemID = stop.itemID, let tripID = stop.tripID { covered.insert("\(tripID)|\(itemID)") }
            add(stop.tripID, .init(
                stopId: stop.id.uuidString, itemId: stop.itemID, title: String(stop.title.prefix(200)), order: stop.order,
                start: linked.map { stamp.instant($0.start) }, end: linked.map { stamp.instant($0.end) },
                status: TripItemStatus(raw: stop.status).rawValue
            ))
        }
        for item in input.tripItems where item.end > day.start && item.start < day.end && !covered.contains("\(item.tripID)|\(item.itemID)") {
            add(item.tripID, .init(
                stopId: nil, itemId: item.itemID, title: String(item.title.prefix(200)), order: nil,
                start: stamp.instant(item.start), end: stamp.instant(item.end), status: TripItemStatus(raw: item.status).rawValue
            ))
        }
        return order.map { AssistantActivityDay.Trip(tripId: $0, items: Array((groups[$0] ?? []).prefix(tripLimit))) }
    }
}

/// 앱 상태(ACX1112A01). AI가 `GET /app`(MCP `get_app_state`)으로 읽는다: 설정, 가계부 이 달 합계·예산·최근 기록,
/// 확인 필요, 받은 결제 문자, 결제 문자 규칙. 번호는 가리고, 좌표·백업 비밀번호·연결 키는 담지 않는다.
/// iOS 단축어 자동화가 있는지·켜졌는지는 앱이 알 수 없어 담지 않는다(받은 문자 수와 마지막 시각만).
struct AssistantAppState: Codable, Equatable, Sendable {
    struct Settings: Codable, Equatable, Sendable {
        var language: String
        var theme: String?
        var mapStyle: String
        var display: [String: Bool]
        var shareLevel: String
        var retentionDays: Int
        var aiConnections: Int
        /// 사용자가 꺼 둔 AI 동작.
        var actionsOff: [String]
        /// 앱에 「BOKKI 결제」 자동화 링크가 들어 있는가.
        var paymentShortcutLink: Bool
        var paymentTexts: Int
        var lastPaymentTextAt: String?
        /// NTF1112A01: 결제 앱 알림 자동화 링크가 있는가, 문자 자동화가 넘기는 낱말(하나라도 들면 넘어옴).
        var paymentAlertLink: Bool?
        var paymentTriggerWords: [String]?
        /// ACB1112A01: 통행료 차종과 급여 방식(정했을 때만).
        var tollVehicle: String?
        var salaryMode: String?
        /// ACC1112A01: `setSetting`으로 바꿀 수 있는 설정의 지금 값. 급여 금액도 담는다(PAY1112A01).
        var values: [String: String]?
        /// ACT1114A07: 결제 알림을 보낸 앱마다의 스위치, 넣지 않을 낱말, 직접 넣은 환율(1단위 = 원). 없으면 칸째 뺀다.
        var paymentSources: [PaymentSource]?
        var skipWords: [String]?
        var fxRates: [String: Double]?
    }

    struct PaymentSource: Codable, Equatable, Sendable {
        var name: String
        var expense: Bool
        var income: Bool
    }

    struct Entry: Codable, Equatable, Sendable {
        var id: String
        var time: String
        var title: String
        var category: String
        var kind: String
        var amount: Double
        var currency: String
        var amountKRW: Double?
        var canceled: Bool
        var source: String
        /// 여행 장부에 든 기록이면 그 장부 id(ACT1114A07).
        var tripId: String?
    }

    struct Ledger: Codable, Equatable, Sendable {
        var month: String
        var budgetKRW: Double?
        var spentKRW: Double
        var incomeKRW: Double
        var ownAccounts: [String]
        var entries: [Entry]
        /// TBG1112A01: 여행 장부. 동행 이름은 담지 않는다. 없으면 칸째 뺀다.
        var trips: [TripLedger]?
    }

    struct TripLedger: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var start: String
        var end: String
        var budgetKRW: Double?
        /// 내 몫(지금까지 든 돈).
        var myCostKRW: Double
        /// 정산하면 일상으로 돌아올 돈(−면 더 보낼 돈).
        var leftoverKRW: Double
        var ended: Bool
    }

    struct Review: Codable, Equatable, Sendable {
        var id: String
        var reason: String
        var receivedAt: String
        var time: String
        var title: String
        var category: String
        var kind: String
        var amount: Double
        var currency: String
    }

    struct Inbox: Codable, Equatable, Sendable {
        var id: String
        var receivedAt: String
        var outcome: String
        var message: String
        var text: String
    }

    struct Rule: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var kind: String
        var pattern: String
    }

    /// 등록한 장소(ACA1112A01). 좌표·주소는 담지 않고 자리가 정해졌는지만 알린다.
    struct Place: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var kind: String
        var radius: Int
        var autoRecord: Bool
        var located: Bool
    }

    /// 여행 하나(ACB1112A01). 날짜를 정하지 않은 여행은 `wishDays`만 있다. 좌표는 담지 않는다.
    struct Trip: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var start: String?
        var end: String?
        var wishDays: Int?
        var country: String?
        var region: String?
        var currency: String?
    }

    struct Category: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var color: String
        var icon: String
        var hidden: Bool
        var custom: Bool
    }

    var format = "bokki-app"
    var version = 1
    var retentionDays: Int
    var updatedAt: String?
    var timeZone: String
    var settings: Settings
    var ledger: Ledger
    var review: [Review]
    var inbox: [Inbox]
    var rules: [Rule]
    /// 비면 칸째 뺀다. 장소는 「머문 곳 이름과 시각」 공유 수준에서만.
    var places: [Place]?
    var categories: [Category]?
    var trips: [Trip]?
    /// HND1112A01: 앱이 등록을 제안하는 자리(장소 이름 공유 수준에서만, 좌표 없음)와 차 오디오 기기 이름.
    var placeSuggestion: PlaceSuggestion?
    var carAudio: CarAudio?

    struct PlaceSuggestion: Codable, Equatable, Sendable {
        var id: String
        var name: String?
        var visits: Int
    }

    struct CarAudio: Codable, Equatable, Sendable {
        var registered: [String]
        var pending: [String]
    }

    /// ACT1114A07: 답을 기다리는 탑승 후보(장소 이름 공유 수준에서만). 역·정류장 이름과 시각만, 좌표는 담지 않는다.
    var boarding: [Boarding]?

    struct Boarding: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var kind: String
        var mode: String
        var start: String
        var end: String
    }
}

/// 앱 상태를 중계 서버에 올린다. 하루 기록을 올린 뒤 함께 돌고, 바뀌었을 때만(또는 20시간마다) 보낸다.
@MainActor
enum AssistantAppStateSync {
    static let hashKey = "assistantAppStateHash"
    static let sentAtKey = "assistantAppStateSentAt"
    static let entryLimit = 100
    static let inboxTextLimit = 300
    static let bodyLimit = 60_000
    static let resendAfter: TimeInterval = 20 * 3_600

    /// 재료. 앱에서 모으고, 시험은 직접 만든다.
    struct Input {
        var now: Date
        var calendar: Calendar
        var language: String
        var mapStyle: MapDisplayStyle
        var display: [String: Bool]
        var shareLevel: AssistantShareLevel
        var retentionDays: Int
        var aiConnections: Int
        var actionsOff: [AssistantActionKind]
        var paymentShortcutLink: Bool
        var paymentAlertLink: Bool = false
        /// 이체 짝 기록을 뺀 가계부 기록.
        var entries: [LedgerEntry]
        var budgetKRW: Double?
        var spentKRW: Double
        var incomeKRW: Double
        var ownAccounts: [String]
        var review: [LedgerReviewStore.Item]
        /// 여행 장부(TBG1112A01). `entries`와 함께 정산을 계산한다.
        var ledgerTrips: [LedgerTrip] = []
        /// 여행 장부의 정산에 쓰는 기록 전체(이체 짝 기록 포함).
        var tripEntries: [LedgerEntry] = []
        var inbox: [PaymentInbox.Item]
        var rules: [LedgerMessageRules.Rule]
        var places: [FrequentPlace] = []
        var categories: [CategoryDefinition] = []
        var trips: [TravelTrip] = []
        var placeSuggestion: FrequentPlaceSuggestion?
        var registeredCarAudio: [String] = []
        var pendingCarAudio: [String] = []
        var tollVehicle: String?
        var salaryMode: String?
        var settingValues: [String: String] = [:]
        var paymentSources: [PaymentAlertSources.Source] = []
        var skipWords: [String] = []
        var fxRates: [String: Double] = [:]
        var boarding: [TransitBoardingCandidate] = []
    }

    static func make(_ input: Input) -> AssistantAppState {
        let stamp = AssistantActivityBuilder.Stamp(calendar: input.calendar)
        let mask = { (text: String, limit: Int) in String(AITaskQueue.mask(text).prefix(limit)) }
        return AssistantAppState(
            retentionDays: input.retentionDays, timeZone: input.calendar.timeZone.identifier,
            settings: .init(
                language: input.language, theme: AssistantCommandParser.themes.first { $0.style == input.mapStyle }?.name,
                mapStyle: input.mapStyle.rawValue, display: input.display, shareLevel: input.shareLevel.rawValue,
                retentionDays: input.retentionDays, aiConnections: input.aiConnections, actionsOff: input.actionsOff.map(\.rawValue),
                paymentShortcutLink: input.paymentShortcutLink, paymentTexts: input.inbox.count,
                lastPaymentTextAt: input.inbox.map(\.receivedAt).max().map(stamp.instant),
                paymentAlertLink: input.paymentAlertLink, paymentTriggerWords: input.paymentShortcutLink ? BokkiPaymentShortcut.triggerWords : nil,
                tollVehicle: input.tollVehicle, salaryMode: input.salaryMode,
                values: input.settingValues.isEmpty ? nil : input.settingValues,
                paymentSources: input.paymentSources.isEmpty ? nil : input.paymentSources.prefix(PaymentAlertSources.limit).map {
                    .init(name: mask($0.name, 40), expense: $0.expense, income: $0.income)
                },
                skipWords: input.skipWords.isEmpty ? nil : input.skipWords.prefix(PaymentAlertSources.skipWordLimit).map { mask($0, 20) },
                fxRates: input.fxRates.isEmpty ? nil : input.fxRates
            ),
            ledger: .init(
                month: LedgerBook.monthKey(input.now, calendar: input.calendar), budgetKRW: input.budgetKRW,
                spentKRW: input.spentKRW, incomeKRW: input.incomeKRW, ownAccounts: input.ownAccounts.prefix(LedgerOwnAccounts.limit).map { mask($0, 30) },
                entries: input.entries.sorted { $0.occurredAt > $1.occurredAt }.prefix(entryLimit).map {
                    .init(
                        id: $0.id.uuidString, time: stamp.instant($0.occurredAt), title: mask($0.title, 60), category: $0.category.rawValue,
                        kind: $0.kind.rawValue, amount: $0.amount, currency: $0.currency, amountKRW: $0.amountKRW,
                        canceled: $0.canceledAt != nil, source: $0.source.rawValue, tripId: $0.tripID
                    )
                },
                trips: input.ledgerTrips.isEmpty ? nil : input.ledgerTrips.prefix(AssistantCatalogLimits.places).map { trip in
                    let sheet = LedgerTripMath.sheet(trip, entries: input.tripEntries)
                    return .init(
                        id: trip.id, name: mask(trip.name, AssistantSetting.tripTitleLimit), start: stamp.date(trip.start), end: stamp.date(trip.end),
                        budgetKRW: trip.budgetKRW, myCostKRW: sheet.myCost, leftoverKRW: sheet.leftover,
                        ended: trip.hasEnded(asOf: input.now, calendar: input.calendar)
                    )
                }
            ),
            review: input.review.suffix(LedgerReviewStore.limit).map {
                .init(
                    id: $0.id.uuidString, reason: $0.reason.rawValue, receivedAt: stamp.instant($0.receivedAt), time: stamp.instant($0.entry.occurredAt),
                    title: mask($0.entry.title, 60), category: $0.entry.category.rawValue, kind: $0.entry.kind.rawValue,
                    amount: $0.entry.amount, currency: $0.entry.currency
                )
            },
            inbox: input.inbox.suffix(PaymentInbox.limit).map {
                .init(
                    id: $0.id.uuidString, receivedAt: stamp.instant($0.receivedAt), outcome: $0.outcome.rawValue,
                    message: mask($0.message, 200), text: mask($0.text, inboxTextLimit)
                )
            },
            rules: input.rules.suffix(LedgerMessageRules.limit).map {
                .init(id: $0.id.uuidString, name: mask($0.name, 40), kind: $0.kind.rawValue, pattern: mask($0.pattern, 300))
            },
            places: input.shareLevel == .visits && !input.places.isEmpty ? input.places.prefix(AssistantCatalogLimits.places).map {
                .init(
                    id: $0.id.uuidString, name: mask($0.displayName, AssistantCatalogLimits.placeName), kind: $0.kind.rawValue,
                    radius: Int($0.radiusMeters.rounded()), autoRecord: $0.isAutomaticRecordingEnabled, located: $0.point != nil
                )
            } : nil,
            categories: input.categories.isEmpty ? nil : input.categories.filter { $0.id != "unconfirmed" }.prefix(AssistantCatalogLimits.places).map {
                .init(id: $0.id, name: mask($0.name, 40), color: $0.lightHex, icon: $0.icon.rawValue, hidden: $0.isHidden, custom: !$0.isBuiltIn)
            },
            trips: input.trips.isEmpty ? nil : input.trips.prefix(AssistantCatalogLimits.places).map {
                .init(
                    id: $0.id, title: mask($0.title, AssistantSetting.tripTitleLimit), start: $0.startDay.isEmpty ? nil : $0.startDay,
                    end: $0.endDay.isEmpty ? nil : $0.endDay, wishDays: $0.isWish ? $0.wishDays : nil, country: $0.countryCode,
                    region: $0.regionName.map { mask($0, 40) }, currency: $0.currencyCode
                )
            },
            placeSuggestion: input.shareLevel == .visits ? input.placeSuggestion.map {
                .init(
                    id: $0.id, name: $0.suggestedName.flatMap { AssistantActivityBuilder.isAddressLike($0) ? nil : mask($0, AssistantCatalogLimits.placeName) },
                    visits: $0.visitCount
                )
            } : nil,
            carAudio: input.registeredCarAudio.isEmpty && input.pendingCarAudio.isEmpty ? nil
                : .init(registered: input.registeredCarAudio.prefix(20).map { mask($0, 60) }, pending: input.pendingCarAudio.prefix(20).map { mask($0, 60) }),
            boarding: input.shareLevel == .visits && !input.boarding.isEmpty ? input.boarding.prefix(AssistantBoardingCandidates.limit).map {
                .init(
                    id: AssistantBoardingCandidates.publicID($0), name: mask($0.name, 40), kind: $0.kind.rawValue,
                    mode: AssistantActivityBuilder.mode($0.mode), start: stamp.instant($0.span.start), end: stamp.instant($0.span.end)
                )
            } : nil
        )
    }

    /// 서버의 64KB 제한 안에 들도록 오래된 가계부 기록부터 절반씩 덜어 낸다.
    static func body(_ state: AssistantAppState, limit: Int = bodyLimit) -> Data? {
        var value = state
        while true {
            guard let data = try? AssistantActivityUploadGate.encoder.encode(value) else { return nil }
            if data.count <= limit { return data }
            guard !value.ledger.entries.isEmpty else { return nil }
            value.ledger.entries = Array(value.ledger.entries.prefix(value.ledger.entries.count / 2))
        }
    }

    /// `updatedAt`은 매번 바뀌므로 빼고 잰다.
    static func hash(_ state: AssistantAppState) -> String {
        var stable = state
        stable.updatedAt = nil
        let data = (try? AssistantActivityUploadGate.encoder.encode(stable)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func input(model: AppModel, preferences: AssistantPreferenceStore, now: Date, calendar: Calendar) async -> Input {
        let defaults = preferences.defaults, book = preferences.ledger
        await book.load()
        let month = LedgerBook.monthKey(now, calendar: calendar)
        let daily = book.entries(inMonth: month, calendar: calendar).filter(book.isDaily)
        return Input(
            now: now, calendar: calendar,
            language: preferences.value(AssistantPreferenceChange.languageKey) ?? AppLanguagePreference.automatic.rawValue,
            mapStyle: model.snapshot.settings.mapDisplayStyle,
            display: Dictionary(uniqueKeysWithValues: AssistantDisplayOption.allCases.map { ($0.rawValue, preferences.value($0.defaultsKey) != "false") }),
            shareLevel: AssistantShareLevel.current(defaults), retentionDays: AssistantRetention.current(defaults).rawValue,
            aiConnections: AssistantKeyLabels.connectionCount(defaults),
            actionsOff: AssistantActionKind.allCases.filter { !AssistantActionToggles.isEnabled($0, defaults: defaults) },
            paymentShortcutLink: BokkiPaymentShortcut.hasAutomationLink, paymentAlertLink: BokkiPaymentShortcut.alertLink != nil,
            entries: book.entries.filter { $0.transfer == nil }, budgetKRW: book.budget(for: month)?.amountKRW,
            spentKRW: LedgerBook.total(daily, .expense), incomeKRW: LedgerBook.total(daily, .income),
            ownAccounts: LedgerOwnAccounts.names(defaults), review: preferences.review.items,
            ledgerTrips: book.trips, tripEntries: book.entries,
            inbox: PaymentInbox.items(defaults, now: now), rules: LedgerMessageRules.rules(defaults),
            places: model.snapshot.settings.frequentPlaces, categories: model.snapshot.categories,
            trips: model.snapshot.settings.travelTrips ?? [],
            placeSuggestion: model.frequentPlaceSuggestion,
            registeredCarAudio: model.settings.registeredCarAudioNames,
            pendingCarAudio: model.settings.recentCarAudioNames.filter {
                !model.settings.registeredCarAudioNames.contains($0) && !model.settings.dismissedCarAudioNames.contains($0)
            },
            tollVehicle: AssistantSetting.tollVehicle.read(defaults),
            salaryMode: MapHomeSalaryPolicy.isAILinked(defaults) ? AssistantSetting.salaryMode.read(defaults) : nil,
            settingValues: Dictionary(uniqueKeysWithValues: AssistantSetting.allCases
                .filter { !$0.isSalary || MapHomeSalaryPolicy.isAILinked(defaults) }.compactMap { setting in
                (setting.isModelBacked ? setting.read(model: model) : setting.read(defaults)).map { (setting.rawValue, $0) }
            }),
            paymentSources: PaymentAlertSources.all(defaults), skipWords: PaymentAlertSources.skipWords(defaults),
            fxRates: (defaults.dictionary(forKey: LedgerBook.manualRatesKey) as? [String: Double]) ?? [:],
            boarding: AssistantBoardingCandidates.current
        )
    }

    /// 공유를 껐으면 서버 사본을 한 번 지운다. 사생활 잠금 중에는 올리지 않는다.
    static func run(
        model: AppModel, defaults: UserDefaults = .standard, env: AssistantRegistration.Environment = .live, now: Date = .now
    ) async {
        guard let master = env.secrets.read(.master) else { return }
        guard AssistantShareLevel.current(defaults) != .off else {
            guard defaults.string(forKey: hashKey) != nil else { return }
            let reply = await TripRelay.send(TripRelay.relayRequest("/app", method: "DELETE", token: master, host: env.host), session: env.session)
            if let reply, (200..<300).contains(reply.status) { defaults.removeObject(forKey: hashKey) }
            return
        }
        guard !TaptionExternalPrivacyStore.isLocked else { return }
        let calendar = Calendar.autoupdatingCurrent
        let preferences: AssistantPreferenceStore = defaults === UserDefaults.standard ? .live : .test(defaults)
        var state = make(await input(model: model, preferences: preferences, now: now, calendar: calendar))
        let tag = hash(state)
        let isFresh = now.timeIntervalSince1970 - defaults.double(forKey: sentAtKey) < resendAfter
        guard defaults.string(forKey: hashKey) != tag || !isFresh else { return }
        state.updatedAt = AssistantActivityBuilder.Stamp(calendar: calendar).instant(now)
        guard let payload = body(state),
              let reply = await TripRelay.send(TripRelay.relayRequest("/app", method: "POST", body: payload, token: master, host: env.host), session: env.session),
              reply.status == 201 else { return }
        defaults.set(tag, forKey: hashKey)
        defaults.set(now.timeIntervalSince1970, forKey: sentAtKey)
    }
}
