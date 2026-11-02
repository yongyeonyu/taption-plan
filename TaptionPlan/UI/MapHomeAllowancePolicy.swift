import Foundation

/// 용돈: 입력 금액을 24시간으로 나눈 시급으로 쌓는다. 근무·수면과 상관없고, 연봉 설정 없이도 쓴다.
/// 연봉 카운터처럼 보는 날 0시부터 센다. 값은 이 기기에만 저장한다.
enum MapHomeAllowancePolicy {
    static let amountKey = "mapHomeAllowanceAmount"
    static let periodKey = "mapHomeAllowancePeriod"

    enum Period: String, CaseIterable {
        case month, week, day
    }

    struct Settings: Equatable {
        var amount = 0.0
        var period: Period = .month

        var isConfigured: Bool { amount > 0 }
    }

    static func load(_ defaults: UserDefaults = .standard) -> Settings {
        Settings(
            amount: defaults.double(forKey: amountKey),
            period: Period(rawValue: defaults.string(forKey: periodKey) ?? "") ?? .month
        )
    }

    /// 환산 시급. 월 단위는 `date`가 속한 달의 실제 일수로 나눈다.
    static func hourlyRate(
        _ settings: Settings,
        on date: Date,
        calendar: Calendar = MapHomeGrowthPolicy.localCalendar
    ) -> Double {
        let days: Int
        switch settings.period {
        case .month: days = calendar.range(of: .day, in: .month, for: date)?.count ?? 30
        case .week: days = 7
        case .day: days = 1
        }
        return settings.amount / Double(days * 24)
    }

    /// `day` 0시부터 `asOf`까지 번 돈. 지난 날은 하루 전체, 앞날은 0이다.
    static func earned(
        _ settings: Settings,
        day: Date,
        asOf: Date,
        tick: TimeInterval = 1,
        calendar: Calendar = MapHomeGrowthPolicy.localCalendar
    ) -> Double {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 60 * 60)
        let elapsed = min(max(0, asOf.timeIntervalSince(start)), end.timeIntervalSince(start))
        return hourlyRate(settings, on: start, calendar: calendar) * MapHomeSalaryPolicy.quantized(elapsed, tick: tick) / 3_600
    }

    /// 재생 중이면 재생 시각까지, 아니면 지금까지 번 돈.
    private static func earned(
        _ settings: Settings,
        day: Date,
        playbackMinute: Double?,
        now: Date,
        tick: TimeInterval,
        calendar: Calendar = MapHomeGrowthPolicy.localCalendar
    ) -> Double {
        let asOf = playbackMinute.map { calendar.startOfDay(for: day).addingTimeInterval($0 * 60) } ?? now
        return earned(settings, day: day, asOf: asOf, tick: tick, calendar: calendar)
    }

    /// 카운터 창의 용돈 줄. 설정이 없으면 nil.
    static func counterLine(
        day: Date,
        playbackMinute: Double?,
        now: Date,
        tick: TimeInterval,
        language: MapHomeLanguage,
        settings: Settings = load()
    ) -> MapHomeCounterSalary? {
        guard settings.isConfigured else { return nil }
        let amount = earned(settings, day: day, playbackMinute: playbackMinute, now: now, tick: tick)
        return MapHomeCounterSalary(
            text: MapHomeSalaryPolicy.wonText(amount, language: language),
            isWorking: false,
            isAllowance: true
        )
    }

    /// 카운터 상세 화면 내용.
    static func detail(
        day: Date,
        playbackMinute: Double?,
        now: Date,
        language: MapHomeLanguage,
        settings: Settings = load()
    ) -> MapHomeCounterDetailContent {
        let amount = earned(settings, day: day, playbackMinute: playbackMinute, now: now, tick: 1)
        let rate = MapHomeSalaryPolicy.wonText(hourlyRate(settings, on: day), language: language)
        return MapHomeCounterDetailContent(
            systemImage: MapHomeCounterSalary.allowanceSymbol,
            title: language.text("용돈", "Allowance"),
            value: MapHomeSalaryPolicy.wonText(amount, language: language),
            sections: [.init(id: 0, title: language.text("시급", "Hourly rate"), rows: [
                .init(id: 0, title: rate, subtitle: nil, value: "")
            ])],
            note: language.text("24시간 내내 시급만큼 쌓여요.", "Grows at this rate around the clock.")
        )
    }
}
