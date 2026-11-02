import CoreMotion
import MapKit
import Photos
import SwiftUI
import UserNotifications

/// 세전 월급에서 근로자가 내는 4대보험·소득세를 빼 세후 월급을 추정한다(2026년 요율, 근로소득 간이세액 방식).
/// 부양가족 본인 1명, 비과세 식대 월 20만 원을 가정한다. 실제 공제액은 회사 정산에 따라 다를 수 있다.
enum MapHomeKoreanNetPay {
    static let mealAllowance = 200_000.0
    static let pensionRate = 0.0475
    static let pensionBase = 400_000.0...6_370_000.0
    static let healthRate = 0.03595
    static let careRateOfHealth = 0.1314
    static let employmentRate = 0.009

    struct Breakdown: Equatable {
        var gross: Double
        var pension: Double
        var health: Double
        var care: Double
        var employment: Double
        var incomeTax: Double
        var localTax: Double
        var net: Double { gross - pension - health - care - employment - incomeTax - localTax }
    }

    static func monthly(gross: Double) -> Breakdown {
        guard gross > 0 else { return Breakdown(gross: 0, pension: 0, health: 0, care: 0, employment: 0, incomeTax: 0, localTax: 0) }
        let taxable = max(0, gross - min(gross, mealAllowance))
        let pension = min(max(taxable, pensionBase.lowerBound), pensionBase.upperBound) * pensionRate
        let health = taxable * healthRate
        let care = health * careRateOfHealth
        let employment = taxable * employmentRate
        let annualTax = annualIncomeTax(totalPay: taxable * 12, annualPension: pension * 12)
        let incomeTax = (annualTax / 12 / 10).rounded(.down) * 10
        let localTax = (incomeTax * 0.1 / 10).rounded(.down) * 10
        return Breakdown(gross: gross, pension: pension, health: health, care: care, employment: employment, incomeTax: incomeTax, localTax: localTax)
    }

    /// 연간 결정세액(지방소득세 제외).
    static func annualIncomeTax(totalPay s: Double, annualPension: Double) -> Double {
        let earnedDeduction = min(20_000_000, {
            switch s {
            case ..<5_000_000: return s * 0.7
            case ..<15_000_000: return 3_500_000 + (s - 5_000_000) * 0.4
            case ..<45_000_000: return 7_500_000 + (s - 15_000_000) * 0.15
            case ..<100_000_000: return 12_000_000 + (s - 45_000_000) * 0.05
            default: return 14_750_000 + (s - 100_000_000) * 0.02
            }
        }())
        // 간이세액표의 특별소득공제 등(공제대상가족 1명) 산식.
        let special: Double = {
            switch s {
            case ..<30_000_000: return 3_100_000 + s * 0.04
            case ..<45_000_000: return 3_100_000 + s * 0.04 - (s - 30_000_000) * 0.05
            case ..<70_000_000: return 3_100_000 + s * 0.015
            case ..<120_000_000: return 3_100_000 + s * 0.005
            default: return 0
            }
        }()
        let base = max(0, s - earnedDeduction - 1_500_000 - annualPension - special)
        let brackets: [(limit: Double, rate: Double)] = [
            (14_000_000, 0.06), (50_000_000, 0.15), (88_000_000, 0.24), (150_000_000, 0.35),
            (300_000_000, 0.38), (500_000_000, 0.40), (1_000_000_000, 0.42), (.infinity, 0.45),
        ]
        var computed = 0.0, lower = 0.0
        for bracket in brackets where base > lower {
            computed += (min(base, bracket.limit) - lower) * bracket.rate
            lower = bracket.limit
        }
        let credit = computed <= 1_300_000 ? computed * 0.55 : 715_000 + (computed - 1_300_000) * 0.3
        let creditLimit: Double = {
            switch s {
            case ...33_000_000: return 740_000
            case ...70_000_000: return max(660_000, 740_000 - (s - 33_000_000) * 0.008)
            case ...120_000_000: return max(500_000, 660_000 - (s - 70_000_000) * 0.5)
            default: return max(200_000, 500_000 - (s - 120_000_000) * 0.5)
            }
        }()
        return max(0, computed - min(credit, creditLimit))
    }
}

/// 연봉 카운터: 업무 시간에 시급을 곱해 번 돈을 보여 준다(금액은 원).
enum MapHomeSalaryPolicy {
    static let annualKey = "mapHomeSalaryAnnual"
    static let monthlyPayKey = "mapHomeSalaryMonthlyPay"
    static let isNetInputKey = "mapHomeSalaryIsNetInput"
    static let showsNetKey = "mapHomeSalaryShowsNet"
    static let isHourlyKey = "mapHomeSalaryIsHourly"
    static let hourlyKey = "mapHomeSalaryHourly"
    static let hourlyTaxKey = "mapHomeSalaryHourlyTax"
    static let weeklyHolidayKey = "mapHomeSalaryWeeklyHoliday"
    static let hourlyIsNetKey = "mapHomeSalaryHourlyIsNet"
    static let monthAccumKey = "mapHomeSalaryMonthAccum"
    static let monthAccumMonthKey = "mapHomeSalaryMonthAccumMonth"
    /// 달별로 실제 받은 월급(수당 포함, 입력 기준). JSON `{"2026-09": 2900000}`.
    static let payHistoryKey = "mapHomeSalaryPayHistory"
    /// 기록이 없을 때 쓰는 법정 연장수당 배율(통상시급 × 1.5).
    static let defaultOvertimeMultiplier = 1.5
    /// 한 달 근무가 이보다 적게 잡히면 그 달 기록은 수당 추정에 쓰지 않는다.
    static let minimumSampleHours = 20.0
    static let tickKey = "mapHomeSalaryTickSeconds"
    static let tickChoices = [1, 10, 30, 60, 300, 600, 1_800, 3_600]
    /// 주 40시간 기준 월 소정근로시간(주휴 포함).
    static let standardMonthlyHours = 209.0
    static let workKey = MapHomeCalendarTimeKind.work.rawValue
    static let movementKey = MapHomeCalendarTimeKind.movement.rawValue

    /// 시급 알바의 세금 계산 방식. 하나만 고른다.
    enum HourlyTax: String, CaseIterable {
        case threePointThree
        case fourInsurance
        case none

        /// 세후 비율. 4대보험은 국민연금·건강(장기요양 포함)·고용보험 근로자 부담분을 뺀다.
        var keepRate: Double {
            switch self {
            case .threePointThree: 1 - 0.033
            case .fourInsurance: 1 - (MapHomeKoreanNetPay.pensionRate + MapHomeKoreanNetPay.healthRate * (1 + MapHomeKoreanNetPay.careRateOfHealth) + MapHomeKoreanNetPay.employmentRate)
            case .none: 1
            }
        }
    }

    struct Settings: Equatable {
        var annualPay = 0.0
        /// 입력한 연봉·월급이 세후 금액인지.
        var isNetInput = false
        /// 0이면 연봉 ÷ 12.
        var monthlyPay = 0.0
        /// 세전 입력일 때 세후로 계산해 보여 줄지.
        var showsNet = true
        /// 이번 달 누적 금액을 직접 고친 값(0이면 근무 시간으로 계산).
        var monthAccumOverride = 0.0
        /// 달별 실제 받은 월급(수당 포함).
        var payHistory: [String: Double] = [:]
        /// 시급으로 입력했는지. 연봉·월급과 하나만 쓴다.
        var isHourly = false
        var hourly = 0.0
        var hourlyTax: HourlyTax = .threePointThree
        /// 주 15시간 이상 근무면 주휴수당을 시급에 더한다.
        var includesWeeklyHoliday = false
        /// 시급을 세후로 입력했는지(세전이면 false).
        var hourlyIsNet = false

        var isConfigured: Bool { isHourly ? hourly > 0 : annualPay > 0 || monthlyPay > 0 }
        var showsNetAmounts: Bool { showsNet }
    }

    static func monthKey(_ date: Date, calendar: Calendar = MapHomeGrowthPolicy.localCalendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func loadSettings(_ defaults: UserDefaults = .standard, now: Date = .now) -> Settings {
        let override = defaults.string(forKey: monthAccumMonthKey) == monthKey(now) ? defaults.double(forKey: monthAccumKey) : 0
        return Settings(
            annualPay: defaults.double(forKey: annualKey),
            isNetInput: defaults.bool(forKey: isNetInputKey),
            monthlyPay: defaults.double(forKey: monthlyPayKey),
            showsNet: defaults.object(forKey: showsNetKey) as? Bool ?? true,
            monthAccumOverride: override,
            payHistory: decodePayHistory(defaults.string(forKey: payHistoryKey) ?? ""),
            isHourly: defaults.bool(forKey: isHourlyKey),
            hourly: defaults.double(forKey: hourlyKey),
            hourlyTax: HourlyTax(rawValue: defaults.string(forKey: hourlyTaxKey) ?? "") ?? .threePointThree,
            includesWeeklyHoliday: defaults.bool(forKey: weeklyHolidayKey),
            hourlyIsNet: defaults.bool(forKey: hourlyIsNetKey)
        )
    }

    static func decodePayHistory(_ raw: String) -> [String: Double] {
        (try? JSONDecoder().decode([String: Double].self, from: Data(raw.utf8))) ?? [:]
    }

    static func encodePayHistory(_ history: [String: Double]) -> String {
        (try? String(data: JSONEncoder().encode(history.filter { $0.value > 0 }), encoding: .utf8)) ?? "{}"
    }

    /// 받은 월급 기록은 실수령(세후)으로 적고, 입력 기준(세전 또는 세후)에 맞춰 짝을 만든다.
    static func paySamples(_ settings: Settings, pastMonthWorkSeconds: [String: TimeInterval]) -> [PaySample] {
        settings.payHistory.compactMap { key, received in
            pastMonthWorkSeconds[key].map {
                PaySample(hours: $0 / 3_600, pay: settings.isNetInput ? received : grossFromNetMonthly(received))
            }
        }
    }

    /// 지난 어느 달의 (근무 시간, 받은 월급) 한 쌍.
    struct PaySample: Equatable {
        var hours: Double
        var pay: Double
    }

    /// 월급 = 고정분 + 209시간을 넘긴 1시간당 수당. 지난달 기록으로 맞춘다.
    struct PayModel: Equatable {
        var fixedMonthly: Double
        var overtimeHourly: Double
        /// 맞추는 데 쓴 달 수(0이면 법정 1.5배 기본값).
        var sampleCount: Int
    }

    /// 지난달들의 (근무 시간, 받은 월급)에 직선을 맞춘다: 받은 월급 = 고정분 + 수당시급 × (근무 − 209시간).
    /// 기록이 2개월 이상이고 근무 시간이 서로 다르면 최소제곱, 1개월이면 그 달로 수당시급만, 없으면 통상시급 × 1.5.
    /// 수당시급은 0~통상시급 3배, 고정분은 기본 월급의 0.5~2배로 묶어 이상값을 막는다.
    static func fitPayModel(baseMonthly: Double, samples: [PaySample]) -> PayModel {
        let baseHourly = baseMonthly / standardMonthlyHours
        let defaultOvertime = baseHourly * defaultOvertimeMultiplier
        let usable = samples.filter { $0.hours >= minimumSampleHours && $0.pay > 0 }
        func clampOvertime(_ v: Double) -> Double { min(max(v, 0), baseHourly * 3) }
        func clampFixed(_ v: Double) -> Double { min(max(v, baseMonthly * 0.5), baseMonthly * 2) }
        guard !usable.isEmpty else { return PayModel(fixedMonthly: baseMonthly, overtimeHourly: defaultOvertime, sampleCount: 0) }
        let xs = usable.map { $0.hours - standardMonthlyHours }
        let ys = usable.map(\.pay)
        let n = Double(usable.count)
        let meanX = xs.reduce(0, +) / n, meanY = ys.reduce(0, +) / n
        let varX = zip(xs, xs).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanX) }
        if usable.count >= 2, varX > 1 {
            let cov = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
            let slope = clampOvertime(cov / varX)
            return PayModel(fixedMonthly: clampFixed(meanY - slope * meanX), overtimeHourly: slope, sampleCount: usable.count)
        }
        // 근무 시간이 다 비슷하면 기울기를 못 구한다: 고정분만 기록 평균으로 보정하고 수당은 기본값.
        if abs(meanX) < 1 {
            return PayModel(fixedMonthly: clampFixed(meanY), overtimeHourly: defaultOvertime, sampleCount: usable.count)
        }
        let slope = clampOvertime((meanY - baseMonthly) / meanX)
        return PayModel(fixedMonthly: baseMonthly, overtimeHourly: slope, sampleCount: usable.count)
    }

    /// 그 달 근무 시간으로 받을 월급(입력 기준). 209시간 미만이어도 고정분은 다 받는 것으로 본다.
    static func expectedMonthlyPay(_ model: PayModel, workHours: Double) -> Double {
        model.fixedMonthly + model.overtimeHourly * max(0, workHours - standardMonthlyHours)
    }

    /// 입력 기준 금액을 보여 줄 기준으로 바꾼다(세전 입력 + 세후 보기면 공제).
    static func displayed(_ amount: Double, _ settings: Settings) -> Double {
        if settings.isNetInput { return settings.showsNet ? amount : grossFromNetMonthly(amount) }
        return settings.showsNet ? MapHomeKoreanNetPay.monthly(gross: amount).net : amount
    }

    /// 세후 월급에서 세전 월급을 거꾸로 구한다. 세후는 세전에 따라 단조 증가하므로 이분법으로 맞춘다.
    static func grossFromNetMonthly(_ net: Double) -> Double {
        guard net > 0 else { return 0 }
        var low = 0.0, high = net * 3
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if MapHomeKoreanNetPay.monthly(gross: mid).net < net { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    /// 입력 기준과 무관하게 세전 월급·세후 월급.
    static func monthlyGross(_ settings: Settings) -> Double {
        settings.isNetInput ? grossFromNetMonthly(inputMonthly(settings)) : inputMonthly(settings)
    }

    static func monthlyNet(_ settings: Settings) -> Double {
        settings.isNetInput ? inputMonthly(settings) : MapHomeKoreanNetPay.monthly(gross: inputMonthly(settings)).net
    }

    /// 입력 기준(세전 또는 세후)의 월급.
    static func inputMonthly(_ settings: Settings) -> Double {
        if settings.isHourly { return 0 }
        return settings.monthlyPay > 0 ? settings.monthlyPay : settings.annualPay / 12
    }

    /// 보여 줄 기준의 월급. 세전 입력을 세후로 보면 4대보험·소득세를 뺀다.
    static func displayedMonthly(_ settings: Settings) -> Double {
        displayed(inputMonthly(settings), settings)
    }

    /// 연봉·시급 연동용: 시급 모드여도 연봉·월급 입력의 세전 월급(시급 모드면 저장된 연봉 기준).
    static func monthlyGrossIgnoringHourly(_ settings: Settings) -> Double {
        let base = settings.monthlyPay > 0 ? settings.monthlyPay : settings.annualPay / 12
        return settings.isNetInput ? grossFromNetMonthly(base) : base
    }

    /// 시급을 쓰면 시급의 연봉 환산(월 209시간 × 12), 연봉을 쓰면 연봉의 세전 시급 환산(÷ 209). 한쪽만 적어도 다른 쪽이 나온다.
    static func linkedAnnualGross(_ settings: Settings) -> Double {
        let fromAnnual = monthlyGrossIgnoringHourly(settings) * 12
        return fromAnnual > 0 ? fromAnnual : hourlyGross(settings, weeklyHours: 0) * standardMonthlyHours * 12
    }

    static func linkedHourlyGross(_ settings: Settings) -> Double {
        settings.hourly > 0 ? hourlyGross(settings, weeklyHours: 0) : monthlyGrossIgnoringHourly(settings) / standardMonthlyHours
    }

    /// 세전 → 세후(4대보험·소득세) 환산 금액.
    static func netOfGross(_ gross: Double) -> Double {
        MapHomeKoreanNetPay.monthly(gross: gross / 12).net * 12
    }

    /// 1,234,567 형식으로 묶는다. 숫자가 아니면 빈 문자열.
    static func grouped(_ text: String) -> String {
        guard let value = Int(text.filter(\.isNumber)) else { return "" }
        return value.formatted(.number.locale(Locale(identifier: "en_US")).grouping(.automatic))
    }

    /// 시급의 세전 금액. 세후로 입력했으면 세율을 거꾸로 적용하고, 주휴수당(주 15시간 이상이면 min(주 근무 ÷ 5, 8)시간분)을 더한다.
    static func hourlyGross(_ settings: Settings, weeklyHours: Double) -> Double {
        var gross = settings.hourlyIsNet ? settings.hourly / settings.hourlyTax.keepRate : settings.hourly
        if settings.includesWeeklyHoliday, weeklyHours >= 15 {
            gross *= 1 + min(weeklyHours / 5, 8) / weeklyHours
        }
        return gross
    }

    /// 표시 기준(세전/세후)에 맞춘 시급.
    static func hourlyDisplayed(_ settings: Settings, weeklyHours: Double) -> Double {
        let gross = hourlyGross(settings, weeklyHours: weeklyHours)
        return settings.showsNet ? gross * settings.hourlyTax.keepRate : gross
    }

    /// 월급 ÷ 209시간.
    static func baseHourlyRate(_ settings: Settings) -> Double? {
        if settings.isHourly { return settings.hourly > 0 ? hourlyDisplayed(settings, weeklyHours: 0) : nil }
        let monthly = displayedMonthly(settings)
        return monthly > 0 ? monthly / standardMonthlyHours : nil
    }

    /// 이번 달 지금까지 번 돈. 직접 고친 값이 있으면 그 값.
    static func accumulated(_ settings: Settings, monthWorkSeconds: TimeInterval) -> Double {
        if settings.monthAccumOverride > 0 { return settings.monthAccumOverride }
        return earnings(workSeconds: monthWorkSeconds, hourlyRate: baseHourlyRate(settings) ?? 0)
    }

    /// 이번 달 받을 것으로 보는 월급(보여 줄 기준): 지난달 기록으로 맞춘 수당 모델에 예상 근무 시간을 넣는다.
    static func expectedMonthPay(_ settings: Settings, projectedMonthWorkSeconds: TimeInterval, samples: [PaySample]) -> Double? {
        let base = inputMonthly(settings)
        guard base > 0 else { return nil }
        let model = fitPayModel(baseMonthly: base, samples: samples)
        let hours = max(projectedMonthWorkSeconds, 0) / 3_600
        return displayed(expectedMonthlyPay(model, workHours: hours), settings)
    }

    /// 시급은 주식처럼 움직인다: 이번 달 예상 월급(수당 포함) ÷ 이번 달 예상 근무 시간.
    /// 예상 근무는 지금까지 + 추세로 예측한 남은 근무, 예상 월급은 지난달 기록으로 맞춘 고정분 + 초과 수당이라
    /// 야근이 늘면 월급과 시간이 함께 올라가고, 월말에는 예상 = 실제가 되어 누적이 그 달 월급과 맞아떨어진다.
    /// 누적 금액을 직접 고쳤으면 그 금액 ÷ 지금까지 근무 시간(1시간 이상일 때).
    static func hourlyRate(
        _ settings: Settings,
        monthWorkSeconds: TimeInterval,
        projectedMonthWorkSeconds: TimeInterval,
        samples: [PaySample] = []
    ) -> Double? {
        if settings.isHourly {
            guard settings.hourly > 0 else { return nil }
            let weeklyHours = max(projectedMonthWorkSeconds, monthWorkSeconds) / 3_600 * 7 / 30.4
            return hourlyDisplayed(settings, weeklyHours: weeklyHours)
        }
        let monthly = displayedMonthly(settings)
        guard monthly > 0 else { return nil }
        if settings.monthAccumOverride > 0, monthWorkSeconds >= 3_600 {
            return settings.monthAccumOverride / (monthWorkSeconds / 3_600)
        }
        let projected = max(projectedMonthWorkSeconds, monthWorkSeconds)
        guard projected >= 3_600 else { return monthly / standardMonthlyHours }
        let pay = expectedMonthPay(settings, projectedMonthWorkSeconds: projected, samples: samples) ?? monthly
        return pay / (projected / 3_600)
    }

    /// 업무 시간 추세로 이번 달 총 근무 시간을 예측한다. 남은 날은 최근 8주 같은 요일의 평균 근무(기록 있는 날만)로,
    /// 오늘은 "지금까지"와 요일 평균 중 큰 쪽으로 본다. 요일 기록이 없으면 평일 평균, 그것도 없으면 0.
    static func projectedMonthWorkSeconds(
        dailyWork: [Date: TimeInterval],
        now: Date,
        calendar: Calendar
    ) -> TimeInterval {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return 0 }
        let today = calendar.startOfDay(for: now)
        let historyStart = calendar.date(byAdding: .day, value: -56, to: today) ?? today
        var byWeekday: [Int: [TimeInterval]] = [:]
        var weekdayValues: [TimeInterval] = []
        for (day, seconds) in dailyWork where day >= historyStart && day < today && seconds > 0 {
            let weekday = calendar.component(.weekday, from: day)
            byWeekday[weekday, default: []].append(seconds)
            if (2...6).contains(weekday) { weekdayValues.append(seconds) }
        }
        func average(_ values: [TimeInterval]) -> TimeInterval { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        // 최근 기록이 전혀 없으면 추세를 세울 수 없으니 월 소정근로시간(209h)을 예상으로 쓴다. 며칠 일한 값으로 월 전체를 줄이지 않는다.
        if byWeekday.isEmpty { return standardMonthlyHours * 3_600 }
        let weekdayAverage = average(weekdayValues)
        func expected(_ day: Date) -> TimeInterval {
            let weekday = calendar.component(.weekday, from: day)
            if let values = byWeekday[weekday], !values.isEmpty { return average(values) }
            return (2...6).contains(weekday) ? weekdayAverage : 0
        }
        var total: TimeInterval = 0
        var day = monthStart
        while day < monthEnd {
            let done = dailyWork[day] ?? 0
            if day < today { total += done }
            else if day == today { total += max(done, expected(day)) }
            else { total += expected(day) }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? monthEnd
        }
        return total
    }

    static func intervalTitle(_ seconds: Int, language: MapHomeLanguage) -> String {
        switch seconds {
        case ..<60: language.text("\(seconds)초", "\(seconds)s")
        case ..<3_600: language.text("\(seconds / 60)분", "\(seconds / 60) min")
        default: language.text("\(seconds / 3_600)시간", "\(seconds / 3_600) h")
        }
    }

    /// 그날 업무로 잡힌 구간들. 재생·지난 날짜는 이 구간에서 시각까지의 근무 시간만 센다(업무 밖에서는 늘지 않는다).
    static func workSpans(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        day: TimeSpan,
        asOf now: Date
    ) -> [TimeSpan] {
        DayPhaseEngine.completePhases(
            actuals: actuals.filter { let s = $0.span(asOf: now); return s.start < day.end && day.start < s.end },
            travel: travel.filter { $0.span.start < day.end && day.start < $0.span.end },
            stays: stays.filter { $0.span.start < day.end && day.start < $0.span.end },
            placeKinds: placeKinds,
            in: day,
            asOf: now
        )
        .filter { phase in
            DayPhaseEngine.categoryDurations([phase], scope: .canonical).contains { $0.categoryID == workKey && $0.actual > 0 }
        }
        .map(\.span)
    }

    static func workSeconds(in spans: [TimeSpan], until date: Date) -> TimeInterval {
        spans.reduce(0) { $0 + max(0, min($1.end, date).timeIntervalSince($1.start)) }
    }

    /// 표시 간격 단위로 내린 값(설정한 간격마다 한 번씩 오른다).
    static func quantized(_ seconds: TimeInterval, tick: TimeInterval) -> TimeInterval {
        let step = max(1, tick)
        return (seconds / step).rounded(.down) * step
    }

    static func earnings(workSeconds: TimeInterval, hourlyRate: Double) -> Double {
        max(0, workSeconds) / 3_600 * hourlyRate
    }

    /// 화면에 보일 오늘 근무 시간. 근무 중이면 마지막으로 센 뒤 흐른 시간을 표시 간격 단위로 더한다.
    static func liveWorkSeconds(base: TimeInterval, baseDate: Date, isWorking: Bool, now: Date, tick: TimeInterval) -> TimeInterval {
        guard isWorking else { return base }
        let elapsed = max(0, now.timeIntervalSince(baseDate))
        let step = max(1, tick)
        return base + (elapsed / step).rounded(.down) * step
    }

    /// 1분 사이 근무 시간이 30초 넘게 늘었으면 지금 근무 중으로 본다.
    static func isWorking(workNow: TimeInterval, workMinuteAgo: TimeInterval) -> Bool {
        workNow - workMinuteAgo > 30
    }

    struct MonthSummary: Equatable {
        var workSeconds: TimeInterval
        var commuteSeconds: TimeInterval
        var earnings: Double
        /// 출퇴근 시간까지 넣은 실질 시급. 출퇴근이 없으면 nil.
        var effectiveHourlyRate: Double?
    }

    /// 달 합계. 출퇴근은 근무한 날의 이동 시간으로 본다.
    static func monthSummary(totals: [Date: [String: TimeInterval]], hourlyRate: Double) -> MonthSummary {
        var work: TimeInterval = 0, commute: TimeInterval = 0
        for values in totals.values {
            let dayWork = values[workKey] ?? 0
            guard dayWork > 0 else { continue }
            work += dayWork
            commute += values[movementKey] ?? 0
        }
        let pay = earnings(workSeconds: work, hourlyRate: hourlyRate)
        let effective: Double? = commute > 0 && work > 0 ? pay / ((work + commute) / 3_600) : nil
        return MonthSummary(workSeconds: work, commuteSeconds: commute, earnings: pay, effectiveHourlyRate: effective)
    }

    /// 지도 라벨·하루 요약이 쓰는 마지막 계산 결과.
    struct Live: Equatable {
        var todayWorkSeconds: TimeInterval
        var measuredAt: Date
        var isWorking: Bool
        var hourlyRate: Double
        var month: MonthSummary?
        var showsNet: Bool
        /// 추세로 예측한 이번 달 총 근무 시간(시급 산정 기준).
        var projectedMonthWorkSeconds: TimeInterval
        /// 수당 모델로 본 이번 달 예상 월급(보여 줄 기준).
        var expectedMonthPay: Double
        /// 지난 석 달 근무 시간(월 키 → 초). 설정 화면의 월급 기록 입력에 보여 준다.
        var pastMonthWorkSeconds: [String: TimeInterval] = [:]
    }

    /// 영어 설정이면 USD, 한국어 설정이면 원으로 표시한다.
    static func wonText(_ value: Double, language: MapHomeLanguage = .current) -> String {
        let number = Int(value.rounded()).formatted(.number.locale(Locale(identifier: "en_US")).grouping(.automatic))
        return language == .english ? "\(number) USD" : "\(number)원"
    }
}
