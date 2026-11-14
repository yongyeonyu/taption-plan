import CoreMotion
import MapKit
import Photos
import SwiftUI
import UserNotifications

/// 사용자가 받을 수 있는 알림 종류. 장소 도착·출발은 등록한 장소 기록으로, 기상은 수면 구간 종료로, 시급은 연봉 카운터로 만든다.
enum MapHomeAlarmKind: String, CaseIterable, Codable, Identifiable {
    case arriveCompany, leaveCompany
    case arriveSchool, leaveSchool
    case arriveAcademy, leaveAcademy
    case arriveHome, leaveHome
    case wakeUp
    case dailyCard
    case rateChange, breakEven

    var id: String { rawValue }

    enum Group: String, CaseIterable {
        case place, day, salary
        func title(_ language: MapHomeLanguage) -> String {
            switch self {
            case .place: language.text("장소", "Places")
            case .day: language.text("하루", "Day")
            case .salary: language.text("연봉 카운터", "Salary counter")
            }
        }
    }

    var group: Group {
        switch self {
        case .wakeUp, .dailyCard: .day
        case .rateChange, .breakEven: .salary
        default: .place
        }
    }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .arriveCompany: language.text("출근했어요", "Arrived at work")
        case .leaveCompany: language.text("퇴근했어요", "Left work")
        case .arriveSchool: language.text("등교했어요", "Arrived at school")
        case .leaveSchool: language.text("하교했어요", "Left school")
        case .arriveAcademy: language.text("학원에 도착했어요", "Arrived at academy")
        case .leaveAcademy: language.text("학원에서 나왔어요", "Left academy")
        case .arriveHome: language.text("집에 왔어요", "Home")
        case .leaveHome: language.text("외출했어요", "Left home")
        case .wakeUp: language.text("일어났어요", "Woke up")
        case .dailyCard: language.text("어제 하루 요약 카드", "Yesterday's day card")
        case .rateChange: language.text("시급 변동(±3%)", "Hourly rate moved (±3%)")
        case .breakEven: language.text("퇴근 손익분기", "Overtime break-even")
        }
    }

    func detail(_ language: MapHomeLanguage) -> String {
        switch self {
        case .arriveCompany, .arriveSchool, .arriveAcademy, .arriveHome:
            language.text("등록한 장소에 머물기 시작하면 알려요.", "When a stay at the registered place begins.")
        case .leaveCompany, .leaveSchool, .leaveAcademy, .leaveHome:
            language.text("장소를 떠나 3분이 지나면 알려요.", "Three minutes after leaving the place.")
        case .wakeUp: language.text("수면 구간이 끝나면 알려요(하루 한 번).", "When the sleep span ends (once a day).")
        case .dailyCard: language.text("설정한 시각(기본 오전 8시)에 어제 카드를 보고 저장·공유할 수 있어요.", "At your set time (8:00 by default) open yesterday's card to save or share.")
        case .rateChange: language.text("추정 시급이 3% 이상 움직이면 알려요(30분에 한 번).", "When the estimated rate moves 3%+ (max every 30 min).")
        case .breakEven: language.text("근무 중 1시간 안에 시급이 기준의 90% 아래로 내려가면 알려요.", "When another hour of work would push the rate below 90% of base.")
        }
    }

    var systemImage: String {
        switch self {
        case .arriveCompany, .leaveCompany: "briefcase.fill"
        case .arriveSchool, .leaveSchool: "graduationcap.fill"
        case .arriveAcademy, .leaveAcademy: "book.fill"
        case .arriveHome, .leaveHome: "house.fill"
        case .wakeUp: "sunrise.fill"
        case .dailyCard: "photo.on.rectangle.angled"
        case .rateChange: "chart.line.uptrend.xyaxis"
        case .breakEven: "clock.badge.exclamationmark"
        }
    }

    /// 장소 종류별 도착·출발 알림.
    static func arrive(_ kind: FrequentPlaceKind) -> MapHomeAlarmKind? {
        switch kind {
        case .company: .arriveCompany
        case .school: .arriveSchool
        case .academy: .arriveAcademy
        case .home: .arriveHome
        default: nil
        }
    }

    static func leave(_ kind: FrequentPlaceKind) -> MapHomeAlarmKind? {
        switch kind {
        case .company: .leaveCompany
        case .school: .leaveSchool
        case .academy: .leaveAcademy
        case .home: .leaveHome
        default: nil
        }
    }
}

struct MapHomeAlarmSettings: Equatable {
    static let storageKey = "mapHomeAlarmSettings"
    static let defaultEnabled: Set<MapHomeAlarmKind> = [.arriveCompany, .leaveCompany, .wakeUp, .dailyCard]
    var enabled: Set<MapHomeAlarmKind>

    init(enabled: Set<MapHomeAlarmKind> = MapHomeAlarmSettings.defaultEnabled) { self.enabled = enabled }

    init(rawValue: String) {
        let kinds = rawValue.data(using: .utf8).flatMap { try? JSONDecoder().decode([MapHomeAlarmKind].self, from: $0) }
        enabled = kinds.map(Set.init) ?? MapHomeAlarmSettings.defaultEnabled
    }

    var rawValue: String {
        (try? String(data: JSONEncoder().encode(enabled.map(\.rawValue).sorted().compactMap(MapHomeAlarmKind.init(rawValue:))), encoding: .utf8)) ?? "[]"
    }

    /// 하루 카드 알림 시각(기본 오전 8시). 사용자가 설정에서 바꾼다.
    static let dailyCardHourKey = "mapHomeDailyCardHour"
    static let dailyCardMinuteKey = "mapHomeDailyCardMinute"
    static var dailyCardTime: DateComponents { dailyCardTime(.standard) }

    static func dailyCardTime(_ defaults: UserDefaults) -> DateComponents {
        let hasValue = defaults.object(forKey: dailyCardHourKey) != nil
        return DateComponents(
            hour: hasValue ? defaults.integer(forKey: dailyCardHourKey) : 8,
            minute: defaults.integer(forKey: dailyCardMinuteKey)
        )
    }

    static var current: MapHomeAlarmSettings { stored(.standard) }

    static func stored(_ defaults: UserDefaults) -> MapHomeAlarmSettings {
        defaults.object(forKey: storageKey) == nil
            ? MapHomeAlarmSettings()
            : MapHomeAlarmSettings(rawValue: defaults.string(forKey: storageKey) ?? "")
    }
}

/// 기록에서 알림 이벤트를 찾는 순수 규칙. 같은 이벤트는 `key`로 한 번만 보낸다.
enum MapHomeAlarmPolicy {
    struct Event: Equatable {
        var kind: MapHomeAlarmKind
        var key: String
        var date: Date
        var body: String
    }

    /// 최근 이 시간 안에 생긴 일만 알린다(앱이 늦게 깨어나 묵은 일을 쏟아내지 않게).
    static let recentWindow: TimeInterval = 45 * 60
    /// 떠난 뒤 이 시간은 기다린다(잠깐 나갔다 돌아오는 경우).
    static let leaveSettle: TimeInterval = 10 * 60

    static func hoursText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)시간 \(minutes % 60)분" : "\(minutes)분"
    }

    static func timeText(_ date: Date, language: MapHomeLanguage) -> String {
        date.formatted(Date.FormatStyle().hour().minute().locale(language.locale))
    }

    /// 등록지점 범위 판정으로 도착·출발 알림 이벤트를 만든다. 최근 45분 안에 확정된 것만 알린다.
    static func zoneEvents(
        readings: [SensorReading],
        frequentPlaces: [FrequentPlace],
        now: Date,
        language: MapHomeLanguage
    ) -> [Event] {
        var events: [Event] = []
        for place in frequentPlaces {
            guard let point = place.point,
                  let arriveKind = MapHomeAlarmKind.arrive(place.kind),
                  let leaveKind = MapHomeAlarmKind.leave(place.kind) else { continue }
            let samples: [MapHomePlaceZone.Sample] = readings.compactMap { reading in
                guard let here = reading.point else { return nil }
                return MapHomePlaceZone.Sample(
                    date: reading.timestamp,
                    distance: distanceMeters(here, point),
                    isMoving: reading.motion.isMovement
                )
            }
            let time = { (date: Date) in timeText(date, language: language) }
            for result in MapHomePlaceZone.events(samples: samples, radius: place.radiusMeters) {
                switch result {
                case .arrived(let date):
                    events.append(Event(
                        kind: arriveKind,
                        key: "\(arriveKind.rawValue)-z\(Int(date.timeIntervalSince1970 / 600))",
                        date: date,
                        body: language.text("\(time(date))에 \(place.name) 도착 확인", "Arrived at \(place.name) at \(time(date))")
                    ))
                case .departed(let date):
                    events.append(Event(
                        kind: leaveKind,
                        key: "\(leaveKind.rawValue)-z\(Int(date.timeIntervalSince1970 / 600))",
                        date: date,
                        body: language.text("\(time(date))에 \(place.name)에서 출발 확인", "Left \(place.name) at \(time(date))")
                    ))
                }
            }
        }
        return events.filter { $0.date > now - recentWindow && $0.date <= now }
    }

    /// 장소 도착·출발. 머문 기록이 다시 계산돼 id가 바뀌어도 같은 일이 되도록 키는 종류 + 10분 단위 시각으로 만든다.
    static func placeEvents(
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        now: Date,
        language: MapHomeLanguage
    ) -> [Event] {
        var events: [Event] = []
        let kinds: [(PlaceStay, FrequentPlaceKind)] = stays.compactMap { stay in placeKinds[stay.placeKey].map { (stay, $0) } }
        for (stay, kind) in kinds {
            let start = stay.span.start, end = stay.span.end
            if let arrive = MapHomeAlarmKind.arrive(kind), start > now - recentWindow, start <= now {
                events.append(Event(
                    kind: arrive, key: "\(arrive.rawValue)-\(Int(start.timeIntervalSince1970 / 600))", date: start,
                    body: language.text("\(timeText(start, language: language))에 \(stay.displayName) 도착", "Arrived at \(stay.displayName) at \(timeText(start, language: language))")
                ))
            }
            if let leave = MapHomeAlarmKind.leave(kind), end > now - recentWindow, end <= now - leaveSettle {
                // 같은 장소에 10분 안에 다시 머물기 시작했으면 떠난 게 아니다.
                let returned = kinds.contains { other, otherKind in
                    otherKind == kind && other.span.start > end && other.span.start <= end + 10 * 60
                }
                if !returned {
                    events.append(Event(
                        kind: leave, key: "\(leave.rawValue)-\(Int(end.timeIntervalSince1970 / 600))", date: end,
                        body: language.text("\(timeText(end, language: language))에 \(stay.displayName)에서 출발", "Left \(stay.displayName) at \(timeText(end, language: language))")
                    ))
                }
            }
        }
        return events
    }

    /// 기상: 오늘 수면 구간이 끝났고 그 뒤로 수면이 없을 때(하루 한 번).
    static func wakeEvent(phases: [DayPhaseSpan], now: Date, calendar: Calendar, language: MapHomeLanguage) -> Event? {
        let sleeps = phases.filter { $0.phase == .sleep }.sorted { $0.span.end < $1.span.end }
        guard let last = sleeps.last, last.span.end > now - recentWindow, last.span.end <= now - 2 * 60 else { return nil }
        let dayKey = MapHomeSalaryPolicy.monthKey(now, calendar: calendar) + String(format: "-%02d", calendar.component(.day, from: now))
        let slept = last.span.duration / 3_600
        return Event(
            kind: .wakeUp, key: "wake-\(dayKey)", date: last.span.end,
            body: language.text(
                "\(timeText(last.span.end, language: language)) 기상 · \(String(format: "%.1f", slept))시간 잤어요",
                "Up at \(timeText(last.span.end, language: language)) · slept \(String(format: "%.1f", slept)) h"
            )
        )
    }

    /// 시급이 마지막으로 알린 값에서 3% 이상 움직였을 때.
    static func rateChangeEvent(previous: Double?, current: Double, now: Date, language: MapHomeLanguage) -> Event? {
        guard let previous, previous > 0 else { return nil }
        let change = (current - previous) / previous
        guard abs(change) >= 0.03 else { return nil }
        let arrow = change > 0 ? "▲" : "▼"
        return Event(
            kind: .rateChange, key: "rate-\(Int(now.timeIntervalSince1970 / 1_800))", date: now,
            body: language.text(
                "\(arrow) \(MapHomeSalaryPolicy.wonText(previous)) → \(MapHomeSalaryPolicy.wonText(current)) (\(String(format: "%+.1f", change * 100))%)",
                "\(arrow) \(MapHomeSalaryPolicy.wonText(previous)) → \(MapHomeSalaryPolicy.wonText(current)) (\(String(format: "%+.1f", change * 100))%)"
            )
        )
    }

    /// 지금부터 몇 시간 더 일하면 시급이 기준(월급 ÷ 209h)의 90% 아래로 내려가는지. 8시간 안에 안 내려가면 nil.
    static func breakEvenHours(
        settings: MapHomeSalaryPolicy.Settings,
        monthWorkSeconds: TimeInterval,
        projectedMonthWorkSeconds: TimeInterval,
        samples: [MapHomeSalaryPolicy.PaySample]
    ) -> Double? {
        guard let base = MapHomeSalaryPolicy.baseHourlyRate(settings) else { return nil }
        let floor = base * 0.9
        var hours = 0.0
        while hours <= 8 {
            let extra = hours * 3_600
            if let rate = MapHomeSalaryPolicy.hourlyRate(
                settings, monthWorkSeconds: monthWorkSeconds + extra,
                projectedMonthWorkSeconds: projectedMonthWorkSeconds + extra, samples: samples
            ), rate < floor {
                return hours
            }
            hours += 0.5
        }
        return nil
    }
}

/// 알림을 실제로 보내고, 보낸 이벤트 키를 기억해 중복을 막는다. 앱이 켜져 있을 때와 백그라운드 새로 고침 때 모두 쓴다.
@MainActor
final class MapHomeAlarmCenter {
    static let shared = MapHomeAlarmCenter()
    static let deliveredKey = "mapHomeAlarmDelivered"
    static let lastRateKey = "mapHomeAlarmLastRate"
    static let dailyCardIdentifier = "taption-alarm-dailyCard"
    private var lastDailyCardSignature = ""
    static let userInfoKind = "taptionAlarm"
    static let userInfoDay = "taptionAlarmDay"
    static let userInfoAt = "taptionAlarmAt"

    private var delivered: [String: Double] = {
        (UserDefaults.standard.dictionary(forKey: MapHomeAlarmCenter.deliveredKey) as? [String: Double]) ?? [:]
    }()

    func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// 장소·기상 이벤트를 찾아 켜 둔 것만 보낸다.
    func evaluate(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        stays: [PlaceStay],
        frequentPlaces: [FrequentPlace],
        readings: [SensorReading] = [],
        now: Date = .now,
        language: MapHomeLanguage = .current
    ) async {
        let settings = MapHomeAlarmSettings.current
        guard !settings.enabled.isDisjoint(with: Set(MapHomeAlarmKind.allCases.filter { $0.group != .salary && $0 != .dailyCard })) else { return }
        let placeKinds = FrequentPlaceResolutionEngine().kindsByPlaceKey(frequentPlaces)
        var events = MapHomeAlarmPolicy.placeEvents(stays: stays, placeKinds: placeKinds, now: now, language: language)
        // 등록지점 범위(히스테리시스)로 도착·출발을 다시 판정한다: 들어와서 머무르고, 나가서 움직여야 확정.
        // 측정이 없는 장소는 위의 머묾 기록 판정을 그대로 쓴다.
        let zoneKinds = Set(frequentPlaces.filter { $0.point != nil }.map(\.kind))
        if !readings.isEmpty, !zoneKinds.isEmpty {
            let zoneAlarmKinds = Set(zoneKinds.flatMap { kind in
                [MapHomeAlarmKind.arrive(kind), MapHomeAlarmKind.leave(kind)].compactMap { $0 }
            })
            events = events.filter { !zoneAlarmKinds.contains($0.kind) }
            events += MapHomeAlarmPolicy.zoneEvents(readings: readings, frequentPlaces: frequentPlaces, now: now, language: language)
        }
        if settings.enabled.contains(.wakeUp) {
            let calendar = MapHomeGrowthPolicy.localCalendar
            let dayStart = calendar.startOfDay(for: now)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
            let phases = DayPhaseEngine.completePhases(
                actuals: actuals, travel: travel, stays: stays, placeKinds: placeKinds,
                in: TimeSpan(start: dayStart, end: dayEnd), asOf: now
            )
            if let wake = MapHomeAlarmPolicy.wakeEvent(phases: phases, now: now, calendar: calendar, language: language) {
                events.append(wake)
            }
        }
        for event in events where settings.enabled.contains(event.kind) {
            await deliver(event, language: language)
        }
        prune(now: now)
    }

    /// 연봉 카운터가 시급을 다시 계산할 때 부른다.
    func noteRate(_ rate: Double, isWorking: Bool, breakEvenHours: Double?, now: Date = .now, language: MapHomeLanguage = .current) async {
        let settings = MapHomeAlarmSettings.current
        let previous = UserDefaults.standard.object(forKey: Self.lastRateKey) as? Double
        if settings.enabled.contains(.rateChange),
           let event = MapHomeAlarmPolicy.rateChangeEvent(previous: previous, current: rate, now: now, language: language) {
            if await deliver(event, language: language) { UserDefaults.standard.set(rate, forKey: Self.lastRateKey) }
        } else if previous == nil {
            UserDefaults.standard.set(rate, forKey: Self.lastRateKey)
        }
        if settings.enabled.contains(.breakEven), isWorking, let hours = breakEvenHours, hours <= 1 {
            let calendar = MapHomeGrowthPolicy.localCalendar
            let dayKey = MapHomeSalaryPolicy.monthKey(now, calendar: calendar) + String(format: "-%02d", calendar.component(.day, from: now))
            let event = MapHomeAlarmPolicy.Event(
                kind: .breakEven, key: "breakEven-\(dayKey)", date: now,
                body: hours <= 0
                    ? language.text("지금 시급이 기준의 90% 아래예요. 더 일할수록 시급이 내려가요.", "Your rate is already under 90% of base; more hours lower it further.")
                    : language.text("\(String(format: "%.1f", hours))시간 더 일하면 시급이 기준의 90% 아래로 내려가요.", "\(String(format: "%.1f", hours)) more hours push your rate under 90% of base.")
            )
            _ = await deliver(event, language: language)
        }
    }

    /// 하루 카드 알림(매일 반복, 기본 오전 8시). 꺼지면 예약을 지운다.
    func syncDailyCardSchedule(language: MapHomeLanguage = .current) async {
        let center = UNUserNotificationCenter.current()
        guard MapHomeAlarmSettings.current.enabled.contains(.dailyCard), await isAuthorized() else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.dailyCardIdentifier])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = language.text("어제 하루 카드가 준비됐어요", "Yesterday's card is ready")
        content.body = language.text("눌러서 보고 저장하거나 공유하세요.", "Tap to view, save or share.")
        content.sound = .default
        content.userInfo = [Self.userInfoKind: MapHomeAlarmKind.dailyCard.rawValue]
        var components = DateComponents()
        let time = MapHomeAlarmSettings.dailyCardTime
        components.hour = time.hour
        components.minute = time.minute
        var failure = "none"
        do {
            try await center.add(UNNotificationRequest(
                identifier: Self.dailyCardIdentifier, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            ))
        } catch {
            failure = String(describing: error)
        }
        await logDailyCardSchedule(center: center, failure: failure)
    }

    /// 하루 카드가 실제로 예약돼 있는지와 알림 설정을 남긴다. 알림은 iOS가 앱 밖에서 보내 로그에 남지 않으므로,
    /// 안 왔을 때 "예약이 있었는가·다음 시각·요약 전달에 묶였는가"를 이 기록으로 가린다(ARC1030A03). 값이 바뀔 때만 남긴다.
    private func logDailyCardSchedule(center: UNUserNotificationCenter, failure: String) async {
        let settings = await center.notificationSettings()
        let pending = await center.pendingNotificationRequests().first { $0.identifier == Self.dailyCardIdentifier }
        let next = (pending?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
        let nextText = next.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        let signature = [
            String(settings.authorizationStatus.rawValue), String(settings.alertSetting.rawValue),
            String(settings.scheduledDeliverySetting.rawValue), String(settings.lockScreenSetting.rawValue),
            pending == nil ? "no" : "yes", nextText, failure,
        ].joined(separator: "|")
        guard signature != lastDailyCardSignature else { return }
        lastDailyCardSignature = signature
        TaptionPlanDiagnosticsLogger.shared.record("daily_card_schedule", fields: [
            "auth": String(settings.authorizationStatus.rawValue),
            "alert": String(settings.alertSetting.rawValue),
            "scheduled_delivery": String(settings.scheduledDeliverySetting.rawValue),
            "lock_screen": String(settings.lockScreenSetting.rawValue),
            "pending": pending == nil ? "false" : "true",
            "next_epoch": nextText,
            "error": failure,
        ])
    }

    @discardableResult
    private func deliver(_ event: MapHomeAlarmPolicy.Event, language: MapHomeLanguage) async -> Bool {
        guard delivered[event.key] == nil, await isAuthorized() else { return false }
        let content = UNMutableNotificationContent()
        content.title = event.kind.title(language)
        content.body = event.body
        content.sound = .default
        content.userInfo = [Self.userInfoKind: event.kind.rawValue, Self.userInfoAt: event.date.timeIntervalSince1970]
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "taption-alarm-\(event.key)", content: content, trigger: nil))
        } catch {
            return false
        }
        delivered[event.key] = event.date.timeIntervalSince1970
        UserDefaults.standard.set(delivered, forKey: Self.deliveredKey)
        TaptionPlanDiagnosticsLogger.shared.record("alarm_delivered", fields: ["kind": event.kind.rawValue])
        return true
    }

    private func prune(now: Date) {
        let cutoff = now.timeIntervalSince1970 - 3 * 86_400
        let kept = delivered.filter { $0.value >= cutoff }
        if kept.count != delivered.count {
            delivered = kept
            UserDefaults.standard.set(delivered, forKey: Self.deliveredKey)
        }
    }
}

/// 알림 설정: 종류별 켜고 끄기, 권한 상태.
struct MapHomeAlarmSettingsSheet: View {
    let language: MapHomeLanguage
    var onNearbyMemoChange: () -> Void = {}
    @AppStorage(NearbyMemoPolicy.enabledKey) private var isNearbyMemoEnabled = true
    @State private var nearbyMemoAvailability: NearbyMemoAvailability?
    @AppStorage(MapHomeAlarmSettings.storageKey) private var raw = MapHomeAlarmSettings().rawValue
    @AppStorage(MapHomeAlarmSettings.dailyCardHourKey) private var cardHour = 8
    @AppStorage(MapHomeAlarmSettings.dailyCardMinuteKey) private var cardMinute = 0
    @State private var isAuthorized: Bool?

    private var settings: MapHomeAlarmSettings { MapHomeAlarmSettings(rawValue: raw) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(language.text("알림", "Alerts"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(22)), weight: .bold))
                Text(language.text(
                    "앱이 기록을 갱신할 때(켜져 있을 때·iOS가 허용한 백그라운드 새로 고침) 찾은 일을 알려요. 위치 '항상 허용'이 있어야 앱이 꺼져 있어도 받을 수 있어요.",
                    "Sent when the app refreshes its records (foreground or iOS-allowed background refresh). 'Always' location access lets alerts arrive while closed."
                ))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                .foregroundStyle(Color.tpSecondary)

                if isAuthorized == false {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        Label(language.text("알림 권한이 꺼져 있어요 · 설정 열기", "Notifications are off · Open Settings"), systemImage: "bell.slash.fill")
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                            .foregroundStyle(Color.tpHoliday)
                    }
                }

                ForEach(MapHomeAlarmKind.Group.allCases, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title(language))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                            .foregroundStyle(Color.tpSecondary)
                        VStack(spacing: 0) {
                            ForEach(MapHomeAlarmKind.allCases.filter { $0.group == group }) { kind in
                                Toggle(isOn: binding(kind)) {
                                    HStack(spacing: 10) {
                                        Image(systemName: kind.systemImage)
                                            .foregroundStyle(Color.tpAccent)
                                            .frame(width: 22)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(kind.title(language)).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                                            Text(kind.detail(language)).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)))).foregroundStyle(Color.tpSecondary)
                                        }
                                    }
                                }
                                .tint(Color.tpAccent)
                                .padding(.vertical, 8)
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    if group == .day {
                        HStack {
                            Text(language.text("하루 카드 알림 시각", "Day card time"))
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                            Spacer()
                            DatePicker("", selection: cardTimeBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                nearbyMemoRow
                ArrivalCardSettingRow(language: language)
            }
            .padding(22)
        }
        .background(Color.tpBackground)
        .task { isAuthorized = await MapHomeAlarmCenter.shared.isAuthorized() }
        .task(id: isNearbyMemoEnabled) { nearbyMemoAvailability = await NearbyMemoAvailability.current().availability }
    }

    private var nearbyMemoRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.text("메모", "Memos"))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
            Toggle(isOn: $isNearbyMemoEnabled) {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(Color.tpAccent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text("근처에 남긴 메모", "Memos left nearby"))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                        Text(nearbyMemoDetail)
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11))))
                            .foregroundStyle(Color.tpSecondary)
                    }
                }
            }
            .tint(Color.tpAccent)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onChange(of: isNearbyMemoEnabled) { _, _ in onNearbyMemoChange() }
        }
    }

    private var nearbyMemoDetail: String {
        switch nearbyMemoAvailability {
        case .notificationsNotAllowed:
            language.text("알림 권한이 꺼져 있어 보내지 않아요.", "Off because notifications aren't allowed.")
        case .locationNotAllowed:
            language.text("위치 권한이 없어 보내지 않아요.", "Off because location isn't allowed.")
        case .approximateLocation:
            language.text("정확한 위치가 꺼져 있어 보내지 않아요.", "Off because Precise Location is off.")
        default:
            language.text(
                "아이콘을 고른 지난 위치 메모의 근처에 가면 iOS가 알려요. 메모 글이 잠금 화면에 보여요.",
                "iOS alerts you near past location memos with a chosen icon. Memo text shows on the Lock Screen."
            )
        }
    }

    private var cardTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: cardHour, minute: cardMinute, second: 0, of: .now) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                cardHour = parts.hour ?? 8
                cardMinute = parts.minute ?? 0
                Task { await MapHomeAlarmCenter.shared.syncDailyCardSchedule(language: language) }
            }
        )
    }

    private func binding(_ kind: MapHomeAlarmKind) -> Binding<Bool> {
        Binding(
            get: { settings.enabled.contains(kind) },
            set: { on in
                var next = settings
                if on { next.enabled.insert(kind) } else { next.enabled.remove(kind) }
                raw = next.rawValue
                Task {
                    if on, await !MapHomeAlarmCenter.shared.isAuthorized() {
                        isAuthorized = await MapHomeAlarmCenter.shared.requestAuthorization()
                    }
                    await MapHomeAlarmCenter.shared.syncDailyCardSchedule(language: language)
                }
            }
        )
    }
}

/// 알람을 눌렀을 때 뜨는 확인 화면. 시간은 지금으로 채워져 있고 고칠 수 있다. 확인하면 실제 기록이 남는다.
struct MapHomeAlarmConfirmSheet: View {
    let kind: MapHomeAlarmKind
    let initialDate: Date
    let language: MapHomeLanguage
    let onConfirm: (Date) -> Void
    let onCancel: () -> Void
    @State private var at: Date

    init(kind: MapHomeAlarmKind, initialDate: Date, language: MapHomeLanguage, onConfirm: @escaping (Date) -> Void, onCancel: @escaping () -> Void) {
        self.kind = kind
        self.initialDate = initialDate
        self.language = language
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _at = State(initialValue: initialDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(kind.title(language))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(22)), weight: .bold))
            Text(language.text("시간을 확인하고 고쳐 주세요. 확인을 누르면 그 시각부터 기록돼요.", "Check the time and edit if needed. Recording starts from this time."))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
            DatePicker("", selection: $at, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack(spacing: 12) {
                Button(language.text("취소", "Cancel"), action: onCancel)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, minHeight: 44)
                Button(language.text("확인", "Confirm")) { onConfirm(at) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.tpAccent)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .background(Color.tpBackground)
    }
}

/// 알람 종류를 실제 기록 종류로 바꾼다. 집 도착·외출은 기록하지 않는다.
enum MapHomeAlarmRecordMapping {
    /// (기록 종류, 제목, 시작인지)
    static func entry(for kind: MapHomeAlarmKind, language: MapHomeLanguage) -> (categoryID: String, title: String, opens: Bool)? {
        switch kind {
        case .arriveCompany: ("work", language.text("업무", "Work"), true)
        case .leaveCompany: ("work", language.text("업무", "Work"), false)
        case .arriveSchool, .arriveAcademy: ("study", language.text("수업", "Class"), true)
        case .leaveSchool, .leaveAcademy: ("study", language.text("수업", "Class"), false)
        case .wakeUp: ("sleep", language.text("수면", "Sleep"), false)
        default: nil
        }
    }
}
