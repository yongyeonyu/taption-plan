import Foundation

/// 하루 카드 1시간 전에 연결된 AI에게 말풍선을 다듬어 달라고 맡긴다(DCB1116A01).
/// 카드 알림을 눌러 열면 오늘 지도 위에 카드가 뜨므로, AI는 어제를 읽고 오늘의 event 말풍선을 쓴다.
/// iOS가 그 시각에 깨운다는 보장이 없어, 앱이 앞으로 오거나 백그라운드 새로고침이 돌 때 창 안이면 올린다.
/// 연결이 없으면 넣지 않고 기억도 남기지 않는다. 새 서버 종류 없이 `.other`로 보낸다.
enum DailyCardBubblePrompt {
    static let lead: TimeInterval = 60 * 60
    static let sentKey = "dailyCardBubblePromptDay"

    /// 지금 올릴 카드 시각. 창(카드 −1시간 ~ 카드 시각 전)이 아니거나, 꺼졌거나, 그 카드 날에 이미 올렸으면 nil.
    static func due(now: Date, time: DateComponents, enabled: Bool, lastSent: String?, calendar: Calendar) -> Date? {
        guard enabled, let card = nextCard(after: now, time: time, calendar: calendar),
              card.timeIntervalSince(now) <= lead, lastSent != dayKey(card, calendar: calendar) else { return nil }
        return card
    }

    /// 백그라운드 새로고침 예약 시각. 다음 창 시작이 앞으로 올 시각이고 지금 예약보다 이르면 그때로 당긴다.
    /// 이미 창 안이면 당기지 않는다(새로고침마다 곧바로 다시 깨우는 고리를 만들지 않게).
    static func earliestBegin(now: Date, defaultDate: Date, time: DateComponents, enabled: Bool, calendar: Calendar) -> Date {
        guard enabled, let card = nextCard(after: now, time: time, calendar: calendar) else { return defaultDate }
        let start = card.addingTimeInterval(-lead)
        return start > now && start < defaultDate ? start : defaultDate
    }

    /// 지금보다 뒤의 가장 가까운 카드 시각. 정확히 그 시각이면 이미 나가는 중이라 다음 날로 본다.
    static func nextCard(after now: Date, time: DateComponents, calendar: Calendar) -> Date? {
        var match = DateComponents()
        match.hour = time.hour ?? 8
        match.minute = time.minute ?? 0
        match.second = 0
        return calendar.nextDate(after: now, matching: match, matchingPolicy: .nextTime)
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// AI에게 보낼 글과 context. 좌표·개인 정보는 넣지 않는다.
    static func request(card: Date, calendar: Calendar) -> (text: String, context: [String: String]) {
        let today = dayKey(card, calendar: calendar)
        let yesterday = dayKey(calendar.date(byAdding: .day, value: -1, to: card) ?? card, calendar: calendar)
        let parts = calendar.dateComponents([.hour, .minute], from: card)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        let text = "\(today) \(clock)에 어제(\(yesterday)) 하루 카드 알림이 나갑니다. 카드를 열면 오늘 지도 위 화랑이 말풍선이 함께 보입니다. "
            + "get_activity로 \(yesterday)를 읽고, set_bubble로 date \(today), kind \"event\" 말풍선을 어제 하루에 맞게 다듬어 주세요(보이는 글 80자 이내)."
        return (text, ["purpose": "daily_card_bubble", "cardDate": today, "readDate": yesterday, "cardTime": clock, "bubbleKind": "event"])
    }

    /// 창 안이고 아직 안 올렸으면 맡긴다. 넣었으면 true.
    @MainActor @discardableResult
    static func runIfDue(now: Date = .now, authorized: Bool, defaults: UserDefaults = .standard,
                         calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let enabled = authorized && MapHomeAlarmSettings.stored(defaults).enabled.contains(.dailyCard)
        guard let card = due(now: now, time: MapHomeAlarmSettings.dailyCardTime(defaults), enabled: enabled,
                             lastSent: defaults.string(forKey: sentKey), calendar: calendar) else { return false }
        let request = request(card: card, calendar: calendar)
        guard AITaskQueue.enqueue(.other, text: request.text, day: card, context: request.context, defaults: defaults) else { return false }
        defaults.set(dayKey(card, calendar: calendar), forKey: sentKey)
        return true
    }

    /// 알림 권한을 읽고 판단한다. 앞으로 올 때·백그라운드 새로고침 때 부른다.
    @MainActor
    static func run() async {
        let authorized = await MapHomeAlarmCenter.shared.isAuthorized()
        runIfDue(authorized: authorized)
    }

    /// 백그라운드 새로고침 예약에 쓰는 시각.
    static func earliestBegin(defaultDate: Date, now: Date = .now, defaults: UserDefaults = .standard) -> Date {
        earliestBegin(now: now, defaultDate: defaultDate, time: MapHomeAlarmSettings.dailyCardTime(defaults),
                      enabled: MapHomeAlarmSettings.stored(defaults).enabled.contains(.dailyCard), calendar: .autoupdatingCurrent)
    }
}
