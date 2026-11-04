import SwiftUI

/// 연봉 카운터 설정: 연봉(세전/세후)·월급·이번 달 누적 금액·누적 시급·간격별 금액. 값은 이 기기에만 저장한다.
struct MapHomeSalarySettingsSheet: View {
    let language: MapHomeLanguage
    /// 이번 달 지금까지 잡힌 근무 시간(초)과 추세로 예측한 이번 달 총 근무 시간.
    let monthWorkSeconds: TimeInterval
    let projectedMonthWorkSeconds: TimeInterval
    /// 지난 석 달 근무 시간(월 키 → 초).
    var pastMonthWorkSeconds: [String: TimeInterval] = [:]
    /// 처음 실행 튜토리얼에서는 금액 입력만 보여 준다. 나머지는 기록이 쌓인 뒤에 뜻이 있다.
    var showsOnlyPayInput = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MapHomeSalaryPolicy.annualKey) private var annualPay = 0.0
    @AppStorage(MapHomeSalaryPolicy.isNetInputKey) private var isNetInput = false
    @AppStorage(MapHomeSalaryPolicy.monthlyPayKey) private var monthlyPay = 0.0
    @AppStorage(MapHomeSalaryPolicy.showsNetKey) private var showsNet = true
    @AppStorage(MapHomeSalaryPolicy.isHourlyKey) private var isHourly = false
    @AppStorage(MapHomeSalaryPolicy.hourlyKey) private var hourlyPay = 0.0
    @AppStorage(MapHomeSalaryPolicy.hourlyTaxKey) private var hourlyTaxRaw = MapHomeSalaryPolicy.HourlyTax.threePointThree.rawValue
    @AppStorage(MapHomeSalaryPolicy.weeklyHolidayKey) private var weeklyHoliday = false
    @AppStorage(MapHomeSalaryPolicy.hourlyIsNetKey) private var hourlyIsNet = false
    @AppStorage(MapHomeSalaryPolicy.monthAccumKey) private var monthAccum = 0.0
    @AppStorage(MapHomeSalaryPolicy.monthAccumMonthKey) private var monthAccumMonth = ""
    @AppStorage(MapHomeSalaryPolicy.tickKey) private var tickSeconds = 10
    @AppStorage(MapHomeSalaryPolicy.payHistoryKey) private var payHistoryRaw = ""
    @AppStorage(MapHomeAllowancePolicy.amountKey) private var allowanceAmount = 0.0
    @AppStorage(MapHomeAllowancePolicy.periodKey) private var allowancePeriodRaw = MapHomeAllowancePolicy.Period.month.rawValue
    @State private var payTexts: [String: String] = [:]
    @State private var annualText = ""
    @State private var monthlyText = ""
    @State private var hourlyText = ""
    @State private var accumText = ""
    @State private var allowanceText = ""
    @State private var directKind = DirectKind.annual
    @State private var directText = ""

    /// 해외에서 직접 넣는 금액 종류.
    private enum DirectKind: Hashable { case hourly, monthly, annual }

    private var settings: MapHomeSalaryPolicy.Settings {
        MapHomeSalaryPolicy.Settings(
            annualPay: annualPay,
            isNetInput: isNetInput,
            monthlyPay: monthlyPay,
            showsNet: showsNet,
            monthAccumOverride: monthAccumMonth == MapHomeSalaryPolicy.monthKey(.now) ? monthAccum : 0,
            payHistory: MapHomeSalaryPolicy.decodePayHistory(payHistoryRaw),
            isHourly: isHourly,
            hourly: hourlyPay,
            hourlyTax: MapHomeSalaryPolicy.HourlyTax(rawValue: hourlyTaxRaw) ?? .threePointThree,
            includesWeeklyHoliday: weeklyHoliday,
            hourlyIsNet: hourlyIsNet
        ).applyingRegion()
    }

    private var region: AppRegion { .current }
    private var currencyUnit: String { region.currencyUnit }

    /// 연봉 또는 시급 중 하나를 고른다.
    private enum InputKind: Hashable { case annual, hourly }

    private var inputKind: Binding<InputKind> {
        Binding(
            get: { isHourly ? .hourly : .annual },
            set: { isHourly = $0 == .hourly }
        )
    }

    /// 지난 석 달의 월 키(최근 달부터).
    private var pastMonthKeys: [String] {
        (1...3).compactMap { offset in
            MapHomeGrowthPolicy.localCalendar.date(byAdding: .month, value: -offset, to: .now).map { MapHomeSalaryPolicy.monthKey($0) }
        }
    }

    private var paySamples: [MapHomeSalaryPolicy.PaySample] {
        MapHomeSalaryPolicy.paySamples(settings, pastMonthWorkSeconds: pastMonthWorkSeconds)
    }

    private func monthLabel(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let month = Int(parts[1]) else { return key }
        return language.text("\(month)월", "\(parts[0])-\(parts[1])")
    }

    private func won(_ value: Double) -> String { MapHomeSalaryPolicy.wonText(value) }

    var body: some View {
        let settings = settings
        let samples = paySamples
        let rate = MapHomeSalaryPolicy.hourlyRate(settings, monthWorkSeconds: monthWorkSeconds, projectedMonthWorkSeconds: projectedMonthWorkSeconds, samples: samples)
        let model = MapHomeSalaryPolicy.fitPayModel(baseMonthly: MapHomeSalaryPolicy.inputMonthly(settings), samples: samples)
        let expectedPay = MapHomeSalaryPolicy.expectedMonthPay(settings, projectedMonthWorkSeconds: max(projectedMonthWorkSeconds, monthWorkSeconds), samples: samples)
        let basis = settings.showsNetAmounts ? language.text("세후", "net") : language.text("세전", "gross")
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !showsOnlyPayInput {
                    Text(language.text("연봉 카운터", "Salary counter"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(22)), weight: .bold))
                    Text(language.text(
                        "업무 시간에만 번 돈이 쌓여요. 금액은 이 기기에만 저장돼요.",
                        "Earnings grow only during work time. Stored only on this device."
                    ))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                }

                if region.isOverseas {
                    directPayCard
                } else {
                // 1. 연봉 또는 시급. 세전/세후는 표시 기준 하나로 고르고, 입력은 세전·세후 어느 쪽이든 된다.
                card {
                    Picker("", selection: inputKind) {
                        Text(language.text("연봉", "Annual")).tag(InputKind.annual)
                        Text(language.text("시급", "Hourly")).tag(InputKind.hourly)
                    }
                    .pickerStyle(.segmented)
                    if isHourly {
                        let weekly = max(projectedMonthWorkSeconds, monthWorkSeconds) / 3_600 * 7 / 30.4
                        let hourlyGrossNow = hourlyText.isEmpty && hourlyPay <= 0
                            ? MapHomeSalaryPolicy.linkedHourlyGross(settings)
                            : MapHomeSalaryPolicy.hourlyGross(settings, weeklyHours: weekly)
                        field(language.text("세전 시급", "Gross hourly"), text: Binding(
                            get: { hourlyIsNet ? "" : hourlyText },
                            set: { hourlyText = $0 }
                        ), unit: currencyUnit, placeholder: String(Int(hourlyGrossNow.rounded()))) {
                            hourlyIsNet = false
                            hourlyPay = number(hourlyText)
                        }
                        field(language.text("세후 시급", "Net hourly"), text: Binding(
                            get: { hourlyIsNet ? hourlyText : "" },
                            set: { hourlyText = $0 }
                        ), unit: currencyUnit, placeholder: String(Int((hourlyGrossNow * settings.hourlyTax.keepRate).rounded()))) {
                            hourlyIsNet = true
                            hourlyPay = number(hourlyText)
                        }
                        Picker("", selection: $hourlyTaxRaw) {
                            Text(language.text("3.3% 공제", "3.3%")).tag(MapHomeSalaryPolicy.HourlyTax.threePointThree.rawValue)
                            Text(language.text("4대보험", "Insurance")).tag(MapHomeSalaryPolicy.HourlyTax.fourInsurance.rawValue)
                            Text(language.text("세금 없음", "None")).tag(MapHomeSalaryPolicy.HourlyTax.none.rawValue)
                        }
                        .pickerStyle(.segmented)
                        Toggle(language.text("주휴수당 포함(주 15시간 이상)", "Include weekly holiday pay"), isOn: $weeklyHoliday)
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                            .tint(Color.tpAccent)
                        Text(language.text(
                            "시간 = 돈. 근무 시간이 늘면 금액도 같이 올라요. 입력하지 않은 쪽은 세금 방식으로 자동 계산해요.",
                            "Time = money. Earnings rise with work hours. The other field is computed from the tax method."
                        ))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium)).foregroundStyle(Color.tpSecondary)
                    } else {
                        let grossWon = MapHomeSalaryPolicy.linkedAnnualGross(settings)
                        let netWon = MapHomeSalaryPolicy.netOfGross(grossWon)
                        field(language.text("세전 연봉", "Gross annual"), text: Binding(
                            get: { isNetInput ? "" : annualText },
                            set: { annualText = $0 }
                        ), unit: currencyUnit, placeholder: String(Int(grossWon.rounded()))) {
                            isNetInput = false
                            annualPay = number(annualText)
                            monthlyPay = 0
                        }
                        field(language.text("세후 연봉", "Net annual"), text: Binding(
                            get: { isNetInput ? annualText : "" },
                            set: { annualText = $0 }
                        ), unit: currencyUnit, placeholder: String(Int(netWon.rounded()))) {
                            isNetInput = true
                            annualPay = number(annualText)
                            monthlyPay = 0
                        }
                        field(language.text("월급", "Monthly pay"), text: $monthlyText, unit: currencyUnit,
                              placeholder: String(Int(MapHomeSalaryPolicy.inputMonthly(settings).rounded()))) {
                            annualPay = number(monthlyText) * 12
                            monthlyPay = 0
                            annualText = String(Int(annualPay.rounded()))
                        }
                        Text(language.text("연봉이나 월급 중 하나만 적으면 나머지는 자동 계산돼요(월급제면 월급만).", "Enter either annual or monthly; the other is computed."))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium)).foregroundStyle(Color.tpSecondary)
                    }
                }

                // 1-1. 표시 기준: 세전 또는 세후
                card {
                    Picker("", selection: $showsNet) {
                        Text(language.text("세전", "Gross")).tag(false)
                        Text(language.text("세후", "Net")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    Text(language.text("연봉·시급 모두 여기서 고른 기준으로 카운터와 누적 금액을 보여 줘요.", "Counter and totals use this basis for annual and hourly pay."))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium)).foregroundStyle(Color.tpSecondary)
                }
                }

                if !showsOnlyPayInput {
                allowanceCard

                if !isHourly, !region.isOverseas {
                // 2-1. 지난달 실제 받은 월급(수당 포함) → 수당 모델
                card {
                    Text(language.text("받은 월급 기록(실수령 세후, 수당 포함)", "Pay received (net, incl. overtime)"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    ForEach(pastMonthKeys, id: \.self) { key in
                        let hours = (pastMonthWorkSeconds[key] ?? 0) / 3_600
                        HStack {
                            Text(monthLabel(key)).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                            Text(language.text("근무 \(String(format: "%.0f", hours))시간", "\(String(format: "%.0f", hours)) h"))
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)))).foregroundStyle(Color.tpSecondary)
                            Spacer()
                            TextField(language.text("받은 금액", "Received"), text: Binding(
                                get: { grouped(payTexts[key] ?? "") },
                                set: { payTexts[key] = $0.filter(\.isNumber); savePayHistory() }
                            ))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                            Text(currencyUnit).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13))))
                        }
                    }
                    Text(model.sampleCount == 0
                         ? language.text("기록이 없어 법정 기준(통상시급 × 1.5)으로 수당을 봐요. 받은 월급을 넣을수록 정확해져요.", "No records: overtime at 1.5× base. Add months to refine.")
                         : language.text(
                            "기록 \(model.sampleCount)개월로 맞춤: 고정 \(won(model.fixedMonthly)) + 209시간 초과 1시간당 \(won(model.overtimeHourly)).",
                            "Fitted from \(model.sampleCount) months: fixed \(won(model.fixedMonthly)) + \(won(model.overtimeHourly)) per hour over 209."
                         ))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium)).foregroundStyle(Color.tpSecondary)
                    if let expectedPay {
                        row(language.text("이번 달 예상 월급(\(basis))", "Expected this month (\(basis))"), won(expectedPay), bold: true)
                    }
                }

                }

                // 3. 이번 달 누적 금액(고칠 수 있음)
                card {
                    let computed = MapHomeSalaryPolicy.earnings(workSeconds: monthWorkSeconds, hourlyRate: rate ?? 0)
                    field(language.text("이번 달 누적(\(basis))", "This month (\(basis))"), text: $accumText, unit: currencyUnit,
                          placeholder: String(Int(computed.rounded()))) {
                        monthAccum = number(accumText)
                        monthAccumMonth = MapHomeSalaryPolicy.monthKey(.now)
                    }
                    Text(language.text(
                        "근무 \(String(format: "%.1f", monthWorkSeconds / 3_600))시간 기준 계산값 \(won(computed)). 실제와 다르면 고쳐 주세요(비우면 계산값).",
                        "Computed \(won(computed)) for \(String(format: "%.1f", monthWorkSeconds / 3_600)) h. Edit if different."
                    ))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium)).foregroundStyle(Color.tpSecondary)
                }

                // 4. 누적 시급(고칠 수 없음)
                card {
                    row(language.text("누적 시급(\(basis))", "Hourly (\(basis))"), rate.map(won) ?? "-", bold: true)
                    Text(language.text(
                        "이번 달 예상 월급 ÷ 예상 근무 \(String(format: "%.0f", max(projectedMonthWorkSeconds, monthWorkSeconds) / 3_600))시간(지금까지 \(String(format: "%.0f", monthWorkSeconds / 3_600))시간 + 최근 8주 요일별 추세). 야근이 늘면 수당도 같이 늘고, 월말엔 그 달 월급과 맞아요. 누적을 고쳤으면 누적 ÷ 근무 시간.",
                        "Expected pay ÷ projected \(String(format: "%.0f", max(projectedMonthWorkSeconds, monthWorkSeconds) / 3_600)) h (\(String(format: "%.0f", monthWorkSeconds / 3_600)) h so far + 8-week trend). Overtime raises both; exact at month end."
                    ))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium)).foregroundStyle(Color.tpSecondary)
                }

                // 5. 간격별 금액
                Text(language.text("표시 간격", "Update every"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                Picker("", selection: $tickSeconds) {
                    ForEach(MapHomeSalaryPolicy.tickChoices, id: \.self) { seconds in
                        Text(MapHomeSalaryPolicy.intervalTitle(seconds, language: language)).tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                if let rate {
                    card {
                        row(language.text("\(MapHomeSalaryPolicy.intervalTitle(tickSeconds, language: language))마다", "Every \(MapHomeSalaryPolicy.intervalTitle(tickSeconds, language: language))"),
                            won(rate / 3_600 * Double(tickSeconds)), bold: true)
                        row(language.text("초급", "Per second"), region.isOverseas ? won(rate / 3_600) : String(format: "%.1f원", rate / 3_600))
                        row(language.text("분급", "Per minute"), won(rate / 60))
                        row(language.text("시급", "Per hour"), won(rate))
                        row(language.text("일급(8시간)", "Per day (8 h)"), won(rate * 8))
                    }
                }

                if settings.isConfigured {
                    Button(language.text("연봉 카운터 끄기", "Turn off"), role: .destructive) {
                        annualPay = 0; monthlyPay = 0; monthAccum = 0
                        isHourly = false; hourlyPay = 0; hourlyIsNet = false
                        annualText = ""; hourlyText = ""; monthlyText = ""; accumText = ""
                    }
                }
                }
            }
            .padding(22)
            // 입력칸·스위치 밖을 누르면 숫자 키보드를 내린다.
            .contentShape(Rectangle())
            .onTapGesture { hideKeyboard() }
        }
        .scrollDismissesKeyboard(.immediately)
        .safeAreaInset(edge: .bottom) {
            if !showsOnlyPayInput { saveButton }
        }
        .background(Color.tpBackground)
        .onAppear {
            payTexts = settings.payHistory.mapValues { String(Int($0.rounded())) }
            annualText = annualPay > 0 ? String(Int(annualPay.rounded())) : ""
            monthlyText = monthlyPay > 0 ? String(Int(monthlyPay.rounded())) : ""
            hourlyText = hourlyPay > 0 ? String(Int(hourlyPay.rounded())) : ""
            accumText = settings.monthAccumOverride > 0 ? String(Int(settings.monthAccumOverride.rounded())) : ""
            allowanceText = allowanceAmount > 0 ? String(Int(allowanceAmount.rounded())) : ""
            directKind = isHourly ? .hourly : .annual
            directText = amountText(isHourly ? hourlyPay : annualPay)
        }
    }

    /// 해외: 시급·월급·연봉 중 하나의 금액과 세전/세후 이름표만 받는다. 세금은 계산하지 않는다.
    private var directPayCard: some View {
        card {
            Picker("", selection: $directKind) {
                Text(language.text("시급", "Hourly")).tag(DirectKind.hourly)
                Text(language.text("월급", "Monthly")).tag(DirectKind.monthly)
                Text(language.text("연봉", "Annual")).tag(DirectKind.annual)
            }
            .pickerStyle(.segmented)
            .onChange(of: directKind) { _, kind in
                switch kind {
                case .hourly: directText = amountText(hourlyPay)
                case .monthly: directText = amountText(annualPay / 12)
                case .annual: directText = amountText(annualPay)
                }
                saveDirectAmount()
            }
            HStack {
                Text(language.text("금액", "Amount"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                Spacer()
                TextField("0", text: $directText)
                    .keyboardType(region.usesDecimalCurrency ? .decimalPad : .numberPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .onChange(of: directText) { _, _ in saveDirectAmount() }
                Text(currencyUnit).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13))))
            }
            Picker("", selection: Binding(
                get: { isHourly ? hourlyIsNet : isNetInput },
                set: { isNet in
                    hourlyIsNet = isNet
                    isNetInput = isNet
                }
            )) {
                Text(language.text("세전", "Gross")).tag(false)
                Text(language.text("세후", "Net")).tag(true)
            }
            .pickerStyle(.segmented)
            Text(language.text(
                "입력한 금액을 그대로 써요. 세금은 계산하지 않아요.",
                "The amount is used as entered. Taxes are not calculated."
            ))
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium)).foregroundStyle(Color.tpSecondary)
        }
    }

    private func saveDirectAmount() {
        let amount = region.amount(from: directText)
        isHourly = directKind == .hourly
        monthlyPay = 0
        switch directKind {
        case .hourly: hourlyPay = amount
        case .monthly: annualPay = amount * 12
        case .annual: annualPay = amount
        }
    }

    private func amountText(_ value: Double) -> String {
        guard value > 0 else { return "" }
        let isWhole = value == value.rounded()
        return value.formatted(.number.locale(region.locale).grouping(.never).precision(.fractionLength(isWhole ? 0 : 2)))
    }

    /// 입력값은 적는 대로 저장되므로, 저장 버튼은 입력을 마치고 창을 닫는다.
    private var saveButton: some View {
        Button {
            hideKeyboard()
            dismiss()
        } label: {
            Text(language.text("저장", "Save"))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.tpAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Color.tpBackground)
        .accessibilityIdentifier("salarySettings.save")
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// 용돈: 연봉과 따로 쓰며, 환산 시급만 보여 준다.
    private var allowanceCard: some View {
        let allowance = MapHomeAllowancePolicy.Settings(
            amount: allowanceAmount,
            period: MapHomeAllowancePolicy.Period(rawValue: allowancePeriodRaw) ?? .month
        )
        return card {
            Picker("", selection: $allowancePeriodRaw) {
                Text(language.text("한 달", "Month")).tag(MapHomeAllowancePolicy.Period.month.rawValue)
                Text(language.text("한 주", "Week")).tag(MapHomeAllowancePolicy.Period.week.rawValue)
                Text(language.text("하루", "Day")).tag(MapHomeAllowancePolicy.Period.day.rawValue)
            }
            .pickerStyle(.segmented)
            field(language.text("용돈", "Allowance"), text: $allowanceText, unit: currencyUnit, placeholder: "0") {
                allowanceAmount = number(allowanceText)
            }
            if allowance.isConfigured {
                row(language.text("환산 시급", "Hourly"), won(MapHomeAllowancePolicy.hourlyRate(allowance, on: .now)), bold: true)
            }
            Text(language.text(
                "근무·수면과 상관없이 24시간 내내 쌓여요. 카운터에는 그날 0시부터 번 돈이 보여요.",
                "Grows around the clock. The counter shows what you earned since midnight."
            ))
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium)).foregroundStyle(Color.tpSecondary)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func row(_ title: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.tpSecondary)
            Spacer()
            Text(value).monospacedDigit().fontWeight(bold ? .bold : .medium)
        }
        .font(.taptionFixed(size: bold ? 15 : 13))
    }

    /// 입력은 바로 저장한다.
    private func field(_ title: String, text: Binding<String>, unit: String, placeholder: String, onChange: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
            Spacer()
            TextField(grouped(placeholder), text: Binding(
                get: { grouped(text.wrappedValue) },
                set: { text.wrappedValue = region.usesDecimalCurrency ? $0.filter { $0.isNumber || String($0) == region.locale.decimalSeparator } : $0.filter(\.isNumber) }
            ))
                .keyboardType(region.usesDecimalCurrency ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .onChange(of: text.wrappedValue) { _, _ in onChange() }
            Text(unit).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13))))
        }
    }

    private func number(_ text: String) -> Double { region.amount(from: text) }

    private func grouped(_ text: String) -> String {
        region.usesDecimalCurrency ? text : MapHomeSalaryPolicy.grouped(text)
    }

    private func savePayHistory() {
        var history = settings.payHistory
        for (key, text) in payTexts { history[key] = number(text) }
        payHistoryRaw = MapHomeSalaryPolicy.encodePayHistory(history)
    }
}
