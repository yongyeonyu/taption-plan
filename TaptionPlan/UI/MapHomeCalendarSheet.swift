import SwiftUI

/// 달력 점: 기록은 있지만 미확인 활동이 남은 날(빨강), 기록이 끝난 날(초록). 기록이 없으면 점이 없다.
enum MapHomeCalendarLogStatus: Equatable {
    case incomplete
    case complete
}

enum MapHomeCalendarLogStatusPolicy {
    /// `month`가 속한 달의 날짜별 상태. 센서·기록이 없는 날은 담지 않는다.
    static func statuses(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        month: Date,
        asOf now: Date,
        calendar: Calendar
    ) -> [Date: MapHomeCalendarLogStatus] {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let end = calendar.date(byAdding: .month, value: 1, to: first),
              let days = calendar.range(of: .day, in: .month, for: first) else { return [:] }
        let monthActuals = actuals.filter {
            let span = $0.span(asOf: now)
            return span.start < end && first < span.end
        }
        let monthTravel = travel.filter { $0.span.start < end && first < $0.span.end }
        guard !monthActuals.isEmpty || !monthTravel.isEmpty else { return [:] }
        var result: [Date: MapHomeCalendarLogStatus] = [:]
        for offset in 0..<days.count {
            guard let day = calendar.date(byAdding: .day, value: offset, to: first) else { continue }
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            let hasRecord = monthActuals.contains {
                let span = $0.span(asOf: now)
                return span.start < dayEnd && day < span.end
            } || monthTravel.contains { $0.span.start < dayEnd && day < $0.span.end }
            guard hasRecord else { continue }
            let segments = MapHomeTimeRailSegmentEngine.segments(
                from: monthActuals, travel: monthTravel, on: day, asOf: now, calendar: calendar
            )
            guard !segments.isEmpty else { continue }
            result[day] = segments.contains { $0.categoryID == "unconfirmed" } ? .incomplete : .complete
        }
        return result
    }
}

/// 달력 하단 메뉴의 시간 종류. `rawValue`는 대분류 canonical 분류 ID와 같다(`DayPhase`).
enum MapHomeCalendarTimeKind: String, CaseIterable, Identifiable {
    case sleep, movement, study, work, exercise, hobby

    var id: String { rawValue }

    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .sleep: language.text("수면시간", "Sleep")
        case .movement: language.text("이동시간", "Travel")
        case .study: language.text("수업시간", "Class")
        case .work: language.text("업무시간", "Work")
        case .exercise: language.text("운동시간", "Exercise")
        case .hobby: language.text("취미시간", "Hobby")
        }
    }

    var systemImage: String {
        switch self {
        case .sleep: "moon.zzz.fill"
        case .movement: "figure.walk.motion"
        case .study: "graduationcap.fill"
        case .work: "briefcase.fill"
        case .exercise: "dumbbell.fill"
        case .hobby: "paintpalette.fill"
        }
    }
}

enum MapHomeCalendarTimeTotalsPolicy {
    /// `month`가 속한 달의 날짜별·대분류별 시간(초). 오늘 이후와 기록이 없는 날은 담지 않는다.
    static func totals(
        actuals: [ActualRecord],
        travel: [TravelSegment],
        stays: [PlaceStay],
        placeKinds: [String: FrequentPlaceKind],
        month: Date,
        asOf now: Date,
        calendar: Calendar
    ) -> [Date: [String: TimeInterval]] {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let end = calendar.date(byAdding: .month, value: 1, to: first),
              let days = calendar.range(of: .day, in: .month, for: first) else { return [:] }
        let monthActuals = actuals.filter {
            let span = $0.span(asOf: now)
            return span.start < end && first < span.end
        }
        let monthTravel = travel.filter { $0.span.start < end && first < $0.span.end }
        let monthStays = stays.filter { $0.span.start < end && first < $0.span.end }
        guard !monthActuals.isEmpty || !monthTravel.isEmpty || !monthStays.isEmpty else { return [:] }
        var result: [Date: [String: TimeInterval]] = [:]
        for offset in 0..<days.count {
            guard let day = calendar.date(byAdding: .day, value: offset, to: first),
                  day <= now,
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            let phases = DayPhaseEngine.completePhases(
                actuals: monthActuals,
                travel: monthTravel,
                stays: monthStays,
                placeKinds: placeKinds,
                in: TimeSpan(start: day, end: dayEnd),
                asOf: now
            )
            var byID: [String: TimeInterval] = [:]
            for entry in DayPhaseEngine.categoryDurations(phases, scope: .canonical) where entry.actual > 0 && entry.categoryID != "unconfirmed" {
                byID[entry.categoryID, default: 0] += entry.actual
            }
            if !byID.isEmpty { result[day] = byID }
        }
        return result
    }

    /// 달력 칸의 짧은 표기: 1시간 이상은 `7:20`, 한 시간 미만은 `45m`. 0은 빈 문자열.
    static func cellText(seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        guard minutes > 0 else { return "" }
        if minutes < 60 { return "\(minutes)m" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60):\(String(format: "%02d", remainder))"
    }

    static func durationText(seconds: TimeInterval, language: MapHomeLanguage) -> String {
        let minutes = Int((seconds / 60).rounded())
        guard minutes > 0 else { return language.text("0분", "0 min") }
        let hours = minutes / 60, remainder = minutes % 60
        if hours == 0 { return language.text("\(remainder)분", "\(remainder) min") }
        if remainder == 0 { return language.text("\(hours)시간", "\(hours) h") }
        return language.text("\(hours)시간 \(remainder)분", "\(hours) h \(remainder) min")
    }
}

/// A compact month selector used by the map home header.
///
/// The sheet deliberately owns only calendar presentation. Holiday dates are
/// supplied by the caller so the same verified holiday source can be reused by
/// the timeline and other date pickers.
struct MapHomeCalendarSheet: View {
    @Binding private var selectedDate: Date
    private let holidayName: (Date) -> String?
    private let logStatuses: (Date) -> [Date: MapHomeCalendarLogStatus]
    private let timeTotals: (Date) async -> [Date: [String: TimeInterval]]
    private let timeTint: (String) -> Color
    private let language: MapHomeLanguage
    private let calendar: Calendar

    @State private var displayedMonth: Date
    @State private var statuses: [Date: MapHomeCalendarLogStatus] = [:]
    @State private var selectedKind: MapHomeCalendarTimeKind?
    @State private var totals: [Date: [String: TimeInterval]] = [:]

    init(
        selectedDate: Binding<Date>,
        holidayName: @escaping (Date) -> String?,
        logStatuses: @escaping (Date) -> [Date: MapHomeCalendarLogStatus] = { _ in [:] },
        timeTotals: @escaping (Date) async -> [Date: [String: TimeInterval]] = { _ in [:] },
        timeTint: @escaping (String) -> Color = { _ in Color.tpAccent },
        language: MapHomeLanguage = .korean
    ) {
        self._selectedDate = selectedDate
        self.holidayName = holidayName
        self.logStatuses = logStatuses
        self.timeTotals = timeTotals
        self.timeTint = timeTint
        self.language = language

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = language.locale
        calendar.timeZone = .current
        calendar.firstWeekday = 1
        self.calendar = calendar

        let day = calendar.startOfDay(for: selectedDate.wrappedValue)
        self._displayedMonth = State(initialValue: calendar.date(
            from: calendar.dateComponents([.year, .month], from: day)
        ) ?? day)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 18)

                weekdayHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 18)

                monthGrid
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                timeMenu
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                if let selectedKind {
                    timePanel(for: selectedKind)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
            }
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.tpBackground)
        .presentationDetents([.height(selectedKind == nil ? 540 : 700), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.tpBackground)
        .task(id: displayedMonth) {
            statuses = logStatuses(displayedMonth)
            totals = [:]
            let month = displayedMonth
            let value = await timeTotals(month)
            guard !Task.isCancelled, month == displayedMonth else { return }
            totals = value
        }
    }

    private func seconds(of kind: MapHomeCalendarTimeKind, on date: Date) -> TimeInterval {
        totals[calendar.startOfDay(for: date)]?[kind.rawValue] ?? 0
    }

    private var timeMenu: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(MapHomeCalendarTimeKind.allCases) { kind in
                let isOn = selectedKind == kind
                let tint = timeTint(kind.rawValue)
                Button {
                    selectedKind = isOn ? nil : kind
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: kind.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                        Text(kind.title(language))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(isOn ? tint : Color.tpInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(isOn ? tint.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isOn ? tint : Color.tpLine, lineWidth: isOn ? 1.2 : 0.8)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(kind.title(language))
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    private func timePanel(for kind: MapHomeCalendarTimeKind) -> some View {
        let tint = timeTint(kind.rawValue)
        let daysInMonth = calendar.range(of: .day, in: .month, for: displayedMonth)?.count ?? 30
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)) ?? displayedMonth
        let days = (0..<daysInMonth).compactMap { calendar.date(byAdding: .day, value: $0, to: monthStart) }
        let values = days.map { day in day <= Date.now ? seconds(of: kind, on: day) : 0 }
        let elapsedDays = max(1, days.filter { $0 <= Date.now }.count)
        let sum = values.reduce(0, +)
        let maxValue = max(values.max() ?? 0, 1)
        let selected = calendar.startOfDay(for: selectedDate)
        let selectedInMonth = calendar.isDate(selected, equalTo: monthStart, toGranularity: .month)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(kind.title(language))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                Spacer()
                if selectedInMonth {
                    Text(language.text("\(calendar.component(.month, from: selected))월 \(calendar.component(.day, from: selected))일",
                                       selected.formatted(.dateTime.month(.abbreviated).day())))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.tpSecondary)
                }
            }
            Text(MapHomeCalendarTimeTotalsPolicy.durationText(
                seconds: selectedInMonth ? seconds(of: kind, on: selected) : 0, language: language))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint.opacity(calendar.isDate(day, inSameDayAs: selected) ? 1 : 0.4))
                        .frame(height: max(2, 44 * values[index] / maxValue))
                }
            }
            .frame(height: 44, alignment: .bottom)
            HStack(spacing: 8) {
                timeStat(language.text("이번 달 합계", "Month total"),
                         MapHomeCalendarTimeTotalsPolicy.durationText(seconds: sum, language: language))
                timeStat(language.text("하루 평균", "Daily average"),
                         MapHomeCalendarTimeTotalsPolicy.durationText(seconds: sum / Double(elapsedDays), language: language))
            }
        }
        .padding(12)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.tpLine.opacity(0.9), lineWidth: 0.8) }
    }

    private func timeStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.tpSecondary)
            Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Color.tpInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.tpBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var header: some View {
        HStack {
            Button {
                shiftMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    .frame(width: 34, height: 34)
                    .background(Color.tpBackground, in: Circle())
            }
            .accessibilityLabel(language.text("이전 달", "Previous month"))

            Spacer(minLength: 12)

            Text(monthTitle)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpInk)

            Spacer(minLength: 12)

            Button {
                shiftMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    .frame(width: 34, height: 34)
                    .background(Color.tpBackground, in: Circle())
            }
            .accessibilityLabel(language.text("다음 달", "Next month"))
        }
    }

    private var weekdayHeader: some View {
        let weekdays = language == .korean
            ? ["일", "월", "화", "수", "목", "금", "토"]
            : ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return LazyVGrid(columns: gridColumns, spacing: 0) {
            ForEach(Array(weekdays.enumerated()), id: \.offset) { index, weekday in
                VStack(spacing: 2) {
                    Image(weekdayIconName(index: index))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)

                    Text(weekday)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(weekdayColor(index: index))
                }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 7) {
            ForEach(monthDays, id: \.self) { date in
                if let date {
                    dayCell(for: date)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
            }
        }
    }

    private func dayCell(for date: Date) -> some View {
        let day = calendar.component(.day, from: date)
        let weekday = calendar.component(.weekday, from: date)
        let holiday = holidayName(date)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)
        let status = statuses[calendar.startOfDay(for: date)]

        return Button {
            selectedDate = date
        } label: {
            VStack(spacing: 2) {
                Text(String(day))
                    .font(.system(size: 15, weight: isSelected ? .bold : .regular, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white : dayColor(weekday: weekday, holiday: holiday))
                    .frame(width: 32, height: 28)
                    .background {
                        if isSelected {
                            Circle().fill(Color.tpAccent)
                        } else if isToday {
                            Circle().stroke(Color.tpAccent.opacity(0.65), lineWidth: 1.5)
                        }
                    }

                if let selectedKind {
                    Text(MapHomeCalendarTimeTotalsPolicy.cellText(seconds: seconds(of: selectedKind, on: date)))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(timeTint(selectedKind.rawValue))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(height: 12)
                } else {
                    Circle()
                        .fill(logDotColor(status))
                        .frame(width: 4, height: 4)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(day: day, date: date, holiday: holiday, status: status))
    }

    private var monthDays: [Date?] {
        guard let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)),
              let dayRange = calendar.range(of: .day, in: .month, for: firstDay)
        else { return [] }

        let leading = calendar.component(.weekday, from: firstDay) - calendar.firstWeekday
        let normalizedLeading = (leading + 7) % 7
        let dates = dayRange.compactMap { day -> Date? in
            calendar.date(byAdding: .day, value: day - 1, to: firstDay)
        }
        return Array(repeating: nil, count: normalizedLeading) + dates
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.calendar = calendar
        formatter.dateFormat = language.monthTitleFormat
        return formatter.string(from: displayedMonth)
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    }

    private func shiftMonth(by value: Int) {
        guard let date = calendar.date(byAdding: .month, value: value, to: displayedMonth) else { return }
        displayedMonth = date
    }

    private func weekdayColor(index: Int) -> Color {
        index == 0 ? .tpHoliday : index == 6 ? .tpSaturday : .tpSecondary
    }

    private func weekdayIconName(index: Int) -> String {
        switch index {
        case 0: "MapHomeCalendarSunday"
        case 1: "MapHomeCalendarMonday"
        case 2: "MapHomeCalendarTuesday"
        case 3: "MapHomeCalendarWednesday"
        case 4: "MapHomeCalendarThursday"
        case 5: "MapHomeCalendarFriday"
        default: "MapHomeCalendarSaturday"
        }
    }

    private func dayColor(weekday: Int, holiday: String?) -> Color {
        if holiday != nil || weekday == 1 { return .tpHoliday }
        if weekday == 7 { return .tpSaturday }
        return .tpInk
    }

    private func logDotColor(_ status: MapHomeCalendarLogStatus?) -> Color {
        switch status {
        case .incomplete: .tpHoliday
        case .complete: Color(red: 0.25, green: 0.70, blue: 0.40)
        case nil: .clear
        }
    }

    private func accessibilityLabel(
        day: Int, date: Date, holiday: String?, status: MapHomeCalendarLogStatus?
    ) -> String {
        var title = language == .korean
            ? "\(monthTitle) \(day)일"
            : "\(monthTitle) \(day)"
        if let holiday { title += ", \(holiday)" }
        switch status {
        case .incomplete: title += language.text(", 미확인 활동 있음", ", unconfirmed activity")
        case .complete: title += language.text(", 기록 완료", ", fully logged")
        case nil: break
        }
        return title
    }
}
